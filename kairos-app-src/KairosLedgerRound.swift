import Foundation

/// 从 being 的回复里抠出那个 json 块。
///
/// 邮局（`KairosMailRoundReply`）和账本（`KairosLedgerRoundReply`）两趟来回共用这一份：
/// 对面是个会客套、会换格式的 agent，不是 RPC 端点——抠块这件事两边一模一样，
/// 抠错的后果也一模一样（整趟白跑）。所以只留一份实现，两边一起被测。
enum KairosJSONBlock {
    /// 优先代码围栏，其次第一个平衡的大括号——being 偶尔会在块前面客套一句，
    /// 不能因为多了一句「好的」就整趟白跑。
    static func extract(from text: String) -> Data? {
        if let fenced = firstFencedBlock(in: text),
           let data = fenced.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\", inString {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 { return String(text[start...index]).data(using: .utf8) }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func firstFencedBlock(in text: String) -> String? {
        var collecting = false
        var block: [String] = []
        for line in text.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if collecting { return block.joined(separator: "\n") }
                collecting = true
                continue
            }
            if collecting { block.append(line) }
        }
        return nil
    }
}

// MARK: - 本趟编号

/// 每趟一个编号，回复必须原样带回来。邮局和账本共用（前缀不同）。
///
/// **为什么要有它。** 202 的意思是「排上了，但这条线拿不到回复」，排着的那条 being 还是会跑；
/// 我们等一会儿再问一次，于是下一次拿回来的流里，答的到底是这一问还是上一问，
/// 今天无从判断——只能靠「账本那趟全量重送、天然幂等」这个论证兜着。带上编号之后，
/// 这句话从**论证**变成**可验证**：对不上就整趟不收，一行的事。
enum KairosRoundID {
    static let ledgerPrefix = "r"
    static let mailPrefix = "m"

    /// `r-4f2a9c1b`。短就够——它只需要在最近几趟里唯一，不是持久标识。
    static func next(_ prefix: String) -> String {
        prefix + "-" + String(format: "%08x", UInt32.random(in: .min ... .max))
    }
}

/// 本趟给每条待办的短号。
///
/// **只在本趟有效，下一趟会换。** 这不是为了省 token（60 条裸 UUID 只占清单的 3%，
/// 大头是每条上千字的 summary / brief / ask），是为了**不让它凭记忆写**：号一换轮就作废，
/// 它只能改这一趟我给它看过的那些行，写不进一条几天前记住的 id。
///
/// 两位短号会撞——所以每条 patch 还要把标题原样抄回来当回声
/// （见 `KairosLedgerPatch.title`）：校验位只能抓「抄错字符」，回声能抓「看错行」，
/// 后者才是它真会犯的错。
enum KairosRoundRef {
    /// 去掉了 i l o 0 1：这几个在等宽字体里互相认错，短号本来就是给人也给它看的。
    static let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")

    /// `count` 个互不相同的两位短号。31² = 961 个坑，清单最多 60 条，撞了重摇即可。
    static func pool(_ count: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        while result.count < count {
            let ref = String([alphabet.randomElement()!, alphabet.randomElement()!])
            if seen.insert(ref).inserted { result.append(ref) }
        }
        return result
    }
}

// MARK: - 送上去给 being 看的那份清单

/// 一条待办的摘要，送给 being 看。
///
/// **为什么要送。** Mac 下架之后 being 手上一份账本都没有（`ledger/cli.js` 写的是 Mac 上
/// iCloud 那个文件），手机的沙盒它也伸不进来。它对这些待办的全部认知就是这份清单——
/// 不送，它只能靠 `bap.notice/1` 一句一句听变化然后拿记忆拼，拼错了还没人知道。
///
/// **为什么是摘要不是整条。** 每趟来回都要重新送一遍（being 不存），整条送法token 烧不起。
/// 送的是它写东西时需要看见的那些字段，加一份 `locked`——被人手改过的字段它写了也会被
/// 规矩 2 挡掉，不如一开始就告诉它别费劲。
private extension String {
    var nonEmptyForRound: String? { isEmpty ? nil : self }
}

