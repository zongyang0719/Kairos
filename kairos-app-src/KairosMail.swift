import Foundation

/// Beings Town 邮局（being 之间的私信）在 Kairos 这一侧的落点。
///
/// ## 为什么不是 Kairos 直接调 Town
///
/// Town 的 DM 接口（`POST /api/messages` / `GET /api/messages?with=…`）用的是 **IP 信任**：
/// `GET /api/channels/help` 原话是「IP Trust — automatic for beings via Heart.
/// Caddy injects x-town-client-ip」。被信任的是 being 的 Heart，不是人类的 Mac 或手机——
/// 从这台机器直接打过去只会拿到 `401 {"error":"missing credentials"}`（实测）。
/// Loom 那边也没有转发口子：`echo.beings.town/<being>` 只开了 status / chat/stream /
/// history / llm/* / stop / stream/active，没有 messages。
///
/// 所以邮件只能由 being 代取代发。剩下的问题是「用什么管子把邮件递给 Kairos」，
/// 答案在 v2.3 里已经写死了：**不用对话通道**。BeingClient 顶上那段注释说得很明白——
/// 机器对机器的流量不该经过对话通道。于是邮箱走和账本同一套地基：
///
///     Kairos/mailbox.json              being 是唯一写者。Town 邮箱的镜像。
///     Kairos/mail-outbox/<设备>.json    那台设备是唯一写者。人类写的、还没发出去的信。
///     ~/.kairos/mail-read.json         纯本机：每个对话读到哪儿了。
///
/// 每个文件一个写者，跟 `KairosOutbox` 是同一条规矩，iCloud 那套「后写的整份盖掉先写的」
/// 伤不到任何人。being 醒来时 `ledger/cli.js mail-pending` 取草稿、`act(http)` 发出去、
/// `mail-receipt` 写回执、`mail-sync` 把 Town 的收发件箱灌回来。
///
/// ## 一条边界
///
/// 收件箱是** being 的**，不是人类的（卷轴原话：「收件箱的主权在 being 手里」）。
/// Kairos 这一屏是人类看 being 的信、替 being 回信——发出去的落款是 being ，界面上要说清楚。

// MARK: - 一封信

/// 字段名照抄 Town 的 payload（`{id, sender, recipient, content, created_at, delivery_status}`），
/// 这样 `mail-sync` 把 Town 的返回原样存下来就行，中间不做翻译——少一层翻译少一个错位的地方。
struct KairosMailMessage: Codable, Hashable, Identifiable {
    var id: String
    var sender: String
    var recipient: String
    var content: String
    var createdAt: String
    /// delivered / rejected / failed，以及以后 Town 可能加的任何值。
    /// **原样透传**：不认识的状态照显示，不要在这里做白名单——邮局加个新状态
    /// 不该让 Kairos 把它显示成「未知」。
    var deliveryStatus: String?

    enum CodingKeys: String, CodingKey {
        case id, sender, recipient, content
        case createdAt = "created_at"
        case deliveryStatus = "delivery_status"
    }

    var date: Date? { KairosMailClock.parse(createdAt) }
}

/// Town 的时间戳是北京时间带偏移（`2026-09-07T21:30:00+08:00`），
/// Kairos 本地生成的是 `KairosClock.now` 的 Z 结尾。两种都要能解析，
/// 否则草稿和已发信混在一条对话里排序会乱。
enum KairosMailClock {
    private static let formatter: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime]
        return value
    }()

    private static let fractional: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return value
    }()

    static func parse(_ value: String) -> Date? {
        formatter.date(from: value) ?? fractional.date(from: value)
    }

    /// 排序用。解析不出来的排到最早——宁可让一封时间戳坏掉的信沉底，
    /// 也不要让它因为字符串比较跳到最上面。
    static func sortKey(_ value: String) -> Date {
        parse(value) ?? .distantPast
    }
}

// MARK: - 回执

