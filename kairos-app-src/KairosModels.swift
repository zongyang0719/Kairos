import Foundation

/// 一条待办只剩一个「走到哪了」的维度。
///
/// **球权（`state`：mine / being / closed）撤了，并进这里。** 它名义上说「下一步该谁动」，
/// 实际上是个临时字段：UI 早就不拿它分段（`KairosWorkspace.matchesOrderKey` 那句
/// 「球权是临时状态、不拿来分段」），没有任何一颗按钮能把一条放进 `being`，
/// 105 条里只有 2 条停在那儿。它真正在做的只有一件事——这条完没完。那是状态的活。
///
/// 词汇照常见 todolist：未开始 / 进行中 / 待定 / 已完结。
/// 不认识的值展示层按未开始处理，但原样存着（以后可能自定义）。
/// 「谁在办」写 `owner`，不是状态：谁在做和做到哪是两件事。
enum KairosStatus {
    static let todo = "todo"
    static let doing = "doing"
    static let pending = "pending"
    static let closed = "closed"

    /// 全部值集（校验、归一用）。Node 侧 `ledger/store.js` 的 `STATUSES` 逐字相同。
    static let all = [doing, todo, pending, closed]

    /// 还开着的那几个。分组和状态菜单按这个顺序排——**已完结是抽屉，不和它们并排**，
    /// 由「了结」那颗按钮和 `showClosed` 管。
    static let open = [doing, todo, pending]

    static func normalized(_ raw: String) -> String {
        all.contains(raw) ? raw : todo
    }

    static func isClosed(_ raw: String) -> Bool {
        normalized(raw) == closed
    }

    static func label(_ raw: String) -> String {
        switch normalized(raw) {
        case doing: "进行中"
        case pending: "待定"
        case closed: "已完结"
        default: "未开始"
        }
    }
}

/// 渠道：一条待办从哪来。`todo` = 账本直接建的，其余是 Town 的渠道。
/// 不认识的值展示层按 `todo` 处理但原样保存。
enum KairosSource {
    static let todo = "todo"
    static let inbox = "inbox"
    static let bonfire = "bonfire"
    static let fireside = "fireside"

    static let all = [todo, inbox, bonfire, fireside]

    /// 只有炉火能带名字：`fireside:炉火名`。
    /// 炉火有很多个，得说清是哪一个；篝火是全局的、只有一个，和待办、邮局一样裸写。
    /// Node 侧 `NAMED_SOURCES` 同名同序。
    static let named = [fireside]

    /// 合法不合法。裸渠道随便哪个都行；带冒号的只有炉火能带，且名字不能是空的。
    /// Node 侧 `ledger/store.js` 的 `isValidSource` 同一套——同一个 being 走 CLI 那条路
    /// 写错会被顶回来，走 Loom 那条路没道理放行。
    static func isValid(_ raw: String) -> Bool {
        let parts = raw.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return all.contains(raw) }
        return named.contains(String(parts[0])) && !parts[1].trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 渠道类型。图标、筛选、归类都只看它——`fireside:演示炉火` 和裸 `fireside` 一样对待。
    static func normalized(_ raw: String) -> String {
        let channel = String(raw.split(separator: ":", maxSplits: 1).first ?? "")
        return all.contains(channel) ? channel : todo
    }

    /// 冒号后面那个具体的篝火/炉火名字，没有就是 nil。
    /// 名字是空的（`fireside:`）也当没有——split 会把空的那半丢掉，count 到不了 2。
    static func name(_ raw: String) -> String? {
        let parts = raw.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, named.contains(String(parts[0])) else { return nil }
        let name = parts[1].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// 屏幕上写哪几个字：有具体名字就写名字（是哪一个炉火），否则写渠道名。
    /// 不写成「炉火 · 演示炉火」——图标已经说了是哪一类，标签再重复一遍是废话。
    static func label(_ raw: String) -> String {
        if let name = name(raw) { return name }
        switch normalized(raw) {
        case inbox: return "信"
        case bonfire: return "篝火"
        case fireside: return "炉火"
        default: return "待办"
        }
    }
}

/// 档位（契约 §三）：顺序即高低，P0 是例外里的例外。这里只管词汇，颜色归各自的界面层
/// （iOS 在 ItemsCompose.swift、Mac 在 KairosViews.swift 的 KairosMacTier），
/// 因为本文件只 import Foundation，碰不到 Color。
/// 不认识的值一律当 P3——列表里不能有条目因为字段坏了就消失。
enum KairosTier {
    static let all = ["P0", "P1", "P2", "P3"]

    static func normalized(_ raw: String) -> String {
        all.contains(raw) ? raw : "P3"
    }
}

/// 一个可以点的判断。`label` 是他点的那句，`detail` 说清楚选它意味着什么。
struct KairosOption: Codable, Hashable, Identifiable {
    var label: String
    /// **可选**：列不出代价时可以不给。Node 侧 `isValidOptions` 也是这么判的。
    var detail: String

    var id: String { label + "\u{0}" + detail }

    init(label: String, detail: String = "") {
        self.label = label
        self.detail = detail
    }

    /// **缺字段不能整条读不出来。** 和 `KairosCounterpart` / `KairosUtterance` 同一条规矩，
    /// 而这里更硬：`items` 不是 lossy 解码，一格 option 抛出去，整本账 105 行一起读不出来，
    /// 界面上只剩「账本损坏」。实测过——Node 的校验说 `detail` 可选、这边却
    /// 要求必填，being 写一条不带 detail 的选项就能把整本账锁死，而且 CLI 那头一声不吭。
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        label = try box.decodeIfPresent(String.self, forKey: .label) ?? ""
        detail = try box.decodeIfPresent(String.self, forKey: .detail) ?? ""
    }
}

/// 一条真源链接（`evidence`）。
struct KairosLink: Codable, Hashable, Identifiable {
    var label: String
    var url: String

    var id: String { label + "\u{0}" + url }

    init(label: String, url: String) {
        self.label = label
        self.url = url
    }

    /// 同 `KairosOption`：缺字段作废这一格，不能牵连整本账。
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        label = try box.decodeIfPresent(String.self, forKey: .label) ?? ""
        url = try box.decodeIfPresent(String.self, forKey: .url) ?? ""
    }
}