struct KairosLedgerRoundItem: Encodable, Hashable {
    /// 本趟的短号，它回话时用它指认这一条。下一趟会换。
    var ref: String
    /// 真 id。留在清单里是为了人对日志、也为了它要在别处引用这条待办时有东西可写；
    /// **不要求它抄回来**（抄回来我也认，但只在本趟清单里认，见 `KairosLedgerRoundMerge`）。
    var id: String
    var title: String
    var tier: String
    var status: String
    var project: String
    var source: String
    var summary: String
    var brief: String
    var ask: String
    /// 谁在等他回。**只有消息行才有**，空的就不发。
    /// 少了它，「私信你不用建，你要做的是补选项」这条规矩在这条路上没法执行——
    /// being 看着一排行，分不出哪几行是欠人回复的。
    var counterpart: String?
    var locked: [String]

    /// 单字段截断长度。being 要的是「认出这条 + 知道现在写到哪了」，不是全文。
    static let clip = 400
    /// 一趟最多送多少条。开着的待办多到这个数以上时，先送最近动过的。
    static let cap = 60

    init(_ item: KairosItem, ref: String) {
        self.ref = ref
        id = item.id
        title = String(item.title.prefix(Self.clip))
        tier = item.tier
        status = item.status
        project = item.project
        source = item.source
        summary = String(item.summary.prefix(Self.clip))
        brief = String(item.brief.prefix(Self.clip))
        ask = String(item.ask.prefix(Self.clip))
        counterpart = item.counterpart?.name.nonEmptyForRound
        locked = item.lastWriter
            .filter { $0.value == KairosField.human }
            .keys.sorted()
    }

    /// 还开着的，按最后改动倒序取前 `cap` 条，逐条发一个本趟短号。
    /// 了结的不送——being 对它们没有该写的东西，白烧 token。
    static func digest(_ items: [KairosItem]) -> [KairosLedgerRoundItem] {
        let open = items
            .filter { !$0.isClosed }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(cap)
        return zip(open, KairosRoundRef.pool(open.count)).map(KairosLedgerRoundItem.init)
    }
}

// MARK: - being 回来的改动

/// being 对一条待办提的改动。没提到的字段 = 不动，不是「清空」——
/// 所以每个字段都是可选的；**空字符串也当没提**，要清空得写进 `clear`。
struct KairosLedgerPatch: Decodable, Hashable {
    /// 本趟短号。指认改的是哪一条，必填。
    var ref: String?
    /// 真 id。可选；给了就必须和 `ref` 指同一条，否则整条不收（它自己糊涂了）。
    var id: String?
    /// 标题回声：把清单里那条的标题原样抄回来。**必填，这是短号能成立的全部理由。**
    var title: String?
    /// 要清空的字段。清空是破坏性的，必须说出口——留空不算数。
    var clear: [String]?
    var summary: String?
    var brief: String?
    var reason: String?
    var ask: String?
    var tier: String?
    var status: String?
    var project: String?
    var source: String?
    var excerpt: String?
    /// 几个可以点的判断。**不是字符串**，所以不走下面那套 `value(_:)` 的通道，
    /// 单独判、单独写（见 `optionsRejection` 和 `applied`）。
    /// 手机单机时这条路是 being 唯一够得着账本的路，而 `options` 是消息行的入场券——
    /// 少了它，「回复是选项不是拟稿」在那条路上等于没实现。
    var options: [KairosOption]?
    /// 已撤掉的那几个。**照样解进来，只为能明说它们去哪了**——
    /// being 手上的提示词可能还是旧的，静默丢掉的话它会一趟趟接着写，而每一趟都白跑。
    var state: String?
    var next: String?

    /// being 能写的字段。`title` 不在里面——标题是人给这条事起的名字，不该被自动改写；
    /// `evidence` 手机上不展示，也不从这条通道走。
    /// `state` / `next` 已撤：球权并进 `status`，下一步写进 `options` 让人点。
    ///
    /// **`options` 不在这张表里**——这张表是「值是字符串的那些」，`options` 是个数组，
    /// 单独走。判断「being 这趟能写哪些」要用 `writableAll`，别只看这一张。
    static let writable = ["summary", "brief", "reason", "ask", "tier", "status", "project", "source", "excerpt"]

