import Foundation
import SwiftUI

enum KairosFiles {
#if os(macOS)
    static let configDirectory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".kairos", isDirectory: true)
    static let legacyProjection: URL? = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Documents/Workspace/being/dashboard/projection-snapshot.json")
#else
    static let configDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Kairos", isDirectory: true)
    static let legacyProjection: URL? = nil
#endif
    static let connection = configDirectory.appendingPathComponent("connection.json")

    /// 账本所在的文件夹。**v2.4 起是可选的**（`KairosLedgerLocation`）：
    /// 默认本机（Mac `~/.kairos`、手机「文稿」），接了 iCloud 就是那个共享文件夹。
    /// Node 侧 `ledger/paths.js` 按同一顺序解析同一个指针文件——两侧必须指同一个文件，
    /// 那是 v2.3 §五「没有两份副本」的底线。
    ///
    /// 手机上「关联」走的是安全作用域书签（`SharedLedgerFolder`），不是这里：
    /// 沙盒里存一个绝对路径下次启动就没权限了。所以手机这里永远是本机那份。
    static var dataDirectory: URL { KairosLedgerLocation.folder }
    static var snapshot: URL { KairosLedgerLocation.ledger }

    /// 派生文件的家（v2.3 §五推论①）：房间日志 / 已读游标 / outbox 全部留在本机，
    /// 不进 iCloud——它们是本机状态，跨设备飘过去只会互相打架。
    static let localDirectory = configDirectory
    static let locksDirectory = configDirectory.appendingPathComponent("locks", isDirectory: true)
    static let rooms = configDirectory.appendingPathComponent("rooms.json")

    static func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: configDirectory.path
        )
    }

    static func ensureDataDirectory() throws {
        try FileManager.default.createDirectory(
            at: dataDirectory,
            withIntermediateDirectories: true
        )
    }

    static func writePrivate(_ data: Data, to url: URL) throws {
        try ensureDirectory()
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    // MARK: - iCloud 落地

    /// 账本住在 iCloud，系统会把不常用的文件逐出成占位符（dataless）。这时
    /// `fileExists` **仍然返回 true**，读却抛 EAGAIN(-11)——2026-09-07 being 第一次跑
    /// doctor 就撞上了。不单独认出这种情况的话，表现是「文件在但读不了」，
    /// 会被误判成账本损坏而进写保护：用户打开 Kairos 只看到一句「无法读取」，
    /// 且从此拒绝一切写入，而真相只是文件还在云上。
    enum LedgerReadError: LocalizedError {
        case notMaterialized

        var errorDescription: String? {
            "账本还在 iCloud 云端没落地（dataless）；已请求下载，稍后自动重试。"
        }
    }

    static func isMaterialized(_ url: URL) -> Bool {
        // **能读到就算落地了。** iCloud 的元数据在进程刚起来时会间歇性答「没落地」（连撞两次：一次邮箱永远「没接通」，一次账本一启动就弹「还在云端」而且列表是空的）。
        // 真的 dataless 文件读第一个字节就会抛 EAGAIN，所以先试读，读得到就不问元数据。
        if canRead(url) { return true }
        guard let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ]) else { return true }
        guard values.isUbiquitousItem == true else { return true } // 不是 iCloud 文件，无所谓
        guard let status = values.ubiquitousItemDownloadingStatus else { return true }
        return status == .current || status == .downloaded
    }

    /// 读一个字节。占位符（dataless）会抛，真文件不会。
    private static func canRead(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 1)) != nil
    }

    /// 请求下载并最多等 `timeout` 秒。`timeout = 0` 表示只踢一脚就走——
    /// fs-watch 那条路跑在主线程上，不能在那儿一等好几秒。
    @discardableResult
    static func materialize(_ url: URL, timeout: TimeInterval) -> Bool {
        if isMaterialized(url) { return true }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        guard timeout > 0 else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isMaterialized(url) { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return isMaterialized(url)
    }

    // MARK: - 账本事务（v2.3 规则 1：锁全程）

    /// 读—改—写整个事务在锁内完成，写完即放。
    ///
    /// 注意 `body` 拿到的是**锁内刚从盘上读回来的**账本，不是调用方手里那份可能已经
    /// 过期的内存副本——这正是规则 1 的要害：只锁「写那一下」的话，两个写入者仍然
    /// 各自基于旧版本计算，rename 再原子也是最后写赢丢数据。
    /// `body` 返回 nil 表示只读事务，不落盘。
    static func withLedgerTransaction(
        purpose: String = "",
        _ body: (KairosSnapshot?) throws -> KairosSnapshot?
    ) throws -> KairosSnapshot? {
        let handle = try KairosLedgerLock.acquire(snapshot, purpose: purpose)
        defer { KairosLedgerLock.release(handle) }
        let current = try readSnapshotUnlocked()
        guard let next = try body(current) else { return current }
        try writeSnapshotUnlocked(next)
        return next
    }

    /// 只在锁内调用。锁外读用于渲染（fs-watch 触发的重读）是可以的——读到写了一半的
    /// 文件在原子 rename 下不会发生，最坏是读到上一版，下一次 watch 事件会纠正。
    static func readSnapshotUnlocked(materializeTimeout: TimeInterval = 10) throws -> KairosSnapshot? {
        guard FileManager.default.fileExists(atPath: snapshot.path) else { return nil }
        // 先读，读不到再问元数据、等下载。进程刚起来时 iCloud 的元数据会间歇性答「没落地」，
        // 先问就白白报一次「账本还在云端」——文件明明好好的在盘上（和邮箱同一个坑）。
        // 真的 dataless 读会抛 EAGAIN，那时才走下面的等待。
        // **每条出盘的路都要过一遍迁移**。漏一条的后果是静默的：`state` 不再是
        // CodingKey，老账本解出来那一格直接没了，87 条已了结的会在人眼前重新打开。
        if let data = try? Data(contentsOf: snapshot) {
            return try JSONDecoder().decode(KairosSnapshot.self, from: data).migratedToMergedStatus()
        }
        guard materialize(snapshot, timeout: materializeTimeout) else {
            throw LedgerReadError.notMaterialized
        }
        return try JSONDecoder()
            .decode(KairosSnapshot.self, from: Data(contentsOf: snapshot))
            .migratedToMergedStatus()
    }

    /// 原子写：临时文件 + rename。与 Node 侧 `writeLedgerUnlocked` 同形。
    static func writeSnapshotUnlocked(_ value: KairosSnapshot) throws {
        try ensureDataDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        let temporary = dataDirectory.appendingPathComponent(
            ".projection-snapshot.\(ProcessInfo.processInfo.processIdentifier).tmp"
        )
        try data.write(to: temporary)
        _ = try FileManager.default.replaceItemAt(snapshot, withItemAt: temporary)
    }
}

struct KairosConnection: Codable, Hashable {
    var api: String
    var token: String
    var name: String

    /// 允许把整条 loom 链接（`https://host/being/?token=…`）直接粘进「API 地址」——
    /// README 一直这么写，但以前没实现，导致 token 留在 api 里、请求打到网页根路径。
    /// 加载与保存都走这里，旧的坏配置在读取时就地纠正，不用重新输入。
    static func normalized(_ value: KairosConnection) -> KairosConnection {
        var result = value
        let raw = value.api.trimmingCharacters(in: .whitespacesAndNewlines)
        var token = value.token.trimmingCharacters(in: .whitespacesAndNewlines)
        var api = raw

        if var components = URLComponents(string: raw) {
            func tokenValue(in query: String?) -> String? {
                guard let query else { return nil }
                return URLComponents(string: "?" + query)?
                    .queryItems?.first { $0.name == "token" }?.value
            }
            // token 可能藏在 query（?token=）或 fragment（#token=）里
            let embedded = tokenValue(in: components.query) ?? tokenValue(in: components.fragment)
            if let embedded = embedded?.trimmingCharacters(in: .whitespacesAndNewlines), !embedded.isEmpty {
                token = embedded
            }
            components.query = nil
            components.fragment = nil
            if let stripped = components.string { api = stripped }
        }

        result.api = api.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        result.token = token
        return result
    }

    static func load() -> KairosConnection? {
        let environment = ProcessInfo.processInfo.environment
        if let api = environment["KAIROS_API"], !api.isEmpty {
            return normalized(KairosConnection(
                api: api,
                token: environment["KAIROS_TOKEN"] ?? "",
                name: environment["KAIROS_BEING"] ?? ""
            ))
        }
        guard let data = try? Data(contentsOf: KairosFiles.connection),
              let value = try? JSONDecoder().decode(KairosConnection.self, from: data),
              !value.api.isEmpty else { return nil }
        return normalized(value)
    }

    func save() throws {
        guard !api.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        try KairosFiles.writePrivate(JSONEncoder().encode(self), to: KairosFiles.connection)
    }
}

/// 连接状态只随「用户明确动作」变化：打开应用不发任何请求（回合制，非实时），
/// 所以启动时已保存的连接停在 configured（未验证），第一次说话/刷新/保存设置才见分晓。
enum BeingConnectionState: Equatable {
    case notConfigured
    case configured(String)
    case checking
    case online(String)
    case offline

    var label: String {
        switch self {
        case .notConfigured: "未接入 Being"
        case .configured(let name): name
        case .checking: "正在连接…"
        case .online(let name): name
        case .offline: "Being 未连接"
        }
    }

    var symbol: String {
        switch self {
        case .notConfigured: "link.badge.plus"
        case .configured: "circle.dotted"
        case .checking: "ellipsis"
        case .online: "circle.fill"
        case .offline: "exclamationmark.circle"
        }
    }

    var isOnline: Bool {
        if case .online = self { return true }
        return false
    }
}

struct KairosUndoNotice: Equatable, Identifiable {
    let id = UUID()
    let title: String
}

@MainActor
final class KairosStore: ObservableObject {
    @Published private(set) var snapshot = KairosSnapshot.empty
    @Published var mainSection: KairosMainSection = .items
    @Published var selectedProjectID = KairosWorkspace.defaultProjectID
    @Published var selection: String?
    @Published var selectedItemIDs: Set<String> = []
    @Published var query = ""
    @Published var editingItem: KairosItem?
    @Published var editingProject: KairosProject?
    @Published var creatingProject = false
    @Published var creatingItem = false
    @Published var showingSettings = false
    @Published var showingBeingInspector = false
    @Published var notice: String?
    /// v2.3 没有「对账」了：账本就是真源，这只是「把盘上最新读回来 + 补发 outbox」。
    @Published var isRefreshing = false
    /// **只是「此刻正在发的那一句」**，不是一把锁。谁都别拿它拦 UI：人可以接着敲、接着发，
    /// 后面那几句在队列里排着（见 `speak`）。这个值只用来说明「现在轮到谁」。
    @Published var isSending = false
    /// 还在排队等着开口的那几句（不含正在发的那一句）。
    @Published private(set) var queuedSpeechCount = 0
    /// 对话页的活水：正在流进来的回复正文（按事项分），以及工具调用的最近一行。
    /// 回复收完就清空——正文落进房间成为过程记录，这里只管「正在说」。
    ///
    /// 键少了 = 那间房这一口气收了，单子上那一行据此亮「没看」（`noteTurnsEnded`）。
    /// 只比键数：正文一秒几十段，每段都是一次赋值，别在这儿多干活。
    @Published private(set) var liveReply: [String: String] = [:] {
        didSet { if liveReply.count < oldValue.count { noteTurnsEnded(since: oldValue) } }
    }
    @Published private(set) var liveActivity: [String: BeingActivity] = [:]
    /// 正在路上的那几句（气泡已经画出来了，服务端还没说收到）。
    ///
    /// 「还没送到」和「没发出去」是两回事。气泡是先落盘再发的，中间隔着一个来回——
    /// 这段时间里如果照着 `delivered == false` 画红字，人按下发送就会看见
    /// 「没发出去，点一下重发」闪一下。那句话此刻是假的。
    @Published private(set) var sendingMessageIDs: Set<String> = []
    /// 轮到了、但 being 正忙着别的一口气，还在等它空出来的那一句（见 `waitForBeingTurn`）。
    @Published private(set) var awaitingBeingMessageID: String?
    /// 它此刻忙的那口气是谁起的（`/api/stream/active` 的 `origin`）。只用来在「排队中」
    /// 后面多说半句在等什么——服务端不给这个字段时它是 nil，那行字退回通用说法。
    @Published private(set) var awaitingBeingOrigin: BeingBreathOrigin?
    /// 排在队头、正等着上一句断流接回收尾的那条气泡（`startSpeechPump`）。
    @Published private(set) var awaitingRecoveryMessageID: String?

    /// 正在流的那口气的流号（键同 `liveReply`）。有它才停得了——`POST /api/stop` 要指名
    /// 停哪一条，不能笼统地说「停」。meta 一到才有（`.accepted`），在那之前按钮不亮。
    @Published private(set) var liveStreamID: [String: String] = [:]

    /// 人自己按停止停掉的那几条流。**断流接回要绕开它们**：停完服务端多半把连接直接收了，
    /// 照常走接回就是去追一口人刚叫停的气，追回来还在房间里写一句「没答完，再问一次」。
    private var humanStoppedStreams: Set<String> = []

    /// 这条连接的身份：normalize 之后的 api 地址。**换了 being 就换一个值。**
    ///
    /// 排着的话、正在接回的回复、正在追的那个 202，说的都是上一个 being。人在设置里
    /// 换一条 loom 链接，这些东西不能顺着发给新的那个——那就是拿 A 的话去问 B。
    /// portal-desktop 那边同一个问题是拿 `X-Portal-Being-Endpoint` 挡的（换了就 409）。
    private var connectionKey: String? {
        guard let connection else { return nil }
        let key = KairosConnection.normalized(connection).api
        return key.isEmpty ? nil : key
    }

    /// 正在后台接回的那几条流（每条待办至多一条）。新开口会顶掉旧的接回。
    private var streamRecovery: [String: Task<Void, Never>] = [:]
    /// 每条待办没发出去的那半句。切到别的行再切回来，字还在——**写了一半的东西不能因为
    /// 点了别处就没了**（切换 Session 再切回来，已经敲过的字没有留下来）。
    ///
    /// 本机的事，存 UserDefaults，不进账本。**故意不是 `@Published`**：每敲一个字都发一次
    /// 通知的话，整个窗口跟着重画——草稿的存在与否不需要谁跟着重画，输入框自己记得。
    private var roomDraftStore: [String: String] =
        UserDefaults.standard.dictionary(forKey: KairosStore.roomDraftsKey) as? [String: String] ?? [:]
    private static let roomDraftsKey = "kairos.roomDrafts"

    /// 边栏里项目的顺序。**本机的事**：边栏里那几个「项目」多半只是待办身上的一个名字，
    /// 从来没登记过，没有 id 可记进账本；排列顺序本来也是每台机器各排各的。
    ///
    /// 早先那版是「拖到谁就顺手把谁登记上」——代价太大：登记过的项目**空了也不会消失**，
    /// 于是排一次序就等于永久钉住一行（下面空了应该自己消失，除非是手动建的）。
    /// 顺序不值这个价，记本机。
    @Published private(set) var sidebarProjectOrder: [String] =
        UserDefaults.standard.stringArray(forKey: "kairos.sidebarProjectOrder") ?? []

    func setSidebarProjectOrder(_ names: [String]) {
        sidebarProjectOrder = names
        UserDefaults.standard.set(names, forKey: "kairos.sidebarProjectOrder")
    }

    func roomDraft(_ key: String) -> String { roomDraftStore[key] ?? "" }