/// 一行的标题怎么写：有对方就把名字放在最前面，用中点分开。
///
/// **名字不进 `title`**——写进去会和 `counterpart.name` 重复，而且人改过标题之后
/// 名字就钉死在里面了。两个平台共用这一份，免得一边画了一边没画。
enum KairosItemRowTitle {
    static func line(_ item: KairosItem) -> AttributedString {
        guard let who = item.counterpart?.name.trimmingCharacters(in: .whitespaces), !who.isEmpty else {
            return AttributedString(item.title)
        }
        // **标题本来就以名字开头，就别再叠一遍。** being 写的标题常常是「Judy 问周四那版……」，
        // 前面再加一个「Judy · 」就成了「Judy · Judy 问周四那版……」。
        // 这时只把标题里那个名字加粗，名字仍然是一眼能扫到的索引。
        if item.title.hasPrefix(who) {
            var name = AttributedString(who)
            name.inlinePresentationIntent = .stronglyEmphasized
            return name + AttributedString(String(item.title.dropFirst(who.count)))
        }
        var name = AttributedString(who + " · ")
        name.inlinePresentationIntent = .stronglyEmphasized
        return name + AttributedString(item.title)
    }
}

/// 顶上那三段。
///
/// **分的依据是「对面有没有人在等你」，不是渠道。** 每天回一百个人的人，脑子里第一个问题
/// 不是「今天有什么事」，是「谁在等我」。渠道是管子——篝火里一条「周五 API 要改」没人等你回，
/// 那是待办；Judy 问「周四那版能不能先看」有人等你回，那是消息。管子退成行上一个小图标。
///
/// 以前这里分的是来源（全部 / 待办 / 信 / 篝火 / 炉火五段），那是按管子分的。
enum KairosMacScope: String, CaseIterable, Codable, Identifiable {
    case all, todo, message

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .todo: "待办"
        case .message: "消息"
        }
    }

    func allows(_ item: KairosItem) -> Bool {
        switch self {
        case .all: true
        case .todo: !item.isMessage
        case .message: item.isMessage
        }
    }
}

/// 对方是谁。
///
/// **一行是消息还是待办，看有没有对方，不看渠道。** 篝火里一条「周五 API 要改」没人
/// 等你回，那是待办；Judy 问「周四那版能不能先看」有人等你回，那是消息。渠道（`source`）
/// 只决定行上那个小图标——渠道是管子，人才是索引。
///
/// 每天回一百个人的人，脑子里第一个问题不是「今天有什么事」，是「谁在等我」。
/// 这个字段就是那个问题在数据上的样子：它同时决定**归哪段、行怎么显示、回给谁**。
struct KairosCounterpart: Codable, Hashable {
    /// 行上的索引。一百个人的时候名字是唯一能快速扫的东西，所以消息行的标题以它开头。
    var name: String
    /// **真地址**，回信要用：Town 私信是 being_id，炉火是炉火名，篝火是那条帖子的 id。
    /// 光有名字回不了信——这是「输入框回给对方」能不能成立的全部依据。
    var id: String
    /// 从哪条管子回去。值集和 `source` 同一套（inbox / bonfire / fireside）。
    /// 同一个人同时在两条管子里找你，那是两行，不是一行。
    var channel: String
    /// 一个人 / 一个群 / 一条帖子。决定房间里怎么称呼、行上画什么。
    var kind: String

    static let person = "person"
    static let group = "group"
    static let post = "post"
    static let kinds = [person, group, post]

    init(name: String, id: String, channel: String, kind: String = KairosCounterpart.person) {
        self.name = name
        self.id = id
        self.channel = channel
        self.kind = kind
    }

    /// 缺字段不能整条读不出来：读不出 = 这一行从消息掉回待办，人会以为「谁在等我」少了一个。
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        name = try box.decodeIfPresent(String.self, forKey: .name) ?? ""
        id = try box.decodeIfPresent(String.self, forKey: .id) ?? ""
        channel = try box.decodeIfPresent(String.self, forKey: .channel) ?? KairosSource.inbox
        kind = try box.decodeIfPresent(String.self, forKey: .kind) ?? KairosCounterpart.person
    }

    /// 名字和地址都空 = 没有对方。只有名字没有地址仍然算消息（能看见谁在等你），
    /// 只是回不了信——界面上要说清楚，不能装作能回。
    var isEmpty: Bool { name.isEmpty && id.isEmpty }
    var canReply: Bool { !id.isEmpty }
    /// 一个人在一条管子里只有一行。合成 id 时用它。
    var rowKey: String { "\(channel):\(id.isEmpty ? name : id)" }
}


/// 结构化字段坏了，**作废这一格，别牵连整条、更别牵连整本账**。
///
/// 2026-09-13 这条是拿一整天的工作换来的：being 用 CLI 写 `thread` 时把
/// `[{…}]` 写成了**一段 JSON 字符串**（双重编码）。`decodeIfPresent` 只在「键不存在」时
/// 返回 nil，**类型对不上是抛异常**——于是 107 条待办里两条的一个字段坏了，
/// 整本账解不出来，Mac 上那一屏显示「没有待办」，还顺手进了写保护。
/// `store.js` 里那句「不合格就整个字段作废，不牵连整条」写了很久，但 Swift 侧一直没照做。
///
/// 两步：先按正常类型解；再试「它是不是一段 JSON 字符串」（双重编码是最常见的写错法，
/// 能捞回来就捞）；还不行就当这一格没有。
extension KeyedDecodingContainer {
    func lossy<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        if let value = try? decodeIfPresent(type, forKey: key) { return value }
        if let text = try? decodeIfPresent(String.self, forKey: key),
           let data = text.data(using: .utf8),
           let salvaged = try? JSONDecoder().decode(type, from: data) {
            return salvaged
        }
        return nil
    }
}

/// 往来里的一句话：谁、什么时候、说了什么。
///
/// 给多人渠道用（炉火像个小群，篝火是一条帖子底下的串）。**一段长 excerpt 是死的，
/// 一串带说话人的话是活的**——「长上下文要不要切开」的答案不是按长度切，是按「谁说的」切。
/// 私信的往来在 `mailbox.json` 镜像里，不重复存进这里。
struct KairosUtterance: Codable, Hashable {
    var who: String
    var at: String
    var text: String