/// being 替这台设备发完一封信之后写回来的东西。
/// 草稿被消费掉（水位推过去）之后，界面靠回执知道那封信到底发出去没有。
struct KairosMailReceipt: Codable, Hashable, Identifiable {
    var draftID: String
    var ok: Bool
    /// 成功时 Town 返回的 message_id；对上 `sent[]` 里那一封。
    var messageID: String?
    /// 成功时 Town 解析出来的收件人 being_id（可能和人类输入的显示名不同）。
    var recipient: String?
    /// 失败原因，原样带上 Town 的话（400 收件人有歧义 / 404 查无此人 / 网络挂了）。
    var error: String?
    var at: String
    /// 收件人回声：我给它的那封信写的是给谁。**不是 `recipient`**——那个是 Town 解析出来的
    /// being_id，这个是我发过去的原话。拿它跟 draft_id 对，防的是它把两封信的回执张冠李戴。
    var to: String?

    var id: String { draftID }

    enum CodingKeys: String, CodingKey {
        case draftID = "draft_id"
        case ok
        case messageID = "message_id"
        case recipient, error, at, to
    }

    init(
        draftID: String,
        ok: Bool,
        messageID: String? = nil,
        recipient: String? = nil,
        error: String? = nil,
        at: String = KairosClock.now,
        to: String? = nil
    ) {
        self.draftID = draftID
        self.ok = ok
        self.messageID = messageID
        self.recipient = recipient
        self.error = error
        self.at = at
        self.to = to
    }

    /// `at` 缺了就当此刻。合成的解码器要求它必填，而我们给 being 的骨架里从来没有这一栏——
    /// 它照着骨架回，整个 receipts 数组解不出来，连带整趟报「json 读不懂」，
    /// 邮箱镜像也一起没了。骨架和解码器对不上，错在我们这边。
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        draftID = try box.decode(String.self, forKey: .draftID)
        ok = try box.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        messageID = try box.decodeIfPresent(String.self, forKey: .messageID)
        recipient = try box.decodeIfPresent(String.self, forKey: .recipient)
        error = try box.decodeIfPresent(String.self, forKey: .error)
        at = try box.decodeIfPresent(String.self, forKey: .at) ?? KairosClock.now
        to = try box.decodeIfPresent(String.self, forKey: .to)
    }
}

// MARK: - 邮箱镜像（being 写，大家读）

struct KairosMailbox: Codable, Hashable {
    static let protocolName = "kairos.mailbox/1"
    /// 收发件箱各留多少封。Town 那边本来就只回最近 100 封，这里留一点余量。
    static let messageCap = 300
    /// 回执留多少条。草稿早就被剪掉了，回执只是给界面看个结果，不必永久保留。
    static let receiptCap = 200

    var protocolVersion: String = KairosMailbox.protocolName
    var beingID: String = ""
    var beingName: String = ""
    /// being 上一次真正问过 Town 的时间。界面上要显示——邮箱是镜像不是实时的，
    /// 不说清楚「什么时候照的镜子」，人会把陈旧当成没有新信。
    var syncedAt: String?
    var received: [KairosMailMessage] = []
    var sent: [KairosMailMessage] = []
    /// 每台设备的草稿消费到第几条。设备自己看水位、自己剪自己的草稿——
    /// 和账本 `sync.outbox_watermark` 同一条路子，消费方不去动别人的文件。
    var outboxWatermark: [String: Int] = [:]
    var receipts: [KairosMailReceipt] = []

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case beingID = "being_id"
        case beingName = "being_name"
        case syncedAt = "synced_at"
        case received, sent
        case outboxWatermark = "outbox_watermark"
        case receipts
    }

    static var empty: KairosMailbox { KairosMailbox() }

    var isSupportedProtocol: Bool { protocolVersion == KairosMailbox.protocolName }

    func receipt(for draftID: String) -> KairosMailReceipt? {
        receipts.first { $0.draftID == draftID }
    }
}

// MARK: - 草稿箱（这台设备写，being 读）

struct KairosMailDraft: Codable, Hashable, Identifiable {
    /// 单调递增，同一设备内唯一。水位比的就是它。
    var seq: Int
    var id: String
    /// 人类输入的收件人：being_id 或显示名都行，由 Town 去解析
    /// （being_id 精确 > 显示名精确 > 忽略大小写，必须唯一命中）。
    var recipient: String
    var content: String
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case seq, id, recipient, content
        case createdAt = "created_at"
    }

    init(
        seq: Int,
        id: String = UUID().uuidString,
        recipient: String,
        content: String,
        createdAt: String = KairosClock.now
    ) {
        self.seq = seq
        self.id = id
        self.recipient = recipient
        self.content = content
        self.createdAt = createdAt
    }
}

