import Foundation

enum KairosWorkspaceEngine {
    static func normalized(_ input: KairosSnapshot) -> KairosSnapshot {
        var snapshot = input
        var workspace = snapshot.workspace

        workspace.projects = uniqueProjects(workspace.projects)
        if workspace.projects.isEmpty {
            workspace.projects = [.defaultProject]
        }
        if !workspace.projects.contains(where: { !$0.archived }) {
            if let index = workspace.projects.firstIndex(where: { $0.id == KairosWorkspace.defaultProjectID }) {
                workspace.projects[index].archived = false
            } else {
                workspace.projects.insert(.defaultProject, at: 0)
            }
        }

        let projectIDs = Set(workspace.projects.map(\.id))
        let itemIDs = Set(snapshot.items.map(\.id))

        // 这儿原来还给每条事项在 `membership` 里补一个默认项目。那张表已撤
        // ——项目归属只剩事项自己的 `project` 字段（`KairosWorkspace` 上有完整交代）。

        var sidebarSeen = Set<String>()
        workspace.sidebarOrder = workspace.sidebarOrder.filter {
            projectIDs.contains($0) && sidebarSeen.insert($0).inserted
        }
        for project in workspace.projects where !workspace.sidebarOrder.contains(project.id) {
            workspace.sidebarOrder.append(project.id)
        }

        // 手工顺序：先把老键迁过来，再清理。
        //
        // 老键是 `"<项目id>/<段>"`，新键只有 `"<段>"`（见 `KairosWorkspace.orderKey`）。
        // 迁移按老键的字典序来，保证同一份账本每次迁出来的结果一样；同一条只留第一次
        // 出现的位置。迁完老键就扔掉，下次进来这段是空转。
        var migrated = workspace.manualOrder
        let legacy = migrated.keys.filter { KairosWorkspace.isLegacyOrderKey($0) }.sorted()
        for key in legacy {
            let ids = migrated.removeValue(forKey: key) ?? []
            guard let segment = key.split(separator: "/", maxSplits: 1).last.map(String.init) else { continue }
            let target = KairosWorkspace.orderKey(segment: segment)
            var merged = migrated[target] ?? []
            var seen = Set(merged)
            for id in ids where seen.insert(id).inserted { merged.append(id) }
            migrated[target] = merged
        }

        var cleanedOrder: [String: [String]] = [:]
        for (key, ids) in migrated {
            var seen = Set<String>()
            cleanedOrder[key] = ids.filter { id in
                // **不再看 membership**。项目归属现在写在 item.project 上，
                // 而顺序和项目无关——一张单子一个桶，拖到哪儿就是哪儿
                // （原来这里要求 membership 和键里的项目 id 对得上，那是老泳道的遗留）。
                guard itemIDs.contains(id),
                      seen.insert(id).inserted,
                      let item = snapshot.items.first(where: { $0.id == id })
                else { return false }
                return matchesOrderKey(item: item, keySegment: key)
            }
        }
        workspace.manualOrder = cleanedOrder
        snapshot.workspace = workspace
        return snapshot
    }

    /// 顺序键的第二段。**现在只有 `active` 一个**——泳道已撤，
    /// 一张单子就一个桶。别的段留着只为读老账本时不炸，它们匹配不到任何一条，
    /// 下一次 normalized 就清空了。
    private static func matchesOrderKey(item: KairosItem, keySegment: String) -> Bool {
        keySegment == KairosWorkspace.activeOrderKey
            ? !item.isClosed
            : KairosStatus.normalized(item.status) == keySegment
    }

// 往泳道里拖（dropping）已撤：泳道没了，它唯一的调用方
    // `KairosStore.dropItems` 也一并撤了。换项目走 assigning，排顺序走 ordered。

    // `assigning`（把几条事项塞进某个项目）已撤：它唯一做的事就是写
    // `membership`，而那张表和它的两个调用方（KairosStore 的 assignItems /
    // archiveProject）已经一起没了。换项目现在走 `KairosStore.macSetProject`，
    // 直接写事项自己的 `project` 字段。

    static func ordered(_ items: [KairosItem], segment: String, workspace: KairosWorkspace) -> [KairosItem] {
        let key = KairosWorkspace.orderKey(segment: segment)
        let rank = Dictionary(uniqueKeysWithValues: (workspace.manualOrder[key] ?? []).enumerated().map { ($0.element, $0.offset) })
        return items.sorted { left, right in
            switch (rank[left.id], rank[right.id]) {
            case let (l?, r?): l < r
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): false
            }
        }
    }

    private static func uniqueProjects(_ projects: [KairosProject]) -> [KairosProject] {
        var seen = Set<String>()
        return projects.compactMap { project in
            var value = project
            value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.id.isEmpty, !value.name.isEmpty, seen.insert(value.id).inserted else { return nil }
            return value
        }
    }
}
