'use strict';
// Kairos v2.5 · 账本读写（Node 侧 / being 用）
//
// 五句规矩（BEING-RULES「账本」节）里，账本侧这四句由本文件负责：
//   规矩 1 锁全程   → withLedgerLock：读—改—写整个事务在锁内，写完即放
//   规矩 2 手动改不被覆盖 → beingWrite 跳过 last_writer=human 的字段
//   规矩 4 先文件后消息 → commitThenNotify：先落盘，成功后才发消息，发失败不回滚
//   规矩 3 快照落盘   → 心跳自己的事，路径在 paths.HEARTBEAT_SNAPSHOT
//
// 关于「flock」：v2.3 原文说的是 flock。Node 不带 flock(2) 绑定（要么上原生扩展，
// 要么 shell 出去，macOS 又没有 util-linux 的 flock 命令），而 Swift 侧能直接调
// flock(2)——两侧用不同原语锁同一个文件，等于没锁，且不报错。所以两侧统一改用
// 「O_CREAT|O_EXCL 独占创建 + 持有者存活检测」这一种都能逐字实现的建议锁。
// 互斥语义与 flock 相同；差别只在崩溃后需要 stale 判定，见 acquireLock。

const fs = require('fs');
const os = require('os');
const { execFileSync } = require('child_process');
const path = require('path');
const paths = require('./paths.js');

/** 业务字段。Swift 侧 KairosField.business 必须逐字相同（规矩 2 按字段比对，名字对不上就等于没保护）。
 *
 *  已撤掉四个（协议 /3，迁移见 migrateToMergedStatus）：
 *    state   球权是临时状态，并进 `status`。UI 早就不拿它分段了（KairosWorkspace 那句
 *            「球权是临时状态、不拿来分段」），能写 being 的只有 being 和消息行推导、没有一颗按钮，
 *            它剩下的活只有「完没完」——那本来就是 status 该说的。
 *    next    26/105 写过，两端没有一块屏幕念过。拍板前它是猜的，拍板后由点的那个 option 决定。
 *    scores  排序里真读它（reach+impact+urgency），但没有任何写入方——那六行一直在比 0 > 0。
 *    links   规矩指派它链另一行待办，类型却是 {label,url}（一个网址），对不上，也没有 UI。
 */
const BUSINESS_FIELDS = [
  'title', 'summary', 'brief', 'reason', 'ask',
  'options', 'tier', 'status', 'project', 'source', 'excerpt', 'evidence',
  // 2026-09-11：消息那三样。
  //   counterpart  对方 { name, id, channel, kind }。**有对方 = 这一行是消息**（欠人一个回复），
  //                没有 = 待办（欠自己一个动作）。它同时决定归哪段、房间怎么显示、回给谁。
  //                注意和 source 是两个维度：篝火里一条「周五 API 要改」没人等你回，那是待办。
  //   （拟好的回复那一项下架了：**回复是选项不是拟稿**——being 列几个判断写进本来就有的
  //     `options`，人类点一个。一百个人的量上，扫三个选项点一个，比读一段稿再改两个字
  //     快一个数量级。）
  //   thread       往来 [{ who, at, text }]。炉火像小群、篝火是帖子底下的串，
  //                上下文按「谁说的」切开，别塞成一段长 excerpt。
  'counterpart', 'thread',
];

/** 对方的种类。一个人 / 一个群（炉火）/ 一条帖子（篝火里 @ 你的那条）。 */
const COUNTERPART_KINDS = ['person', 'group', 'post'];

/** 对方长得对不对。**不合格就整个字段作废**（和值集同一条规矩：作废那一个字段，不牵连整条）。
 *  name 是行上的索引，id 是回信的真地址——只有名字没有地址仍然算消息（看得见谁在等你），
 *  只是回不了信，界面上会说清楚，不装作能回。 */
function isValidCounterpart(value) {
  if (value === null) return true; // 显式清空：这一行从消息变回待办
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  if (typeof value.name !== 'string' || typeof value.id !== 'string') return false;
  if (!value.name && !value.id) return false;
  if (typeof value.channel !== 'string' || !isValidSource(value.channel)) return false;
  if (value.kind !== undefined && !COUNTERPART_KINDS.includes(value.kind)) return false;
  return true;
}

/** 往来长得对不对：一个数组，每格 { who, at, text } 都是字符串。 */
function isValidThread(value) {
  if (!Array.isArray(value)) return false;
  return value.every(
    (said) =>
      said && typeof said === 'object' && !Array.isArray(said) &&
      typeof said.who === 'string' && typeof said.text === 'string' &&
      (said.at === undefined || typeof said.at === 'string')
  );
}

