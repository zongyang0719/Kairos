import Foundation

// Beings Town 邮局 · Kairos 侧组装逻辑的原生测试（Swift）
// 对应 kairos-app-src/KairosMail.swift；Node 侧对应 tests/mail.test.js。
//
// 跑：
//   swiftc kairos-app-src/KairosModels.swift kairos-app-src/KairosMail.swift \
//          tests/native-mail/main.swift -o /tmp/kairos-native-mail-test && /tmp/kairos-native-mail-test

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("✗ " + message) }
}

func message(
    _ id: String,
    sender: String,
    recipient: String,
    content: String = "…",
    at: String,
    status: String? = nil
) -> KairosMailMessage {
    KairosMailMessage(
        id: id, sender: sender, recipient: recipient,
        content: content, createdAt: at, deliveryStatus: status
    )
}

let me = "me"

// ── 时间戳 ───────────────────────────────────────────────────────────────

// Town 给北京时间带偏移，Kairos 本地生成 Z 结尾。两种都得能解析，
// 否则草稿和已发信混在一条对话里排序会乱。
expect(KairosMailClock.parse("2026-09-07T21:30:00+08:00") != nil, "解析得了 Town 的 +08:00")
expect(KairosMailClock.parse("2026-09-07T13:30:00Z") != nil, "解析得了本地的 Z")
expect(
    KairosMailClock.parse("2026-09-07T21:30:00+08:00") == KairosMailClock.parse("2026-09-07T13:30:00Z"),
    "同一时刻的两种写法要相等——不然对话里同一秒的两封信会排出先后"
)
expect(KairosMailClock.sortKey("这不是时间") == .distantPast, "坏时间戳沉底，不跳到最上面")

// ── 按人分组 ─────────────────────────────────────────────────────────────

var mailbox = KairosMailbox.empty
mailbox.beingID = me
mailbox.syncedAt = "2026-09-07T13:00:00Z"
mailbox.received = [
    message("r1", sender: "judy", recipient: me, content: "在吗", at: "2026-09-07T20:00:00+08:00"),
    message("r2", sender: "hex", recipient: me, content: "看到卷轴了", at: "2026-09-07T21:00:00+08:00"),
    message("r3", sender: "judy", recipient: me, content: "？", at: "2026-09-07T22:00:00+08:00"),
]
mailbox.sent = [
    message("s1", sender: me, recipient: "judy", content: "在", at: "2026-09-07T20:30:00+08:00", status: "delivered"),
]

var cursor = KairosMailReadCursor()
var threads = KairosMailAssembly.threads(mailbox: mailbox, drafts: [], cursor: cursor, me: me)

expect(threads.count == 2, "两个对话方，实际 \(threads.count)")
expect(threads[0].correspondent == "judy", "最近说话的排最上面，实际 \(threads[0].correspondent)")
expect(threads[0].entries.count == 3, "judy 那条要把收到的和发出去的混在一起")
expect(
    threads[0].entries.map(\.id) == ["r1", "s1", "r3"],
    "对话内按时间排，实际 \(threads[0].entries.map(\.id))"
)
expect(threads[0].entries[1].direction == .outgoing, "s1 是发出去的")

// 自己不该出现在对话列表里——Town 本来就不许给自己发信，
// 但镜像里万一有（比如别名撞上了），也不能冒出一条「和自己的对话」。
mailbox.sent.append(message("s9", sender: me, recipient: me, content: "?", at: "2026-09-07T23:00:00+08:00"))
expect(
    KairosMailAssembly.threads(mailbox: mailbox, drafts: [], cursor: cursor, me: me)
        .allSatisfy { $0.correspondent != me },
    "自己不成一条对话"
)
mailbox.sent.removeLast()

// ── 未读 ────────────────────────────────────────────────────────────────

expect(KairosMailAssembly.unreadCount(mailbox: mailbox, cursor: cursor) == 3, "没读过就是全未读")
expect(threads[0].unreadCount == 2, "judy 那条 2 封未读")