    /// being 这条通道上能写的全部字段（含非字符串的）。文档里那句「能写的只有…」对的是它。
    static let writableAll = writable + ["options"]

    /// 能清空的字段。档位 / 状态 / 渠道是枚举，清空没有意义——它们各有默认值，
    /// 想改就写一个合法值进来，不存在「这条没有档位」这回事。
    /// `options` 在里面：一条消息回掉之后那几个判断就不该再挂着了。
    static let clearable = ["summary", "brief", "reason", "ask", "project", "excerpt", "options"]

    /// 撤掉的字段 → 该写哪儿。写了就作废那一个字段并说清楚，不牵连同一条里别的字段。
    /// **只列解得进来的那两个**：`scores` / `links` 的值不是字符串，这个结构体没有
    /// 对应的属性，写了到不了这里——列在这儿只会让人以为它会被报出来。
    static let retired = [
        "state": "球权撤了，并进状态：closed → status=closed，being → status=doing，mine 不用写",
        "next": "下一步撤了：写进 options 让他点一个，别写成一句没人念的预言",
    ]

    /// 这条 patch 里提到的、已经撤掉的字段。
    var retiredMentioned: [String] {
        Self.retired.keys.sorted().filter { field in
            guard let value = retiredValue(field) else { return false }
            return !value.isEmpty
        }
    }

    func retiredValue(_ field: String) -> String? {
        switch field {
        case "state": state
        case "next": next
        default: nil
        }
    }

    /// 选项的形状。**和 Node 侧 `ledger/store.js` 的 `isValidOptions` 同一条规矩**：
    /// 数组，每格 `label` 不能空、`detail` 可选。不合格作废这一个字段，不牵连整条。
    /// 走 CLI 那条路会被顶回来，走这条路没道理放行。
    static func optionsRejection(_ options: [KairosOption]) -> String? {
        guard !options.isEmpty else {
            return "options 给了个空数组。真要清掉写 clear，没有就整个别给"
        }
        guard options.allSatisfy({ !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return "options 每格的 label 不能空：[{\"label\":\"他点的那句\",\"detail\":\"选它意味着什么（可省）\"}]"
        }
        return nil
    }

    func value(_ field: String) -> String? {
        switch field {
        case "summary": summary
        case "brief": brief
        case "reason": reason
        case "ask": ask
        case "tier": tier
        case "status": status
        case "project": project
        case "source": source
        case "excerpt": excerpt
        default: nil
        }
    }

    /// 这条 patch 真正提到了哪些字段。**空字符串不算提到**：留空不是清空。
    var mentioned: [String] {
        Self.writable.filter { field in
            guard let value = value(field) else { return false }
            return !value.isEmpty
        }
    }

    /// 值集校验。写死的那几个字段写了没见过的值，**作废这一个字段，不牵连整条**——
    /// 它把档位写错了，不该连带丢掉同一条里写得好好的 brief。
    /// 值集与 Node 侧 `ledger/store.js` 的 TIERS / STATUSES / isValidSource 同一套：
    /// 同一个 being 走 CLI 那条路会被顶回来，走这条路没道理放行。
    static func rejection(_ field: String, value: String, projects: [String]) -> String? {
        switch field {
        case "tier":
            return KairosTier.all.contains(value) ? nil : "档位只认 " + KairosTier.all.joined(separator: " / ")
        case "status":
            return KairosStatus.all.contains(value) ? nil : "状态只认 " + KairosStatus.all.joined(separator: " / ")
        case "source":
            return KairosSource.isValid(value)
                ? nil
                : "渠道只认 " + KairosSource.all.joined(separator: " / ") + "，炉火要写成 fireside:炉火名"
        // 项目名**不拦**。它和档位/状态不是一回事：
        // 档位写错一个字，那条会沉到列表最底下、人还看不出来，所以必须拦；
        // 项目写个新名字，边栏上多一摊事，人看得见、不想要就删。
        // being 看见五条都在讲同一件事顺手归成一摊，那正是要它干的活。
        // 正文里仍然会把已有的项目名发给它——那是提示，让它复用而不是造近义词，不是门禁。
        // 以前这里拦着，而 CLI 那条路不拦：手机单机时 being 写 project:"demo" 会被顶回来，
        // 而同名项目就在边栏上挂着 19 条。两条路不一致，按松的那条对齐。
        default:
            return nil
        }
    }

    func applied(_ field: String, to item: KairosItem) -> KairosItem {
        var result = item
        switch field {
        case "summary": if let summary { result.summary = summary }
        case "brief": if let brief { result.brief = brief }
        case "reason": if let reason { result.reason = reason }
        case "ask": if let ask { result.ask = ask }
        case "tier": if let tier { result.tier = tier }
        case "status": if let status { result.status = status }
        case "project": if let project { result.project = project }
        case "source": if let source { result.source = source }
        case "excerpt": if let excerpt { result.excerpt = excerpt }
        default: break
        }
        return result
    }

    static func cleared(_ field: String, in item: KairosItem) -> KairosItem {
        var result = item
        switch field {
        case "summary": result.summary = ""
        case "brief": result.brief = ""
        case "reason": result.reason = ""
        case "ask": result.ask = ""
        case "project": result.project = ""
        case "excerpt": result.excerpt = ""
        case "options": result.options = []
        default: break
        }
        return result
    }
}

// MARK: - being 自己要建的

/// being 摄入了新东西要上桌，自己建一条。
///
/// **为什么账本那趟要能新建。** being 不是只会回答问题的那一头：Town 来的信、篝火里 @ 它的、
/// 炉火里聊出来的事、它心跳时自己想到的——这些都是它有、人类还没有的信息。
/// Mac 在的时候它直接跑 `ledger/cli.js new` 就写进去了；手机单机之后那条路断了，
/// 而这趟以前只能改已有的条目（编出来的 id 一律不当新建），于是**它摄入的东西根本上不了
/// 手机的桌**——「inbox 归 Being，先消化后上桌」那半条契约在手机上是空的。
///
/// **幂等靠 being 自己给的 id。** 这趟会重问、会重发（它忙、流断了、Kairos 等不到回复再问一次），
/// 同一条新建很可能被回两次。所以 id 由它给、且必须稳定：同一件事再回一次给同一个 id，
/// 账本上已经有了就整条跳过。不额外记状态，账本自己就是去重表。
struct KairosLedgerCreate: Decodable, Hashable {
    /// being 给的稳定 id。**幂等键**：同一件事重发时给同一个。
    var id: String?
    /// 必填。没有标题的待办在单子上就是一行空白。
    var title: String?
    var summary: String?
    var brief: String?
    var reason: String?
    var ask: String?
    var tier: String?
    var status: String?
    var project: String?
    var source: String?
    var excerpt: String?
    /// 见 `KairosLedgerPatch.options`。消息行建出来就该带上几个可以点的判断，
    /// 分两趟写等于多一次忘记的机会。
    var options: [KairosOption]?

