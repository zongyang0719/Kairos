'use strict';
// Kairos v2.3 · 账本侧五句规矩的测试（Node）
// 对应 BEING-RULES「账本」节。

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const paths = require('../ledger/paths.js');
const store = require('../ledger/store.js');

/** 落一本临时账本。协议号可改——迁移那几条要拿 /1、/2 的真形状喂进来。 */
function tempLedger(items = [], protocol = 'kairos.local/3', workspace = null) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kairos-ledger-'));
  const file = path.join(dir, 'projection-snapshot.json');
  fs.writeFileSync(file, JSON.stringify({
    protocol,
    updated_at: '2026-09-07T00:00:00Z',
    being: { name: 'Being' },
    sync: { last_sync_at: null },
    items,
    tombstones: [],
    conflicts: [],
    workspace: workspace || { projects: [], manualOrder: {}, sidebarOrder: [] },
    seeds: [],
  }, null, 2));
  return file;
}

function item(overrides = {}) {
  return {
    id: 'i-1', localRev: 1, syncedLocalRev: 0, beingRev: 0, remoteKnown: false,
    type: 'request', title: '订体检', summary: '', reason: '',
    ask: '', options: [], tier: 'P3', status: 'todo', owner: '',
    updated_at: '2026-09-07T00:00:00Z', evidence: [], lastWriter: {},
    ...overrides,
  };
}

// ── 路径与锁 ─────────────────────────────────────────────────────────────

test('账本路径就是 iCloud 那一个文件（v2.3 §五）', () => {
  assert.strictEqual(
    paths.LEDGER,
    path.join(os.homedir(), 'Library/Mobile Documents/com~apple~CloudDocs/Kairos/projection-snapshot.json')
  );
});

test('锁文件落在 ~/.kairos/locks/，不跟着账本进 iCloud', () => {
  const lock = paths.lockPathFor(paths.LEDGER);
  assert.ok(lock.startsWith(paths.LOCKS_DIR + path.sep), lock);
  assert.ok(lock.endsWith('.lock'));
  // 确定性：同一路径永远同一把锁（Swift 侧 KairosLedgerLock.lockURL 必须算出同一个值）
  assert.strictEqual(lock, paths.lockPathFor(paths.LEDGER));
});

test('锁路径映射与 Swift 侧逐字一致（对拍向量）', () => {
  // 同一个向量在 tests/native-ledger/main.swift 里也断言了一遍。
  // 两侧算出不同的锁名不会报错，只会让两个写入者都以为自己独占——所以要对拍。
  assert.strictEqual(
    path.basename(paths.lockPathFor('/tmp/kairos-lock-vector.json')),
    '53b6c7f2d1138a681b99f43797868cd18f989237cdfddbf14f5a14a0a1534d84.lock'
  );
});

test('锁互斥：拿着锁的时候别人拿不到', () => {
  const file = tempLedger();
  const held = store.acquireLock(file, { purpose: 'test' });
  assert.throws(
    () => store.acquireLock(file, { timeoutMs: 200 }),
    /拿不到账本锁/
  );
  store.releaseLock(held);
  const again = store.acquireLock(file, { timeoutMs: 200 });
  store.releaseLock(again); // 放开之后立刻能拿到
});

test('崩溃残留的锁会被掰断（持有者已死）', () => {
  const file = tempLedger();
  const lockPath = paths.lockPathFor(file);
  fs.mkdirSync(path.dirname(lockPath), { recursive: true });
  fs.writeFileSync(lockPath, JSON.stringify({
    pid: 999999, host: os.hostname(), acquiredAt: '2026-09-07T00:00:00Z', purpose: 'dead',
  }));
  const handle = store.acquireLock(file, { timeoutMs: 500 });
  store.releaseLock(handle);
});

test('规矩 1：mutate 拿到的是锁内重读的账本，不是调用方手上那份', () => {
  const file = tempLedger([item()]);
  // 模拟「调用方出发之后、拿到锁之前，别人改了盘上的账本」
  const meddled = JSON.parse(fs.readFileSync(file, 'utf8'));
  meddled.items[0].summary = '别人写的';
  fs.writeFileSync(file, JSON.stringify(meddled, null, 2));

  let seen = null;
  store.withLedgerLock((ledger) => { seen = ledger.items[0].summary; return undefined; }, { ledgerPath: file });
  assert.strictEqual(seen, '别人写的');
});

