#!/usr/bin/env node
'use strict';
// Kairos v2.5 · 账本命令行（being 侧唯一的写入口）
//
// 红线：**being 不许手改账本 JSON**。台账一旦被直接编辑，已了结的判例会被整批
// 拉回待办——那不是同步 bug，是 LLM 直接写 JSON 的后果。所有读写走这里，
// 五句规矩由 ledger/store.js 强制执行，改不动的字段会明说跳过，不会安静盖掉。
//
// 用法：
//   node ledger/cli.js list [--status todo|doing|pending|closed] [--json]
//   node ledger/cli.js get <id> [--json]
//   node ledger/cli.js create --title "..." [--id <手机通知里的 item_id>] [--tier P2] [--status doing] [--project demo] [--source inbox] [--excerpt "原话"] [--summary "..."] [--brief "..."] [--ask "..."]
//   node ledger/cli.js set <id> status=doing project=demo source=inbox excerpt="原话" brief="..." [--expect-being-rev N]
//   node ledger/cli.js rank <id> <id> ...      # 单子的顺序：你排，界面从上往下画
//   node ledger/cli.js release <id>        # 人给了新信号 → 解开人类锁
//   node ledger/cli.js drain               # 把手机等设备的改动并进账本（每次醒来先跑这个）
//   node ledger/cli.js doctor              # 账本体检：路径、条数、锁、被锁住的字段
//
//   邮局（Beings Town DM）——已停用，代码保留；下面这些命令别再跑：
//   node ledger/cli.js mail                # 看邮箱镜像
//   node ledger/cli.js mail-pending --json # 人类写了、等你发出去的信
//   node ledger/cli.js mail-receipt <id> --message-id <mid> --recipient <who>
//   node ledger/cli.js mail-receipt <id> --error "..."   # 发失败也要写，不然它会一直排队
//   node ledger/cli.js mail-sync           # 把 Town 的收发件箱从 stdin 灌进镜像

const fs = require('fs');
const paths = require('./paths.js');
const store = require('./store.js');
const outbox = require('./outbox.js');
const mail = require('./mail.js');

const STATE_GONE =
  '球权（state）撤了，并进 status：\n' +
  '  closed → status=closed   being → status=doing   mine → 状态原样，不用写\n' +
  '「谁在办」不是字段（owner 2026-09-12 也撤了）——在这条的房间里说一句。';
const EVIDENCE_HELP =
  'evidence 要是 [{"url":"真源链接","label":"标题（可省）"}]，url 不能空。';
const OPTIONS_HELP =
  'options 要是 [{"label":"他点的那句","detail":"选它意味着什么（可省）"}]，label 不能空。\n' +
  '  裸字符串数组（["能","周一"]）不收——那种格式 Mac 端整本账都解不开。';
const SOURCE_HELP =
  'source 只能是 todo | inbox | bonfire | fireside；' +
  '只有炉火能带名字：fireside:炉火名（冒号后不能空），其余一律裸写';
// 值是 JSON 的字段。**thread / counterpart 2026-09-13 补进来**：它们不在这张表里的时候，
// `thread='[{"who":…}]'` 被当成一个普通字符串原样写进账本，而 Swift 侧 `thread` 要的是数组——
// 那天 being 就这么写了两条，整本账在 Mac 上解不开：一屏「没有待办」，外加进了写保护。
// （Swift 侧也补了容错，见 `KeyedDecodingContainer.lossy`，但**写者别写错**才是正路。）
const STRUCTURED = new Set(['options', 'evidence', 'thread', 'counterpart']);

function die(message) {
  console.error('KAIROS_LEDGER_ERROR: ' + message);
  process.exit(1);
}

function parseFlags(argv) {
  const flags = {};
  const rest = [];
  for (let i = 0; i < argv.length; i++) {
    const token = argv[i];
    if (token.startsWith('--')) {
      const key = token.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith('--')) flags[key] = true;
      else { flags[key] = next; i++; }
    } else {
      rest.push(token);
    }
  }
  return { flags, rest };
}

