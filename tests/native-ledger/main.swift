import Foundation

// Kairos v2.3 · 账本侧规矩的原生测试（Swift）
// 对应 BEING-RULES「账本」节；Node 侧对应 tests/ledger.test.js。

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("✗ " + message) }
}

func snapshot(_ items: String) -> KairosSnapshot {
    let json = """
    {
      "protocol": "kairos.local/2",
      "updated_at": "2026-09-07T00:00:00Z",
      "being": { "name": "Being" },
      "sync": { "last_sync_at": null },
      "items": [\(items)],
      "tombstones": [], "conflicts": [], "seeds": [],
      "workspace": { "projects": [], "manualOrder": {}, "sidebarOrder": [] }
    }
    """
    return try! JSONDecoder().decode(KairosSnapshot.self, from: Data(json.utf8))
}

func row(_ id: String, status: String = "todo", title: String = "标题", summary: String = "", beingRev: Int = 0) -> String {
    """
    { "id": "\(id)", "status": "\(status)", "title": "\(title)", "summary": "\(summary)",
      "localRev": 1, "syncedLocalRev": 0, "beingRev": \(beingRev), "remoteKnown": true }
    """
}

// ── 锁路径：必须与 ledger/paths.js 的 lockPathFor 逐字一致 ────────────────
// 同一个向量在 tests/ledger.test.js 里也断言了一遍。两侧算出不同的锁名不会报错，
// 只会让两个写入者都以为自己独占——所以这条测试是对拍，不是形式。

let vector = URL(fileURLWithPath: "/tmp/kairos-lock-vector.json")
let vectorLock = KairosLedgerLock.lockURL(for: vector)
expect(
    vectorLock.lastPathComponent == "53b6c7f2d1138a681b99f43797868cd18f989237cdfddbf14f5a14a0a1534d84.lock",
    "锁路径映射与 Node 侧不一致，实际：\(vectorLock.lastPathComponent)"
)
expect(
    vectorLock.deletingLastPathComponent().path == KairosFiles.locksDirectory.path,
    "锁文件必须落在 ~/.kairos/locks/，不能跟着账本进 iCloud"
)

// ── 规矩 2 的边界：新建不盖戳，显式修改只盖变了的字段 ────────────────────

var fresh = KairosItem(id: "n-1", title: "新的", tier: "P0")
fresh = KairosItemEdit.created.stamped(fresh, from: nil)
expect(fresh.lastWriter.isEmpty, "新建时填的初值不算「手动改」，不该盖戳")

let before = KairosItem(id: "e-1", title: "订体检", summary: "要做")
var after = before
after.title = "订体检（新）"
after = KairosItemEdit.edited.stamped(after, from: before)
expect(after.lastWriter["title"] == KairosField.human, "改过的字段要盖 human")
expect(after.lastWriter["summary"] == nil, "没改的字段不该被顺手锁住")
expect(after.lastWriter["status"] == nil, "没改的字段不该被顺手锁住")

// ── 规矩 1 的后半段：锁内重读后的三方合并 ────────────────────────────────

let base = snapshot(row("a", title: "甲") + "," + row("b", title: "乙"))

// 调用方（UI）改了 a 的标题
var edited = base
edited.items[0].title = "甲改"

// 与此同时 being 在盘上：给 a 补了摘要、加了一条新待办 c
var disk = base
disk.items[0].summary = "being 补的摘要"
disk.items[0].beingRev = 7
disk.items.append(try! JSONDecoder().decode(KairosItem.self, from: Data(row("c", title: "丙").utf8)))

let merged = KairosLedgerMerge.rebase(edited, base: base, onto: disk)
let a = merged.items.first { $0.id == "a" }!
expect(a.title == "甲改", "人的改动要保住")
expect(a.summary == "being 补的摘要", "人没碰的字段不该被一次无关编辑连坐抹掉")
expect(a.beingRev == 7, "盘上的 beingRev 要保住")
expect(merged.items.contains { $0.id == "c" }, "being 新加的条目不该被覆盖掉")
expect(merged.items.count == 3, "合并后应有 3 条，实际 \(merged.items.count)")

// 盘上没被别人动过时，原样落盘
let untouched = KairosLedgerMerge.rebase(edited, base: base, onto: base)
expect(untouched.items.first { $0.id == "a" }!.title == "甲改", "无人插队时应原样落盘")

// 人在本地删掉的条目，合并后不该复活
var deleted = base
deleted.items.removeAll { $0.id == "b" }
let afterDelete = KairosLedgerMerge.rebase(deleted, base: base, onto: base)
expect(!afterDelete.items.contains { $0.id == "b" }, "人删掉的条目不该复活")

// ── 规矩 5：未读分两级，只有 ask 计数 ────────────────────────────────────

var rooms = KairosRooms.empty
rooms.append(KairosRoomMessage(
    itemID: "a", origin: KairosMessageOrigin.being,
    weight: KairosMessageWeight.routine, text: "排序变了"
))
expect(rooms.unreadAskCount("a") == 0, "routine 不亮不计数")
expect(!rooms.hasUnreadAsk("a"), "全是 routine 的待办不该亮提示")

rooms.append(KairosRoomMessage(
    itemID: "a", origin: KairosMessageOrigin.being,
    weight: KairosMessageWeight.ask, text: "这条要你拍板"
))
expect(rooms.unreadAskCount("a") == 1, "ask 才计入未读")
expect(rooms.hasUnreadAsk("a"), "有 ask 才亮提示")

