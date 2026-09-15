import Foundation

/// 账本住在哪儿（v2.4，2026-09-10）。
///
/// ## 为什么要有这一层
///
/// v2.3 把账本定成「iCloud 里那一个 json 文件」，路径在 `KairosFiles` 里写死。
/// 好处是两侧（Kairos / being 的 CLI）不可能指错文件；代价是**没登 iCloud 就没有一条干净的路**，
/// 而且「Mac 和手机各用各的」这件事根本表达不出来——iCloud 从「可选的关联方式」
/// 变成了「用这个 app 的前提」。
///
/// 现在分两种形态，两个平台同一套说法：
///
/// | 形态 | Mac | iPhone |
/// |---|---|---|
/// | **单机**（默认） | `~/.kairos/projection-snapshot.json` | 「文稿」/`projection-snapshot.json`（文件 App 里看得见） |
/// | **关联**（可选） | 指向 iCloud 的 Kairos 文件夹 | 书签指向同一个文件夹 |
///
/// 关联之后规则一个字没变（v2.3 §五 + 2026-09-07 多端写入）：
/// **账本只有 Mac / being 写，手机只读账本、只写自己的 `outbox/<设备>.json`。**
/// 这一层只决定「哪个文件夹」，不改动谁能写什么。
///
/// ## 位置记在哪儿
///
/// Mac：`~/.kairos/ledger-location.json`，**Node 侧 `ledger/paths.js` 读同一个文件**。
/// being 跑 CLI 写的必须和 Kairos 看的是同一份账本——这是 v2.3 §五「没有两份副本」的底线，
/// 换成可选位置之后，这条底线全靠这个指针文件维持。
///
/// iPhone：沙盒里存一个绝对路径没有意义（下次启动就没权限了），所以手机的「关联」
/// 仍然是 `SharedLedgerFolder` 那个安全作用域书签。这里只回答「单机时账本在哪」。
enum KairosLedgerLocation {
    static let ledgerFileName = "projection-snapshot.json"
    static let pointerProtocol = "kairos.ledger-location/1"

    /// 指针文件。Node 侧 `ledger/paths.js` 逐字读同一个路径、同一个字段名。
    struct Pointer: Codable, Equatable {
        var protocolVersion: String = KairosLedgerLocation.pointerProtocol
        /// 账本所在的**文件夹**（不是文件本身）。空字符串 = 单机。
        var folder: String
        var updatedAt: String = KairosClock.now

        enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol"
            case folder
            case updatedAt = "updated_at"
        }

        init(folder: String, updatedAt: String = KairosClock.now) {
            self.folder = folder
            self.updatedAt = updatedAt
        }

        /// 缺字段不能让整份读不出来：读不出 = 回落到单机 = 看不见自己 iCloud 上的账本。
        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            protocolVersion = try box.decodeIfPresent(String.self, forKey: .protocolVersion)
                ?? KairosLedgerLocation.pointerProtocol
            folder = try box.decodeIfPresent(String.self, forKey: .folder) ?? ""
            updatedAt = try box.decodeIfPresent(String.self, forKey: .updatedAt) ?? KairosClock.now
        }
    }

    // MARK: - 三个候选位置

    /// 单机时账本所在的文件夹。
    static var localFolder: URL {
#if os(macOS)
        // 和派生文件同一个家。选它不是图省事：`~/.kairos` **一定不会被任何同步服务
        // 卷进去**（`~/Documents` 在开了「桌面与文稿」同步的 Mac 上其实就是 iCloud），
        // 而「单机」这两个字必须是真的。路径在设置里写明，也能一键在访达里打开。
        KairosFiles.configDirectory
#else
        // 手机上放「文稿」：开了 UIFileSharingEnabled 之后，文件 App → 我的 iPhone →
        // Kairos 里就能看见它。数据在哪、是不是自己的，得让人看得见。
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
#endif
    }

    /// v2.3 那个写死的 iCloud 文件夹。只用来做一件事：**升级时不打断现有的用法**。
    static var legacyCloudFolder: URL? {
#if os(macOS)
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Kairos", isDirectory: true)
#else
        nil
#endif
    }

    static var pointerFile: URL {
        KairosFiles.configDirectory.appendingPathComponent("ledger-location.json")
    }

    // MARK: - 解析（纯函数，好验）

    /// 决定用哪个文件夹。顺序是固定的，两侧（Swift / Node）必须一致：
    ///
    ///   1. 指针文件写了非空的 folder → 就是它（人明确选过的，优先级最高）；
    ///   2. 没有指针，但老的 iCloud 位置上**真有一份账本** → 用它，并写下指针
    ///      （升级路径：人类现在的账本就在那儿，不能因为换了机制就「一夜之间空了」）；
    ///   3. 都没有 → 单机。
    static func resolveFolder(
        pointer: Pointer?,
        cloudFolder: URL?,
        cloudLedgerExists: Bool,
        localFolder local: URL
    ) -> URL {
        if let folder = pointer?.folder, !folder.isEmpty {
            return URL(fileURLWithPath: folder, isDirectory: true)
        }
        if let cloudFolder, cloudLedgerExists { return cloudFolder }
        return local
    }

    static func readPointer() -> Pointer? {
        guard let data = try? Data(contentsOf: pointerFile) else { return nil }
        return try? JSONDecoder().decode(Pointer.self, from: data)
    }

    @discardableResult
    static func writePointer(folder: URL?) -> Bool {
        let pointer = Pointer(folder: folder?.standardizedFileURL.path ?? "")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(pointer) else { return false }
        return (try? KairosFiles.writePrivate(data, to: pointerFile)) != nil
    }

    /// 当前该用的文件夹。**每次读，不缓存**——设置里换完位置，下一次读写就得落到新地方。
    static var folder: URL {
#if os(macOS)
        let cloud = legacyCloudFolder
        let exists = cloud.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(ledgerFileName).path)
        } ?? false
        return resolveFolder(
            pointer: readPointer(),
            cloudFolder: cloud,
            cloudLedgerExists: exists,
            localFolder: localFolder
        )
