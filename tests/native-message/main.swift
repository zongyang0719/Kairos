import Foundation

// 消息也是账本上的一行 · 原生测试（Swift）
// 对应 kairos-app-src/KairosMessageRow.swift + KairosModels 里的 counterpart / thread。
//
// 这套测试守三句话：
//   1. **一个人一行**，不是一封信一行——一百个人的时候，按封分是灾难；
//   2. **人手改过的不被下一封信抹掉**（规矩 2 对消息一样成立）；
//   3. **球权跟着「谁最后说话」走**：勾掉是球出去了，对面回了这一条自己回来。

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("✗ " + message) }
}

func entry(_ text: String, at: String, incoming: Bool = true) -> KairosMailEntry {
    KairosMailEntry(
        id: text + at,
        direction: incoming ? .incoming : .outgoing,
        content: text,
        createdAt: at,
        status: incoming ? .none : .delivered,
        detail: nil,
        isUnread: incoming,
        draftID: nil
    )
}

func thread(_ who: String, _ entries: [KairosMailEntry], done: Bool = false) -> KairosMailThread {
    KairosMailThread(
        correspondent: who,
        entries: entries,
        unreadCount: entries.filter(\.isUnread).count,
        isDone: done
    )
}

let judy = thread("judy", [
    entry("周四那版能不能先看", at: "2026-09-11T01:00:00Z"),
])

// ── 建行：有对方、有原话，就是欠一个回复 ─────────────────────────────────
do {
    let (merged, _) = (KairosMessageRow.merging(.empty, threads: [judy]), ())
    expect(merged.items.count == 1, "一封信 = 一行")
    let row = merged.items[0]
    expect(row.isMessage, "有对方 = 这是消息，不是待办")
    expect(row.counterpart?.name == "judy", "对方是谁")
    expect(row.counterpart?.channel == KairosSource.inbox, "从哪条管子来的")
    expect(row.status == KairosStatus.todo, "对面最后说话 = 还等着我")
    expect(row.title == "周四那版能不能先看", "标题是首句，**不带人名**——名字由行自己画在前面")
    expect(row.excerpt == "周四那版能不能先看", "原话一字不改")
    expect(row.id == KairosMessageRow.rowID(channel: KairosSource.inbox, address: "judy"), "id 稳定")
}

// ── 一个人一行：她一天问三件事，还是一行 ─────────────────────────────────
//
// 按封分行，一百个人的时候就是几百行。她问出来的两件真正的活另起两行待办。
do {
    var box = KairosMessageRow.merging(.empty, threads: [judy])
    let more = thread("judy", judy.entries + [
        entry("还有个事，周五的会改到三点行吗", at: "2026-09-11T02:00:00Z"),
    ])
    box = KairosMessageRow.merging(box, threads: [more])
    expect(box.items.count == 1, "同一个人还是一行，实际 \(box.items.count)")
    expect(box.items[0].title == "还有个事，周五的会改到三点行吗", "标题跟到最新那句")
}

// ── 状态跟着「谁最后说话」走 ─────────────────────────────────────────────
do {
    // 我回过去了 → 球不在我这 → 下单子
    let replied = thread("judy", judy.entries + [
        entry("能，下午发你", at: "2026-09-11T03:00:00Z", incoming: false),
    ])
    let after = KairosMessageRow.merging(.empty, threads: [replied])
    expect(after.items[0].status == KairosStatus.closed, "我最后说话 = 不欠这一封了")

    // 她又回了，而且比我那句晚 → 这一条**自己回来**，不是新建一条
    let again = thread("judy", replied.entries + [
        entry("好，那我等你", at: "2026-09-11T04:00:00Z"),
    ])
    let back = KairosMessageRow.merging(after, threads: [again])
    expect(back.items.count == 1, "回来的是同一行，不是新的一行")
    expect(back.items[0].status == KairosStatus.todo, "对面回了，又等着我")
}

