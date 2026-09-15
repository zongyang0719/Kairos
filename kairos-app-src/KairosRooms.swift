import Foundation

/// Kairos v2.3 · 渠道 = 房间（§三）
///
/// 每条待办一个房间，房间号就是 being 侧多 Session 的 `session_id`——两边同一个东西，
/// 不再有两套对话概念。房间**不是账本**：它只是通知 + 过程记录，整个删掉，
/// 账本 diff 自愈，什么都不少。所以这份状态是派生文件，留在本机 `~/.kairos/rooms.json`，
/// 不进 iCloud（v2.3 §五推论①）。
///
/// 三根管子（房间列表 / 系统消息写入 / 已读游标）**暂不开放给 being 侧**：
/// 房间列表 Kairos 本地自己有（账本就是待办清单）、系统消息走现有发送通道、
/// 已读游标就是本文件。origin / weight 在信封里带上，being 侧不认识也不影响。

enum KairosMessageOrigin {
    static let user = "user"
    static let app = "app"
    static let being = "being"
}

/// 规矩 5：未读分两级。渠道一多，不分级就是红点海。
enum KairosMessageWeight {
    /// 排序变化、字段补全、状态推进——写进房间可查，但不亮不计数。
    static let routine = "routine"
    /// 置 mine 的入场券、blocker、conflict、deadline 前置提醒——才计入未读、才亮。
    static let ask = "ask"
}

struct KairosRoomMessage: Codable, Hashable, Identifiable {
    /// change-id 幂等键（v2.2 已有，不变）。重复投递按这个去重。
    var id: String
    var itemID: String
    var origin: String
    var weight: String
    var text: String
    var createdAt: String
    /// 规矩 4：先文件后消息。消息发失败**不回滚文件**，留在这儿标记未送达，
    /// 下次连上补发；补不上也不致命，心跳 diff 自愈会补。
    var delivered: Bool

    init(
        id: String = UUID().uuidString,
        itemID: String,
        origin: String,
        weight: String,
        text: String,
        createdAt: String = KairosClock.now,
        delivered: Bool = false
    ) {
        self.id = id
        self.itemID = itemID
        self.origin = origin
        self.weight = weight
        self.text = text
        self.createdAt = createdAt
        self.delivered = delivered
    }
}

struct KairosRoom: Codable, Hashable {
    var itemID: String
    /// 已读游标：RFC3339 时间戳。每房间一个，客户端自己写、自己算未读。
    var readUpTo: String?
    var messages: [KairosRoomMessage] = []
    /// 这间房跟 being 交代过「这是哪条待办」没有。
    ///
    /// 本来是拿「房间里一条消息都没有」当判断的，但它不成立：**已经有来往的
    /// 房间永远等不到那行交代**——人类在一条聊过的待办里问「你能读到这条 todo 的标题吗」，
    /// being 答「我读到的就是你发来的这段话本身」。记一个显式的标记，老房间下一句就补上。
    var toldWhichItem: Bool = false

    /// 规矩 5：只数 ask 级，且只数别人说的。routine 再多也不亮。
    var unreadAskCount: Int {
        messages.filter {
            $0.weight == KairosMessageWeight.ask
                && $0.origin != KairosMessageOrigin.user
                && isAfterCursor($0.createdAt)
        }.count
    }

    init(itemID: String, readUpTo: String? = nil, messages: [KairosRoomMessage] = [], toldWhichItem: Bool = false) {
        self.itemID = itemID
        self.readUpTo = readUpTo
        self.messages = messages
        self.toldWhichItem = toldWhichItem
    }

    /// **必须手写。** Swift 合成的解码器**不认属性上的默认值**——老的 `rooms.json` 没有
    /// `toldWhichItem` 这个键，合成解码器会抛 keyNotFound，`KairosRooms.load()` 读不出就回
    /// `.empty`，**所有房间日志静默清空**。`roundSessions` 那次踩的就是这个坑（见下面那段注释），
    /// 2026-09-11 差点又踩一次——那天早上人类刚说过「往来的信息今天全都丢了」。
    /// 缺这个键 = 还没交代过，补一次比漏一次好。
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        itemID = try box.decode(String.self, forKey: .itemID)
        readUpTo = try box.decodeIfPresent(String.self, forKey: .readUpTo)
        messages = try box.decodeIfPresent([KairosRoomMessage].self, forKey: .messages) ?? []
        toldWhichItem = try box.decodeIfPresent(Bool.self, forKey: .toldWhichItem) ?? false
    }

    var hasUnreadAsk: Bool { unreadAskCount > 0 }

    var lastActivityAt: String? { messages.last?.createdAt }

    private func isAfterCursor(_ timestamp: String) -> Bool {
        guard let readUpTo else { return true }
        return timestamp > readUpTo // RFC3339 同一格式下字典序即时序
    }
}

/// 机器来回的名字，也是 `KairosRooms.roundSessions` 的键。
enum KairosRoundKind {
    static let mail = "mailround"
    static let ledger = "ledgerround"
}

