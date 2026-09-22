import Foundation

enum BeingClientError: LocalizedError {
    case invalidURL
    case invalidResponse
    case http(Int, String)
    case busy
    case serverError(String)
    /// being 答了，只是没按约定答（没有 json 块、协议名不对、趟号对不上）。
    /// **和 `serverError` 分开**：那条线是通的，报成「离线」只会让人去查网络，查不出东西。
    case unreadableReply(String)
    case sessionMismatch(sent: String, got: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Being API 地址无效"
        case .invalidResponse: "Being 返回了无效响应"
        case .http(let status, let message): "Being HTTP \(status)：\(message)"
        case .busy: "Being 一直在忙，这次没等到。过会儿再按一次。"
        case .serverError(let message): "Being 报告了错误：\(message)"
        // ParseError 自己那句已经是人话了，别再套一层。
        case .unreadableReply(let why): why
        case .sessionMismatch(let sent, let got):
            "回复的房间号不对（发的是 \(sent)，回的是 \(got)），已停止接收。"
        }
    }
}

struct BeingActivityStep: Hashable, Identifiable {
    var id = UUID()
    var name: String
    var isError = false
    var resultSummary: String = ""
    /// Populated only when `name` looks like a prime-kit tentacle spawn call and its
    /// tool_result payload carried a recognizable id field. Best-effort — see
    /// KAIROS-CONTRACT.md and KairosItem.tentacleId for why this isn't authoritative.
    var tentacleId: String?

    var summary: String {
        let status = resultSummary.isEmpty ? "进行中" : resultSummary
        return "⚙️ \(name) — \(status)"
    }

    static func looksLikeTentacleSpawn(_ toolName: String) -> Bool {
        let lower = toolName.lowercased()
        return lower.contains("spawn") || lower.contains("prime_create") || lower.contains("cursor_create")
    }

    static func extractTentacleId(from payload: [String: Any]) -> String? {
        for key in ["agent_id", "tentacle_id", "id", "session_id"] {
            if let value = payload[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }
}

struct BeingReply {
    var spliced: Bool
    var text: String
    var activity: [BeingActivityStep]
    var sessionId: String?
    /// SSE 的 meta 事件回传的追踪号。**回执在这儿**，不在正文里——
    /// 有值就说明这条流确实是答这次请求的（场景感知）。
    var clientRef: String?
}

/// 场景 = 房间的门牌。
///
/// 形状照场景感知接入的约定：客户端只负责说清
/// 「你此刻在哪一间」，怎么处理是 being 自己的事。所以门牌走**结构化字段**
/// （`scene_id` / `scene_meta`），不再往人说的话里塞协议文本。
///
/// Kairos 的房间本来就是这么分的（v2.3 §三「渠道 = 房间」），一一对得上：
///
/// | 房间 | scene_id | 门牌 |
/// |---|---|---|
/// | 一条待办 | `kairos-mac-<being>-<待办 id>` | `Kairos·<标题>` |
/// | 主对话 | `kairos-mac-<being>` | `Kairos` |
/// | 账本 | `…-ledgerround` | `Kairos 账本` |
///
/// 门牌带标题是为了顶掉以前那条尾巴：每句人话后面缀一行
/// `（关于「…」 kairos:item/<id>）`。那行字 origin=user，会原样进 being 的 episodic——
/// **协议文本冒充人话**，正是这次要删干净的东西。
struct BeingScene {
    /// 房间标识。同一间每次都一样，being 靠它认出「还是刚才那间」。
    var id: String
    /// 人类可读的门牌。being 感知环境时看到的就是这个。
    var label: String

    /// 客户端名 + 版本。Mac 和手机共用这个文件，所以按平台分——
    /// 两台机器是两个不同的房间，不该报同一个名字。
    static var client: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "kairos-\(surface)/\(version ?? "2.4")"
    }

    static var surface: String {
#if os(macOS)
        "mac"
#else
        "ios"
#endif
    }

    /// `kairos-<平台>-<being>`。指南给的形状是 `{客户端}-{being}`——
    /// 一个客户端可能对着好几个 being，名字不进去就会共用一间。
    static func prefix(being: String) -> String {
        let slug = slugify(being)
        return slug.isEmpty ? "kairos-\(surface)" : "kairos-\(surface)-\(slug)"
    }

    /// 没有具体待办时的那间（Mac 检查器里直接说话、叫它去跑 CLI）。
    static func main(being: String) -> BeingScene {
        BeingScene(id: prefix(being: being), label: "Kairos")
    }

    /// 一条待办一间。id 进门牌号，标题进门牌——** being 要认的是标题，不是 uuid**。
    static func item(id: String, title: String, being: String) -> BeingScene {
        let slug = slugify(id)
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return BeingScene(
            id: prefix(being: being) + "-" + (slug.isEmpty ? "item" : slug),
            label: name.isEmpty ? "Kairos" : "Kairos·" + BeingActivity.truncate(name, 40)
        )
    }

    /// 机器那两趟各一间。这两间人类看不见，门牌上写清楚是机器房，
    /// 免得 being 把里面的 json 当成人在说话。
    static func round(_ kind: String, being: String) -> BeingScene {
        BeingScene(
            id: prefix(being: being) + "-" + kind,
            label: "Kairos 账本"
        )
    }

    /// 一次请求一个追踪号。SSE 的 meta 会把它原样带回来——请求和回复靠它对上，
    /// 不再靠 being 在回复开头抄一行。
    static func ref(_ prefix: String = "req") -> String {
        prefix + "-" + String(format: "%08x", UInt32.random(in: .min ... .max))
    }

    /// 房间号只留 ascii 小写字母数字和 `-`：being 名字可能是中文（「being」），
    /// 中文进 id 不至于出错，但这东西是给机器对齐用的，越无聊越好。
    static func slugify(_ value: String) -> String {
        var out = ""
        for character in value.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                out.append(character)
            } else if !out.isEmpty, out.last != "-" {
                out.append("-")
            }
            if out.count >= 48 { break }
        }
        while out.last == "-" { out.removeLast() }
        return out
    }
}