// ── 写好还没发出去的：being 在办 ─────────────────────────────────────────────
//
// 这就是「草稿箱按 todo 的形式拆」：草稿不另开一个视图，它是这一行上的一个状态。
do {
    var draft = entry("能，下午发你", at: "2026-09-11T03:00:00Z", incoming: false)
    draft.status = .pending
    let waiting = KairosMessageRow.merging(.empty, threads: [thread("judy", judy.entries + [draft])])
    expect(waiting.items[0].status == KairosStatus.doing, "写好没发 = 等 being 发出，不是已完结")

    // being 真的发出去之后才算球出去了。
    var sent = draft
    sent.status = .delivered
    let done = KairosMessageRow.merging(.empty, threads: [thread("judy", judy.entries + [sent])])
    expect(done.items[0].status == KairosStatus.closed, "发出去了才下单子")
}

// ── 人手改过的，下一封信不许抹掉（规矩 2） ───────────────────────────────
do {
    var box = KairosMessageRow.merging(.empty, threads: [judy])
    box.items[0].title = "Judy 要周四那版"          // 人改成自己看得懂的说法
    box.items[0].tier = "P0"
    box.items[0].project = "demo"
    box.items[0].lastWriter["title"] = KairosField.human

    let more = thread("judy", judy.entries + [
        entry("在吗", at: "2026-09-11T05:00:00Z"),
    ])
    let after = KairosMessageRow.merging(box, threads: [more])
    expect(after.items[0].title == "Judy 要周四那版", "人改过的标题不被下一封信抹回去")
    expect(after.items[0].tier == "P0", "档位是人的判断，机械并入不碰")
    expect(after.items[0].project == "demo", "归过的项目也不碰")
    expect(after.items[0].excerpt == "在吗", "没锁的字段照常跟到最新")
}

// ── being 也会建消息行：同一个人不许出现两行 ─────────────────────────────────
do {
    // being 先建了一条（篝火 @ 转过来的、或者它自己回掉留痕的），带着对方。
    var box = KairosSnapshot.empty
    var mine = KairosItem(id: "being-made-1", title: "Judy 问周四那版", source: KairosSource.inbox)
    mine.counterpart = KairosCounterpart(name: "Judy", id: "judy", channel: KairosSource.inbox)
    mine.tier = "P1"
    box.items = [mine]

    let after = KairosMessageRow.merging(box, threads: [judy])
    expect(after.items.count == 1, "认的是「同一条管子同一个对方」，不是只认 id——实际 \(after.items.count) 行")
    expect(after.items[0].id == "being-made-1", "并到它建的那一行上，不另起一行")
    expect(after.items[0].tier == "P1", "它写的档位留着")
}

// ── 老条目没有 counterpart，但原话对得上就是同一件事 ─────────────────────
do {
    // 真实情形：being 早先给 cotton 那封信建过一条并了结了，那条没有 counterpart 字段。
    var box = KairosSnapshot.empty
    var legacy = KairosItem(
        id: "da64e592", title: "Cotton 打招呼",
        status: KairosStatus.closed,
        source: KairosSource.inbox,
        excerpt: "嗨，Being。我是 Cotton，别人的 being。刚在 Town 里看见你。",
        updatedAt: "2026-09-12T00:00:00Z"
    )
    legacy.lastWriter["status"] = KairosField.being
    box.items = [legacy]

    let cotton = thread("cotton", [
        entry("嗨，Being。我是 Cotton，别人的 being。刚在 Town 里看见你。", at: "2026-09-09T00:00:00Z"),
    ])
    let after = KairosMessageRow.merging(box, threads: [cotton])
    expect(after.items.count == 1, "原话对得上就是同一件事，不另起一行——实际 \(after.items.count) 行")
    expect(after.items[0].status == KairosStatus.closed, "它早就处理完了，不许被机械建行拉回「在等你回」")
    expect(after.items[0].counterpart?.id == "cotton", "顺手把对方补上")

    // 但别错认：原话不一样的，还是两件事。
    let other = thread("judy", [entry("完全不相干的另一件事，要你看一眼那版设计", at: "2026-09-09T00:00:00Z")])
    let two = KairosMessageRow.merging(box, threads: [other])
    expect(two.items.count == 2, "不同的原话是不同的事，宁可重复也不能并错")
}