test('原子写：写完之后没有临时文件残留', () => {
  const file = tempLedger([item()]);
  store.withLedgerLock((ledger) => store.humanEdit(ledger, 'i-1', { title: '改过' }), { ledgerPath: file });
  const leftovers = fs.readdirSync(path.dirname(file)).filter((name) => name.includes('.tmp'));
  assert.deepStrictEqual(leftovers, []);
  assert.strictEqual(JSON.parse(fs.readFileSync(file, 'utf8')).items[0].title, '改过');
});

// ── 规矩 2：手动改不被覆盖 ───────────────────────────────────────────────

test('新建时填的初值不算「手动改」，不盖戳（v2.3 §五）', () => {
  const ledger = store.createTodo(
    { protocol: 'kairos.local/3', items: [] },
    { id: 'n-1', title: '新的', status: 'todo', tier: 'P0' }
  );
  assert.deepStrictEqual(ledger.items[0].lastWriter, {});
});

test('being 可以覆盖新建时的初值（因为没盖戳）', () => {
  let ledger = store.createTodo({ protocol: 'kairos.local/3', items: [] }, { id: 'n-1', status: 'todo', tier: 'P0' });
  const result = store.beingWrite(ledger, 'n-1', { status: 'doing', tier: 'P2' });
  assert.deepStrictEqual(result.skipped, []);
  assert.strictEqual(result.ledger.items[0].status, 'doing');
  assert.strictEqual(result.ledger.items[0].lastWriter.status, 'being');
});

test('humanEdit 只给真正变了的字段盖戳', () => {
  const ledger = { protocol: 'kairos.local/3', items: [item({ title: '订体检', summary: '要做' })] };
  const next = store.humanEdit(ledger, 'i-1', { title: '订体检（新）', summary: '要做' });
  assert.deepStrictEqual(Object.keys(next.items[0].lastWriter), ['title']);
});

test('humanEdit 没有实际改动时不写盘', () => {
  const ledger = { protocol: 'kairos.local/3', items: [item({ title: '订体检' })] };
  assert.strictEqual(store.humanEdit(ledger, 'i-1', { title: '订体检' }), undefined);
});

test('规矩 2：being 跳过人改过的字段，不改也不报错', () => {
  let ledger = { protocol: 'kairos.local/3', items: [item()] };
  ledger = store.humanEdit(ledger, 'i-1', { status: 'closed' });
  const result = store.beingWrite(ledger, 'i-1', { status: 'doing', summary: '我补的摘要' });
  assert.deepStrictEqual(result.skipped, ['status']);
  assert.deepStrictEqual(result.written, ['summary']);
  assert.strictEqual(result.ledger.items[0].status, 'closed', '人定的状态不许被自动同步撤销');
  assert.strictEqual(result.ledger.items[0].summary, '我补的摘要');
});

test('规矩 2：所有想写的字段都被人锁住时，being 一个字都不写', () => {
  let ledger = { protocol: 'kairos.local/3', items: [item()] };
  ledger = store.humanEdit(ledger, 'i-1', { status: 'closed' });
  const result = store.beingWrite(ledger, 'i-1', { status: 'doing' });
  assert.strictEqual(result.ledger, undefined);
  assert.deepStrictEqual(result.skipped, ['status']);
});

test('新的用户信号解开人类锁，being 从此刻起可以重新覆盖', () => {
  let ledger = { protocol: 'kairos.local/3', items: [item()] };
  ledger = store.humanEdit(ledger, 'i-1', { status: 'closed' });
  ledger = store.releaseHumanLocks(ledger, 'i-1');
  const result = store.beingWrite(ledger, 'i-1', { status: 'doing' });
  assert.deepStrictEqual(result.skipped, []);
  assert.strictEqual(result.ledger.items[0].status, 'doing');
});

test('行级 CAS：版本不符就拒写', () => {
  const ledger = { protocol: 'kairos.local/3', items: [item({ localRev: 3, beingRev: 5 })] };
  assert.throws(() => store.humanEdit(ledger, 'i-1', { title: 'x' }, { expectedRev: 2 }), store.LedgerCASError);
  assert.throws(() => store.beingWrite(ledger, 'i-1', { title: 'x' }, { expectedBeingRev: 4 }), store.LedgerCASError);
  assert.ok(store.humanEdit(ledger, 'i-1', { title: 'x' }, { expectedRev: 3 }));
});

// ── 规矩 4：先文件后消息 ─────────────────────────────────────────────────