struct KairosMailOutbox: Codable, Hashable {
    static let protocolName = "kairos.mail-outbox/1"

    var protocolVersion: String = KairosMailOutbox.protocolName
    var deviceID: String
    var deviceName: String
    var updatedAt: String = KairosClock.now
    var drafts: [KairosMailDraft] = []
    /// 发过的最大 seq，**只增不减**。和 `KairosOutbox.lastSeq` 同一个理由：
    /// 剪枝会把已消费的删掉，从 drafts 现算就会重发一个 ≤ 水位的 seq，那封信从此永远发不出去。
    var lastSeq: Int = 0

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case deviceID = "device_id"
        case deviceName = "device_name"
        case updatedAt = "updated_at"
        case drafts
        case lastSeq = "last_seq"
    }

    init(deviceID: String, deviceName: String) {
        self.deviceID = deviceID
        self.deviceName = deviceName
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try box.decodeIfPresent(String.self, forKey: .protocolVersion)
            ?? KairosMailOutbox.protocolName
        deviceID = try box.decode(String.self, forKey: .deviceID)
        deviceName = try box.decodeIfPresent(String.self, forKey: .deviceName) ?? ""
        updatedAt = try box.decodeIfPresent(String.self, forKey: .updatedAt) ?? KairosClock.now
        drafts = try box.decodeIfPresent([KairosMailDraft].self, forKey: .drafts) ?? []
        lastSeq = try box.decodeIfPresent(Int.self, forKey: .lastSeq) ?? (drafts.map(\.seq).max() ?? 0)
    }

    @discardableResult
    mutating func append(recipient: String, content: String) -> KairosMailDraft {
        lastSeq += 1
        let draft = KairosMailDraft(seq: lastSeq, recipient: recipient, content: content)
        drafts.append(draft)
        updatedAt = KairosClock.now
        return draft
    }

    /// 水位说「你到第 N 条为止我都发过了」，那 N 条就可以删了。
    /// 我们是这个文件的唯一写者，删自己的东西不会跟谁打架。
    mutating func prune(sentThrough watermark: Int) {
        drafts.removeAll { $0.seq <= watermark }
    }

    /// 撤回一封还没被 being 拿走的信。拿走之后就撤不了了——那封信已经在路上。
    mutating func discard(_ draftID: String) {
        drafts.removeAll { $0.id == draftID }
        updatedAt = KairosClock.now
    }
}

// MARK: - 已读游标（纯本机）

/// 派生文件，v2.3 §五推论①：留在本机，不进 iCloud。
/// 「读到哪儿了」本来就是每台设备各自的事，飘过去只会互相打架。
struct KairosMailReadCursor: Codable, Hashable {
    static let protocolName = "kairos.mail-read/2"

    var protocolVersion: String = KairosMailReadCursor.protocolName
    /// 对话方 being_id → 读到的时间戳（RFC3339）。
    var threads: [String: String] = [:]
    /// 对话方 being_id → 了结到的时间戳（RFC3339）。
    ///
    /// 和「读到哪儿」是两件事，所以是两个游标：**看过 ≠ 处理完**。以前只有已读，
    /// 结果是信只会变细，永远不下单子，一直挂在界面里去不掉。
    /// 信也是待办，那就跟待办同一个词、同一个动作——了结。
    /// /1 的老文件解出来这一栏是空的，等于「一条都还没了结」，正是想要的。
    var done: [String: String] = [:]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case threads
        case done
    }

    init() {}

    /// 少一栏就当它是空的。合成的解码器**不认默认值**，`done` 一缺就整份解不出来——
    /// 盘上那份 /1 的老文件正是没有这一栏，那样等于把已读游标一起丢了，
    /// 所有看过的信一夜之间全变未读。加一栏不能是这个代价。
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        // 版本号一律记成当下这版：解出来的这份马上就要带着 done 一起存回去。
        _ = try box.decodeIfPresent(String.self, forKey: .protocolVersion)
        protocolVersion = KairosMailReadCursor.protocolName
        threads = try box.decodeIfPresent([String: String].self, forKey: .threads) ?? [:]
        done = try box.decodeIfPresent([String: String].self, forKey: .done) ?? [:]
    }

    func isUnread(_ message: KairosMailMessage, from correspondent: String) -> Bool {
        guard let readUpTo = threads[correspondent], let cursor = KairosMailClock.parse(readUpTo) else {
            return true
        }
        guard let at = message.date else { return true }
        return at > cursor
    }

    /// 这条对话了结了没有。**了结的是「到此为止」，不是这个人**——
    /// 之后再来信（或者自己又写了一封），比这个时间晚，它就自己回到单子上，
    /// 不用人记得去「重新打开」。这条规则是这个设计能成立的全部理由。
    func isDone(_ correspondent: String, latest: Date?) -> Bool {
        guard let mark = done[correspondent], let cursor = KairosMailClock.parse(mark) else { return false }
        guard let latest else { return true }
        return latest <= cursor
    }

    mutating func markRead(_ correspondent: String) {
        threads[correspondent] = KairosClock.now
    }

    /// 了结必然是看过了，两个游标一起推——不然会出现「已了结但仍未读」这种自相矛盾的行。
    mutating func markDone(_ correspondent: String) {
        let now = KairosClock.now
        threads[correspondent] = now
        done[correspondent] = now
    }

    mutating func reopen(_ correspondent: String) {
        done.removeValue(forKey: correspondent)
    }
}