    /// 一趟最多建多少条。不是怕它勤快，是怕一次灌进来几十条把单子冲掉——
    /// 真有那么多，下一趟接着来。
    static let cap = 20
    /// id 的形状：不带空白、4-64 个字符。太随意的 id 撞车和认错的概率都高。
    static let idLength = 4...64

    static func isValidID(_ raw: String) -> Bool {
        idLength.contains(raw.count) && !raw.contains(where: \.isWhitespace)
    }

    func value(_ field: String) -> String? {
        switch field {
        case "summary": summary
        case "brief": brief
        case "reason": reason
        case "ask": ask
        case "tier": tier
        case "status": status
        case "project": project
        case "source": source
        case "excerpt": excerpt
        default: nil
        }
    }

    /// 真正给了值的字段。和 patch 一样：空字符串当没给。
    var mentioned: [String] {
        KairosLedgerPatch.writable.filter { field in
            guard let value = value(field) else { return false }
            return !value.isEmpty
        }
    }

    /// 建出来的那条。**默认落「进行中」**（契约 §三：being 摄入的新 item 是它在消化——
    /// 先消化、后上桌，单子上不允许出现没消化过的东西。以前这条写的是「落 being」，
    /// 球权并进状态之后 being 就是 doing）。
    /// `remoteKnown` 为真：这条本来就是它建的，不存在「等它确认」。
    func item(id: String, projects: [String]) -> KairosItem {
        var result = KairosItem(
            id: id,
            remoteKnown: true,
            title: title ?? "",
            status: KairosStatus.doing,
            source: KairosSource.inbox
        )
        for field in mentioned {
            guard let value = value(field),
                  KairosLedgerPatch.rejection(field, value: value, projects: projects) == nil
            else { continue }
            switch field {
            case "summary": result.summary = value
            case "brief": result.brief = value
            case "reason": result.reason = value
            case "ask": result.ask = value
            case "tier": result.tier = value
            case "status": result.status = value
            case "project": result.project = value
            case "source": result.source = value
            case "excerpt": result.excerpt = value
            default: break
            }
        }
        if let options, KairosLedgerPatch.optionsRejection(options) == nil {
            result.options = options
        }
        return result
    }
}

// MARK: - 没写进去的东西

/// 一处没写进去的改动，以及为什么。
///
/// **两个用处**：说给人听（notice），和下一趟原样贴回给 being （`last_round`）。
/// 今天拒了只告诉人，being 那边一个字都收不到，下一轮照错不误——这是它唯一能变好的路。
struct KairosLedgerRoundRejection: Hashable {
    var ref: String
    /// 整条被拒时是 nil（号对不上、标题对不上），字段级被拒时是那个字段名。
    var field: String?
    var why: String

