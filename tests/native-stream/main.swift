import Foundation

// being 那条流的解码 · 原生测试（Swift）
// 对应 kairos-app-src/BeingClient.swift 的 BeingStreamReader / BeingActivity。
//
// 这套测试守的是一句话：**「已送达」和「回复收完」是两件事**。
// meta 一到就是送达；后面断了是回复没收全，不该在气泡上写「没发出去」。

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("✗ " + message) }
}

/// 跑一串事件，收集发出去的东西。seq 传 nil 就按 live 那条路自己数。
@discardableResult
func run(
    _ reader: inout BeingStreamReader,
    _ frames: [(String, [String: Any])],
    serverSeq: Bool = false
) -> [BeingStreamEvent] {
    var emitted: [BeingStreamEvent] = []
    for (index, frame) in frames.enumerated() {
        try! reader.consume(
            event: frame.0,
            data: frame.1,
            seq: serverSeq ? index + 1 : nil
        ) { emitted.append($0) }
    }
    return emitted
}

func accepted(_ events: [BeingStreamEvent]) -> [String?] {
    events.compactMap { if case .accepted(let id) = $0 { return .some(id) } else { return nil } }
}

func activities(_ events: [BeingStreamEvent]) -> [BeingActivity?] {
    events.compactMap { if case .activity(let value) = $0 { return .some(value) } else { return nil } }
}

// ── meta：送达的那一刻，且不占 seq ──────────────────────────────────────────
do {
    var reader = BeingStreamReader(sessionId: "room-1")
    let events = run(&reader, [("meta", ["stream_id": "breath-7"])])
    expect(reader.seq == 0, "meta 不写 replay 缓冲，不能占 seq")
    expect(reader.streamId == "breath-7", "meta 带来流号")
    expect(accepted(events) == ["breath-7"], "meta 就是「服务端收下了」")
}

// ── 正文：累加、发段、seq 一帧一个 ────────────────────────────────────────
do {
    var reader = BeingStreamReader(sessionId: nil)
    // 照真实顺序来：POST 拿到 2xx 先亮「在思考」，正文才开始流。
    var events: [BeingStreamEvent] = []
    reader.begin { events.append($0) }
    events += run(&reader, [
        ("meta", ["stream_id": "b1"]),
        ("content_block_delta", ["delta": ["text": "待"]]),
        ("content_block_delta", ["delta": ["text": "定"]]),
    ])
    expect(reader.text == "待定", "正文按段拼起来")
    expect(reader.seq == 2, "两个正文帧 = 两个 seq，meta 不算")
    let deltas = events.compactMap { if case .delta(let t) = $0 { return t } else { return nil } }
    expect(deltas == ["待", "定"], "每段都吐给界面")
    expect(activities(events).last == .some(nil), "正文一开始流，状态行让位给正文")
    // **只在切换那一下发一次。** 每段正文都发一次 `.activity(nil)` 的话，一句话就是
    // 几十次整屏重画，屏幕上看着是抖。
    expect(activities(events).count == 2, "「在思考」一次 + 让位一次，不是每段一次，实际 \(activities(events).count)")
}

// ── 在想什么：以前被 default 吃掉，界面上只剩三个点 ───────────────────────
do {
    var reader = BeingStreamReader(sessionId: nil)
    let events = run(&reader, [
        ("reasoning", ["text": "aces 和 tonemapping 得一起做，"]),
        ("thinking", ["delta": ["text": "不然效果变两次"]]),
    ])
    let last = activities(events).last ?? nil
    expect(last?.label == "在思考", "reasoning / thinking 都是「在思考」")
    expect(last?.preview.contains("不然效果变两次") == true, "想的话给一小截，看得出它在想什么")
}

