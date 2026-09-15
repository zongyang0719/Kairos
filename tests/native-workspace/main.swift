import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

// 无 workspace 的 /2 快照：normalized 应补出唯一的 Default 项目，不猜别的项目。

let fixture = Data("""
{
  "protocol": "kairos.local/2",
  "updated_at": "2026-08-29T10:00:00Z",
  "being": { "name": "demo" },
  "sync": { "last_sync_at": null },
  "items": [
    { "id": "m-1", "state": "mine",   "title": "拍板一", "localRev": 0, "syncedLocalRev": 0, "beingRev": 2, "remoteKnown": true },
    { "id": "m-2", "state": "mine",   "title": "拍板二", "localRev": 0, "syncedLocalRev": 0, "beingRev": 1, "remoteKnown": true },
    { "id": "b-1", "state": "being",  "title": "在办",   "localRev": 0, "syncedLocalRev": 0, "beingRev": 3, "remoteKnown": true },
    { "id": "c-1", "state": "closed", "title": "判例",   "localRev": 0, "syncedLocalRev": 0, "beingRev": 4, "remoteKnown": true }
  ],
  "tombstones": [],
  "conflicts": []
}
""".utf8)

// fixture 是一本 /2 的账（球权还在）：正好拿它验一遍 /2 → /3。
let decoded = try JSONDecoder().decode(KairosSnapshot.self, from: fixture)
let original = decoded.migratedToMergedStatus()
let migrated = KairosWorkspaceEngine.normalized(original)

expect(original.protocolName == KairosSnapshot.protocolV3, "读进来就该是 /3")
expect(original.items.first(where: { $0.id == "c-1" })?.status == KairosStatus.closed,
       "closed → closed。这条错了，87 条已了结的会在人眼前重新打开")
expect(original.items.first(where: { $0.id == "b-1" })?.status == KairosStatus.doing,
       "being → doing（being 在办 = 进行中）")
expect(original.items.first(where: { $0.id == "m-1" })?.status == KairosStatus.todo,
       "mine → 状态原样；这本账没写 status，落默认 todo")
expect(decoded.items.first(where: { $0.id == "c-1" })?.legacyState == "closed",
       "老账本的球权要被接住——它不是 CodingKey 的话，解码时这一格就静默没了")

expect(migrated.workspace.projects.count == 1, "normalization should create exactly one project")
expect(migrated.workspace.projects[0].name == "Default", "the only default project should be named Default")
expect(migrated.workspace.projects[0].id == "default", "Default should have a stable id")
expect(migrated.workspace.projects.contains { $0.id == "default" }, "默认项目要在")
expect(migrated.items == original.items, "workspace normalization must not mutate items or revisions")

// 合并列表顺序挂在 active 桶：状态混排，但不改任何一条的状态。

var withActiveOrder = migrated
let activeKey = KairosWorkspace.orderKey(segment: KairosWorkspace.activeOrderKey)
withActiveOrder.workspace.manualOrder[activeKey] = ["b-1", "m-2", "m-1"]
let normalizedActiveOrder = KairosWorkspaceEngine.normalized(withActiveOrder)
expect(
    normalizedActiveOrder.workspace.manualOrder[activeKey] == ["b-1", "m-2", "m-1"],
    "active order should preserve mixed statuses"
)
expect(
    normalizedActiveOrder.items.first(where: { $0.id == "b-1" })?.status == KairosStatus.doing,
    "active ordering must not rewrite status"
)

// 老键迁移：顺序不能因为换了键格式就没了。
//
// 2026-09-11 把手工顺序的键从 "<项目id>/<段>" 改成 "<段>"——老键取的项目 id 来自
// `selectedProjectID`，而它会在读账本时被自动改，一改人拖的顺序就找不回来了。
// 换格式**必须带迁移**，不然这次改动自己就成了那个丢顺序的 bug。

var withLegacyOrder = migrated
withLegacyOrder.workspace.manualOrder = ["default/active": ["m-2", "b-1", "m-1"]]
let afterMigration = KairosWorkspaceEngine.normalized(withLegacyOrder)
expect(
    afterMigration.workspace.manualOrder[activeKey] == ["m-2", "b-1", "m-1"],
    "老键 default/active 的顺序要原样迁到新键 active 上"
)
expect(
    afterMigration.workspace.manualOrder["default/active"] == nil,
    "迁完老键就该扔掉，不留两份"
)
// 再跑一次：迁移必须是幂等的，第二次进来不该把顺序搅乱。
expect(
    KairosWorkspaceEngine.normalized(afterMigration).workspace.manualOrder[activeKey] == ["m-2", "b-1", "m-1"],
    "normalized 跑第二遍，顺序不变"
)

