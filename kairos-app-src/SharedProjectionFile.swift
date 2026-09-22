import Foundation

/// 手机怎么够到 iCloud 上的 Kairos 目录。
///
/// 2026-09-07 从「选一个文件」改成「选整个 Kairos 文件夹」——因为手机现在要写东西了：
/// 它读账本 `projection-snapshot.json`，写自己的 `outbox/<设备id>.json`。
/// 只给一个文件的书签是够不到同目录下别的文件的。
///
/// 铁律没变，只是换了说法：**手机绝不写账本本身**。它只写自己那个 outbox 文件，
/// 那个文件除了它没有第二个写者，所以 iCloud 那套「后写的整份盖掉先写的」伤不到它。
struct SharedLedgerFolder {
    private static let bookmarkKey = "kairos.sharedLedgerFolderBookmark"
    private let defaults = UserDefaults.standard

    var isConfigured: Bool { defaults.data(forKey: Self.bookmarkKey) != nil }
    var displayName: String? { resolve()?.lastPathComponent }

    func adopt(_ url: URL) throws {
        // 换文件夹前先把旧文件夹里这台设备的改动和草稿拿出来——2026-09-08 人类选的是手机本地的
        // 同名文件夹，改动全写在那里；重选 iCloud 那个的时候这些不能丢。
        let device = KairosDevice.id
        let carriedOutbox = readOutbox(deviceID: device)

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        defaults.set(try url.bookmarkData(), forKey: Self.bookmarkKey)

        // 新文件夹里这台设备还没有 outbox 才搬；有的话说明以前用过这个文件夹，以它为准。
        if let carriedOutbox, !carriedOutbox.entries.isEmpty, readOutbox(deviceID: device) == nil {
            writeOutbox(carriedOutbox)
        }
    }

    func forget() { defaults.removeObject(forKey: Self.bookmarkKey) }

    func resolve() -> URL? {
        guard let bookmark = defaults.data(forKey: Self.bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let refreshed = try? url.bookmarkData() {
            defaults.set(refreshed, forKey: Self.bookmarkKey)
        }
        return url
    }

    /// 在文件夹的安全作用域里做一件事。所有读写都得裹在这里面，否则拿不到权限。
    private func withFolder<T>(_ body: (URL) throws -> T) rethrows -> T? {
        guard let folder = resolve() else { return nil }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        return try body(folder)
    }

    // MARK: - 账本（只读）

    /// 本机有一份、但云上已经有更新版本时（状态是 downloaded 而不是 current），iOS 不一定
    /// 会自己去拉——得踢一脚。这次先读本机这份，新版本落地后 CloudLedgerWatcher 会再叫读一次。
    private static func requestLatestVersion(_ url: URL) {
        guard let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ]), values.isUbiquitousItem == true,
        let status = values.ubiquitousItemDownloadingStatus, status != .current else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    func readLedger() -> KairosSnapshot? {
        let result: KairosSnapshot?? = withFolder { folder in
            let url = folder.appendingPathComponent("projection-snapshot.json")
            // 选到的是手机本地的文件夹（撞上的：同名「Kairos」，不在 iCloud 里）——
            // 它永远到不了 Mac，留着只会让改动写进一个没人看的地方。忘掉它，手机当单机用。
            let inCloud = (try? folder.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
            guard inCloud else {
                Self.report(.init(folder: folder, ledger: "missing"))
                forget()
                return nil
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                Self.report(.init(folder: folder, ledger: "missing"))
                return nil
            }
            // iCloud 可能把文件逐出成占位符：先请求下载，读不到就等下次刷新。
            if !KairosFiles.isMaterialized(url) {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                Self.report(.init(folder: folder, ledger: "notDownloaded"))
                return nil
            }
            Self.requestLatestVersion(url)
            var snapshot: KairosSnapshot?
            var failure: String?
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
                do {
                    snapshot = try JSONDecoder()
                        .decode(KairosSnapshot.self, from: Data(contentsOf: readURL))
                        .migratedToMergedStatus()
                } catch {
                    failure = error.localizedDescription
                }
            }
            if let coordinationError { failure = coordinationError.localizedDescription }
            Self.report(.init(
                folder: folder,
                ledger: snapshot == nil ? "unreadable" : (Self.isCurrent(url) ? "current" : "stale"),
                itemCount: snapshot?.items.count,
                error: failure
            ))
            return snapshot
        }
        return result ?? nil
    }