// ── 计时：同一个状态里不重开表 ────────────────────────────────────────────
//
// 屏幕上那个秒数是人判断「它是不是卡住了」的唯一线索。每帧都新建一个状态的话，
// 它永远停在 0s，那个数字就白给了。
do {
    var reader = BeingStreamReader(sessionId: nil)
    var seen: [BeingActivity?] = []
    reader.begin { if case .activity(let a) = $0 { seen.append(a) } }
    let started = (seen.last ?? nil)?.startedAt

    run(&reader, [
        ("reasoning", ["text": "先想一下，"]),
        ("reasoning", ["text": "再想一下"]),
    ]).forEach { if case .activity(let a) = $0 { seen.append(a) } }

    let now = seen.last ?? nil
    expect(now?.label == "在思考", "还在思考")
    expect(now?.startedAt == started, "同一个状态：表接着走，不重开")
    expect(now?.preview.contains("再想一下") == true, "预览跟着更新")

    // 换成工具了：这是新的一段，表重开。
    run(&reader, [("tool_use", ["name": "search_web", "input": ["query": "aces"]])])
        .forEach { if case .activity(let a) = $0 { seen.append(a) } }
    let tool = seen.last ?? nil
    expect(tool?.label == "在搜索" && tool?.startedAt != started, "换了状态才重开表")
}

// ── 工具：说人话，别露内部名字 ────────────────────────────────────────────
do {
    var reader = BeingStreamReader(sessionId: nil)
    let events = run(&reader, [
        ("tool_use", ["name": "run_command", "input": ["command": "npm test"]]),
    ])
    let now = activities(events).last ?? nil
    expect(now?.label == "在执行", "run_command → 在执行")
    expect(now?.arg == "npm test", "关键参数一眼可见")

    var other = BeingStreamReader(sessionId: nil)
    let unknown = run(&other, [("tool_use", ["name": "quantum_frobnicate", "input": [:]])])
    expect((activities(unknown).last ?? nil)?.label == "在行动", "不认识的工具一律「在行动」")
}

// ── 工具跑完回到在思考；触手 id 照旧捡得到 ────────────────────────────────
do {
    var reader = BeingStreamReader(sessionId: nil)
    let events = run(&reader, [
        ("tool_use", ["name": "prime_create", "input": ["topic": "aces"]]),
        ("tool_result", ["is_error": false, "content": "{\"agent_id\":\"t-42\"}"]),
    ])
    expect((activities(events).last ?? nil)?.label == "在思考", "工具跑完回到在思考")
    expect(reader.activity.first?.tentacleId == "t-42", "触手 id 还是捡得到")
}

// ── 房间号对不上：就地中断，别把别人的回复收进这条待办 ───────────────────
do {
    var reader = BeingStreamReader(sessionId: "room-1")
    var threw = false
    do {
        try reader.consume(event: "content_block_delta", data: ["session_id": "room-2"])
    } catch {
        threw = true
    }
    expect(threw, "房间号对不上必须抛")
}

// ── 接回：seq 用服务端给的，接着上一段往下拼 ─────────────────────────────
do {
    var live = BeingStreamReader(sessionId: "room-1")
    run(&live, [("meta", ["stream_id": "b9"]), ("content_block_delta", ["delta": ["text": "前半"]])])
    expect(live.seq == 1, "live 读到第 1 个事件就断了")

    // 断线之后从 ?after=1 接着读：服务端给的 seq 直接采信。
    var resumed = BeingStreamReader(sessionId: "room-1", seq: live.seq, streamId: live.streamId)
    var emitted: [BeingStreamEvent] = []
    try! resumed.consume(event: "content_block_delta", data: ["delta": ["text": "后半"]], seq: 2) {
        emitted.append($0)
    }
    expect(resumed.seq == 2, "游标跟着服务端走")
    expect(resumed.text == "后半", "接回来的只有断点之后那截，不重不漏")
    expect(resumed.streamId == "b9", "接的还是同一条流")
}

// ── error 帧：finish 时才翻脸，前面收到的正文不丢 ─────────────────────────
do {
    var reader = BeingStreamReader(sessionId: nil)
    run(&reader, [
        ("content_block_delta", ["delta": ["text": "半句"]]),
        ("error", ["message": "provider exploded"]),
    ])
    expect(reader.hasServerError, "服务端报错要记下")
    var threw = false
    do { _ = try reader.finish() } catch { threw = true }
    expect(threw, "带着 error 收尾必须抛")
    expect(reader.text == "半句", "抛归抛，已经收到的字还在")
}