// MARK: - 一条对话

/// 界面按「和谁」分组，不是一条平的信流。Town 的模型是平的（一封一封的 DM），
/// 但人脑不是——「Judy 说了什么」比「今天收到了几封信」有用得多。
struct KairosMailThread: Identifiable, Hashable {
    /// 对话方：不是 being 自己的那一头。
    var correspondent: String
    var entries: [KairosMailEntry]
    var unreadCount: Int
    /// 处理完了，从单子上下去了。新的一封信会把它带回来（见 `KairosMailReadCursor.isDone`）。
    var isDone: Bool = false

    var id: String { correspondent }
    var latest: KairosMailEntry? { entries.last }
    var hasUnread: Bool { unreadCount > 0 }
    /// 有没有还没发出去 / 发失败的。列表上要能一眼看见。
    var hasPending: Bool { entries.contains { $0.status == .pending } }
    var hasFailure: Bool { entries.contains { $0.status == .failed || $0.status == .rejected } }
}

/// 对话里的一格。三种来源混在一起按时间排：收到的、发出去的、还在草稿箱里的。
struct KairosMailEntry: Identifiable, Hashable {
    enum Direction: Hashable { case incoming, outgoing }

    /// 一封信在界面上的状态。`delivered` / `rejected` / `failed` 是 Town 的说法，
    /// `pending` 是 Kairos 自己的——草稿还在设备上，being 还没来拿。
    /// `rejected` 和 `failed` 是 Town 分开的两种，界面上也**不能合并**：
    /// 一个是对方不收（再发一百次也一样），一个是没送到（可以再试）。
    /// 合成一句「发送失败」，人只会一直重发一封永远发不出去的信。
    enum Status: Hashable {
        /// 还在这台设备的草稿箱里，等 being 下次醒来。
        case pending
        /// being 发出去了，Town 收下了。
        case delivered
        /// 对方拒收——收件箱的主权在对方手里，这是邮局承诺过的权利，不是故障。
        case rejected
        /// 没送到：收件人有歧义、查无此人、或者投递中途挂了。
        case failed
        /// Town 给了个我们不认识的状态，原样显示。
        case other(String)
        /// 收到的信没有「发送状态」这回事。
        case none
    }

    var id: String
    var direction: Direction
    var content: String
    var createdAt: String
    var status: Status
    /// 失败时说清楚为什么。不写原因的失败提示等于没提示。
    var detail: String?
    var isUnread: Bool
    /// 只有还在草稿箱里的信能撤回。
    var draftID: String?

    var date: Date { KairosMailClock.sortKey(createdAt) }
}

// MARK: - 组装

/// 把镜像 + 本机草稿 + 已读游标合成界面要的东西。
///
/// 纯函数，不碰文件——测试直接喂三个值进来就能验。
enum KairosMailAssembly {
    /// Town 的 delivery_status → 界面状态。认识的翻译，不认识的原样带走。
    static func status(fromDelivery value: String?) -> KairosMailEntry.Status {
        switch value?.lowercased() {
        case nil, "": .delivered  // 老数据没这个字段：既然进了 sent[]，就是发出去了
        case "delivered": .delivered
        case "rejected": .rejected
        case "failed": .failed
        case .some(let other): .other(other)
        }
    }