#else
        // 手机的「关联」走书签（`SharedLedgerFolder`），这里只答单机那一份。
        localFolder
#endif
    }

    static var ledger: URL { folder.appendingPathComponent(ledgerFileName) }

    /// 现在是不是关联着别的文件夹（而不是本机那份）。
    static var isLinked: Bool {
        folder.standardizedFileURL.path != localFolder.standardizedFileURL.path
    }

    /// 升级时把老的 iCloud 位置写成显式指针。
    ///
    /// 不写也能跑（`resolveFolder` 第 2 条会一直兜着），但**指针文件是 Node 侧唯一的
    /// 依据**：不落下来，being 的 CLI 只能靠同一条兜底猜，两侧就多了一处会分叉的地方。
    /// 启动时调一次，幂等。
    static func adoptLegacyLocationIfNeeded() {
#if os(macOS)
        guard readPointer() == nil,
              let cloud = legacyCloudFolder,
              FileManager.default.fileExists(atPath: cloud.appendingPathComponent(ledgerFileName).path)
        else { return }
        writePointer(folder: cloud)
#endif
    }

    // MARK: - 备份（换位置之前，先留一份能回去的东西）

    static var backupsFolder: URL {
        KairosFiles.configDirectory.appendingPathComponent("backups", isDirectory: true)
    }

    /// 把一个文件复制进 `~/.kairos/backups/`，名字带时间戳。
    /// 换位置这种「一步走错要人命」的动作之前必须先做这件事——**账本没有回收站**。
    @discardableResult
    static func backup(_ url: URL, tag: String) -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try? FileManager.default.createDirectory(at: backupsFolder, withIntermediateDirectories: true)
        let stamp = KairosClock.now
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        let target = backupsFolder.appendingPathComponent("\(stamp)-\(tag).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard (try? data.write(to: target, options: .atomic)) != nil else { return nil }
        return target
    }

    // MARK: - 换位置时的读写（不经 `KairosFiles.snapshot`——那个正指着旧位置）

    /// 读某个位置上的账本。读不出来（不存在 / 还在云上 / 坏了）一律回 nil，
    /// 由调用方决定怎么办：换位置这件事上，「读不出来」和「是空的」必须分得开。
    static func readLedger(at url: URL) -> KairosSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard KairosFiles.materialize(url, timeout: 10) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(KairosSnapshot.self, from: data),
              snapshot.isSupportedProtocol else { return nil }
        // 那边那份可能还是 /2：合并之前先折成 /3，否则并出来的东西一半新一半旧。
        return snapshot.migratedToMergedStatus()
    }

    /// 原子写 + 上锁。锁按**目标路径**算（`KairosLedgerLock.lockURL`），所以换位置的这一下
    /// 和 being 的 CLI 抢的是同一把锁——它正在写那个文件的话，我们等它。
    @discardableResult
    static func writeLedger(_ snapshot: KairosSnapshot, to url: URL) -> Bool {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let handle = try? KairosLedgerLock.acquire(url, purpose: "switch ledger location") else {
            return false
        }
        defer { KairosLedgerLock.release(handle) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(snapshot) else { return false }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".projection-snapshot.\(ProcessInfo.processInfo.processIdentifier).tmp"
        )
        guard (try? data.write(to: temporary)) != nil else { return false }
        if FileManager.default.fileExists(atPath: url.path) {
            return (try? FileManager.default.replaceItemAt(url, withItemAt: temporary)) != nil
        }
        return (try? FileManager.default.moveItem(at: temporary, to: url)) != nil
    }
}