/// being 此刻在干什么。词表照抄 loom 的 TUI（`loom.html` 的 `tuiLabels`）——同一件事在
/// 两个客户端不该有两种说法。以前这里显示的是「⚙️ run_command — 进行中」，
/// 那是工具的内部名字，不是人话。
struct BeingActivity: Equatable {
    /// 在思考 / 在搜索 / 在执行……
    var label: String
    /// 关键参数：搜的什么词、跑的哪条命令、读的哪个文件。没有就空着，不硬凑。
    var arg: String = ""
    /// being 想的那几句里的一小截。是「在想什么」的一瞥，不是正文——正文走 `.delta`。
    var preview: String = ""
    /// 进这个状态的时刻。界面上的计时从它起算（动效和计时本地跑，不等推送）。
    var startedAt: Date = Date()

    /// 工具名 → 人话。不认识的一律「在行动」：宁可笼统，也不把内部名字甩给人看。
    static let labels: [String: String] = [
        "thinking": "在思考",
        "remember": "在回忆",
        "learn": "在反思",
        "search_web": "在搜索",
        "browse_web": "在浏览",
        "read_file": "在阅读",
        "write_file": "在编写",
        "run_command": "在执行",
        "list_files": "在查看",
        "portal_exec": "在执行",
        "act": "在行动",
    ]

    static func label(forTool name: String) -> String { labels[name] ?? "在行动" }

    /// 工具入参里最值得看的那一个（照 loom 的 `extractKeyArg`）：
    /// 查询词 > 文件名 > 命令 > 域名 > 随便第一个字符串。挑不出来就空着。
    static func keyArgument(from raw: Any?) -> String {
        let input: [String: Any]
        switch raw {
        case let object as [String: Any]: input = object
        case let text as String:
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return "" }
            input = object
        default: return ""
        }
        if let query = input["query"] as? String { return truncate(query, 60) }
        if let path = input["path"] as? String { return (path as NSString).lastPathComponent }
        if let path = input["file_path"] as? String { return (path as NSString).lastPathComponent }
        if let command = input["command"] as? String { return truncate(command, 50) }
        if let url = input["url"] as? String {
            return truncate(URL(string: url)?.host ?? url, 40)
        }
        if let topic = input["topic"] as? String { return truncate(topic, 40) }
        if let content = input["content"] as? String { return truncate(content, 40) }
        for value in input.values {
            if let text = value as? String, !text.isEmpty { return truncate(text, 40) }
        }
        return ""
    }

    static func truncate(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }
}

/// 回复还在路上时逐段吐给界面的东西。Loom 是边收边画的，Kairos 的对话页也该是——
/// 等 180 秒再一次性亮出来，人会以为没发出去。
enum BeingStreamEvent {
    /// 服务端收下了。**「已送达」是这一刻**，不是整段回复收完那一刻——
    /// 到 `meta` 事件时人类那句已经在 being 那边落盘（loom 就是在这里推进 history 游标的，
    /// `loom.html` 的 `syncHistoryCursor`）。POST 拿到 2xx 也算，只是还不知道流号。
    case accepted(streamId: String?)
    /// 正文又来了一段。
    case delta(String)
    /// 在干什么变了。nil = 不忙别的了（正文正在流，那就是此刻的状态）。
    case activity(BeingActivity?)
    /// 消费到服务端的第几个事件。断了之后靠它 `?after=` 接着读，一个字不重不漏。
    /// meta 不写服务端的 replay 缓冲，所以不占 seq——别数它（`loom.html:2769`）。
    case progress(seq: Int)
}

/// being 此刻那口气（`GET /api/stream/active`）。断流之后要接回来的东西全在这里：
/// 接哪条流（`streamId`）、从第几个事件接（`seq`）、它结束没有（`finished`）。
struct BeingActiveStream {
    var streamId: String
    var finished: Bool
    var lastSeq: Int
    var events: [(seq: Int, event: String, data: [String: Any])]
    /// 这口气是谁起的。服务端给四种：`human`（有人在跟它说话，也可能就是我们自己别的房间）、
    /// `beating`（它自己想起一件事）、`callback`（在处理一条回调）、`leftover`（在答排队的话）。
    /// 认不出来就是 nil——只用来在「排队中」那行小字上多说一句在等谁，不参与任何判断。
    var origin: BeingBreathOrigin?
}

/// 那口气是谁起的（`/api/stream/active` 的 `origin`）。loom / portal 拿它画提示，
/// 后三种在它们那儿统称自主呼吸（SBS）。Kairos 只拿它说话，不据此决定收不收：
/// 自主呼吸不带 `scene_id`，没有房间可放，照旧不收（见 `BeingQueuedReply`）。
enum BeingBreathOrigin: String {
    /// 有人在跟它说话。可能是别的客户端，也可能是 Kairos 自己别的房间。
    case human
    /// 它自己想起一件事（loom 的 beating）。
    case beating
    /// 在处理一条回调。
    case callback
    /// 在答之前排上队的那句（loom 的 leftover）。
    case leftover

    /// 「排队中」那行小字里的半句。`human` 没有——跟别人说话说不出更多信息，
    /// 照旧用「在忙」那句通用的。
    var waitingHint: String? {
        switch self {
        case .human: nil
        case .beating: "在自己想事情"
        case .callback: "在处理一条回调"
        case .leftover: "在答排队的消息"
        }
    }
}