rooms.append(KairosRoomMessage(
    itemID: "a", origin: KairosMessageOrigin.user,
    weight: KairosMessageWeight.ask, text: "我自己说的"
))
expect(rooms.unreadAskCount("a") == 1, "自己说的话不该算成未读")

rooms.markRead("a")
expect(rooms.unreadAskCount("a") == 0, "读过之后未读归零")

// change-id 幂等：同一条重复投递只留一份
let once = KairosRoomMessage(id: "chg-1", itemID: "b", origin: KairosMessageOrigin.app,
                             weight: KairosMessageWeight.routine, text: "同一条")
rooms.append(once)
rooms.append(once)
expect(rooms.room("b").messages.count == 1, "change-id 幂等键应该去重")

// outbox：没送达的留着下次补（规矩 4：消息发失败不回滚文件）
expect(rooms.undelivered.contains { $0.id == "chg-1" }, "未送达的消息要留在 outbox")
rooms.markDelivered("chg-1", in: "b")
expect(!rooms.undelivered.contains { $0.id == "chg-1" }, "送达后应移出 outbox")

print("native ledger tests: all checks passed")

// ── 多端写入：outbox ─────────────────────────────────────────────────────

var box = KairosOutbox(deviceID: "phone-1", deviceName: "iPhone")
var phoneEdit = KairosItem(id: "a", title: "甲")
phoneEdit.status = "closed"
box.record(phoneEdit, op: "upsert", changed: ["status"])
box.record(phoneEdit, op: "upsert", changed: ["status"])
expect(box.entries.count == 1, "同一条只留最后一版")
expect(box.entries[0].seq == 2, "seq 单调递增，实际 \(box.entries[0].seq)")
expect(box.entries[0].fields == ["status"], "条目记的是真正改过的字段，实际 \(String(describing: box.entries[0].fields))")

// 手机视图 = 账本 + 自己的改动
let ledger = snapshot(row("a", title: "甲") + "," + row("b", title: "乙"))
let phoneView = box.applied(onto: ledger)
expect(phoneView.items.first { $0.id == "a" }!.status == "closed", "手机上刚改的要立刻可见")
expect(phoneView.items.first { $0.id == "a" }!.lastWriter["status"] == KairosField.human, "手机上改的也盖 human")

// Mac 并入：推水位、盖戳
let drained = KairosOutboxDrain.draining(ledger, outboxes: [box])
expect(drained.items.first { $0.id == "a" }!.status == "closed", "并入后账本应是 closed")
expect(drained.sync.outboxWatermark["phone-1"] == 2, "水位应推到 2")
expect(drained.items.first { $0.id == "a" }!.lastWriter["status"] == KairosField.human, "并入的字段盖 human")

// 水位以下不重放
let again = KairosOutboxDrain.draining(drained, outboxes: [box])
expect(again == drained, "水位以下的不该重放")

// 设备看到水位后自己剪
box.prune(appliedThrough: drained.sync.outboxWatermark["phone-1"] ?? 0)
expect(box.entries.isEmpty, "并入过的条目设备自己删掉")

// 与 Node 侧对拍：同一份 outbox JSON，两边并出同样的账本
let nodeStyleOutbox = """
{"protocolVersion":"kairos.outbox/1","deviceID":"phone-2","deviceName":"iPhone","updatedAt":"x",
 "entries":[{"seq":1,"id":"e1","itemID":"b","op":"upsert","createdAt":"x",
   "item":{"id":"b","status":"doing","type":"info","title":"乙改","summary":"","reason":"","ask":"",
           "options":[],"tier":"P3","owner":"","updated_at":"x","evidence":[]}}]}
"""
let decoded = try! JSONDecoder().decode(KairosOutbox.self, from: Data(nodeStyleOutbox.utf8))
let cross = KairosOutboxDrain.draining(ledger, outboxes: [decoded])
let b = cross.items.first { $0.id == "b" }!
expect(b.title == "乙改" && b.status == "doing", "Node 格式的 outbox 也能并")
expect(Set(b.lastWriter.keys) == ["title", "status"], "只盖真正变了的字段，实际 \(b.lastWriter)")

// 只叠 fields 里的字段：手机手里的账本是旧的，being 后来写的摘要不能被旧副本盖回去
let staleBase = snapshot("""
{"id":"s","status":"todo","title":"S","tier":"P2","summary":"being 写的新摘要",
 "lastWriter":{"summary":"being"},"updated_at":"2026-09-08T09:00:00.000Z"}
""")
let fieldsOnly = try! JSONDecoder().decode(KairosOutbox.self, from: Data("""
{"protocolVersion":"kairos.outbox/1","deviceID":"phone-3","deviceName":"iPhone","updatedAt":"x",
 "entries":[{"seq":1,"id":"e1","itemID":"s","op":"upsert","createdAt":"2026-09-08T00:05:45Z","fields":["tier"],
   "item":{"id":"s","status":"todo","type":"request","title":"S","summary":"手机上那份旧摘要","reason":"","ask":"",
           "options":[],"tier":"P1","owner":"","updated_at":"2026-09-08T00:05:45Z","evidence":[]}}]}
""".utf8))
let partial = KairosOutboxDrain.draining(staleBase, outboxes: [fieldsOnly]).items.first { $0.id == "s" }!
expect(partial.tier == "P1", "手机改的优先级要并进来")
expect(partial.summary == "being 写的新摘要", "手机没改过的摘要不能被旧副本盖回去，实际 \(partial.summary)")
expect(partial.lastWriter["summary"] == KairosField.being && partial.lastWriter["tier"] == KairosField.human, "只给真正并入的字段盖 human")

