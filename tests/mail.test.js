'use strict';
// Beings Town 邮局 · 账本旁边那个邮箱的测试（Node）
// 对应 ledger/mail.js。这里一个网络请求都没有——Town 只信 being 的 Heart，
// HTTP 那两下永远在 being 手里，这一层只管文件。

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const mail = require('../ledger/mail.js');

function tempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'kairos-mail-'));
}

function outbox(overrides = {}) {
  return {
    protocol: 'kairos.mail-outbox/1',
    device_id: 'phone',
    device_name: 'iPhone',
    updated_at: '2026-09-07T10:00:00Z',
    last_seq: 3,
    drafts: [
      { seq: 1, id: 'd1', recipient: 'Judy', content: '一', created_at: '2026-09-07T10:00:01Z' },
      { seq: 2, id: 'd2', recipient: 'Judy', content: '二', created_at: '2026-09-07T10:00:02Z' },
      { seq: 3, id: 'd3', recipient: 'Hex', content: '三', created_at: '2026-09-07T10:00:03Z' },
    ],
    ...overrides,
  };
}

function receipt(draftID, overrides = {}) {
  return {
    draft_id: draftID,
    ok: true,
    message_id: 'm-' + draftID,
    recipient: 'judy',
    error: null,
    at: '2026-09-07T10:01:00Z',
    ...overrides,
  };
}

// ── 待发清单 ─────────────────────────────────────────────────────────────

test('待发＝水位以上且还没有回执', () => {
  const box = {
    ...mail.emptyMailbox(),
    outbox_watermark: { phone: 1 },
    receipts: [receipt('d2')],
  };
  const waiting = mail.pending(box, [outbox()]);
  assert.deepStrictEqual(waiting.map((d) => d.id), ['d3']);
});

test('回执写了但水位没推上去时，不会把同一封再发一遍', () => {
  // 只看水位的话 d1 会被再发一次——这正是「重复投递」的来源。
  const box = { ...mail.emptyMailbox(), outbox_watermark: {}, receipts: [receipt('d1')] };
  const waiting = mail.pending(box, [outbox()]);
  assert.deepStrictEqual(waiting.map((d) => d.id), ['d2', 'd3']);
});

test('待发按时间排，多台设备混在一起也是一条队', () => {
  const other = outbox({
    device_id: 'mac',
    drafts: [{ seq: 1, id: 'm1', recipient: 'Hex', content: '插队', created_at: '2026-09-07T10:00:00Z' }],
  });
  const waiting = mail.pending(mail.emptyMailbox(), [outbox(), other]);
  assert.deepStrictEqual(waiting.map((d) => d.id), ['m1', 'd1', 'd2', 'd3']);
});

test('别的协议版本的草稿箱不认', () => {
  const alien = outbox({ protocol: 'kairos.mail-outbox/9' });
  const dir = tempDir();
  const ledger = path.join(dir, 'projection-snapshot.json');
  fs.mkdirSync(path.join(dir, 'mail-outbox'));
  fs.writeFileSync(path.join(dir, 'mail-outbox', 'phone.json'), JSON.stringify(alien));
  assert.deepStrictEqual(mail.loadOutboxes(ledger), []);
});

// ── 水位 ────────────────────────────────────────────────────────────────

test('水位只推到「连续已回执」为止，中间有空档就停下', () => {
  // 跳着处理：d1、d3 有回执，d2 没有。取最大会把 d2 一起冲掉——那封信从此蒸发。
  const ids = new Set(['d1', 'd3']);
  assert.strictEqual(mail.contiguousWatermark(outbox(), ids, 0), 1);
});

test('全部回执了水位推到底', () => {
  const ids = new Set(['d1', 'd2', 'd3']);
  assert.strictEqual(mail.contiguousWatermark(outbox(), ids, 0), 3);
});

test('水位不倒退', () => {
  assert.strictEqual(mail.contiguousWatermark(outbox(), new Set(), 2), 2);
});

// ── 回执 ────────────────────────────────────────────────────────────────

test('成功的回执推水位', () => {
  const next = mail.applyReceipt(mail.emptyMailbox(), [outbox()], receipt('d1'));
  assert.strictEqual(next.outbox_watermark.phone, 1);
  assert.strictEqual(next.receipts.length, 1);
});

test('失败的回执照样推水位——否则那封发不出去的信会永远排在队首', () => {
  const failed = receipt('d1', { ok: false, message_id: null, error: '404 being not found' });
  const next = mail.applyReceipt(mail.emptyMailbox(), [outbox()], failed);
  assert.strictEqual(next.outbox_watermark.phone, 1);
  assert.strictEqual(mail.pending(next, [outbox()]).map((d) => d.id).join(), 'd2,d3');
});

test('同一封草稿重复写回执只留最后一条', () => {
  let box = mail.applyReceipt(mail.emptyMailbox(), [outbox()], receipt('d1', { ok: false, error: '超时' }));
  box = mail.applyReceipt(box, [outbox()], receipt('d1'));
  assert.strictEqual(box.receipts.filter((r) => r.draft_id === 'd1').length, 1);
  assert.strictEqual(box.receipts.find((r) => r.draft_id === 'd1').ok, true);
});

test('给一个草稿箱里没有的 id 写回执会明说，不静默', () => {
  assert.throws(
    () => mail.applyReceipt(mail.emptyMailbox(), [outbox()], receipt('不存在')),
    mail.MailError
  );
});