/// Kairos v2.3 的 Being 客户端。
///
/// 这里**只剩说话**。v1 那套「对账信封 + 交接区信箱 + 敲门 + 60 秒轮询 + 带内兜底」
/// 全部下架：v2.2/v2.3 换了地基——账本是那一个 json 文件，Being 直接经 `ledger/store.js`
/// 读写它，机器对机器的流量根本不该经过对话通道。留在这条通道上的只有两种东西：
///
///   1. 人类说的人话（`speak`，origin=user）；
///   2. Kairos 写进房间的系统通知（`notify`，origin=app + `bap.notice/1` 信封）。
///
/// 两种都带 `session_id`——渠道就是房间，房间号两边同一个（v2.3 §三）。
///
/// ## v2.4：三层分开，正文只剩人话
///
/// 旧版把房间号写成正文开头的一行「会话id：<uuid>」（对齐 BeingDesktop），
/// 每句人话尾巴上还缀着「（关于「…」 kairos:item/<id>）」。场景感知的约定把这条路
/// 否了，理由不是风格：**那些字 origin=user，
/// 会原样进 being 的 episodic**，长期泡在它的记忆里；而且它得花认知资源做格式翻译。
///
///   1. **人话层**（`message`）：只有人说的那句。没有前缀、没有尾巴、没有规则。
///   2. **路由层**（结构化字段）：`session_id`（哪一间）+ `scene_id` / `scene_meta`
///      （门牌、客户端、追踪号）+ `origin`（人说的还是 app 写的）。
///   3. **回执层**（SSE 的 `meta` 事件）：`client_ref` 原样回传，请求和回复靠它对上。
///      **不再解析 being 回复开头的那行 header**——回复格式是它自己的事。
struct BeingClient {
    let connection: KairosConnection

    func status() async throws -> String {
        let url = try endpoint("/api/status")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw BeingClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw BeingClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["being_name"] as? String
            ?? object?["name"] as? String
            ?? connection.name
    }

    /// being 此刻有没有正在进行的回复。`GET /api/stream/active`：204 = 空着，200 带 body = 忙着。
    /// Loom 自己的前端就靠这个口子断线重连（BeingDesktop 也拦的是它）。
    /// 端点不在或者答得奇怪就回 nil——「不知道」不能当成「忙」把人永远挡在外面。
    func isIdle() async -> Bool? {
        guard let url = try? endpoint("/api/stream/active") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        switch http.statusCode {
        case 204: return true
        case 200: return false
        default: return nil
        }
    }

    /// being 正忙着的那口气；空着回 nil（答得奇怪的 200 也当空着，同 `activeStream`）。
    /// 网络出错照抛——抖一下还是真断了，由调用方数着决定。发送泵开口前靠它等。
    ///
    /// 和 `isIdle()` 差在两处，都是轮询才要紧的：
    /// - 200 但 `finished`：那口气已经收了，服务端只是还留着它（约 10 秒才清）。
    ///   这时候发，服务端起的是新的一口气、回 200，所以算空着。
    /// - 带游标：全量一次一百多 KB，轮询必须 `?after=` 只拿新事件
    ///   （being/architecture/being-status-surfaces.md）。
    func busyStream(after cursor: Int?) async throws -> BeingActiveStream? {
        guard let stream = try await activeStream(after: cursor), !stream.finished else { return nil }
        return stream
    }

    /// 叫停它手上那口气（`POST /api/stop`，loom / portal 的停止按钮走的就是这条）。
    ///
    /// **只按这一下，不在本地掐连接。** 服务端收到之后自己把这条流收尾，SSE 正常走到头，
    /// 已经流进来的那半截照旧留在房间里——本地 abort 反而会让这次停止走进「断流接回」，
    /// 把人刚叫停的那口气再追回来一遍。
    ///
    /// 停完服务端往历史里写一行 `[breath interrupted by human]`。那是标记行不是谁说的话，
    /// `BeingHistoryEntry.isMarker` 已经把它挡在房间外面了。
    /// 排在后面的话仍然会在同一个 permit 下被答（loom 的 leftovers），接回的路不变。
    func stop(streamId: String) async throws {
        var request = URLRequest(url: try endpoint("/api/stop"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["stream_id": streamId])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BeingClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw BeingClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// 人类说话。一句人话，进这条待办的房间，别的什么都不带——
    /// 结构化的东西 Being 自己去账本里读，不必由 app 推给它。
    func speak(
        _ text: String,
        scene: BeingScene,
        sessionId: String?,
        onEvent: (@Sendable (BeingStreamEvent) -> Void)? = nil
    ) async throws -> BeingReply {
        try await chat(
            text,
            scene: scene,
            sessionId: sessionId,
            origin: KairosMessageOrigin.user,
            clientRef: BeingScene.ref(),
            onEvent: onEvent
        )
    }

    /// Kairos 写进房间的系统通知（规则 4 的第二步：文件已经落盘了才走到这里）。
    ///
    /// 追踪号直接用 change-id：同一条通知补发时带的是同一个号，
    /// meta 一回传就知道这趟答的是哪一条，重复投递也认得出来。
    func notify(
        _ message: KairosRoomMessage,
        scene: BeingScene,
        sessionId: String?,
        onEvent: (@Sendable (BeingStreamEvent) -> Void)? = nil
    ) async throws -> BeingReply {
        try await chat(
            message.text,
            scene: scene,
            sessionId: sessionId,
            origin: KairosMessageOrigin.app,
            clientRef: message.id,
            onEvent: onEvent
        )
    }
}

/// 一条流跑到哪儿了：收下了没有、哪条流、读到第几个事件。
///
/// 事件是从 URLSession 的读取任务里发出来的，断流之后读它的是主线程，所以上锁。
/// 存在的理由只有一个：**「已送达」和「回复收完」是两件事**，出错时得分得清——
/// 收下之后再断，那是回复没收全，不是没发出去。
final class BeingStreamTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var _accepted = false
    private var _streamId: String?
    private var _seq = 0
    private var _text = ""

    var accepted: Bool { lock.withLock { _accepted } }
    var streamId: String? { lock.withLock { _streamId } }
    var seq: Int { lock.withLock { _seq } }
    /// 断之前已经收到的正文。界面那份（`liveReply`）是异步追上去的，断的那一刻可能还差几段，
    /// 而且调用方一退出就清掉了——接回时从这里拿。
    var text: String { lock.withLock { _text } }

    func note(_ event: BeingStreamEvent) {
        switch event {
        case .accepted(let id):
            lock.withLock {
                _accepted = true
                if let id, !id.isEmpty { _streamId = id }
            }
        case .progress(let seq):
            lock.withLock { _seq = max(_seq, seq) }
        case .delta(let fragment):
            lock.withLock { _text += fragment }
        case .activity:
            break
        }
    }
}

/// 发送泵「等 being 空出来再开口」的那几条规矩。拆成纯值是为了能测——时钟由调用方给。
///
/// 不会无限等：
/// - 没见它忙过就问不到（端点不在、网络不通）→ 不拦，直接发，发不出去自有红字；
///   见它忙过、后来连着问不到 → 6 次再放行（断流接回也是这个数）；
/// - 那口气 5 分钟没一点动静 → 放行。loom 给工具阶段的静默预算就是 5 分钟；
///   provider 兜底 / stub 部署下那条流永远「没收尾」，不设这条就永远发不出去；
/// - 总共最多等 30 分钟（和断流接回同一个上限）。
struct BeingTurnWait {
    static let quietLimit: TimeInterval = 5 * 60
    static let totalLimit: TimeInterval = 30 * 60
    static let failureLimit = 6