    func setRoomDraft(_ text: String, for key: String) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard roomDraftStore.removeValue(forKey: key) != nil else { return }
        } else {
            guard roomDraftStore[key] != text else { return }
            roomDraftStore[key] = text
        }
        UserDefaults.standard.set(roomDraftStore, forKey: Self.roomDraftsKey)
    }

    /// 攒着还没跟 being 说的改动：itemID → 上次说过的那个样子。见 `announce`。
    private var pendingAnnounce: [String: KairosPendingAnnounce] = [:]
    private var announceTask: Task<Void, Never>?
    /// 攒多久。够长到一次拖拽 + 一次反悔都落在同一个窗口里，短到人还记得自己刚做了什么。
    private static let announceDelay: Duration = .seconds(6)
    /// 每间房最近一次没发出去的原因（键同 `liveReply`：待办 id，或桌面对话的保留键）。
    /// 就地显示在那间房的输入框上面，不弹全局弹窗——弹窗会把人正在看的那一屏顶掉，
    /// 而且关掉就找不回来了。
    ///
    /// **按房间分，只画在出事的那间。** 以前是一个全局字符串：C 发失败，红字画在此刻开着的
    /// A 底下；离开房间就清，切回 C 原因也没了。现在切走再切回来还在，直到那间房
    /// 下一句送到（`.accepted`）、人点了重发（`resend`），或者换了连接（`updateConnection`）。
    @Published private(set) var sendErrors: [String: String] = [:]
    /// 房间（渠道）的本机状态：房间日志、已读游标、没送达的消息。
    /// 派生文件，不进 iCloud——房间整个删掉，账本 diff 自愈，什么都不少。
    @Published var rooms = KairosRooms.empty
    /// 正在等 iCloud 把账本拉下来，别叠多个重试循环。
    private var isRetryingLedger = false
    @Published var connectionState: BeingConnectionState = .notConfigured
    /// 向 being 要 BEING-RULES 的状态（按当前连接键，见 `connectionKey`）。
    @Published private(set) var beingRulesRequestedAt: Date?
    @Published private(set) var beingRulesDeliveredAt: Date?
    /// 正在请 being 看账本（`bap.ledgerround/1`）。按钮据此转圈并禁用，防连点。
    @Published var isAskingBeing = false
    /// 关联着，但自己的改动堆着没人来收——Mac 关机 / being 没在跑的样子。
    ///
    /// 跟着读盘算（`mergedWithOwnOutbox` 那儿 outbox 正好在手上），不在 `body` 里算：
    /// 这个值 `LaneListView` 的头每帧都要看一眼，每帧读一次文件不行。
    /// 前台那个 30 秒的 ticker 会重读，所以 Mac 一直不回来，✨ 会自己冒出来。
    @Published private(set) var ledgerDrainStalled = false
    /// 上一趟账本来回的判决（改进去几条、哪几处没收），下一趟原样带给 being。
    /// **只在内存里**：它是「上一趟」的意思，app 重开之后没有上一趟，丢了正好。
    private var lastLedgerRound: KairosLedgerRoundReport?
    @Published var undoNotice: KairosUndoNotice?
    /// 勾选待了结：本地意图，不进账本。见 toggleChecked / flushCheckedItems。
    @Published private(set) var checkedItemIDs: Set<String> = []

    private static let checkedDefaultsKey = "kairos.checkedItemIDs"

    private(set) var connection: KairosConnection?
#if !os(macOS)
    private let sharedFolder = SharedLedgerFolder()
#endif
    private let fallbackUndoManager = UndoManager()
    weak var undoManager: UndoManager?
    private var writeBlockedReason: String?

    init() {
        undoManager = fallbackUndoManager
        connection = KairosConnection.load()
        // 打开应用零通信：有连接也只标记「已配置」，不发验证请求。
        connectionState = connection.map { .configured($0.name.nonEmpty ?? "Being") } ?? .notConfigured
        syncBeingRulesDeliveryState()
        loadSnapshot()
        rooms = KairosRooms.load()
        // 勾了但还没落账的，重开 App 仍然划着；快照里已经没有的 id 顺手丢掉。
        let restored = Set(UserDefaults.standard.stringArray(forKey: Self.checkedDefaultsKey) ?? [])
        checkedItemIDs = restored.intersection(snapshot.items.map(\.id))
#if os(macOS)
        startWatchingLedger()
#endif
    }

#if os(macOS)
    /// 数据面直接 fs-watch 账本文件，变更即重读渲染，不依赖消息到达（v2.2）。
    /// being 心跳写完账本，这里立刻看得见——消息只是通知，文件才是真源。
    private var ledgerWatch: DispatchSourceFileSystemObject?

    private func startWatchingLedger() {
        ledgerWatch?.cancel()
        ledgerWatch = nil
        let descriptor = open(KairosFiles.snapshot.path, O_EVTONLY)
        guard descriptor >= 0 else { return } // 文件还不存在：第一次 commit 之后再挂
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = self.ledgerWatch?.data ?? []
            self.reloadFromDisk()
            // 原子写是 rename：被监视的 inode 会被换掉，必须重新挂，否则只收得到第一次。
            if flags.contains(.delete) || flags.contains(.rename) {
                self.startWatchingLedger()
            }
        }
        source.setCancelHandler { close(descriptor) }
        ledgerWatch = source
        source.resume()
        startWatchingOutbox()
    }

    private var outboxWatch: DispatchSourceFileSystemObject?

    /// 也盯着 outbox 目录——手机写完它自己那个文件，iCloud 同步下来就是这个目录变了。
    /// 不盯的话手机上的改动要等你下拉刷新才出现，那就白做了。
    private func startWatchingOutbox() {
        outboxWatch?.cancel()
        outboxWatch = nil
        let directory = KairosFiles.dataDirectory.appendingPathComponent("outbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.drainDeviceOutboxes()
        }
        source.setCancelHandler { close(descriptor) }
        outboxWatch = source
        source.resume()
    }