    init(who: String, at: String, text: String) {
        self.who = who
        self.at = at
        self.text = text
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        who = try box.decodeIfPresent(String.self, forKey: .who) ?? ""
        at = try box.decodeIfPresent(String.self, forKey: .at) ?? ""
        text = try box.decodeIfPresent(String.self, forKey: .text) ?? ""
    }
}

struct KairosItem: Codable, Hashable, Identifiable {
    var id: String
    var localRev: Int
    var syncedLocalRev: Int
    var beingRev: Int
    var remoteKnown: Bool
    var title: String
    var summary: String
    /// being 消化过的背景：来龙去脉、现在卡在哪、它的判断。给人看的一段话，手机详情页拿它开场。
    /// 和 `summary`（一句是什么，列表副行用）是两种颗粒度，不重复。
    var brief: String
    var reason: String
    /// 要你判断什么。`options` 是它做到位的形态——being 列几个可以点的判断，人扫一眼点一个；
    /// `ask` 是退路：列不出选项时至少把问题说清楚。两个都空 = 把活原样退回给人。
    var ask: String
    var options: [KairosOption]
    var tier: String
    /// 走到哪了，也包括完没完：`KairosStatus`。球权并在这里。
    /// 和 `tier` 一样是 being 定的维度，人也能改。
    var status: String
    /// 属于哪个项目（名字，空 = 不属于任何项目）。第三个维度：
    /// 照 Things 的 Project / 提醒事项的列表。being 和人都能定；项目清单本身在 `workspace.projects`。
    var project: String
    /// 从哪个渠道来的（being 定）：`KairosSource`。`todo` = 账本直接建的；`inbox` / `bonfire` / `fireside` = Town 的渠道。
    var source: String
    /// 源头原话，一字不改。和 `summary`（being 概括的一句）、`brief`（being 消化的来龙去脉）都不一样——
    /// 它是给人对着验证 being 有没有读偏的，也保留 being 可能滤掉的上下文。纯展示，不跳转。可能很长。
    var excerpt: String
    var updatedAt: String
    var evidence: [KairosLink]
    var lastCommandId: String?
    /// Best-effort tentacle/session handle captured client-side from a `tool_use`/`tool_result`
    /// pair during a `delegate` reply. Informational only — not part of the synced payload,
    /// never round-tripped to Being, never affects `isPending`. See KAIROS-CONTRACT.md.
    var tentacleId: String?
    /// 规矩 2（v2.3 §二）：字段级写者标记 `字段名 -> human | being`。
    /// 人类**新建之后**显式改过的字段记 human，Being 心跳写入时必须跳过——
    /// 「自动同步」永远没有资格替人撤销人刚做的决定。新建时填的初值不算手动改
    /// （v2.3 §五的边界），所以 `.created` 不盖戳，只有 `.edited` 才盖。
    /// 人在这条待办的房间里再说一句话 = 新的用户信号，锁随之解开。
    var lastWriter: [String: String]
    /// 渠道 = 房间（v2.3 §三）：这条待办对应的 being 房间号，与 being 侧多 Session
    /// 用**同一个** session_id，不再有两套对话概念。空 = 还没开过口（零消息渠道合法）。
    var sessionId: String?
    /// 对方。**空 = 待办**（欠自己一个动作），**有 = 消息**（欠人一个回复）。
    var counterpart: KairosCounterpart?
    /// 往来（炉火 / 篝火这类多人渠道）。见 `KairosUtterance`。
    var thread: [KairosUtterance]

    /// 老账本（/1、/2）里的球权，**只为迁移活着**：解码时接住，`migratedToMergedStatus`
    /// 折进 `status` 之后清空，永远不编码、不进 `business`、不进 payload。
    /// 没有它的话，去掉 `state` 这个 CodingKey 就等于解码时静默丢值——
    /// 87 条已了结的会在人眼前重新打开，而且不报错。
    var legacyState: String?

    /// 这一行是不是消息。
    var isMessage: Bool { counterpart?.isEmpty == false }

    /// 完了没有。以前是 `state == closed`，现在是状态的一个值。
    var isClosed: Bool { KairosStatus.isClosed(status) }

    /// 这一行还等着你动手吗。**「进行中」不算**——消息行上的进行中是「写好了等 being 发出」，
    /// 球已经不在你手上；已了结更不算。顶上那个「几个人在等你」数的就是这个。
    var isWaitingOnMe: Bool {
        let status = KairosStatus.normalized(status)
        return status != KairosStatus.closed && status != KairosStatus.doing
    }

    /// 搜索面。**必须带上对方的名字**——消息行的名字不在 `title` 里（是行自己画在前面的），
    /// 不加进来的话搜「Judy」找不到 Judy 那一行，而名字恰恰是一百个人时唯一的索引。
    var searchText: String {
        [title, summary, brief, reason, ask,
         counterpart?.name ?? "", counterpart?.id ?? ""]
            .joined(separator: " ")
            .lowercased()
    }

    enum CodingKeys: String, CodingKey {
        case id, localRev, syncedLocalRev, beingRev, remoteKnown
        case title, summary, brief, reason, ask, options
        case tier, status, project, source, excerpt, evidence, lastCommandId, tentacleId
        case lastWriter, sessionId, counterpart, thread
        case updatedAt = "updated_at"
        case legacyUpdated = "updated"
        case legacyState = "state"
    }