/** 选项长得对不对：一个数组，每格 `{ label, detail }`，label 不能是空的、detail 可选。
 *  **这一条以前没有，是个真坑**：v2.4 把 `options` 提成回复机制之后，CLI 只做 JSON.parse，
 *  写一句 `options='["能","周一"]'`（裸字符串数组）也照收。而 Swift 侧 `items` 不是 lossy 解码
 *  （`decodeIfPresent([KairosItem].self)`），一格格式不对，整本账全解不开——不是作废那一个字段，
 *  是整个快照。和 counterpart / thread 同一条规矩：不合格就整个字段作废，不牵连整条。 */
function isValidOptions(value) {
  if (!Array.isArray(value)) return false;
  return value.every(
    (option) =>
      option && typeof option === 'object' && !Array.isArray(option) &&
      typeof option.label === 'string' && option.label.trim().length > 0 &&
      (option.detail === undefined || typeof option.detail === 'string')
  );
}

/** 真源链接（`evidence`）长得对不对：数组，每格 `{ label, url }`，url 不能空。
 *  **这一条以前也没有**：CLI 把 evidence 当结构化字段只做 JSON.parse，
 *  写 `evidence='[{"label":"x"}]'` 照收，而 Swift 侧 `KairosLink` 当时要求 url 必填——
 *  和 options 一模一样的坑，同一天一起堵上（Swift 那边也改成了缺字段作废这一格）。 */
function isValidEvidence(value) {
  if (!Array.isArray(value)) return false;
  return value.every(
    (link) =>
      link && typeof link === 'object' && !Array.isArray(link) &&
      typeof link.url === 'string' && link.url.trim().length > 0 &&
      (link.label === undefined || typeof link.label === 'string')
  );
}

/** 渠道：todo = 账本直接建的，其余是 Town 的渠道。 */
const SOURCES = ['todo', 'inbox', 'bonfire', 'fireside'];

/** 只有炉火能带名字：`fireside:炉火名`。
 *  炉火有很多个，得说清是哪一个；篝火是全局的、只有一个，和待办、邮局一样裸写。 */
const NAMED_SOURCES = ['fireside'];

/** 渠道类型，冒号后面的名字不算：`fireside:演示炉火` → `fireside`。
 *  认不出的原样返回——判不判违法是 isValidSource 的事，这里不替它决定。 */
function sourceChannel(raw) {
  const text = String(raw);
  const at = text.indexOf(':');
  return at < 0 ? text : text.slice(0, at);
}

/** 裸渠道随便哪个都行；带冒号的只有篝火和炉火能带，且名字不能是空的。 */
function isValidSource(raw) {
  const text = String(raw);
  const at = text.indexOf(':');
  if (at < 0) return SOURCES.includes(text);
  return NAMED_SOURCES.includes(text.slice(0, at)) && text.slice(at + 1).trim().length > 0;
}

/** 第二维度：走到哪了。
 *  「已完结」也是这里的一个值——球权那个字段撤了，完没完归它说。
 *  顺序即分组顺序：进行中 / 未开始 / 待定，已完结是抽屉，不和前三个并排。 */
const STATUSES = ['todo', 'doing', 'pending', 'closed'];
const CLOSED = 'closed';

/** 性质（契约 §三）。顺序即排序次级键：同档位内按这个先后排，见 KairosStore.compare。 */

/** 档位（契约 §三）。顺序即高低，P0 是例外里的例外。
 *  和 status/source 不同，展示层对不认识的档位没有 normalized 兜底以外的补救：
 *  排序里 firstIndex 落空就排到 P3 之后——写错一个字，要紧的那条沉到底。 */
const TIERS = ['P0', 'P1', 'P2', 'P3'];

const HUMAN = 'human';
const BEING = 'being';

/** 当前协议。Swift 侧 KairosSnapshot.protocolV3 必须是同一个字符串。 */
const PROTOCOL = 'kairos.local/3';
const KNOWN_PROTOCOLS = ['kairos.local/1', 'kairos.local/2', PROTOCOL];

/** iOS 合并列表那个顺序桶。不是状态，只是一个存「用户拖出来的顺序」的键。 */
const ACTIVE_ORDER_KEY = 'active';