// ── 回执走事件流：meta 带回追踪号，不用 being 在正文里抄 ───────────────────────
//
// 现在的地基（场景感知的约定）：请求-响应关联走 SSE 的
// meta，不再让 being 在回复开头写「会话id：… 请求id：…」。那种做法要它做格式翻译，
// 而且那几行字会进它的记忆。
do {
    var reader = BeingStreamReader(sessionId: "room-1", clientRef: "req-abc")
    run(&reader, [
        ("meta", ["stream_id": "b3", "scene_id": "kairos-mac-su-k7", "client_ref": "req-abc"]),
        ("content_block_delta", ["delta": ["text": "好，我看看。"]]),
    ])
    let reply = try! reader.finish()
    expect(reply.clientRef == "req-abc", "追踪号从 meta 拿回来")
    expect(reader.replySceneId == "kairos-mac-su-k7", "门牌回声也记下")
    expect(reply.text == "好，我看看。", "正文只有它说的话")
}

// ── 答的不是这一问：就地中断 ──────────────────────────────────────────────
do {
    var reader = BeingStreamReader(sessionId: "room-1", clientRef: "req-new")
    var threw = false
    do {
        try reader.consume(event: "meta", data: ["stream_id": "b4", "client_ref": "req-old"])
    } catch {
        threw = true
    }
    expect(threw, "追踪号对不上必须抛——那是别人那一问的回复")
}

// ── 老服务端不认这两个字段：照常跑，只是没有回执 ─────────────────────────
do {
    var reader = BeingStreamReader(sessionId: "room-1", clientRef: "req-abc")
    run(&reader, [("meta", ["stream_id": "b5"]), ("content_block_delta", ["delta": ["text": "在"]])])
    let reply = try! reader.finish()
    expect(reply.clientRef == nil, "没回传就是没有，不假装有")
    expect(reply.text == "在", "关联拿不到不影响收字")
}

// ── 第一段正文立刻上屏，一个字都不扣着 ────────────────────────────────────
//
// 以前要先等「会话id：<uuid>」那行 header 集齐（或者攒够 50 字确认它不来），
// 第一段才敢发给界面——为一个不该存在的协议头，每次回复都晚半拍。
do {
    var reader = BeingStreamReader(sessionId: nil)
    let events = run(&reader, [("content_block_delta", ["delta": ["text": "好"]])])
    let deltas = events.compactMap { if case .delta(let t) = $0 { return t } else { return nil } }
    expect(deltas == ["好"], "第一个字就上屏")
}

// ── 门牌：房间的名字是结构化字段，不是人话的一部分 ────────────────────────
do {
    let room = BeingScene.item(id: "7B3F-item", title: "素材库后台导出", being: "Being")
    expect(room.label == "Kairos·素材库后台导出", "门牌上写标题——being 要认的是标题不是 uuid")
    expect(room.id == BeingScene.item(id: "7B3F-item", title: "改了标题", being: "Being").id,
           "门牌号跟着待办走，标题改了还是同一间")

    let mail = BeingScene.round(KairosRoundKind.mail, being: "cotton")
    let ledger = BeingScene.round(KairosRoundKind.ledger, being: "cotton")
    expect(mail.id != ledger.id, "邮局和账本是两间")
    expect(mail.label == "Kairos 邮局", "机器房的门牌写明白是机器房")
    expect(mail.id.contains("cotton"), "对着哪个 being 也进门牌号——一个客户端可能对好几个")

    // being 名字是中文时不留空号：这东西是给机器对齐用的，越无聊越好。
    expect(BeingScene.slugify("名字") == "", "非 ascii 全丢掉")
    expect(BeingScene.main(being: "名字").id == "kairos-" + BeingScene.surface, "丢空了就只剩平台名")
    expect(BeingScene.ref("m").hasPrefix("m-"), "追踪号带前缀，一眼看得出是哪一趟")
}

// ── 关键参数：按 loom 那份优先级挑 ────────────────────────────────────────
do {
    expect(BeingActivity.keyArgument(from: ["query": "aces tonemapping"]) == "aces tonemapping", "查询词优先")
    expect(BeingActivity.keyArgument(from: ["file_path": "/a/b/KairosStore.swift"]) == "KairosStore.swift", "文件只要名字")
    expect(BeingActivity.keyArgument(from: ["url": "https://forum.d5render.cn/t/123"]) == "forum.d5render.cn", "链接只要域名")
    expect(BeingActivity.keyArgument(from: "{\"command\":\"ls -la\"}") == "ls -la", "入参是 JSON 字符串也认")
    expect(BeingActivity.keyArgument(from: ["depth": 3]) == "", "挑不出字符串就空着，不硬凑")
}

print("native stream tests: all checks passed")