// 老格式条目（没有 fields）：账本那条在它之后又被 being 动过 → 跳过；没动过 → 只认 status/tier/title
let legacyBase = snapshot("""
{"id":"a","status":"closed","title":"A","tier":"P2","updated_at":"2026-09-07T16:06:52.181Z"},
{"id":"b","status":"todo","title":"B","tier":"P2","summary":"being 写的","updated_at":"2026-09-07T10:00:00.000Z"}
""")
let legacy = try! JSONDecoder().decode(KairosOutbox.self, from: Data("""
{"protocolVersion":"kairos.outbox/1","deviceID":"phone-4","deviceName":"iPhone","updatedAt":"x",
 "entries":[
  {"seq":1,"id":"e1","itemID":"a","op":"upsert","createdAt":"2026-09-07T16:05:45Z",
   "item":{"id":"a","status":"doing","title":"A","tier":"P2","updated_at":"2026-09-07T16:05:45Z"}},
  {"seq":2,"id":"e2","itemID":"b","op":"upsert","createdAt":"2026-09-07T16:05:45Z",
   "item":{"id":"b","status":"closed","title":"B","tier":"P2","summary":"旧摘要","updated_at":"2026-09-07T16:05:45Z"}}]}
""".utf8))
let legacyDrained = KairosOutboxDrain.draining(legacyBase, outboxes: [legacy])
expect(legacyDrained.items.first { $0.id == "a" }!.status == "closed", "being 一分钟后关掉的，不能被手机更早的改动重新打开")
let lb = legacyDrained.items.first { $0.id == "b" }!
expect(lb.status == "closed" && lb.summary == "being 写的", "老格式只认 status/tier/title，摘要不动，实际 \(lb.status) / \(lb.summary)")
expect(legacyDrained.sync.outboxWatermark["phone-4"] == 2, "跳过的也算并过，水位照推")
// 手机视图用同一个函数：同样不会把旧副本盖上去
let legacyPhoneView = legacy.applied(onto: legacyBase)
expect(legacyPhoneView.items.first { $0.id == "a" }!.status == "closed", "手机视图也不该把 being 关掉的重新打开")

print("native outbox tests: all checks passed")

// ── 缺字段的嵌套结构不能把整本账拖垮 ─────────────────────────────────
//
// `items` 不是 lossy 解码：一格 option / evidence 抛出去，105 行一起读不出来，
// 界面上只剩「账本损坏」。实测过——Node 的校验说 option.detail 可选、
// 这边却要求必填，being 写一条不带 detail 的选项就能把整本账锁死，CLI 那头一声不吭。

let raggedLedger = """
{"protocol":"kairos.local/3","updated_at":"x","being":{"name":"being"},"sync":{},
 "items":[{"id":"a","title":"A","status":"todo","tier":"P2","localRev":1,
           "options":[{"label":"没有 detail"},{"label":"有","detail":"都要收下"}],
           "evidence":[{"url":"https://x"}],
           "counterpart":{"name":"judy"},
           "thread":[{"who":"judy","text":"没有 at"}]}],
 "tombstones":[],"conflicts":[],
 "workspace":{"projects":[],"manualOrder":{},"sidebarOrder":[]},"seeds":[]}
"""
let ragged = try JSONDecoder().decode(KairosSnapshot.self, from: Data(raggedLedger.utf8))
expect(ragged.items.count == 1, "缺字段不该让整本账解不开")
expect(ragged.items[0].options.count == 2, "两格选项都要留下")
expect(ragged.items[0].options[0].detail.isEmpty, "缺的 detail 落空串，不是抛出去")
expect(ragged.items[0].evidence[0].url == "https://x", "缺 label 的真源照样读出来")
expect(ragged.items[0].counterpart?.name == "judy", "缺 id 的对方照样读出来")
expect(ragged.items[0].thread.count == 1, "缺 at 的那句照样读出来")

// 一个字段的**类型**写错了，也不许牵连整本账。
// 真事：being 用 `ledger set … thread='[{…}]'` 写进去的是一段**字符串**（CLI 那边
// `STRUCTURED` 表里漏了 thread），Swift 的 `decodeIfPresent` 类型不符是抛异常不是返回 nil，
// 于是 107 条待办里两条的一个字段坏了，Mac 上整屏「没有待办」还进了写保护。
// 现在：能从字符串里捞回来就捞（双重编码是最常见的写错法），捞不回来就当这一格没有。
let doubleEncoded = """
{"protocol":"kairos.local/3","updated_at":"x","being":{"name":"being"},"sync":{},
 "items":[{"id":"a","title":"A","status":"todo","tier":"P2",
           "thread":"[{\\"who\\":\\"溯\\",\\"text\\":\\"双重编码\\"}]"},
          {"id":"b","title":"B","status":"todo","tier":"P2","thread":"根本不是 json"},
          {"id":"c","title":"C","status":"todo","tier":"P2","options":"[\\"裸字符串\\"]"}],
 "tombstones":[],"conflicts":[],
 "workspace":{"projects":[],"manualOrder":{},"sidebarOrder":[]},"seeds":[]}
"""
let salvaged = try JSONDecoder().decode(KairosSnapshot.self, from: Data(doubleEncoded.utf8))
expect(salvaged.items.count == 3, "一格类型写错，整本账照样读得出来")
expect(salvaged.items[0].thread.first?.text == "双重编码", "双重编码的 thread 要捞回来")
expect(salvaged.items[1].thread.isEmpty, "捞不回来的就当这一格没有")
expect(salvaged.items[2].options.isEmpty, "options 同一条规矩")
expect(salvaged.items[2].title == "C", "作废的是那一格，不是整条")

