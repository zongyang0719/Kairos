'use strict';
// 多端写入：把各设备的 outbox 并进账本。Swift 侧 KairosOutboxDrain 同形。
//
// 每台设备只写自己的 outbox/<设备id>.json，账本只有 Mac / being 写——每个文件永远一个写者，
// iCloud 那套「后写的整份盖掉先写的」就伤不到任何人。并入方不改设备的文件，只在账本里
// 记水位 sync.outbox_watermark[设备id]；设备自己看水位、自己删自己的。

const fs = require('fs');
const path = require('path');
const store = require('./store.js');

const BUSINESS = store.BUSINESS_FIELDS;
/** 老格式 outbox 条目不知道改了什么；老手机界面能改的只有这三样。Swift 侧 legacyFields 同。
 *  `state` 撤了（并进 status），老 outbox 里那一格按同一张表折过来——
 *  手机上「了结」按的就是它，丢了等于人在手机上勾掉的那一下没算数。 */
const LEGACY_FIELDS = ['status', 'tier', 'title'];

function outboxDir(ledgerPath) {
  return path.join(path.dirname(ledgerPath), 'outbox');
}

function loadOutboxes(ledgerPath) {
  const dir = outboxDir(ledgerPath);
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir)
    .filter((name) => name.endsWith('.json'))
    .map((name) => {
      const file = path.join(dir, name);
      try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
      catch (error) {
        // 手机写的 outbox 同样住在 iCloud，同样会被逐出成占位符：拉一下再读。
        if (!store.isDataless(error) || !store.materialize(file)) return null;
        try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
      }
    })
    .filter((o) => o && o.protocolVersion === 'kairos.outbox/1');
}

/** 纯函数：把 outboxes 里水位以上的条目并进 ledger，推水位。返回 {ledger, applied} */
function draining(ledger, outboxes) {
  const next = { ...ledger, items: [...(ledger.items || [])], sync: { ...(ledger.sync || {}) } };
  const watermarks = { ...(next.sync.outbox_watermark || {}) };
  const applied = [];

  for (const outbox of outboxes) {
    const mark = watermarks[outbox.deviceID] || 0;
    const fresh = (outbox.entries || []).filter((e) => e.seq > mark).sort((a, b) => a.seq - b.seq);
    if (!fresh.length) continue;

    for (const entry of fresh) {
      const index = next.items.findIndex((i) => i.id === entry.itemID);
      if (entry.op === 'delete') {
        if (index >= 0) next.items.splice(index, 1);
        applied.push({ device: outbox.deviceName, op: 'delete', id: entry.itemID });
        continue;
      }
      // 手机那版可能还在写 /2 的形状（球权、next/scores/links）：进账本之前先折成 /3，
      // 否则一条老手机的改动会把撤掉的字段又种回账本里。和 readLedger 用的是同一个函数。
      const payload = entry.item ? store.migrateItemToMergedStatus(entry.item) : null;
      if (!payload) continue;
      if (index >= 0) {
        const current = next.items[index];
        // 只叠这台设备真正改过的字段（entry.fields）。手机手里那份账本可能是旧的
        // （实测：手机可能读的是好几天前的旧副本），整条 payload 盖上去会把 being 后来
        // 写的字段一并抹回旧值。老格式条目（没有 fields）只认老手机界面能改的三样，
        // 而且账本那条要是在这条改动之后又被动过，手机那份就是过时的，整条跳过。
        // Swift 侧 KairosOutboxEntry.merged(onto:) 同形。
        let fields = entry.fields;
        if (!Array.isArray(fields)) {
          if (Date.parse(current.updated_at || 0) > Date.parse(entry.createdAt || 0)) continue;
          fields = LEGACY_FIELDS;
        }
        const merged = { ...current };
        const lastWriter = { ...(current.lastWriter || {}) };
        let touched = false;
        for (const field of fields) {
          if (!BUSINESS.includes(field) || !(field in payload)) continue;
          if (JSON.stringify(current[field]) !== JSON.stringify(payload[field])) {
            merged[field] = payload[field];
            lastWriter[field] = store.HUMAN; // 手机上也是人改的，规则 2 照样算
            touched = true;
          }
        }
        if (!touched) continue;
        merged.lastWriter = lastWriter;
        merged.localRev = (current.localRev || 0) + 1;
        merged.updated_at = payload.updated_at || new Date().toISOString();
        next.items[index] = merged;
        applied.push({ device: outbox.deviceName, op: 'upsert', id: entry.itemID, title: merged.title });
      } else {
        next.items.push({
          id: entry.itemID, localRev: 1, syncedLocalRev: 0, beingRev: 0, remoteKnown: false,
          title: '', summary: '', brief: '', reason: '', ask: '',
          options: [], tier: 'P3', status: 'todo', project: '', source: 'todo', excerpt: '', evidence: [],
          ...payload,
          lastWriter: {},
          updated_at: payload.updated_at || new Date().toISOString(),
        });
        applied.push({ device: outbox.deviceName, op: 'create', id: entry.itemID, title: payload.title });
      }
    }
    watermarks[outbox.deviceID] = Math.max(...fresh.map((e) => e.seq));
  }
  next.sync.outbox_watermark = watermarks;
  return { ledger: next, applied };
}

/** 锁内并入。没有新东西就不写盘。 */
function drain(ledgerPath) {
  const outboxes = loadOutboxes(ledgerPath);
  let applied = [];
  store.withLedgerLock((ledger) => {
    const result = draining(ledger, outboxes);
    applied = result.applied;
    return applied.length ? result.ledger : undefined;
  }, { ledgerPath, purpose: 'drain outbox' });
  return applied;
}

module.exports = { outboxDir, loadOutboxes, draining, drain };