cursor.threads["judy"] = "2026-09-07T21:00:00+08:00"
threads = KairosMailAssembly.threads(mailbox: mailbox, drafts: [], cursor: cursor, me: me)
let judy = threads.first { $0.correspondent == "judy" }!
expect(judy.unreadCount == 1, "游标之后的才算未读，实际 \(judy.unreadCount)")
expect(KairosMailAssembly.unreadCount(mailbox: mailbox, cursor: cursor) == 2, "总未读跟着降")

// 发出去的不算未读——那是状态，不是「有人找你」。规矩 5 的态度：不分级就是红点海。
expect(judy.entries.filter(\.isUnread).allSatisfy { $0.direction == .incoming }, "只有收到的会未读")

// ── 草稿：待发 / 回执 ────────────────────────────────────────────────────

let draft = KairosMailDraft(seq: 1, id: "d1", recipient: "judy", content: "等下说", createdAt: "2026-09-07T23:00:00Z")
threads = KairosMailAssembly.threads(mailbox: mailbox, drafts: [draft], cursor: cursor, me: me)
let withDraft = threads.first { $0.correspondent == "judy" }!
expect(withDraft.hasPending, "还没被 being 拿走的草稿是「待发」")
expect(withDraft.entries.last?.status == .pending, "实际 \(String(describing: withDraft.entries.last?.status))")
expect(withDraft.entries.last?.draftID == "d1", "待发的才给得出撤回用的 draftID")

// being 发完了但 Town 的 sent[] 还没灌回来：这时候该显示回执的结果，不是「待发送」。
mailbox.receipts = [KairosMailReceipt(
    draftID: "d1", ok: true, messageID: "m-1", recipient: "judy", error: nil, at: "2026-09-07T23:01:00Z"
)]
threads = KairosMailAssembly.threads(mailbox: mailbox, drafts: [draft], cursor: cursor, me: me)
let receipted = threads.first { $0.correspondent == "judy" }!
expect(receipted.entries.last?.status == .delivered, "有回执就按回执说的算")
expect(receipted.entries.last?.draftID == nil, "已经发出去的撤不回来")
expect(!receipted.hasPending, "别再说「等 being 发出」")

// 失败要说清为什么。不写原因的失败提示等于没提示。
mailbox.receipts = [KairosMailReceipt(
    draftID: "d1", ok: false, messageID: nil, recipient: nil,
    error: "404 being not found", at: "2026-09-07T23:01:00Z"
)]
threads = KairosMailAssembly.threads(mailbox: mailbox, drafts: [draft], cursor: cursor, me: me)
let failed = threads.first { $0.correspondent == "judy" }!
expect(failed.hasFailure, "发失败的对话要能一眼看见")
expect(
    KairosMailThread(correspondent: "x", entries: [KairosMailEntry(
        id: "e", direction: .outgoing, content: "c", createdAt: "2026-09-07T00:00:00Z",
        status: .rejected, detail: nil, isUnread: false, draftID: nil
    )], unreadCount: 0).hasFailure,
    "对方拒收也要在列表上看得见"
)
expect(failed.entries.last?.detail == "404 being not found", "原因原样带上")

// 回执里的 recipient 是 Town 解析出来的 being_id，跟人类输入的显示名可能不同——
// 归到解析后的那个人名下，不然同一个人会裂成两条对话。
let byDisplayName = KairosMailDraft(
    seq: 2, id: "d2", recipient: "Judy", content: "嗨", createdAt: "2026-09-07T23:05:00Z"
)
mailbox.receipts = [KairosMailReceipt(
    draftID: "d2", ok: true, messageID: "m-2", recipient: "judy", error: nil, at: "2026-09-07T23:06:00Z"
)]
threads = KairosMailAssembly.threads(mailbox: mailbox, drafts: [byDisplayName], cursor: cursor, me: me)
expect(threads.count == 2, "「Judy」解析成 judy 之后不该多出一条对话，实际 \(threads.map(\.correspondent))")

