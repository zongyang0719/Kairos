import Foundation

/// 多端写入（取代旧版「iPhone 只读」）
///
/// 硬约束只有一条：**两台设备不能写同一个文件**——iCloud 不做仲裁，后写的整份盖掉
/// 先写的（8/30 跨设备血统污染就是这么来的）。所以让每台设备写自己的文件：
///
///     Kairos/projection-snapshot.json   账本，只有 Mac / being 写
///     Kairos/outbox/<设备id>.json        只有那台设备写，别人只读
///
/// 手机改完立刻写自己的 outbox，界面上立刻可见；Mac 或 being 醒来时把 outbox 并进账本。
/// 谁也盖不掉谁，不需要跨设备锁。
///
/// 清理不由并入方做（那样又变成两个写者）：并入方只在**账本**里记一个水位
/// `sync.outboxWatermark[设备id] = 已并到第几条`，设备自己读水位、自己删自己的。
struct KairosOutboxEntry: Codable, Hashable, Identifiable {
    /// 单调递增，同一设备内唯一。水位就是拿它比的。
    var seq: Int
    var id: String
    var itemID: String
    /// `upsert`（新建或改字段）/ `delete`
    var op: String
    /// 这次改动之后那条待办的完整业务内容（全量，方便新建）。
    var item: KairosItemPayload?
    /// 这台设备在这条上**真正改过**的业务字段（累计）。并入时只叠这几个字段——
    /// 手机手里那份账本可能是旧的（实测：可能落后好几天），
    /// 整条 payload 盖上去会把 being 后来写的字段一并抹回旧值。
    /// nil = 老格式条目，按 `legacyFields` + 时间先后处理。
    var fields: [String]?
    var createdAt: String

    /// 老格式条目不知道改了什么。老手机界面能改的只有这三样，别的一律不动。
    /// `state` 2026-09-11 并进了 `status`：手机上「了结」按的就是它，
    /// 这里跟着改名，否则人在老手机上勾掉的那一下并回来等于没算数。
    static let legacyFields = ["status", "tier", "title"]

    init(
        seq: Int,
        id: String = UUID().uuidString,
        itemID: String,
        op: String,
        item: KairosItemPayload?,
        fields: [String]? = nil,
        createdAt: String = KairosClock.now
    ) {
        self.seq = seq
        self.id = id
        self.itemID = itemID
        self.op = op
        self.item = item
        self.fields = fields
        self.createdAt = createdAt
    }

    /// 把这条改动叠到账本上已有的那条上。返回 nil = 这条该跳过。
    /// 手机上看自己的改动、Mac / being 并入，用的是同一个函数——两边并出来必须一样。
    func merged(onto current: KairosItem) -> KairosItem? {
        // 手机那份可能还在写 /2 的形状（球权）：并进来之前先折成 /3。
        // Node 侧 `ledger/outbox.js` 的 draining 同一位置调同一个函数——
        // 少这一行，手机上按的「了结」在两侧会并出两个不同的状态。
        guard let payload = item?.migratedToMergedStatus() else { return nil }
        let apply: [String]
        if let fields {
            apply = fields
        } else {
            // 老格式：账本那条要是在这条改动之后又被别人（being）动过，手机那份就是过时的，跳过。
            guard KairosClock.parse(current.updatedAt) <= KairosClock.parse(createdAt) else { return nil }
            apply = Self.legacyFields
        }
        let incoming = payload.item(
            localRev: current.localRev,
            syncedLocalRev: current.syncedLocalRev,
            beingRev: current.beingRev,
            remoteKnown: current.remoteKnown
        )
        var merged = current.applying(apply, from: incoming)
        let changed = KairosField.changed(from: current, to: merged)
        guard !changed.isEmpty else { return nil }
        // 从手机来的也是人改的，照样盖 human 戳——规矩 2 不因为换了设备就不算。
        for field in changed { merged.lastWriter[field] = KairosField.human }
        merged.localRev = current.localRev + 1
        merged.updatedAt = payload.updatedAt.isEmpty ? KairosClock.now : payload.updatedAt
        return merged
    }
}

struct KairosOutbox: Codable, Hashable {
    enum CodingKeys: String, CodingKey {
        case protocolVersion, deviceID, deviceName, updatedAt, entries, lastSeq
    }

    init(deviceID: String, deviceName: String) {
        self.deviceID = deviceID
        self.deviceName = deviceName
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try box.decodeIfPresent(String.self, forKey: .protocolVersion) ?? KairosOutbox.protocolName
        deviceID = try box.decode(String.self, forKey: .deviceID)
        deviceName = try box.decodeIfPresent(String.self, forKey: .deviceName) ?? ""
        updatedAt = try box.decodeIfPresent(String.self, forKey: .updatedAt) ?? KairosClock.now
        entries = try box.decodeIfPresent([KairosOutboxEntry].self, forKey: .entries) ?? []
        lastSeq = try box.decodeIfPresent(Int.self, forKey: .lastSeq) ?? (entries.map(\.seq).max() ?? 0)
    }