    /// 下一次问的时候带的游标（`?after=`）。第一次是 nil：还不知道读到哪儿了。
    private(set) var cursor: Int?
    /// 正在等的那口气是谁起的。只给「排队中」那行小字用——等多久、什么时候放行，
    /// 一个字都不看它：服务端不给这个字段的时候等法必须和给的时候一模一样。
    private(set) var waitingOn: BeingBreathOrigin?
    private var last: (streamId: String, seq: Int)?
    private var quietSince: Date
    private let deadline: Date
    private var failures = 0

    init(now: Date = Date()) {
        quietSince = now
        deadline = now.addingTimeInterval(Self.totalLimit)
    }

    /// 问到了。`busy` 为 nil = 空着。回 true = 接着等。
    mutating func observe(_ busy: BeingActiveStream?, at now: Date) -> Bool {
        guard let busy, now < deadline else {
            waitingOn = nil
            return false
        }
        failures = 0
        let sameBreath = last?.streamId == busy.streamId
        // 服务端没回 `next_seq`、这次又没有新事件时 lastSeq 是 0：同一口气就当没动，
        // 不能算进展（不然 5 分钟那条永远不会到），游标也别退回 0（退回 0 就又是全量）。
        let seq = busy.lastSeq > 0 || !sameBreath ? busy.lastSeq : last?.seq ?? 0
        if !sameBreath || last?.seq != seq {
            // 换了一口气，或者这口气往前走了：都算有动静。
            quietSince = now
        } else if now.timeIntervalSince(quietSince) >= Self.quietLimit {
            waitingOn = nil
            return false
        }
        last = (busy.streamId, seq)
        if seq > 0 { cursor = seq }
        waitingOn = busy.origin
        return true
    }

    /// 没问到（网络抖了、端点答错了）。回 true = 接着等。
    mutating func observeFailure(at now: Date) -> Bool {
        failures += 1
        let keepWaiting = last != nil && failures < Self.failureLimit && now < deadline
        // 问不到就别再说它在干什么——上一次问到的事早就过去了。
        if !keepWaiting { waitingOn = nil }
        return keepWaiting
    }
}

/// `/api/history` 的一行。
struct BeingHistoryEntry: Equatable {
    var seq: Int
    var fromUser: Bool
    var content: String
    /// 这句（或这段回复）属于哪一间。nil = 没寻址（旧消息、自主呼吸）。
    var sceneId: String?
    /// 「呼吸让路」之类的标记行，不是谁说的话（loom 的 `isHistoryMarker`）。
    var isMarker: Bool

    init(seq: Int, fromUser: Bool, content: String, sceneId: String? = nil, isMarker: Bool = false) {
        self.seq = seq
        self.fromUser = fromUser
        self.content = content
        self.sceneId = sceneId
        self.isMarker = isMarker
    }