// ── 投递状态原样透传 ─────────────────────────────────────────────────────

expect(KairosMailAssembly.status(fromDelivery: "delivered") == .delivered, "delivered")
// rejected 和 failed 不能合并：一个是对方不收（再发一百次也一样），一个是没送到（可以再试）。
// 合成一句「发送失败」，人只会一直重发一封永远发不出去的信。
expect(KairosMailAssembly.status(fromDelivery: "rejected") == .rejected, "rejected 单独一档")
expect(KairosMailAssembly.status(fromDelivery: "failed") == .failed, "failed 单独一档")
expect(KairosMailAssembly.status(fromDelivery: "rejected") != KairosMailAssembly.status(fromDelivery: "failed"), "两者不许相等")
expect(KairosMailAssembly.status(fromDelivery: "DELIVERED") == .delivered, "大小写不该影响判断")
// 邮局以后加个新状态，Kairos 要原样显示它，不能吞成「未知」。
expect(KairosMailAssembly.status(fromDelivery: "queued") == .other("queued"), "不认识的原样带走")
expect(KairosMailAssembly.status(fromDelivery: nil) == .delivered, "老数据没这个字段：进了 sent[] 就是发出去了")

// ── 草稿箱：水位与剪枝 ───────────────────────────────────────────────────

var outbox = KairosMailOutbox(deviceID: "phone", deviceName: "iPhone")
let first = outbox.append(recipient: "judy", content: "一")
_ = outbox.append(recipient: "hex", content: "二")
expect(outbox.lastSeq == 2 && outbox.drafts.count == 2, "两封草稿")

outbox.prune(sentThrough: 1)
expect(outbox.drafts.map(\.seq) == [2], "水位以下的自己删掉")
expect(outbox.lastSeq == 2, "lastSeq 只增不减——从 drafts 现算会重发一个 ≤ 水位的 seq，那封信从此发不出去")

let third = outbox.append(recipient: "judy", content: "三")
expect(third.seq == 3, "剪枝之后接着往上发号，实际 \(third.seq)")

outbox.discard(third.id)
expect(outbox.drafts.map(\.seq) == [2], "撤回把草稿删掉")
expect(outbox.lastSeq == 3, "撤回也不回收号")
expect(first.seq == 1, "第一封是 1")

// ── 跨语言对拍：Node 写的文件，Swift 读得懂 ───────────────────────────────

let nodeMailbox = """
{"protocol":"kairos.mailbox/1","being_id":"me","being_name":"Being",
 "synced_at":"2026-09-07T13:00:00.000Z",
 "received":[{"id":"1","sender":"judy","recipient":"me","content":"嗨",
              "created_at":"2026-09-07T21:30:00+08:00","delivery_status":"delivered","thread_id":"t-1"}],
 "sent":[],"outbox_watermark":{"phone":2},
 "receipts":[{"draft_id":"d1","ok":true,"message_id":"m-1","recipient":"judy","error":null,
              "at":"2026-09-07T13:01:00.000Z"}]}
"""
let decodedMailbox = try! JSONDecoder().decode(KairosMailbox.self, from: Data(nodeMailbox.utf8))
expect(decodedMailbox.isSupportedProtocol, "协议版本对得上")
expect(decodedMailbox.beingID == "me" && decodedMailbox.beingName == "Being", "being 身份读得回来")
expect(decodedMailbox.received.first?.deliveryStatus == "delivered", "delivery_status 映射对")
expect(decodedMailbox.outboxWatermark["phone"] == 2, "水位读得回来")
expect(decodedMailbox.receipt(for: "d1")?.messageID == "m-1", "回执按 draft_id 找得到")
expect(
    KairosMailClock.parse(decodedMailbox.syncedAt ?? "") != nil,
    "Node 写的是带毫秒的 ISO（new Date().toISOString()），必须解析得了——否则界面上「上次同步」永远显示没同步过"
)