    init(
        id: String = UUID().uuidString,
        localRev: Int = 1,
        syncedLocalRev: Int = 0,
        beingRev: Int = 0,
        remoteKnown: Bool = false,
        title: String = "",
        summary: String = "",
        brief: String = "",
        reason: String = "",
        ask: String = "",
        options: [KairosOption] = [],
        tier: String = "P3",
        status: String = KairosStatus.todo,
        project: String = "",
        source: String = KairosSource.todo,
        excerpt: String = "",
        updatedAt: String = KairosClock.now,
        evidence: [KairosLink] = [],
        lastCommandId: String? = nil,
        tentacleId: String? = nil,
        lastWriter: [String: String] = [:],
        sessionId: String? = nil,
        counterpart: KairosCounterpart? = nil,
        thread: [KairosUtterance] = []
    ) {
        self.id = id
        self.localRev = localRev
        self.syncedLocalRev = syncedLocalRev
        self.beingRev = beingRev
        self.remoteKnown = remoteKnown
        self.title = title
        self.summary = summary
        self.brief = brief
        self.reason = reason
        self.ask = ask
        self.options = options
        self.tier = tier
        self.status = status
        self.project = project
        self.source = source
        self.excerpt = excerpt
        self.updatedAt = updatedAt
        self.evidence = evidence
        self.lastCommandId = lastCommandId
        self.tentacleId = tentacleId
        self.lastWriter = lastWriter
        self.sessionId = sessionId
        self.counterpart = counterpart
        self.thread = thread
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(String.self, forKey: .id)
        localRev = try box.decodeIfPresent(Int.self, forKey: .localRev) ?? 0
        syncedLocalRev = try box.decodeIfPresent(Int.self, forKey: .syncedLocalRev) ?? 0
        beingRev = try box.decodeIfPresent(Int.self, forKey: .beingRev) ?? 0
        remoteKnown = try box.decodeIfPresent(Bool.self, forKey: .remoteKnown) ?? true
        title = try box.decodeIfPresent(String.self, forKey: .title) ?? "(无标题)"
        summary = try box.decodeIfPresent(String.self, forKey: .summary) ?? ""
        brief = try box.decodeIfPresent(String.self, forKey: .brief) ?? ""
        reason = try box.decodeIfPresent(String.self, forKey: .reason) ?? ""
        ask = try box.decodeIfPresent(String.self, forKey: .ask) ?? ""
        options = box.lossy([KairosOption].self, forKey: .options) ?? []
        tier = try box.decodeIfPresent(String.self, forKey: .tier) ?? "P3"
        status = try box.decodeIfPresent(String.self, forKey: .status) ?? KairosStatus.todo
        project = try box.decodeIfPresent(String.self, forKey: .project) ?? ""
        source = try box.decodeIfPresent(String.self, forKey: .source) ?? KairosSource.todo
        excerpt = try box.decodeIfPresent(String.self, forKey: .excerpt) ?? ""
        updatedAt = try box.decodeIfPresent(String.self, forKey: .updatedAt)
            ?? box.decodeIfPresent(String.self, forKey: .legacyUpdated)
            ?? ""
        evidence = box.lossy([KairosLink].self, forKey: .evidence) ?? []
        lastCommandId = try box.decodeIfPresent(String.self, forKey: .lastCommandId)
        tentacleId = try box.decodeIfPresent(String.self, forKey: .tentacleId)
        lastWriter = try box.decodeIfPresent([String: String].self, forKey: .lastWriter) ?? [:]
        sessionId = try box.decodeIfPresent(String.self, forKey: .sessionId)
        counterpart = box.lossy(KairosCounterpart.self, forKey: .counterpart)
        thread = box.lossy([KairosUtterance].self, forKey: .thread) ?? []
        legacyState = try box.decodeIfPresent(String.self, forKey: .legacyState)
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(id, forKey: .id)
        try box.encode(localRev, forKey: .localRev)
        try box.encode(syncedLocalRev, forKey: .syncedLocalRev)
        try box.encode(beingRev, forKey: .beingRev)
        try box.encode(remoteKnown, forKey: .remoteKnown)
        try box.encode(title, forKey: .title)
        try box.encode(summary, forKey: .summary)
        try box.encode(brief, forKey: .brief)
        try box.encode(reason, forKey: .reason)
        try box.encode(ask, forKey: .ask)
        try box.encode(options, forKey: .options)
        try box.encode(tier, forKey: .tier)
        try box.encode(status, forKey: .status)
        try box.encode(project, forKey: .project)
        try box.encode(source, forKey: .source)
        try box.encode(excerpt, forKey: .excerpt)
        try box.encode(updatedAt, forKey: .updatedAt)
        try box.encode(updatedAt, forKey: .legacyUpdated)
        try box.encode(evidence, forKey: .evidence)
        try box.encodeIfPresent(lastCommandId, forKey: .lastCommandId)
        try box.encodeIfPresent(tentacleId, forKey: .tentacleId)
        try box.encode(lastWriter, forKey: .lastWriter)
        try box.encodeIfPresent(sessionId, forKey: .sessionId)
        // 三个后加的字段：没有就整个不写，别在账本里留一堆空壳。
        try box.encodeIfPresent(counterpart, forKey: .counterpart)
        if !thread.isEmpty { try box.encode(thread, forKey: .thread) }
    }

    var isPending: Bool { localRev > syncedLocalRev }

    /// 入场券（KAIROS-CONTRACT 第三节）：完整义务是 summary/reason/ask/evidence 四件，
    /// 由同步提示词向 Being 主张；UI 降权只盯真正没法拍板的缺口——summary（是什么）
    /// 或 ask（要判断什么）为空。四字段全查会把存量旧卡全部标脏，信号变噪音。
    /// 以 remoteKnown 近似「经手过 Being」——人类刚本地新建的卡不受此约束。
    var lacksEntryTicket: Bool {
        // 以前这里查的是 state == mine（球在人手上）。球权撤了之后，
        // 「在他面前」就是「没了结」——没了结的都在那张单子上。
        !isClosed && remoteKnown
            && (summary.isEmpty || ask.isEmpty)
    }

    func hasSameBusinessFields(as other: KairosItem) -> Bool {
        payload == other.payload
    }

    var payload: KairosItemPayload { KairosItemPayload(item: self) }

    // MARK: 展示去重（真实数据常见「标题≈ask≈摘要」，一张卡念三遍是噪音）

    /// ask 与标题高度相似时卡片不再重复展示；数据本身不动。
    var displayAsk: String {
        Self.isNearDuplicate(ask, of: title) ? "" : ask
    }