#endif

    var beingName: String {
        switch connectionState {
        case .online(let name), .configured(let name): name
        default: connection?.name.nonEmpty ?? snapshot.being.name.nonEmpty ?? "Being"
        }
    }

    /// 连接**不对劲**：没配过，或者连不上。在线和正在查都不算——
    /// 好的时候界面上一个点都不该多（工具栏那一项整项都不存在，见 `KairosWindow.toolbar`）。
    var connectionNeedsAttention: Bool {
        switch connectionState {
        case .notConfigured, .offline: true
        default: false
        }
    }

    /// 夹在汉字中间的 being 名字：**拉丁字母的名字两边补一个空格**。
    ///
    /// 「跟Heart说这件事」「记一条，或者问being」——中英文贴在一起，字挤成一团，
    /// 这是中英混排最常见的一处失手（中文排版里那条「盘古之白」；Apple 自己的中文
    /// 本地化也一律留这个空格）。而**中文名字不能补**：「跟 小明 说这件事」是错的。
    /// 所以看名字首尾是不是 ASCII 字母/数字再决定，不写死。
    ///
    /// 名字在句首的地方（「Heart 上次去」）用 `beingNameLeading`——那儿不能有前导空格。
    var beingNameInline: String {
        let name = beingName
        guard name.first?.isLatinish == true || name.last?.isLatinish == true else { return name }
        return " " + name + " "
    }

    /// 句首的 being 名字：只补后面那个空格。
    var beingNameLeading: String {
        let name = beingName
        guard name.last?.isLatinish == true else { return name }
        return name + " "
    }

    /// 名字后面紧跟中文标点（「：」「，」「。」…）时用这个：只补前面那个空格。
    /// 「落款是 Heart：信由 ta 代收代发」——标点前面不留空格，那是中文排版的硬规则。
    var beingNameTrailing: String {
        let name = beingName
        guard name.first?.isLatinish == true else { return name }
        return " " + name
    }

    /// v2.3 没有「待同步」了：账本就是真源，commit 成功即落账。
    /// 侧栏该显示的是「有多少条在等你」——只数 ask 级未读（规则 5）。
    var unreadAskCount: Int { rooms.totalUnreadAsk }
    var conflictCount: Int { snapshot.conflicts.count }
    var selectedItem: KairosItem? { snapshot.items.first { $0.id == selection } }

    /// 此刻真正存在的项目名：登记过的 + 条目身上已经在用的。
    /// **发给 being 当提示用**（让它复用已有的名字，别造出 同一摊事的三个近义名），
    /// 不是门禁——它写个新名字照收。边栏也是按「条目身上有什么」现推的，两边同一个口径。
    var allProjectNames: [String] {
        var seen = Set<String>()
        var names: [String] = []
        for project in snapshot.workspace.projects where !project.archived {
            if project.id != KairosWorkspace.defaultProjectID, seen.insert(project.name).inserted {
                names.append(project.name)
            }
        }
        for item in snapshot.items where !item.project.isEmpty {
            if seen.insert(item.project).inserted { names.append(item.project) }
        }
        return names
    }

    var projects: [KairosProject] {
        orderedProjects.filter { !$0.archived }
    }

    var archivedProjects: [KairosProject] {
        orderedProjects.filter(\.archived)
    }

    var selectedProject: KairosProject? {
        snapshot.workspace.projects.first { $0.id == selectedProjectID }
    }

    private var orderedProjects: [KairosProject] {
        let rank = Dictionary(uniqueKeysWithValues: snapshot.workspace.sidebarOrder.enumerated().map { ($0.element, $0.offset) })
        return snapshot.workspace.projects.sorted {
            (rank[$0.id] ?? Int.max, $0.name) < (rank[$1.id] ?? Int.max, $1.name)
        }
    }

    /// 已了结那个抽屉。**按时间倒序，不叠手工顺序**——拖过的顺序是给还要做的事排的，
    /// 已经完了的东西不值得再花一次力气排。
    var closedItems: [KairosItem] {
        let lowerQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return snapshot.items
            .filter { item in
                guard item.isClosed else { return false }
                guard !lowerQuery.isEmpty else { return true }
                return item.searchText.contains(lowerQuery)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func conflict(for id: String) -> KairosConflict? {
        snapshot.conflicts.first { $0.id == id }
    }

    func saveDraft(_ draft: KairosItem, isNew: Bool) throws {
        var next = snapshot
        if isNew {
            var item = draft
            item.id = item.id.nonEmpty ?? UUID().uuidString
            item.localRev = 1
            item.syncedLocalRev = 0
            item.beingRev = 0
            item.remoteKnown = false
            item.updatedAt = KairosClock.now
            next.items.append(item)
        } else if let index = next.items.firstIndex(where: { $0.id == draft.id }) {
            let current = next.items[index]
            guard !current.hasSameBusinessFields(as: draft) else { return }
            var item = draft
            item.localRev = current.localRev + 1
            item.syncedLocalRev = current.syncedLocalRev
            item.beingRev = current.beingRev
            item.remoteKnown = current.remoteKnown
            item.updatedAt = KairosClock.now
            next.items[index] = item
            if let conflictIndex = next.conflicts.firstIndex(where: { $0.id == item.id }) {
                next.conflicts[conflictIndex].local = item.payload
            }
        }
        let before = snapshot.items.first { $0.id == draft.id }
        // v2.3 §五的边界：新建时填的初值不算「手动改」，being 例行推进可以覆盖；
        // 只有新建之后的显式修改才盖 human 戳。
        try commit(next, edit: isNew ? .created : .edited)
        announce(draft.id, before: before, isNew: isNew)
    }

    /// 了结。球权撤掉之后「完没完」就是状态的一个值，所以这里走的是同一条路。
    /// 不叫 `close`：这个类里还调着 POSIX 的 `close(fd)`，同名成员会把那个全局函数遮掉。
    func finish(item: KairosItem) {
        applyStatus(item, to: KairosStatus.closed, actionName: "已了结")
    }

    /// 重新打开 → **回到「未开始」**。
    /// 了结时原来的状态被盖掉了，没有第二个字段替它记着——这是并成一个字段的代价，
    /// 也正是它的好处：单子上不会再有「已了结 + 进行中」这种自己跟自己打架的行。
    func reopen(item: KairosItem) {
        applyStatus(item, to: KairosStatus.todo, actionName: "已重新打开")
    }

    private func applyStatus(_ item: KairosItem, to status: String, actionName: String) {
        guard let current = snapshot.items.first(where: { $0.id == item.id }), current.status != status else {
            return
        }
        let previousStatuses = [current.id: current.status]
        let previousWorkspace = snapshot.workspace
        var draft = current
        draft.status = status
        do {
            try saveDraft(draft, isNew: false)
            registerStatusUndo(previousStatuses, workspace: previousWorkspace, actionName: actionName)
            undoNotice = KairosUndoNotice(title: actionName)
        } catch {
            notice = error.localizedDescription
        }
    }

    /// 一张单子：还没了结的都在这儿，先按优先级排，再叠用户自己拖出来的顺序。
    /// （以前这里写的是「球权是临时状态、不拿来分段」——2026-09-11 球权干脆并进了状态。）
    ///
    /// **这里不再按 `workspace.membership` 过滤了**。
    ///
    /// 「属于哪摊事」曾经有两套写法同时活着：
    ///   A `item.project` —— 事项身上的项目名。契约里写的是它（KAIROS-CONTRACT §96/§139）、
    ///     `ledger/cli.js --project` 写的是它、Mac 边栏和右键菜单读写的也全是它。
    ///   B `workspace.membership` —— 事项 id → 项目 id 的另一张表。09-08 那次界面重做之前的
    ///     设计，重做之后**界面上一处都没有了**（`moveToProject` / `projectCounts` /
    ///     `addProject` / `renameProject` 在视图层全是 0 引用）。
    ///
    /// B 不只是多余，它是个活的坑：这三道过滤（这儿、`closedItems`、`searchAllStates`）
    /// 是主列表的第一关。眼下所有条目碰巧都落在同一个默认桶里所以没出事，但
    /// `selectedProjectID` 在读账本时还会被自动改成「第一个没归档的项目」（见下面三处赋值）——
    /// 账本里一旦出现一个真项目、而它的 id 和条目的归属对不上，**整张单子会静默地少东西甚至变空**，
    /// 而且没法在界面上修，因为已经没有任何按钮连着 B 了。
    ///
    /// 所以留 A、拆 B。**B 已经整个删了**（字段、那一圈函数、Node 侧的骨架、契约那一句），
    /// 顺序的键也顺手和项目脱钩了（见 `KairosWorkspace.orderKey`），迁移带测试。
    /// 老账本里残留的 `membership` 键读的时候直接忽略，下次落盘就没了。
    var activeItems: [KairosItem] {
        let lowerQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let baseline = snapshot.items
            .filter { item in
                guard !item.isClosed else { return false }
                guard !lowerQuery.isEmpty else { return true }
                return item.searchText.contains(lowerQuery)
            }
        return KairosWorkspaceEngine.ordered(
            baseline,
            segment: KairosWorkspace.activeOrderKey,
            workspace: snapshot.workspace
        )
    }

    /// 用户拖出来的顺序。传进来的是拖完之后的完整可见顺序。
    func reorderActive(_ ids: [String]) {
        let previous = snapshot.workspace
        var next = snapshot
        let key = KairosWorkspace.orderKey(segment: KairosWorkspace.activeOrderKey)
        next.workspace.manualOrder[key] = ids
        do {
            guard next.workspace != previous else { return }
            try commit(next)
            registerWorkspaceUndo(previous, actionName: "调整顺序")
            undoNotice = KairosUndoNotice(title: "已调整顺序")
        } catch {
            notice = error.localizedDescription
        }
    }

    func performUndo() {
        undoManager?.undo()
        undoNotice = nil
    }

    func dismissUndoNotice(_ id: UUID) {
        guard undoNotice?.id == id else { return }
        undoNotice = nil
    }

    /// 改优先级。tier 是业务字段，走普通编辑落账本；being 下次心跳读账本就看见了。
    func setTier(_ item: KairosItem, to tier: String) {
        guard item.tier != tier else { return }
        var draft = item
        draft.tier = tier
        do {
            try saveDraft(draft, isNew: false)
            // 右键菜单改优先级以前是**撤不回来**的：⌘Z 没反应，也没有那颗「撤销」胶囊。
            // 改一下就是给 being 发一条消息，撤不回来就只能再改回去、再发一条。
            registerFieldUndo([item.id: KairosFieldSnapshot(item)], actionName: "改优先级")
            undoNotice = KairosUndoNotice(title: "已改优先级")
        } catch { notice = error.localizedDescription }
    }

    /// 改状态。和 `setTier` 同形：业务字段，走普通编辑落账本，盖 human 戳。
    /// **两端共用**——手机上「进行中 / 待定」也是人能自己拨的一档，
    /// 原来它长在 Mac 专属的视图文件里，等于手机根本没有这个动作。
    func setStatus(_ item: KairosItem, to status: String) {
        let value = KairosStatus.normalized(status)
        guard item.status != value else { return }
        var draft = item
        draft.status = value
        do {
            try saveDraft(draft, isNew: false)
            registerFieldUndo([item.id: KairosFieldSnapshot(item)], actionName: "改状态")
            undoNotice = KairosUndoNotice(title: "已改状态")
        } catch { notice = error.localizedDescription }
    }

    /// 见 `KairosFieldSnapshot`。
    func registerFieldUndo(_ previous: [String: KairosFieldSnapshot], actionName: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            Task { @MainActor in target.restoreFields(previous, actionName: actionName) }
        }
        undoManager?.setActionName(actionName)
    }

    private func restoreFields(_ previous: [String: KairosFieldSnapshot], actionName: String) {
        var redo: [String: KairosFieldSnapshot] = [:]
        for (id, old) in previous {
            guard let item = snapshot.items.first(where: { $0.id == id }) else { continue }
            var draft = item
            draft.tier = old.tier
            draft.status = old.status
            guard !draft.hasSameBusinessFields(as: item) else { continue }
            do {
                try saveDraft(draft, isNew: false)
                redo[id] = KairosFieldSnapshot(item)
            } catch {
                notice = error.localizedDescription
            }
        }
        guard !redo.isEmpty else { return }
        registerFieldUndo(redo, actionName: actionName)
    }

    func isChecked(_ item: KairosItem) -> Bool { checkedItemIDs.contains(item.id) }

    /// 勾一下之后，隔多久才真的离开单子。
    ///
    /// 2 秒是挑出来的，不是随手写的：够你连着勾三四条而单子不在手底下反复重排，
    /// 又短到不会让人以为「我勾了怎么没反应」。
    static let checkGrace: Duration = .seconds(2)

    /// 勾一下：**先划掉，`checkGrace` 之后才真的了结**，这段时间里再点一下就是反悔；
    /// 真了结那一下会弹撤销胶囊（`finish` 管），5 秒内还能整条撤回。
    ///
    /// **两端同一条路**。在这之前是各写各的：
    ///   手机  勾上只是划掉，**一直留在单子上**，要等下一次刷新（切后台再回来、或下拉）
    ///         才落账——人的感受是「我勾了它怎么还在」。
    ///   Mac   `KairosMacShell.toggleCompletion`，0.6 秒后直接落账——太快，
    ///         而且在手机上照搬的话，连勾几条时列表会在拇指底下不停重排。
    /// 现在两边都走这里。Mac 那个 `completing` 集合连同 `toggleCompletion` 一起撤掉了。
    func toggleChecked(_ item: KairosItem) {
        if checkedItemIDs.contains(item.id) {
            checkedItemIDs.remove(item.id)          // 反悔
            persistChecked()
            return
        }
        checkedItemIDs.insert(item.id)
        persistChecked()
        let id = item.id
        Task { @MainActor in
            try? await Task.sleep(for: Self.checkGrace)
            // 这两秒里点了第二下（反悔），或者这条已经从别处没了 → 什么都不做。
            guard checkedItemIDs.contains(id),
                  let fresh = snapshot.items.first(where: { $0.id == id }),
                  !fresh.isClosed
            else { return }
            checkedItemIDs.remove(id)
            persistChecked()
            finish(item: fresh)
        }
    }

    /// 勾选状态落本机。**要持久化**：万一在那 2 秒里退出了 app，这条不能悄悄变回没勾过——
    /// 下次刷新时 `flushCheckedItems` 会把它补上。
    private func persistChecked() {
        UserDefaults.standard.set(Array(checkedItemIDs), forKey: Self.checkedDefaultsKey)
    }

    /// 刷新时把勾掉的一次性落成 closed（一次 commit）。
    private func flushCheckedItems() {
        guard !checkedItemIDs.isEmpty else { return }
        var next = snapshot
        var changed = false
        for id in checkedItemIDs {
            guard let index = next.items.firstIndex(where: { $0.id == id }) else { continue }
            let current = next.items[index]
            guard !current.isClosed else { continue }
            var item = current
            item.status = KairosStatus.closed
            item.localRev = current.localRev + 1
            item.updatedAt = KairosClock.now
            next.items[index] = item
            if let conflictIndex = next.conflicts.firstIndex(where: { $0.id == id }) {
                next.conflicts[conflictIndex].local = item.payload
            }
            changed = true
        }
        checkedItemIDs = []
        UserDefaults.standard.removeObject(forKey: Self.checkedDefaultsKey)
        guard changed else { return }
        do { try commit(next) }
        catch { notice = error.localizedDescription }
    }

#if os(macOS)
    func select(_ item: KairosItem, visibleItems: [KairosItem], modifiers suppliedModifiers: NSEvent.ModifierFlags? = nil) {
        let modifiers = suppliedModifiers ?? NSApp.currentEvent?.modifierFlags ?? []
        if modifiers.contains(.command) {
            if selectedItemIDs.contains(item.id) { selectedItemIDs.remove(item.id) }
            else { selectedItemIDs.insert(item.id) }
        } else if modifiers.contains(.shift), let anchor = selection,
                  let start = visibleItems.firstIndex(where: { $0.id == anchor }),
                  let end = visibleItems.firstIndex(where: { $0.id == item.id }) {
            let range = min(start, end)...max(start, end)
            selectedItemIDs.formUnion(range.map { visibleItems[$0].id })
        } else {
            selectedItemIDs = [item.id]
        }
        selection = selectedItemIDs.count == 1 ? selectedItemIDs.first : nil
        if selection != nil { showingBeingInspector = false }
    }
#else
    func select(_ item: KairosItem) {
        markRoomRead(item.id)
        selectedItemIDs = [item.id]
        selection = item.id
        showingBeingInspector = false
    }
#endif

    func searchAllStates(_ text: String) -> [KairosItem] {
        let lowerQuery = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowerQuery.isEmpty else { return [] }
        return snapshot.items
            .filter { item in
                return item.searchText.contains(lowerQuery)
            }
    }

    func clearSelection() {
        selection = nil
        selectedItemIDs.removeAll()
    }

    func openBeingInspector() {
        showingBeingInspector = true
        clearSelection()
    }

    func toggleBeingInspector() {
        if showingBeingInspector {
            showingBeingInspector = false
        } else {
            openBeingInspector()
        }
    }

    func closeInspector() {
        showingBeingInspector = false
        clearSelection()
    }

    func dragIDs(startingWith item: KairosItem, visibleItems: [KairosItem]) -> [String] {
        if selectedItemIDs.contains(item.id), !selectedItemIDs.isEmpty {
            let visible = visibleItems.filter { selectedItemIDs.contains($0.id) }.map(\.id)
            let hidden = snapshot.items.filter {
                selectedItemIDs.contains($0.id) && !visible.contains($0.id)
            }.map(\.id)
            return visible + hidden
        }
        selectedItemIDs = [item.id]
        selection = item.id
        return [item.id]
    }

// 围着 `workspace.membership` 长出来的那一圈 2026-09-11 整块撤掉：
    // assignItems / createProject / updateProject / archiveProject / restoreProject /
    // count(for:) / moveToProject / selectedProjectID / selectedProject。
    //
    // 它们是 09-08 界面重做之前那套「项目 = 一张归属表」的设计。重做之后界面改走
    // 事项自己的 `project` 字段（契约 §96/§139），这一圈从此一个调用方都没有，
    // 却还在往账本里写 membership——而 `activeItems` 又拿 membership 当第一道过滤，
    // 于是留下一个会**静默吞掉整张单子**的坑（详见 `activeItems` 上的注释）。
    //
    // 现在界面用的是 `macProjects` / `macAddProject` / `macSetProject` 那一套，
    // 直接读写 `workspace.projects` 和 `item.project`，和这里没有关系。

    var seeds: [KairosSeed] { snapshot.seeds }

    func deleteSeed(_ seed: KairosSeed) {
        var next = snapshot
        next.seeds.removeAll { $0.id == seed.id }
        try? commit(next)
    }

    /// 把一条残留的想法变成真正的事项，并从 seeds 里删掉。
    /// 「想法」这一屏两端都没了：启动时把残留的一次性转成事项（`absorbSeedsIntoItems`，
    /// Mac 在 KairosViews.swift、iOS 在 ItemsCompose.swift 各有一份同名扩展）。
    func promoteSeed(_ seed: KairosSeed) {
        var draft = KairosItem()
        draft.title = seed.text
        do {
            try saveDraft(draft, isNew: true)
            deleteSeed(seed)
        } catch {
            notice = error.localizedDescription
        }
    }

    func delete(_ item: KairosItem) {
        var next = snapshot
        next.items.removeAll { $0.id == item.id }
        next.conflicts.removeAll { $0.id == item.id }
        for key in next.workspace.manualOrder.keys {
            next.workspace.manualOrder[key]?.removeAll { $0 == item.id }
        }
        if item.remoteKnown {
            next.tombstones.removeAll { $0.id == item.id }
            next.tombstones.append(KairosTombstone(
                id: item.id,
                localRev: item.localRev + 1,
                syncedLocalRev: item.syncedLocalRev,
                beingRev: item.beingRev,
                deletedAt: KairosClock.now
            ))
        }
        do {
            try commit(next)
            // 房间没有独立生命：待办没了，房间跟着走，不留孤儿。
            rooms.forget(item.id)
            rooms.save()
            if selection == item.id { selection = nil }
            selectedItemIDs.remove(item.id)
        } catch {
            notice = error.localizedDescription
        }
    }

    func resolve(_ conflict: KairosConflict, choice: ConflictChoice) {
        do { try commit(KairosSyncEngine.resolving(conflict.id, choice: choice, in: snapshot)) }
        catch { notice = error.localizedDescription }
    }

    /// 只在用户明确动作时调用（保存设置、点「测试连接」），绝不挂计时器、不随启动跑。
    func checkBeing() async {
        guard let connection else {
            connectionState = .notConfigured
            return
        }
        connectionState = .checking
        do {
            let name = try await BeingClient(connection: connection).status()
            connectionState = .online(connection.name.nonEmpty ?? name.nonEmpty ?? snapshot.being.name.nonEmpty ?? "Being")
            // 名字：设置里填了就用填的，没填才记它自报的（界面有默认名，不是它自报的那个名字）。
            // 以前是自报的一律盖掉填的——那是为了纠正旧配置里填成「人类」的那一栏，
            // 但代价是人怎么填都留不住。
            if connection.name.nonEmpty == nil, let reported = name.nonEmpty {
                var updated = connection
                updated.name = reported
                try? updated.save()
                self.connection = updated
            }
        } catch {
            connectionState = .offline
        }
    }

    // MARK: - 账本刷新（v2.3：没有「对账」这回事了）

    /// 账本就是真源，Being 直接经 `ledger/store.js` 读写同一个文件。所以这里不再有
    /// 信封、不再敲门、不再轮询——只做两件事：把盘上最新读回来渲染，顺手补发
    /// 上次没送达的房间消息（规则 4：消息发失败不回滚文件，留着下次补）。
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        // 勾掉的一次性落成 closed。刷新是这个动作的落点——和以前「同步前落账」同一个
        // 位置，只是 v2.3 里那个动作改叫刷新了。
        flushCheckedItems()
#if os(macOS)
        drainDeviceOutboxes()
#endif
        reloadFromDisk()
        await flushOutbox()
    }

    /// 数据面直接读文件，不依赖任何消息到达（v2.2）。fs-watch 和下拉刷新共用这一条。
    /// 读到写了一半的内容不致命：原子写是 rename，最坏读到上一版，下一次事件会纠正。
    func reloadFromDisk() {
        guard writeBlockedReason == nil else { return }
#if !os(macOS)
        // 单写入者（v2.3 §五）：手机只做只读投影，读 iCloud 上那一个账本文件，绝不写回。
        if sharedFolder.isConfigured, let cloud = mergedWithOwnOutbox() {
            apply(cloud)
            return
        }
#endif
        do {
            // timeout 0：fs-watch 跑在主线程上，只踢一脚让 iCloud 去拉，别在这儿等。
            guard let disk = try KairosFiles.readSnapshotUnlocked(materializeTimeout: 0) else { return }
            apply(disk)
        } catch KairosFiles.LedgerReadError.notMaterialized {
            notice = "账本还在 iCloud 云端，正在拉取…"
            scheduleLedgerRetry()
        } catch {
            // 读到写了一半的内容：原子写是 rename，最坏读到上一版，下次事件会纠正。
        }
    }

    /// iCloud 把文件拉下来不一定会触发 fs-watch（我们盯的可能是占位符那个 inode），
    /// 所以不能干等事件——自己隔几秒回来看一眼，落地了就读进来并把 watch 重新挂上。
    private func scheduleLedgerRetry() {
        guard !isRetryingLedger else { return }
        isRetryingLedger = true
        Task { [weak self] in
            defer { Task { @MainActor in self?.isRetryingLedger = false } }
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self else { return }
                let ready = await MainActor.run { KairosFiles.isMaterialized(KairosFiles.snapshot) }
                guard ready else { continue }
                await MainActor.run {
                    self.notice = nil
                    self.reloadFromDisk()
#if os(macOS)
                    self.startWatchingLedger()
#endif
                }
                return
            }
            await MainActor.run { self?.notice = "iCloud 一直没把账本拉下来；命令行可以 brctl download 强拉一次。" }
        }
    }

#if !os(macOS)
    /// 手机看到的 = 账本 + 自己还没被并进账本的改动。
    /// 不叠自己的 outbox 的话，你刚改完一刷新就「变回去了」——那才是最气人的。
    private func mergedWithOwnOutbox() -> KairosSnapshot? {
        // 拉不到账本时 `ledgerDrainStalled` 故意留着上一次的值：读不出来是**证据变少**，
        // 不是新证据。清成 false 等于凭空说「Mac 回来了」，置成 true 等于把 iCloud 打嗝
        // 报成「Mac 关机了」——只有沿用旧值不编造事实。别在这儿补一层。
        guard let ledger = sharedFolder.readLedger() else { return nil }
        guard var outbox = sharedFolder.readOutbox(deviceID: KairosDevice.id) else {
            ledgerDrainStalled = false // 一条积压都没有，没有证据说那头没人在
            return ledger
        }
        // 账本里的水位说「你到第 N 条为止我都并进去了」，那 N 条就可以删了。
        // 我们是这个文件的唯一写者，删自己的东西不会跟谁打架。
        let watermark = ledger.sync.outboxWatermark[KairosDevice.id] ?? 0
        let before = outbox.entries.count
        outbox.prune(appliedThrough: watermark)
        if outbox.entries.count != before { sharedFolder.writeOutbox(outbox) }
        // 剩下的就是还没被收走的。最老那条等多久了，决定 being 还走不走 Mac 那条路。
        ledgerDrainStalled = Self.drainStalled(
            oldestPendingAt: outbox.entries.map(\.createdAt).min(by: { KairosClock.parse($0) < KairosClock.parse($1) })
        )
        return outbox.applied(onto: ledger)
    }

    /// 还没并进账本的改动条数——界面上要能看见，不能让人以为改丢了。
    var pendingToMacCount: Int {
        sharedFolder.readOutbox(deviceID: KairosDevice.id)?.entries.count ?? 0
    }

    // MARK: - 接上 Mac 那份账本
    //
    // 这三个是「我」那一屏的入口。2026-09-08「mac 相关都隐藏」把按钮拿掉过一次，
    // 底下的机制一行没删——结果是开关永远配不上，being 在 Mac 上写的账本手机读不到，
    // 手机的 outbox 也永远等不到人来 drain。话通、账本不通。
    //
    // **这不是 8-30 那个 iCloud。** 那次炸掉是两边都写同一个文件（整文件共享），
    // 撞出 8 条真冲突。现在是每个文件一个写者：手机只写 `outbox/<设备>.json`，
    // 账本只有 Mac 写。那次的教训修的就是这个形状，不是把它重来一遍。

    var sharedFolderName: String? { sharedFolder.displayName }
    var isSharedFolderConfigured: Bool { sharedFolder.isConfigured }

    /// 选定 iCloud 上那个 Kairos 文件夹。选完立刻读一次——人按完要当场看见待办出来，
    /// 而不是「好像成了？」然后自己去杀进程重开。
    func adoptSharedFolder(_ url: URL) throws {
        try sharedFolder.adopt(url)
        pushLocalItemsToOutbox()
        loadSnapshot()
    }

    /// 接上的那一刻，把本机这份里**共享账本还没有的**条目推进自己的 outbox。
    ///
    /// 不推会怎样：单机期间攒的东西在接上的一瞬间从屏幕上整批消失——文件还在，
    /// 但界面从此看的是共享账本。人看到的就是「我的东西没了」，而且没有任何地方
    /// 告诉他去哪儿找。推进 outbox 之后，Mac 一 drain 它们就上桌，中间这段时间
    /// 也照样显示（`mergedWithOwnOutbox` 会把自己的 outbox 叠上去）。
    ///
    /// 只推共享账本没有的：接上之前手机从没编辑过共享账本里的条目，
    /// 硬把本机那版推过去，等于拿一份没有依据的旧值去盖 being 写的东西。
    private func pushLocalItemsToOutbox() {
        guard sharedFolder.isConfigured else { return }
        // 先读一次共享账本：这一步也是**对文件夹的体检**——选到的要是手机本地那个同名
        // 「Kairos」（撞过），`readLedger` 会当场把书签忘掉，回到单机。
        // 忘掉之后再往里写 outbox 就是写进一个没人看的地方，所以顺序不能反。
        let shared = sharedFolder.readLedger()
        guard sharedFolder.isConfigured else { return }
        guard let local = try? KairosFiles.readSnapshotUnlocked(materializeTimeout: 0),
              !local.items.isEmpty else { return }
        let known = Set(shared?.items.map(\.id) ?? [])
        let deleted = Set(shared?.tombstones.map(\.id) ?? [])
        var outbox = sharedFolder.readOutbox(deviceID: KairosDevice.id)
            ?? KairosOutbox(deviceID: KairosDevice.id, deviceName: KairosDevice.name)
        var pushed = 0
        for item in local.items where !known.contains(item.id) && !deleted.contains(item.id) {
            outbox.record(item, op: "upsert", changed: KairosField.business)
            pushed += 1
        }
        guard pushed > 0 else { return }
        if sharedFolder.writeOutbox(outbox) {
            notice = "本机 \(pushed) 条已排队，Mac 下次打开就会并进共享账本"
        } else {
            notice = "本机 \(pushed) 条还没能写进 iCloud——回到有网的地方会自动补上"
        }
    }

    /// 断开，回到单机。
    ///
    /// **断开不是「回到一周前」**：先把此刻屏幕上这份（共享账本 + 自己还没并进去的改动）
    /// 写进本机那份，再断。本机原来那份先备份——这一步走错没有回收站。
    func forgetSharedFolder() {
        let shown = snapshot
        KairosLedgerLocation.backup(KairosFiles.snapshot, tag: "local-before-unlink")
        try? KairosFiles.writeSnapshotUnlocked(shown)
        sharedFolder.forget()
        loadSnapshot()
        notice = "已回到单机。看到的这些都留在本机那份账本里了。"
    }