let nodeOutbox = """
{"protocol":"kairos.mail-outbox/1","device_id":"phone","device_name":"iPhone",
 "updated_at":"2026-09-07T13:00:00Z","last_seq":5,
 "drafts":[{"seq":5,"id":"x9","recipient":"judy","content":"晚点聊","created_at":"2026-09-07T13:00:00Z"}]}
"""
let decodedOutbox = try! JSONDecoder().decode(KairosMailOutbox.self, from: Data(nodeOutbox.utf8))
expect(decodedOutbox.deviceID == "phone" && decodedOutbox.lastSeq == 5, "Node 格式的草稿箱读得懂")
expect(decodedOutbox.drafts.first?.recipient == "judy", "草稿字段对得上")

// Swift 写出去的，字段名要和 Node 侧读的一致（两边共用一个文件，错一个字就断了）。
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
let roundTrip = String(data: try! encoder.encode(decodedOutbox), encoding: .utf8)!
for key in ["\"protocol\"", "\"device_id\"", "\"last_seq\"", "\"created_at\"", "\"drafts\""] {
    expect(roundTrip.contains(key), "写出去要有 \(key)，实际 \(roundTrip)")
}

print("native mail tests: all checks passed")

// ── 一趟邮局：being 回什么样的东西我们都得接得住 ──────────────────────────────

let trip = "m-0badc0de"
let d1 = KairosMailDraft(seq: 1, id: "d1", recipient: "judy", content: "带我一个", createdAt: "2026-09-08T09:00:00Z")

func mailEnvelope(_ body: String, round: String = trip, proto: String = KairosMailRoundReply.protocolName) -> String {
    "{\"protocol\":\"\(proto)\",\"round\":\"\(round)\",\(body)}"
}

// 老实回一个围栏块
let clean = """
```json
\(mailEnvelope("""
"being_id":"me","being_name":"Being",
"received":{"count":1,"messages":[{"id":"1","sender":"judy","recipient":"me",
  "content":"嗨","created_at":"2026-09-08T09:30:00+08:00","delivery_status":"delivered"}]},
"sent":{"count":0,"messages":[]},
"receipts":[{"draft_id":"d1","to":"judy","ok":true,"message_id":"m1","recipient":"judy"}]
"""))
```
"""
let parsed = try! KairosMailRoundReply.parse(clean, round: trip, drafts: [d1])
expect(parsed.received?.count == 1, "收件解出来")
expect(parsed.sent?.count == 0, "发件是空数组，不是「没给」")
expect(parsed.receipts.first?.messageID == "m1", "回执解出来")
expect(parsed.beingID == "me", "身份解出来")
// 骨架里从来没有 at 这一栏。以前它是必填的，being 照着骨架回，整个 receipts 解不出来，
// 连带整趟报「json 读不懂」，邮箱镜像一起没了——骨架和解码器对不上，错在我们这边。
expect(!(parsed.receipts.first?.at.isEmpty ?? true), "回执缺 at 要当此刻，不能整趟解不出来")
expect(parsed.notes.isEmpty, "老实回的一趟不该有话说")

// 前面客套一句 —— 不能因为多了一句「好的」整趟白跑
let chatty = """
好的，我去了一趟。结果如下：

```json
\(mailEnvelope("\"received\":[{\"id\":\"2\",\"sender\":\"hex\",\"recipient\":\"me\",\"content\":\"在\",\"created_at\":\"2026-09-08T10:00:00+08:00\"}]"))
```

有需要再叫我。
"""
let fromChatty = try! KairosMailRoundReply.parse(chatty, round: trip, drafts: [])
expect(fromChatty.received?.count == 1, "围栏前后有闲话也要能抠出来")
expect(fromChatty.sent == nil, "sent 没给就是 nil——不是空，界面上天差地别")
expect(fromChatty.receipts.isEmpty, "没有回执就是空")

// 忘了打围栏，裸给一个对象
let bare = "这次没有新信：" + mailEnvelope("\"received\":{\"count\":0,\"messages\":[]},\"sent\":{\"count\":0,\"messages\":[]}")
let fromBare = try! KairosMailRoundReply.parse(bare, round: trip, drafts: [])
expect(fromBare.received?.isEmpty == true && fromBare.sent?.isEmpty == true, "没围栏也认")