    static let protocolName = "kairos.outbox/1"

    var protocolVersion: String = KairosOutbox.protocolName
    var deviceID: String
    var deviceName: String
    var updatedAt: String = KairosClock.now
    var entries: [KairosOutboxEntry] = []
    /// 发过的最大 seq，**只增不减**。不能从 entries 里现算：同一条重记会先删旧的、
    /// 剪枝会把已并入的删掉，现算就会重发一个 ≤ 水位的 seq，那条改动从此永远收不到。
    var lastSeq: Int = 0

    /// 记一次本地改动。同一条待办只留最后一版，改过的字段累计——中间过程没人关心，
    /// 留着只会让并入方重放一串注定被覆盖的写。
    /// `changed`：这次真正变了的业务字段；新建传 `KairosField.business`（整条都是新的）。
    mutating func record(_ item: KairosItem, op: String, changed: [String]) {
        let previous = entries.first { $0.itemID == item.id }
        entries.removeAll { $0.itemID == item.id }
        lastSeq += 1
        var fields: [String]? = nil
        if op != "delete" {
            var union = previous?.fields ?? (previous == nil ? [] : KairosOutboxEntry.legacyFields)
            for field in changed where !union.contains(field) { union.append(field) }
            fields = union
        }
        entries.append(KairosOutboxEntry(
            seq: lastSeq,
            itemID: item.id,
            op: op,
            item: op == "delete" ? nil : item.payload,
            fields: fields
        ))
        updatedAt = KairosClock.now
    }

    /// 账本里的水位说「你到第 N 条为止我都并进去了」，那 N 条就可以删了。
    mutating func prune(appliedThrough watermark: Int) {
        entries.removeAll { $0.seq <= watermark }
    }

    /// 手机上看到的 = 账本 + 自己还没被并进去的改动。
    /// 不这么做的话，你刚改完一刷新就「变回去了」——那才是最气人的。
    func applied(onto snapshot: KairosSnapshot) -> KairosSnapshot {
        var next = snapshot
        for entry in entries.sorted(by: { $0.seq < $1.seq }) {
            switch entry.op {
            case "delete":
                next.items.removeAll { $0.id == entry.itemID }
            default:
                guard let payload = entry.item else { continue }
                if let index = next.items.firstIndex(where: { $0.id == entry.itemID }) {
                    if let merged = entry.merged(onto: next.items[index]) { next.items[index] = merged }
                } else {
                    next.items.append(payload.item(
                        localRev: 1, syncedLocalRev: 0, beingRev: 0, remoteKnown: false
                    ))
                }
            }
        }
        return next
    }
}

/// 这台设备是谁。第一次跑生成一个 UUID 存起来，之后不变。
enum KairosDevice {
    private static let key = "kairos.deviceID"

    static var id: String {
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    static var name: String {
#if os(macOS)
        ProcessInfo.processInfo.hostName
#else
        "iPhone"
#endif
    }
}

/// 账本写入者（Mac / being）把别的设备的 outbox 并进账本。**只在账本锁内调用。**
enum KairosOutboxDrain {
    /// 读 `Kairos/outbox/` 下所有设备的 outbox（跳过自己的——Mac 直接写账本，没有 outbox）。
    static func load(from directory: URL, excluding deviceID: String) -> [KairosOutbox] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(KairosOutbox.self, from: Data(contentsOf: $0)) }
            .filter { $0.deviceID != deviceID }
    }

    /// 并入。水位以下的跳过（已经并过了，重放只会把人后来的改动又盖回去）。
    /// 并完把水位推上去——设备下次读账本看见水位，自己删自己那几条。
    static func draining(_ snapshot: KairosSnapshot, outboxes: [KairosOutbox]) -> KairosSnapshot {
        var next = snapshot
        for outbox in outboxes {
            let watermark = next.sync.outboxWatermark[outbox.deviceID] ?? 0
            let fresh = outbox.entries.filter { $0.seq > watermark }.sorted { $0.seq < $1.seq }
            guard !fresh.isEmpty else { continue }
            for entry in fresh {
                switch entry.op {
                case "delete":
                    next.items.removeAll { $0.id == entry.itemID }
                default:
                    guard let payload = entry.item else { continue }
                    if let index = next.items.firstIndex(where: { $0.id == entry.itemID }) {
                        // 只叠这台设备真正改过的字段；老格式条目比账本旧就跳过。
                        if let merged = entry.merged(onto: next.items[index]) { next.items[index] = merged }
                    } else {
                        next.items.append(payload.item(
                            localRev: 1, syncedLocalRev: 0, beingRev: 0, remoteKnown: false
                        ))
                    }
                }
            }
            next.sync.outboxWatermark[outbox.deviceID] = fresh.map(\.seq).max() ?? watermark
        }
        return next
    }
}