    static func threads(
        mailbox: KairosMailbox,
        drafts: [KairosMailDraft],
        cursor: KairosMailReadCursor,
        me: String
    ) -> [KairosMailThread] {
        var buckets: [String: [KairosMailEntry]] = [:]
        var unread: [String: Int] = [:]

        for message in mailbox.received {
            let who = message.sender
            let new = cursor.isUnread(message, from: who)
            buckets[who, default: []].append(KairosMailEntry(
                id: message.id,
                direction: .incoming,
                content: message.content,
                createdAt: message.createdAt,
                status: .none,
                detail: nil,
                isUnread: new,
                draftID: nil
            ))
            if new { unread[who, default: 0] += 1 }
        }

        for message in mailbox.sent {
            // 自己是发件人，对话方是收件人。being 的 being_id 和显示名都可能出现在
            // sender 上，所以判断谁是「对方」以 recipient 为准，别去猜 sender。
            let who = message.recipient
            let outcome = status(fromDelivery: message.deliveryStatus)
            buckets[who, default: []].append(KairosMailEntry(
                id: message.id,
                direction: .outgoing,
                content: message.content,
                createdAt: message.createdAt,
                status: outcome,
                // Town 的 sent[] 只给一个状态词，没有别的可说。把那个词再抄一遍
                // 当「原因」，屏幕上就是「没送到 · failed」——重复一次不等于说明白了。
                detail: nil,
                isUnread: false,
                draftID: nil
            ))
        }

        for draft in drafts {
            // 已经有回执的草稿：回执说了算。being 可能刚发完还没来得及把 Town 的
            // sent[] 灌回来，这时候界面要显示回执的结果，不是「待发送」。
            let receipt = mailbox.receipt(for: draft.id)
            let who = receipt?.recipient ?? draft.recipient
            let outcome: KairosMailEntry.Status
            switch receipt {
            case nil: outcome = .pending
            case .some(let value) where value.ok: outcome = .delivered
            default: outcome = .failed
            }
            buckets[who, default: []].append(KairosMailEntry(
                id: "draft:" + draft.id,
                direction: .outgoing,
                content: draft.content,
                createdAt: draft.createdAt,
                status: outcome,
                detail: receipt?.error,
                isUnread: false,
                draftID: outcome == .pending ? draft.id : nil
            ))
        }

        buckets.removeValue(forKey: me)

        return buckets
            .map { correspondent, entries in
                let sorted = entries.sorted { $0.date < $1.date }
                return KairosMailThread(
                    correspondent: correspondent,
                    entries: sorted,
                    unreadCount: unread[correspondent] ?? 0,
                    isDone: cursor.isDone(correspondent, latest: sorted.last?.date)
                )
            }
            // 新的在上。空对话不可能出现（能进 buckets 就至少有一封）。
            .sorted { ($0.latest?.date ?? .distantPast) > ($1.latest?.date ?? .distantPast) }
    }

    static func unreadCount(mailbox: KairosMailbox, cursor: KairosMailReadCursor) -> Int {
        mailbox.received.filter { cursor.isUnread($0, from: $0.sender) }.count
    }
}

// MARK: - 手机自己维护邮箱（手机单机之后）

/// 以前镜像是 being 写的文件、Kairos 只读。手机单机之后**没有共享文件**了——
/// being 够不着 iOS 沙盒，信只能经 Loom 那条线回来。于是这些「怎么把新拿到的信并进邮箱」
/// 的规则，得在 Swift 这边也有一份。
///
/// 与 Node 侧 `ledger/mail.js` 逐条对应（Mac 走文件那条路还在用它），
/// 两边同形，`tests/native-mail/main.swift` 与 `tests/mail.test.js` 用同一批向量对拍。
enum KairosMailMerge {
    static let messageCap = KairosMailbox.messageCap
    static let receiptCap = KairosMailbox.receiptCap