/**
 * 球权 → 状态。null = 状态原样留着（球在人类手上不说明这件事走到哪了）。
 * /1 的五态也在表里：它们先按老映射折成三态（inbox/doing→being，todo/decide→mine），
 * 折完再并，所以两步可以合成这一张表，不必先跑一遍 /1→/2。
 */
const STATE_TO_STATUS = {
  closed: CLOSED,
  being: 'doing',   // being 在办 = 进行中
  inbox: 'doing',   // /1 词汇：inbox → being
  doing: 'doing',   // /1 词汇：doing → being
  mine: null,
  todo: null,       // /1 词汇：todo → mine
  decide: null,     // /1 词汇：decide → mine
};

const LOCK_TIMEOUT_MS = 10_000;
const LOCK_STALE_MS = 30_000;
const LOCK_RETRY_MS = 50;

class LedgerError extends Error {}
class LedgerCASError extends LedgerError {}

// ── 规矩 1：锁 ────────────────────────────────────────────────────────────

function lockHolderAlive(holder) {
  if (!holder || typeof holder.pid !== 'number') return false;
  if (holder.host !== os.hostname()) return true; // 别的机器的进程，本机判不了死活，当活的
  try {
    process.kill(holder.pid, 0);
    return true;
  } catch (error) {
    return error.code === 'EPERM'; // EPERM = 活着但不是我的；ESRCH = 死了
  }
}

function readHolder(lockPath) {
  try {
    return JSON.parse(fs.readFileSync(lockPath, 'utf8'));
  } catch {
    return null; // 读不出来（写到一半 / 空文件）就交给 stale 判定
  }
}

function acquireLock(targetPath, { timeoutMs = LOCK_TIMEOUT_MS, purpose = '' } = {}) {
  const lockPath = paths.lockPathFor(targetPath);
  fs.mkdirSync(path.dirname(lockPath), { recursive: true });
  const token = {
    pid: process.pid,
    host: os.hostname(),
    acquiredAt: new Date().toISOString(),
    purpose,
  };
  const payload = JSON.stringify(token);
  const deadline = Date.now() + timeoutMs;

  for (;;) {
    try {
      const fd = fs.openSync(lockPath, 'wx');
      fs.writeSync(fd, payload);
      fs.closeSync(fd);
      return { lockPath, token };
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
    }

    const holder = readHolder(lockPath);
    let age = Infinity;
    try {
      age = Date.now() - fs.statSync(lockPath).mtimeMs;
    } catch {
      continue; // 刚被别人释放，立刻重试
    }
    // 持有者死了、或锁太旧（崩溃残留）→ 掰断重来。这是 flock 不需要而建议锁必须有的一步。
    if (!lockHolderAlive(holder) || age > LOCK_STALE_MS) {
      try { fs.unlinkSync(lockPath); } catch { /* 已被别人清掉 */ }
      continue;
    }
    if (Date.now() > deadline) {
      throw new LedgerError(
        `拿不到账本锁（${lockPath} 被 pid ${holder && holder.pid} 持有，已 ${Math.round(age / 1000)}s）`
      );
    }
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, LOCK_RETRY_MS);
  }
}

function releaseLock(handle) {
  if (!handle) return;
  const holder = readHolder(handle.lockPath);
  // 只放自己的锁。锁被掰断后又被别人拿走时，这里不该把别人的锁删掉。
  if (holder && holder.pid !== handle.token.pid) return;
  try { fs.unlinkSync(handle.lockPath); } catch { /* 已经没了 */ }
}

// ── 读写 ─────────────────────────────────────────────────────────────────

/**
 * 账本住在 iCloud，系统会把不常用的文件逐出成占位符（dataless）。这时
 * `existsSync` 仍然为真，`readFileSync` 却抛 EAGAIN(-11)——2026-09-07 being 第一次
 * 跑 doctor 就撞上了。让 CLI 自己把文件拉回来，别指望每次都记得手动 brctl。
 */
/**
 * iCloud 占位符读不出来时的错误长什么样：Linux 风格是 code='EAGAIN'，
 * 但 macOS 上 Node 把它报成 code='Unknown system error -11'、errno=-11（being 2026-09-07
 * 在 drain 路径撞到）。三种写法都认，别再靠一个字符串。
 */
function isDataless(error) {
  if (!error) return false;
  if (error.code === 'EAGAIN' || error.errno === -11) return true;
  return /system error -11\b/.test(String(error.message || error.code || ''));
}