    var line: String {
        guard let field else { return "\(ref)：\(why)" }
        return "\(ref) 的 \(field)：\(why)"
    }
}

/// 上一趟的结果，下一趟原样带给 being。
struct KairosLedgerRoundReport: Hashable {
    var round: String
    var applied: Int
    var created: Int = 0
    /// 它上一趟已经建过、这趟又回了一遍的。不是错——是幂等生效了，
    /// 但要告诉它「那条已经在账本上了」，否则它以为没成功，会一直重回。
    var duplicates: Int = 0
    var rejected: [KairosLedgerRoundRejection]
}

/// 「请 being 看一眼账本」这个来回的话术和解析。纯逻辑，不碰网络也不碰文件。
enum KairosLedgerRoundReply {
    static let protocolName = "bap.ledgerround/1"

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
                "对面回的不是账本这一趟的东西（protocol = \(got.isEmpty ? "没给" : got)），没敢当成「没有要改的」。"
            case .staleRound(let sent, let got):
                "对面答的是别的趟（我问的是 \(sent)，它回的是 \(got.isEmpty ? "没给编号" : got)），已丢弃。"
            }
        }
    }

    /// 请求正文。**只说这一趟的事**：编号、清单、上一趟的判决、回复骨架。
    ///
    /// 规矩（协议长什么样、值集、短号只在本趟有效、清空要显式）写在
    /// `BEING-RULES.md` 的「Kairos 直连的两趟」那节，一次性的东西不该每趟重发。
    /// 骨架留着是 2026-08-29 的裁决：多花几十 token，省掉一次带工具调用的全量失败往返。
    /// 它没读操作卡也不会出事——拒收是失败安全的，下一趟 `last_round` 会把那条规矩贴回它脸上。
    ///
    /// 正文里避开裸反引号（裸反引号会搅乱围栏配对，整趟白跑）。
    static func request(
        items: [KairosLedgerRoundItem],
        round: String,
        projects: [String],
        last: KairosLedgerRoundReport?
    ) -> String {
        var lines = [
            "看一眼账本（Kairos 直连，手机上这份就是全部——你那边没有文件可读，别去跑 CLI）。",
            "规矩在 BEING-RULES.md 的「Kairos 直连的两趟」那节，这里只说这一趟的事。",
            "",
            "本趟编号 \(round)",
        ]
        if !projects.isEmpty {
            lines.append("项目只有这几个：" + projects.joined(separator: " / "))
        }
        if let last {
            lines.append(lastRoundLine(last))
        }

        if items.isEmpty {
            lines.append(contentsOf: [
                "",
                "现在一条开着的都没有。没有要改的就回一个空的；**你手上有该上桌的新东西，这趟一样可以建**：",
                "",
                "```json",
                "{\"protocol\":\"\(protocolName)\",\"round\":\"\(round)\",\"patches\":[],",
                " \"creates\":[{\"id\":\"你给的稳定 id\",\"title\":\"新的一条\",\"summary\":\"…\"}]}",
                "```",
            ])
            return lines.joined(separator: "\n")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let list = (try? encoder.encode(items)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        lines.append(contentsOf: [
            "",
            "开着的待办：",
            list,
            "",
            "有要补要改的就回，只回一个 json 代码块，块外别写任何字：",
            "",
            "```json",
            "{\"protocol\":\"\(protocolName)\",\"round\":\"\(round)\",",
            " \"patches\":[{\"ref\":\"\(items[0].ref)\",\"title\":\"把标题原样抄回来\",",
            "             \"summary\":\"一句话说是什么\",\"tier\":\"P1\"}],",
            " \"creates\":[{\"id\":\"你给的稳定 id\",\"title\":\"新的一条\",\"summary\":\"…\"}]}",
            "```",
            "",
            "- 编号和 ref 原样抄回来；ref 只在这一趟有效，下一趟会换。",
            "- 每条带上 title 原样抄一遍，我拿它跟 ref 对——对不上说明看串行了，这条不收。",
            "- 只写真要改的字段，留空不是清空；要清空写 \"clear\":[\"brief\"]。",
            "- 没有要改的就回空 patches，别为了交差硬写。locked 里的字段你写了也进不去。",
            "- **你手上有该上桌的新东西就写进 creates**，不用等我问。id 你给、要稳定——",
            "  这趟可能是重发，同一件事给同一个 id 我才认得出是同一条，已经建过的会跳过。",
        ])
        return lines.joined(separator: "\n")
    }

    /// 上一趟的判决。**这是规矩按需重述的地方**：不犯就不说，犯了才把那一条贴回去。
    static func lastRoundLine(_ report: KairosLedgerRoundReport) -> String {
        var text = "上一趟（\(report.round)）：改进去 \(report.applied) 条"
        if report.created > 0 { text += "，新建 \(report.created) 条" }
        if report.duplicates > 0 { text += "（另有 \(report.duplicates) 条你上次已经建过了，跳过）" }
        text += "。"
        guard !report.rejected.isEmpty else { return text }
        text += "这几处没进去——"
        text += report.rejected.map { "\n- " + safeForBody($0.line) }.joined()
        return text
    }

    /// 判决里带着** being 自己写的字**（它发明的项目名、整趟没收时它说的那 200 字），
    /// 这些字下一趟要回到正文里。两样东西必须先拿掉，否则等于让它一句话废掉下一趟：
    ///
    /// - **反引号**：正文靠 ``` 围栏划出回复骨架，它回过一个非 json 的围栏块，
    ///   原样贴回去就把围栏配对搅乱了（整趟白跑）。
    /// - **换行**：判决是一行一条的列表，中间断行会让后面那半截看着像新的一条规矩。
    static func safeForBody(_ text: String) -> String {
        text
            .replacingOccurrences(of: "`", with: "'")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// 一趟回信解出来的东西：改哪些、建哪些。
    struct Reply {
        var patches: [KairosLedgerPatch] = []
        var creates: [KairosLedgerCreate] = []

        var isEmpty: Bool { patches.isEmpty && creates.isEmpty }
    }

    static func parse(_ text: String, round: String, correlated: Bool = false) throws -> Reply {
        guard let data = KairosJSONBlock.extract(from: text) else {
            throw ParseError.noJSON(String(text.prefix(200)))
        }
        struct Payload: Decodable {
            var protocolName: String?
            var round: String?
            var patches: [KairosLedgerPatch]?
            var creates: [KairosLedgerCreate]?

            enum CodingKeys: String, CodingKey {
                case protocolName = "protocol"
                case round, patches, creates
            }
        }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw ParseError.badJSON(error.localizedDescription)
        }
        // 信封先验。以前这里任何一个 json 对象都解得通（`patches` 是可选的），
        // 于是 being 答非所问、或者把邮局那趟的块答进来，屏幕上写的是「这一轮没有要改的」——
        // 它压根没答，人看到的是它答了「不用改」。
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
        return Reply(patches: payload.patches ?? [], creates: payload.creates ?? [])
    }
}

// MARK: - 并进账本

/// 一趟并完的结果。没写进去的要能说出口——「被挡掉了」和「being 没写」在界面上是两回事。
struct KairosLedgerRoundResult: Equatable {
    var snapshot: KairosSnapshot
    var changedItems: Int = 0
    /// 因为规矩 2 被挡下来的：`待办 id -> 字段名`。
    var blocked: [String: [String]] = [:]
    /// being 自己建的条数。
    var createdItems: Int = 0
    /// 它已经建过、这趟又回了一遍的（幂等跳过）。
    var duplicateCreates: Int = 0
    /// 号对不上、标题对不上、值集不认——连同原因，下一趟贴回给 being。
    var rejected: [KairosLedgerRoundRejection] = []

    func report(round: String) -> KairosLedgerRoundReport {
        KairosLedgerRoundReport(
            round: round,
            applied: changedItems,
            created: createdItems,
            duplicates: duplicateCreates,
            rejected: rejected
        )
    }
}

enum KairosLedgerRoundMerge {
    /// 把 being 提的改动并进账本。
    ///
    /// **规矩 2 在这里落地**：人类手改过的字段（`lastWriter[字段] == human`）一律跳过。
    /// being 这条通道上没有「更新的用户信号」可作依据——那是账本 CLI 那条路才有的东西——
    /// 所以这里没有例外，挡下就是挡下。
    ///
    /// 写者戳由 `commit(edit: .beingWrite)` 统一盖，这里不碰 `lastWriter`。
    static func apply(
        _ reply: KairosLedgerRoundReply.Reply,
        to snapshot: KairosSnapshot,
        digest: [KairosLedgerRoundItem],
        projects: [String]
    ) -> KairosLedgerRoundResult {
        var result = KairosLedgerRoundResult(snapshot: snapshot)
        for patch in reply.patches {
            let ref = patch.ref?.trimmingCharacters(in: .whitespaces) ?? ""
            let id = patch.id?.trimmingCharacters(in: .whitespaces) ?? ""
            let label = ref.isEmpty ? (id.isEmpty ? "(没给号)" : id) : ref

            // 只在**本趟的清单**里找。认不出就是认不出，不去整个账本里捞一个 id 相同的——
            // 那正是「凭记忆写」，短号要挡的就是它。
            var found = digest.first { $0.ref == ref && !ref.isEmpty }
            if found == nil, !id.isEmpty { found = digest.first { $0.id == id } }
            guard let entry = found else {
                result.rejected.append(KairosLedgerRoundRejection(
                    ref: label,
                    field: nil,
                    why: ref.isEmpty && id.isEmpty ? "这条没给 ref" : "这个号不在本趟清单里"
                ))
                continue
            }
            if !ref.isEmpty, !id.isEmpty, entry.id != id {
                result.rejected.append(KairosLedgerRoundRejection(
                    ref: label, field: nil, why: "ref 和 id 指的不是同一条"
                ))
                continue
            }
            guard let echo = patch.title else {
                result.rejected.append(KairosLedgerRoundRejection(
                    ref: label, field: nil, why: "没把标题抄回来，对不上是不是同一条"
                ))
                continue
            }
            guard sameTitle(echo, entry.title) else {
                result.rejected.append(KairosLedgerRoundRejection(
                    ref: label, field: nil, why: "标题对不上，我给的是「\(entry.title)」"
                ))
                continue
            }
            guard let index = result.snapshot.items.firstIndex(where: { $0.id == entry.id }) else {
                result.rejected.append(KairosLedgerRoundRejection(
                    ref: label, field: nil, why: "这条刚被了结或删掉了"
                ))
                continue
            }

            let before = result.snapshot.items[index]
            var item = before
            var blocked: [String] = []
            for field in patch.retiredMentioned {
                result.rejected.append(KairosLedgerRoundRejection(
                    ref: label, field: field, why: KairosLedgerPatch.retired[field] ?? "这个字段撤了"
                ))
            }
            // options 不是字符串，不在 `mentioned` 里，单独走一遍同样的三关：
            // 人锁 → 值集 → 写入。
            if let options = patch.options {
                if before.lastWriter["options"] == KairosField.human {
                    blocked.append("options")
                } else if let why = KairosLedgerPatch.optionsRejection(options) {
                    result.rejected.append(KairosLedgerRoundRejection(ref: label, field: "options", why: why))
                } else if options != before.options {
                    item.options = options
                }
            }
            for field in patch.mentioned {
                if before.lastWriter[field] == KairosField.human {
                    blocked.append(field)
                    continue
                }
                if let why = KairosLedgerPatch.rejection(
                    field, value: patch.value(field) ?? "", projects: projects
                ) {
                    result.rejected.append(KairosLedgerRoundRejection(ref: label, field: field, why: why))
                    continue
                }
                item = patch.applied(field, to: item)
            }
            for field in patch.clear ?? [] {
                guard KairosLedgerPatch.clearable.contains(field) else {
                    result.rejected.append(KairosLedgerRoundRejection(
                        ref: label,
                        field: field,
                        why: KairosLedgerPatch.writableAll.contains(field)
                            ? "这个字段不能清空，写一个合法值进来"
                            : "这个字段不归你写"
                    ))
                    continue
                }
                if before.lastWriter[field] == KairosField.human {
                    blocked.append(field)
                    continue
                }
                item = KairosLedgerPatch.cleared(field, in: item)
            }
            if !blocked.isEmpty { result.blocked[entry.id] = blocked }
            guard !KairosField.changed(from: before, to: item).isEmpty else { continue }
            item.updatedAt = KairosClock.now
            result.snapshot.items[index] = item
            result.changedItems += 1
        }
        create(reply.creates, into: &result, projects: projects)
        return result
    }

    /// being 自己建的那些。
    ///
    /// 顺序在 patch 之后：它可能在同一趟里既改旧的又建新的，新建的这几条本趟没有短号
    /// （短号是清单发下去时给的），下一趟才会出现在清单里、才能被改。
    static func create(
        _ creates: [KairosLedgerCreate],
        into result: inout KairosLedgerRoundResult,
        projects: [String]
    ) {
        for create in creates.prefix(KairosLedgerCreate.cap) {
            let id = create.id?.trimmingCharacters(in: .whitespaces) ?? ""
            let label = id.isEmpty ? "(没给 id)" : id
            guard !id.isEmpty, KairosLedgerCreate.isValidID(id) else {
                result.rejected.append(KairosLedgerRoundRejection(
                    ref: label,
                    field: nil,
                    why: "新建要给一个稳定 id（4-64 个字符、不带空格），重发时给同一个我才认得出是同一条"
                ))
                continue
            }
            // 幂等：账本上已经有了就整条跳过。不是错——是它上一趟已经建成了。
            guard !result.snapshot.items.contains(where: { $0.id == id }) else {
                result.duplicateCreates += 1
                continue
            }
            // 人类删过的不再建。删除意图比它的摄入优先——不然删一条它下一趟又送回来。
            guard !result.snapshot.tombstones.contains(where: { $0.id == id }) else {
                result.rejected.append(KairosLedgerRoundRejection(
                    ref: label, field: nil, why: "这条人类删过了，不再建"
                ))
                continue
            }
            let title = create.title?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !title.isEmpty else {
                result.rejected.append(KairosLedgerRoundRejection(
                    ref: label, field: nil, why: "新建必须有标题"
                ))
                continue
            }
            // 值集不认的字段照 patch 那套办：作废那一个，不牵连整条。
            for field in create.mentioned {
                if let why = KairosLedgerPatch.rejection(
                    field, value: create.value(field) ?? "", projects: projects
                ) {
                    result.rejected.append(KairosLedgerRoundRejection(ref: label, field: field, why: why))
                }
            }
            result.snapshot.items.append(create.item(id: id, projects: projects))
            result.createdItems += 1
        }
        if creates.count > KairosLedgerCreate.cap {
            result.rejected.append(KairosLedgerRoundRejection(
                ref: "(新建)",
                field: nil,
                why: "一趟最多建 \(KairosLedgerCreate.cap) 条，多出来的 \(creates.count - KairosLedgerCreate.cap) 条没收，下一趟再来"
            ))
        }
    }

    /// 标题回声比对。空白折叠了再比——它会顺手把换行改成空格，那不算看错行。
    static func sameTitle(_ echo: String, _ sent: String) -> Bool {
        func flatten(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return flatten(echo) == flatten(sent)
    }
}