// MARK: - bap.ledgerround/1（being → 手机的待办回程）

func lockedRow(_ id: String, title: String, summary: String, locked: [String: String]) -> String {
    let writer = locked.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
    return """
    { "id": "\(id)", "status": "todo", "title": "\(title)", "summary": "\(summary)",
      "localRev": 1, "syncedLocalRev": 0, "beingRev": 0, "remoteKnown": true,
      "lastWriter": {\(writer)} }
    """
}

let theRound = "r-deadbeef"
let roundBase = snapshot(row("a", title: "订体检", summary: "原摘要"))
let roundDigest = KairosLedgerRoundItem.digest(roundBase.items)
let theRef = roundDigest[0].ref

func envelope(_ patches: String, round: String = theRound, proto: String = KairosLedgerRoundReply.protocolName) -> String {
    "{\"protocol\":\"\(proto)\",\"round\":\"\(round)\",\"patches\":[\(patches)]}"
}

func onePatch(_ body: String, ref: String = theRef, title: String? = "订体检") -> String {
    let echo = title.map { "\"title\":\"\($0)\"," } ?? ""
    return "{\"ref\":\"\(ref)\",\(echo)\(body)}"
}

func merged(_ text: String, into base: KairosSnapshot = roundBase,
            digest: [KairosLedgerRoundItem] = roundDigest,
            projects: [String] = ["Default", "demo"]) -> KairosLedgerRoundResult {
    let reply = try! KairosLedgerRoundReply.parse(text, round: theRound)
    return KairosLedgerRoundMerge.apply(reply, to: base, digest: digest, projects: projects)
}

/// 只有 creates、没有 patches 的一趟。
func created(_ creates: String, into base: KairosSnapshot = roundBase,
             projects: [String] = ["Default", "demo"]) -> KairosLedgerRoundResult {
    let text = "{\"protocol\":\"\(KairosLedgerRoundReply.protocolName)\",\"round\":\"\(theRound)\",\"creates\":[\(creates)]}"
    let reply = try! KairosLedgerRoundReply.parse(text, round: theRound)
    return KairosLedgerRoundMerge.apply(reply, to: base, digest: roundDigest, projects: projects)
}

// 抠块：being 在块外客套一句不该让整趟白跑
let politeReply = """
好的，我看了一下。

```json
\(envelope(onePatch("\"summary\":\"改过的摘要\"")))
```
"""
let politePatches = try! KairosLedgerRoundReply.parse(politeReply, round: theRound).patches
expect(politePatches.count == 1 && politePatches[0].summary == "改过的摘要", "块外客套一句不该让整趟白跑")

// 没有块 = 明说，不当成「没有改动」
var noBlockErrored = false
do { _ = try KairosLedgerRoundReply.parse("我这边看不到账本啊", round: theRound) } catch { noBlockErrored = true }
expect(noBlockErrored, "being 没回 json 块要报错，不能静默当成没改动")

// 空 patches 合法
expect(try! KairosLedgerRoundReply.parse(envelope(""), round: theRound).isEmpty, "空 patches 是合法回复")

// ── being 自己建：它有信息要写，不必等我问 ─────────────────────────────────
let born = created("{\"id\":\"town-judy-0909\",\"title\":\"Judy 问周四那版\",\"summary\":\"她要先看\",\"tier\":\"P1\"}")
expect(born.createdItems == 1 && born.snapshot.items.count == 2, "being 自己建的要进账本")
let bornItem = born.snapshot.items.first { $0.id == "town-judy-0909" }!
expect(bornItem.status == KairosStatus.doing, "它摄入的新条目落「进行中」——先消化后上桌")
expect(bornItem.title == "Judy 问周四那版" && bornItem.tier == "P1", "给的字段要写进去")
expect(bornItem.remoteKnown, "它自己建的，不存在「等它确认」")
expect(bornItem.lastWriter.isEmpty, "新建时填的初值不算手动改，不该盖戳")

// 幂等：同一件事重发一次，不该变成两条
let twice = created("{\"id\":\"town-judy-0909\",\"title\":\"Judy 问周四那版\"}", into: born.snapshot)
expect(twice.createdItems == 0 && twice.duplicateCreates == 1, "已经建过的整条跳过，不是错")
expect(twice.snapshot.items.count == 2, "重发不能变成两条")

// id 得像个 id，标题不能空
expect(created("{\"title\":\"没给 id\"}").createdItems == 0, "没给稳定 id 的新建不收——重发时认不出是同一条")
expect(created("{\"id\":\"x\",\"title\":\"太短\"}").createdItems == 0, "id 太短不收")
expect(created("{\"id\":\"town-0909-a\"}").createdItems == 0, "没有标题的待办在单子上就是一行空白")

// 人类删过的不再建——删除意图比它的摄入优先
var buried = roundBase
buried.tombstones = [KairosTombstone(id: "town-dead", localRev: 1, syncedLocalRev: 0, beingRev: 0, deletedAt: KairosClock.now)]
let reborn = created("{\"id\":\"town-dead\",\"title\":\"又送回来了\"}", into: buried)
expect(reborn.createdItems == 0, "删过的不能被它下一趟又送回来")