    /// summary 与标题或 ask 雷同时同样省略。
    var displaySummary: String {
        // 消息行 being 还没写 summary 时，副行接着念这封信标题之后的话：
        // 标题只取了第一句（`KairosMessageRow.headline`），剩下的不能就这么看不见。
        if summary.isEmpty, isMessage, !excerpt.isEmpty {
            return KairosMessageRow.remainder(excerpt, after: title)
        }
        return (Self.isNearDuplicate(summary, of: title) || Self.isNearDuplicate(summary, of: ask))
            ? "" : summary
    }

    /// 归一化后互相包含，或字符 bigram Dice 相似度 > 0.6，视为重复。
    static func isNearDuplicate(_ left: String, of right: String) -> Bool {
        let a = deduplicationKey(left)
        let b = deduplicationKey(right)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b || a.contains(b) || b.contains(a) { return true }
        let bigramsA = bigrams(a)
        let bigramsB = bigrams(b)
        guard !bigramsA.isEmpty, !bigramsB.isEmpty else { return false }
        let shared = bigramsA.intersection(bigramsB).count
        return Double(2 * shared) / Double(bigramsA.count + bigramsB.count) > 0.6
    }

    private static func deduplicationKey(_ text: String) -> String {
        let dropped = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        return String(String.UnicodeScalarView(
            text.lowercased().unicodeScalars.filter { !dropped.contains($0) }
        ))
    }

    private static func bigrams(_ text: String) -> Set<String> {
        let characters = Array(text)
        guard characters.count >= 2 else { return [text] }
        return Set((0..<(characters.count - 1)).map {
            String(characters[$0]) + String(characters[$0 + 1])
        })
    }
}

/// 业务字段名。**必须与 Node 侧 `ledger/store.js` 的 `BUSINESS_FIELDS` 逐字相同**——
/// 规矩 2 按字段名比对写者，名字对不上等于保护没生效，而且不会报错，只会安静地
/// 让 being 盖掉人刚改的东西。
enum KairosField {
    static let human = "human"
    static let being = "being"

    static let business = [
        // 已撤掉四个：`state` 并进 `status`（球权是临时状态），
        // `next` 两端没有一块屏幕念过，`scores` 有读没有写，`links` 类型和规矩对不上。
        "title", "summary", "brief", "reason", "ask",
        "options", "tier", "status", "project", "source", "excerpt", "evidence",
        // 2026-09-11：消息那两样。`counterpart` 决定这一行归哪段，所以它是业务字段——
        // 手机改了要能并回账本，being 写了要受规矩 2 管。
        // （拟好的回复那一项下架了：**回复是选项不是拟稿**，选项走本来就有的 `options`。）
        "counterpart", "thread",
    ]

    /// 两版之间真正变了的业务字段。逐字段显式比对，不走反射——字段增删时编译器
    /// 不会提醒你补这里，但至少一眼看得出漏了谁。
    static func changed(from before: KairosItem, to after: KairosItem) -> [String] {
        var result: [String] = []
        if before.title != after.title { result.append("title") }
        if before.summary != after.summary { result.append("summary") }
        if before.brief != after.brief { result.append("brief") }
        if before.reason != after.reason { result.append("reason") }
        if before.ask != after.ask { result.append("ask") }
        if before.options != after.options { result.append("options") }
        if before.tier != after.tier { result.append("tier") }
        if before.status != after.status { result.append("status") }
        if before.project != after.project { result.append("project") }
        if before.source != after.source { result.append("source") }
        if before.excerpt != after.excerpt { result.append("excerpt") }
        if before.evidence != after.evidence { result.append("evidence") }
        if before.counterpart != after.counterpart { result.append("counterpart") }
        if before.thread != after.thread { result.append("thread") }
        return result
    }
}

extension KairosItem {
    /// 把 `other` 的指定业务字段搬到自己身上。规矩 1 的 rebase 用它：以盘上最新那条
    /// 为地基，只叠调用方真正改过的字段，不整条覆盖——否则 being 刚写进去的别的字段
    /// 会被一次无关的本地编辑连坐抹掉。
    func applying(_ fields: [String], from other: KairosItem) -> KairosItem {
        var result = self
        for field in fields {
            switch field {
            case "title": result.title = other.title
            case "summary": result.summary = other.summary
            case "brief": result.brief = other.brief
            case "reason": result.reason = other.reason
            case "ask": result.ask = other.ask
            case "options": result.options = other.options
            case "tier": result.tier = other.tier
            case "status": result.status = other.status
            case "project": result.project = other.project
            case "source": result.source = other.source
            case "excerpt": result.excerpt = other.excerpt
            case "evidence": result.evidence = other.evidence
            case "counterpart": result.counterpart = other.counterpart
            case "thread": result.thread = other.thread
            default: break
            }
            if let writer = other.lastWriter[field] { result.lastWriter[field] = writer }
        }
        return result
    }
}

/// 一次本地写入是「新建」还是「用户显式修改」——v2.3 §五那条边界的类型化表达。
///
/// 新建时填的状态/优先级只是初值，being 例行推进（改状态、排序）可以覆盖；
/// 只有新建**之后**用户显式改的那一下才盖 `last_writer: human`，从那一刻起
/// being 盖不动。Node 侧对应 `createTodo`（不盖戳）/ `humanEdit`（盖戳）。
enum KairosItemEdit {
    case created
    case edited
    /// being 写入（`bap.ledgerround/1` 把 being 提的改动并进来）。盖 `being` 戳，
    /// 不盖 `human`——自动写入永远不该假冒成人做的决定，否则规矩 2 从此形同虚设。
    case beingWrite

    /// 给 `next` 打上写者戳后返回。`.edited` 只给真正变了的字段盖戳——
    /// 没变的字段不该被顺手锁住，否则打开编辑器点一下保存就把整条待办对 being 冻死。
    func stamped(_ next: KairosItem, from before: KairosItem?) -> KairosItem {
        var result = next
        switch self {
        case .created:
            result.lastWriter = [:]
        case .edited:
            guard let before else { return result }
            for field in KairosField.changed(from: before, to: next) {
                result.lastWriter[field] = KairosField.human
            }
        case .beingWrite:
            guard let before else { return result }
            for field in KairosField.changed(from: before, to: next) {
                result.lastWriter[field] = KairosField.being
            }
        }
        return result
    }
}