test('规矩 4：先落盘再发消息，消息发失败不回滚文件', async () => {
  const file = tempLedger([item()]);
  const order = [];
  const result = await store.commitThenNotify(
    (ledger) => { order.push('file'); return store.humanEdit(ledger, 'i-1', { title: '改了' }); },
    async () => { order.push('message'); throw new Error('being 不在线'); },
    { ledgerPath: file }
  );
  assert.deepStrictEqual(order, ['file', 'message'], '顺序固定：文件在前，消息在后');
  assert.strictEqual(result.notified, false);
  assert.match(result.notifyError.message, /being 不在线/);
  assert.strictEqual(
    JSON.parse(fs.readFileSync(file, 'utf8')).items[0].title,
    '改了',
    '消息发失败不回滚文件——消息只是信号，心跳 diff 自愈会补'
  );
});

// ── 两侧对齐 ─────────────────────────────────────────────────────────────

test('业务字段清单与 Swift 侧 KairosField.business 逐字一致', () => {
  const swift = fs.readFileSync(path.join(__dirname, '..', 'kairos-app-src', 'KairosModels.swift'), 'utf8');
  const block = swift.match(/static let business = \[([\s\S]*?)\]/);
  assert.ok(block, '在 KairosModels.swift 里找不到 business 清单');
  const names = [...block[1].matchAll(/"([a-zA-Z]+)"/g)].map((m) => m[1]);
  assert.deepStrictEqual(names, store.BUSINESS_FIELDS);
});

test('档位值集与 Swift 侧逐字一致', () => {
  const swift = fs.readFileSync(path.join(__dirname, '..', 'kairos-app-src', 'KairosModels.swift'), 'utf8');
  const vocabulary = (name) => {
    const block = swift.match(new RegExp(`enum ${name} \\{[\\s\\S]*?static let all = \\[([^\\]]*)\\]`));
    assert.ok(block, `在 KairosModels.swift 里找不到 ${name}.all`);
    return [...block[1].matchAll(/"([A-Za-z0-9]+)"/g)].map((m) => m[1]);
  };
  assert.deepStrictEqual(vocabulary('KairosTier'), store.TIERS);
});

// ── 渠道带名字 ───────────────────────────────────────────────────────────
// `bonfire:篝火名` / `fireside:炉火名`。Node 侧先放行，
// 不然 being 连写都写不进去——Swift 那两处认得再全也没用。

test('只有炉火能带名字，其余渠道一律裸写', () => {
  assert.ok(store.isValidSource('fireside:演示炉火'));
  assert.ok(store.isValidSource('fireside'), '裸值照旧要过');
  assert.ok(store.isValidSource('bonfire'));
  assert.ok(store.isValidSource('todo'));
  assert.ok(!store.isValidSource('bonfire:演示篝火'), '篝火是全局的，只有一个，没有名字');
  assert.ok(!store.isValidSource('todo:随便'), '待办没有渠道，不许带名字');
  assert.ok(!store.isValidSource('inbox:某人'), '邮局只有一个，不许带名字');
  assert.ok(!store.isValidSource('fireside:'), '冒号后不能空');
  assert.ok(!store.isValidSource('fireside:   '), '只有空格也是空');
  assert.ok(!store.isValidSource('weird:demo'), '认不出的渠道');
});

test('渠道类型只看冒号前——归类和筛选都靠它', () => {
  assert.strictEqual(store.sourceChannel('fireside:演示炉火'), 'fireside');
  assert.strictEqual(store.sourceChannel('fireside'), 'fireside');
  assert.strictEqual(store.sourceChannel('fireside:a:b'), 'fireside', '只在第一个冒号处切');
});

test('能带名字的渠道清单与 Swift 侧 KairosSource.named 一致', () => {
  const swift = fs.readFileSync(path.join(__dirname, '..', 'kairos-app-src', 'KairosModels.swift'), 'utf8');
  const block = swift.match(/static let named = \[([^\]]*)\]/);
  assert.ok(block, '在 KairosModels.swift 里找不到 KairosSource.named');
  const names = [...block[1].matchAll(/([a-z]+)/g)].map((m) => m[1]);
  assert.deepStrictEqual(names, store.NAMED_SOURCES);
});

// ── CLI：being 侧唯一的写入口 ────────────────────────────────────────────
// 手改 JSON 是红线（台账一旦被压平，判例全没），
// 所以这层薄壳也要有测试——它是 being 实际碰到的那个面。

const { execFileSync } = require('child_process');
const CLI = path.join(__dirname, '..', 'ledger', 'cli.js');

function cli(args, ledgerPath) {
  return execFileSync('node', [CLI, ...args], {
    encoding: 'utf8',
    env: { ...process.env, KAIROS_LEDGER: ledgerPath },
  });
}