// 值集照样拦，作废那一个字段，不牵连整条
let badTierCreate = created("{\"id\":\"town-0909-b\",\"title\":\"新的\",\"tier\":\"urgent\",\"summary\":\"这句要留下\"}")
expect(badTierCreate.createdItems == 1, "一个字段作废不该让整条建不成")
let bornB = badTierCreate.snapshot.items.first { $0.id == "town-0909-b" }!
expect(bornB.tier == "P3" && bornB.summary == "这句要留下", "作废的字段落默认值，别的照写")

// 一趟建太多要有个盖子
let flood = (1...25).map { "{\"id\":\"town-flood-\($0)\",\"title\":\"第 \($0) 条\"}" }.joined(separator: ",")
let flooded = created(flood)
expect(flooded.createdItems == KairosLedgerCreate.cap, "一趟最多建 \(KairosLedgerCreate.cap) 条")
expect(flooded.rejected.contains { $0.why.contains("下一趟再来") }, "没收的要说清楚，别让它以为建成了")

// 信封先验：答非所问不能被当成「这一轮没有要改的」。
// 以前任何一个 json 对象都解得通（patches 是可选的），being 把邮局那趟的块答进来，
// 屏幕上写的是「being 看过了，这一轮没有要改的」——它压根没答。
var wrongProtocolErrored = false
do {
    _ = try KairosLedgerRoundReply.parse("{\"received\":[],\"sent\":[]}", round: theRound)
} catch { wrongProtocolErrored = true }
expect(wrongProtocolErrored, "不带 protocol 的块不能静默当成「没有要改的」")

var staleRoundErrored = false
do {
    _ = try KairosLedgerRoundReply.parse(envelope(onePatch("\"summary\":\"上一趟的\""), round: "r-00000000"), round: theRound)
} catch { staleRoundErrored = true }
expect(staleRoundErrored, "编号对不上是上一趟的回答，整趟不收")

// 关联走传输层：meta 把 client_ref 带回来了，正文里抄不抄趟号就不重要了
// （场景感知：别让 being 做格式翻译）。老服务端没这个口子时才退回去认正文那个号。
let plainReply = "{\"protocol\":\"\(KairosLedgerRoundReply.protocolName)\",\"patches\":[]}"
expect(try! KairosLedgerRoundReply.parse(plainReply, round: theRound, correlated: true).isEmpty,
       "meta 认过了，正文没抄趟号也收")

var noEchoNoMetaErrored = false
do { _ = try KairosLedgerRoundReply.parse(plainReply, round: theRound) } catch { noEchoNoMetaErrored = true }
expect(noEchoNoMetaErrored, "meta 没带回来、正文又没抄——认不出是哪一趟，不收")

var echoedWrongErrored = false
do {
    _ = try KairosLedgerRoundReply.parse(
        envelope(onePatch("\"summary\":\"上一趟的\""), round: "r-00000000"),
        round: theRound,
        correlated: true
    )
} catch { echoedWrongErrored = true }
expect(echoedWrongErrored, "正文抄了个别的趟号：那是答旧的那一问，meta 认过也不收")

// 没提到的字段 = 不动，不是清空
let afterBrief = merged(envelope(onePatch("\"brief\":\"being 写的背景\"")))
expect(afterBrief.snapshot.items[0].summary == "原摘要", "没提到的字段必须原样不动")
expect(afterBrief.snapshot.items[0].brief == "being 写的背景", "提到的字段要写进去")
expect(afterBrief.changedItems == 1, "改了一条就报一条")

// 空字符串当没提——留空不是清空
let blankSummary = merged(envelope(onePatch("\"summary\":\"\"")))
expect(blankSummary.snapshot.items[0].summary == "原摘要", "空字符串是「没提」，不能拿它把字段抹掉")
expect(blankSummary.changedItems == 0, "什么都没改就不该报改了")

// 清空要显式说出口
let cleared = merged(envelope(onePatch("\"clear\":[\"summary\"]")))
expect(cleared.snapshot.items[0].summary.isEmpty, "写进 clear 的字段要真的清掉")

// 枚举字段不能清空——它们各有默认值，没有「这条没有档位」这回事
let clearTier = merged(envelope(onePatch("\"clear\":[\"tier\"]")))
expect(clearTier.rejected.contains { $0.field == "tier" }, "清空档位要被顶回来并说明原因")

// 规矩 2：人手改过的字段挡下来，同一条里别的字段照常写
let lockedBase = snapshot(lockedRow("a", title: "订体检", summary: "我自己写的", locked: ["summary": "human"]))
let lockedDigest = KairosLedgerRoundItem.digest(lockedBase.items)
let afterLocked = merged(
    envelope(onePatch("\"summary\":\"being 想盖掉\",\"ask\":\"要不要改期\"", ref: lockedDigest[0].ref)),
    into: lockedBase, digest: lockedDigest
)
expect(afterLocked.snapshot.items[0].summary == "我自己写的", "人手改过的字段，being 盖不动")
expect(afterLocked.snapshot.items[0].ask == "要不要改期", "同一条里没锁的字段照常写")
expect(afterLocked.blocked["a"] == ["summary"], "被挡下的字段要说得出口，实际 \(afterLocked.blocked)")

// 本趟清单里没有的号：不当新建，也不去整个账本里捞——那正是「凭记忆写」
let ghost = merged(envelope(onePatch("\"summary\":\"凭空\"", ref: "zz")))
expect(ghost.snapshot.items.count == 1, "认错的号不能凭空建出一条")
expect(ghost.rejected.first?.ref == "zz", "认错的号要报出来，实际 \(ghost.rejected)")