// 括号出现在字符串里，不能把它当结构
let braceInString = """
```json
\(mailEnvelope("\"received\":[{\"id\":\"3\",\"sender\":\"judy\",\"recipient\":\"me\",\"content\":\"给你个例子 {\\\"a\\\":1} 看看\",\"created_at\":\"2026-09-08T11:00:00+08:00\"}]"))
```
"""
let tricky = try! KairosMailRoundReply.parse(braceInString, round: trip, drafts: [])
expect(tricky.received?.first?.content.contains("{\"a\":1}") == true, "字符串里的大括号不参与配平")

// 光说人话，一个 json 都没有 —— 得明说，不能当成「没有信」
do {
    _ = try KairosMailRoundReply.parse("邮局今天关门了，我明天再去。", round: trip, drafts: [])
    fatalError("✗ 没有 json 时应该抛错，不该静静地当成空邮箱")
} catch {}

// 信封先验：不带 protocol、或者答的是上一趟，都不能当成空邮箱
do {
    _ = try KairosMailRoundReply.parse("{\"received\":[],\"sent\":[]}", round: trip, drafts: [])
    fatalError("✗ 不带 protocol 的块不该被当成空邮箱")
} catch {}
do {
    _ = try KairosMailRoundReply.parse(mailEnvelope("\"received\":[]", round: "m-00000000"), round: trip, drafts: [])
    fatalError("✗ 编号对不上是上一趟的回答，整趟不收")
} catch {}

// Town 自己回的 count 是白给的一道校验：它「顺手」精简过就当这一步没取到，
// 镜像宁可旧，不能被裁剪过的那份盖掉
let trimmed = mailEnvelope("\"received\":{\"count\":9,\"messages\":[{\"id\":\"4\",\"sender\":\"judy\",\"recipient\":\"me\",\"content\":\"一\",\"created_at\":\"2026-09-08T12:00:00+08:00\"}]}")
let fromTrimmed = try! KairosMailRoundReply.parse(trimmed, round: trip, drafts: [])
expect(fromTrimmed.received == nil, "count 和条数对不上就当没取到，不能拿裁剪过的盖掉镜像")
expect(fromTrimmed.notes.count == 1, "对不上要说出口")

// 回执要拿这趟托它发的信核对：没托它发过的、收件人对不上的，都不进邮箱
let ghostReceipt = mailEnvelope("\"receipts\":[{\"draft_id\":\"没给过\",\"ok\":true,\"message_id\":\"m9\"}]")
let fromGhost = try! KairosMailRoundReply.parse(ghostReceipt, round: trip, drafts: [d1])
expect(fromGhost.receipts.isEmpty, "我没托它发过的回执不能进邮箱")
expect(fromGhost.notes.contains { $0.contains("没托它发") }, "丢掉了要说出口")

let crossed = mailEnvelope("\"receipts\":[{\"draft_id\":\"d1\",\"to\":\"kim\",\"ok\":true,\"message_id\":\"m2\"}]")
let fromCrossed = try! KairosMailRoundReply.parse(crossed, round: trip, drafts: [d1])
expect(fromCrossed.receipts.isEmpty, "收件人回声对不上，那封回执张冠李戴了")

let silent = try! KairosMailRoundReply.parse(mailEnvelope("\"received\":[]"), round: trip, drafts: [d1])
expect(silent.notes.contains { $0.contains("没给回执") }, "给了信却没回执，得说出来——那封还在草稿箱里")

// 请求正文里要带上待发的信，否则 being 根本不知道要发什么
// 关联走传输层：meta 回传了 client_ref，正文里那个趟号就只是兜底。
let mailNoEcho = "{\"protocol\":\"\(KairosMailRoundReply.protocolName)\",\"received\":{\"count\":0,\"messages\":[]}}"
expect(try! KairosMailRoundReply.parse(mailNoEcho, round: trip, drafts: [], correlated: true).received != nil,
       "meta 认过了，正文没抄趟号也收")