test('CLI：list / create / get 走得通', () => {
  const file = tempLedger([item()]);
  assert.match(cli(['list'], file), /订体检/);
  cli(['create', '--title', '新的一条', '--status', 'doing'], file);
  const ledger = store.readLedger(file);
  assert.strictEqual(ledger.items.length, 2);
  assert.deepStrictEqual(ledger.items[1].lastWriter, {}, '新建不盖戳');
});

test('CLI：set 跳过人锁住的字段，并且明说跳了哪些', () => {
  const file = tempLedger([item()]);
  store.withLedgerLock((l) => store.humanEdit(l, 'i-1', { status: 'closed' }), { ledgerPath: file });

  const stdout = execFileSync('node', [CLI, 'set', 'i-1', 'status=doing', 'summary=being 补的'], {
    encoding: 'utf8',
    env: { ...process.env, KAIROS_LEDGER: file },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const after = store.readLedger(file).items[0];
  assert.strictEqual(after.status, 'closed', '人定的状态不许被 CLI 盖掉');
  assert.strictEqual(after.summary, 'being 补的', '没被锁的字段照写');
  assert.match(stdout, /已写入 summary/);
});

test('CLI：不认识的字段直接拒绝，不安静吞掉', () => {
  const file = tempLedger([item()]);
  assert.throws(() => cli(['set', 'i-1', 'sate=doing'], file), /Command failed/);
  assert.strictEqual(store.readLedger(file).items[0].status, 'todo');
});

test('CLI：撤掉的字段说清楚去哪了，别只说「不认识」', () => {
  const file = tempLedger([item()]);
  // state 已撤掉，being 手上的提示词可能还是旧的——
  // 回一句「不认识的字段 state」它会以为自己拼错了，然后换着花样再试三次。
  assert.throws(() => cli(['set', 'i-1', 'state=closed'], file), /status=closed/);
  assert.throws(() => cli(['set', 'i-1', 'next=先问问'], file), /options/);
  assert.throws(() => cli(['create', '--title', 'x', '--state', 'being'], file), /status=doing/);
});

test('CLI：owner / type 撤了，也要说清楚去哪了', () => {
  const file = tempLedger([item()]);
  assert.throws(() => cli(['set', 'i-1', 'owner=being'], file), /房间里说一句/);
  assert.throws(() => cli(['set', 'i-1', 'type=risk'], file), /顺序现在归你管/);
});

// 可逆的全自动，不可逆的必须问（契约 §六规矩 6）。了结是 being 唯一按下去撤不回来的
// 写入——原状态被盖掉，重开只回 todo。所以它没有静默通道。
test('CLI：being 不许直接了结，只能把判断写进 options', () => {
  const file = tempLedger([item()]);
  assert.throws(() => cli(['set', 'i-1', 'status=closed'], file), /options/);
  assert.strictEqual(store.readLedger(file).items[0].status, 'todo', '拦住了就是没写进去');
  // 别的状态照走，拦的只有不可逆那一个
  cli(['set', 'i-1', 'status=doing'], file);
  assert.strictEqual(store.readLedger(file).items[0].status, 'doing');
  // 人自己了结不受影响（humanEdit 不走 CLI 这道闸）
  store.withLedgerLock((l) => store.humanEdit(l, 'i-1', { status: 'closed' }), { ledgerPath: file });
  assert.strictEqual(store.readLedger(file).items[0].status, 'closed');
});

// 顺序就是 items 数组的顺序——没有 rank 字段，轻重只用一种东西表达。
test('CLI：rank 重排单子，且不动 rev 和 updated_at', () => {
  const file = tempLedger([item({ id: 'i-1' }), item({ id: 'i-2' }), item({ id: 'i-3' })]);
  const before = store.readLedger(file).items.find((i) => i.id === 'i-3');
  cli(['rank', 'i-3', 'i-1'], file);
  const after = store.readLedger(file);
  assert.deepStrictEqual(after.items.map((i) => i.id), ['i-3', 'i-1', 'i-2'], '没点到的跟在后面，保持原次序');
  const moved = after.items[0];
  assert.strictEqual(moved.localRev, before.localRev, '重排不是业务编辑，不许 +rev');
  assert.strictEqual(moved.updated_at, before.updated_at, '也不许把整本账标成刚改过');
  assert.throws(() => cli(['rank', 'i-9'], file), /账本里没有/);
});

test('CLI：options 形状不对就顶回来（裸字符串数组会让 Mac 端整本账解不开）', () => {
  const file = tempLedger([item()]);
  assert.throws(() => cli(['set', 'i-1', 'options=["能","周一"]'], file), /label/);
  assert.throws(() => cli(['set', 'i-1', 'options=[{"detail":"没有 label"}]'], file), /label/);
  cli(['set', 'i-1', 'options=[{"label":"能，下午发你","detail":"那版今天能整理出来"}]'], file);
  assert.strictEqual(store.readLedger(file).items[0].options[0].label, '能，下午发你');
});

test('CLI：evidence 形状不对也顶回来（和 options 同一个坑）', () => {
  const file = tempLedger([item()]);
  // 2026-09-11：evidence 当时只做 JSON.parse，什么形状都收，而 Swift 侧 KairosLink
  // 要求 url 必填——写一条没 url 的真源，Mac 端整本账就解不开了。
  assert.throws(() => cli(['set', 'i-1', 'evidence=[{"label":"只有标题"}]'], file), /url/);
  assert.throws(() => cli(['set', 'i-1', 'evidence=["http://x"]'], file), /url/);
  cli(['set', 'i-1', 'evidence=[{"url":"https://x","label":"那封信"}]'], file);
  assert.strictEqual(store.readLedger(file).items[0].evidence[0].url, 'https://x');
});

test('CLI：options 的 detail 是可选的（Swift 侧也必须这么认）', () => {
  const file = tempLedger([item()]);
  // 两侧对「detail 可不可省」的看法必须一致。2026-09-11 之前 Node 说可省、
  // Swift 说必填，于是这一句合法的写入会让 Mac 端整本账解不开。
  cli(['set', 'i-1', 'options=[{"label":"能，下午发你"}]'], file);
  const written = store.readLedger(file).items[0].options;
  assert.deepStrictEqual(written, [{ label: '能，下午发你' }]);
});

test('值集与 Swift 侧对得上：STATUSES 四个值', () => {
  assert.deepStrictEqual([...store.STATUSES].sort(), ['closed', 'doing', 'pending', 'todo']);
});

test('CLI：release 解开人类锁之后 being 才盖得动', () => {
  const file = tempLedger([item()]);
  store.withLedgerLock((l) => store.humanEdit(l, 'i-1', { status: 'closed' }), { ledgerPath: file });
  cli(['release', 'i-1'], file);
  cli(['set', 'i-1', 'status=doing'], file);
  assert.strictEqual(store.readLedger(file).items[0].status, 'doing');
});

// ── /2 → /3：球权并进状态 ───────────────────────────────────────────────

test('迁移：closed → closed，being → doing，mine 保持原状态', () => {
  const file = tempLedger([
    { id: 'a', state: 'closed', status: 'doing', title: 'A' },
    { id: 'b', state: 'being', status: 'todo', title: 'B' },
    { id: 'c', state: 'mine', status: 'pending', title: 'C' },
    { id: 'd', state: 'mine', status: 'todo', title: 'D' },
  ], 'kairos.local/2');
  const ledger = store.readLedger(file);
  assert.strictEqual(ledger.protocol, 'kairos.local/3');
  const by = Object.fromEntries(ledger.items.map((i) => [i.id, i]));
  assert.strictEqual(by.a.status, 'closed', '了结过的还是了结的——这条错了，87 条会在人眼前重新打开');
  assert.strictEqual(by.b.status, 'doing', 'being 在办 = 进行中');
  assert.strictEqual(by.c.status, 'pending', '球在人手上不说明这件事走到哪了，状态原样留着');
  assert.strictEqual(by.d.status, 'todo');
  for (const i of ledger.items) assert.strictEqual('state' in i, false, 'state 不留在账本里');
});

test('迁移：/1 的五态一步折到位，不用先跑一遍 /1→/2', () => {
  const file = tempLedger([
    { id: 'a', state: 'inbox', status: 'todo', title: 'A' },   // → being → doing
    { id: 'b', state: 'decide', status: 'todo', title: 'B' },  // → mine  → 原样
    { id: 'c', state: 'doing', status: 'todo', title: 'C' },   // → being → doing
  ], 'kairos.local/1');
  const by = Object.fromEntries(store.readLedger(file).items.map((i) => [i.id, i]));
  assert.strictEqual(by.a.status, 'doing');
  assert.strictEqual(by.b.status, 'todo');
  assert.strictEqual(by.c.status, 'doing');
});

test('迁移：人锁过球权的，锁跟着搬到 status', () => {
  const file = tempLedger([
    { id: 'a', state: 'closed', status: 'todo', title: 'A', lastWriter: { state: 'human', next: 'being' } },
    { id: 'b', state: 'closed', status: 'todo', title: 'B', lastWriter: { state: 'human', status: 'being' } },
  ], 'kairos.local/2');
  const by = Object.fromEntries(store.readLedger(file).items.map((i) => [i.id, i]));
  assert.strictEqual(by.a.lastWriter.status, 'human', '他锁的是「这条完没完我说了算」，换个字段名不该弄丢');
  assert.strictEqual(by.a.lastWriter.state, undefined);
  assert.strictEqual(by.a.lastWriter.next, undefined, '撤掉的字段不留锁');
  assert.strictEqual(by.b.lastWriter.status, 'being', 'status 自己已经锁着就不动它');
});

test('迁移：撤掉的字段不留在账本里，泳道上的手工顺序清掉、合并列表那个桶留着', () => {
  const file = tempLedger(
    [{ id: 'a', state: 'mine', status: 'todo', title: 'A', next: '下一步', scores: { reach: 3 }, links: [{ label: 'x', url: 'y' }] }],
    'kairos.local/2',
    { projects: [], sidebarOrder: [], manualOrder: { 'default/active': ['a'], 'default/mine': ['a'], 'default/closed': [] } }
  );
  const ledger = store.readLedger(file);
  assert.deepStrictEqual(Object.keys(ledger.items[0]).filter((k) => ['state', 'next', 'scores', 'links'].includes(k)), []);
  assert.deepStrictEqual(Object.keys(ledger.workspace.manualOrder), ['default/active']);
});

test('迁移对拍：Node 侧跑 tests/fixtures/migration-vectors.json（Swift 侧断言同一份）', () => {
  // 两个实现各写各的迁移是真出过 bug 的（outbox 那条路 Swift 侧漏了迁移，
  // 手机按的「了结」两侧并出两个不同状态，不报错）。这份向量两侧共用，
  // 改一侧不改另一侧，这里就会红。
  const vectors = require('./fixtures/migration-vectors.json').vectors;
  const items = vectors.map((v, i) => ({ id: 'v' + i, title: v.name, ...v.in }));
  const file = tempLedger(items, 'kairos.local/2');
  const got = store.readLedger(file).items;
  vectors.forEach((v, i) => {
    assert.strictEqual(got[i].status, v.status, `[${v.name}] 状态`);
    assert.strictEqual('state' in got[i], false, `[${v.name}] state 不该留下`);
    if (v.lastWriter) {
      assert.deepStrictEqual(got[i].lastWriter, v.lastWriter, `[${v.name}] 写者戳`);
    }
  });
});

test('迁移幂等：已经是 /3 的原样返回', () => {
  const file = tempLedger([item({ status: 'closed' })]);
  const once = store.readLedger(file);
  assert.deepStrictEqual(store.migrateToMergedStatus(once), once);
});

// ── 多端写入：outbox 并入 ────────────────────────────────────────────────

const outboxMod = require('../ledger/outbox.js');

function writeOutbox(ledgerPath, box) {
  const dir = outboxMod.outboxDir(ledgerPath);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, box.deviceID + '.json'), JSON.stringify(box));
}