struct KairosRooms: Codable, Hashable {
    static let protocolName = "kairos.rooms/1"
    /// 一个房间最多留多少条。房间是过程记录不是账本，超了就从头丢——
    /// 丢了不影响任何状态（§一铁律：房间整个删掉，账本 diff 自愈）。
    static let messageCap = 500

    var protocolVersion: String = KairosRooms.protocolName
    var rooms: [String: KairosRoom] = [:]
    /// 机器来回（邮局 / 账本）各自的固定房间号，`来回名 -> session_id`。
    ///
    /// BeingDesktop 的做法：client 自己生成 UUID、本地存、每次请求都带上。信息不串的
    /// 根子在这里——邮局的话永远落邮局那间，账本的话永远落账本那间，进不了任何一条
    /// 待办的房间，也进不了人类和 being 的主对话。以前这两趟发的是 `session_id: nil`，
    /// 机器流量全落进主对话里当噪音。
    var roundSessions: [String: String] = [:]

    static var empty: KairosRooms { KairosRooms() }

    init() {}

    enum CodingKeys: String, CodingKey {
        case protocolVersion, rooms, roundSessions
    }

    /// `roundSessions` 是后加的：老的 `rooms.json` 没这个键，缺了不能整份读不出来——
    /// 那会把所有房间日志静默清空（`load()` 读不出就回 `.empty`）。
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try box.decodeIfPresent(String.self, forKey: .protocolVersion) ?? Self.protocolName
        rooms = try box.decodeIfPresent([String: KairosRoom].self, forKey: .rooms) ?? [:]
        roundSessions = try box.decodeIfPresent([String: String].self, forKey: .roundSessions) ?? [:]
    }

    /// 某种机器来回的房间号。这台设备第一次用时生成，以后一直用同一个。
    mutating func roundSession(_ kind: String) -> String {
        if let existing = roundSessions[kind], !existing.isEmpty { return existing }
        let id = UUID().uuidString.lowercased()
        roundSessions[kind] = id
        return id
    }

    func room(_ itemID: String) -> KairosRoom {
        rooms[itemID] ?? KairosRoom(itemID: itemID)
    }

    func unreadAskCount(_ itemID: String) -> Int { room(itemID).unreadAskCount }

    /// 「事项亮提示」只亮 ask 级（v2.3 §四）：todo 上有动静但全是 routine 的，
    /// 不动它的视觉状态——排序位置的变化本身就是 routine 反馈。
    func hasUnreadAsk(_ itemID: String) -> Bool { room(itemID).hasUnreadAsk }

    var totalUnreadAsk: Int { rooms.values.reduce(0) { $0 + $1.unreadAskCount } }

    var undelivered: [KairosRoomMessage] {
        rooms.values.flatMap(\.messages).filter { !$0.delivered }
            .sorted { $0.createdAt < $1.createdAt }
    }

    mutating func append(_ message: KairosRoomMessage) {
        var room = room(message.itemID)
        // change-id 幂等：同一条重复投递只留一份。
        if let index = room.messages.firstIndex(where: { $0.id == message.id }) {
            room.messages[index] = message
        } else {
            room.messages.append(message)
        }
        if room.messages.count > Self.messageCap {
            room.messages.removeFirst(room.messages.count - Self.messageCap)
        }
        rooms[message.itemID] = room
    }

    mutating func markDelivered(_ messageID: String, in itemID: String) {
        guard var room = rooms[itemID],
              let index = room.messages.firstIndex(where: { $0.id == messageID }) else { return }
        room.messages[index].delivered = true
        rooms[itemID] = room
    }

    /// 撤掉一条。只用于「没发出去的那句重发」——发出去了的话就是过程记录，不删。
    mutating func remove(_ messageID: String, in itemID: String) {
        guard var room = rooms[itemID] else { return }
        room.messages.removeAll { $0.id == messageID }
        rooms[itemID] = room
    }

    /// 记下「这间房已经交代过是哪条待办了」。
    mutating func markToldWhichItem(_ itemID: String) {
        var room = room(itemID)
        guard !room.toldWhichItem else { return }
        room.toldWhichItem = true
        rooms[itemID] = room
    }

    mutating func markRead(_ itemID: String) {
        var room = room(itemID)
        room.readUpTo = KairosClock.now
        rooms[itemID] = room
    }

    /// 待办被删掉时顺手清房间。房间没有独立生命，不留孤儿。
    mutating func forget(_ itemID: String) { rooms.removeValue(forKey: itemID) }

    // MARK: - 持久化（本机派生文件，坏了就从空的重来，不阻塞账本）

    static func load() -> KairosRooms {
        guard let data = try? Data(contentsOf: KairosFiles.rooms),
              let value = try? JSONDecoder().decode(KairosRooms.self, from: data) else {
            return .empty
        }
        return value
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return }
        try? KairosFiles.writePrivate(data, to: KairosFiles.rooms)
    }
}
