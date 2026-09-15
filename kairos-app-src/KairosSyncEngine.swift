import Foundation

/// Kairos v2.3 · 冲突裁决
///
/// v1/v2.0 那套 `kairos.sync/1` 对账协议（request / response / results / 信封 / CAS 校验）
/// 在这一版整体下架：账本就是 iCloud 上那一个 json 文件，Kairos 与 Being 读写的是
/// **同一份**，靠规矩 1（锁全程）+ 规矩 2（字段级 last_writer）保证正确性，
/// 没有两份副本要对账，也就没有信封可传。
///
/// 剩下的只有「冲突」这个概念本身——它不再由对账产生，而是 being 判断面自己写进
/// 账本的一条待裁决（房间设计 §四把 conflict 列为 ask 级通知）。这里负责人类
/// 在两边之间选一边。
enum KairosSyncError: LocalizedError {
    case conflictWithoutLocal(String)

    var errorDescription: String? {
        switch self {
        case .conflictWithoutLocal(let id): "\(id) 在本地不存在，无法裁决冲突"
        }
    }
}

enum ConflictChoice {
    case keepLocal
    case useBeing
}

enum KairosSyncEngine {
    static func resolving(
        _ conflictID: String,
        choice: ConflictChoice,
        in snapshot: KairosSnapshot
    ) throws -> KairosSnapshot {
        guard let conflict = snapshot.conflicts.first(where: { $0.id == conflictID }) else {
            return snapshot
        }
        var next = snapshot
        let index = next.items.firstIndex { $0.id == conflictID }

        switch choice {
        case .keepLocal:
            guard let index else { throw KairosSyncError.conflictWithoutLocal(conflictID) }
            next.items[index].beingRev = conflict.remoteBeingRev
            next.items[index].remoteKnown = true
        case .useBeing:
            if conflict.remoteDeleted {
                if let index { next.items.remove(at: index) }
            } else if let remote = conflict.remote {
                let localRev = index.map { next.items[$0].localRev } ?? 0
                var adopted = remote.item(
                    localRev: localRev,
                    syncedLocalRev: localRev,
                    beingRev: conflict.remoteBeingRev,
                    remoteKnown: true
                )
                if let index {
                    adopted.sessionId = next.items[index].sessionId
                    adopted.tentacleId = next.items[index].tentacleId
                }
                // 采纳 being 那一边 = 人明确把这些字段交回给它（规矩 2 的「新的用户信号」），
                // 所以顺手解开人类锁；否则 being 以后再也改不动这条，而这正是人刚同意的事。
                adopted.lastWriter = [:]
                if let index { next.items[index] = adopted } else { next.items.append(adopted) }
            }
            next.tombstones.removeAll { $0.id == conflictID }
        }
        next.conflicts.removeAll { $0.id == conflictID }
        next.updatedAt = KairosClock.now
        return next
    }
}