function phoneBox(entries) {
  return { protocolVersion: 'kairos.outbox/1', deviceID: 'phone-1', deviceName: 'iPhone', updatedAt: 'x', entries };
}

test('outbox：手机的改动并进账本，字段盖 human 戳，水位推上去', () => {
  const file = tempLedger([item({ title: '订体检', summary: '旧摘要' })]);
  writeOutbox(file, phoneBox([
    { seq: 1, id: 'e1', itemID: 'i-1', op: 'upsert', createdAt: 'x',
      item: { id: 'i-1', status: 'closed', title: '订体检', summary: '旧摘要' } },
  ]));
  const applied = outboxMod.drain(file);
  assert.strictEqual(applied.length, 1);
  const ledger = store.readLedger(file);
  assert.strictEqual(ledger.items[0].status, 'closed');
  assert.strictEqual(ledger.items[0].lastWriter.status, 'human', '手机上也是人改的');
  assert.strictEqual(ledger.items[0].lastWriter.summary, undefined, '没变的字段不盖');
  assert.strictEqual(ledger.sync.outbox_watermark['phone-1'], 1);
});

test('outbox：水位以下的不重放（否则会把人后来的改动又盖回去）', () => {
  const file = tempLedger([item({ status: 'todo' })]);
  writeOutbox(file, phoneBox([
    { seq: 1, id: 'e1', itemID: 'i-1', op: 'upsert', createdAt: 'x', item: { id: 'i-1', status: 'closed' } },
  ]));
  outboxMod.drain(file);
  // Mac 上又把它改回 being
  store.withLedgerLock((l) => store.humanEdit(l, 'i-1', { status: 'doing' }), { ledgerPath: file });
  const applied = outboxMod.drain(file);
  assert.strictEqual(applied.length, 0);
  assert.strictEqual(store.readLedger(file).items[0].status, 'doing');
});

