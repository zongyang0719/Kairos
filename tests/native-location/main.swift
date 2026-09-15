import Foundation

// 账本住在哪儿 · 原生测试（Swift）
// 对应 kairos-app-src/KairosLedgerLocation.swift。
//
// 这套测试守两句话：
//   1. **两侧解析出同一个文件**（Swift 这边的顺序，和 ledger/paths.js 那边逐条对齐）；
//   2. **换位置不丢东西**——两份账本并起来是并集，不是「谁盖谁」。

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("✗ " + message) }
}

/// **这一行必须在碰任何 `KairosFiles` 之前。**
///
/// 下面有几条要真的落文件（指针、备份、换位置的读写）。`KairosFiles.configDirectory`
/// 是 `static let`，第一次用到时才算，算的是 `NSHomeDirectory()`——而 macOS 上
/// `NSHomeDirectory()` **不看 `$HOME`**，只认 `CFFIXED_USER_HOME`。不改它的话，
/// 这套测试会往人类真的 `~/.kairos` 里写东西。
let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("kairos-location-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
try! FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
setenv("CFFIXED_USER_HOME", sandbox.path, 1)
defer { try? FileManager.default.removeItem(at: sandbox) }

let cloud = URL(fileURLWithPath: "/Users/x/Library/Mobile Documents/com~apple~CloudDocs/Kairos", isDirectory: true)
let local = URL(fileURLWithPath: "/Users/x/.kairos", isDirectory: true)

// ── 解析顺序：指针 > 老 iCloud 位置（且真有账本）> 本机 ─────────────────────
do {
    let picked = KairosLedgerLocation.resolveFolder(
        pointer: .init(folder: "/Volumes/Share/Kairos"),
        cloudFolder: cloud,
        cloudLedgerExists: true,
        localFolder: local
    )
    expect(picked.path == "/Volumes/Share/Kairos", "人明确选过的位置优先级最高")

    let legacy = KairosLedgerLocation.resolveFolder(
        pointer: nil, cloudFolder: cloud, cloudLedgerExists: true, localFolder: local
    )
    expect(legacy == cloud, "还没有指针、但老位置上真有一份账本：接着用它，别让人一夜之间空了")

    let standalone = KairosLedgerLocation.resolveFolder(
        pointer: nil, cloudFolder: cloud, cloudLedgerExists: false, localFolder: local
    )
    expect(standalone == local, "什么都没有 = 单机，这是默认，不是异常")

    // 空 folder 不能当成「有指针」——那会解析出一个根目录下的账本。
    let empty = KairosLedgerLocation.resolveFolder(
        pointer: .init(folder: ""), cloudFolder: cloud, cloudLedgerExists: false, localFolder: local
    )
    expect(empty == local, "指针是空的当没有")
}

// ── 指针文件：缺字段不能整份读不出来 ──────────────────────────────────────
//
// 读不出 = 回落到单机 = 一打开发现 iCloud 上那本账「不见了」。这种解码器必须容错。
do {
    let minimal = #"{"folder":"/Volumes/Share/Kairos"}"#.data(using: .utf8)!
    let pointer = try! JSONDecoder().decode(KairosLedgerLocation.Pointer.self, from: minimal)
    expect(pointer.folder == "/Volumes/Share/Kairos", "只有 folder 也要读得出来")
    expect(pointer.protocolVersion == KairosLedgerLocation.pointerProtocol, "缺的字段落默认值")

    let encoded = try! JSONEncoder().encode(KairosLedgerLocation.Pointer(folder: "/a/b"))
    let text = String(data: encoded, encoding: .utf8)!
    // Node 侧读的就是这个字段名（ledger/paths.js 的 readPointerFolder）。
    expect(text.contains("\"folder\""), "字段名是两侧的约定，不能改")
}

// ── 并集：两边的东西都在 ─────────────────────────────────────────────────

func snapshot(_ items: [KairosItem], tombstones: [KairosTombstone] = []) -> KairosSnapshot {
    var value = KairosSnapshot.empty
    value.items = items
    value.tombstones = tombstones
    return value
}

func at(_ stamp: String) -> String { stamp }

do {
    let mac = snapshot([
        KairosItem(id: "a", title: "Mac 上的", updatedAt: at("2026-09-01T10:00:00Z")),
        KairosItem(id: "both", title: "旧标题", updatedAt: at("2026-09-01T10:00:00Z")),
    ])
    let phone = snapshot([
        KairosItem(id: "b", title: "手机上的", updatedAt: at("2026-09-02T10:00:00Z")),
        KairosItem(id: "both", title: "新标题", updatedAt: at("2026-09-03T10:00:00Z")),
    ])

    let (merged, report) = KairosLedgerUnion.union(mac, phone)
    let ids = Set(merged.items.map(\.id))
    expect(ids == ["a", "b", "both"], "两边独有的都在，实际 \(ids.sorted())")
    expect(merged.items.first { $0.id == "both" }?.title == "新标题", "同一条留改得晚的那一版")
    expect(report.added == 1 && report.replaced == 1, "报告说得出到底动了什么，实际 \(report)")
    expect(report.line.contains("搬过去 1 条"), "给人看的一句话，实际「\(report.line)」")
}

// ── 并集：房间号和人手改过的标记不能因为并而丢 ────────────────────────────
//
// 房间号是这条待办和 being 之间那根线，断了它在 being 那边就找不到自己的房间；
// human 标记丢了，等于把人刚做的决定悄悄交回给 being （规矩 2）。
do {
    var older = KairosItem(id: "x", title: "旧", updatedAt: at("2026-09-01T10:00:00Z"))
    older.sessionId = "room-7"
    older.lastWriter = ["tier": KairosField.human]
    var newer = KairosItem(id: "x", title: "新", updatedAt: at("2026-09-05T10:00:00Z"))
    newer.sessionId = nil

    let (merged, _) = KairosLedgerUnion.union(snapshot([older]), snapshot([newer]))
    let survivor = merged.items.first { $0.id == "x" }
    expect(survivor?.title == "新", "业务内容按时间挑")
    expect(survivor?.sessionId == "room-7", "赢的那版没有房间号就继承对面的，线不能断")
    expect(survivor?.lastWriter["tier"] == KairosField.human, "人手改过的标记取并集")
}

// ── 并集：一边删了、另一边还留着，谁晚听谁的 ──────────────────────────────
do {
    let kept = KairosItem(id: "d", title: "还在", updatedAt: at("2026-09-01T10:00:00Z"))
    let stone = KairosTombstone(
        id: "d", localRev: 1, syncedLocalRev: 0, beingRev: 0, deletedAt: at("2026-09-04T10:00:00Z")
    )
    let (deleted, report) = KairosLedgerUnion.union(snapshot([kept]), snapshot([], tombstones: [stone]))
    expect(deleted.items.isEmpty, "删得比改得晚：真删")
    expect(report.deleted == 1, "删掉几条要说出口")

    // 反过来：删完又改（复活）。墓碑作废，否则下次并的时候它又会被删掉，
    // 人看到的是「这条自己消失了」。
    let revived = KairosItem(id: "d", title: "又回来了", updatedAt: at("2026-09-06T10:00:00Z"))
    let (alive, _) = KairosLedgerUnion.union(snapshot([revived]), snapshot([], tombstones: [stone]))
    expect(alive.items.count == 1, "改得比删得晚：留下")
    expect(alive.tombstones.isEmpty, "墓碑要一起撤掉，不然下一趟又把它删了")
}

// ── 并集：水位取大的 ─────────────────────────────────────────────────────
//
// 取小的那个会让已经并过的 outbox 条目被重放一遍——那是「改动自己又出现一次」。
do {
    var mac = KairosSnapshot.empty
    mac.sync.outboxWatermark = ["phone": 7]
    var phone = KairosSnapshot.empty
    phone.sync.outboxWatermark = ["phone": 3, "ipad": 5]
    let (merged, _) = KairosLedgerUnion.union(mac, phone)
    expect(merged.sync.outboxWatermark["phone"] == 7, "同一台设备取大的")
    expect(merged.sync.outboxWatermark["ipad"] == 5, "只有一边有的照样带上")
}

// ── 并集：项目和手拖的顺序 ───────────────────────────────────────────────
do {
    var mac = KairosSnapshot.empty
    mac.workspace.projects = [KairosProject.defaultProject]
    mac.workspace.manualOrder = ["default/mine": ["a", "b"]]
    var phone = KairosSnapshot.empty
    phone.workspace.projects = [
        KairosProject(id: "demo", name: "demo", symbol: "square", color: "red", archived: false),
    ]
    phone.workspace.manualOrder = ["default/mine": ["b", "c"]]

    let (merged, report) = KairosLedgerUnion.union(mac, phone)
    expect(merged.workspace.projects.count == 2, "项目并集")
    expect(report.projects == 1, "带过去几个项目要说出口")
    expect(merged.workspace.manualOrder["default/mine"] == ["a", "b", "c"],
           "同一个桶：这边的顺序不动，对面独有的排后面，实际 \(merged.workspace.manualOrder["default/mine"] ?? [])")
}

// ── 并集：内容一样时不说废话 ─────────────────────────────────────────────
do {
    let same = snapshot([KairosItem(id: "a", title: "一样的", updatedAt: at("2026-09-01T10:00:00Z"))])
    let (_, report) = KairosLedgerUnion.union(same, same)
    expect(report.isEmpty, "两边一样就是没有需要并的")
    expect(report.line == "两边内容一样，没有需要并的", "别把「什么都没发生」说成「合并成功」")
}

// ── 真的落文件：指针写下去读回来、换位置的读写、备份 ────────────────────
//
// 上面几条都是纯函数。这一段验的是**换位置那一下真的落了盘**——
// 指针没写下去 = being 的 CLI 还在读老位置，两侧从此看的不是同一本账。
do {
    // 安全阀：万一 CFFIXED_USER_HOME 没生效（换了系统版本、换了 Foundation 实现），
    // 宁可跳过这一段，也不能往真的 ~/.kairos 里写东西。
    guard KairosFiles.configDirectory.path.hasPrefix(sandbox.path) else {
        fatalError("✗ 沙盒没生效，configDirectory 是 \(KairosFiles.configDirectory.path)——这段会写到真账本旁边，停手")
    }

    let shared = sandbox.appendingPathComponent("Shared/Kairos", isDirectory: true)
    let sharedLedger = shared.appendingPathComponent(KairosLedgerLocation.ledgerFileName)

    // 单机：还没有指针，也没有老的 iCloud 账本 → 本机那份。
    expect(KairosLedgerLocation.folder.path == KairosLedgerLocation.localFolder.path, "默认是单机")
    expect(!KairosLedgerLocation.isLinked, "默认不是关联态")

    // 写一份账本到「共享文件夹」，再把指针指过去——这就是接上那一下做的事。
    var toShare = KairosSnapshot.empty
    toShare.items = [KairosItem(id: "s-1", title: "共享那份里的")]
    expect(KairosLedgerLocation.writeLedger(toShare, to: sharedLedger), "写得进共享文件夹")
    expect(KairosLedgerLocation.writePointer(folder: shared), "指针写得下去")

    expect(KairosLedgerLocation.folder.path == shared.standardizedFileURL.path,
           "指针一写，账本位置立刻跟着变，实际 \(KairosLedgerLocation.folder.path)")
    expect(KairosLedgerLocation.isLinked, "现在是关联态")
    expect(KairosFiles.snapshot.path == sharedLedger.standardizedFileURL.path,
           "KairosFiles 每次现算，不缓存旧位置")

    let readBack = KairosLedgerLocation.readLedger(at: KairosFiles.snapshot)
    expect(readBack?.items.first?.title == "共享那份里的", "读回来的是共享那份")

    // 备份：换位置之前的那一步，账本没有回收站。
    let copy = KairosLedgerLocation.backup(sharedLedger, tag: "before-link")
    expect(copy != nil, "备份要真的产出一个文件")
    expect(FileManager.default.fileExists(atPath: copy!.path), "备份文件在 \(copy!.path)")

    // 「那边没有账本」和「那边有账本但读不出来」是两件事。
    // 后者当成前者的话，接上的那一下就是拿本机这份盖掉对面一份完好的账本
    // （典型场景：iCloud 还没把文件拉下来）。`readLedger` 两种都回 nil，
    // 所以调用方必须自己再看一眼文件在不在——`linkLedger` 就是这么拦的。
    let broken = shared.appendingPathComponent("broken.json")
    try! Data("{ 这不是 json".utf8).write(to: broken)
    expect(KairosLedgerLocation.readLedger(at: broken) == nil, "读不出来就是 nil")
    expect(FileManager.default.fileExists(atPath: broken.path), "但文件确实在——两件事分得开")

    // 断开：指针写回本机。**空指针不行**——那会退回「老 iCloud 位置若有账本就用它」，
    // 等于断不掉。所以断开写的是本机那条明确的路径。
    expect(KairosLedgerLocation.writePointer(folder: KairosLedgerLocation.localFolder), "指针写得回去")
    expect(!KairosLedgerLocation.isLinked, "断开之后回到单机")
    expect(KairosLedgerLocation.folder.path == KairosLedgerLocation.localFolder.standardizedFileURL.path,
           "断开之后指的是本机那份")
}

print("native location tests: all checks passed")
