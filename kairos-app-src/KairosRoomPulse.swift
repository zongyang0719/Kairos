import Foundation

/// 单子上一行的行尾：这条待办的房间此刻怎么样了。
///
/// 「being 不是状态」（09-08 裁决）——它是一口气，不是一个常驻的去处。所以这里**一个字都不进账本**：
/// 在答、在等，全是 store 内存里现成的活水（`liveReply` / `liveActivity` / 气泡上的 `queued`），
/// 气收了行尾自己就干净了。唯一落盘的是房间日志里两个数（`KairosRoom.beats / seenBeats`），
/// 为的是关掉 app 再打开，没看的回复还亮着。
///
/// 四种样子，前面的压过后面的：
/// - **在答**：being 手上正是这间房。会动的三个点 + 一个词（在思考 / 在搜索 / 在回复……），
///   词表和房间里那行（`BeingActivity.labels`）是同一张。
/// - **在等**：话还没到它手上——排队中、发送中。不动，淡一档。
/// - **没发出去**：这间房最近的动静停在「没发出去」上，而你还没回来看过。
/// - **没看**：being 答了（或者有话要你拍板），而你还没回来看过。
///
/// 前两种自己会消失；后两种**点进这条待办就消失**（`KairosStore.markRoomRead`）。
enum KairosRoomPulse: Equatable {
    /// `detail`：搜的词、跑的命令……没有就空着。只进 tooltip，不上行。
    case working(label: String, detail: String)
    case waiting(label: String)
    case unsent
    /// `asking`：是 being 在等你拍板（规则 5 的 ask），不只是答完了。
    case unread(asking: Bool)

    /// 纯判断，不碰 store——测试直接喂。
    ///
    /// - Parameters:
    ///   - liveText: 这间房正在流进来的回复（`KairosStore.liveReply`）。非 nil = being 这口气在这间房。
    ///   - sending: 已经开口、服务端还没说收下的那几句（`KairosStore.sendingMessageIDs`）。
    ///   - countsAsk: 「要你拍板」算不算数。已了结的那条不算——事情已经定了；
    ///     但你在里面问的话答完了照样亮，那是你自己要的回音。
    static func of(
        room: KairosRoom,
        liveText: String?,
        activity: BeingActivity?,
        sending: Set<String>,
        countsAsk: Bool
    ) -> KairosRoomPulse? {
        let lastSaid = room.lastUserMessage
        if let liveText {
            // 开口那一刻就有活水了，可服务端还没说收下——话其实还在路上，不能说它在想。
            if let lastSaid, sending.contains(lastSaid.id) { return .waiting(label: "发送中") }
            if let activity { return .working(label: activity.label, detail: activity.arg) }
            // 出字之后 being 那边不再报状态（`BeingStreamReader` 切到正文就清掉）。
            return .working(label: liveText.isEmpty ? "在思考" : "在回复", detail: "")
        }
        // 队列先进先出，排着的永远是这间房最后那几句——看最后一句就够了，不用翻整间房。
        if lastSaid?.queued == true { return .waiting(label: "排队中") }
        if room.hasUnseenBeat {
            if let lastSaid, !lastSaid.delivered, !sending.contains(lastSaid.id) { return .unsent }
            return .unread(asking: countsAsk && room.hasUnreadAsk)
        }
        if countsAsk, room.hasUnreadAsk { return .unread(asking: true) }
        return nil
    }
}

extension KairosStore {
    /// 这一行行尾该画什么。nil = 什么都不画。
    func roomPulse(for item: KairosItem) -> KairosRoomPulse? {
        KairosRoomPulse.of(
            room: rooms.room(item.id),
            liveText: liveReply[item.id],
            activity: liveActivity[item.id],
            sending: sendingMessageIDs,
            countsAsk: !item.isClosed
        )
    }

    /// `liveReply` 少了哪个键，哪间房的这一口气就收了——没发出去、没接住回复这种**没有回话落进来**的结果，
    /// 只有这里记得到（回话本身在 `KairosRooms.append` 里各记一拍）。
    ///
    /// **只由 `liveReply` 的 `didSet` 调。** 不去 `performSpeak` 那几条路上各记一笔：
    /// 那几条路各有各的收尾（202 追回复、断流接回），漏记一处就是一行永远不亮。
    ///
    /// **晚一拍再记**：断流时 `performSpeak` 退出先把键清掉，紧接着接回（`resumeStream`）又把它放回去——
    /// 那一下不是收气，being 还在往下说。接回那个任务比这里先排进主线程，所以等到这里执行时，
    /// 键要是又回来了，就不记。
    func noteTurnsEnded(since previous: [String: String]) {
        let ended = previous.keys.filter { liveReply[$0] == nil }
        guard !ended.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            var changed = false
            for key in ended where self.liveReply[key] == nil {
                changed = self.rooms.markBeat(key) || changed
            }
            if changed { self.rooms.save() }
        }
    }
}