/** `field=value`。结构化字段（options/evidence）的值按 JSON 解析。 */
function parseAssignments(tokens) {
  const patch = {};
  for (const token of tokens) {
    const at = token.indexOf('=');
    if (at < 0) die(`「${token}」不是 field=value 的形式`);
    const field = token.slice(0, at);
    const raw = token.slice(at + 1);
    if (field === 'state') die(STATE_GONE);
    if (['next', 'scores', 'links'].includes(field)) {
      die(`${field} 撤了（没有任何一块屏幕念它）。下一步写进 options 让他点，别写成一句预言。`);
    }
    if (field === 'owner') {
      die('owner 撤了：两端没有一块屏幕画过它，是球权那个坑的残骸。\n' +
          '  「谁在办」不是字段——你接手了就在这条的房间里说一句。');
    }
    if (field === 'type') {
      die('type 撤了：它唯一的读者是排序次级键，而顺序现在归你管（见下）。');
    }
    if (!store.BUSINESS_FIELDS.includes(field)) {
      die(`不认识的字段 ${field}。可写字段：${store.BUSINESS_FIELDS.join(', ')}`);
    }
    if (STRUCTURED.has(field)) {
      try { patch[field] = JSON.parse(raw); }
      catch { die(`${field} 需要 JSON 值，收到：${raw}`); }
    } else {
      patch[field] = raw;
    }
  }
  return patch;
}

/** 入场券（契约 §三）：放一条没了结的上单子就是占人类的注意力，缺料就是噪音。不拦，但明说。
 *  brief 也算料：详情页开场画的就是它，空着人类点进去就是一片白。
 *  以前这里只查 state=mine 的——球权撤了之后没有「还没轮到他看」这回事：
 *  只要没 closed，它就在单子上。 */
function warnEntryTicket(item) {
  if (item.status === store.CLOSED) return;
  const missing = ['summary', 'brief', 'reason', 'ask'].filter((f) => !String(item[f] || '').trim());
  if (!(item.evidence || []).length) missing.push('evidence');
  if (missing.length) {
    console.error(`⚠️  入场券不全：${missing.join('、')} 还是空的。放上单子就是占人类的注意力，补齐再放上桌。`);
  }
}

function line(item) {
  const locked = Object.entries(item.lastWriter || {})
    .filter(([, who]) => who === store.HUMAN)
    .map(([field]) => field);
  const lock = locked.length ? `  🔒${locked.join(',')}` : '';
  const status = (item.status || 'todo').padEnd(8);
  const tier = item.tier || 'P3';
  const project = item.project ? `  [${item.project}]` : '';
  const who = item.counterpart && item.counterpart.name ? `${item.counterpart.name} · ` : '';
  return `${status} ${tier} ${item.id.slice(0, 8)}  ${who}${item.title}${project}${lock}`;
}

const [, , command, ...argv] = process.argv;
const { flags, rest } = parseFlags(argv);