function materialize(ledgerPath) {
  for (let attempt = 0; attempt < 6; attempt++) {
    try {
      execFileSync('brctl', ['download', ledgerPath], { stdio: 'ignore', timeout: 30_000 });
    } catch {
      // 不是 iCloud 文件，或者 brctl 用不了——交给下面的读去报真正的错。
    }
    try {
      fs.readFileSync(ledgerPath, 'utf8');
      return true;
    } catch (error) {
      if (!isDataless(error)) return false;
    }
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 500);
  }
  return false;
}

/**
 * 一本空账。**「还没有账本」不是错误**——v2.4 起「单机」是默认形态，
 * 一台刚装好的机器上本来就还没有这个文件（Swift 侧 `loadSnapshot` 也是这么做的：
 * 文件不在就落一份空的下去）。以前这里直接把 ENOENT 抛出去，于是 `doctor`
 * 在全新单机上是一屏 node 堆栈。
 */
function emptyLedger() {
  return {
    protocol: PROTOCOL,
    updated_at: new Date().toISOString(),
    being: { name: '' },
    sync: { last_sync_at: null, outbox_watermark: {} },
    items: [],
    tombstones: [],
    conflicts: [],
    workspace: { projects: [], manualOrder: {}, sidebarOrder: [] },
    seeds: [],
  };
}

function readLedger(ledgerPath = paths.LEDGER) {
  let raw;
  try {
    raw = fs.readFileSync(ledgerPath, 'utf8');
  } catch (error) {
    // 文件不存在 = 还没建过账本，不是坏了。**和 dataless 分得清清楚楚**：
    // 那个是「文件在、内容还在云上」，得等；这个是「本来就没有」，给一本空的。
    if (error && error.code === 'ENOENT') return emptyLedger();
    if (!isDataless(error)) throw error;
    if (!materialize(ledgerPath)) {
      throw new LedgerError(
        `账本还在 iCloud 云端没落地（EAGAIN），自动拉取也没成功：${ledgerPath}\n` +
        `手动强拉一次：brctl download "${ledgerPath}"`
      );
    }
    raw = fs.readFileSync(ledgerPath, 'utf8');
  }
  const value = JSON.parse(raw);
  if (!KNOWN_PROTOCOLS.includes(value.protocol)) {
    throw new LedgerError(`账本协议不认识：${value.protocol}`);
  }
  return migrateToMergedStatus(value);
}

/**
 * /1、/2 → /3 就地迁移：球权并进状态，撤掉 next / scores / links。
 *
 * **和 /1→/2 同性质，是词汇迁移不是业务编辑**：不改任何 rev、不生成 tombstone、
 * 不碰 updated_at（契约 §十一）。谁先打开账本谁迁，两侧算出来必须是同一个结果——
 * Swift 侧 `KairosSnapshot.migratedToMergedStatus()` 逐条对齐，改一处必须改两处。
 *
 * 幂等：已经是 /3 的原样返回。
 */
function migrateToMergedStatus(ledger) {
  if (ledger.protocol === PROTOCOL) return ledger;
  const next = {
    ...ledger,
    protocol: PROTOCOL,
    items: (ledger.items || []).map(mergedStatusItem),
  };
  if (Array.isArray(ledger.conflicts)) {
    next.conflicts = ledger.conflicts.map((conflict) => ({
      ...conflict,
      local: conflict.local ? mergedStatusItem(conflict.local) : conflict.local,
      remote: conflict.remote ? mergedStatusItem(conflict.remote) : conflict.remote,
    }));
  }
  // 泳道没了（KairosLane 那三条），挂在泳道上的手工顺序也就没有东西可挂。
  // 合并列表那个桶（`active`）是唯一还活着的，留着——它本来就不是球权状态。
  const manualOrder = ledger.workspace && ledger.workspace.manualOrder;
  if (manualOrder) {
    next.workspace = {
      ...ledger.workspace,
      manualOrder: Object.fromEntries(
        Object.entries(manualOrder).filter(([key]) => {
          const at = key.indexOf('/');
          return at >= 0 && key.slice(at + 1) === ACTIVE_ORDER_KEY;
        })
      ),
    };
  }
  return next;
}

