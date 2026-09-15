'use strict';
// Beings Town 邮局 · 账本旁边的邮箱
//
// ## 为什么这一层存在
//
// Town 的 DM 接口按 **IP 信任**放行：`GET /api/channels/help` 原话是
// 「IP Trust — automatic for beings via Heart. Caddy injects x-town-client-ip」。
// 被信任的是 being 的 Heart，不是人类的 Mac/手机——Kairos 直接打过去只有
// `401 {"error":"missing credentials"}`（实测）。Loom 那边也没有转发口子。
//
// 所以邮件只能由 being 代收代发。而**递给 Kairos 的管子不能是对话通道**（v2.3：机器对机器
// 的流量不该经过对话）。于是邮箱走和账本同一套地基——每个文件一个写者：
//
//     Kairos/mailbox.json             being 写。Town 收发件箱的镜像 + 回执 + 水位。
//     Kairos/mail-outbox/<设备>.json   那台设备写。人类写了、还没发出去的信。
//
// being 每次醒来做三件事（HTTP 那两下只能它自己用 act(http) 打，本文件碰不到网）：
//
//     node ledger/cli.js mail-pending --json      # 有没有要替人类发的
//     → act(http) POST https://beings.town/api/messages {recipient, content}
//     node ledger/cli.js mail-receipt <id> --message-id <mid> --recipient <who>
//     node ledger/cli.js mail-receipt <id> --error "..."          # 发失败也要写
//     → act(http) GET /api/messages ; GET /api/messages?with=sent
//     node ledger/cli.js mail-sync                # 两份 JSON 从 stdin 灌进来
//
// ## 水位为什么按「连续已回执」算
//
// 水位一推过去，设备就会把那几封草稿删掉。所以只有**确实处理过**（不管成败，
// 有回执就算处理过）的才能推。按「连续」算而不是「取最大」：being 要是跳着处理，
// 取最大会把中间那封还没发的一起冲掉，那封信从此人间蒸发且没人知道。

const fs = require('fs');
const path = require('path');
const store = require('./store.js');
const paths = require('./paths.js');

const MAILBOX_PROTOCOL = 'kairos.mailbox/1';
const OUTBOX_PROTOCOL = 'kairos.mail-outbox/1';
/** Town 那边本来就只回最近 100 封，留点余量就够。镜像不是档案馆。 */
const MESSAGE_CAP = 300;
/** 回执只是给界面看个结果。草稿早剪掉了，留太多没意义。 */
const RECEIPT_CAP = 200;

class MailError extends Error {}

function mailboxPath(ledgerPath = paths.LEDGER) {
  return path.join(path.dirname(ledgerPath), 'mailbox.json');
}

function outboxDir(ledgerPath = paths.LEDGER) {
  return path.join(path.dirname(ledgerPath), 'mail-outbox');
}

function emptyMailbox() {
  return {
    protocol: MAILBOX_PROTOCOL,
    being_id: '',
    being_name: '',
    synced_at: null,
    received: [],
    sent: [],
    outbox_watermark: {},
    receipts: [],
  };
}

/** 邮箱也住 iCloud，同样会被逐出成占位符（EAGAIN）——复用账本那套自动拉取。 */
function readMailbox(file = mailboxPath()) {
  if (!fs.existsSync(file)) return emptyMailbox();
  let raw;
  try {
    raw = fs.readFileSync(file, 'utf8');
  } catch (error) {
    if (!store.isDataless(error)) throw error;
    if (!store.materialize(file)) {
      throw new MailError(
        `邮箱还在 iCloud 云端没落地（EAGAIN），自动拉取也没成功：${file}\n` +
        `手动强拉一次：brctl download "${file}"`
      );
    }
    raw = fs.readFileSync(file, 'utf8');
  }
  const value = JSON.parse(raw);
  if (value.protocol !== MAILBOX_PROTOCOL) {
    throw new MailError(`邮箱协议不认识：${value.protocol}`);
  }
  return { ...emptyMailbox(), ...value };
}

/** 原子写：临时文件 + rename。只在锁内调用。 */
function writeMailboxUnlocked(value, file = mailboxPath()) {
  const next = { ...value, protocol: MAILBOX_PROTOCOL };
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = file + '.tmp-' + process.pid;
  fs.writeFileSync(tmp, JSON.stringify(next, null, 2) + '\n', 'utf8');
  fs.renameSync(tmp, file);
  return next;
}

/**
 * 规矩 1 照抄：读—改—写全程持锁。being 是唯一写者，但心跳跑重了会有两个它，
 * 锁挡的是这个，不是别的设备。
 */
function withMailboxLock(mutate, { file = mailboxPath(), purpose = '' } = {}) {
  const handle = store.acquireLock(file, { purpose });
  try {
    const current = readMailbox(file);
    const next = mutate(current);
    if (next === undefined) return current;
    return writeMailboxUnlocked(next, file);
  } finally {
    store.releaseLock(handle);
  }
}

// ── 设备草稿箱（只读，being 不许改别人的文件） ────────────────────────────────

function loadOutboxes(ledgerPath = paths.LEDGER) {
  const dir = outboxDir(ledgerPath);
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir)
    .filter((name) => name.endsWith('.json'))
    .map((name) => {
      const file = path.join(dir, name);
      try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
      catch (error) {
        // 手机写的草稿箱也住 iCloud，也会被逐出成占位符。不拉一下就读，
        // 表现是「人类明明写了信，being 这边一封待发都没有」——最坏的那种沉默失败。
        if (!store.isDataless(error) || !store.materialize(file)) return null;
        try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
      }
    })
    .filter((box) => box && box.protocol === OUTBOX_PROTOCOL);
}

