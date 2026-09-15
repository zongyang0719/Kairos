import CryptoKit
import Foundation

/// Kairos v2.3 · 账本锁与原子写（Swift 侧）
///
/// 与 Node 侧 `ledger/store.js` 是同一套协议的两个实现，锁同一个文件。任何一侧改了
/// 锁路径映射、锁文件格式或 stale 判定，另一侧必须同步改——两侧算法一旦分叉，
/// 结果不是报错，而是**两个写入者都以为自己独占**，这正是规矩 1 要防的事。
///
/// 关于「flock」：v2.3 §二规矩 1 原文说的是 flock。Node 不带 flock(2) 绑定
/// （要上原生扩展，macOS 也没有 util-linux 的 flock 命令），所以两侧统一改用
/// 「O_CREAT|O_EXCL 独占创建 + 持有者存活检测」这一种都能逐字实现的建议锁。
/// 互斥语义与 flock 相同；差别只在崩溃后需要 stale 判定，见 acquire。
enum KairosLedgerLock {
    struct Holder: Codable {
        var pid: Int32
        var host: String
        var acquiredAt: String
        var purpose: String
    }

    struct Handle {
        let url: URL
        let pid: Int32
    }

    enum LockError: LocalizedError {
        case timeout(String, Int32?, Int)
        case io(String)

        var errorDescription: String? {
            switch self {
            case .timeout(let path, let pid, let seconds):
                "拿不到账本锁（\(path) 被 pid \(pid.map(String.init) ?? "?") 持有，已 \(seconds)s）"
            case .io(let detail):
                "账本锁读写失败：\(detail)"
            }
        }
    }

    static let timeout: TimeInterval = 10
    static let stale: TimeInterval = 30
    static let retry: TimeInterval = 0.05

    /// 目标文件 → 锁文件的确定性映射。**必须与 `ledger/paths.js` 的 `lockPathFor` 逐字一致**：
    /// 绝对路径的 UTF-8 字节做 SHA-256，小写 hex，加 `.lock`，落在 `~/.kairos/locks/`。
    ///
    /// 锁不跟着账本进 iCloud（v2.3 §五）：锁的语义只在本机，让一把陈旧的 .lock 从别的
    /// 设备飘过来，只会白白挡住本机唯一的写入者。
    static func lockURL(for target: URL) -> URL {
        let absolute = target.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(absolute.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return KairosFiles.locksDirectory.appendingPathComponent(digest + ".lock")
    }

    static func acquire(_ target: URL, purpose: String = "") throws -> Handle {
        let url = lockURL(for: target)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let pid = ProcessInfo.processInfo.processIdentifier
        let holder = Holder(
            pid: pid,
            host: ProcessInfo.processInfo.hostName,
            acquiredAt: KairosClock.now,
            purpose: purpose
        )
        let payload = (try? JSONEncoder().encode(holder)) ?? Data()
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            let descriptor = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if descriptor >= 0 {
                payload.withUnsafeBytes { _ = write(descriptor, $0.baseAddress, $0.count) }
                close(descriptor)
                return Handle(url: url, pid: pid)
            }
            guard errno == EEXIST else { throw LockError.io(String(cString: strerror(errno))) }

            let current = readHolder(url)
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else {
                continue // 刚被别人释放，立刻重试
            }
            let age = Date().timeIntervalSince(modified)
            // 持有者死了、或锁太旧（崩溃残留）→ 掰断重来。建议锁必须有这一步，flock 不必。
            if !isAlive(current) || age > stale {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            if Date() > deadline {
                throw LockError.timeout(url.path, current?.pid, Int(age))
            }
            Thread.sleep(forTimeInterval: retry)
        }
    }

    static func release(_ handle: Handle) {
        // 只放自己的锁。锁被掰断后又被别人拿走时，这里不该把别人的锁删掉。
        if let holder = readHolder(handle.url), holder.pid != handle.pid { return }
        try? FileManager.default.removeItem(at: handle.url)
    }

    private static func readHolder(_ url: URL) -> Holder? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Holder.self, from: data)
    }

    private static func isAlive(_ holder: Holder?) -> Bool {
        guard let holder else { return false }
        // 别的机器的进程，本机判不了死活，当活的。
        guard holder.host == ProcessInfo.processInfo.hostName else { return true }
        if kill(holder.pid, 0) == 0 { return true }
        return errno == EPERM // EPERM = 活着但不是我的；ESRCH = 死了
    }
}