test('草稿还在设备上的回执不会被剪掉', () => {
  // 先塞满一堆早就没有对应草稿的旧回执，再给活着的草稿写一条。
  const stale = Array.from({ length: mail.RECEIPT_CAP + 50 }, (_, i) => receipt('old-' + i, {
    at: '2026-09-0' + (1 + (i % 5)) + 'T00:00:00Z',
  }));
  const box = { ...mail.emptyMailbox(), receipts: stale };
  const next = mail.applyReceipt(box, [outbox()], receipt('d1'));
  assert.ok(next.receipts.some((r) => r.draft_id === 'd1'));
  assert.ok(next.receipts.length <= mail.RECEIPT_CAP + 1);
});

// ── 灌镜像 ───────────────────────────────────────────────────────────────

test('只取到一半时，另一半保持原样（别把「这次没取到」写成「一封都没有」）', () => {
  const box = {
    ...mail.emptyMailbox(),
    received: [{ id: '1', sender: 'judy', recipient: 'me', content: '在吗', created_at: '2026-09-07T10:00:00+08:00' }],
    sent: [{ id: '2', sender: 'me', recipient: 'judy', content: '在', created_at: '2026-09-07T10:01:00+08:00' }],
  };
  const next = mail.applySync(box, { received: { count: 0, messages: [] } });
  assert.strictEqual(next.received.length, 0);
  assert.strictEqual(next.sent.length, 1, 'sent 没给就不该动');
});

test('Town 的字段原样保留，不认识的也带走', () => {
  const next = mail.applySync(mail.emptyMailbox(), {
    received: { count: 1, messages: [{
      id: 7, sender: 'judy', recipient: 'me', content: '嗨',
      created_at: '2026-09-07T21:30:00+08:00', delivery_status: 'delivered',
      // 邮局以后加的新字段：不该被这一层吃掉
      thread_id: 't-1',
    }] },
  });
  assert.strictEqual(next.received[0].id, '7', 'id 统一成字符串');
  assert.strictEqual(next.received[0].delivery_status, 'delivered');
  assert.strictEqual(next.received[0].thread_id, 't-1');
  assert.ok(next.synced_at, '同步时间要落下来，界面靠它说「上次去邮局是什么时候」');
});

test('镜像不是档案馆：超过上限只留最近的', () => {
  const messages = Array.from({ length: mail.MESSAGE_CAP + 40 }, (_, i) => ({
    id: String(i), sender: 'judy', recipient: 'me', content: String(i),
    created_at: new Date(Date.UTC(2026, 0, 1) + i * 60000).toISOString(),
  }));
  const next = mail.applySync(mail.emptyMailbox(), { received: messages });
  assert.strictEqual(next.received.length, mail.MESSAGE_CAP);
  assert.strictEqual(next.received.at(-1).id, String(mail.MESSAGE_CAP + 39), '最新的要留着');
});

test('没有 id 的信不敢往镜像里放', () => {
  assert.throws(
    () => mail.applySync(mail.emptyMailbox(), { received: [{ sender: 'judy', content: '?' }] }),
    mail.MailError
  );
});

test('认不出的 Town 返回明说，不当成空邮箱', () => {
  assert.throws(() => mail.applySync(mail.emptyMailbox(), { received: { oops: 1 } }), mail.MailError);
});

// ── 落盘 ────────────────────────────────────────────────────────────────

test('邮箱是账本的邻居，不是账本的一部分', () => {
  const ledger = '/tmp/x/Kairos/projection-snapshot.json';
  assert.strictEqual(mail.mailboxPath(ledger), '/tmp/x/Kairos/mailbox.json');
  assert.strictEqual(mail.outboxDir(ledger), '/tmp/x/Kairos/mail-outbox');
});

test('读写往返：写下去的读得回来', () => {
  const file = path.join(tempDir(), 'mailbox.json');
  const written = mail.writeMailboxUnlocked(mail.applySync(mail.emptyMailbox(), {
    received: [{ id: '1', sender: 'judy', recipient: 'me', content: '嗨', created_at: '2026-09-07T21:30:00+08:00' }],
    beingID: 'me',
    beingName: 'Being',
  }), file);
  const read = mail.readMailbox(file);
  assert.strictEqual(read.being_id, 'me');
  assert.strictEqual(read.received[0].content, '嗨');
  assert.strictEqual(read.protocol, mail.MAILBOX_PROTOCOL);
  assert.strictEqual(read.synced_at, written.synced_at);
});

test('邮箱文件不在＝空邮箱，不是错误（第一次用本来就没有）', () => {
  const box = mail.readMailbox(path.join(tempDir(), 'mailbox.json'));
  assert.strictEqual(box.synced_at, null);
  assert.deepStrictEqual(box.received, []);
});

test('协议版本不认识就报错，不硬着头皮读', () => {
  const file = path.join(tempDir(), 'mailbox.json');
  fs.writeFileSync(file, JSON.stringify({ protocol: 'kairos.mailbox/9' }));
  assert.throws(() => mail.readMailbox(file), mail.MailError);
});

test('锁内读改写：mutate 返回 undefined 就不写盘', () => {
  const file = path.join(tempDir(), 'mailbox.json');
  mail.withMailboxLock(() => undefined, { file, purpose: 'test' });
  assert.strictEqual(fs.existsSync(file), false);
});