/**
 * 纯函数：还没处理过的草稿。判据是「水位以上 **且** 还没有回执」——
 * 光看水位不够：回执写了但水位因为前面有空档没推上去时，重跑会把同一封再发一遍。
 */
function pending(mailbox, outboxes) {
  const receipted = new Set((mailbox.receipts || []).map((r) => r.draft_id));
  const out = [];
  for (const box of outboxes) {
    const mark = (mailbox.outbox_watermark || {})[box.device_id] || 0;
    for (const draft of (box.drafts || []).slice().sort((a, b) => a.seq - b.seq)) {
      if (draft.seq <= mark) continue;
      if (receipted.has(draft.id)) continue;
      out.push({
        device_id: box.device_id,
        device_name: box.device_name || '',
        seq: draft.seq,
        id: draft.id,
        recipient: draft.recipient,
        content: draft.content,
        created_at: draft.created_at,
      });
    }
  }
  return out.sort((a, b) => String(a.created_at).localeCompare(String(b.created_at)));
}

/**
 * 连续已回执的最大 seq。跳着处理时中间那封没回执，水位就停在它前面——
 * 设备不会把它剪掉，下一轮 pending 还会把它交出来。
 */
function contiguousWatermark(outbox, receiptIDs, current) {
  let mark = current;
  for (const draft of (outbox.drafts || []).slice().sort((a, b) => a.seq - b.seq)) {
    if (draft.seq <= mark) continue;
    if (!receiptIDs.has(draft.id)) break;
    mark = draft.seq;
  }
  return mark;
}

/** 纯函数：写一条回执，顺带把那台设备的水位推到「连续已回执」为止。 */
function applyReceipt(mailbox, outboxes, receipt) {
  const owner = outboxes.find((box) => (box.drafts || []).some((d) => d.id === receipt.draft_id));
  if (!owner) throw new MailError(`草稿箱里没有 ${receipt.draft_id}——是不是已经发过、被剪掉了？`);

  const receipts = (mailbox.receipts || []).filter((r) => r.draft_id !== receipt.draft_id);
  receipts.push(receipt);

  const ids = new Set(receipts.map((r) => r.draft_id));
  const watermark = { ...(mailbox.outbox_watermark || {}) };
  watermark[owner.device_id] = contiguousWatermark(
    owner, ids, watermark[owner.device_id] || 0
  );

  // 剪回执：草稿还在设备上的那些一律留着（界面靠它显示结果），其余留最近的。
  const live = new Set(outboxes.flatMap((box) => (box.drafts || []).map((d) => d.id)));
  const kept = receipts.filter((r) => live.has(r.draft_id));
  const rest = receipts.filter((r) => !live.has(r.draft_id))
    .sort((a, b) => String(a.at).localeCompare(String(b.at)))
    .slice(-RECEIPT_CAP);

  return { ...mailbox, receipts: [...rest, ...kept], outbox_watermark: watermark };
}

/** Town 的返回可能是 `{count, messages}`，也可能有人直接把数组喂进来。两种都收。 */
function messagesOf(payload) {
  if (!payload) return [];
  if (Array.isArray(payload)) return payload;
  if (Array.isArray(payload.messages)) return payload.messages;
  throw new MailError('认不出这份 Town 返回：要 {count, messages} 或者一个数组');
}

/** 字段照抄 Town，不翻译。多余的字段留着——邮局以后加什么，界面原样带得走。 */
function normalize(message) {
  if (!message || typeof message.id === 'undefined') {
    throw new MailError('一封信没有 id，不敢往镜像里放');
  }
  return {
    ...message,
    id: String(message.id),
    sender: String(message.sender || ''),
    recipient: String(message.recipient || ''),
    content: String(message.content || ''),
    created_at: String(message.created_at || ''),
  };
}

function newestFirstCap(messages) {
  return messages
    .slice()
    .sort((a, b) => String(a.created_at).localeCompare(String(b.created_at)))
    .slice(-MESSAGE_CAP);
}

/**
 * 纯函数：把 being 刚从 Town 取回来的收发件箱灌进镜像。
 *
 * `received` / `sent` 缺哪个就不动哪个——being 可能只取了一半（另一半失败了），
 * 这时候把没取到的那半当成「空」写进去，界面上会表现成「信全没了」。
 */
function applySync(mailbox, { received, sent, beingID, beingName, at } = {}) {
  const next = { ...mailbox };
  if (received !== undefined) next.received = newestFirstCap(messagesOf(received).map(normalize));
  if (sent !== undefined) next.sent = newestFirstCap(messagesOf(sent).map(normalize));
  if (beingID) next.being_id = String(beingID);
  if (beingName) next.being_name = String(beingName);
  next.synced_at = at || new Date().toISOString();
  return next;
}

module.exports = {
  MAILBOX_PROTOCOL,
  OUTBOX_PROTOCOL,
  MESSAGE_CAP,
  RECEIPT_CAP,
  MailError,
  mailboxPath,
  outboxDir,
  emptyMailbox,
  readMailbox,
  writeMailboxUnlocked,
  withMailboxLock,
  loadOutboxes,
  pending,
  contiguousWatermark,
  applyReceipt,
  applySync,
  messagesOf,
};
