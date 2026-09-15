import Foundation

/// 邮箱在盘上的落点。纯逻辑（模型、组装、已读判断）在 `KairosMail.swift`——
/// 那一半不碰文件，所以能单独编译进 `tests/native-mail/main.swift` 里验。

enum KairosMailFiles {
    static let mailboxName = "mailbox.json"
    static let outboxFolderName = "mail-outbox"

    /// 已读游标：纯本机派生文件，不跟着账本走。
    /// `configDirectory` 两个平台各自对：macOS 是 `~/.kairos`，iOS 是 App Support/Kairos
    /// （不放「文稿」——「文件」App 里只该看见账本和信，不该看见一堆内部游标）。
    static let readCursor = KairosFiles.configDirectory.appendingPathComponent("mail-read.json")

    static func outboxFile(in folder: URL, deviceID: String) -> URL {
        folder
            .appendingPathComponent(outboxFolderName, isDirectory: true)
            .appendingPathComponent("\(deviceID).json")
    }
}

enum KairosMailSendError: LocalizedError {
    case empty
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .empty: "收件人和内容都得写。"
        case .writeFailed: "信没写下来，再试一次。"
        }
    }
}

/// 邮箱的读写。**和账本住同一个目录，走同一条规则**（手机改单机之后）：
///
///   macOS  `KairosFiles.dataDirectory` = iCloud 的 Kairos 文件夹
///   iOS    `KairosFiles.dataDirectory` = App 的「文稿」目录
///          （文件 App → 我的 iPhone → Kairos，和 projection-snapshot.json 并排）
///
/// 谁要是还连着一个共享文件夹（iCloud / 网盘），优先用那个——和账本的取舍逐字相同，
/// 免得出现「待办从共享文件夹读、信从本机读」这种一半一半的状态。
///
/// 之前这里是 `#if os(macOS)` 走本地、否则**只**走 `SharedLedgerFolder`。手机改单机、
/// 界面不再露出选文件夹之后，那条分支等于把邮箱永久锁死：书签一辈子配不上，
/// 于是 Inbox 永远是「还没接通」，信也永远写不下去。
struct KairosMailStorage {
    private let sharedFolder = SharedLedgerFolder()

    private static let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return value
    }()

    /// 共享文件夹优先，没有就用本机那个目录。账本怎么选，这里就怎么选。
    private var folder: URL? {
        if sharedFolder.isConfigured, let shared = sharedFolder.resolve() { return shared }
        return KairosFiles.dataDirectory
    }

    private var usesSharedFolder: Bool { sharedFolder.isConfigured }

    /// 这台设备是不是 `mailbox.json` 的写者。
    ///
    /// 规矩没变，还是「每个文件一个写者」，只是写者随部署形态换人：
    ///   · 连着共享文件夹（Mac / iCloud / 网盘）→ 写者是 being （走 `ledger/cli.js mail-sync`），
    ///     这边只读，绝不去动那个文件；
    ///   · 手机单机 → being 够不着这个沙盒，写者只能是**我们自己**：跑完一趟邮局，
    ///     把 being 带回来的东西合进本机这份。
    var ownsMailbox: Bool {
#if os(macOS)
        // Mac 上账本旁边那份 mailbox.json 的写者是 being （`ledger/cli.js mail-sync` / `mail-receipt`），
        // Kairos 只读镜像、只写自己的草稿箱。这里以前算成 `!usesSharedFolder`——Mac 没有
        // 书签，算出来是 true，Mac 就会自己跑一趟邮局再写这个文件：两个写者。
        false
#else
        !usesSharedFolder
#endif
    }

    // MARK: 镜像（只读——写者永远是 being）

    func readMailbox() -> KairosMailbox? {
        if usesSharedFolder { return sharedFolder.readMailbox() }
        let url = KairosFiles.dataDirectory.appendingPathComponent(KairosMailFiles.mailboxName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // **先读，读不到再当它在云上。** iCloud 上的文件可能被逐出成占位符（读会抛 EAGAIN），
        // 但反过来先问元数据靠不住：进程刚起来时 iCloud 的元数据还没热，第一次问会答
        // 「没落地」，其实文件好好的在盘上。以前这里先问元数据，答「没落地」就放弃，
        // 而邮箱又没有账本那样的轮询兜底——于是 Mac 一打开 Inbox 永远是「还没接通」。
        guard let data = try? Data(contentsOf: url) else {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return nil
        }
        guard let value = try? JSONDecoder().decode(KairosMailbox.self, from: data),
              value.isSupportedProtocol else { return nil }
        return value
    }

    /// 只在 `ownsMailbox` 为真时可用。共享文件夹里那份是 being 的，我们插手就是两个写者。
    @discardableResult
    func writeMailbox(_ mailbox: KairosMailbox) -> Bool {
        guard ownsMailbox else { return false }
        try? FileManager.default.createDirectory(
            at: KairosFiles.dataDirectory, withIntermediateDirectories: true
        )
        let url = KairosFiles.dataDirectory.appendingPathComponent(KairosMailFiles.mailboxName)
        guard let data = try? Self.encoder.encode(mailbox) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    // MARK: 草稿箱（这台设备是唯一写者）

    func readOutbox() -> KairosMailOutbox? {
        if usesSharedFolder { return sharedFolder.readMailOutbox(deviceID: KairosDevice.id) }
        let url = KairosMailFiles.outboxFile(in: KairosFiles.dataDirectory, deviceID: KairosDevice.id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // 同上：先读，读不到再当它在云上。
        guard let data = try? Data(contentsOf: url) else {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return nil
        }
        return try? JSONDecoder().decode(KairosMailOutbox.self, from: data)
    }

    @discardableResult
    func writeOutbox(_ outbox: KairosMailOutbox) -> Bool {
        if usesSharedFolder { return sharedFolder.writeMailOutbox(outbox) }
        let directory = KairosFiles.dataDirectory
            .appendingPathComponent(KairosMailFiles.outboxFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = KairosMailFiles.outboxFile(in: KairosFiles.dataDirectory, deviceID: outbox.deviceID)
        guard let data = try? Self.encoder.encode(outbox) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}

extension KairosMailReadCursor {
    static func load() -> KairosMailReadCursor {
        guard let data = try? Data(contentsOf: KairosMailFiles.readCursor),
              let value = try? JSONDecoder().decode(KairosMailReadCursor.self, from: data) else {
            return KairosMailReadCursor()
        }
        return value
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return }
        try? KairosFiles.writePrivate(data, to: KairosMailFiles.readCursor)
    }
}