// ── 值集：type 只能是那五个 ───────────────────────────────────────────────

// ── 名字要搜得到：它不在 title 里，是行自己画的 ───────────────────────────
do {
    let row = KairosMessageRow.merging(.empty, threads: [judy]).items[0]
    expect(row.searchText.contains("judy"), "搜人名要能找到这一行——名字是一百个人时唯一的索引")
}

// ── 删过的不再建：他删了就是不要了 ───────────────────────────────────────
do {
    var box = KairosSnapshot.empty
    box.tombstones = [KairosTombstone(
        id: KairosMessageRow.rowID(channel: KairosSource.inbox, address: "judy"),
        localRev: 1, syncedLocalRev: 0, beingRev: 0,
        deletedAt: "2026-09-11T00:00:00Z"
    )]
    let after = KairosMessageRow.merging(box, threads: [judy])
    expect(after.items.isEmpty, "删过的不再冒出来，不然就是跟他较劲")
}

// ── 分段：分的依据是「对面有没有人」，不是渠道 ───────────────────────────
do {
    // 篝火里一条「周五 API 要改」——渠道是篝火，但没人等你回，那是待办。
    var notice = KairosItem(id: "b-1", title: "周五 API 要改", source: KairosSource.bonfire)
    expect(!notice.isMessage, "有渠道没对方 = 待办")
    expect(KairosMacScope.todo.allows(notice), "它该出现在「待办」那段")
    expect(!KairosMacScope.message.allows(notice), "不该出现在「消息」那段")

    // 同一条管子里，@ 你的那条有对方，就是消息。
    notice.counterpart = KairosCounterpart(
        name: "cotton", id: "post-42", channel: KairosSource.bonfire, kind: KairosCounterpart.post
    )
    expect(notice.isMessage, "有对方 = 消息，跟它从哪条管子来的无关")
    expect(KairosMacScope.message.allows(notice), "归「消息」那段")
    expect(KairosMacScope.all.allows(notice), "「全部」两种都要")
}

// ── 对方：只有名字也算消息，只是回不了信 ─────────────────────────────────
do {
    let anonymous = KairosCounterpart(name: "某人", id: "", channel: KairosSource.inbox)
    expect(!anonymous.isEmpty, "看得见谁在等你")
    expect(!anonymous.canReply, "但没有地址就回不了——界面要说清楚，不能装作能回")

    let judyCard = KairosCounterpart(name: "Judy", id: "judy", channel: KairosSource.inbox)
    let judyInFireside = KairosCounterpart(name: "Judy", id: "judy", channel: KairosSource.fireside)
    expect(judyCard.rowKey != judyInFireside.rowKey,
           "同一个人在两条管子里找你 = 两行：那本来就是两个地方要回")
}

// ── 存得下、读得回：新加的两个字段要能过一遍 json ─────────────────────────
do {
    var item = KairosItem(id: "m-1", title: "导出卡在权限上")
    item.counterpart = KairosCounterpart(
        name: "演示炉火", id: "演示炉火", channel: KairosSource.fireside, kind: KairosCounterpart.group
    )
    // 回复不是拟稿，是选项：being 列几个判断写进 `options`，人点一个。
    item.options = [
        KairosOption(label: "我看一下权限配置，晚点回", detail: "今天之内给结论"),
        KairosOption(label: "让他们先用导出脚本绕过去", detail: "治标，但今天就能动"),
    ]
    item.thread = [
        KairosUtterance(who: "cotton", at: "2026-09-11T01:00:00Z", text: "导出那条还是 403"),
        KairosUtterance(who: "judy", at: "2026-09-11T01:02:00Z", text: "我这边也是"),
    ]
    let data = try! JSONEncoder().encode(item)
    let back = try! JSONDecoder().decode(KairosItem.self, from: data)
    expect(back.counterpart == item.counterpart, "对方存得下读得回")
    expect(back.options == item.options, "几个选项存得下读得回")
    expect(back.thread == item.thread, "往来存得下读得回")

    // 老账本没有这三个键，不能因此整条读不出来。
    let legacy = #"{"id":"old","title":"老条目"}"#.data(using: .utf8)!
    let old = try! JSONDecoder().decode(KairosItem.self, from: legacy)
    expect(old.counterpart == nil && old.thread.isEmpty, "老条目照常读得出来")
    expect(!old.isMessage, "没有对方就是待办")

    // 空的那三样不写进 json：账本里不留一堆空壳。
    let bare = try! JSONEncoder().encode(KairosItem(id: "bare", title: "光杆"))
    let text = String(data: bare, encoding: .utf8)!
    expect(!text.contains("counterpart") && !text.contains("thread"), "没有的字段整个不写")
}