var mailNoEchoNoMetaErrored = false
do { _ = try KairosMailRoundReply.parse(mailNoEcho, round: trip, drafts: []) } catch { mailNoEchoNoMetaErrored = true }
expect(mailNoEchoNoMetaErrored, "meta 没带回来、正文又没抄——认不出是哪一趟，不收")

var mailEchoedWrongErrored = false
do {
    _ = try KairosMailRoundReply.parse(
        mailEnvelope("\"received\":[]", round: "m-00000000"), round: trip, drafts: [], correlated: true
    )
} catch { mailEchoedWrongErrored = true }
expect(mailEchoedWrongErrored, "正文抄了个别的趟号：那是上一趟的回答，meta 认过也不收")

let ask = KairosMailRoundReply.request(drafts: [d1], round: trip)
expect(ask.contains("d1") && ask.contains("带我一个"), "待发的信要出现在请求里")
expect(ask.contains(trip), "本趟编号要写在正文里")
expect(ask.contains("成败都要给回执"), "回执要求要写死在话术里")
expect(ask.contains("BEING-RULES.md"), "规矩在约定里，正文只指路")
expect(!ask.contains("seq"), "seq 是这台设备自己的记账，别送给 being 让它以为也要回")
expect(KairosMailRoundReply.request(drafts: [], round: trip).contains("没有要发的信"), "没有待发也要说清楚")

// ── 合并规则：与 Node 侧 ledger/mail.js 同形 ─────────────────────────────

var box = KairosMailbox.empty
var phone = KairosMailOutbox(deviceID: "phone", deviceName: "iPhone")
let a = phone.append(recipient: "judy", content: "一")
let b = phone.append(recipient: "hex", content: "二")
let c = phone.append(recipient: "judy", content: "三")

// 跳着回执：a 和 c 有、b 没有 → 水位只能停在 a，不然 b 会被剪掉且没人知道
box = KairosMailMerge.applyReceipts(box, [
    KairosMailReceipt(draftID: a.id, ok: true, messageID: "m1", recipient: "judy", error: nil, at: "2026-09-08T09:00:00Z"),
    KairosMailReceipt(draftID: c.id, ok: true, messageID: "m3", recipient: "judy", error: nil, at: "2026-09-08T09:00:02Z"),
], outbox: phone)
expect(box.outboxWatermark["phone"] == a.seq, "水位停在连续段末尾，实际 \(box.outboxWatermark["phone"] ?? -1)")
expect(
    KairosMailMerge.pending(box, outbox: phone).map(\.id) == [b.id],
    "b 还得再发，c 已有回执不重发，实际 \(KairosMailMerge.pending(box, outbox: phone).map(\.content))"
)

// 补上 b 之后水位一路推到底
box = KairosMailMerge.applyReceipts(box, [
    KairosMailReceipt(draftID: b.id, ok: false, messageID: nil, recipient: nil, error: "404", at: "2026-09-08T09:01:00Z"),
], outbox: phone)
expect(box.outboxWatermark["phone"] == c.seq, "补齐空档后推到底")
expect(KairosMailMerge.pending(box, outbox: phone).isEmpty, "失败的也算处理过，不再重发")

// 灌镜像：缺哪半不动哪半
box = KairosMailMerge.applySync(box, received: [
    message("r1", sender: "judy", recipient: me, at: "2026-09-08T09:00:00+08:00"),
], sent: nil, beingID: "me", beingName: "Being")
expect(box.received.count == 1 && box.sent.isEmpty, "只给了 received")
box = KairosMailMerge.applySync(box, received: nil, sent: [
    message("s1", sender: me, recipient: "judy", at: "2026-09-08T09:05:00+08:00", status: "delivered"),
])
expect(box.received.count == 1, "sent 那一趟不该把 received 抹掉")
expect(box.sent.count == 1 && box.syncedAt != nil, "sent 灌进来了，同步时间也落了")