// 两个老桶（账本里出现过真项目时会有）合并到一个新桶，先来的排前面，不重复。
var twoLegacy = migrated
twoLegacy.workspace.manualOrder = ["default/active": ["m-1"], "custom/active": ["m-2", "m-1"]]
let mergedLegacy = KairosWorkspaceEngine.normalized(twoLegacy)
expect(
    mergedLegacy.workspace.manualOrder[activeKey] == ["m-2", "m-1"],
    "两个老桶合并：按键名字典序 custom 在 default 前，同一条只留第一次出现的位置"
)

// 「换项目」走事项自己的 `project` 字段，不再有 membership 那张表，
// 所以这儿原来那条 assigning 的用例连同被测函数一起撤了。
// 项目归属现在由 `KairosStore.macSetProject` 管，它走的是普通的 saveDraft 路径
// （盖 human 戳、正常涨 rev），和 workspace 无关。

// ── 迁移对拍：和 tests/ledger.test.js 跑同一份向量 ──────────────────────
//
// 两个实现各写各的迁移是真出过 bug 的（outbox 并入那条路有一侧漏了迁移，
// 手机按的「了结」两侧并出两个不同的状态，而且不报错）。这份向量两侧共用，
// 改一侧不改另一侧，两边总有一边会红。

struct MigrationVector: Decodable {
    var name: String
    var status: String
    var lastWriter: [String: String]?
    enum CodingKeys: String, CodingKey { case name, status, lastWriter }
}

let vectorsURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()          // tests/native-workspace
    .deletingLastPathComponent()          // tests
    .appendingPathComponent("fixtures/migration-vectors.json")
let vectorData = try Data(contentsOf: vectorsURL)
let vectorRoot = try JSONSerialization.jsonObject(with: vectorData) as! [String: Any]
let rawVectors = vectorRoot["vectors"] as! [[String: Any]]
let vectors = try JSONDecoder().decode(
    [MigrationVector].self,
    from: JSONSerialization.data(withJSONObject: rawVectors)
)

// 按向量拼一本 /2 的账，走和线上同一条路：解码 → migratedToMergedStatus()
var vectorItems: [[String: Any]] = []
for (index, raw) in rawVectors.enumerated() {
    var item = raw["in"] as! [String: Any]
    item["id"] = "v\(index)"
    item["title"] = raw["name"] as! String
    vectorItems.append(item)
}
let vectorLedger: [String: Any] = [
    "protocol": "kairos.local/2",
    "updated_at": "2026-09-11T00:00:00Z",
    "being": ["name": "Being"],
    "items": vectorItems,
    "tombstones": [], "conflicts": [],
]
let vectorSnapshot = try JSONDecoder()
    .decode(KairosSnapshot.self, from: JSONSerialization.data(withJSONObject: vectorLedger))
    .migratedToMergedStatus()

expect(vectorSnapshot.items.count == vectors.count, "向量条数对不上")
for (index, vector) in vectors.enumerated() {
    let got = vectorSnapshot.items[index]
    expect(got.status == vector.status,
           "[\(vector.name)] 状态应为 \(vector.status)，实际 \(got.status)")
    expect(got.legacyState == nil, "[\(vector.name)] 球权该被清掉")
    if let wantWriter = vector.lastWriter {
        expect(got.lastWriter == wantWriter,
               "[\(vector.name)] 写者戳应为 \(wantWriter)，实际 \(got.lastWriter)")
    }
}

// 同一份向量再走一遍 outbox 并入那条路——它是 2026-09-11 真漏掉迁移的那条。
for (index, vector) in vectors.enumerated() {
    var raw = rawVectors[index]["in"] as! [String: Any]
    raw["id"] = "v\(index)"
    raw["title"] = vector.name
    let payload = try JSONDecoder()
        .decode(KairosItemPayload.self, from: JSONSerialization.data(withJSONObject: raw))
    let entry = KairosOutboxEntry(
        seq: 1, itemID: "v\(index)", op: "upsert",
        item: payload, fields: ["status"], createdAt: "2026-09-12T00:00:00Z"
    )
    var onLedger = KairosItem(id: "v\(index)", title: vector.name)
    onLedger.status = "__none__"          // 保证一定算成「变了」，逼它真的写一次
    let merged = entry.merged(onto: onLedger)
    expect(merged?.status == vector.status,
           "[\(vector.name)] outbox 并入应得 \(vector.status)，实际 \(merged?.status ?? "nil")")
}

print("native workspace tests: all checks passed")