// ── 后加的字段不能把老文件读废（Swift 合成解码器不认属性默认值） ───────────
//
// 2026-09-11 差点第二次栽在这上面：`KairosRoom` 加了 `toldWhichItem`，老 `rooms.json`
// 没这个键 → 合成解码器抛 keyNotFound → `KairosRooms.load()` 读不出就回 `.empty`
// → **所有房间日志静默清空**。那天早上人类刚说过「往来的信息今天全都丢了」。
do {
    let legacyRoom = #"{"itemID":"i-1","readUpTo":"2026-09-10T00:00:00Z","messages":[]}"#
    let room = try! JSONDecoder().decode(KairosRoom.self, from: legacyRoom.data(using: .utf8)!)
    expect(room.itemID == "i-1", "老格式的房间照常读得出来")
    expect(!room.toldWhichItem, "缺这个键 = 还没交代过，补一次比漏一次好")

    let legacyRooms = #"{"protocolVersion":"kairos.rooms/1","rooms":{"i-1":{"itemID":"i-1","messages":[]}}}"#
    let rooms = try! JSONDecoder().decode(KairosRooms.self, from: legacyRooms.data(using: .utf8)!)
    expect(rooms.rooms.count == 1, "整份也读得出来——读不出就是把日志全清了")
}

print("native message tests: all checks passed")

// MARK: - 标题取第一句

do {
    let long = "上次说的那个插件接口，我这边空出下周二一整天，你看要不要一起过一遍。"
    expect(KairosMessageRow.headline(long) == "上次说的那个插件接口",
           "一句太长就在第一个逗号断，实际 \(KairosMessageRow.headline(long))")
    expect(KairosMessageRow.remainder(long, after: KairosMessageRow.headline(long)) == "我这边空出下周二一整天，你看要不要一起过一遍。",
           "剩下的话进副行")
    expect(KairosMessageRow.headline("周四那版能不能先发我看一眼结构？另外周五的会改到三点。") == "周四那版能不能先发我看一眼结构",
           "到第一个句末标点为止")
    expect(KairosMessageRow.headline("好") == "好", "短句原样")
    expect(KairosMessageRow.headline("  \n ") == "（空信）", "空信")

    // 迁移：机器按旧规则写的长标题换成第一句；人改过的不碰
    var box = KairosMessageRow.merging(.empty, threads: [thread("cotton", [entry(long, at: "2026-09-10T10:00:00Z")])])
    box.items[0].title = KairosMessageRow.legacyHeadline(long)
    box = KairosMessageRow.merging(box, threads: [thread("cotton", [entry(long, at: "2026-09-10T10:00:00Z")])])
    expect(box.items[0].title == "上次说的那个插件接口", "旧规则写的标题迁成第一句")
    box.items[0].title = "和 cotton 对插件接口"
    box.items[0].lastWriter["title"] = KairosField.human
    box = KairosMessageRow.merging(box, threads: [thread("cotton", [entry(long, at: "2026-09-10T10:00:00Z")])])
    expect(box.items[0].title == "和 cotton 对插件接口", "人改过的标题不动")
    print("native headline tests: all checks passed")
}