    /// 灌镜像。**缺哪半就不动哪半**——being 可能只取到一半（另一半失败了），
    /// 把没取到的当成空写进去，界面上是「信全没了」。
    static func applySync(
        _ mailbox: KairosMailbox,
        received: [KairosMailMessage]?,
        sent: [KairosMailMessage]?,
        beingID: String? = nil,
        beingName: String? = nil,
        at: String = KairosClock.now
    ) -> KairosMailbox {
        var next = mailbox
        if let received { next.received = newestFirstCap(received) }
        if let sent { next.sent = newestFirstCap(sent) }
        if let beingID, !beingID.isEmpty { next.beingID = beingID }
        if let beingName, !beingName.isEmpty { next.beingName = beingName }
        next.syncedAt = at
        return next
    }

    /// 镜像不是档案馆：超了只留最近的。
    static func newestFirstCap(_ messages: [KairosMailMessage]) -> [KairosMailMessage] {
        let sorted = messages.sorted { KairosMailClock.sortKey($0.createdAt) < KairosMailClock.sortKey($1.createdAt) }
        return sorted.count > messageCap ? Array(sorted.suffix(messageCap)) : sorted
    }

    /// 写回执，顺带把这台设备的水位推到「连续已回执」为止。
    ///
    /// 按连续算而不是取最大：being 要是跳着处理，取最大会把中间那封还没发的一起冲掉
    /// （设备看见水位就把草稿删了），那封信从此人间蒸发且没人知道。
    static func applyReceipts(
        _ mailbox: KairosMailbox,
        _ incoming: [KairosMailReceipt],
        outbox: KairosMailOutbox
    ) -> KairosMailbox {
        guard !incoming.isEmpty else { return mailbox }
        var next = mailbox
        var receipts = next.receipts.filter { existing in
            !incoming.contains { $0.draftID == existing.draftID }
        }
        receipts.append(contentsOf: incoming)

        let ids = Set(receipts.map(\.draftID))
        next.outboxWatermark[outbox.deviceID] = contiguousWatermark(
            outbox, receipted: ids, from: next.outboxWatermark[outbox.deviceID] ?? 0
        )

        // 剪回执：草稿还在的一律留着（界面靠它显示结果），其余留最近的。
        let live = Set(outbox.drafts.map(\.id))
        let kept = receipts.filter { live.contains($0.draftID) }
        var rest = receipts.filter { !live.contains($0.draftID) }
            .sorted { KairosMailClock.sortKey($0.at) < KairosMailClock.sortKey($1.at) }
        if rest.count > receiptCap { rest = Array(rest.suffix(receiptCap)) }
        next.receipts = rest + kept
        return next
    }

    static func contiguousWatermark(
        _ outbox: KairosMailOutbox,
        receipted: Set<String>,
        from current: Int
    ) -> Int {
        var mark = current
        for draft in outbox.drafts.sorted(by: { $0.seq < $1.seq }) {
            if draft.seq <= mark { continue }
            guard receipted.contains(draft.id) else { break }
            mark = draft.seq
        }
        return mark
    }

    /// 该交给 being 发的草稿：水位以上 **且** 还没有回执。
    /// 光看水位不够——回执写了但水位因为前面有空档没推上去时，重跑会把同一封再发一遍。
    static func pending(_ mailbox: KairosMailbox, outbox: KairosMailOutbox) -> [KairosMailDraft] {
        let receipted = Set(mailbox.receipts.map(\.draftID))
        let mark = mailbox.outboxWatermark[outbox.deviceID] ?? 0
        return outbox.drafts
            .filter { $0.seq > mark && !receipted.contains($0.id) }
            .sorted { $0.seq < $1.seq }
    }
}

// MARK: - being 跑完一趟带回来的东西

/// 缺的字段就是**这次没取到**，不是「空的」——两者在界面上天差地别，
/// 所以 received / sent 都是可选的，缺哪半就不动哪半。
struct KairosMailRound {
    var received: [KairosMailMessage]?
    var sent: [KairosMailMessage]?
    var receipts: [KairosMailReceipt] = []
    var beingID: String?
    var beingName: String?
    /// 这趟有什么不对劲：数目对不上、回执张冠李戴、有信没给回执。
    /// 不是错误（这趟照样并进去），但人得知道——不说，界面上就是「跑成了」。
    var notes: [String] = []
}

/// 「请 being 跑一趟」这个来回的**话术和解析**。纯逻辑，不碰网络也不碰文件，
/// 所以能单独编译进 `tests/native-mail/main.swift` 验——这一层最容易出错
/// （对面是个会客套、会换格式的 agent，不是 RPC 端点），也最该被测。
enum KairosMailRoundReply {
    static let protocolName = "bap.mailround/1"