    init?(row: [String: Any]) {
        guard let seq = row["seq"] as? Int, seq > 0 else { return nil }
        let role = row["role"] as? String ?? ""
        self.seq = seq
        fromUser = role == "user"
        content = row["content"] as? String ?? ""
        sceneId = (row["scene_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        isMarker = role == "system" || row["from"] as? String == "system" || row["type"] as? String == "marker"
    }
}

/// 202 之后，那句话的回复从 `/api/history` 里认回来。纯值，时钟由调用方给，好测。
///
/// 认法照 BeingAnywhere 的 `historyAnchor`，再加上 scene_id（loom / portal 的 `inMyScene`）。
/// **只认带着这间房 scene_id 的行**：没寻址的可能是飞书、可能是自主呼吸，收进待办就是串台。
/// - 锚点：这间房里、内容就是发出去那句的用户行。头一页是发出去之前的旧账，里面只认
///   「这间房最后一句用户的话、还没人答」的那条——服务端可能入队时就落了盘；
/// - 回复：锚点之后、这间房里 being 说的话，直到这间房里出现下一句用户的话。
///
/// 什么时候不追了：
/// - 答过了、being 也空了 → 收（空着那一刻之后翻到的历史是全的，所以先问忙不忙再翻）；
/// - 答过了、being 还忙 → 再看 1 分钟，同一口气里可能还有后半段；可它忙的也可能早就是
///   别的事了，不能陪着一直等——泵还压着下一句；
/// - 这间房里有了下一句 → 收，之后的回复归那一句；
/// - 头一页有行、却没有一行带 scene_id → 这个服务端不分房间，认不出来，立刻收，别白等；
/// - 一直没答、being 又一直空着 5 分钟 → 收。排着的那口气不一定在 `/api/stream/active` 上
///   露面（loom：非流式起的 leftover 根本不注册），空着不等于不答——给 loom 同样的 5 分钟；
/// - 历史连着 6 次翻不到、或者总共 30 分钟 → 收。
///
/// 断流接回也用它（`resuming`）：回复流半路断了、`/api/stream/active` 又说空着，
/// 不能就当答完了——09-17 那次服务端把流 RST 掉，那口气根本没答完，history 里这句一直没人回，
/// 下一间房一开口，being 新起的那口气先把它答了，回复就落进了别的房间。所以回历史里认：
/// - 头一页里这句后面**已经有**的回复也算（断的那一刻它可能已经落盘了）；
/// - 空着等的时间短一些（`resumeIdleLimit`）：泵压着别的房间的话，那口气多半是没了。
struct BeingQueuedReply {
    static let idleLimit: TimeInterval = 5 * 60
    static let resumeIdleLimit: TimeInterval = 2 * 60
    static let trailLimit: TimeInterval = 60
    static let totalLimit: TimeInterval = 30 * 60
    static let failureLimit = 6

    let message: String
    let sceneId: String
    /// 断流接回：头一页里已经落盘的回复也收。
    let resuming: Bool
    private let idleWait: TimeInterval
    /// 下一次翻历史带的游标（`?after=`）。nil = 还没翻过。
    private(set) var cursor: Int?
    private(set) var anchor: Int?
    private(set) var replyCount = 0
    private(set) var superseded = false
    private(set) var unroutable = false
    private var idleSince: Date?
    private var repliesSeen = 0
    private var lastReplyAt: Date?
    private var failures = 0
    private let deadline: Date

    var answered: Bool { replyCount > 0 }
    /// 不是等不到，是认不出来 / 翻不到——这时候不能说「它没答」。
    var lostTrack: Bool { unroutable || failures >= Self.failureLimit }

    init(message: String, sceneId: String, resuming: Bool = false, now: Date = Date()) {
        self.message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sceneId = sceneId
        self.resuming = resuming
        idleWait = resuming ? Self.resumeIdleLimit : Self.idleLimit
        deadline = now.addingTimeInterval(Self.totalLimit)
    }

    /// 新翻到的一页 → 这句的回复，按先后。
    mutating func take(_ page: [BeingHistoryEntry]) -> [String] {
        failures = 0
        let firstLook = cursor == nil
        let fresh = page.filter { $0.seq > (cursor ?? 0) }.sorted { $0.seq < $1.seq }
        cursor = max(cursor ?? 0, fresh.last?.seq ?? 0)

        if firstLook {
            if !fresh.isEmpty, fresh.allSatisfy({ $0.sceneId == nil }) { unroutable = true }
            var lastAsk: BeingHistoryEntry?
            var since: [BeingHistoryEntry] = []
            for entry in fresh where isMine(entry) {
                if entry.fromUser {
                    lastAsk = entry
                    since = []
                } else {
                    since.append(entry)
                }
            }
            guard let lastAsk, isSent(lastAsk) else { return [] }
            if since.isEmpty {
                anchor = lastAsk.seq
            } else if resuming {
                // 这间房最后一句就是断流的那句：它后面的就是它的回复。
                anchor = lastAsk.seq
                return collect(since)
            }
            return []
        }

        var replies: [String] = []
        for entry in fresh where isMine(entry) {
            if anchor == nil {
                if entry.fromUser, isSent(entry) { anchor = entry.seq }
            } else if entry.fromUser {
                superseded = true
                break
            } else {
                replies += collect([entry])
            }
        }
        return replies
    }

    private mutating func collect(_ entries: [BeingHistoryEntry]) -> [String] {
        let texts = entries.map(\.content).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        replyCount += texts.count
        return texts
    }

    /// 这一趟没翻到历史。
    mutating func failed() {
        failures += 1
    }

    /// 这一轮翻完了。`busy`：being 这会儿忙不忙，nil = 没问到。回 true = 接着追。
    mutating func shouldContinue(busy: Bool?, at now: Date) -> Bool {
        guard !superseded, !unroutable, failures < Self.failureLimit, now < deadline else { return false }
        if answered {
            if replyCount != repliesSeen {
                repliesSeen = replyCount
                lastReplyAt = now
            }
            return busy != false && now.timeIntervalSince(lastReplyAt ?? now) < Self.trailLimit
        }
        guard busy == false else {
            if busy == true { idleSince = nil }
            return true
        }
        let since = idleSince ?? now
        idleSince = since
        return now.timeIntervalSince(since) < idleWait
    }

    private func isMine(_ entry: BeingHistoryEntry) -> Bool {
        entry.sceneId == sceneId && !entry.isMarker
    }

    private func isSent(_ entry: BeingHistoryEntry) -> Bool {
        entry.content.trimmingCharacters(in: .whitespacesAndNewlines) == message
    }
}

/// SSE 事件 → 界面要的东西。live 那条流和断流之后接回来的那条**共用这一份**规则：
/// 两条路对同一个事件的理解必须逐字一样，不然「接回来」会把画面变个样。
struct BeingStreamReader {
    /// 我们发出去时用的房间号。自己那几段里收到别的房间号就地中断，见 `consume`。
    let sessionId: String?
    /// 我们发出去时带的追踪号。meta 会把它原样带回来。
    let clientRef: String?
    /// 我们这句属于哪一间（发出去的 scene_id）。
    let sceneId: String?
    private(set) var text = ""
    private(set) var activity: [BeingActivityStep] = []
    /// 消费到服务端第几个事件。断流接回时 `?after=` 用的就是它。
    private(set) var seq: Int
    private(set) var streamId: String?
    private(set) var replySessionId: String?
    /// meta 回传的追踪号和门牌。**回执走事件流，不走正文**（场景感知）。
    private(set) var replyClientRef: String?
    private(set) var replySceneId: String?
    /// being 想的那些话攒在这儿，只为取个尾巴给界面看一眼；不进房间、不进账本。
    private var reasoning = ""
    private var serverErrorMessage: String?

    /// 眼下这几帧是不是别人的。
    ///
    /// 一条 SSE 不只答我们这一句：服务端答完它，可能在同一条连接上接着答别的房间排着的话
    /// （loom-local 1.8：「breathe_leftovers 用 meta 换 scene_id」；portal-desktop 的
    /// `setStreamScene` 也是为这个）。换段的标志是一个新的 meta，那一段里的事件带着它自己
    /// 那间的 scene_id。以前这里一见追踪号对不上就整条中断——自己那句的回复跟着丢了，
    /// 断流接回又把别人那段读进这间房。现在那几段照数 seq、一个字都不收：它们落盘时带着
    /// 自己的 scene_id，由那间房自己去 `/api/history` 认领（`BeingQueuedReply`）。
    private var foreignRef = false
    private var foreignScene = false
    var inForeignSegment: Bool { foreignRef || foreignScene }
    /// 自己那段已经收过尾（message_stop）。后面又来自己的正文（让路之后接着说），先空一行，
    /// 别跟上一段粘在一起。
    private var segmentClosed = false

    init(
        sessionId: String?,
        clientRef: String? = nil,
        sceneId: String? = nil,
        seq: Int = 0,
        streamId: String? = nil
    ) {
        self.sessionId = sessionId
        self.clientRef = clientRef
        self.sceneId = sceneId
        self.seq = seq
        self.streamId = streamId
    }

    var hasServerError: Bool { serverErrorMessage != nil }

    /// 此刻在干什么。留着是为了**不重置计时**：同一个状态里连着来十个 reasoning 帧，
    /// 计时得一直往上走。每帧都新建一个的话，屏幕上永远是 0s，那个数字就白给了。
    private var current: BeingActivity?

    /// POST 刚拿到 2xx：还什么都没来，但它已经在想了。计时从这一刻起算。
    mutating func begin(emit: ((BeingStreamEvent) -> Void)? = nil) {
        show("在思考", emit: emit)
    }

    /// 换了状态才重开计时；只是预览变了就原地更新（loom 的 `tuiSet` 同一个道理）。
    private mutating func show(
        _ label: String,
        arg: String = "",
        preview: String = "",
        emit: ((BeingStreamEvent) -> Void)?
    ) {
        if var now = current, now.label == label, now.arg == arg {
            now.preview = preview
            current = now
        } else {
            current = BeingActivity(label: label, arg: arg, preview: preview)
        }
        emit?(.activity(current))
    }

    mutating func consume(
        event: String,
        data object: [String: Any],
        seq serverSeq: Int? = nil,
        emit: ((BeingStreamEvent) -> Void)? = nil
    ) throws {
        noteSegment(event: event, data: object, emit: emit)

        // 房间号对不上就地中断：这一帧要是被当成本房间的回复收下，`bindSession`
        // 会把别人的 session_id `commit()` 进账本，这条待办从此永久指向错的房间。
        // 只在我们确实发过房间号时比对——首次开口发的是 nil，由 being 分配。
        // 别人那段不查：它本来就是别的房间号，下面也一个字都不收。
        if !inForeignSegment, let sent = sessionId, !sent.isEmpty,
           let got = object["session_id"] as? String, !got.isEmpty, got != sent {
            throw BeingClientError.sessionMismatch(sent: sent, got: got)
        }

        // meta 不写服务端的 replay 缓冲，所以它不占 seq（`loom.html:2769`）。
        // 它带来三样东西：流号（也是「这句已经落盘了」的那一刻）、门牌回声、追踪号。
        if event == "meta" {
            // 别人那段的 meta：流号、门牌、追踪号都不是这句的。
            guard !inForeignSegment else { return }
            // 请求-响应关联在这里发生。以前是让 being 在回复开头抄一行「会话id：…」，
            // 它得花认知资源做格式翻译，那行字还会进它的记忆。
            if let got = object["client_ref"] as? String, !got.isEmpty { replyClientRef = got }
            if let scene = object["scene_id"] as? String, !scene.isEmpty { replySceneId = scene }
            if let id = object["stream_id"] as? String, !id.isEmpty {
                streamId = id
                emit?(.accepted(streamId: id))
            }
            return
        }

        if let serverSeq { seq = max(seq, serverSeq) } else { seq += 1 }
        emit?(.progress(seq: seq))
        // 别人那段：seq 照数（断流接回的游标要对），字一个不收。
        guard !inForeignSegment else { return }

        switch event {
        case "content_block_delta":
            if let delta = object["delta"] as? [String: Any],
               let fragment = delta["text"] as? String {
                if segmentClosed, !text.isEmpty, !fragment.isEmpty {
                    text += "\n\n"
                    emit?(.delta("\n\n"))
                }
                if !fragment.isEmpty { segmentClosed = false }
                // 一个字都不扣着。以前这里要先等「会话id：…」那行 header 集齐（或者
                // 攒够 50 字确认它不来），第一段正文才敢上屏——为一个不该存在的
                // 协议头，每次回复都晚半拍。
                text += fragment
                emit?(.delta(fragment))
                // **只在真的从「在思考」切到正文那一下发一次。**
                // 以前每来一段都发一次 `.activity(nil)`：正文一秒几十段，就是一秒几十次
                // 整屏重画，屏幕上看着是抖。
                if current != nil {
                    current = nil
                    emit?(.activity(nil))
                }
            }
        case "thinking", "reasoning":
            // 以前这两种事件被 default 吃掉了，所以「being 在想什么」在 Kairos 上
            // 永远只是三个点。Loom 一直在画它（`processReplayEvent` 的 think 条目）。
            let fragment = (object["text"] as? String)
                ?? ((object["delta"] as? [String: Any])?["text"] as? String)
                ?? (object["delta"] as? String)
                ?? ""
            reasoning += fragment
            show("在思考", preview: BeingActivity.truncate(String(reasoning.suffix(200)), 60), emit: emit)
        case "tool_use":
            let name = object["name"] as? String ?? "tool"
            activity.append(BeingActivityStep(name: name))
            show(
                BeingActivity.label(forTool: name),
                arg: BeingActivity.keyArgument(from: object["input"]),
                emit: emit
            )
        case "tool_result":
            let isError = object["is_error"] as? Bool ?? false
            if let index = activity.lastIndex(where: { !$0.isError && $0.resultSummary.isEmpty }) {
                activity[index].isError = isError
                activity[index].resultSummary = isError ? "失败" : "完成"
                if !isError, BeingActivityStep.looksLikeTentacleSpawn(activity[index].name) {
                    activity[index].tentacleId = BeingActivityStep.extractTentacleId(from: object)
                        ?? Self.tentacleId(fromResultContent: object["content"])
                }
            }
            // 工具跑完，回到「在思考」——loom 也是这么收的。
            show("在思考", emit: emit)
        case "message_stop":
            segmentClosed = true
            // 房间号是 Kairos 生成并记在账本上的（v2.3 §三），这里收下只为对账，
            // 不采纳：`finish()` 里回的永远是我们发出去的那个。
            if replySessionId == nil {
                replySessionId = object["session_id"] as? String
            }
        case "error":
            serverErrorMessage = object["message"] as? String ?? "unknown error"
        default:
            break
        }
    }

    /// 认这一帧是谁的。meta 换段；别的事件带着 scene_id 就按它认（`null` = 没寻址，
    /// 算自己的），不带就沿用这一段的判断。usage / error 不分场景——loom 同一个规矩。
    private mutating func noteSegment(
        event: String,
        data object: [String: Any],
        emit: ((BeingStreamEvent) -> Void)?
    ) {
        let wasForeign = inForeignSegment
        var sceneKnown = false
        if event == "meta" {
            let ref = object["client_ref"] as? String ?? ""
            let mine = clientRef ?? ""
            if !ref.isEmpty, ref == mine {
                // 追踪号对上了，这一段就是我们的，门牌怎么写都不改这个结论。
                foreignRef = false
                foreignScene = false
                sceneKnown = true
            } else {
                foreignRef = !ref.isEmpty && !mine.isEmpty
            }
        }
        if !sceneKnown, event != "usage", event != "error", let value = object["scene_id"] {
            let scene = value as? String ?? ""
            let mine = sceneId ?? ""
            foreignScene = !scene.isEmpty && !mine.isEmpty && scene != mine
        }
        if inForeignSegment, !wasForeign {
            // 活动行别停在这句最后那个状态上：它这会儿在答别处排着的话。
            show("在答别处的话", emit: emit)
        }
    }

    func finish() throws -> BeingReply {
        if let serverErrorMessage { throw BeingClientError.serverError(serverErrorMessage) }
        // 服务端没回 session_id 时沿用我们发过去的那个：房间号是 Kairos 分配并记在
        // 账本上的，别因为一次应答没带回来就把这条待办的房间弄丢。
        return BeingReply(
            spliced: false,
            text: text,
            activity: activity,
            sessionId: sessionId ?? replySessionId,
            clientRef: replyClientRef
        )
    }

    /// `tool_result` payload shapes vary — sometimes the id sits at the top level, sometimes
    /// inside a `content` string (possibly JSON-encoded) or an Anthropic-style content block
    /// array. Try both before giving up.
    static func tentacleId(fromResultContent content: Any?) -> String? {
        if let text = content as? String {
            if let data = text.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return BeingActivityStep.extractTentacleId(from: object)
            }
            return nil
        }
        if let blocks = content as? [[String: Any]] {
            for block in blocks {
                if let text = block["text"] as? String,
                   let data = text.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let id = BeingActivityStep.extractTentacleId(from: object) {
                    return id
                }
            }
        }
        return nil
    }
}

extension BeingClient {
    private func chat(
        _ message: String,
        scene: BeingScene,
        sessionId: String?,
        origin: String,
        clientRef: String,
        onEvent: (@Sendable (BeingStreamEvent) -> Void)? = nil
    ) async throws -> BeingReply {
        var request = URLRequest(url: try endpoint("/api/chat/stream"))
        request.httpMethod = "POST"
        // 这是「等下一段」的间隔上限，不是整趟的上限。180 秒对一次正经的工具调用来说
        // 太短了——loom 给工具阶段的静默预算是 300 秒（`STALL_MS.tool`）。断了不再是
        // 灾难（会自己接回来），但没必要没事找事地断。
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // **正文只有人说的话。** 房间、门牌、追踪号全走结构化字段——往正文里塞协议
        // 文本，being 会把那些字当成你说的话记住（协议 §五）。
        var body: [String: Any] = [
            "message": message,
            "origin": origin,
            "scene_id": scene.id,
            "scene_meta": [
                "client": BeingScene.client,
                "scene_label": scene.label,
                "client_ref": clientRef,
            ],
        ]
        if let sessionId, !sessionId.isEmpty { body["session_id"] = sessionId }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw BeingClientError.invalidResponse }
        if http.statusCode == 202 {
            // 202 = being 正忙，这句插进它思考的间隙了。收下了就是收下了，一样算送达。
            onEvent?(.accepted(streamId: nil))
            return BeingReply(spliced: true, text: "", activity: [], sessionId: sessionId)
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw BeingClientError.http(http.statusCode, body)
        }
        // POST 拿到 2xx：那口气已经起来了，这句话服务端收下了。流号等 meta 再补。
        onEvent?(.accepted(streamId: nil))