struct KairosItemPayload: Codable, Hashable {
    var id: String
    var title: String
    var summary: String
    var brief: String
    var reason: String
    var ask: String
    var options: [KairosOption]
    var tier: String
    var status: String
    var project: String
    var source: String
    var excerpt: String
    var updatedAt: String
    var evidence: [KairosLink]
    var counterpart: KairosCounterpart?
    var thread: [KairosUtterance]
    /// 见 `KairosItem.legacyState`。冲突面里那两份 payload 也是老账本写的。
    var legacyState: String?

    enum CodingKeys: String, CodingKey {
        case id, title, summary, brief, reason, ask
        case options, tier, status, project, source, excerpt, evidence
        case counterpart, thread
        case updatedAt = "updated_at"
        case legacyUpdated = "updated"
        case legacyState = "state"
    }

    init(item: KairosItem) {
        id = item.id
        legacyState = nil
        title = item.title
        summary = item.summary
        brief = item.brief
        reason = item.reason
        ask = item.ask
        options = item.options
        tier = item.tier
        status = item.status
        project = item.project
        source = item.source
        excerpt = item.excerpt
        updatedAt = item.updatedAt
        evidence = item.evidence
        counterpart = item.counterpart
        thread = item.thread
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try box.decodeIfPresent(String.self, forKey: .title) ?? "(无标题)"
        summary = try box.decodeIfPresent(String.self, forKey: .summary) ?? ""
        brief = try box.decodeIfPresent(String.self, forKey: .brief) ?? ""
        reason = try box.decodeIfPresent(String.self, forKey: .reason) ?? ""
        ask = try box.decodeIfPresent(String.self, forKey: .ask) ?? ""
        options = box.lossy([KairosOption].self, forKey: .options) ?? []
        tier = try box.decodeIfPresent(String.self, forKey: .tier) ?? "P3"
        // 兜底和 `KairosItem`、和 Node 侧 `mergedStatusItem` 一样是 todo。
        // **别在这里塞「being 摄入的默认 doing」**：那条契约在 `KairosLedgerCreate.item` 里
        // 显式写着。写在这个兜底上，老 outbox 里一条 `{"state":"mine"}`（没有 status）
        // 两侧就会算出不同的值——Node 兜 todo，这边兜 doing。
        status = try box.decodeIfPresent(String.self, forKey: .status) ?? KairosStatus.todo
        project = try box.decodeIfPresent(String.self, forKey: .project) ?? ""
        source = try box.decodeIfPresent(String.self, forKey: .source) ?? KairosSource.todo
        excerpt = try box.decodeIfPresent(String.self, forKey: .excerpt) ?? ""
        updatedAt = try box.decodeIfPresent(String.self, forKey: .updatedAt)
            ?? box.decodeIfPresent(String.self, forKey: .legacyUpdated)
            ?? ""
        evidence = box.lossy([KairosLink].self, forKey: .evidence) ?? []
        counterpart = box.lossy(KairosCounterpart.self, forKey: .counterpart)
        thread = box.lossy([KairosUtterance].self, forKey: .thread) ?? []
        legacyState = try box.decodeIfPresent(String.self, forKey: .legacyState)
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(id, forKey: .id)
        try box.encode(title, forKey: .title)
        try box.encode(summary, forKey: .summary)
        try box.encode(brief, forKey: .brief)
        try box.encode(reason, forKey: .reason)
        try box.encode(ask, forKey: .ask)
        try box.encode(options, forKey: .options)
        try box.encode(tier, forKey: .tier)
        try box.encode(status, forKey: .status)
        try box.encode(project, forKey: .project)
        try box.encode(source, forKey: .source)
        try box.encode(excerpt, forKey: .excerpt)
        try box.encode(updatedAt, forKey: .updatedAt)
        try box.encode(updatedAt, forKey: .legacyUpdated)
        try box.encode(evidence, forKey: .evidence)
        try box.encodeIfPresent(counterpart, forKey: .counterpart)
        if !thread.isEmpty { try box.encode(thread, forKey: .thread) }
    }

    /// 球权并进状态。**每一条从盘上/别的设备来的 payload 都要过这一遍**：
    /// 快照迁移走它，outbox 并入也走它（`KairosOutboxEntry.merged(onto:)`）。
    /// 漏掉 outbox 那条的后果是两侧算出不同的结果——手机上按的「了结」，
    /// Node 并出来是 closed，Swift 并出来是 doing，而且不报错。
    func migratedToMergedStatus() -> KairosItemPayload {
        guard legacyState != nil else { return self }
        var next = self
        next.status = KairosSnapshot.mergedStatus(legacyState: legacyState, status: status)
        next.legacyState = nil
        return next
    }

    func item(localRev: Int, syncedLocalRev: Int, beingRev: Int, remoteKnown: Bool) -> KairosItem {
        KairosItem(
            id: id,
            localRev: localRev,
            syncedLocalRev: syncedLocalRev,
            beingRev: beingRev,
            remoteKnown: remoteKnown,
            title: title,
            summary: summary,
            brief: brief,
            reason: reason,
            ask: ask,
            options: options,
            tier: tier,
            status: status,
            project: project,
            source: source,
            excerpt: excerpt,
            updatedAt: updatedAt,
            evidence: evidence,
            counterpart: counterpart,
            thread: thread
        )
    }
}

struct KairosTombstone: Codable, Hashable, Identifiable {
    var id: String
    var localRev: Int
    var syncedLocalRev: Int
    var beingRev: Int
    var deletedAt: String

    enum CodingKeys: String, CodingKey {
        case id, localRev, syncedLocalRev, beingRev
        case deletedAt = "deleted_at"
    }
}

struct KairosConflict: Codable, Hashable, Identifiable {
    var id: String
    var local: KairosItemPayload?
    var remote: KairosItemPayload?
    var remoteDeleted: Bool
    var baseBeingRev: Int
    var remoteBeingRev: Int
    var detectedAt: String

    enum CodingKeys: String, CodingKey {
        case id, local, remote, remoteDeleted, baseBeingRev, remoteBeingRev
        case detectedAt = "detected_at"
    }
}

struct KairosBeing: Codable, Hashable {
    var name: String
}