// 超上限只留最近的
let flood = (0..<(KairosMailMerge.messageCap + 25)).map {
    message("f\($0)", sender: "judy", recipient: me, at: "2026-01-01T00:00:00Z", status: nil)
}
let capped = KairosMailMerge.applySync(box, received: flood, sent: nil)
expect(capped.received.count == KairosMailMerge.messageCap, "镜像不是档案馆")

// ── 了结：信也是待办，处理完就下单子 ─────────────────────────────────────
//
// 守的是一句话：**了结的是「到此为止」，不是这个人**。新的一封信要能把它带回来，
// 不然人得记着去「重新打开」——那等于把遗漏的责任推给人。

do {
    var box = KairosMailbox.empty
    box.beingID = me
    box.received = [
        message("c1", sender: "cotton", recipient: me, content: "aces 那条", at: "2026-09-09T10:00:00+08:00"),
    ]

    var marks = KairosMailReadCursor()
    var list = KairosMailAssembly.threads(mailbox: box, drafts: [], cursor: marks, me: me)
    expect(list[0].isDone == false, "没了结过的信当然还开着")

    // 只是读过：行上的加粗和圆点没了，但事情还在——看过 ≠ 处理完。
    marks.markRead("cotton")
    list = KairosMailAssembly.threads(mailbox: box, drafts: [], cursor: marks, me: me)
    expect(list[0].hasUnread == false, "读过了")
    expect(list[0].isDone == false, "读过不等于了结")

    marks.markDone("cotton")
    list = KairosMailAssembly.threads(mailbox: box, drafts: [], cursor: marks, me: me)
    expect(list[0].isDone, "了结了就下单子")
    expect(list[0].hasUnread == false, "了结必然是看过了，不该还挂着未读")

    // cotton 又来一封：比了结那一刻晚，自己回到单子上。
    //
    // 时间戳从此刻现算，**不能写死日期**：`markDone` 记的是「现在」，写死的那天一过，
    // 这封信就成了「了结之前的旧信」，测试自己变成假的（写死日期的 suite 过几天就红）。
    let later = ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))
    box.received.append(
        message("c2", sender: "cotton", recipient: me, content: "还有一条", at: later)
    )
    list = KairosMailAssembly.threads(mailbox: box, drafts: [], cursor: marks, me: me)
    expect(list[0].isDone == false, "新的一封信把它带回来")
    expect(list[0].hasUnread, "带回来的那封是未读")

    // 手动重新打开：了结的印记去掉，回到开着。
    marks.markDone("cotton")
    marks.reopen("cotton")
    list = KairosMailAssembly.threads(mailbox: box, drafts: [], cursor: marks, me: me)
    expect(list[0].isDone == false, "重新打开就该回来")

    // 自己写的草稿也算新动静：回了一封，这条对话当然还没完。
    marks.markDone("cotton")
    let reply = KairosMailDraft(
        seq: 1, id: "d1", recipient: "cotton",
        content: "收到", createdAt: "2026-09-11T10:00:00+08:00"
    )
    list = KairosMailAssembly.threads(mailbox: box, drafts: [reply], cursor: marks, me: me)
    expect(list[0].isDone == false, "自己又写了一封，这条就还开着")
}

// 老的 /1 文件解出来：一条都没了结，正是想要的。
do {
    let legacy = """
    {"protocol":"kairos.mail-read/1","threads":{"cotton":"2026-09-09T03:09:30Z"}}
    """
    let decoded = try! JSONDecoder().decode(KairosMailReadCursor.self, from: Data(legacy.utf8))
    expect(decoded.threads["cotton"] != nil, "老文件的已读游标还在")
    expect(decoded.done.isEmpty, "老文件没有了结这一栏，解出来是空的")
    expect(decoded.isDone("cotton", latest: Date()) == false, "空的就是一条都没了结")
}

print("native mail-round tests: all checks passed")