// MARK: - 两份账本并成一份

/// 换位置时把两边的账本并起来。
///
/// 和 `KairosLedgerMerge.rebase`（规则 1：拿到锁之后把自己这段改动叠到盘上最新那份）
/// 不是一回事：那个有共同祖先（`base`），知道「这次改了什么」；这里**没有共同祖先**——
/// 两份账本各活各的，只能按 id 并、按时间挑。
///
/// 什么时候会有两份：Mac 单机用了一阵子，手机也单机用了一阵子（各自都有真东西），
/// 然后要接到同一个 iCloud 文件夹上。这时候**任何一边被整份盖掉都是数据丢失**，
/// 所以不做「谁盖谁」，做并集。
///
/// 并的规则只有一条能记住的：**按 id 并，同一条留改得晚的那一版。**
/// 剩下的都是这条的推论。id 是 UUID（或者 being 给的稳定 id），两台独立用的设备撞 id 的
/// 概率可以忽略，所以并集在实践中几乎全是「两边的东西都在」。
enum KairosLedgerUnion {
    struct Report: Equatable {
        /// 对面没有、从这边搬过去的条数。
        var added = 0
        /// 两边都有，留下的是「这边」这一版（它更新）。
        var replaced = 0
        /// 两边都有，留下的是对面那一版（对面更新）。
        var yielded = 0
        /// 因为另一边删得更晚而没有留下的条数。
        var deleted = 0
        /// 顺手带过去的项目数。
        var projects = 0

        var isEmpty: Bool { added == 0 && replaced == 0 && yielded == 0 && deleted == 0 }

        /// 给人看的一句话。**不说「合并成功」这种废话**，说清楚到底发生了什么。
        var line: String {
            if isEmpty { return "两边内容一样，没有需要并的" }
            var parts: [String] = []
            if added > 0 { parts.append("搬过去 \(added) 条") }
            if replaced > 0 { parts.append("\(replaced) 条用了本机较新的一版") }
            if yielded > 0 { parts.append("\(yielded) 条保留了那边较新的一版") }
            if deleted > 0 { parts.append("\(deleted) 条因为另一边删得更晚而没有留下") }
            if projects > 0 { parts.append("带过去 \(projects) 个项目") }
            return parts.joined(separator: "，")
        }
    }