test('outbox：手机新建的条目进账本，手机删的从账本消失', () => {
  const file = tempLedger([item({ id: 'old' })]);
  writeOutbox(file, phoneBox([
    { seq: 1, id: 'e1', itemID: 'new-1', op: 'upsert', createdAt: 'x', item: { id: 'new-1', title: '手机上记的', status: 'todo' } },
    { seq: 2, id: 'e2', itemID: 'old', op: 'delete', createdAt: 'x', item: null },
  ]));
  outboxMod.drain(file);
  const ids = store.readLedger(file).items.map((i) => i.id);
  assert.deepStrictEqual(ids, ['new-1']);
});

test('outbox：带 fields 的条目只叠那几个字段，being 后来写的别的字段不动', () => {
  const file = tempLedger([
    item({ id: 'a', title: 'A', status: 'todo', tier: 'P2', summary: 'being 写的新摘要', lastWriter: { summary: 'being' }, updated_at: '2026-09-08T09:00:00.000Z' }),
  ]);
  writeOutbox(file, phoneBox([{
    seq: 1, id: 'e1', itemID: 'a', op: 'upsert', createdAt: '2026-09-08T00:05:45Z',
    fields: ['tier'],
    item: { id: 'a', title: 'A', status: 'todo', tier: 'P1', summary: '手机上那份旧摘要', updated_at: '2026-09-08T00:05:45Z' },
  }]));
  outboxMod.drain(file);
  const a = store.readLedger(file).items.find((i) => i.id === 'a');
  assert.strictEqual(a.tier, 'P1', '手机改的优先级要并进来');
  assert.strictEqual(a.summary, 'being 写的新摘要', '手机没改过的摘要不能被旧副本盖回去');
  assert.strictEqual(a.lastWriter.tier, 'human');
  assert.strictEqual(a.lastWriter.summary, 'being');
});