struct KairosSyncMetadata: Codable, Hashable {
    var lastSyncAt: String?
    /// 多端写入的水位：`设备id -> 已经并进账本的最后一条 outbox seq`。
    /// 只有账本的写入者（Mac / being）动它；设备读它来决定自己能删掉哪几条。
    /// 这样每个文件永远只有一个写者，跨设备不需要锁。
    var outboxWatermark: [String: Int] = [:]

    enum CodingKeys: String, CodingKey {
        case lastSyncAt = "last_sync_at"
        case outboxWatermark = "outbox_watermark"
    }

    init(lastSyncAt: String?, outboxWatermark: [String: Int] = [:]) {
        self.lastSyncAt = lastSyncAt
        self.outboxWatermark = outboxWatermark
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        lastSyncAt = try box.decodeIfPresent(String.self, forKey: .lastSyncAt)
        outboxWatermark = try box.decodeIfPresent([String: Int].self, forKey: .outboxWatermark) ?? [:]
    }
}

/// 攒着还没说给 being 听的一条改动：上次说过的样子，以及它是不是新建的。
struct KairosPendingAnnounce {
    var before: KairosItem?
    var isNew: Bool
}

/// 撤销记的那三个字段：球权、优先级、状态。拖一下、点一下菜单，改的都是它们。
/// 两个最容易被手滑改掉的字段。撤销记的就是它们。
/// （以前是三个，球权 2026-09-11 并进了 `status`。）
struct KairosFieldSnapshot {
    var tier: String
    var status: String

    init(tier: String, status: String) {
        self.tier = tier
        self.status = status
    }

    init(_ item: KairosItem) {
        self.init(tier: item.tier, status: item.status)
    }
}

struct KairosProject: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var symbol: String
    var color: String
    var archived: Bool

    static let defaultProject = KairosProject(
        id: KairosWorkspace.defaultProjectID,
        name: "Default",
        symbol: "square.grid.2x2",
        color: "blue",
        archived: false
    )
}

struct KairosProjectDraft: Hashable {
    var name: String = ""
    var symbol: String = "square.grid.2x2"
    var color: String = "blue"
}

struct KairosWorkspace: Codable, Hashable {
    enum CodingKeys: String, CodingKey { case projects, manualOrder, sidebarOrder }

    static let defaultProjectID = "default"

    var projects: [KairosProject]
    var manualOrder: [String: [String]]
    var sidebarOrder: [String]

    // `membership`（事项 id → 项目 id）已撤掉。
    //
    // 它是 09-08 那次界面重做之前的设计，重做之后**界面上一处都没碰过**，却还挡在
    // 主列表的过滤最前面——所有条目碰巧落在同一个默认桶里所以没出事，但
    // `selectedProjectID` 会在读账本时被自动改，一旦账本里出现真项目、桶对不上，
    // **整张单子会静默地少东西甚至变空**，而且界面上没有任何按钮能修。
    //
    // 项目归属只剩一处：事项身上的 `project`（契约 §96/§139），being 也写它。
    // 老账本里残留的 `membership` 键**读的时候直接忽略**（不在 CodingKeys 里），
    // 下一次落盘就没了，不需要迁移——它从来没有过第二个读者。
    //
    // **给 being 的协议没变**：契约 §121 早就写明 workspace 这一坨不进 Being payload。

    init(projects: [KairosProject], manualOrder: [String: [String]], sidebarOrder: [String]) {
        self.projects = projects
        self.manualOrder = manualOrder
        self.sidebarOrder = sidebarOrder
    }

    /// **手写。** 这个项目被合成解码器坑过两次（`KairosRoom.toldWhichItem`、
    /// `KairosMacFilter.scope`）：少一个键就抛 keyNotFound，整份账本读不出来，
    /// 表现是「今天的东西全没了」。缺什么就给什么的空值，一条都别丢。
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        projects = try box.decodeIfPresent([KairosProject].self, forKey: .projects) ?? []
        manualOrder = try box.decodeIfPresent([String: [String]].self, forKey: .manualOrder) ?? [:]
        sidebarOrder = try box.decodeIfPresent([String].self, forKey: .sidebarOrder) ?? []
    }

    static var empty: KairosWorkspace {
        KairosWorkspace(projects: [], manualOrder: [:], sidebarOrder: [])
    }

    /// 合并列表的顺序段。不是状态值，只是一个存「用户拖出来的顺序」的桶。
    /// 球权撤掉之后它是唯一还活着的段——单子本来就只有一张。
    static let activeOrderKey = "active"

    /// 手工顺序的键。**不带项目 id。**
    ///
    /// 原来是 `"<项目id>/<段>"`。那个项目 id 取自 `selectedProjectID`，而它会在**读账本时
    /// 被自动改**成「第一个没归档的项目」——账本里一旦出现一个真项目，键就变了，
    /// 人拖出来的顺序当场找不回来。
    /// 一张单子就一个桶（泳道 09-11 已经撤了），键里本来也不需要项目。
    static func orderKey(segment: String) -> String { segment }

    /// 老键的样子，只在迁移时用来认出它们。见 `KairosWorkspaceEngine.normalized`。
    static func isLegacyOrderKey(_ key: String) -> Bool { key.contains("/") }
}

/// A raw, unprocessed thought — deliberately NOT a KairosItem. No business fields, no sync,
/// no rev. Local-only capture; promoting one creates a real item (default status "todo")
/// and removes the seed. See KAIROS-CONTRACT.md.
struct KairosSeed: Codable, Hashable, Identifiable {
    var id: String = UUID().uuidString
    var text: String
    var createdAt: String = KairosClock.now
}

struct KairosSnapshot: Codable, Hashable {
    static let protocolV1 = "kairos.local/1"
    static let protocolV2 = "kairos.local/2"
    static let protocolV3 = "kairos.local/3"