    enum ParseError: LocalizedError {
        case noJSON(String)
        case badJSON(String)
        case wrongProtocol(String)
        case staleRound(sent: String, got: String)

        var errorDescription: String? {
            switch self {
            case .noJSON(let said): "对面没有回一个 json 块。它说的是：\(said)"
            case .badJSON(let why): "对面回的 json 读不懂：\(why)"
            case .wrongProtocol(let got):
                "对面回的不是邮局这一趟的东西（protocol = \(got.isEmpty ? "没给" : got)），没敢当成空邮箱。"
            case .staleRound(let sent, let got):
                "对面答的是别的趟（我问的是 \(sent)，它回的是 \(got.isEmpty ? "没给编号" : got)），已丢弃。"
            }
        }
    }

    /// 送给 being 的待发清单。**不把 `KairosMailDraft` 整个丢过去**：seq / created_at
    /// 是这台设备自己的记账，它用不着，写在正文里只会让它以为也要回。
    struct Outgoing: Encodable {
        var draftID: String
        var to: String
        var content: String

        enum CodingKeys: String, CodingKey {
            case draftID = "draft_id"
            case to, content
        }
    }

    /// 请求正文。**只说这一趟的事**：编号、要跑的三步、回复骨架。
    /// 规矩（协议、draft_id 跨趟不变、原样返回）写在 `BEING-RULES.md` 的
    /// 「Kairos 直连的两趟」那节，一次性的东西不该每趟重发。
    ///
    /// 正文里避开裸反引号（裸反引号会搅乱围栏配对，整趟白跑）。
    static func request(drafts: [KairosMailDraft], round: String) -> String {
        let outgoing: String
        if drafts.isEmpty {
            outgoing = "这次没有要发的信。"
        } else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let list = drafts.map { Outgoing(draftID: $0.id, to: $0.recipient, content: $0.content) }
            let body = (try? encoder.encode(list)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            outgoing = """
            这几封是我托你发的，每封都 act(http) POST https://beings.town/api/messages \
            {"recipient":…,"content":…}，成败都要给回执：
            \(body)
            """
        }

        return """
        去一趟邮局（Kairos 直连，不走 Mac 上的文件）。
        规矩在 BEING-RULES.md 的「Kairos 直连的两趟」那节，这里只说这一趟的事。

        本趟编号 \(round)

        1. act(http) GET https://beings.town/api/messages
        2. act(http) GET https://beings.town/api/messages?with=sent
        3. \(outgoing)

        然后只回一个 json 代码块，块外别写任何字：

        ```json
        {"protocol":"\(protocolName)","round":"\(round)",
         "being_id":"…","being_name":"…",
         "received": <第 1 步的原样返回>,
         "sent": <第 2 步的原样返回>,
         "receipts":[{"draft_id":"…","to":"收件人原样抄回来","ok":true,"message_id":"…","recipient":"…"},
                     {"draft_id":"…","to":"…","ok":false,"error":"404 being not found"}]}
        ```

        - 编号原样抄回来，不是这一趟的我整趟不收。
        - draft_id 跨趟不变：这趟可能是重发（你刚才忙、我等了一会儿再来的），
          投过的别再投第二次，把上次的回执原样给我。
        - 上面给你几封，回执就得有几条；每条把 to 原样抄一遍，我拿它跟 draft_id 对。
        - received / sent 要 Town 回给你的原样返回，连 count 一起，别自己拼、别精简。
          哪一步没取到，那个字段就整个别给——拿空数组顶上，我这边看到的是「信全没了」。
        - /api/messages 只管 being 之间的私信。grove 通知、篝火 @、卷轴评论别塞进来。
        """
    }