test('outbox：老格式条目比账本上那条旧就跳过（手机拿的是旧副本）', () => {
  const file = tempLedger([
    item({ id: 'a', title: 'A', status: 'closed', tier: 'P2', updated_at: '2026-09-07T16:06:52.181Z' }),
    item({ id: 'b', title: 'B', status: 'todo', tier: 'P2', summary: 'being 写的', updated_at: '2026-09-07T10:00:00.000Z' }),
  ]);
  writeOutbox(file, phoneBox([
    { seq: 1, id: 'e1', itemID: 'a', op: 'upsert', createdAt: '2026-09-07T16:05:45Z',
      item: { id: 'a', title: 'A', status: 'doing', tier: 'P2', updated_at: '2026-09-07T16:05:45Z' } },
    { seq: 2, id: 'e2', itemID: 'b', op: 'upsert', createdAt: '2026-09-07T16:05:45Z',
      item: { id: 'b', title: 'B', status: 'closed', tier: 'P2', summary: '旧摘要', updated_at: '2026-09-07T16:05:45Z' } },
  ]));
  outboxMod.drain(file);
  const ledger = store.readLedger(file);
  assert.strictEqual(ledger.items.find((i) => i.id === 'a').status, 'closed', 'being 一分钟后关掉的，不能被手机更早的改动重新打开');
  const b = ledger.items.find((i) => i.id === 'b');
  assert.strictEqual(b.status, 'closed', '账本那条没被动过，手机的状态改动照并');
  assert.strictEqual(b.summary, 'being 写的', '老格式只认 status/tier/title，摘要不动');
  assert.strictEqual(ledger.sync.outbox_watermark['phone-1'], 2, '跳过的也算并过，水位照推');
});

test('outbox：并入方不动设备的文件（那样又成了两个写者）', () => {
  const file = tempLedger([item()]);
  const box = phoneBox([{ seq: 1, id: 'e1', itemID: 'i-1', op: 'upsert', createdAt: 'x', item: { id: 'i-1', status: 'closed' } }]);
  writeOutbox(file, box);
  const before = fs.readFileSync(path.join(outboxMod.outboxDir(file), 'phone-1.json'), 'utf8');
  outboxMod.drain(file);
  const after = fs.readFileSync(path.join(outboxMod.outboxDir(file), 'phone-1.json'), 'utf8');
  assert.strictEqual(before, after);
});