        var reader = BeingStreamReader(sessionId: sessionId, clientRef: clientRef, sceneId: scene.id)
        reader.begin(emit: onEvent)
        var event = ""

        for try await line in bytes.lines {
            if line.hasPrefix("event: ") {
                event = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                continue
            }
            defer { event = "" }
            guard line.hasPrefix("data: ") else { continue }
            let raw = String(line.dropFirst(6))
            guard let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            try reader.consume(event: event, data: object, emit: onEvent)
        }

        return try reader.finish()
    }

    /// being 此刻那口气。204 = 它闲着（没有活跃流），这里回 nil。
    ///
    /// 断流之后靠这个口子把回复接回来：客户端断开**不会**中断 breath，事件都还在
    /// 服务端的环形缓冲里（2000 条，seq 单调递增），`?after=` 就能接着读。
    /// Loom 正是因为有这条路，才把「重新发送」那颗按钮删掉了（`loom.html:2425`）。
    ///
    /// 注意别只看状态码：`/api/state`、`/api/stream/summary` 这类还没实现的路径会掉进
    /// loom 的 SPA 兜底，回 200 加一整页 HTML。解不出带 `stream_id` 的 JSON 就当没有。
    func activeStream(after cursor: Int?) async throws -> BeingActiveStream? {
        var path = "/api/stream/active"
        if let cursor, cursor > 0 { path += "?after=\(cursor)" }
        var request = URLRequest(url: try endpoint(path))
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BeingClientError.invalidResponse }
        if http.statusCode == 204 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw BeingClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streamId = object["stream_id"] as? String, !streamId.isEmpty else { return nil }