    var protocolName: String
    var updatedAt: String
    var being: KairosBeing
    var sync: KairosSyncMetadata
    var items: [KairosItem]
    var tombstones: [KairosTombstone]
    var conflicts: [KairosConflict]
    var workspace: KairosWorkspace
    var seeds: [KairosSeed]

    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case updatedAt = "updated_at"
        case being, sync, items, tombstones, conflicts, workspace, seeds
    }

    static var empty: KairosSnapshot {
        KairosSnapshot(
            protocolName: protocolV3,
            updatedAt: KairosClock.now,
            being: KairosBeing(name: ""),
            sync: KairosSyncMetadata(lastSyncAt: nil),
            items: [],
            tombstones: [],
            conflicts: [],
            workspace: .empty,
            seeds: []
        )
    }

    var isSupportedProtocol: Bool {
        [Self.protocolV1, Self.protocolV2, Self.protocolV3].contains(protocolName)
    }

    /// 球权 → 状态。nil = 状态原样留着（球在人类手上不说明这件事走到哪了）。
    /// /1 的五态也在表里：它们先按老映射折成三态（inbox/doing→being，todo/decide→mine），
    /// 折完再并，所以两步合成这一张表，不必先跑一遍 /1→/2。
    /// **Node 侧 `ledger/store.js` 的 `STATE_TO_STATUS` 逐条相同，改一处必须改两处。**
    static let stateToStatus: [String: String?] = [
        "closed": KairosStatus.closed,
        "being": KairosStatus.doing,   // being 在办 = 进行中
        "inbox": KairosStatus.doing,   // /1 词汇：inbox → being
        "doing": KairosStatus.doing,   // /1 词汇：doing → being
        "mine": String?.none,
        "todo": String?.none,          // /1 词汇：todo → mine
        "decide": String?.none,        // /1 词汇：decide → mine
    ]

    /// /1、/2 → /3 就地迁移：球权并进状态，撤掉 next / scores / links。
    ///
    /// **和 /1→/2 同性质，是词汇迁移不是业务编辑**：不改任何 rev、不产生 pending、
    /// 不生成 tombstone（契约 §十一）。已经是 /3 的原样返回。
    func migratedToMergedStatus() -> KairosSnapshot {
        guard protocolName != Self.protocolV3 else { return self }
        var next = self
        next.protocolName = Self.protocolV3

        for index in next.items.indices {
            next.items[index] = Self.merging(next.items[index])
        }
        for index in next.conflicts.indices {
            next.conflicts[index].local = next.conflicts[index].local?.migratedToMergedStatus()
            next.conflicts[index].remote = next.conflicts[index].remote?.migratedToMergedStatus()
        }

        // manualOrder 的 key 是 "projectID/段"。泳道撤了，挂在泳道上的手工顺序
        // 没有东西可挂；合并列表那个桶（`active`）是唯一还活着的段，留着。
        next.workspace.manualOrder = next.workspace.manualOrder.filter { key, _ in
            key.split(separator: "/", maxSplits: 1).last.map(String.init)
                == KairosWorkspace.activeOrderKey
        }
        return next
    }

    static func mergedStatus(legacyState: String?, status: String) -> String {
        // 表里查不到（认不出的球权）和查到 nil（球在人类手上）都是「状态原样留着」。
        if let legacyState, let mapped = stateToStatus[legacyState], let mapped {
            return mapped
        }
        return KairosStatus.normalized(status)
    }

    private static func merging(_ item: KairosItem) -> KairosItem {
        var next = item
        next.status = mergedStatus(legacyState: item.legacyState, status: item.status)
        next.legacyState = nil
        // 人锁过球权的，锁跟着搬到 status——他锁的是「这条完没完我说了算」，
        // 字段换个名字不该把这个决定弄丢。status 自己已经锁着就不动它。
        if let owner = next.lastWriter["state"], next.lastWriter["status"] == nil {
            next.lastWriter["status"] = owner
        }
        for gone in ["state", "next", "scores", "links"] { next.lastWriter[gone] = nil }
        return next
    }

}

extension KairosSnapshot {
    enum LegacyCodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case updatedAt = "updated_at"
        case generatedAt = "generated_at"
        case being, beingName, sync, items, tombstones, conflicts, workspace, seeds
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: LegacyCodingKeys.self)
        protocolName = try box.decodeIfPresent(String.self, forKey: .protocolName) ?? "kairos.local/1"
        updatedAt = try box.decodeIfPresent(String.self, forKey: .updatedAt)
            ?? box.decodeIfPresent(String.self, forKey: .generatedAt)
            ?? KairosClock.now
        being = try box.decodeIfPresent(KairosBeing.self, forKey: .being)
            ?? KairosBeing(name: box.decodeIfPresent(String.self, forKey: .beingName) ?? "")
        sync = try box.decodeIfPresent(KairosSyncMetadata.self, forKey: .sync)
            ?? KairosSyncMetadata(lastSyncAt: nil)
        items = try box.decodeIfPresent([KairosItem].self, forKey: .items) ?? []
        tombstones = try box.decodeIfPresent([KairosTombstone].self, forKey: .tombstones) ?? []
        conflicts = try box.decodeIfPresent([KairosConflict].self, forKey: .conflicts) ?? []
        workspace = try box.decodeIfPresent(KairosWorkspace.self, forKey: .workspace) ?? .empty
        seeds = try box.decodeIfPresent([KairosSeed].self, forKey: .seeds) ?? []
    }
}

enum KairosClock {
    static var now: String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static let plain: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime]
        return value
    }()

    private static let fractional: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return value
    }()

    /// Swift 写的是 `…:45Z`，Node 写的是 `…:52.181Z`，同一秒内字符串比较会比反。
    /// 要比先后，走这里。解析不出来当最早。
    static func parse(_ value: String) -> Date {
        plain.date(from: value) ?? fractional.date(from: value) ?? .distantPast
    }
}

/// Mac 侧栏主导航：就两项——事项、Inbox。
/// 「已了结」不占导航，是事项那一屏右上角的一个开关；being 是 being 的临时状态，
/// 不是事项的去处，也不进导航。账本里 mine / being / closed 三态照旧——这是展示层的事。
enum KairosMainSection: Hashable {
    case items
    case inbox
}

/// 账本的球权三态，Store 按它筛列表。界面上不再画成三条泳道：
/// Mac 只用 `.closed` 区分「已了结」，mine / being 合成一条「开着」的流。
// 泳道（KairosLane：待我拍板 / Being 在办 / 已了结）已撤：界面是
// 「一张单子 + 项目 / 状态 / 来源三维度」，三个泳道里只有「已了结」
// 那个抽屉还在用，而它现在是 status 的一个值。