#endif

#if os(macOS)
    // MARK: - 账本位置（单机 / 关联，v2.4）
    //
    // 手机那边「关联」是安全作用域书签，Mac 这边是一个指针文件（`KairosLedgerLocation`）：
    // Mac 不在沙盒里，存绝对路径就够，而且** being 的 CLI 必须能读到同一个位置**——
    // 指针文件是两侧唯一的共同依据。

    var ledgerFolderPath: String { KairosFiles.dataDirectory.path }
    var ledgerFilePath: String { KairosFiles.snapshot.path }
    var isLedgerLinked: Bool { KairosLedgerLocation.isLinked }

    /// 把账本接到一个共享文件夹（一般是 iCloud 云盘里的 Kairos）。
    ///
    /// 两边都可能已经有真东西（Mac 单机用了一阵、手机也写过），所以**不是搬过去覆盖，
    /// 是并集**（`KairosLedgerUnion`）。并之前两份都备份到 `~/.kairos/backups/`。
    @discardableResult
    func linkLedger(to folder: URL) -> Bool {
        let target = folder.standardizedFileURL
        guard target.path != KairosFiles.dataDirectory.standardizedFileURL.path else {
            notice = "账本已经在这个文件夹里了"
            return false
        }
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        } catch {
            notice = "这个文件夹用不了：\(error.localizedDescription)"
            return false
        }

        let currentURL = KairosFiles.snapshot
        let targetURL = target.appendingPathComponent(KairosLedgerLocation.ledgerFileName)
        KairosLedgerLocation.backup(currentURL, tag: "before-link")
        KairosLedgerLocation.backup(targetURL, tag: "target-before-link")

        // 读本机这份时**上锁**：being 的 CLI 可能正在写它，读到一半的版本并过去就是丢改动。
        // 锁一放再去写目标，两把锁不嵌套（先本机、后目标），不会互相等。
        // 拿不到锁就干脆不换——换位置是个可以晚一分钟再做的动作。
        guard let handle = try? KairosLedgerLock.acquire(currentURL, purpose: "read before link") else {
            notice = "账本正被占用（多半是\(beingName)在写），过一会儿再换位置。"
            return false
        }
        let mine = (try? KairosFiles.readSnapshotUnlocked(materializeTimeout: 10)) ?? nil
        KairosLedgerLock.release(handle)
        // **「那边没有账本」和「那边有账本但现在读不出来」必须分开。**
        // 后者最常见的样子是 iCloud 还没把文件拉下来（dataless）。当成「没有」直接写过去，
        // 就是拿本机这份把对面一份完好的账本盖掉——而且那种时候连备份都做不成
        // （占位符读不出字节）。所以：文件在、读不出来，就不换。
        let theirs = KairosLedgerLocation.readLedger(at: targetURL)
        if theirs == nil, FileManager.default.fileExists(atPath: targetURL.path) {
            notice = "那个文件夹里已经有一份账本，但现在读不出来（多半还在 iCloud 上没下来）。等它下来再接，别拿本机这份盖掉它。"
            return false
        }

        let merged: KairosSnapshot
        var report = KairosLedgerUnion.Report()
        switch (mine, theirs) {
        case (let mine?, let theirs?):
            (merged, report) = KairosLedgerUnion.union(theirs, mine)
        case (let mine?, nil):
            merged = mine
        case (nil, let theirs?):
            merged = theirs
        case (nil, nil):
            merged = snapshot
        }

        guard KairosLedgerLocation.writeLedger(merged, to: targetURL) else {
            notice = "写不进那个文件夹，位置没有改。"
            return false
        }
        guard KairosLedgerLocation.writePointer(folder: target) else {
            notice = "账本已经写进那个文件夹，但位置没记下来——再试一次。"
            return false
        }
        writeBlockedReason = nil
        loadSnapshot()
        notice = report.isEmpty
            ? "账本已经接到「\(target.lastPathComponent)」"
            : "账本已经接到「\(target.lastPathComponent)」：\(report.line)"
        return true
    }

    /// 回到单机。共享文件夹里那份**不动**（手机可能还在用它），只是这台 Mac 不再看它。
    /// 本机那份用此刻共享账本的内容覆盖——断开不是回到接上之前那一天。
    @discardableResult
    func unlinkLedger() -> Bool {
        guard KairosLedgerLocation.isLinked else { return false }
        let localURL = KairosLedgerLocation.localFolder
            .appendingPathComponent(KairosLedgerLocation.ledgerFileName)
        KairosLedgerLocation.backup(localURL, tag: "local-before-unlink")
        // 读当前（共享）那份，同样上锁；读不出来就用此刻内存里这份——人看到什么就落下什么。
        guard let handle = try? KairosLedgerLock.acquire(KairosFiles.snapshot, purpose: "read before unlink") else {
            notice = "账本正被占用（多半是\(beingName)在写），过一会儿再换位置。"
            return false
        }
        let shown = ((try? KairosFiles.readSnapshotUnlocked(materializeTimeout: 10)) ?? nil) ?? snapshot
        KairosLedgerLock.release(handle)
        guard KairosLedgerLocation.writeLedger(shown, to: localURL) else {
            notice = "本机那份没写成，位置没有改。"
            return false
        }
        guard KairosLedgerLocation.writePointer(folder: KairosLedgerLocation.localFolder) else {
            notice = "位置没记下来，再试一次。"
            return false
        }
        writeBlockedReason = nil
        loadSnapshot()
        notice = "已回到单机账本：\(localURL.path)"
        return true
    }