// 标题回声：没抄、抄错都不收——这是两位短号能成立的全部理由
let noEcho = merged(envelope(onePatch("\"summary\":\"没抄标题\"", title: nil)))
expect(noEcho.changedItems == 0 && noEcho.rejected.count == 1, "没把标题抄回来就对不上是不是同一条")
let wrongEcho = merged(envelope(onePatch("\"summary\":\"抄错了\"", title: "别的事")))
expect(wrongEcho.changedItems == 0 && wrongEcho.rejected.count == 1, "标题对不上说明看串行了，这条不收")
expect(KairosLedgerRoundMerge.sameTitle("订 体检", "订 体检"), "空白折叠了再比，换行改空格不算看错行")

// 值集：写死的几个字段写了没见过的值，作废那一个字段，不牵连整条
let junkTier = merged(envelope(onePatch("\"tier\":\"high\",\"ask\":\"这句要留下\"")))
expect(junkTier.snapshot.items[0].tier != "high", "没见过的档位不能进账本")
expect(junkTier.snapshot.items[0].ask == "这句要留下", "一个字段作废不该牵连同一条里别的字段")
expect(junkTier.rejected.first?.field == "tier", "作废了要说出口，下一趟贴回给 being")

let junkStatus = merged(envelope(onePatch("\"status\":\"进行中\"")))
expect(junkStatus.snapshot.items[0].status == "todo", "没见过的状态词不能写进账本")
// 球权撤了：being 手上的提示词可能还写着 state，那一个字段作废，别牵连同一条里别的字段
let goneState = merged(envelope(onePatch("\"state\":\"being\",\"ask\":\"这句要留下\"")))
expect(goneState.snapshot.items[0].ask == "这句要留下", "撤掉的字段作废那一个，不牵连整条")
expect(goneState.rejected.first?.field == "state", "作废了要说出口，下一趟贴回给 being")

// options 走得通。**这条路是手机单机时 being 唯一够得着账本的路**，而 options 是消息行的
// 入场券——2026-09-11 文档说「能写 options」，patch 结构体里却根本没这个字段，
// being 写了会被静默丢掉，连拒绝都不报，于是「回复是选项不是拟稿」在那条路上等于没实现。
let withOptions = merged(envelope(onePatch(
    "\"options\":[{\"label\":\"能，下午发你\",\"detail\":\"那版今天能整理出来\"},{\"label\":\"周一给\"}]"
)))
expect(withOptions.snapshot.items[0].options.count == 2, "being 给的选项要真写进账本")
expect(withOptions.snapshot.items[0].options[0].label == "能，下午发你", "label 原样")
expect(withOptions.snapshot.items[0].options[1].detail.isEmpty, "detail 可省")
// 戳由 KairosStore 提交时打（和 brief 那条同一条路），这里验它认得出 options 变了
expect(
    KairosItemEdit.beingWrite
        .stamped(withOptions.snapshot.items[0], from: roundBase.items[0])
        .lastWriter["options"] == KairosField.being,
    "being 写的 options 要盖 being 戳，不能盖成 human"
)

// 形状不对作废这一个字段，**并且说出口**——静默丢掉它会一趟趟接着写。
let junkOptions = merged(envelope(onePatch(
    "\"options\":[{\"label\":\"  \"}],\"ask\":\"这句要留下\""
)))
expect(junkOptions.snapshot.items[0].options.isEmpty, "label 是空白的不能进账本")
expect(junkOptions.snapshot.items[0].ask == "这句要留下", "一个字段作废不牵连同一条里别的")
expect(junkOptions.rejected.contains { $0.field == "options" }, "作废了要说出口")

// 人手改过的选项，being 盖不动（规矩 2 对 options 同样成立）
var lockedOptionsBase = roundBase
lockedOptionsBase.items[0].lastWriter["options"] = KairosField.human
let blockedOptions = merged(envelope(onePatch("\"options\":[{\"label\":\"我来定\"}]")), into: lockedOptionsBase)
expect(blockedOptions.snapshot.items[0].options.isEmpty, "人锁住的 options being 盖不动")
expect(blockedOptions.blocked[roundBase.items[0].id]?.contains("options") == true, "挡掉了要回报")

// 项目名不拦：归类是 being 的活，写个新名字就建起来了。
// 档位/状态那种写错会让人看不出来的才拦，项目写错人一眼就看见、删掉就行。
let newProject = merged(envelope(onePatch("\"project\":\"一摊新事\"")))
expect(newProject.snapshot.items[0].project == "一摊新事", "being 归的新项目要收下")
expect(!newProject.rejected.contains { $0.field == "project" }, "项目名不该被作废")
let realProject = merged(envelope(onePatch("\"project\":\"demo\"")))
expect(realProject.snapshot.items[0].project == "demo", "清单里有的项目名照常写")

let namedSource = merged(envelope(onePatch("\"source\":\"fireside:演示炉火\"")))
expect(namedSource.snapshot.items[0].source == "fireside:演示炉火", "炉火带名字是合法渠道")
let junkSource = merged(envelope(onePatch("\"source\":\"bonfire:哪一堆\"")))
expect(junkSource.snapshot.items[0].source != "bonfire:哪一堆", "只有炉火能带名字")

// 标题是回声位，不是可写字段——抄对了也不会把账本上的标题改掉
let retitle = merged(envelope(onePatch("\"summary\":\"新摘要\"")))
expect(retitle.snapshot.items[0].title == "订体检", "标题是人起的名字，being 不能改")
expect(retitle.snapshot.items[0].summary == "新摘要", "同一条里该写的还是要写")