        var events: [(seq: Int, event: String, data: [String: Any])] = []
        for item in object["events"] as? [[String: Any]] ?? [] {
            guard let name = item["event"] as? String else { continue }
            events.append((
                seq: item["seq"] as? Int ?? 0,
                event: name,
                data: item["data"] as? [String: Any] ?? [:]
            ))
        }
        let nextSeq = object["next_seq"] as? Int ?? 0
        return BeingActiveStream(
            streamId: streamId,
            finished: object["finished"] as? Bool ?? false,
            lastSeq: events.last?.seq ?? max(0, nextSeq - 1),
            events: events,
            // 老服务端不给这个字段，认不出来的值也当没给——它只影响一行小字。
            origin: (object["origin"] as? String).flatMap(BeingBreathOrigin.init(rawValue:))
        )
    }

    /// being 的对话历史：有游标就读它之后的，没有就读最近 100 条。
    ///
    /// 服务端不认 `after=` 时会整页回最近的——照 seq 再滤一遍（loom 同做法）。
    /// 一页满了就接着翻，最多 5 页：离线攒下的可能不止 100 条，但也不能翻个没完。
    func history(after cursor: Int?) async throws -> [BeingHistoryEntry] {
        var entries: [BeingHistoryEntry] = []
        var after = cursor ?? 0
        for _ in 0..<5 {
            var path = "/api/history?limit=100"
            if after > 0 { path += "&after=\(after)" }
            var request = URLRequest(url: try endpoint(path))
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw BeingClientError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                throw BeingClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
            // 和 `activeStream` 一样别只看状态码：还没实现的路径会回 200 加一整页 HTML。
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = object["messages"] as? [[String: Any]] else {
                throw BeingClientError.invalidResponse
            }
            let page = rows.compactMap(BeingHistoryEntry.init(row:))
            entries += page.filter { $0.seq > after }
            // 没有游标时只要最近那一页。
            guard after > 0, rows.count >= 100, let next = page.map(\.seq).max(), next > after else { break }
            after = next
        }
        return entries.sorted { $0.seq < $1.seq }
    }