/** 一条的迁移。item、conflict 里的 payload、设备 outbox 里那一条，同一个形状，共用这一个。 */
function mergedStatusItem(item) {
  if (!item || typeof item !== 'object') return item;
  const { state, next: _next, scores: _scores, links: _links, ...rest } = item;
  const mapped = state === undefined ? undefined : STATE_TO_STATUS[state];
  // mapped 为 null（球在人类手上）或认不出的球权 → 状态原样留着，认不出的状态落 todo。
  const result = {
    ...rest,
    status: mapped || (STATUSES.includes(rest.status) ? rest.status : 'todo'),
  };
  if (rest.lastWriter) {
    const lastWriter = { ...rest.lastWriter };
    // 人锁过球权的，锁跟着搬到 status——他锁的是「这条完没完我说了算」，
    // 字段换了名字不该把这个决定弄丢。status 自己已经锁着就不动它。
    if (lastWriter.state && !lastWriter.status) lastWriter.status = lastWriter.state;
    delete lastWriter.state;
    delete lastWriter.next;
    delete lastWriter.scores;
    delete lastWriter.links;
    result.lastWriter = lastWriter;
  }
  return result;
}

/** 原子写：临时文件 + rename。只在锁内调用。 */
function writeLedgerUnlocked(value, ledgerPath = paths.LEDGER) {
  const next = { ...value, protocol: PROTOCOL, updated_at: new Date().toISOString() };
  const text = JSON.stringify(next, null, 2) + '\n';
  const tmp = ledgerPath + '.tmp-' + process.pid;
  fs.mkdirSync(path.dirname(ledgerPath), { recursive: true });
  fs.writeFileSync(tmp, text, 'utf8');
  fs.renameSync(tmp, ledgerPath);
  return next;
}

/**
 * 规矩 1：读—改—写全程持锁。
 * `mutate(ledger)` 拿到的是**锁内刚读的**账本，不是调用方手上那份旧的；
 * 返回 undefined 表示不写（只读事务）。
 */
function withLedgerLock(mutate, { ledgerPath = paths.LEDGER, purpose = '' } = {}) {
  const handle = acquireLock(ledgerPath, { purpose });
  try {
    const current = readLedger(ledgerPath);
    const next = mutate(current);
    if (next === undefined) return current;
    return writeLedgerUnlocked(next, ledgerPath);
  } finally {
    releaseLock(handle);
  }
}

// ── 规矩 2：字段级 last_writer ────────────────────────────────────────────

function findItem(ledger, id) {
  const index = (ledger.items || []).findIndex((item) => item.id === id);
  if (index < 0) throw new LedgerError(`账本里没有 ${id}`);
  return index;
}

function stampedFields(before, after) {
  return BUSINESS_FIELDS.filter(
    (field) => field in after && JSON.stringify(before[field]) !== JSON.stringify(after[field])
  );
}

/**
 * 新建。**不盖戳**（v2.3 §五）：用户建待办时选的状态/优先级只是初值，
 * being 例行推进（改状态、排序）可以覆盖。
 */
function createTodo(ledger, fields) {
  const now = new Date().toISOString();
  const item = {
    id: fields.id || require('crypto').randomUUID(),
    localRev: 1,
    syncedLocalRev: 0,
    beingRev: 0,
    remoteKnown: false,
    title: '',
    summary: '',
    brief: '',
    reason: '',
    ask: '',
    options: [],
    tier: 'P3',
    status: 'todo',
    project: '',
    source: 'todo',
    excerpt: '',
    evidence: [],
    ...fields,
    updated_at: now,
    lastWriter: {}, // ← 初值不盖戳，这一行就是 v2.3 §五那条边界
  };
  return { ...ledger, items: [...(ledger.items || []), item] };
}

/**
 * 重排单子。**顺序就是 items 数组的顺序**，界面从上往下画——
 * 没有 rank 字段，也不该有：轻重只用一种东西表达，多一个字段就多一处要对齐。
 *
 * 给出的 id 按给定次序挪到最前，没点到的保持原相对次序跟在后面。
 * **不动 localRev / beingRev / updated_at**：重排不是业务编辑，不该让每条都 +1
 * 去挤冲突，也不该因为 being 排了一次序就把整本账标成「刚改过」。
 */
function reorder(ledger, ids) {
  const items = ledger.items || [];
  const byId = new Map(items.map((item) => [item.id, item]));
  const picked = [];
  const seen = new Set();
  for (const id of ids) {
    const item = byId.get(id);
    if (!item || seen.has(id)) continue;
    seen.add(id);
    picked.push(item);
  }
  const rest = items.filter((item) => !seen.has(item.id));
  return { ...ledger, items: [...picked, ...rest] };
}

/**
 * 人类显式修改。**只给真正变了的字段盖 human 戳**——没变的字段不该被顺手锁住，
 * 否则打开编辑器点一下保存就把整条待办对 being 冻死了。
 */