// 送上去的清单：了结的不送，锁着的字段要标出来，每条一个不重样的短号
let digestBase = snapshot([
    lockedRow("a", title: "开着", summary: "x", locked: ["tier": "human"]),
    row("b", status: "closed", title: "了结了"),
].joined(separator: ","))
let digest = KairosLedgerRoundItem.digest(digestBase.items)
expect(digest.count == 1 && digest[0].id == "a", "了结的不送上去烧 token")
expect(digest[0].locked == ["tier"], "锁着的字段要告诉 being ，别让它白写")
expect(!digest[0].ref.isEmpty, "每条都要有本趟短号")
expect(digest[0].counterpart == nil, "待办没有对方，这个字段就不该出现")

// 消息行要带上对方：文档叫 being 「给消息行补选项」，它得先看得出哪行是消息。
var msgBase = roundBase
msgBase.items[0].counterpart = KairosCounterpart(
    name: "judy", id: "judy", channel: KairosSource.inbox
)
let msgDigest = KairosLedgerRoundItem.digest(msgBase.items)
expect(msgDigest[0].counterpart == "judy", "消息行要告诉 being 谁在等，实际 \(msgDigest[0].counterpart ?? "nil")")
let manyRefs = KairosRoundRef.pool(60)
expect(Set(manyRefs).count == 60, "一趟里的短号不能撞")

// being 写入盖 being 戳，不是 human——盖错了它自己以后都盖不动
let stamped = KairosItemEdit.beingWrite.stamped(
    afterBrief.snapshot.items[0], from: roundBase.items[0]
)
expect(stamped.lastWriter["brief"] == KairosField.being,
       "being 写入必须盖 being 戳，实际 \(stamped.lastWriter)")

// 上一趟的判决要能说成人话贴回给 being
let report = KairosLedgerRoundReport(round: "r-1", applied: 3, rejected: [
    KairosLedgerRoundRejection(ref: "k7", field: "tier", why: "档位只认 P0 / P1 / P2 / P3"),
])
let lastLine = KairosLedgerRoundReply.lastRoundLine(report)
expect(lastLine.contains("3 条") && lastLine.contains("k7 的 tier"), "上一趟的判决要带回去，实际：\(lastLine)")

// being 不回 json：整趟不收，而且要能说出它当时说的是什么
do {
    _ = try KairosLedgerRoundReply.parse("好的，我看过了，暂时不用改。", round: theRound)
    expect(false, "没有 json 块也解通了——那等于把「它没答」当成「它说不用改」")
} catch let error as KairosLedgerRoundReply.ParseError {
    expect(error.localizedDescription.contains("好的"),
           "没收也要把它当时说的话带出来，实际：\(error.localizedDescription)")
} catch {
    expect(false, "抛的不是 ParseError：\(error)")
}

// 判决里带着 being 自己写的字，下一趟要回到正文里——反引号和换行必须先拿掉
let flattened = KairosLedgerRoundReply.safeForBody("它说的是：\n```json\n不是 json\n```")
expect(!flattened.contains("`"), "反引号要换掉，实际：\(flattened)")
expect(!flattened.contains("\n"), "换行要压平，实际：\(flattened)")

let messyReport = KairosLedgerRoundReport(round: "r-2", applied: 0, rejected: [
    KairosLedgerRoundRejection(
        ref: "整趟", field: nil,
        why: "being 没有回一个 json 块。它说的是：```json\n{坏的\n```"
    ),
])
let messyAsk = KairosLedgerRoundReply.request(
    items: roundDigest, round: theRound, projects: ["Default"], last: messyReport
)
expect(messyAsk.components(separatedBy: "```").count % 2 == 1,
       "正文里的围栏必须成对——判决里贴回去的反引号会把下一趟整个废掉")

// 请求正文：编号、项目清单、骨架都要在
let ask = KairosLedgerRoundReply.request(
    items: roundDigest, round: theRound, projects: ["Default", "demo"], last: report
)
expect(ask.contains(theRound), "本趟编号要写在正文里")
expect(ask.contains("Default / demo"), "项目清单要送，否则「别自己发明项目名」这条没法遵守")
expect(ask.contains(KairosLedgerRoundReply.protocolName), "回复骨架要给，省掉一次全量失败往返")
expect(ask.contains("BEING-RULES.md"), "规矩在约定里，正文只指路")
expect(ask.contains("k7 的 tier"), "上一趟犯的那条规矩要贴回它脸上")

// 规矩按需重述：没犯就不说。值集这种一次性的东西在操作卡里，不每趟重发。
let cleanAsk = KairosLedgerRoundReply.request(
    items: roundDigest, round: theRound, projects: ["Default"], last: nil
)
expect(!cleanAsk.contains("只认 P0"), "没犯规就不该重复值集，那是操作卡里的东西")
expect(!cleanAsk.contains("上一趟"), "第一趟没有上一趟可说")

print("native ledger-round tests: all checks passed")

// MARK: - 机器来回的固定房间（信息不串的根子）

var roomsA = KairosRooms.empty
let mailRoom = roomsA.roundSession(KairosRoundKind.mail)
let ledgerRoom = roomsA.roundSession(KairosRoundKind.ledger)
expect(!mailRoom.isEmpty && !ledgerRoom.isEmpty, "两种来回都要有房间号")
expect(mailRoom != ledgerRoom, "邮局和账本不能是同一间，否则两趟的话会串")
expect(roomsA.roundSession(KairosRoundKind.mail) == mailRoom, "同一种来回每次都是同一间")