    /// 把 `incoming` 并进 `base`。`base` 是**目标位置那份**（并完写回目标位置）。
    static func union(_ base: KairosSnapshot, _ incoming: KairosSnapshot) -> (KairosSnapshot, Report) {
        var next = base
        var report = Report()

        // 墓碑先并：它决定一条「本来要搬过去的」到底还该不该在。
        var tombstones = Dictionary(uniqueKeysWithValues: base.tombstones.map { ($0.id, $0) })
        for stone in incoming.tombstones {
            if let existing = tombstones[stone.id] {
                if later(stone.deletedAt, than: existing.deletedAt) { tombstones[stone.id] = stone }
            } else {
                tombstones[stone.id] = stone
            }
        }

        var items = Dictionary(uniqueKeysWithValues: base.items.map { ($0.id, $0) })
        for item in incoming.items {
            if let existing = items[item.id] {
                // 两边一模一样：什么都没发生，也就没什么好报的。
                // （不判断的话，「两份账本内容相同」会被报成「N 条保留了那边的版本」，
                // 人看到一串数字会以为刚刚发生了一次真的合并。）
                if existing == item { continue }
                if later(item.updatedAt, than: existing.updatedAt)
                    || (sameInstant(item.updatedAt, existing.updatedAt) && item.localRev > existing.localRev) {
                    items[item.id] = inheriting(item, from: existing)
                    report.replaced += 1
                } else {
                    items[item.id] = inheriting(existing, from: item)
                    report.yielded += 1
                }
            } else {
                items[item.id] = item
                report.added += 1
            }
        }

        // 一边删了、另一边还留着：谁晚听谁的。删得晚 → 真删；改得晚 → 那是删完又复活，
        // 墓碑作废（否则这条会在下一次并的时候又被删掉，人会觉得「它自己消失了」）。
        for (id, stone) in tombstones {
            guard let item = items[id] else { continue }
            if later(stone.deletedAt, than: item.updatedAt) {
                items.removeValue(forKey: id)
                if report.added > 0, base.items.contains(where: { $0.id == id }) == false {
                    report.added -= 1
                }
                report.deleted += 1
            } else {
                tombstones.removeValue(forKey: id)
            }
        }

        next.items = items.values.sorted { $0.id < $1.id }
        next.tombstones = tombstones.values.sorted { $0.id < $1.id }

        // 冲突：并集，同 id 以 base 为准（它已经在目标位置上，正在等人裁决）。
        var conflicts = base.conflicts
        for conflict in incoming.conflicts where !conflicts.contains(where: { $0.id == conflict.id }) {
            conflicts.append(conflict)
        }
        next.conflicts = conflicts

        // 随手记：并集，同 id 以 base 为准。
        var seeds = base.seeds
        for seed in incoming.seeds where !seeds.contains(where: { $0.id == seed.id }) {
            seeds.append(seed)
        }
        next.seeds = seeds

        // 水位取大的：小的那个会让已经并过的 outbox 条目被重放一遍。
        var watermark = base.sync.outboxWatermark
        for (device, seq) in incoming.sync.outboxWatermark {
            watermark[device] = max(watermark[device] ?? 0, seq)
        }
        next.sync.outboxWatermark = watermark

        let (workspace, addedProjects) = mergedWorkspace(base.workspace, incoming.workspace)
        next.workspace = workspace
        report.projects = addedProjects

        if next.being.name.isEmpty { next.being = incoming.being }
        next.protocolName = KairosSnapshot.protocolV2
        next.updatedAt = KairosClock.now
        return (next, report)
    }

    /// 留下的那一版继承对面的**房间号和触手 id**。
    ///
    /// 这两个不是业务字段，是「这条待办和 being 之间那根线」。哪一版更新是按业务改动算的，
    /// 但线不能因为这次并而断——断了那条待办从此在 being 那边找不到自己的房间。
    private static func inheriting(_ winner: KairosItem, from loser: KairosItem) -> KairosItem {
        var next = winner
        if next.sessionId?.isEmpty != false { next.sessionId = loser.sessionId }
        if next.tentacleId?.isEmpty != false { next.tentacleId = loser.tentacleId }
        // 人手改过的字段标记取并集：任何一边说「这是人改的」，那就是人改的——
        // 规则 2 宁可挡住 being 的一次自动写入，也不能把人的决定悄悄交回去。
        for (field, writer) in loser.lastWriter where writer == KairosField.human {
            next.lastWriter[field] = KairosField.human
        }
        return next
    }

    private static func mergedWorkspace(
        _ base: KairosWorkspace,
        _ incoming: KairosWorkspace
    ) -> (KairosWorkspace, Int) {
        var next = base
        var added = 0
        for project in incoming.projects where !next.projects.contains(where: { $0.id == project.id }) {
            next.projects.append(project)
            added += 1
        }
        // 归属那张表（membership）已撤，这里没什么可并的——
        // 项目归属写在事项自己的 `project` 字段上，跟着事项一起并，不是 workspace 的事。
        // 手拖出来的顺序：同一个桶里，对面独有的排在后面——顺序是偏好不是数据，
        // 并错了人重拖一下就行，但**丢了**就得整列重排一遍。
        for (key, order) in incoming.manualOrder {
            var merged = next.manualOrder[key] ?? []
            for id in order where !merged.contains(id) { merged.append(id) }
            next.manualOrder[key] = merged
        }
        for id in incoming.sidebarOrder where !next.sidebarOrder.contains(id) {
            next.sidebarOrder.append(id)
        }
        return (next, added)
    }

    // MARK: - 时间比较

    /// `KairosClock.parse` 自己就把解不出来的当最早（`.distantPast`）——坏时间戳赢不了，
    /// 这正是并集要的：一条时间戳坏掉的记录不该把好的那版顶掉。
    /// 字符串直接比是不行的：Swift 写 `…:45Z`、Node 写 `…:52.181Z`，同一秒内会比反。
    private static func later(_ lhs: String, than rhs: String) -> Bool {
        KairosClock.parse(lhs) > KairosClock.parse(rhs)
    }

    private static func sameInstant(_ lhs: String, _ rhs: String) -> Bool {
        KairosClock.parse(lhs) == KairosClock.parse(rhs)
    }
}
