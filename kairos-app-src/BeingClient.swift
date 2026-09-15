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
    case refMismatch(sent: String, got: String)

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
        case .refMismatch(let sent, let got):
            "这条流答的不是这次请求（发的是 \(sent)，回的是 \(got)），已停止接收。"
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
/// | 邮局 / 账本 | `…-mailround` / `…-ledgerround` | `Kairos 邮局` / `Kairos 账本` |
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
            label: kind == KairosRoundKind.mail ? "Kairos 邮局" : "Kairos 账本"
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

    /// Kairos 写进房间的系统通知（规矩 4 的第二步：文件已经落盘了才走到这里）。
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

    var accepted: Bool { lock.withLock { _accepted } }
    var streamId: String? { lock.withLock { _streamId } }
    var seq: Int { lock.withLock { _seq } }

    func note(_ event: BeingStreamEvent) {
        switch event {
        case .accepted(let id):
            lock.withLock {
                _accepted = true
                if let id, !id.isEmpty { _streamId = id }
            }
        case .progress(let seq):
            lock.withLock { _seq = max(_seq, seq) }
        case .delta, .activity:
            break
        }
    }
}

/// SSE 事件 → 界面要的东西。live 那条流和断流之后接回来的那条**共用这一份**规则：
/// 两条路对同一个事件的理解必须逐字一样，不然「接回来」会把画面变个样。
struct BeingStreamReader {
    /// 我们发出去时用的房间号。收到别的房间的帧就地中断，见 `consume`。
    let sessionId: String?
    /// 我们发出去时带的追踪号。meta 会把它原样带回来，对不上就地中断——
    /// 那条流答的是别人的请求，收进来就是张冠李戴。
    let clientRef: String?
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

    init(sessionId: String?, clientRef: String? = nil, seq: Int = 0, streamId: String? = nil) {
        self.sessionId = sessionId
        self.clientRef = clientRef
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
        // 房间号对不上就地中断：这一帧要是被当成本房间的回复收下，`bindSession`
        // 会把别人的 session_id `commit()` 进账本，这条待办从此永久指向错的房间。
        // 只在我们确实发过房间号时比对——首次开口发的是 nil，由 being 分配。
        if let sent = sessionId, !sent.isEmpty,
           let got = object["session_id"] as? String, !got.isEmpty, got != sent {
            throw BeingClientError.sessionMismatch(sent: sent, got: got)
        }

        // meta 不写服务端的 replay 缓冲，所以它不占 seq（`loom.html:2769`）。
        // 它带来三样东西：流号（也是「这句已经落盘了」的那一刻）、门牌回声、追踪号。
        if event == "meta" {
            // 请求-响应关联在这里发生。以前是让 being 在回复开头抄一行「会话id：…」，
            // 它得花认知资源做格式翻译，那行字还会进它的记忆。
            if let got = object["client_ref"] as? String, !got.isEmpty {
                if let sent = clientRef, !sent.isEmpty, got != sent {
                    throw BeingClientError.refMismatch(sent: sent, got: got)
                }
                replyClientRef = got
            }
            if let scene = object["scene_id"] as? String, !scene.isEmpty { replySceneId = scene }
            if let id = object["stream_id"] as? String, !id.isEmpty {
                streamId = id
                emit?(.accepted(streamId: id))
            }
            return
        }

        if let serverSeq { seq = max(seq, serverSeq) } else { seq += 1 }
        emit?(.progress(seq: seq))

        switch event {
        case "content_block_delta":
            if let delta = object["delta"] as? [String: Any],
               let fragment = delta["text"] as? String {
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

        var reader = BeingStreamReader(sessionId: sessionId, clientRef: clientRef)
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
            events: events
        )
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

// MARK: - 一趟邮局（手机单机之后的直连，2026-09-08）

extension BeingClient {
    /// 请 being 跑一趟邮局：取回收发件箱，顺手把这台设备待发的信投出去。
    ///
    /// ## 为什么这条走对话通道
    ///
    /// 手机够不着 Town（IP 信任只认 being 的 Heart），但够得着 being——
    /// loom 那条线本来就通、本来就带 token。手机改单机之后，**Loom 是手机和 being 之间
    /// 唯一存在的直连**：没有共享文件系统了，being 也伸不进 iOS 沙盒。
    ///
    /// v2.3 说过「机器对机器的流量不该经过对话通道」。那条规矩的前提是两边共享一个
    /// 文件系统——前提没了，规矩就不适用了；硬守着它的结果是这个功能根本不存在。
    /// 等 Loom 开出结构化的口子（`/api/town/messages` 之类），换掉这一层就行，
    /// 上面的 UI 和合并规则（`KairosMailMerge`）一行都不用动。
    ///
    /// 信封带 `bap.mailround/1` + origin=app：这不是人类说的话，别记进 episodic。
    func mailRound(
        drafts: [KairosMailDraft],
        round: String,
        scene: BeingScene,
        sessionId: String?
    ) async throws -> KairosMailRound {
        let reply = try await chat(
            KairosMailRoundReply.request(drafts: drafts, round: round),
            scene: scene,
            sessionId: sessionId,
            origin: KairosMessageOrigin.app,
            // 趟号就是追踪号：meta 把它原样带回来，这趟答的是哪一问不用问 being。
            clientRef: round
        )
        guard !reply.spliced else { throw BeingClientError.busy }
        do {
            return try KairosMailRoundReply.parse(
                reply.text, round: round, drafts: drafts, correlated: reply.clientRef != nil
            )
        } catch let error as KairosMailRoundReply.ParseError {
            throw BeingClientError.unreadableReply(error.localizedDescription)
        }
    }

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