/// 规矩 1 的后半段：锁内重读之后怎么合。
///
/// 调用方（UI）编辑时手上拿的是内存副本 `base`，改完得到 `value`；等拿到锁再读盘，
/// 盘上可能已经是 being 心跳写过的 `disk` 了。直接把 `value` 写下去就是「最后写赢」，
/// 正是规矩 1 要防的丢数据。所以以 `disk` 为地基，只把 base→value 这段真正的改动叠上去。
enum KairosLedgerMerge {
    static func rebase(
        _ value: KairosSnapshot,
        base: KairosSnapshot,
        onto disk: KairosSnapshot
    ) -> KairosSnapshot {
        // 盘上和调用方出发时一模一样：没人插队，原样落盘即可。
        guard disk != base else { return value }

        var result = disk
        let baseItems = Dictionary(uniqueKeysWithValues: base.items.map { ($0.id, $0) })
        let valueItems = Dictionary(uniqueKeysWithValues: value.items.map { ($0.id, $0) })

        var merged: [KairosItem] = []
        var seen = Set<String>()

        for diskItem in disk.items {
            seen.insert(diskItem.id)
            guard let edited = valueItems[diskItem.id] else {
                // 调用方删掉了它：只有当它出发时确实见过这一条，才当成「人删的」。
                // 没见过说明是 being 刚加的，留着。
                if baseItems[diskItem.id] != nil { continue }
                merged.append(diskItem)
                continue
            }
            guard let original = baseItems[diskItem.id] else {
                merged.append(edited)
                continue
            }
            let changed = KairosField.changed(from: original, to: edited)
            if changed.isEmpty {
                // 业务字段没动，但 rev / 房间号这类元数据可能动了。
                var carried = diskItem
                carried.sessionId = edited.sessionId ?? diskItem.sessionId
                carried.tentacleId = edited.tentacleId ?? diskItem.tentacleId
                carried.localRev = max(diskItem.localRev, edited.localRev)
                carried.syncedLocalRev = max(diskItem.syncedLocalRev, edited.syncedLocalRev)
                merged.append(carried)
                continue
            }
            var rebased = diskItem.applying(changed, from: edited)
            rebased.sessionId = edited.sessionId ?? diskItem.sessionId
            rebased.tentacleId = edited.tentacleId ?? diskItem.tentacleId
            rebased.localRev = max(diskItem.localRev, edited.localRev)
            rebased.syncedLocalRev = min(rebased.localRev, max(diskItem.syncedLocalRev, edited.syncedLocalRev))
            rebased.updatedAt = KairosClock.now
            merged.append(rebased)
        }
        // 调用方新建的（盘上还没有）。
        for item in value.items where !seen.contains(item.id) && baseItems[item.id] == nil {
            merged.append(item)
        }
        result.items = merged

        // 其余各段：调用方动过就用它的，没动过就留盘上的。这几段本来就只有 Kairos 自己写。
        if value.workspace != base.workspace { result.workspace = value.workspace }
        if value.seeds != base.seeds { result.seeds = value.seeds }
        if value.tombstones != base.tombstones { result.tombstones = value.tombstones }
        if value.conflicts != base.conflicts { result.conflicts = value.conflicts }
        if value.being != base.being { result.being = value.being }
        if value.sync != base.sync { result.sync = value.sync }
        return result
    }
}
