'use strict';
// Kairos v2.3 · 账本与派生文件的路径（Node 侧）
//
// 依据：单机为默认，iCloud 可选（BEING-RULES 手册）。
//   账本还是那一个 json 文件、还是没有第二份副本——只是**位置可选**了：单机时在
//   ~/.kairos/，关联 iCloud 时在那个共享文件夹里。Node 侧（本文件）与 Swift 侧
//   （KairosLedgerLocation）按同一顺序解析同一个指针文件，任何一侧改顺序都要两边一起改。
//   派生文件（心跳快照 / 房间日志 / 已读游标 / outbox）留在本机 ~/.kairos/，
//   不进 iCloud——它们是本机状态，跨设备飘过去只会互相打架。
//   锁文件同理，且理由更硬：iCloud 跨设备同步时文件锁语义失效，一把从别的设备
//   飘过来的陈旧 .lock 只会白白挡住本机唯一的写入者。

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');

const HOME = os.homedir();

/**
 * 账本：唯一真源。**位置从 v2.4 起是可选的**。
 *
 * 以前这里写死成 iCloud 里那个文件；现在 Kairos 允许「单机」和「关联 iCloud」两种形态，
 * 所以两侧改成按同一个顺序解析同一个指针文件：
 *
 *   1. `KAIROS_LEDGER`（只为测试和演练；正常运行一律不设）
 *   2. `~/.kairos/ledger-location.json` 里的 `folder` → 该文件夹下的账本
 *   3. 没有指针，但老的 iCloud 位置上真有一份账本 → 用它（升级路径，别让人一夜之间空了）
 *   4. 都没有 → `~/.kairos/projection-snapshot.json`（单机）
 *
 * **Swift 侧 `KairosLedgerLocation.resolveFolder` 是同一顺序，改一处必须改两处。**
 * 两侧解析出不同的文件 = v2.3 §五要消灭的「两份副本」，而且是静默的。
 */
const LEDGER_FILE = 'projection-snapshot.json';

/** v2.3 那个写死的位置。留着只为第 3 条兜底。 */
const DEFAULT_LEDGER = path.join(
  HOME,
  'Library/Mobile Documents/com~apple~CloudDocs/Kairos',
  LEDGER_FILE
);

/** 纯函数，好验：给定四个输入，账本就在哪儿。文件系统的事留给调用方。 */
function resolveLedgerFrom({ env, pointerFolder, cloudLedgerExists, home = HOME }) {
  if (env) return env;
  if (pointerFolder) return path.join(pointerFolder, LEDGER_FILE);
  if (cloudLedgerExists) {
    return path.join(home, 'Library/Mobile Documents/com~apple~CloudDocs/Kairos', LEDGER_FILE);
  }
  return path.join(home, '.kairos', LEDGER_FILE);
}

/** 指针文件里的 folder；没有 / 读不出来 / 空的都回 null。 */
function readPointerFolder() {
  try {
    const raw = fs.readFileSync(path.join(HOME, '.kairos', 'ledger-location.json'), 'utf8');
    const folder = JSON.parse(raw).folder;
    return typeof folder === 'string' && folder ? folder : null;
  } catch {
    return null;
  }
}

function resolveLedger() {
  return resolveLedgerFrom({
    env: process.env.KAIROS_LEDGER,
    pointerFolder: readPointerFolder(),
    cloudLedgerExists: fs.existsSync(DEFAULT_LEDGER),
  });
}

/** 派生文件的家。永远本机，永远不进 iCloud。 */
const LOCAL_DIR = path.join(HOME, '.kairos');
const LOCKS_DIR = path.join(LOCAL_DIR, 'locks');

/** 心跳快照（规则 3）：being 心跳的内存态落盘处，崩了从这儿接上。 */
const HEARTBEAT_SNAPSHOT = path.join(LOCAL_DIR, 'heartbeat-snapshot.json');

/**
 * 目标文件 → 锁文件的确定性映射。
 *
 * 算法（Swift 侧 KairosFiles.lockURL 逐字对齐，改一处必须改两处）：
 *   1. 目标路径取绝对路径，不做符号链接解析、不做大小写折叠；
 *   2. 对该路径的 UTF-8 字节算 SHA-256；
 *   3. 取小写 hex，加 `.lock` 后缀，落在 ~/.kairos/locks/ 下。
 *
 * 为什么是哈希而不是「同目录 + .lock」：账本在 iCloud，锁不能跟去（见文件头）。
 * 为什么不带可读前缀：可读性零收益，而任何「顺手加个前缀」的改动都会让两侧算出
 * 不同的锁名——那等于没有锁，且不报错。宁可难看。
 */
function lockPathFor(targetPath) {
  const absolute = path.resolve(targetPath);
  const digest = crypto.createHash('sha256').update(absolute, 'utf8').digest('hex');
  return path.join(LOCKS_DIR, digest + '.lock');
}

module.exports = {
  HOME,
  DEFAULT_LEDGER,
  LEDGER_FILE,
  LOCAL_DIR,
  LOCKS_DIR,
  HEARTBEAT_SNAPSHOT,
  lockPathFor,
  resolveLedger,
  resolveLedgerFrom,
};

/**
 * `paths.LEDGER` 每次取值都重新解析。
 *
 * 不能在 require 时算死：`store.js` / `mail.js` 那些 `ledgerPath = paths.LEDGER` 是
 * **默认参数**，每次调用都会读一次这个属性——人在 Kairos 里换了账本位置之后，
 * 同一个长跑进程里的下一次读写就该落到新位置，而不是等重启。
 */
Object.defineProperty(module.exports, 'LEDGER', {
  enumerable: true,
  get: resolveLedger,
});