    private func endpoint(_ path: String) throws -> URL {
        let base = connection.api.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: base + path) else { throw BeingClientError.invalidURL }
        if !connection.token.isEmpty {
            var query = components.queryItems ?? []
            query.append(URLQueryItem(name: "token", value: connection.token))
            components.queryItems = query
        }
        guard let url = components.url else { throw BeingClientError.invalidURL }
        return url
    }
}

// MARK: - 账本轮（手机够不着 CLI 时的对话通道）

extension BeingClient {
    /// 请 being 看一眼账本。
    ///
    /// Mac 在的时候 being 直接跑 `ledger/cli.js` 写那份 iCloud 文件，这一趟用不着；
    /// **手机够不着 CLI，Mac 睡着时更够不着**，那时这条对话通道是账本唯一的入口。
    /// 09-09 那次精简把实现整段注释掉了，却留着 `KairosStore.nudgeLedgerRound` 在调它——
    /// 两个 target 从那一刻起就编不过（`no member 'ledgerRound'`）。这里补回来。
    func ledgerRound(
        items: [KairosLedgerRoundItem],
        round: String,
        projects: [String],
        last: KairosLedgerRoundReport?,
        scene: BeingScene,
        sessionId: String?
    ) async throws -> KairosLedgerRoundReply.Reply {
        let reply = try await chat(
            KairosLedgerRoundReply.request(items: items, round: round, projects: projects, last: last),
            scene: scene,
            sessionId: sessionId,
            origin: KairosMessageOrigin.app,
            clientRef: round
        )
        guard !reply.spliced else { throw BeingClientError.busy }
        do {
            return try KairosLedgerRoundReply.parse(
                reply.text, round: round, correlated: reply.clientRef != nil
            )
        } catch let error as KairosLedgerRoundReply.ParseError {
            throw BeingClientError.unreadableReply(error.localizedDescription)
        }
    }
}