switch (command) {
  case 'list': {
    const ledger = store.readLedger();
    let items = ledger.items;
    if (typeof flags.state === 'string') die(STATE_GONE);
    if (typeof flags.status === 'string') {
      if (!store.STATUSES.includes(flags.status)) die(`status 只能是 ${store.STATUSES.join(' | ')}`);
      items = items.filter((i) => i.status === flags.status);
    }
    if (flags.json) { console.log(JSON.stringify(items, null, 2)); break; }
    items.forEach((i) => console.log(line(i)));
    console.log(`\n共 ${items.length} 条（账本 ${ledger.items.length} 条）。🔒 = 人类手改过、你盖不动的字段。`);
    break;
  }

  case 'get': {
    const id = rest[0] || die('要给 id');
    const item = store.readLedger().items.find((i) => i.id === id || i.id.startsWith(id));
    if (!item) die(`账本里没有 ${id}`);
    console.log(JSON.stringify(item, null, 2));
    break;
  }

  case 'create': {
    if (!flags.title) die('--title 必填');
    const fields = { title: flags.title };
    // 手机单机时它的改动只以通知（手机通知）到你这儿；照通知里的 item_id 建，
    // 以后手机和账本接上时同一条不会变成两条。
    if (typeof flags.id === 'string' && flags.id.trim()) {
      const existing = store.readLedger().items.find((i) => i.id === flags.id.trim());
      if (existing) die(`账本里已经有 ${flags.id}（${existing.title}），用 set 改它，别重建`);
      fields.id = flags.id.trim();
    }
    if (typeof flags.state === 'string') die(STATE_GONE);
    for (const key of ['tier', 'status', 'project', 'source', 'excerpt', 'summary', 'brief', 'reason', 'ask']) {
      if (typeof flags[key] === 'string') fields[key] = flags[key];
    }
    // 选项直接在 create 上给：消息行的入场券多这一项，分两步写等于多一次忘记的机会。
    if (typeof flags.options === 'string') {
      let parsed;
      try {
        parsed = JSON.parse(flags.options);
      } catch {
        die('--options 要是一段 json：[{"label":"能，下午发你","detail":"那版今天能整理出来"}]');
      }
      if (!store.isValidOptions(parsed)) die(OPTIONS_HELP);
      fields.options = parsed;
    }
    // 消息那三样。**有对方这一行就是消息**，进顶上「消息」那段。
    //   --from "Judy"          谁在等你（行上的索引，标题前面画的就是它）
    //   --from-id "judy"       回信的真地址；不给就只看得见、回不了
    //   --from-kind person|group|post
    //   --thread '[{"who":"Judy","at":"...","text":"..."}]'  多人渠道的往来，按谁说的切开
    if (typeof flags.from === 'string' && flags.from.trim()) {
      fields.counterpart = {
        name: flags.from.trim(),
        id: typeof flags['from-id'] === 'string' ? flags['from-id'].trim() : '',
        // 炉火的名字在 source 里（`fireside:演示炉火`），channel 只要裸的那截。
        channel: store.sourceChannel(fields.source || 'inbox'),
        kind: typeof flags['from-kind'] === 'string' ? flags['from-kind'] : 'person',
      };
      if (!store.isValidCounterpart(fields.counterpart)) die('--from / --from-id / --from-kind 组合不合法');
    }
    if (typeof flags.thread === 'string') {
      let parsed;
      try {
        parsed = JSON.parse(flags.thread);
      } catch {
        die('--thread 要是一段 json：[{"who":"…","at":"…","text":"…"}]');
      }
      if (!store.isValidThread(parsed)) die('--thread 每格要有 who / text，at 可选，都是字符串');
      fields.thread = parsed;
    }
    if (fields.tier && !store.TIERS.includes(fields.tier)) die(`tier 只能是 ${store.TIERS.join(' | ')}`);
    if (fields.status && !store.STATUSES.includes(fields.status)) die(`status 只能是 ${store.STATUSES.join(' | ')}`);
    if (fields.source && !store.isValidSource(fields.source)) die(SOURCE_HELP);
    let created = null;
    store.withLedgerLock((ledger) => {
      const next = store.createTodo(ledger, fields);
      created = next.items[next.items.length - 1];
      return next;
    }, { purpose: 'cli create' });
    warnEntryTicket(created);
    console.log(`已新建 ${created.id}`);
    console.log(line(created));
    break;
  }

  // 顺序归 being 管。以前排序写死在客户端：tier → type → updated_at，
  // being 能碰的只有一个四档旋钮，而 updated_at 还让它每补一句 summary 就把那条往前顶——
  // 越勤快单子越抖。现在单子就是账本里 items 的次序，它排，界面照画。
  case 'rank': {
    const ids = rest.length ? rest : String(flags.ids || '').split(',').map((s) => s.trim()).filter(Boolean);
    if (!ids.length) die('要给一串 id（空格分开，或 --ids a,b,c）：排在最前的写最前面');
    let head = [];
    store.withLedgerLock((ledger) => {
      const known = new Set((ledger.items || []).map((i) => i.id));
      const missing = ids.filter((id) => !known.has(id));
      if (missing.length) die(`账本里没有：${missing.join('、')}`);
      const next = store.reorder(ledger, ids);
      head = next.items.slice(0, Math.min(5, next.items.length));
      return next;
    }, { purpose: 'cli rank' });
    console.log(`已重排 ${ids.length} 条。单子最前面现在是：`);
    for (const item of head) console.log(line(item));
    console.error('⚠️  排完在房间里说一句：为什么第一条是它。顺序不解释就是又一个不透明的排序算法。');
    break;
  }

  case 'set': {
    const id = rest[0] || die('要给 id');
    const patch = parseAssignments(rest.slice(1));
    if (!Object.keys(patch).length) die('至少给一个 field=value');
    if (patch.options !== undefined && !store.isValidOptions(patch.options)) die(OPTIONS_HELP);
    if (patch.evidence !== undefined && !store.isValidEvidence(patch.evidence)) die(EVIDENCE_HELP);
    if (patch.thread !== undefined && !store.isValidThread(patch.thread)) {
      die('thread 要是一段 json：[{"who":"…","at":"…","text":"…"}]，每格 who / text 必填');
    }
    if (patch.counterpart !== undefined && !store.isValidCounterpart(patch.counterpart)) {
      die('counterpart 要是一段 json：{"name":"…","channel":"…"}');
    }
    if (patch.tier && !store.TIERS.includes(patch.tier)) die(`tier 只能是 ${store.TIERS.join(' | ')}`);
    // 可逆的全自动，不可逆的拿证据。了结盖掉原状态、重开只回 todo——防手滑靠证据：
    // 确实完成了（证据确凿），同一次 set 带 evidence 直接关，替人类拿这个主意；
    // 证据不够，把判断写进 options，让他点。
    if (patch.status === store.CLOSED && !(Array.isArray(patch.evidence) && patch.evidence.length)) {
      die('了结要有证据（不可逆：盖掉原状态，重开只回 todo）。\n' +
          '  确实完成了：同一次 set 里把 evidence 带上，例如\n' +
          '    evidence=\'[{"url":"…","label":"草稿已发出，对方回了收到"}]\'\n' +
          '  证据不够、要他拍板：把判断写进 options，例如\n' +
          '    options=\'[{"label":"确认完结","detail":"周四那封已发出，对方回了收到"},{"label":"还没完","detail":"…"}]\'');
    }
    if (patch.status && !store.STATUSES.includes(patch.status)) die(`status 只能是 ${store.STATUSES.join(' | ')}`);
    if (patch.source && !store.isValidSource(patch.source)) die(SOURCE_HELP);

    let outcome = null;
    store.withLedgerLock((ledger) => {
      const item = ledger.items.find((i) => i.id === id || i.id.startsWith(id));
      if (!item) die(`账本里没有 ${id}`);
      const options = {};
      if (flags['expect-being-rev'] !== undefined) {
        options.expectedBeingRev = Number(flags['expect-being-rev']);
      }
      const result = store.beingWrite(ledger, item.id, patch, options);
      // 证据闸收口：status=closed 时证据必须真落盘。evidence 被人类锁挡下
      // （written 里没有它）的话，status 也一起撤回——关一张没有证据的卡，
      // 等于闸门白设。die 走到这里账本还没写盘，安全。
      if (patch.status === store.CLOSED && !result.written.includes('evidence')) {
        die('了结被拦：evidence 没有真正写入' +
            (result.skipped.includes('evidence')
              ? '——这个字段他手改过，being 无资格覆盖；等他在房间给出新信号解锁，或他自己关。'
              : '（写入层未落盘）。') +
            '账本未改动。');
      }
      outcome = result;
      return result.ledger;
    }, { purpose: 'cli set' });

    if (outcome.skipped.length) {
      console.error(
        `⏭  跳过 ${outcome.skipped.join('、')}：人类手改过这些字段，自动写入没有资格撤销他的决定。\n` +
        `   真要改，等他在这条的房间里给出新信号，或让他自己改。`
      );
    }
    if (!outcome.written.length) {
      console.log('没有写入任何字段。');
      break;
    }
    console.log(`已写入 ${outcome.written.join('、')}`);
    const after = store.readLedger().items.find((i) => i.id === id || i.id.startsWith(id));
    warnEntryTicket(after);
    console.log(line(after));
    break;
  }

  case 'release': {
    const id = rest[0] || die('要给 id');
    let hit = false;
    store.withLedgerLock((ledger) => {
      const item = ledger.items.find((i) => i.id === id || i.id.startsWith(id));
      if (!item) die(`账本里没有 ${id}`);
      const next = store.releaseHumanLocks(ledger, item.id);
      hit = next !== undefined;
      return next;
    }, { purpose: 'cli release' });
    console.log(hit ? '人类锁已解开，这条你可以重新盖了。' : '这条本来就没有人类锁。');
    break;
  }

  case 'drain': {
    const applied = outbox.drain(paths.LEDGER);
    if (!applied.length) { console.log('没有待并入的改动。'); break; }
    for (const a of applied) console.log(`${a.device}  ${a.op.padEnd(6)} ${a.id.slice(0, 8)}  ${a.title || ''}`);
    console.log(`\n并入 ${applied.length} 条。`);
    break;
  }

  // ── 邮局 ────────────────────────────────────────────────────────────────
  //
  // 这里一行网络请求都没有，故意的：Town 按 IP 信任你的 Heart，从这台机器打过去是 401。
  // HTTP 只能你用 act(http) 打，CLI 只管把结果落进文件、把人类写的信交给你。

  case 'mail': {
    const box = mail.readMailbox(mail.mailboxPath());
    const waiting = mail.pending(box, mail.loadOutboxes(paths.LEDGER));
    console.log('邮箱    ' + mail.mailboxPath());
    console.log('上次同步 ' + (box.synced_at || '——还没同步过，跑 mail-sync'));
    console.log('收件    ' + box.received.length + ' 封');
    console.log('发件    ' + box.sent.length + ' 封');
    console.log('待发    ' + waiting.length + ' 封' + (waiting.length ? '  ← 跑 mail-pending' : ''));
    if (flags.json) { console.log(JSON.stringify(box, null, 2)); break; }
    for (const m of box.received.slice(-10)) {
      console.log(`  ← ${m.created_at}  ${m.sender}：${m.content.replace(/\s+/g, ' ').slice(0, 60)}`);
    }
    break;
  }

  case 'mail-pending': {
    const box = mail.readMailbox(mail.mailboxPath());
    const waiting = mail.pending(box, mail.loadOutboxes(paths.LEDGER));
    if (flags.json) { console.log(JSON.stringify(waiting, null, 2)); break; }
    if (!waiting.length) { console.log('没有待发的信。'); break; }
    for (const d of waiting) {
      console.log(`${d.id}  →${d.recipient}  ${d.content.replace(/\s+/g, ' ').slice(0, 60)}`);
    }
    console.log(`\n共 ${waiting.length} 封。发完每封都要写回执（成败都写），否则它会一直排在这儿。`);
    break;
  }

  case 'mail-receipt': {
    const draftID = rest[0] || die('要给草稿 id（mail-pending 里那个 id）');
    const failed = typeof flags.error === 'string';
    if (!failed && typeof flags['message-id'] !== 'string') {
      die('成功要给 --message-id（Town 返回的 message_id）；失败给 --error "原因"');
    }
    const receipt = {
      draft_id: draftID,
      ok: !failed,
      message_id: failed ? null : flags['message-id'],
      recipient: typeof flags.recipient === 'string' ? flags.recipient : null,
      error: failed ? flags.error : null,
      at: new Date().toISOString(),
    };
    const boxes = mail.loadOutboxes(paths.LEDGER);
    try {
      mail.withMailboxLock(
        (box) => mail.applyReceipt(box, boxes, receipt),
        { purpose: 'cli mail-receipt' }
      );
    } catch (error) {
      if (error instanceof mail.MailError) die(error.message);
      throw error;
    }
    console.log(failed ? `已记下没发出去：${flags.error}` : `已记下送达：${flags['message-id']}`);
    break;
  }

  case 'mail-sync': {
    // stdin 收一个 JSON：{"received": <GET /api/messages 的返回>,
    //                    "sent": <GET /api/messages?with=sent 的返回>,
    //                    "being_id": "...", "being_name": "..."}
    // 只取到一半就只给一半——缺的那半保持原样，别把「这次没取到」写成「一封都没有」。
    let payload;
    try {
      payload = JSON.parse(fs.readFileSync(0, 'utf8'));
    } catch (error) {
      die('stdin 不是合法 JSON：' + error.message);
    }
    let result;
    try {
      result = mail.withMailboxLock((box) => mail.applySync(box, {
        received: payload.received,
        sent: payload.sent,
        beingID: payload.being_id,
        beingName: payload.being_name,
      }), { purpose: 'cli mail-sync' });
    } catch (error) {
      if (error instanceof mail.MailError) die(error.message);
      throw error;
    }
    console.log(`镜像已更新：收件 ${result.received.length} 封，发件 ${result.sent.length} 封。`);
    // 灌进来全是空的，十有八九是喂错了东西——2026-09-08 第一次真跑就撞上：
    // being 明明读到一条，镜像里却是 received: []。空邮箱和「没喂对」在结果上长得一样，
    // 不喊一声，人类看到的是「一封信都没有」，而真相是那一趟白跑了。
    if (!result.received.length && !result.sent.length) {
      console.error(
        '⚠️  收发件箱都是空的。真的一封都没有就忽略这句；\n' +
        '    但你刚才要是读到过信，那就是喂错了——mail-sync 要的是 act(http) 的**原样返回**\n' +
        '    （`{"count":N,"messages":[…]}`），不是你自己拼的空壳。没取到的那半就别给。'
      );
    }
    break;
  }

  case 'doctor': {
    const ledger = store.readLedger();
    const byStatus = ledger.items.reduce((a, i) => ((a[i.status] = (a[i.status] || 0) + 1), a), {});
    const lockedItems = ledger.items.filter(
      (i) => Object.values(i.lastWriter || {}).includes(store.HUMAN)
    );
    console.log('账本    ' + paths.LEDGER);
    console.log('协议    ' + ledger.protocol);
    console.log('更新于  ' + ledger.updated_at);
    console.log('条数    ' + ledger.items.length + '  ' + JSON.stringify(byStatus));
    console.log('锁文件  ' + paths.lockPathFor(paths.LEDGER));
    const boxes = outbox.loadOutboxes(paths.LEDGER);
    const marks = (ledger.sync && ledger.sync.outbox_watermark) || {};
    const waiting = boxes.reduce((n, b) => n + (b.entries || []).filter((e) => e.seq > (marks[b.deviceID] || 0)).length, 0);
    console.log('设备 outbox  ' + boxes.length + ' 个，待并入 ' + waiting + ' 条' + (waiting ? '  ← 跑 drain' : ''));
    try {
      const box = mail.readMailbox(mail.mailboxPath());
      const waiting = mail.pending(box, mail.loadOutboxes(paths.LEDGER));
      console.log(
        '邮箱    收 ' + box.received.length + ' / 发 ' + box.sent.length +
        '，待发 ' + waiting.length + (waiting.length ? '  ← 跑 mail-pending' : '') +
        '，上次同步 ' + (box.synced_at || '从未')
      );
    } catch (error) {
      console.log('邮箱    读不出来：' + error.message);
    }
    console.log('被人类手改过的条目：' + lockedItems.length);
    for (const item of lockedItems) console.log('  ' + line(item));
    break;
  }

  default:
    console.log(require('fs').readFileSync(__filename, 'utf8')
      .split('\n').slice(1, 23).map((l) => l.replace(/^\/\/ ?/, '')).join('\n'));
    process.exit(command ? 1 : 0);
}