test('CLI：drain 走得通', () => {
  const file = tempLedger([item()]);
  writeOutbox(file, phoneBox([{ seq: 1, id: 'e1', itemID: 'i-1', op: 'upsert', createdAt: 'x', fields: ['summary'], item: { id: 'i-1', summary: '手机补的' } }]));
  assert.match(cli(['drain'], file), /并入 1 条/);
  assert.match(cli(['drain'], file), /没有待并入/);
});

test('dataless 判定：EAGAIN / errno -11 / "Unknown system error -11" 三种写法都认', () => {
  assert.ok(store.isDataless({ code: 'EAGAIN' }));
  assert.ok(store.isDataless({ errno: -11, code: 'Unknown system error -11' }));
  assert.ok(store.isDataless(new Error('Unknown system error -11: Unknown system error -11, read')));
  assert.ok(!store.isDataless({ code: 'ENOENT', errno: -2 }));
  assert.ok(!store.isDataless(new Error('system error -110')));
});

// ── 账本住在哪儿（v2.4：单机为默认，iCloud 可选） ──────────────────────────
//
// 这几条守的是一句话：**Node 侧和 Swift 侧解析出同一个文件**。
// 顺序在 ledger/paths.js 和 KairosLedgerLocation.resolveFolder 里各写了一遍，
// 两边分叉的后果是「being 写的账和 Kairos 看的账不是同一本」，而且不报错。
test('账本位置：指针 > 老 iCloud 位置 > 本机', () => {
  const home = '/Users/x';
  const cloud = path.join(home, 'Library/Mobile Documents/com~apple~CloudDocs/Kairos/projection-snapshot.json');

  assert.strictEqual(
    paths.resolveLedgerFrom({ home, pointerFolder: '/Volumes/Share/Kairos' }),
    '/Volumes/Share/Kairos/projection-snapshot.json'
  );
  assert.strictEqual(
    paths.resolveLedgerFrom({ home, cloudLedgerExists: true }),
    cloud
  );
  assert.strictEqual(
    paths.resolveLedgerFrom({ home, cloudLedgerExists: false }),
    path.join(home, '.kairos/projection-snapshot.json')
  );
  // 指针优先于老位置：人明确换过位置之后，老位置上那份就不该再被看一眼。
  assert.strictEqual(
    paths.resolveLedgerFrom({ home, pointerFolder: '/Volumes/Share/Kairos', cloudLedgerExists: true }),
    '/Volumes/Share/Kairos/projection-snapshot.json'
  );
  // KAIROS_LEDGER 仍然压过一切——测试和演练靠它，不能被指针影响。
  assert.strictEqual(
    paths.resolveLedgerFrom({ home, env: '/tmp/copy.json', pointerFolder: '/Volumes/Share/Kairos' }),
    '/tmp/copy.json'
  );
});

test('账本位置：paths.LEDGER 每次取值都重新解析，不在 require 时算死', () => {
  // store.js / mail.js 那些 `ledgerPath = paths.LEDGER` 是默认参数，每次调用读一次。
  // 人在 Kairos 里换完位置，同一个长跑进程的下一次读写就该落到新地方。
  const original = process.env.KAIROS_LEDGER;
  try {
    process.env.KAIROS_LEDGER = '/tmp/one.json';
    assert.strictEqual(paths.LEDGER, '/tmp/one.json');
    process.env.KAIROS_LEDGER = '/tmp/two.json';
    assert.strictEqual(paths.LEDGER, '/tmp/two.json');
  } finally {
    if (original === undefined) delete process.env.KAIROS_LEDGER;
    else process.env.KAIROS_LEDGER = original;
  }
});

test('账本位置：锁按解析后的路径算，换了位置就是另一把锁', () => {
  // 锁名 = 绝对路径的 SHA-256（Swift 侧 KairosLedgerLock.lockURL 同一套）。
  // 两个位置共用一把锁的话，单机那份和共享那份会互相挡；各算各的才对。
  const a = paths.lockPathFor('/Users/x/.kairos/projection-snapshot.json');
  const b = paths.lockPathFor('/Users/x/Library/Mobile Documents/com~apple~CloudDocs/Kairos/projection-snapshot.json');
  assert.notStrictEqual(a, b);
  assert.ok(a.startsWith(paths.LOCKS_DIR), '锁永远在本机 ~/.kairos/locks/，不跟着账本进 iCloud');
  assert.ok(b.startsWith(paths.LOCKS_DIR));
});