// 存了再读，房间号不变——换个房间就等于把之前的上下文丢了
let encoded = try! JSONEncoder().encode(roomsA)
var roomsB = try! JSONDecoder().decode(KairosRooms.self, from: encoded)
expect(roomsB.roundSession(KairosRoundKind.mail) == mailRoom, "重启之后邮局还是那一间")

// 老的 rooms.json 没有 roundSessions 这个键——不能因此整份读不出来，那会把房间日志全清空
let legacyRooms = """
{"protocolVersion":"kairos.rooms/1",
 "rooms":{"a":{"itemID":"a","messages":[{"id":"m1","itemID":"a","origin":"user","weight":"routine",
   "text":"在吗","createdAt":"2026-09-08T10:00:00Z","delivered":true}]}}}
"""
let decodedLegacy = try? JSONDecoder().decode(KairosRooms.self, from: Data(legacyRooms.utf8))
expect(decodedLegacy != nil, "老格式 rooms.json 必须还能读")
expect(decodedLegacy?.rooms["a"]?.messages.count == 1, "老格式里的房间日志一条都不能丢")
expect(decodedLegacy?.roundSessions.isEmpty == true, "老格式没有来回房间，第一次用时再生成")

print("native round-room tests: all checks passed")

// ── 渠道带名字：`bonfire:篝火名` / `fireside:炉火名`────────
//
// 归类只看冒号前，标签只看冒号后。两边分开测——normalized 认错了会让整条待办
// 从筛选里消失，label 认错了只是标签难看，严重程度不一样。

expect(KairosSource.normalized("fireside:演示炉火") == KairosSource.fireside, "带名字的炉火还是炉火")
expect(KairosSource.normalized("bonfire:乱写") == KairosSource.bonfire,
       "篝火不该带名字，但真带了也得归类成篝火——CLI 拦得住新写的，拦不住已经在账本里的")
expect(KairosSource.normalized("fireside") == KairosSource.fireside, "裸值照旧")
expect(KairosSource.normalized("fireside:") == KairosSource.fireside, "名字空着也还是炉火")
expect(KairosSource.normalized("weird:demo") == KairosSource.todo, "认不出的渠道当待办，不是当炉火")
expect(KairosSource.normalized("") == KairosSource.todo, "空串当待办")

expect(KairosSource.name("fireside:演示炉火") == "演示炉火", "名字取冒号后面整段")
expect(KairosSource.name("fireside:a:b") == "a:b", "只在第一个冒号处切，名字里可以再有冒号")
expect(KairosSource.name("fireside") == nil, "裸值没有名字")
expect(KairosSource.name("fireside:") == nil, "空名字等于没名字")
expect(KairosSource.name("fireside:   ") == nil, "只有空格也等于没名字")
expect(KairosSource.name("bonfire:演示篝火") == nil, "篝火是全局的，冒号后面那截不当名字用")
expect(KairosSource.name("todo:随便") == nil, "待办不许带名字——只有炉火能带")
expect(KairosSource.name("inbox:某人") == nil, "邮局只有一个，不许带名字")

expect(KairosSource.label("fireside:演示炉火") == "演示炉火", "有名字就写名字")
expect(KairosSource.label("fireside") == "炉火", "没名字写渠道名")
expect(KairosSource.label("bonfire:演示篝火") == "篝火", "篝火不认名字，标签还是「篝火」")
expect(KairosSource.label("todo:随便") == "待办", "待办带的后缀不当名字用")

print("native source-name tests: all checks passed")

// MARK: - being 还够不够得着账本（drain 停摆判据，2026-09-11）
//
// 关联 + Mac 关机那个洞：粗手（在 Mac 上跑 CLI）没了，细手（对话线）又因为
// 「接了 iCloud」被挡掉，being 彻底哑。判据得看那头有没有人在收，不是看有没有接。

let stallNow = KairosClock.parse("2026-09-11T12:00:00Z")

expect(
    !KairosStore.drainStalled(oldestPendingAt: nil, now: stallNow),
    "一条积压都没有：不算证据，不能据此说 Mac 关着"
)
expect(
    !KairosStore.drainStalled(oldestPendingAt: "2026-09-11T11:58:00Z", now: stallNow),
    "刚改完两分钟，Mac 还没来得及收，别急着退回对话线"
)
expect(
    !KairosStore.drainStalled(oldestPendingAt: "2026-09-11T11:31:00Z", now: stallNow),
    "29 分钟还在门槛内——Mac 合盖睡一会儿不该被判成不在"
)
expect(
    KairosStore.drainStalled(oldestPendingAt: "2026-09-11T11:30:00Z", now: stallNow),
    "整 30 分钟就算停摆，门槛是闭区间"
)
expect(
    KairosStore.drainStalled(oldestPendingAt: "2026-09-10T12:00:00Z", now: stallNow),
    "堆了一天：那头肯定没人在"
)
expect(
    KairosStore.drainStalled(oldestPendingAt: "看不懂的时间", now: stallNow),
    "解析不出来当最早（KairosClock.parse 的约定），按停摆算——宁可多问一趟也别让 being 哑着"
)
expect(
    !KairosStore.drainStalled(oldestPendingAt: "2026-09-11T11:00:00Z", now: stallNow, threshold: 7200),
    "门槛可调：两小时的话，一小时的积压还不算停摆"
)

print("native drain-stall tests: all checks passed")