    /// 解一趟回信。`drafts` 是我们这趟托它发的那些——回执要拿它核对，
    /// 核不上的丢掉：一条我没托它发过的回执，要么是它记串了，要么是它编的，
    /// 两种都不该进邮箱。
    static func parse(
        _ text: String,
        round: String,
        drafts: [KairosMailDraft],
        correlated: Bool = false
    ) throws -> KairosMailRound {
        guard let data = extractJSONObject(from: text) else {
            throw ParseError.noJSON(String(text.prefix(200)))
        }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw ParseError.badJSON(error.localizedDescription)
        }
        guard payload.protocolName == protocolName else {
            throw ParseError.wrongProtocol(payload.protocolName ?? "")
        }
        // 趟号对不对，先看传输层：SSE 的 meta 把 `client_ref` 原样带回来了，
        // 那这条流就是答这一问的，正文里抄不抄那个号都不重要（场景感知：
        // 关联信息走结构化字段，别让 being 做格式翻译）。meta 没带回来时——老服务端、
        // 或者这个口子还没上线——才退回去认正文里那个号，认不上整趟不收。
        if let echoed = payload.round, echoed != round {
            throw ParseError.staleRound(sent: round, got: echoed)
        }
        if payload.round == nil, !correlated {
            throw ParseError.staleRound(sent: round, got: "")
        }

        var notes: [String] = []

        // Town 自己回的 count 是白给的一道校验：它要是「顺手」帮我精简了几封再贴回来，
        // 数目就对不上。对不上就当这一步没取到——镜像宁可旧，不能被裁剪过的那份盖掉。
        func intact(_ list: MessageList?, _ which: String) -> [KairosMailMessage]? {
            guard let list else { return nil }
            guard list.isIntact else {
                notes.append("\(which)它说有 \(list.count ?? 0) 封、实际给了 \(list.messages.count) 封，对不上，这一步当没取到")
                return nil
            }
            return list.messages
        }

        var receipts: [KairosMailReceipt] = []
        for receipt in payload.receipts ?? [] {
            guard let draft = drafts.first(where: { $0.id == receipt.draftID }) else {
                notes.append("回执里有我没托它发的信（\(receipt.draftID)），丢掉了")
                continue
            }
            if let echo = receipt.to, !sameRecipient(echo, draft.recipient) {
                notes.append("给「\(draft.recipient)」那封信的回执上写的是「\(echo)」，对不上，丢掉了")
                continue
            }
            receipts.append(receipt)
        }
        let missing = drafts.filter { draft in !receipts.contains { $0.draftID == draft.id } }
        if !missing.isEmpty {
            notes.append("\(missing.count) 封信没给回执，还在草稿箱里，下次再问")
        }

        return KairosMailRound(
            received: intact(payload.received, "收件箱"),
            sent: intact(payload.sent, "发件箱"),
            receipts: receipts,
            beingID: payload.beingID,
            beingName: payload.beingName,
            notes: notes
        )
    }

    /// 收件人回声比对。大小写和前后空白不算数——Town 自己解析收件人时也是这么宽的。
    static func sameRecipient(_ echo: String, _ sent: String) -> Bool {
        echo.trimmingCharacters(in: .whitespaces).lowercased()
            == sent.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// 抠块的实现和账本那趟共用（`KairosJSONBlock`）——两边对面是同一个会客套的 agent，
    /// 抠错的后果也一样（整趟白跑）。名字留在这儿，既有的测试照着它写。
    static func extractJSONObject(from text: String) -> Data? {
        KairosJSONBlock.extract(from: text)
    }

    /// Town 回的是 `{"count":N,"messages":[…]}`；有人图省事直接给数组也认。
    struct MessageList: Decodable {
        var count: Int?
        var messages: [KairosMailMessage]

        /// 直接给数组时没有 count 可对，那就不对——`nil` 是「没这一栏」，不是「0」。
        var isIntact: Bool { count == nil || count == messages.count }

        init(from decoder: Decoder) throws {
            if let array = try? [KairosMailMessage](from: decoder) {
                messages = array
                count = nil
                return
            }
            let box = try decoder.container(keyedBy: CodingKeys.self)
            messages = try box.decodeIfPresent([KairosMailMessage].self, forKey: .messages) ?? []
            count = try box.decodeIfPresent(Int.self, forKey: .count)
        }

        enum CodingKeys: String, CodingKey { case messages, count }
    }

    struct Payload: Decodable {
        var protocolName: String?
        var round: String?
        var received: MessageList?
        var sent: MessageList?
        var receipts: [KairosMailReceipt]?
        var beingID: String?
        var beingName: String?

        enum CodingKeys: String, CodingKey {
            case protocolName = "protocol"
            case round, received, sent, receipts
            case beingID = "being_id"
            case beingName = "being_name"
        }
    }
}