#endif

    /// 在等你的**人数**（不是条数）。顶上「消息」那段的数字就是它。
    ///
    /// Judy 一天问三件事是一行、也只算一个人；同一个人在两条管子里找你算两个
    /// （那本来就是两行、两个地方要回）。按 `counterpart.rowKey` 去重。
    var waitingPeopleCount: Int {
        var seen = Set<String>()
        // 只数还等着你的。已了结的（发出去了）和进行中的（写好了等 being 发）球都不在你手上，
        // 算进去就是虚报——顶上那个数字一虚报，它就再也不值得看了。
        for item in snapshot.items where item.isMessage && item.isWaitingOnMe {
            if let key = item.counterpart?.rowKey { seen.insert(key) }
        }
        return seen.count
    }

    // MARK: - 请 being 跑一趟的公共节奏（账本轮用）

    /// **先等 ta 空出来，再发；发过去还是忙，等 ta 空了再问一次。**
    ///
    /// BeingDesktop 的做法是排队等——「忙」是常态不是错误。以前这里 202 直接扔 `busy`，
    /// 上层弹一句「没跑成」就完了：being 正在想事情的时候按按钮必然失败，得人自己再按。
    ///
    /// 202 之后**不立刻重发**：202 的意思是「排上了，但这条线拿不到回复」——排着的那条
    /// ta 还是会跑。立刻再发就是排两条。所以先回到「等 ta 空出来」，等排着的都跑完了
    /// 再问。重问是安全的：账本那趟每次全量重送、天然幂等。
    private func withBeingTurn<T>(_ client: BeingClient, _ send: () async throws -> T) async throws -> T {
        for _ in 0..<3 {
            await waitUntilIdle(client)
            do {
                return try await send()
            } catch BeingClientError.busy {
                notice = "\(beingName)刚接了别的活，等 ta 空出来再问一次…"
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        throw BeingClientError.busy
    }

    /// 每 5 秒看一眼，最多等 60 秒。「不知道忙不忙」（端点不在）不算忙，直接放行。
    private func waitUntilIdle(_ client: BeingClient) async {
        for tick in 0..<12 {
            guard let idle = await client.isIdle(), !idle else { return }
            notice = tick == 0 ? "\(beingName)在忙，等 ta 空出来…" : "\(beingName)还在忙，已经等了 \(tick * 5) 秒…"
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    // MARK: - 账本这一趟（bap.ledgerround/1）

    /// being 够不够得着这份账本——`bap.ledgerround/1` 那趟跑不跑，只看这一件事。
    ///
    /// 够得着 → 它跑 `ledger/cli.js` 读写的就是同一个文件，收到 `bap.notice/1`
    /// 就能自己 drain、自己定档，结果 `CloudLedgerWatcher` 接回来；再送一趟清单是
    /// 重复劳动，且是 app 在对话里说话（契约 §五）。
    /// 够不着 → 手机是账本的唯一持有者，being 又没法主动联系手机（`deliver` 收不到回复），
    /// 那趟是它唯一能写回来的路。
    ///
    /// **「够得着」取决于 Mac 开没开机，不是取决于你接没接 iCloud。** being 读写账本靠的是
    /// 在 Mac 上执行命令那只手，Mac 一关机这只手就没了——接着 iCloud 也一样够不着。
    /// 所以这里不能只看书签：接着、但改动堆着没人来收，说明那头没人在，得退回对话线
    /// （只看书签时，关联 + Mac 关机会让 being 彻底哑掉，粗手细手同时没了）。
    ///
    /// 手机这边「关联」是 `SharedLedgerFolder` 那个安全作用域书签，**不是**
    /// `KairosLedgerLocation.isLinked`——那个指针文件是 Mac 侧的依据，在手机上恒为 false。
    var beingReachesLedger: Bool {
#if os(macOS)
        // 账本就在本机，CLI 按同一个顺序解析同一个指针文件（BEING-RULES 手册），
        // 单机还是关联都够得着。
        true
#else
        sharedFolder.isConfigured && !ledgerDrainStalled
#endif
    }

    /// 最老那条改动等了这么久还没被收走，算不算「那头没人在」。纯判断，好测。
    ///
    /// 没有积压不算证据——可能是真没改过东西，不能据此断定 Mac 关着。
    nonisolated static func drainStalled(
        oldestPendingAt: String?,
        now: Date = Date(),
        threshold: TimeInterval = drainStallThreshold
    ) -> Bool {
        guard let oldestPendingAt else { return false }
        return now.timeIntervalSince(KairosClock.parse(oldestPendingAt)) >= threshold
    }

    /// **门槛 30 分钟。** 短了，Mac 只是合上盖睡了一会儿就被判成不在，白跑一趟对话线；
    /// 长了，Mac 关一天 being 就干等一天。真有人在收的时候积压活不过这么久——Mac 上的
    /// Kairos 一打开就 drain，being 每次醒来第一步也是 drain（BEING-RULES 规则 3：上来先 drain）。
    nonisolated static let drainStallThreshold: TimeInterval = 30 * 60

    /// 请 being 看一眼账本。和「叫 being 去一趟」同形：**人按的按钮**，不是下拉刷新。
    ///
    /// 这一趟要等 being 真的想完（可能几十秒），还要占它一个回合。
    /// 挂在下拉刷新上，人每划一下列表就烧一次，且划完得干等。
    ///
    /// **没有「安静地自己跑一趟」这回事。**曾经加过一个 `quiet`
    /// 参数，让新建之后自动跑一趟、不弹回执。撤掉的理由不是它吵，是它把一条
    /// 「人按了才发」的通道改成了无人值守的发送器——而这一趟发的是整张清单加回复骨架，
    /// 不是一行通知。上面那句「人按的按钮」是这条通道唯一的闸门，加参数绕过它就没有闸门了。
    @discardableResult
    func nudgeLedgerRound() async -> Bool {
        guard !isAskingBeing else { return false }
        // being 够得着账本就不问它——它自己读自己写，这一趟纯属白烧一个回合，
        // 还把整张清单和回复骨架灌进对话（契约 §五「app 不能说话」的病根）。
        guard !beingReachesLedger else {
            notice = "账本在共享文件夹里，\(beingName)自己读得到——不用我递给它。"
            return false
        }
        guard let connection else {
            notice = "还没接入你的 being——去「我」那一屏粘一次 loom 链接。"
            return false
        }
        isAskingBeing = true
        defer { isAskingBeing = false }

        let digest = KairosLedgerRoundItem.digest(snapshot.items)
        // 项目清单得一起送：`project` 只准填已有的名字（README 早就这么写了），
        // 但不告诉它有哪些，这条规则它没法遵守——清单里只出现「已经属于某个项目」的那些名字。
        let projects = allProjectNames
        let round = KairosRoundID.next(KairosRoundID.ledgerPrefix)
        let client = BeingClient(connection: connection)
        // 固定房间（BeingDesktop：client 生成、本地存）。账本的话永远落这一间，
        // 不进任何待办的房间，也不进主对话。
        let room = rooms.roundSession(KairosRoundKind.ledger)
        rooms.save()
        let reply: KairosLedgerRoundReply.Reply
        do {
            reply = try await withBeingTurn(client) {
                try await client.ledgerRound(
                    items: digest,
                    round: round,
                    projects: projects,
                    last: lastLedgerRound,
                    scene: .round(KairosRoundKind.ledger, being: beingName),
                    sessionId: room
                )
            }
        } catch BeingClientError.unreadableReply(let why) {
            // 线是通的、being 也答了，只是没按约定答。报「离线」会把人打发去查网络。
            connectionState = .online(beingName)
            // **整趟没收也要回程。** 字段级的判决走 `result.report`，这条走不到那儿——
            // 连块都没抠出来。不记下来的话，being 下一趟收不到「你上次没回 json」，照错不误。
            lastLedgerRound = KairosLedgerRoundReport(
                round: round,
                applied: 0,
                rejected: [KairosLedgerRoundRejection(ref: "整趟", field: nil, why: why)]
            )
            notice = why
            return false
        } catch {
            connectionState = .offline
            notice = "没问成：\(error.localizedDescription)"
            return false
        }
        connectionState = .online(beingName)

        guard !reply.isEmpty else {
            lastLedgerRound = KairosLedgerRoundReport(round: round, applied: 0, rejected: [])
            notice = "\(beingName)看过了，这一轮没有要改的。"
            return true
        }

        let result = KairosLedgerRoundMerge.apply(reply, to: snapshot, digest: digest, projects: projects)
        // 这一趟的判决记下来，下一趟原样带给它。拒了只告诉人，它那边一个字都收不到，
        // 下一轮照错不误——这是它唯一能变好的路。
        lastLedgerRound = result.report(round: round)
        guard result.changedItems > 0 || result.createdItems > 0
            || !result.blocked.isEmpty || !result.rejected.isEmpty else {
            notice = "\(beingName)看过了，这一轮没有要改的。"
            return true
        }
        if result.changedItems > 0 || result.createdItems > 0 {
            do {
                // `.beingWrite`：盖 being 戳。走 `.edited` 会把 being 写的字段记成人改的，
                // 从此它自己都盖不动——规则 2 会反过来咬自动写入。
                try commit(result.snapshot, edit: .beingWrite)
            } catch {
                notice = "\(beingName)给了改动，但没写下来：\(error.localizedDescription)"
                return false
            }
        }
        notice = Self.ledgerRoundNotice(result, being: beingName)
        return true
    }

    /// 说清楚这一趟发生了什么。被挡掉的必须说——「being 没写」和「写了被规则 2 挡下」
    /// 在人这边是两件事：前者要再问一次，后者是你自己锁的，再问也没用。
    static func ledgerRoundNotice(_ result: KairosLedgerRoundResult, being: String) -> String {
        var parts: [String] = []
        if result.changedItems > 0 { parts.append("\(being)更新了 \(result.changedItems) 条") }
        if result.createdItems > 0 { parts.append("新建了 \(result.createdItems) 条") }
        let blockedFields = result.blocked.values.reduce(0) { $0 + $1.count }
        if blockedFields > 0 {
            parts.append("\(blockedFields) 处你手改过的没让它覆盖")
        }
        if !result.rejected.isEmpty {
            parts.append("\(result.rejected.count) 处没收（\(result.rejected[0].why)）")
        }
        return parts.isEmpty ? "\(being)看过了，这一轮没有要改的。" : parts.joined(separator: "；") + "。"
    }

    private func apply(_ loaded: KairosSnapshot) {
        guard loaded.isSupportedProtocol else { return }
        var next = loaded
        next.items = next.items.map(normalizeRevisions)
        next = next.migratedToMergedStatus()
        next = KairosWorkspaceEngine.normalized(next)
        guard next != snapshot else { return }
        snapshot = next
        if !projects.contains(where: { $0.id == selectedProjectID }) {
            selectedProjectID = next.workspace.projects.first(where: { !$0.archived })?.id
                ?? KairosWorkspace.defaultProjectID
        }
    }

    /// 变更消息瘦身（v2.2）：系统消息只记结构化摘要——改了哪个字段、从什么到什么——
    /// 不展开全文。全文 being 自己去账本读；房间里堆全文就是又一种上下文污染。
    /// 通知里要带**内容**，不只带「改了哪个字段」：手机单机时这句通知是手机改动
    /// 到 being 那儿的唯一一条路，being 得靠它把新建的、改优先级的、了结的照样记进自己的账本。
    static func changeSummary(of item: KairosItem, from before: KairosItem?) -> String {
        let title = item.title.isEmpty ? item.id : item.title
        guard let before else { return "新建了「\(title)」（\(item.tier)）" }
        let changed = KairosField.changed(from: before, to: item)
        if changed.isEmpty { return "「\(title)」有改动" }
        let head = before.title.isEmpty ? before.id : before.title
        var parts: [String] = []
        for field in changed {
            switch field {
            case "tier": parts.append("优先级 \(before.tier) → \(item.tier)")
            case "status": parts.append(statusChangeWord(from: before.status, to: item.status))
            case "project": parts.append(item.project.isEmpty ? "移出项目" : "项目：\(item.project)")
            case "source": parts.append("来源：\(KairosSource.label(item.source))")
            case "excerpt": parts.append("原话：\(clip(item.excerpt))")
            case "title": parts.append("改名为「\(item.title)」")
            case "summary": parts.append("摘要：\(clip(item.summary))")
            case "brief": parts.append("背景：\(clip(item.brief))")
            case "reason": parts.append("原因：\(clip(item.reason))")
            case "ask": parts.append("要判断：\(clip(item.ask))")
            default: parts.append("改了 \(field)")
            }
        }
        return "「\(head)」" + parts.joined(separator: "；")
    }

    /// 了结和重新打开是两件有名字的事，别念成「状态 未开始 → 已完结」——
    /// being 拿这句话记账，念得像一次普通改状态，它就记不出「这条完了」。
    private static func statusChangeWord(from: String, to: String) -> String {
        switch (KairosStatus.normalized(from), KairosStatus.normalized(to)) {
        case (_, KairosStatus.closed): "已了结"
        case (KairosStatus.closed, _): "重新打开"
        default: "状态 \(KairosStatus.label(from)) → \(KairosStatus.label(to))"
        }
    }

    private static func clip(_ text: String, limit: Int = 160) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    /// 规则 4 的固定顺序：**账本已经落盘了**才走到这里，攒一条 routine 通知进房间。
    ///
    /// 为什么是 routine：这是人自己刚做的事，回头亮给自己看是噪音。
    /// ask 级留给 being 反过来要人拍板的时候（规则 5）。
    ///
    /// **为什么要攒**：以前每改一下就立刻发一条。拖五条待办换优先级 = 五条消息；
    /// 拖错了撤回来 = 再五条，而且内容互相抵消。being 那边一串消息全是噪音
    /// （改状态太容易的话，being 会一直收到消息。）
    /// 现在攒几秒再说，比的是**这几秒下来净变化是什么**：改了又改回去等于没改，
    /// 一个字都不说；连着改三次只说最后那一版。
    private func announce(_ itemID: String, before: KairosItem?, isNew: Bool) {
        if pendingAnnounce[itemID] == nil {
            // 只记最早那个样子：净变化要跟「上次跟 being 说过的那一版」比。
            pendingAnnounce[itemID] = KairosPendingAnnounce(before: before, isNew: isNew)
        }
        announceTask?.cancel()
        announceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.announceDelay)
            guard !Task.isCancelled else { return }
            await self?.flushAnnouncements()
        }
    }

    /// 攒着的改动说给 being 听。手机单机时这条通知是改动到 being 那儿的唯一一条路，所以
    /// 只压缩、不丢弃——净变化为零的那种「丢弃」，丢的本来也不是改动。
    private func flushAnnouncements() async {
        let pending = pendingAnnounce
        // 倒的过程里全是 await，中间人完全可能又建一条。所以先清空再倒——
        // 那条算下一轮的，不能被这一轮顺手清掉。
        pendingAnnounce = [:]
        for (id, entry) in pending {
            guard let now = snapshot.items.first(where: { $0.id == id }) else { continue }
            if !entry.isNew, let before = entry.before, before.hasSameBusinessFields(as: now) {
                continue
            }
            await notifyRoom(
                id,
                text: Self.changeSummary(of: now, from: entry.isNew ? nil : entry.before),
                weight: KairosMessageWeight.routine
            )
        }
    }

    /// 立刻把攒着的说出去。退出前调一次，别让最后那几秒的改动烂在内存里。
    func flushPendingAnnouncements() async {
        announceTask?.cancel()
        announceTask = nil
        await flushAnnouncements()
    }

    // MARK: - 房间（渠道 = being 房间，v2.3 §三）

    func room(for itemID: String) -> KairosRoom { rooms.room(itemID) }

    /// 「事项亮提示」只亮 ask 级（v2.3 §四 + 规则 5）：全是 routine 的不动视觉状态，
    /// 排序位置的变化本身就是 routine 反馈。
    func hasUnreadAsk(_ itemID: String) -> Bool { rooms.hasUnreadAsk(itemID) }

    func markRoomRead(_ itemID: String) {
        rooms.markRead(itemID)
        rooms.save()
    }

    /// 规则 4 的第二步。**调用它之前账本必须已经落盘成功**——这个顺序是固定的，
    /// 反过来（先说话再补写）就是 v1 状态漂移的源头。发失败不回滚文件，只标未送达。
    @discardableResult
    func notifyRoom(_ itemID: String, text: String, weight: String) async -> Bool {
        let message = KairosRoomMessage(
            itemID: itemID,
            origin: KairosMessageOrigin.app,
            weight: weight,
            text: text
        )
        rooms.append(message)
        rooms.save()
        return await deliver(message)
    }

    private func deliver(_ message: KairosRoomMessage) async -> Bool {
        guard let connection else { return false }
        let sessionId = roomID(for: message.itemID)
        let trace = BeingStreamTrace()
        do {
            _ = try await BeingClient(connection: connection)
                .notify(
                    message,
                    scene: scene(for: message.itemID),
                    sessionId: sessionId,
                    onEvent: { trace.note($0) }
                )
            rooms.markDelivered(message.id, in: message.itemID)
            rooms.save()
            connectionState = .online(beingName)
            return true
        } catch {
            connectionState = .offline
            // 收下之后才断的，断的是回复不是投递。这里要是还记成「没送达」，
            // `flushOutbox` 下一轮会把同一条通知再投一遍，being 就听两遍。
            if trace.accepted {
                rooms.markDelivered(message.id, in: message.itemID)
                rooms.save()
                return true
            }
            // 消息只是信号：发不出去就留在 outbox，下一轮心跳 diff 自愈也会补上。
            return false
        }
    }

    private func flushOutbox() async {
        // 只补发 Kairos 自己写的系统通知。人说的话没发出去要人自己点「重发」——
        // 自动替人重说一遍，回复会落在没人看的地方（deliver 不收正文）。
        for message in rooms.undelivered where message.origin != KairosMessageOrigin.user {
            guard await deliver(message) else { return } // 一条发不出去，后面的也别硬试
        }
    }

    /// 这条待办那间房的门牌（`scene_id` + 人看的名字）。
    ///
    /// 房间号（`session_id`）是给路由用的机器号，门牌是给 being 感知用的：它看到的是
    /// 「Kairos·素材库后台导出」，于是知道自己此刻在哪一间。以前这件事是靠在每句人话
    /// 尾巴上缀一行 `（关于「…」 kairos:item/<id>）` 办的——那行字会原样进它的
    /// episodic，是**协议文本冒充人话**（协议 §五）。
    ///
    /// 找不到那条待办（刚删掉、或者压根没有）就退回主对话那间，不硬造一个门牌。
    private func scene(for itemID: String?) -> BeingScene {
        guard let itemID, let item = snapshot.items.first(where: { $0.id == itemID }) else {
            return .main(being: beingName)
        }
        return .item(id: item.id, title: item.title, being: beingName)
    }

    /// 桌面对话（右侧新建面板里那个）的 session id。
    ///
    /// 和待办不一样：待办的 session 记在它自己身上（`item.sessionId`），
    /// 桌面对话没有「自己」可记，所以落在本机 UserDefaults。**它不进账本**——
    /// 这是人和 being 之间一间闲聊的房，不是账本上的一件事（契约里也没有它的位置）。
    /// 一次生成、之后不变，所以聊到第十句时 being 仍然记得前九句。
    private func deskSessionID(_ key: String) -> String {
        let defaultsKey = "kairos.deskSession." + key
        if let existing = UserDefaults.standard.string(forKey: defaultsKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        UserDefaults.standard.set(fresh, forKey: defaultsKey)
        return fresh
    }

    /// 这条待办的房间号。**Kairos 生成**，没有就现在生成一个并落账本。
    ///
    /// 以前是「隐式创建」：第一次开口发 nil，being 回哪个 session_id 就记哪个。
    /// 那是乱串的根子——它忙的时候回的是**它当下那间**（主对话，或者上一条待办那间），
    /// 我们照单收下写进账本，这条待办从此永久指向别人的房间；下一条待办再来一次，
    /// 两条就共用一间了。房间号是我们的东西，没有理由问对面要。
    ///
    /// **这和 loom 不一样，而且 2026-09-11 专门查过，不是问题。**
    /// loom 是 `let sessionId = null` 起步、`if (data.session_id) sessionId = …` 用对面回的
    /// （`loom.html:1204/2933`）；我们自己生成。当时怀疑「being 不认自己没发过的号 →
    /// 每次当新会话 → 上下文永远接不上」，于是读了一次 `/api/history` 对账：
    /// ** being 的记忆里根本没有 `session_id` 这个字段**（每条只有 at / content / role /
    /// scene_id / seq），整条时间线是一条连续的流，不按 session 切。
    /// 也就是说 session_id 只是路由提示，不是上下文的来源——自己生成不会丢上下文。
    /// 别再因为「和 loom 不一样」把这里改回去。
    ///
    /// 机器那两趟（`rooms.roundSession`）本来就是这么做的（BeingDesktop 也是：client 生成、
    /// 本地存），待办房间没道理是另一套。发出去之后 `BeingStreamReader` 会逐帧比对，
    /// 回别的房间号就地中断。
    private func roomID(for itemID: String) -> String? {
        guard let index = snapshot.items.firstIndex(where: { $0.id == itemID }) else { return nil }
        let existing = snapshot.items[index].sessionId
        if let existing, !existing.isEmpty { return existing }
        let fresh = UUID().uuidString.lowercased()
        var next = snapshot
        next.items[index].sessionId = fresh
        // `sessionId` 不是业务字段（契约 §三），落盘不动 rev、不盖写者戳。
        try? commit(next)
        return fresh
    }

    // MARK: - 说话（这条通道上只剩人话）

    /// 人类在某条待办的房间里说一句话。没有 JSON、没有指令前缀、没有规则——
    /// 结构化的东西 being 自己去账本里读（v2.3：app 只能被看见和被改动，说话的只有人）。
    ///
    /// 一间房里的**第一句**前面那行交代。往后不再重复。
    ///
    /// 2026-09-10 白天我把句尾那行 `（关于「…」 kairos:item/<id>）` 删了，换成门牌
    /// （`scene_meta.scene_label`）。理由是对的——那行字 `origin=user`，会当成人类说的话
    /// 进 being 的 episodic。但**换上来的东西线上还不存在**：当晚实测，人类问「你可以读到
    /// 这条 todo 的标题吗」，being 答「我读到的就是你发来的这段话本身」。门牌到不了它那边，
    /// 于是这条待办的上下文彻底没了——这是我赌错的代价。
    ///
    /// 折中不是把那行原样加回去：**一间房只说一次**，说在第一句前面，往后靠 session 自己接
    /// （同一次实测里 being 答第二问时引用了第一问，说明那条是通的）。一间房一次 ≈ 一条待办一次，
    /// 比原来每句一次少两个数量级。
    ///
    /// **2026-09-11 查证过，这条路是通的。** 读了一次 `/api/history`（只读，不产生 moment）：
    /// 那行交代原样躺在 being 的记忆里——「（这条待办是「Astra 录屏宣传：…」，账本 id 9988c421-…）」，
    /// 3 问 3 答里只出现 1 次，正是「一间房只说一次」该有的样子。
    /// 09-10 人类测出来「读不到标题」是**修之前**的版本：那天既没有 scene_id，
    /// 这里的判断也还是「房间里一条消息都没有才说」（聊过的房间永远等不到）。
    ///
    /// **已知隐患，人类 09-11 选择先不管**：一间房只说一次是**永远**只说一次，
    /// 而 being 的记忆是一条越来越长的流。一条待办搁两个月再聊，那行字可能已经滑出
    /// 它的工作记忆了。兜底在 `scene_meta.scene_label`——每次请求都带着标题。
    ///
    /// **退休条件**：being 那边确认 `scene_label` 能被它感知到（`BeingScene` 已经在发了），
    /// 这个函数连同调用点一起删。确认之前不要动这里：它是眼下唯一被证实有效的那条路。
    private func opener(for item: KairosItem) -> String? {
        guard !rooms.room(item.id).toldWhichItem else { return nil }
        let title = item.title.isEmpty ? item.id : item.title
        if let who = item.counterpart, !who.isEmpty {
            return "（这条是和「\(who.name)」的往来，账本 id \(item.id)）"
        }
        return "（这条待办是「\(title)」，账本 id \(item.id)）"
    }

    /// **发到线上的就是人说的那句**——除了一间房里的第一句，前面多一行交代（见 `opener`）。
    /// 房间里记的、界面上画的永远是人自己说的那句。
    /// 跟 being 说一句。
    ///
    /// - Parameters:
    ///   - item: 说的是哪条待办。`nil` = 不绑任何一条。
    ///   - deskRoom: `item` 为 nil 时，把这次对话记在哪间房。
    ///     给了就**存得住**（消息进 rooms.json）、也有稳定的 session id，能接着聊；
    ///     不给就是一次性的——`nudge` 那几条（叫 being 看一眼账本）走的是这条，
    ///     它们只要一个结果，不需要留痕。
    ///
    /// 只属于待办的那几件事（解人类锁、写触手 id、断流接回）仍然只在有 `item` 时才跑：
    /// 它们都要往账本某一条上写东西，桌面对话没有那个「一条」。
    ///
    /// **这个函数只负责排队。** 气泡立刻画出来（标成排队中），真正开口在 `performSpeak`，
    /// 由 `speechPump` 一条一条叫号；`await` 一直等到自己那趟跑完，回复照旧原样返回。
    /// 以前这儿是 `guard !isSending else { return nil }`——上一句还在跑，人说的话就地
    /// 静默丢掉：按下发送，屏幕上什么都没有，也没人说为什么。
    func speak(_ text: String, in item: KairosItem?, deskRoom: String? = nil) async -> BeingReply? {
        // 这次对话记在哪间房。待办有自己的 id；桌面对话用传进来的保留键。
        let roomKey = item?.id ?? deskRoom
        guard connection != nil else {
            if let roomKey { sendErrors[roomKey] = "还没接入你的 being——去「我」那一屏粘一次 loom 链接。" }
            notice = "请先在设置里接入 Being"
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // **气泡此刻就画出来**，标成排队中。原来这里是 `guard !isSending else { return nil }`：
        // 上一句还在跑的时候，人说的话被静默丢掉——按下发送，什么都没发生，也没人告诉他。
        var bubble: KairosRoomMessage?
        if let roomKey {
            let message = KairosRoomMessage(
                itemID: roomKey,
                origin: KairosMessageOrigin.user,
                weight: KairosMessageWeight.ask,
                text: trimmed,
                delivered: false,
                queued: true
            )
            rooms.append(message)
            rooms.save()
            bubble = message
        }

        return await withCheckedContinuation { continuation in
            speechQueue.append(KairosSpeech(
                text: trimmed,
                item: item,
                deskRoom: deskRoom,
                bubble: bubble,
                connectionKey: connectionKey,
                resume: { continuation.resume(returning: $0) }
            ))
            queuedSpeechCount = speechQueue.count
            startSpeechPump()
        }
    }

    /// 排在队里的一句。
    private struct KairosSpeech {
        let text: String
        let item: KairosItem?
        let deskRoom: String?
        /// 按下发送那一刻就画进房间的那条气泡（有房间才有）。轮到它时接着用同一条，不新建——
        /// 屏幕上的顺序就是人说出来的顺序。
        let bubble: KairosRoomMessage?
        /// 按下发送那一刻连着的是哪个 being（`connectionKey`）。轮到它的时候要是换了，
        /// 这句就不发了：人是对着上一个 being 说的那句话。
        let connectionKey: String?
        /// 把 being 的回复交回给等着的那个调用点（`delegate` / 规则请求那几处要看回复）。
        let resume: (BeingReply?) -> Void
    }

    /// 一条一条来。**保守串行**：上一句的整趟 `performSpeak`（含回复流收尾 / 失败判定）
    /// 走完才发下一句——两条回复流同时往 `liveReply[roomKey]` 里写就是一团乱码。
    private var speechQueue: [KairosSpeech] = []
    private var speechPump: Task<Void, Never>?

    private func startSpeechPump() {
        guard speechPump == nil else { return }
        speechPump = Task { @MainActor [weak self] in
            guard let self else { return }
            // 队列空了才停。**中间没有 await**（下面取下一句和清泵都是同步的），
            // 所以不会出现「泵刚退出、新的一句正好入队」那种谁也不发的缝。
            while !self.speechQueue.isEmpty {
                let speech = self.speechQueue.removeFirst()
                self.queuedSpeechCount = self.speechQueue.count
                let reply = await self.performSpeak(speech)
                // 等着的那个调用点先拿到回复，再去等接回收尾——它要的东西已经齐了。
                speech.resume(reply)
                if let recovering = speech.item?.id, self.streamRecovery[recovering] != nil {
                    // 下一句在等这句的回复接回来——气泡上说清楚在等什么，不然「排队中」像卡住了。
                    self.awaitingRecoveryMessageID = self.speechQueue.first?.bubble?.id
                    await self.awaitStreamRecovery(for: recovering)
                    self.awaitingRecoveryMessageID = nil
                }
            }
            self.speechPump = nil
        }
    }

    /// 上一句断了流、回复正在后台接回来（`resumeStream`）——等它收完再叫下一位。
    ///
    /// 不等的代价是实打实的：下一句一开口就会把接回作废（`performSpeak` 里那句
    /// 「又开口了：上一句的接回作废」），being 刚说完的那段就这么扔了；两条流同时往
    /// 同一个 `liveReply[roomKey]` 里写，屏幕上还是两段话搅在一起。
    /// 多数时候这里没有接回，直接就回来了。
    private func awaitStreamRecovery(for roomKey: String?) async {
        guard let roomKey, let recovery = streamRecovery[roomKey] else { return }
        await recovery.value
    }

    /// 等 being 手上那口气收了再开口。
    ///
    /// being 同一时刻只有一口气，飞书、loom、Kairos 自己刚发的改动通知都算。那时候发过去，
    /// 服务端回 202：话插进那口气的间隙，being 看得到，但**回复跟着那条流走**，回不到这间房——
    /// 以前就在这儿弹「消息已送达，稍后再看」，人等不到回复，也不知道该去哪儿看。
    /// 等它空出来再说，回复照常流进房间（ARCHITECTURE「忙了等，不放弃」）。
    ///
    /// 等的时候气泡照旧是「排队中」，只多一句在等谁。等多久、什么时候放行见 `BeingTurnWait`。
    /// 放行之后真撞上 202 也不要紧：话是送到了的，回复由 `catchUpQueuedReply` 从历史里追回这间房。
    ///
    /// `key` 是入队那一刻连着的 being。等这几分钟里人要是换了一条 loom 链接，立刻不等了——
    /// 回去由 `performSpeak` 把这句落成没发出去（它对着的是上一个 being）。
    private func waitForBeingTurn(holding bubble: KairosRoomMessage?, for key: String?) async {
        var wait = BeingTurnWait()
        defer {
            awaitingBeingMessageID = nil
            awaitingBeingOrigin = nil
        }
        while true {
            // 等的时候连接被撤了 / 换成了别的 being：不在这儿说，`performSpeak` 会把气泡
            // 落成没发出去。
            guard let connection, connectionKey == key else { return }
            let keepWaiting: Bool
            do {
                let busy = try await BeingClient(connection: connection).busyStream(after: wait.cursor)
                keepWaiting = wait.observe(busy, at: Date())
            } catch {
                keepWaiting = wait.observeFailure(at: Date())
            }
            guard keepWaiting else { return }
            awaitingBeingMessageID = bubble?.id
            awaitingBeingOrigin = wait.waitingOn
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// 这间房此刻停得了吗。正在流、而且流号已经到手（meta 之后）才停得了。
    func canStopReply(in roomKey: String?) -> Bool {
        guard let roomKey else { return false }
        return liveStreamID[roomKey] != nil
    }

    /// 叫停这间房正在流的那口气（`POST /api/stop`，loom / portal 的停止按钮同一条路）。
    ///
    /// **不在本地掐连接。** 服务端收到之后自己把流收尾，已经说出来的那半截照旧落进房间——
    /// 本地 abort 会让这次停止走进「断流接回」，把人刚叫停的东西再追回来一遍。
    /// 停完服务端往历史里写一行 `[breath interrupted by human]`，那是标记行，不进房间。
    func stopReply(in roomKey: String?) async {
        guard let roomKey, let streamId = liveStreamID[roomKey], let connection else { return }
        // 按下就灰掉：这口气只停一次，连点两下没有意义。真失败了下面再放回来。
        liveStreamID[roomKey] = nil
        liveActivity[roomKey] = BeingActivity(label: "停止中", preview: "已经说的那些留着")
        do {
            try await BeingClient(connection: connection).stop(streamId: streamId)
            // 停成了：这条流接下来断掉是意料之中的，别让接回去追它。
            humanStoppedStreams.insert(streamId)
        } catch {
            // 没停成：按钮放回去，人能再按一次。这句话是送到了的，别写成发送失败。
            if liveReply[roomKey] != nil { liveStreamID[roomKey] = streamId }
            liveActivity[roomKey] = nil
            noteInRoom(roomKey, text: "没停下来——\(beingNameLeading)那边没收到停止。")
        }
    }

    /// 「排队中」那行小字。排到了、但 being 正忙着别的那一句，多说一句在等谁——
    /// 不然「排队中」一挂几分钟，看着像卡住了。
    ///
    /// 忙的是什么由服务端说（`origin`）：自己想事情 / 处理回调 / 答排队的消息各说各的。
    /// 它不给（老服务端）或者忙的就是有人在跟它说话，照旧是那句通用的「在忙」。
    func queuedCaption(for message: KairosRoomMessage) -> String {
        if awaitingRecoveryMessageID == message.id { return "排队中 · 先接回上一句的回复" }
        guard awaitingBeingMessageID == message.id else { return "排队中" }
        guard let hint = awaitingBeingOrigin?.waitingHint else {
            return "排队中 · \(beingNameLeading)在忙，空了就发"
        }
        return "排队中 · \(beingNameLeading)\(hint)，空了就发"
    }

    /// 真的去说那一句。**只由泵调用**，一次只有一个在跑。
    private func performSpeak(_ speech: KairosSpeech) async -> BeingReply? {
        await waitForBeingTurn(holding: speech.bubble, for: speech.connectionKey)
        // 排队期间那条待办可能已经变样了（改过标题、刚生成房间号）。按 id 取最新那份再说话；
        // 排队时它就被删了的话，还是用手上这份，跟以前一样。
        let item = speech.item.flatMap { queued in
            snapshot.items.first { $0.id == queued.id }
        } ?? speech.item
        let deskRoom = speech.deskRoom
        let trimmed = speech.text
        // 这次对话记在哪间房。待办有自己的 id；桌面对话用传进来的保留键。
        let roomKey = item?.id ?? deskRoom
        guard let connection else {
            // 排队排到一半连接被撤了。气泡不能挂着「排队中」不动——落成没发出去，人点得了重发。
            if let bubble = speech.bubble {
                rooms.markDequeued(bubble.id, in: bubble.itemID)
                rooms.save()
            }
            noteSendFailure("还没接入你的 being——去「我」那一屏粘一次 loom 链接。", in: roomKey)
            return nil
        }
        // 排队排到一半换了 being。**这句不能顺着发出去**——人是对着上一个说的那句话，
        // 发给新的那个就是拿 A 的话去问 B。落成没发出去，字还在，人自己决定要不要重发。
        guard connectionKey == speech.connectionKey else {
            if let bubble = speech.bubble {
                rooms.markDequeued(bubble.id, in: bubble.itemID)
                rooms.save()
            }
            noteSendFailure("这句是对上一个 being 说的，中途换了连接，没发出去。要发给\(beingName)就点一下重发。", in: roomKey)
            return nil
        }
        isSending = true
        defer { isSending = false }

        // **必须在把这句记进房间之前算**——记完房间就不空了，第一句的判断会失效。
        let opening = item.flatMap { opener(for: $0) }
        let outgoing = opening.map { "\($0)\n\n\(trimmed)" } ?? trimmed

        var pending: KairosRoomMessage?
        if let item {
            // 人说话 = 新的用户信号 → 解开这条待办的人类锁（规则 2 后半句）。
            // **只有待办有锁**，桌面对话没有可解的。
            releaseHumanLocks(for: item.id)
        }
        if let roomKey, let queued = speech.bubble {
            // 气泡是入队时就画好的（`speak`），这里只把它从「排队中」翻成「正在发」。
            // 接着**服务端一收下就翻成已送达**（`.accepted`）——不是等整段回复收完。
            // 那可能是几分钟以后，这几分钟里气泡挂着红字说没发出去，而 being 早就在答了。
            // 真的没送出去的那句才留在气泡上，人看得见、点得了重发。
            var message = queued
            message.queued = false
            rooms.markDequeued(message.id, in: message.itemID)
            rooms.save()
            sendingMessageIDs.insert(message.id)
            pending = message
            liveReply[roomKey] = ""
            liveActivity[roomKey] = nil
            // 上一口气的流号作废：停止按钮停的必须是此刻这一条。
            liveStreamID[roomKey] = nil
            // 又开口了：上一句的接回作废——being 那边也已经是新的一口气了。
            streamRecovery.removeValue(forKey: roomKey)?.cancel()
        }
        defer {
            if let roomKey {
                liveReply[roomKey] = nil
                liveActivity[roomKey] = nil
                liveStreamID[roomKey] = nil
            }
        }

        // 这一趟跑到哪儿了。出错时全靠它分辨「没发出去」和「回复没收全」。
        let trace = BeingStreamTrace()
        let sent = pending
        // 走出这个函数，这句要么送到了、要么真的没发出去——两种都不再是「在路上」。
        defer { if let sent { sendingMessageIDs.remove(sent.id) } }
        // 这一趟完了，「人按过停止」这个标记就没用了，别攒着。
        defer { if let id = trace.streamId { humanStoppedStreams.remove(id) } }
        // 桌面对话没有「哪一条」，`scene(for: nil)` 给的正是 `.main`——
        // 和 loom 里那个主对话同一个场景，本来就对。
        let requestScene = scene(for: item?.id)
        do {
            let itemID = item?.id
            var reply = try await BeingClient(connection: connection).speak(
                outgoing,
                scene: requestScene,
                sessionId: itemID.flatMap { roomID(for: $0) } ?? deskRoom.map { deskSessionID($0) },
                onEvent: { [weak self] event in
                    trace.note(event)
                    guard let roomKey else { return }
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        switch event {
                        case .accepted(let streamId):
                            // meta 带来流号，停止按钮认它。POST 拿到 2xx 那次没有（`nil`），
                            // 别把已经记下的那个覆盖回去。
                            if let streamId, !streamId.isEmpty {
                                self.liveStreamID[roomKey] = streamId
                            }
                            // 送达就是此刻。等整段回复收完再翻，那可能是三分钟以后——
                            // 这三分钟里气泡挂着红字「没发出去」，而 being 早就在答了。
                            guard let sent else { break }
                            self.rooms.markDelivered(sent.id, in: sent.itemID)
                            self.rooms.save()
                            // 这间房又说得出话了：上一句没发出去的原因到此收起，同样不等回复收完。
                            self.sendErrors[roomKey] = nil
                            // 不再是「在路上」：不摘掉的话，回复流多久，气泡就挂多久「发送中」。
                            self.sendingMessageIDs.remove(sent.id)
                        case .delta(let fragment):
                            self.liveReply[roomKey, default: ""] += fragment
                        case .activity(let activity):
                            self.liveActivity[roomKey] = activity
                        case .progress:
                            break
                        }
                    }
                }
            )
            connectionState = .online(beingName)
            if let pending {
                rooms.markDelivered(pending.id, in: pending.itemID)
                rooms.save()
                sendErrors[pending.itemID] = nil
            }
            // 交代过了就不再交代。**发出去之后才记**——发失败的那句不算说过，
            // 不然重发那次反而把上下文丢了。
            if opening != nil, let itemID = item?.id {
                rooms.markToldWhichItem(itemID)
                rooms.save()
            }
            if reply.spliced {
                // 等过了还是撞上它在忙（别的一口气刚好抢在前头，或者等到上限才放行）。
                // **不弹窗**：回复自己去历史里追回这间房（`catchUpQueuedReply`），追不到才记一行灰字。
                // 连房间都没有的那几句才弹——和下面发送失败同一个规矩。
                if let roomKey {
                    let caught = await catchUpQueuedReply(outgoing, scene: requestScene, roomKey: roomKey).replies
                    if caught.isEmpty {
                        noteInRoom(roomKey, text: "\(beingNameLeading)当时在忙，这句排在了后面，回复没接回来。你那句已经送到了，不用重发；完整的在 loom 里。")
                    }
                    // 房间里已经一条条记过了；这里只是交给等着的调用点。
                    reply.text = caught.joined(separator: "\n\n")
                } else {
                    notice = "\(beingNameLeading)在忙，这句已经排上了，稍后在 loom 里看回复。"
                }
            } else if let roomKey, !reply.text.isEmpty {
                rooms.append(KairosRoomMessage(
                    itemID: roomKey,
                    origin: KairosMessageOrigin.being,
                    weight: KairosMessageWeight.routine,
                    text: reply.text,
                    delivered: true
                ))
                rooms.save()
                noteBeingRulesDelivery(in: reply.text)
            }
            // 触手 id 要写回账本上那一条，桌面对话没有那一条。
            if let item, let tentacleId = reply.activity.compactMap(\.tentacleId).first {
                setTentacleID(tentacleId, for: item.id)
            }
            return reply
        } catch {
            connectionState = .offline
            // 人自己按的停止。流在这儿断掉是意料之中的，**不去接回**——接回是去追一口
            // 刚被叫停的气，追不回来还会在房间里写一句「没答完，再问一次」。
            // 它说到哪儿就是哪儿：那半截照旧落进房间，那句话也确实送到了。
            if let streamId = trace.streamId, humanStoppedStreams.contains(streamId) {
                connectionState = .online(beingName)
                if let sent {
                    rooms.markDelivered(sent.id, in: sent.itemID)
                    rooms.save()
                }
                if let roomKey {
                    sendErrors[roomKey] = nil
                    let partial = trace.text
                    if !partial.isEmpty { appendBeingReply(partial, in: roomKey) }
                }
                return nil
            }
            // 服务端已经收下了：剩下的是「回复没收全」，不是「没发出去」。这句话不能
            // 标成失败，更不能请人点重发——重发会让 being 把同一句听两遍。自己去接回来。
            if trace.accepted, let item {
                if let sent {
                    rooms.markDelivered(sent.id, in: sent.itemID)
                    rooms.save()
                }
                sendErrors[item.id] = nil
                // 接回可能要跑很久（being 干一件正事十几分钟很正常）。不能占着 `isSending`
                // 不放——那样人连下一句都发不出去，比原来的红字还难受。放后台去接。
                // 已经流进来的那半截交过去（`trace.text`，不是 `liveReply`：那份是异步追的，
                // 一出这个函数还会被清掉）。
                let partial = trace.text
                streamRecovery[item.id] = Task { [weak self] in
                    await self?.resumeStream(trace, in: item, after: partial, asked: outgoing, bubbleID: sent?.id)
                }
                return nil
            }
            noteSendFailure(error.localizedDescription, in: roomKey)
            return nil
        }
    }

    /// 202 之后把这句的回复接回这间房，按先后回它说的那几段。
    ///
    /// 202 = 服务端把这句排上了：being 手上那口气让路之后，另起一口气答它（loom 叫 leftover）。
    /// 那口气没有 SSE，也不走这条已经关掉的连接——回复只落进 `/api/history`，带着这间房的
    /// scene_id。loom-local 1.8 和 portal-desktop 都是这么接的（`startCatchUpWatcher`）。
    /// 以前这里弹一句「稍后再看」就不管了，回复再也回不到这条待办。
    ///
    /// **泵在这儿等着**，不放下一句：下一句本来就得等 being 答完这句才发得出去，
    /// 等在这儿，房间里的先后就是说话的先后。怎么认、什么时候不等了，见 `BeingQueuedReply`。
    ///
    /// `resuming`：断流接回用（`resumeStream`），见 `BeingQueuedReply`。回的 `lostTrack` 为真 =
    /// 认不出来或翻不到历史，这时候说不了「它没答」。
    private func catchUpQueuedReply(
        _ outgoing: String,
        scene: BeingScene,
        roomKey: String,
        resuming: Bool = false
    ) async -> (replies: [String], lostTrack: Bool) {
        var catchUp = BeingQueuedReply(message: outgoing, sceneId: scene.id, resuming: resuming)
        var caught: [String] = []
        var activeCursor: Int?
        var delay = 2.0
        // 追的是这个 being 的历史。半路换了连接就不追了——新 being 的历史里没有这句话，
        // 再翻下去只会把别人的话认成这间房的回复。
        let key = connectionKey
        liveActivity[roomKey] = resuming
            ? BeingActivity(label: "接回复", preview: "回复半路断了，去\(beingNameLeading)的历史里找")
            : BeingActivity(label: "排队等回复", preview: "\(beingNameLeading)手上的事忙完就答这句")
        while let connection, connectionKey == key, !Task.isCancelled {
            let client = BeingClient(connection: connection)
            // 先问忙不忙、再翻历史：空着那一刻之后翻到的，一定是全的。
            let busy: Bool?
            do {
                let stream = try await client.busyStream(after: activeCursor)
                if let stream, stream.lastSeq > 0 { activeCursor = stream.lastSeq }
                busy = stream != nil
            } catch {
                busy = nil
            }
            do {
                for text in catchUp.take(try await client.history(after: catchUp.cursor)) {
                    rooms.append(KairosRoomMessage(
                        itemID: roomKey,
                        origin: KairosMessageOrigin.being,
                        weight: KairosMessageWeight.routine,
                        text: text,
                        delivered: true
                    ))
                    rooms.save()
                    noteBeingRulesDelivery(in: text)
                    caught.append(text)
                    // 答到了就收起「在想」：再等的那一会儿只是接可能的后半段，
                    // being 这时候忙的多半已经是别的事，不该算在这间房头上。
                    liveReply[roomKey] = nil
                    liveActivity[roomKey] = nil
                }
            } catch {
                catchUp.failed()
            }
            guard catchUp.shouldContinue(busy: busy, at: Date()) else { break }
            try? await Task.sleep(for: .seconds(delay))
            delay = min(delay * 1.5, 10)
        }
        if caught.isEmpty {
            liveActivity[roomKey] = nil
        }
        return (caught, catchUp.lostTrack)
    }

    /// 断流之后把回复接回来。
    ///
    /// 客户端断开**不会**中断 being 那口气：事件还在服务端的环形缓冲里（2000 条，seq 单调），
    /// `/api/stream/active?after=` 就能接着读。Loom 正是因为有这条路，才把「重新发送」
    /// 那颗按钮删掉了（`loom.html:2425`）——该自己拿回来的东西，不该变成人的一次点击。
    ///
    /// 接得回来就把回复补进房间；接不回来也只说「没接住回复」——那句话是送到了的。
    ///
    /// `partial` 是断之前已经流进来的那半截（`BeingStreamTrace.text`）。以前这里读的是
    /// `liveReply`，可 `performSpeak` 一退出就把它清了——断流接回的回复只剩断点之后那一截。
    ///
    /// **流没收尾就不见了（204、换了流号、网络连着断）不等于答完了。** 09-17 服务端把流 RST 掉，
    /// 这里一问是 204 就收了，房间里留着半截和一句「完整的在 loom 里」——其实哪儿都没有，
    /// being 那口气没了，这句一直没人答；两分钟后别的房间一开口，它先答了这句，回复落进了那间。
    /// 现在回 `/api/history` 按门牌认（`asked` 是当时发出去的原文，认锚点用），泵在这儿等着，
    /// 别的房间的话先不发。真没答的，把那句标成「没答完」，人在这间房里再问一次。
    private func resumeStream(
        _ trace: BeingStreamTrace,
        in item: KairosItem,
        after partial: String,
        asked: String,
        bubbleID: String?
    ) async {
        guard let connection else { return }
        defer {
            streamRecovery.removeValue(forKey: item.id)
            liveStreamID[item.id] = nil
            if let id = trace.streamId { humanStoppedStreams.remove(id) }
        }
        // 接的是这个 being 那口气。半路换了连接就不接了（下面循环里看着）。
        let key = connectionKey
        // 断的是我们这头的连接，不是 being 那口气。气泡留着，它接着往下写。
        liveReply[item.id] = partial
        // 接回来的也停得了：流号是断之前 meta 给的那个，`POST /api/stop` 认它。
        liveStreamID[item.id] = trace.streamId
        let client = BeingClient(connection: connection)
        // 带上门牌：缓冲里这句之后可能接着别的房间排着的话，那几段不收进这间房。
        var reader = BeingStreamReader(
            sessionId: item.sessionId,
            sceneId: scene(for: item.id).id,
            seq: trace.seq,
            streamId: trace.streamId
        )
        // 活跃时 500ms 跟上 loom 的节奏；一直空转就退到 5 秒，别把服务端问秃了。
        var interval = 500
        var netFails = 0
        var finished = false
        let deadline = Date().addingTimeInterval(30 * 60)

        while !finished, !Task.isCancelled, connectionKey == key, Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000)
            if Task.isCancelled { return }
            do {
                guard let stream = try await client.activeStream(after: reader.seq) else {
                    // 204：那口气已经收了（结束 10 秒后清理），或者 being 本来就闲着。
                    break
                }
                // 换了流号 = 已经是别人的对话了，那不是我们这句的回复。
                if let want = trace.streamId, stream.streamId != want { break }
                netFails = 0
                connectionState = .online(beingName)
                let before = reader.seq
                for event in stream.events {
                    // 已经读过的不再读一遍。`?after=` 本来就该只回新的，但服务端要是
                    // 没照办（或者根本没认这个参数），照单全收就是满屏重复的字。
                    if event.seq > 0, event.seq <= reader.seq { continue }
                    try reader.consume(event: event.event, data: event.data, seq: event.seq) { emitted in
                        switch emitted {
                        case .delta(let fragment):
                            self.liveReply[item.id, default: ""] += fragment
                        case .activity(let activity):
                            self.liveActivity[item.id] = activity
                        case .accepted, .progress:
                            break
                        }
                    }
                }
                interval = reader.seq > before ? 500 : min(interval * 2, 5000)
                finished = stream.finished
            } catch {
                // 网络抖一下不算断：loom 连错 3 次才翻脸，这里给 6 次。
                netFails += 1
                if netFails >= 6 { break }
                interval = min(interval * 2, 5000)
            }
        }

        // 同一间房又开口了：气泡归新那句，这里一个字都不动。
        if Task.isCancelled { return }
        liveActivity[item.id] = nil

        let text = partial + reader.text
        // 接到一半人按了停止（接回来的那口气也停得了）。**不追了**：它说到哪儿就是哪儿，
        // 再去历史里认就是把人刚叫停的东西补回来。
        if let streamId = trace.streamId, humanStoppedStreams.contains(streamId) {
            liveReply[item.id] = nil
            if !text.isEmpty { appendBeingReply(text, in: item.id) }
            return
        }
        // 接到一半换了 being。上一个 being 的历史已经够不着了，别去新的那个里瞎认——
        // 收到的那半截照旧摆着（它确实说了），那句标成没答完，人自己决定要不要再问。
        guard connectionKey == key else {
            liveReply[item.id] = nil
            if !text.isEmpty { appendBeingReply(text, in: item.id) }
            if let bubbleID {
                rooms.markUnanswered(bubbleID, in: item.id)
                rooms.save()
            }
            noteInRoom(item.id, text: "回复接到一半换了连接，这句没答完。要接着问就点「再问一次」。")
            return
        }
        if finished {
            liveReply[item.id] = nil
            if !text.isEmpty {
                appendBeingReply(text, in: item.id)
            } else {
                noteInRoom(item.id, text: "没接住\(beingName)的回复。你那句已经送到了，不用重发。")
            }
            return
        }

        // 没等到收尾。已经流进来的半截先摆着，找的这段时间人看得见它说到哪儿了；
        // 键不撤（空串也算），单子那一行才一直是「在答」，不会先亮一下「答完了」。
        liveReply[item.id] = text
        let found = await catchUpQueuedReply(
            asked,
            scene: scene(for: item.id),
            roomKey: item.id,
            resuming: true
        )
        liveReply[item.id] = nil
        if Task.isCancelled { return }
        if !found.replies.isEmpty { return } // 历史里那份是完整的，已经一条条记进房间了

        if !text.isEmpty { appendBeingReply(text, in: item.id) }
        if found.lostTrack {
            // 翻不到历史 / 服务端不分房间：说不清它答没答。
            noteInRoom(item.id, text: text.isEmpty
                ? "没接住\(beingName)的回复。你那句已经送到了，不用重发。"
                : "上面这段可能没收全，完整的在 loom 里。")
            return
        }
        if let bubbleID {
            rooms.markUnanswered(bubbleID, in: item.id)
            rooms.save()
        }
        noteInRoom(item.id, text: "\(beingNameLeading)这次没答完：回复半路断了，它那边也没留下这句的回复。点你那句下面的「再问一次」——不问的话，它可能会在别的房间里答这句。")
    }

    private func appendBeingReply(_ text: String, in itemID: String) {
        rooms.append(KairosRoomMessage(
            itemID: itemID,
            origin: KairosMessageOrigin.being,
            weight: KairosMessageWeight.routine,
            text: text,
            delivered: true
        ))
        rooms.save()
    }

    /// 只给这台机器自己看的一行灰字。`delivered: true` 是要紧的：房间里没送达的
    /// app 消息会被 `flushOutbox` 补发给 being——这行字不是说给它听的。
    private func noteInRoom(_ itemID: String, text: String) {
        rooms.append(KairosRoomMessage(
            itemID: itemID,
            origin: KairosMessageOrigin.app,
            weight: KairosMessageWeight.routine,
            text: text,
            delivered: true
        ))
        rooms.save()
    }

    /// 没发出去的原因记在哪儿。有房间就记在**那间**房（`sendErrors`），由它自己在输入框上面画——
    /// 不是此刻开着的那间；连房间都没有的那几句（nudge）没地方画，才弹一下。
    private func noteSendFailure(_ reason: String, in roomKey: String?) {
        if let roomKey {
            sendErrors[roomKey] = reason
        } else {
            notice = "发送失败：\(reason)"
        }
    }

    /// 没发出去的那句再发一次：先把旧气泡撤掉，再当成新的一句说——也就是重新排进队里
    /// （`speak` 会画一条新的「排队中」气泡）。还在排队的那句不用重发，它本来就要发。
    ///
    /// 「没答完」的那句（`unanswered`）也走这里：话它听到过，但没留下回复，再问一次。
    func resend(_ message: KairosRoomMessage, in item: KairosItem) async {
        guard message.origin == KairosMessageOrigin.user,
              !message.delivered || message.unanswered,
              !message.queued else { return }
        rooms.remove(message.id, in: item.id)
        rooms.save()
        // 人已经在处理了，上一次的原因收起来；这次再发不出去会重新写上。
        sendErrors[item.id] = nil
        _ = await speak(message.text, in: item)
    }

    /// 把一条待办交给 being。**一句人话，仅此而已**——全文、状态、入场券它自己去账本读，
    /// 不由 app 推给它；在哪一条上说话由门牌交代，不用在句子里贴 `kairos:item/<id>`。
    func delegate(_ item: KairosItem, note: String = "") async -> BeingReply? {
        let title = item.title.isEmpty ? item.id : item.title
        let extra = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentence = extra.isEmpty
            ? "把「\(title)」交给你。"
            : "把「\(title)」交给你：\(extra)。"
        return await speak(sentence, in: item)
    }

    /// Records a best-effort tentacle handle captured from a `tool_result` event. Purely
    /// informational bookkeeping — deliberately bypasses `saveDraft` so it never looks
    /// like a user edit（不盖 human 戳）.
    private func setTentacleID(_ tentacleId: String, for itemID: String) {
        var next = snapshot
        guard let index = next.items.firstIndex(where: { $0.id == itemID }) else { return }
        next.items[index].tentacleId = tentacleId
        try? commit(next)
    }

    /// Asks Being to check in on a previously-captured tentacle, in that item's own room.
    func checkTentacleProgress(for item: KairosItem) async -> BeingReply? {
        guard let tentacleId = item.tentacleId else { return nil }
        return await speak("看一下触手 \(tentacleId) 现在的 checkpoint 进展", in: item)
    }

    func updateConnection(_ value: KairosConnection) throws {
        let normalized = KairosConnection.normalized(value)
        try normalized.save()
        connection = normalized
        // 各房间挂着的原因说的是上一个连接（「还没接入」、旧地址连不上），换了就不成立了。
        // 没发出去的气泡照旧挂着重发；再失败会写上新的原因。
        sendErrors.removeAll()
        syncBeingRulesDeliveryState()
        connectionState = .checking
        Task { await checkBeing() }
    }

    /// 断开 being：删连接配置（API/token），回到单机。
    /// 账本、待办、邮件、草稿都不动——重新填上链接即恢复，数据不会因为断开而丢。
    func disconnectBeing() {
        guard connection != nil else { return }
        try? FileManager.default.removeItem(at: KairosFiles.connection)
        connection = nil
        connectionState = .notConfigured
        syncBeingRulesDeliveryState()
    }

    // MARK: - BEING-RULES 递送（首启约定）

    private static let beingRulesDeskRoom = "being-rules"

    /// 规则请求最近一次没发出去的原因。那间房没有页面，就画在设置里发请求的那一块——
    /// 以前它走全局 `sendError`，红字落在主窗口此刻开着的那条待办底下。
    var beingRulesSendError: String? { sendErrors[Self.beingRulesDeskRoom] }

    private func beingRulesDefaultsKey(_ prefix: String) -> String? {
        guard let id = connectionKey else { return nil }
        return "\(prefix).\(id)"
    }

    private func syncBeingRulesDeliveryState() {
        beingRulesRequestedAt = readBeingRulesStamp(prefix: "rulesRequestedAt")
        beingRulesDeliveredAt = readBeingRulesStamp(prefix: "rulesDeliveredAt")
    }

    private func readBeingRulesStamp(prefix: String) -> Date? {
        guard let key = beingRulesDefaultsKey(prefix),
              let interval = UserDefaults.standard.object(forKey: key) as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    private func writeBeingRulesStamp(prefix: String, date: Date) {
        guard let key = beingRulesDefaultsKey(prefix) else { return }
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: key)
        syncBeingRulesDeliveryState()
    }

    /// 规则全文到了才算「已收下」：光提 `BEING-RULES` 五个字不算——being 随口一提就会误记成已送达。
    /// 形状要求：提到 BEING-RULES + 带 markdown 大标题 + 有全文的体量（≥500 字）。
    private func noteBeingRulesDelivery(in text: String) {
        guard beingRulesDeliveredAt == nil else { return }
        // 指针模式：being 读完账本里的文件，按 requestBeingRules 的约定回确认短语。
        if text.contains("[BEING-RULES 已读]") {
            writeBeingRulesStamp(prefix: "rulesDeliveredAt", date: Date())
            return
        }
        // 全文模式（回退 / 老 being）：提到 BEING-RULES + 带 markdown 大标题 + 有全文的体量。
        guard text.localizedCaseInsensitiveContains("BEING-RULES") else { return }
        guard text.count >= 500 else { return }
        guard text.contains("\n# ") || text.hasPrefix("# ") else { return }
        writeBeingRulesStamp(prefix: "rulesDeliveredAt", date: Date())
    }

/// 把 app 内置的 BEING-RULES.md 落到账本文件夹。每次请求都覆盖，保证是当前 app 版本带的规则。
@discardableResult
func ensureRulesFileInLedger() -> URL? {
    guard let bundled = Bundle.main.url(forResource: "BEING-RULES", withExtension: "md"),
          let text = try? String(contentsOf: bundled, encoding: .utf8) else { return nil }
    let target = KairosFiles.dataDirectory.appendingPathComponent("BEING-RULES.md")
    do {
        try text.write(to: target, atomically: true, encoding: .utf8)
        return target
    } catch { return nil }
}

/// 向 being 房间发规则请求。v2.5.6 起走指针模式：规则文档落在账本文件夹，
/// 请 being 自己去读——聊天里只过一句话，不把全文灌进对话。
func requestBeingRules() async {
    guard connection != nil else { return }
    let prompt: String
    if let rulesURL = ensureRulesFileInLedger() {
        prompt = "Kairos 是你的工作台账。规则文档在账本文件夹：\(rulesURL.path)，读了按它来，读完回一句带「[BEING-RULES 已读]」的确认。"
    } else {
        // 账本文件夹写不进（少见）——回退全文模式。
        prompt = "请把你的 BEING-RULES 全文发到这个房间，一次就够。"
    }
    _ = await speak(prompt, in: nil, deskRoom: Self.beingRulesDeskRoom)
    writeBeingRulesStamp(prefix: "rulesRequestedAt", date: Date())
}

    func loadSnapshot() {
        // 升级路径：老版本把账本写死在 iCloud 那个文件夹，指针文件还不存在。
        // 这一步只做一次，把当时那个位置**显式**记下来——不记的话 being 的 CLI 只能靠
        // 同一条兜底去猜，两侧就多了一处会分叉的地方。
        KairosLedgerLocation.adoptLegacyLocationIfNeeded()
        do {
#if !os(macOS)
            // 单写入者（v2.3 §五）：手机只从 iCloud 读账本，绝不写回。
            // iCloud 跨设备时文件锁失效，两台设备各自持锁写同一个账本等于没锁。
            if sharedFolder.isConfigured, let cloud = mergedWithOwnOutbox() {
                guard cloud.isSupportedProtocol else {
                    throw CocoaError(.coderInvalidValue)
                }
                apply(cloud)
                return
            }
#endif
            // 迁移：旧本地快照 ~/.kairos/projection-snapshot.json → 当前账本位置。
            // v2.4 起单机模式下这两个路径**就是同一个文件**，那时什么都不用做——
            // 不判断的话是拿一个文件 move 到它自己身上。
            let legacyLocalSnapshot = KairosFiles.configDirectory.appendingPathComponent("projection-snapshot.json")
            if legacyLocalSnapshot.standardizedFileURL != KairosFiles.snapshot.standardizedFileURL,
               !FileManager.default.fileExists(atPath: KairosFiles.snapshot.path),
               FileManager.default.fileExists(atPath: legacyLocalSnapshot.path) {
                try? FileManager.default.createDirectory(at: KairosFiles.dataDirectory, withIntermediateDirectories: true)
                try? FileManager.default.moveItem(at: legacyLocalSnapshot, to: KairosFiles.snapshot)
            }

            if FileManager.default.fileExists(atPath: KairosFiles.snapshot.path) {
                // dataless 占位符也算 fileExists，所以先确保它真的落了地，
                // 否则下面这行会抛 EAGAIN，被 catch 当成账本损坏。
                guard KairosFiles.materialize(KairosFiles.snapshot, timeout: 10) else {
                    throw KairosFiles.LedgerReadError.notMaterialized
                }
                let data = try Data(contentsOf: KairosFiles.snapshot)
                var loaded = try JSONDecoder().decode(KairosSnapshot.self, from: data)
                guard loaded.isSupportedProtocol else {
                    throw CocoaError(.coderInvalidValue)
                }
                let needsProtocolMigration = loaded.protocolName != KairosSnapshot.protocolV3
                let oldWorkspace = loaded.workspace
                loaded.items = loaded.items.map(normalizeRevisions)
                loaded = loaded.migratedToMergedStatus()
                loaded = KairosWorkspaceEngine.normalized(loaded)
                if needsProtocolMigration || loaded.workspace != oldWorkspace {
                    try persist(loaded)
                }
                snapshot = loaded
                if !projects.contains(where: { $0.id == selectedProjectID }) {
                    selectedProjectID = loaded.workspace.projects.first(where: { !$0.archived })?.id
                        ?? KairosWorkspace.defaultProjectID
                }
                return
            }

            if let legacyProjection = KairosFiles.legacyProjection,
               FileManager.default.fileExists(atPath: legacyProjection.path) {
                let data = try Data(contentsOf: legacyProjection)
                var migrated = try JSONDecoder().decode(KairosSnapshot.self, from: data)
                migrated.protocolName = KairosSnapshot.protocolV1
                migrated.updatedAt = KairosClock.now
                migrated.sync = KairosSyncMetadata(lastSyncAt: nil)
                migrated.items = migrated.items.map {
                    var item = $0
                    item.localRev = 0
                    item.syncedLocalRev = 0
                    item.beingRev = max(item.beingRev, 0)
                    item.remoteKnown = true
                    return item
                }
                migrated.tombstones = []
                migrated.conflicts = []
                migrated = migrated.migratedToMergedStatus()
                migrated = KairosWorkspaceEngine.normalized(migrated)
                try persist(migrated)
                snapshot = migrated
                return
            }

            try persist(snapshot)
        } catch KairosFiles.LedgerReadError.notMaterialized {
            // 文件在云上没下来 ≠ 账本坏了。**绝不能因此进写保护**——那会让用户
            // 打开应用只看到「无法读取」且从此不能写，而真相只是等 iCloud 拉一下。
            notice = "账本还在 iCloud 云端，正在拉取…"
            scheduleLedgerRetry()
        } catch {
            writeBlockedReason = error.localizedDescription
            notice = "账本无法读取；为防止覆盖，已经进入写保护"
        }
    }



    private func normalizeRevisions(_ item: KairosItem) -> KairosItem {
        var next = item
        next.localRev = max(item.localRev, 0)
        next.syncedLocalRev = min(next.localRev, max(item.syncedLocalRev, 0))
        next.beingRev = max(item.beingRev, 0)
        return next
    }

    /// 规则 1（锁全程）+ 规则 2（盖戳）的落点。
    ///
    /// 调用方一路都是「拷一份 snapshot、改、commit」，它手上那份在拿到锁的一瞬间
    /// 可能已经过期（being 心跳刚写过账本）。所以这里不直接把它写下去：
    /// 持锁 → 重读盘上最新 → 把调用方那段改动 rebase 上去 → 原子写 → 放锁。
    /// - Parameter createOnly: 这几条**只在账本里还没有的时候才算数**（眼下只有手机把信
    ///   并成消息行时用）。机械并出来的行，我们手里这份账本可能比真账本旧：Mac 那边
    ///   可能已经按更新的一封信建过、也更新过这一行了。把旧值并回去还会盖 human 戳
    ///   （`KairosOutboxEntry.merged`），等于替人把这几个字段对 being 锁死。
    ///   记成「改过的字段是空集」正好表达这件事：账本里没有就整条建出来，已经有了就跳过。
    func commit(_ value: KairosSnapshot, edit: KairosItemEdit = .edited, createOnly: Set<String> = []) throws {
        if let writeBlockedReason {
            throw NSError(
                domain: "KairosSnapshot",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(writeBlockedReason)；为防止覆盖，已拒绝写入"]
            )
        }
        let base = snapshot
        var staged = value
        staged.protocolName = KairosSnapshot.protocolV2
        staged.updatedAt = KairosClock.now
        staged = KairosWorkspaceEngine.normalized(staged)
        stampHumanWriters(&staged, base: base, edit: edit)

#if os(macOS)
        // Mac 是账本的写入者。
        let committed = try KairosFiles.withLedgerTransaction(purpose: "kairos-app") { disk in
            guard let disk else { return staged }
            let drained = KairosOutboxDrain.draining(disk, outboxes: pendingOutboxes())
            return KairosLedgerMerge.rebase(staged, base: base, onto: drained)
        }
        snapshot = committed ?? staged
#else
        // 手机不写账本，只写自己的 outbox——那个文件除了它没有第二个写者，
        // 所以 iCloud 那套「后写的整份盖掉先写的」伤不到它。
        recordToOutbox(staged, base: base, createOnly: createOnly)
        try KairosFiles.writeSnapshotUnlocked(staged) // 本机留一份，断网也能看
        snapshot = staged
#endif
    }

#if os(macOS)
    /// 把手机等设备的 outbox 并进账本。锁内做，和别的写一样受规则 1 约束。
    func drainDeviceOutboxes() {
        let outboxes = pendingOutboxes()
        guard !outboxes.isEmpty else { return }
        do {
            let committed = try KairosFiles.withLedgerTransaction(purpose: "drain outbox") { disk in
                guard let disk else { return nil }
                let drained = KairosOutboxDrain.draining(disk, outboxes: outboxes)
                return drained == disk ? nil : drained
            }
            if let committed, committed != snapshot { apply(committed) }
        } catch {
            notice = "并入手机改动失败：\(error.localizedDescription)"
        }
    }

    private func pendingOutboxes() -> [KairosOutbox] {
        KairosOutboxDrain.load(
            from: KairosFiles.dataDirectory.appendingPathComponent("outbox", isDirectory: true),
            excluding: KairosDevice.id
        )
    }
#else
    /// 把这一版和上一版的差记进自己的 outbox。同一条只留最后一版。
    private func recordToOutbox(_ staged: KairosSnapshot, base: KairosSnapshot, createOnly: Set<String> = []) {
        // 没接 iCloud（手机默认单机）：改动只留本机，没有 outbox 可写，也不该弹提示。
        guard sharedFolder.isConfigured else { return }
        var outbox = sharedFolder.readOutbox(deviceID: KairosDevice.id)
            ?? KairosOutbox(deviceID: KairosDevice.id, deviceName: KairosDevice.name)
        let before = Dictionary(uniqueKeysWithValues: base.items.map { ($0.id, $0) })
        let after = Dictionary(uniqueKeysWithValues: staged.items.map { ($0.id, $0) })

        for item in staged.items {
            guard let original = before[item.id] else {
                // 新建：整条都是新的。`createOnly` 那几条例外，见 `commit` 的参数说明。
                outbox.record(item, op: "upsert", changed: createOnly.contains(item.id) ? [] : KairosField.business)
                continue
            }
            let changed = KairosField.changed(from: original, to: item)
            // 只动了 rev / 房间号 / 锁标记之类的元数据：账本上没有对应的字段可并，别记。
            guard !changed.isEmpty else { continue }
            outbox.record(item, op: "upsert", changed: changed)
        }
        for item in base.items where after[item.id] == nil {
            outbox.record(item, op: "delete", changed: [])
        }
        guard sharedFolder.writeOutbox(outbox) else {
            notice = "改动已存在本机，但还没写进 iCloud——回到有网的地方会自动补上"
            return
        }
    }
#endif

    /// 规则 2：字段级 last_writer。
    ///
    /// 边界按 v2.3 §五：**新建时填的初值不算「手动改」**——用户建待办时选的状态/优先级
    /// 只是初值，being 例行推进（改状态、排序）可以覆盖；只有新建**之后**用户显式改的
    /// 那一下才盖 human，从那一刻起 being 盖不动。所以盘上没有的条目一律走 `.created`
    /// 不盖戳，已有的才按 `edit` 盖，而且只盖真正变了的字段。
    private func stampHumanWriters(
        _ value: inout KairosSnapshot,
        base: KairosSnapshot,
        edit: KairosItemEdit
    ) {
        let before = Dictionary(uniqueKeysWithValues: base.items.map { ($0.id, $0) })
        for index in value.items.indices {
            let item = value.items[index]
            let original = before[item.id]
            let mode: KairosItemEdit = original == nil ? .created : edit
            value.items[index] = mode.stamped(item, from: original)
        }
    }

    /// 新的用户信号 → 解开这条待办的人类锁（规则 2 后半句）。
    /// 人在这条待办的房间里说了话、下了指令，就等于授权 being 重新算这些字段。
    /// Node 侧对应 `releaseHumanLocks`。
    private func releaseHumanLocks(for itemID: String) {
        guard let index = snapshot.items.firstIndex(where: { $0.id == itemID }),
              !snapshot.items[index].lastWriter.isEmpty else { return }
        var next = snapshot
        next.items[index].lastWriter = [:]
        try? commit(next)
    }

    private func persist(_ value: KairosSnapshot) throws {
        try KairosFiles.writeSnapshotUnlocked(value)
    }

    private func registerWorkspaceUndo(_ workspace: KairosWorkspace, actionName: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            Task { @MainActor in target.restoreWorkspace(workspace, actionName: actionName) }
        }
        undoManager?.setActionName(actionName)
    }

    private func restoreWorkspace(_ workspace: KairosWorkspace, actionName: String) {
        let current = snapshot.workspace
        var next = snapshot
        next.workspace = workspace
        do {
            try commit(next)
            registerWorkspaceUndo(current, actionName: actionName)
            if !projects.contains(where: { $0.id == selectedProjectID }) {
                selectedProjectID = projects.first?.id ?? KairosWorkspace.defaultProjectID
                clearSelection()
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    private func registerStatusUndo(
        _ statuses: [String: String],
        workspace: KairosWorkspace,
        actionName: String
    ) {
        undoManager?.registerUndo(withTarget: self) { target in
            Task { @MainActor in
                target.restoreStatuses(statuses, workspace: workspace, actionName: actionName)
            }
        }
        undoManager?.setActionName(actionName)
    }

    private func restoreStatuses(
        _ statuses: [String: String],
        workspace: KairosWorkspace,
        actionName: String
    ) {
        let currentStatuses = Dictionary(uniqueKeysWithValues: snapshot.items
            .filter { statuses[$0.id] != nil }
            .map { ($0.id, $0.status) })
        let currentWorkspace = snapshot.workspace
        var next = snapshot
        next.workspace = workspace
        for index in next.items.indices {
            guard let status = statuses[next.items[index].id], next.items[index].status != status else { continue }
            next.items[index].status = status
            next.items[index].localRev += 1
            next.items[index].updatedAt = KairosClock.now
            if let conflictIndex = next.conflicts.firstIndex(where: { $0.id == next.items[index].id }) {
                next.conflicts[conflictIndex].local = next.items[index].payload
            }
        }
        do {
            try commit(next)
            registerStatusUndo(currentStatuses, workspace: currentWorkspace, actionName: actionName)
        } catch {
            notice = error.localizedDescription
        }
    }

}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

private extension Character {
    /// 拉丁字母或数字。中日韩字符、标点都不算。
    var isLatinish: Bool { isASCII && (isLetter || isNumber) }
}