    // MARK: - 诊断：手机到底看没看到 Mac 的账本

    /// 每次读账本都留一份状态在本机（App Support/Kairos/sync-status.json）。
    /// 「我」那一屏拿它说人话；排查时用 devicectl 从手机上拷出来看，不用猜。
    /// 2026-09-08 就是这么发现手机根本没读到账本、一直在看 8 月底的旧副本的。
    struct Status: Codable {
        var folderName: String
        var folderInCloud: Bool
        /// missing / notDownloaded / stale / current / unreadable
        var ledger: String
        var itemCount: Int?
        var error: String?
        var checkedAt: String = KairosClock.now

        init(folder: URL, ledger: String, itemCount: Int? = nil, error: String? = nil) {
            folderName = folder.lastPathComponent
            let values = try? folder.resourceValues(forKeys: [.isUbiquitousItemKey])
            folderInCloud = values?.isUbiquitousItem == true
            self.ledger = ledger
            self.itemCount = itemCount
            self.error = error
        }

        /// 给人看的一句话。
        var line: String {
            if !folderInCloud { return "这个文件夹不在 iCloud 里，Mac 看不到它——重新选 iCloud 云盘里的 Kairos" }
            switch ledger {
            case "missing": return "这个文件夹里没有账本——选的不是 Mac 那个 Kairos 文件夹"
            case "notDownloaded": return "账本还在云上，正在下载…"
            case "stale": return "已连上，正在拿最新版本…"
            case "current": return "已连上，\(itemCount ?? 0) 条事项"
            default: return "账本读不出来：\(error ?? "未知原因")"
            }
        }

        var isHealthy: Bool { folderInCloud && (ledger == "current" || ledger == "stale") }
    }

    static let statusFile = KairosFiles.configDirectory.appendingPathComponent("sync-status.json")

    private static func report(_ status: Status) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(status) else { return }
        try? KairosFiles.writePrivate(data, to: statusFile)
    }

    /// 上次读账本时看到的状态；没读过就是 nil。
    static func lastStatus() -> Status? {
        guard let data = try? Data(contentsOf: statusFile) else { return nil }
        return try? JSONDecoder().decode(Status.self, from: data)
    }

    private static func isCurrent(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true,
              let status = values.ubiquitousItemDownloadingStatus else { return true }
        return status == .current
    }

    // MARK: - 自己的 outbox（唯一有权写的东西）

    private func outboxURL(in folder: URL, deviceID: String) -> URL {
        folder
            .appendingPathComponent("outbox", isDirectory: true)
            .appendingPathComponent("\(deviceID).json")
    }

    func readOutbox(deviceID: String) -> KairosOutbox? {
        withFolder { folder in
            let url = outboxURL(in: folder, deviceID: deviceID)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            if !KairosFiles.isMaterialized(url) {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                return nil
            }
            var outbox: KairosOutbox?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: nil) { readURL in
                guard let data = try? Data(contentsOf: readURL) else { return }
                outbox = try? JSONDecoder().decode(KairosOutbox.self, from: data)
            }
            return outbox
        } ?? nil
    }

    @discardableResult
    func writeOutbox(_ outbox: KairosOutbox) -> Bool {
        (withFolder { folder -> Bool in
            let directory = folder.appendingPathComponent("outbox", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = outboxURL(in: folder, deviceID: outbox.deviceID)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(outbox) else { return false }
            var ok = false
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: nil) { writeURL in
                ok = (try? data.write(to: writeURL, options: .atomic)) != nil
            }
            return ok
        }) ?? false
    }

}