function humanEdit(ledger, id, patch, { expectedRev } = {}) {
  const items = [...ledger.items];
  const index = findItem(ledger, id);
  const before = items[index];
  if (expectedRev !== undefined && before.localRev !== expectedRev) {
    throw new LedgerCASError(`${id} 版本不符：账本 localRev=${before.localRev}，写入方以为 ${expectedRev}`);
  }
  const changed = stampedFields(before, patch);
  if (changed.length === 0) return undefined;

  const lastWriter = { ...(before.lastWriter || {}) };
  for (const field of changed) lastWriter[field] = HUMAN;

  items[index] = {
    ...before,
    ...pick(patch, changed),
    lastWriter,
    localRev: before.localRev + 1,
    updated_at: new Date().toISOString(),
  };
  return { ...ledger, items };
}

/**
 * being 写入（心跳 / 判断面）。规矩 2 的执行点：
 * last_writer=human 的字段直接跳过，不改、不报错——「自动同步」永远没有资格
 * 替人撤销人刚做的决定。跳过了哪些字段会回报给调用方，方便心跳记一笔。
 */
function beingWrite(ledger, id, patch, { expectedBeingRev } = {}) {
  const items = [...ledger.items];
  const index = findItem(ledger, id);
  const before = items[index];
  if (expectedBeingRev !== undefined && before.beingRev !== expectedBeingRev) {
    throw new LedgerCASError(`${id} 版本不符：账本 beingRev=${before.beingRev}，写入方以为 ${expectedBeingRev}`);
  }
  const lastWriter = { ...(before.lastWriter || {}) };
  const wanted = stampedFields(before, patch);
  const skipped = wanted.filter((field) => lastWriter[field] === HUMAN);
  const allowed = wanted.filter((field) => lastWriter[field] !== HUMAN);
  if (allowed.length === 0) return { ledger: undefined, skipped, written: [] };

  for (const field of allowed) lastWriter[field] = BEING;
  items[index] = {
    ...before,
    ...pick(patch, allowed),
    lastWriter,
    beingRev: before.beingRev + 1,
    updated_at: new Date().toISOString(),
  };
  return { ledger: { ...ledger, items }, skipped, written: allowed };
}

/**
 * 新的用户信号（在该待办的房间里说了话 / 下了指令）→ 解开人类锁。
 * v2.3 规矩 2 的后半句：「心跳写人改过的字段需要新的用户信号作依据」——
 * 这就是那个依据落地的地方，being 从此刻起可以重新覆盖。
 */
function releaseHumanLocks(ledger, id) {
  const items = [...ledger.items];
  const index = findItem(ledger, id);
  if (Object.keys(items[index].lastWriter || {}).length === 0) return undefined;
  items[index] = { ...items[index], lastWriter: {} };
  return { ...ledger, items };
}

// ── 规矩 4：先文件后消息 ──────────────────────────────────────────────────

/**
 * 固定顺序：先写账本，成功后才发消息；消息发失败**不回滚文件**——
 * 消息只是信号，下一轮心跳 diff 自愈会补上。反过来（先说话再补写）
 * 就是 v1 状态漂移的源头。
 */
async function commitThenNotify(mutate, notify, options = {}) {
  const ledger = withLedgerLock(mutate, options);
  try {
    await notify(ledger);
    return { ledger, notified: true, notifyError: null };
  } catch (error) {
    return { ledger, notified: false, notifyError: error };
  }
}

function pick(source, fields) {
  const result = {};
  for (const field of fields) result[field] = source[field];
  return result;
}

module.exports = {
  reorder,
  BUSINESS_FIELDS,
  STATUSES,
  CLOSED,
  PROTOCOL,
  ACTIVE_ORDER_KEY,
  migrateToMergedStatus,
  migrateItemToMergedStatus: mergedStatusItem,
  COUNTERPART_KINDS,
  isValidCounterpart,
  isValidThread,
  isValidOptions,
  isValidEvidence,
  SOURCES,
  NAMED_SOURCES,
  sourceChannel,
  isValidSource,
  TIERS,
  materialize,
  isDataless,
  HUMAN,
  BEING,
  LedgerError,
  LedgerCASError,
  acquireLock,
  releaseLock,
  readLedger,
  emptyLedger,
  withLedgerLock,
  createTodo,
  humanEdit,
  beingWrite,
  releaseHumanLocks,
  commitThenNotify,
};
