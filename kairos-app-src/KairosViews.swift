import AppKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 窗口骨架
//
// 信息架构：
//
//   边栏      项目（照 Things 的 Project / 提醒事项的列表）：「全部」+ 自己建的项目，待办能拖进去。
//             一个 being、一张单子，边栏不做「待办 / 信箱」这种分类——那是顶上分段的事。
//   单子      待办和信混在一起：一封信就是一行，进现有的优先级 / 状态组，只靠信封图标区分；
//             「来源」在筛选里。以后篝火、炉火进来就是再加一种来源。
//   视图      边栏里存下来的一组显示设置（分组、筛选、项目、显示已了结），点一下就回到那个样子。
//             三个维度都由 being 定、人也能改：优先级（多要紧）、状态（走到哪了）、项目（属于哪摊事）。
//             顶上是今天的日期和星期；⌘N 在单子里就地多一行输入，回车就加，Esc 收起。
//             点圆点先打勾、半秒后再消失——手滑还能反悔。没有「现在」卡：几件事混着做是他的习惯。
//   看板      **撤了**。一条待办的状态是 being 在推进的结果，不是人拖着走的
//             一张卡：拖卡那个动作本身就是「人来调度」，而这个产品的整句话是人不调度。
//             它在这儿还有一个具体的代价——看板逼着「不分组」退回按优先级，等于永远
//             看不到 being 排的那张顺序。分堆看的需求由列表的「分组」接着。
//   房间      右侧检查器，默认收着，点一条才出现，× 或 Esc 或 ⌥⌘I 收起。
//   时间      不进协议。没有 due date、没有日历、没有逾期——时机在 being 的记忆里，该提醒时它在房间里说话。
//
// 视觉走原生 Apple：系统底色、系统材质、系统强调色做选中和焦点。自己的颜色只剩两个语义色：
// P0 红、P1 橙。状态用 Linear 那套圆点：空圈未开始、半圆进行中、虚线圈待定、实心勾已完结。

extension UTType {
    static let kairosItems = UTType(exportedAs: "com.kairos.items")
    static let kairosProjects = UTType(exportedAs: "com.kairos.projects")
}

struct KairosItemDragPayload: Codable, Transferable {
    let itemIDs: [String]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .kairosItems)
    }
}

/// 拖的是项目自己（边栏里换个位置），不是待办。
///
/// 单独一个类型，不和待办共用：边栏的项目行**两种拖拽都收**——待办拖进来是「换项目」，
/// 项目拖进来是「换位置」。靠类型区分，落点自己认领自己那一种，谁也不会误收谁。
struct KairosProjectDragPayload: Codable, Transferable {
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .kairosProjects)
    }
}

// MARK: - Mac 专属的窗口状态

/// 一行是从哪来的：账本上的 `source`（`KairosSource`）。
/// 以后篝火、炉火进来就是 being 建待办时写上对应的 source，这里不用改。
enum KairosMacSource {
    static func symbol(_ source: String) -> String {
        switch KairosSource.normalized(source) {
        case KairosSource.inbox: "envelope"
        // SF Symbols 里没有 campfire / bonfire / firewood，只能在现有符号里挑：
        // 篝火是敞开的明火，炉火是炉膛里的火。两个都用线框——这一排图标本来就该是同一套
        // 笔触，掺一个实心的进去只会显得那一格更重（用 `flame`）。
        case KairosSource.bonfire: "flame"
        case KairosSource.fireside: "fireplace"
        default: "checklist"
        }
    }
}

enum KairosMacGrouping: String, CaseIterable, Identifiable, Codable {
    case tier, status, none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tier: "按优先级"
        case .status: "按状态"
        case .none: "不分组"
        }
    }
}

enum KairosMacAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// 筛选：空集 = 不筛。`project` 由边栏定（nil = 全部），其余在「显示 › 筛选」里。
struct KairosMacFilter: Equatable, Codable {
    enum CodingKeys: String, CodingKey { case tiers, statuses, sources, project, scope }

    var tiers: Set<String> = []
    var statuses: Set<String> = []
    /// 渠道（`KairosSource` 的值）。
    var sources: Set<String> = []
    var project: String? = nil
    /// 顶上那三段。**不算「筛选着东西」**——它是分段不是漏斗，所以不进 `isActive`。
    var scope: KairosMacScope = .all
    init() {}

    /// **必须手写。** Swift 合成的解码器不认属性上的默认值：存下来的「视图」是老格式的 json，
    /// 里面没有 `scope` 这个键，合成解码器会整份解不出来——人类存的那几个视图一夜之间全没了。
    /// （`KairosRoom` 那边刚栽过一次同样的坑，那次丢的是房间日志。）
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        tiers = try box.decodeIfPresent(Set<String>.self, forKey: .tiers) ?? []
        statuses = try box.decodeIfPresent(Set<String>.self, forKey: .statuses) ?? []
        sources = try box.decodeIfPresent(Set<String>.self, forKey: .sources) ?? []
        project = try box.decodeIfPresent(String.self, forKey: .project)
        scope = try box.decodeIfPresent(KairosMacScope.self, forKey: .scope) ?? .all
    }

    /// 「显示」那个图标要不要变成漏斗——边栏选了项目不算，那是导航不是筛选。
    var isActive: Bool { !tiers.isEmpty || !statuses.isEmpty || !sources.isEmpty }

    func allows(source: String) -> Bool {
        sources.isEmpty || sources.contains(KairosSource.normalized(source))
    }

    func allows(_ item: KairosItem) -> Bool {
        guard scope.allows(item) else { return false }
        guard allows(source: item.source) else { return false }
        if let project, item.project != project { return false }
        if !tiers.isEmpty, !tiers.contains(KairosMacTier.normalized(item.tier)) { return false }
        if !statuses.isEmpty, !statuses.contains(KairosStatus.normalized(item.status)) { return false }
        return true
    }
}


/// 一行上显不显示哪几样。参考同类看板工具的「卡片属性」那一组开关——
/// 它们是**显示**的事（这一行长什么样），不是筛选（看哪些行）。
/// 这条分界要守住：两个按钮内容不许重复。
struct KairosMacRowProperties: OptionSet, Codable, Equatable {
    let rawValue: Int
    static let project = KairosMacRowProperties(rawValue: 1 << 0)
    static let tier = KairosMacRowProperties(rawValue: 1 << 1)
    static let source = KairosMacRowProperties(rawValue: 1 << 2)
    static let date = KairosMacRowProperties(rawValue: 1 << 3)
    static let standard: KairosMacRowProperties = [.project, .tier, .source, .date]

    /// 「来源」这一格 2026-09-13 从面板上撤了：全部都归到待办，信不再是另一类东西，
    /// 行上那颗信封 / 火焰也跟着不画。位还留着（老的视图存过它，解码要认得）。
    static let all: [(KairosMacRowProperties, String)] = [
        (.project, "项目"), (.tier, "优先级"), (.date, "日期"),
    ]
}

/// 边栏里存下来的视图：一组显示设置，点一下就回到那个样子。存在 UserDefaults，纯本机。
struct KairosMacView: Codable, Identifiable, Equatable {
    enum CodingKeys: String, CodingKey { case id, name, symbol, grouping, showClosed, filter, rowProperties }

    var id: String = UUID().uuidString
    var name: String
    /// 边栏上画哪个图标。人自己挑，随时能改。
    var symbol: String = KairosMacView.defaultSymbol
    var grouping: KairosMacGrouping
    var showClosed: Bool
    var filter: KairosMacFilter
    var rowProperties: KairosMacRowProperties = .standard

    /// 给视图挑图标时的备选。不做全量 SF Symbols 浏览器——十几个够用，
    /// 挑图标不该变成一件要花时间的事。
    static let symbolChoices = [
        "line.3.horizontal.decrease", "star", "flame", "bolt", "flag", "tag",
        "tray.full", "calendar", "clock", "person.2", "folder", "bookmark",
        "target", "chart.bar", "sparkles", "moon",
    ]
    static let defaultSymbol = "line.3.horizontal.decrease"

    init(
        id: String = UUID().uuidString,
        name: String,
        symbol: String = KairosMacView.defaultSymbol,
        grouping: KairosMacGrouping,
        showClosed: Bool,
        filter: KairosMacFilter,
        rowProperties: KairosMacRowProperties = .standard
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.grouping = grouping
        self.showClosed = showClosed
        self.filter = filter
        self.rowProperties = rowProperties
    }

    /// **必须手写**，和 `KairosMacFilter` 那次同一个理由：Swift 合成的解码器不认属性上的
    /// 默认值，存过的老视图里没有 `rowProperties` 这个键，合成解码器会让**整份视图列表**
    /// 解不出来——人类存的视图会一夜之间全没（`KairosMacFilter.init(from:)` 上有原案）。
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try box.decode(String.self, forKey: .name)
        symbol = try box.decodeIfPresent(String.self, forKey: .symbol) ?? KairosMacView.defaultSymbol
        // 存过的老视图里那个 `layout` 键读都不读——看板撤了，
        // 键留在 json 里不碍事，下次存这个视图就没了。
        grouping = try box.decodeIfPresent(KairosMacGrouping.self, forKey: .grouping) ?? .tier
        showClosed = try box.decodeIfPresent(Bool.self, forKey: .showClosed) ?? false
        filter = try box.decodeIfPresent(KairosMacFilter.self, forKey: .filter) ?? KairosMacFilter()
        rowProperties = try box.decodeIfPresent(KairosMacRowProperties.self, forKey: .rowProperties) ?? .standard
    }
}

/// 边栏的选中：「全部」、某个项目名、或某个视图。
enum KairosSidebarTag {
    static let all = "\u{0}all"
    private static let viewPrefix = "\u{0}view:"

    static func view(_ id: String) -> String { viewPrefix + id }

    static func viewID(_ tag: String) -> String? {
        tag.hasPrefix(viewPrefix) ? String(tag.dropFirst(viewPrefix.count)) : nil
    }
}

/// Store 是两端共用的，Mac 才有的状态不塞进去，放这儿。显示偏好记在 UserDefaults。
@MainActor
final class KairosMacShell: ObservableObject {
    /// 等着被删的那几条。**是一批**：多选之后右键删除，删的是整批。
    @Published var pendingDeleteIDs: [String] = []
    /// ⌘F：把光标要到单子头上那个搜索框（`MacSearchField`）。
    /// 搜索框从窗口工具栏挪下来之后，`.searchable` 白送的那个 ⌘F 也一起没了，得自己接。
    @Published var searchTick = 0
    @Published var creatingProject = false
    /// 房间（右侧检查器）开没开。默认收着，点一条才开。
    @Published var roomShown = false
    /// 正在被拖的那几条。**只用来把原位那几行调暗**——手上拖着的是一张预览卡，
    /// 原位要是一点变化都没有，看着就像「拖出来一份复制品」，而不是「把这条挪走」。
    @Published var draggingIDs: Set<String> = []
    private var dragCleanup: Task<Void, Never>?

    func beginDrag(_ ids: [String]) {
        draggingIDs = Set(ids)
        // SwiftUI 的 `.draggable` **不给「拖拽结束」的回调**——放下、按 Esc 取消、
        // 拖出窗口外松手，三种都没有。落点自己会调 `endDrag`，那是正常路径；
        // 取消和拖飞了靠这个兜底，不然原位那几行会一直灰着直到下次拖拽。
        dragCleanup?.cancel()
        dragCleanup = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.draggingIDs = []
        }
    }

    func endDrag() {
        dragCleanup?.cancel()
        dragCleanup = nil
        draggingIDs = []
    }

    /// 每加一次，右侧那个新建输入框就把光标要回来一次。
    /// （原来这儿是 `quickAdding`：⌘N 在单子顶上插一行输入。那一行没了——
    /// 「新建」和右侧空面板现在是同一件事，见 `NewItemPanel`。）
    @Published var composeTick = 0
    /// 头上那行输入框开没开。**平时收着**，点头上那颗橙色的 + 或 ⌘N 才出来。
    @Published var composing = false
    @Published var filter = KairosMacFilter()

    /// 存下来的视图。
    /// 存下来的视图。
    ///
    /// **落在账本文件夹里的 `views.json`，不是 UserDefaults，也不进账本本身。**
    ///   · 不是 UserDefaults —— 那是「这一台机器」的东西，换台机器就没了。
    ///     放进账本文件夹，接了 iCloud 就自动跟着走。
    ///   · 不进 `projection-snapshot.json` —— 视图是**纯人类的东西**，being 不需要知道
    ///     你把单子筛成什么样（人类原话：「完全属于人类的东西」）。契约 §121 本来就把
    ///     工作区组织划在 Being payload 之外，这条是同一个道理，只是换了个文件装。
    @Published var views: [KairosMacView] {
        didSet { Self.writeViews(views) }
    }
    @Published var savingView = false
    /// 那张表单在改哪个视图；nil = 在存一个新的。同一张表单两用，见 `SaveViewSheet`。
    @Published var editingViewID: String?
    /// 边栏里**点中**的那个视图。nil = 现在站在「全部」或某个项目上。
    /// 为什么要显式记一个而不是推导，见 `activeView`。
    @Published var activeViewID: String?

    @Published var grouping: KairosMacGrouping {
        didSet { UserDefaults.standard.set(grouping.rawValue, forKey: Self.groupingKey) }
    }

    @Published var showClosed: Bool {
        didSet { UserDefaults.standard.set(showClosed, forKey: Self.showClosedKey) }
    }

    /// 行上显不显示哪几样。属于「显示」，不属于「筛选」。
    @Published var rowProperties: KairosMacRowProperties {
        didSet { UserDefaults.standard.set(rowProperties.rawValue, forKey: Self.rowPropertiesKey) }
    }

    @Published var appearance: KairosMacAppearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: Self.appearanceKey)
            appearance.apply()
        }
    }

    private static let viewsKey = "kairos.mac.views"   // 只用来读一次老数据，见 `loadViews`
    /// 视图存在账本文件夹里，和账本同一个家；接了 iCloud 就跟着进 iCloud。
    private static var viewsFile: URL {
        KairosFiles.dataDirectory.appendingPathComponent("views.json")
    }

    private static func writeViews(_ views: [KairosMacView]) {
        guard let data = try? JSONEncoder().encode(views) else { return }
        let url = viewsFile
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// 读视图。**先读文件；文件还没有就把老的 UserDefaults 那份搬过来**——
    /// 换存法不能让人已经存好的视图凭空消失。搬完就把老键清掉，只搬这一次。
    private static func loadViews() -> [KairosMacView] {
        if let data = try? Data(contentsOf: viewsFile),
           let decoded = try? JSONDecoder().decode([KairosMacView].self, from: data) {
            return decoded
        }
        let defaults = UserDefaults.standard
        guard let legacy = defaults.data(forKey: viewsKey),
              let decoded = try? JSONDecoder().decode([KairosMacView].self, from: legacy)
        else { return [] }
        writeViews(decoded)
        defaults.removeObject(forKey: viewsKey)
        return decoded
    }
    private static let groupingKey = "kairos.mac.grouping"
    private static let showClosedKey = "kairos.mac.showClosed"
    private static let rowPropertiesKey = "kairos.mac.rowProperties"
    private static let appearanceKey = "kairos.mac.appearance"

    init() {
        let defaults = UserDefaults.standard
        views = Self.loadViews()
        grouping = KairosMacGrouping(rawValue: defaults.string(forKey: Self.groupingKey) ?? "") ?? .tier
        showClosed = defaults.bool(forKey: Self.showClosedKey)
        // 没存过就是全都显示（`.standard`）。`object(forKey:)` 判 nil，不能直接 integer——
        // 那个「没存过」和「存了 0（一个都不显示）」返回的都是 0。
        rowProperties = defaults.object(forKey: Self.rowPropertiesKey)
            .map { KairosMacRowProperties(rawValue: ($0 as? Int) ?? 0) } ?? .standard
        appearance = KairosMacAppearance(rawValue: defaults.string(forKey: Self.appearanceKey) ?? "") ?? .system
    }

    /// 边栏选的项目；nil = 全部。
    var selectedProject: String? {
        get { filter.project }
        set { filter.project = newValue }
    }

    var inspectorShown: Bool { roomShown }

    /// 右侧此刻是不是真开着。检查器的开关和窗口的最小宽度（`KairosMacLayout`）都认这一句，
    /// 两处说法一不一致，窗口就可能缩到分栏放不下的宽度。
    func showsRoom(_ store: KairosStore) -> Bool {
        roomShown && store.selectedItem != nil
    }

    /// 现在这一屏的样子，存成视图就是它。
    func snapshotView(named name: String, symbol: String = KairosMacView.defaultSymbol) -> KairosMacView {
        KairosMacView(
            name: name, symbol: symbol, grouping: grouping,
            showClosed: showClosed, filter: filter, rowProperties: rowProperties
        )
    }

    func apply(_ view: KairosMacView) {
        grouping = view.grouping
        showClosed = view.showClosed
        filter = view.filter
        rowProperties = view.rowProperties
    }

    /// 回到出厂设置。边栏点「全部」就是这个——**「全部」就该是全部**，
    /// 不能把上一个视图的筛选偷偷带过来——切回全部，就应该是全部、是默认。
    func resetToDefaults() {
        activeViewID = nil
        grouping = .tier
        showClosed = false
        rowProperties = .standard
        filter = KairosMacFilter()
    }

    /// 现在这个样子值不值得存成一个视图 —— 第二行那颗「存为视图」只在值得的时候才出现。
    ///
    /// **只看筛选，不看显示。** 布局、分组、行上显示哪几样是**长期偏好**：一个人习惯
    /// 「不分组」，不代表他每次打开 app 都该被问一句「要不要存成视图」。而筛选是临时的
    /// ——筛出来一组东西，那才叫「一个视图」。
    /// （显示和筛选没有任何操作、全是默认的情况下，不该露「创建视图」——
    /// 原来把分组也算进去，分组设成不分组之后，那颗按钮就再也不消失了。）
    ///
    /// 另一种也值得存：正用着某个视图、又在它基础上改了东西——那时候「存」的意思是
    /// 「把改动留下来」，所以也露出来。
    /// **只回答一件事：不在任何视图上时，现在这副样子值不值得存。**
    /// 站在某个视图上时该显示「更新 / 另存」还是什么都不显示，由 `SaveViewButton`
    /// 自己按 `activeViewOnDisk` + `matches` 判断——那是两个问题，别揉在一个布尔里。
    var hasSavableState: Bool {
        filter.isActive || filter.scope != .all
    }

    /// 边栏里哪个视图该亮。
    ///
    /// **由「点了哪一行」说了算，不是「现在的样子碰巧和哪个视图一样」。**
    /// 原来只有后半句——`views.first { 四项都相等 }`，没有 `activeViewID` 这一层。
    /// 于是存一个「全部 + 当前设置」的视图之后，点「全部」什么都不会变（本来就一样），
    /// 推导出来的仍然是那个视图，**边栏再也回不到「全部」**
    /// （创建了视图，却从视图点不回全部。）
    ///
    /// 现在记一个显式的 `activeViewID`：点视图才亮，点「全部」/ 项目就灭。
    /// 亮着的时候仍然要求设置确实还和它一样——改动了任何一项照旧自己灭，那半句没丢。
    /// 边栏上**点中**的那个视图本身，不管现在的设置还和它一不一样。
    ///
    /// 和 `activeView` 是两个问题：那个问「边栏该不该亮它」（设置一改就不亮了），
    /// 这个问「你现在站在哪个视图上」。改了设置之后前者变 nil、后者还在——
    /// 正因为还在，才问得出「要不要把改动存回去」。
    var activeViewOnDisk: KairosMacView? {
        activeViewID.flatMap { id in views.first { $0.id == id } }
    }

    var activeView: KairosMacView? {
        guard let activeViewID,
              let view = views.first(where: { $0.id == activeViewID }),
              matches(view)
        else { return nil }
        return view
    }

    func matches(_ view: KairosMacView) -> Bool {
        view.grouping == grouping
            && view.showClosed == showClosed && view.filter == filter
            && view.rowProperties == rowProperties
    }

    /// 「新建」= **把光标要到单子底下那一行**。
    ///
    /// 它曾经是「右侧开出来一块空面板，光标落在面板底部」——那块面板九成的面积是空白，
    /// 而人要做的只是打一行字（人类这天的原话：「这个排布，什么狗屁」）。
    /// 现在记东西的地方常驻在单子底下，⌘N 只做一件事：聚焦。不换屏、不开面板、不清选中。
    func newItem(_ store: KairosStore) {
        composing = true
        composeTick += 1
    }

    func closeInspector(_ store: KairosStore) {
        roomShown = false
        store.clearSelection()
    }

}

private typealias T = KairosTokens

struct KairosWindow: View {
    @ObservedObject var store: KairosStore
    @ObservedObject var shell: KairosMacShell
    @Environment(\.undoManager) private var undoManager

    private var pendingDeleteItems: [KairosItem] {
        shell.pendingDeleteIDs.compactMap { id in store.snapshot.items.first { $0.id == id } }
    }

    var body: some View {
        NavigationSplitView {
            ProjectSidebar(store: store, shell: shell)
        } detail: {
            MainScreen(store: store, shell: shell)
        }
        .navigationSplitViewStyle(.balanced)
        // 右侧挂在**整个分栏**上，不挂在单子那一栏里。
        //
        // 两处画出来的面板一样，工具栏不一样：挂在单子那一栏里，工具栏不知道右侧从哪儿开始，
        // 单子那一段的按钮会越过分界，跑到右侧头顶上去。挂在这儿，工具栏才按「单子 | 右侧」
        // 分成两段，各自的按钮待在各自那一栏的正上方。
        .inspector(isPresented: inspectorBinding) {
            // 最宽就是默认宽：右侧每宽一点，窗口就得宽出两倍（`KairosMacLayout`）。
            inspectorColumn
                .inspectorColumnWidth(
                    min: KairosMacLayout.roomMinWidth,
                    ideal: KairosMacLayout.roomWidth,
                    max: KairosMacLayout.roomWidth
                )
        }
        // **标题栏上那颗「显示/隐藏边栏」撤了**：它孤零零浮在边栏右上角，和底下任何东西都不对齐。
        // 边栏是这个窗口的常驻去处，收起它是低频操作：「显示」菜单里的 ⌃⌘S 照样能收。
        // （修饰符挂在**边栏那一列的视图上**才生效，见 `ProjectSidebar`；挂在分栏容器上系统不认。）
        //
        // `navigationTitle` 要给——「窗口」菜单、Mission Control、旁白都念它——但不画在工具栏上：
        // 人不需要被提醒自己在用哪个 app，那一排留给日期。
        .navigationTitle("Kairos")
        .toolbar(removing: .title)
        // **工具栏不要自己的底。** 系统给它配的是一条和单子同色的底 + 一根发丝线，
        // 静止时那根线就横在日期底下——顶上多出来的那一条就是它。
        // 滚上去的行由单子自己收边（`ToolbarScrim`），不画线。
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .sheet(item: $store.editingItem) { item in
            ItemEditor(item: item, store: store)
        }
        .sheet(isPresented: $shell.creatingProject) {
            NewProjectSheet(store: store, shell: shell)
        }
        .sheet(isPresented: $shell.savingView) {
            SaveViewSheet(shell: shell)
        }
        .alert(
            "Kairos",
            isPresented: Binding(
                get: { store.notice != nil },
                set: { if !$0 { store.notice = nil } }
            ),
            presenting: store.notice
        ) { _ in
            Button("好", role: .cancel) { store.notice = nil }
        } message: { Text($0) }
        // 删几条就说几条。多选之后删除，弹一个「删除这条待办？」是在骗人——
        // 按下去没的是一批（跟着多选一起补的）。
        .alert(
            pendingDeleteItems.count > 1 ? "删除这 \(pendingDeleteItems.count) 条待办？" : "删除这条待办？",
            isPresented: Binding(
                get: { !pendingDeleteItems.isEmpty },
                set: { if !$0 { shell.pendingDeleteIDs = [] } }
            )
        ) {
            Button("删除", role: .destructive) {
                let doomed = pendingDeleteItems
                shell.pendingDeleteIDs = []
                for item in doomed { store.delete(item) }
            }
            Button("取消", role: .cancel) { shell.pendingDeleteIDs = [] }
        } message: {
            Text("对话记录也会一起没有。")
        }
        .environmentObject(shell)
        .background(KeepWindowOnScreen())
        // 系统控件（开关、分段、步进）的着色跟 app 走，不跟系统强调色走：这台机器的强调色是粉，
        // 「显示」面板里那颗开关原来是一颗粉的，在一屏橙和灰里是唯一的粉。
        .tint(KairosMacPalette.attention)
        // 时间戳跟着界面走中文（信的「9月8日 21:35」）。
        .environment(\.locale, Locale(identifier: "zh_Hans"))
        .onAppear {
            // environment 里没有 undoManager 时别把 store 自带的那个覆盖成 nil——
            // 覆盖了以后 ⌘Z 和「撤销」胶囊都是空的（了结错了就撤不回来）。
            if let undoManager { store.undoManager = undoManager }
            shell.appearance.apply()
            // 以前记在「想法」里的东西一次性变成待办，别让它们随那一屏一起消失。
            store.absorbSeedsIntoItems()
            // 开机跑一趟。**以前只有菜单里那颗「刷新账本」会调它**——于是收手机的改动、
            // 读邮箱、把信并成单子上的行，全都要人手动按一下才发生。
            // 打开就该是最新的，这是「一张单子」的底线。
            Task { await store.refresh() }
        }
        .onChange(of: shell.selectedProject) {
            shell.closeInspector(store)
        }
        // 改动通知是攒几秒再发的（见 `KairosStore.announce`）。退出前把攒着的倒出去，
        // 别让最后几秒的改动烂在内存里——账本上有，但 being 不会主动知道。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            Task { await store.flushPendingAnnouncements() }
        }
    }

    /// 检查器开着 = 选了一个人的信，或者开了一条待办的房间。关掉就清选中——
    /// 不清的话再点同一行不会有变化事件，就再也打不开。
    private var inspectorBinding: Binding<Bool> {
        Binding(
            // **点开一条才有右侧。** 两种情况：一条待办的房间，或者一个人的往来。
            // 没有「空着的右侧」，也没有不绑任何事的桌面对话（理由见 `CaptureBar`）。
            get: { shell.showsRoom(store) },
            set: { shown in
                if !shown { shell.closeInspector(store) }
            }
        )
    }

    /// 右侧那一栏：**铺回单子那块底**，和单子之间只隔一根发丝线。
    ///
    /// 系统的检查器自带一层贴边的玻璃。左边是浮着的边栏玻璃，右边再来一块贴边的玻璃，
    /// 窗口里就有三种面——浮着的、贴边的、单子的底——拼起来就是一块一块的补丁。
    /// 铺回同一块底之后，窗口里只剩「左边一块导航的玻璃 + 一整块内容」：
    /// 右侧是内容被分出去的一半，不是另一块板子。
    ///
    /// 「收起」在工具栏里、这一栏的正上方，和左上角的红绿灯站在同一排。
    private var inspectorColumn: some View {
        inspectorContent
            .background {
                KairosCanvas()
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor))
                            .frame(width: 1)
                    }
                    .ignoresSafeArea()
            }
            .toolbar {
                ToolbarSpacer(.flexible)
                ToolbarItem {
                    Button {
                        shell.closeInspector(store)
                    } label: {
                        Label("收起", systemImage: "xmark")
                    }
                    .help("收起（⌥⌘I）")
                }
            }
    }

    @ViewBuilder
    private var inspectorContent: some View {
        if let item = store.selectedItem, shell.roomShown {
            // `.id`：换一条待办就换一份视图状态，草稿不会从上一条串过来。
            ItemRoomView(store: store, itemID: item.id)
                .id(item.id)
        }
    }
}

/// 三栏的宽度和窗口的最小宽度是**同一道算术题**，不能各写各的。
///
/// macOS 26 这套「边栏 + 单子 + 右侧（inspector）」分栏，实测窗口至少要
/// **边栏宽 + 2 × 右侧宽**：边栏 180 / 300 × 右侧 360 / 460 / 720 六种组合都是这个数，
/// 换成 `.automatic` 分栏样式也一样；右侧不开时只要 300。
///
/// 以前窗口最小宽度写死 860、右侧最宽 720：窗口能缩到分栏根本放不下的宽度，
/// 分栏在几种分法之间来回算，AppKit 数到上限就把 app 杀掉——
/// 「The window has been marked as needing another Update Constraints in Window pass…」。
/// 09-16、09-17 那三次闪退都是它：860 宽开着右侧必崩；1240 宽把右侧拖过 530 也崩。
///
/// 所以右侧开着时，窗口最小宽度按最坏的情况算（边栏最宽 + 2 × 右侧最宽），
/// 右侧也不许再往宽里拖——再宽，窗口就得跟着宽出两倍。
enum KairosMacLayout {
    static let sidebarMinWidth: CGFloat = 180
    static let sidebarIdealWidth: CGFloat = 210
    static let sidebarMaxWidth: CGFloat = 300
    static let roomMinWidth: CGFloat = 360
    /// 右侧的默认宽度，也是它最宽能到的宽度。
    static let roomWidth: CGFloat = 460
    static let windowMinWidth: CGFloat = 860
    static let windowMinWidthWithRoom: CGFloat = sidebarMaxWidth + 2 * roomWidth
    static let windowMinHeight: CGFloat = 560
}

/// 程序改了窗口大小之后，右边出了屏幕就整个往左挪回来。
///
/// 右侧开出来时窗口最小宽度跟着变大（`KairosMacLayout`），窗口是**往右**撑宽的——
/// 贴着屏幕右边放的窗口会被推出去一截。人自己拖着改大小时不管（`inLiveResize`），
/// 全屏时也不管。
struct KeepWindowOnScreen: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WatcherView() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class WatcherView: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak window] _ in
                MainActor.assumeIsolated {
                    guard let window,
                          !window.inLiveResize,
                          !window.styleMask.contains(.fullScreen),
                          let visible = window.screen?.visibleFrame,
                          window.frame.maxX > visible.maxX + 0.5
                    else { return }
                    window.setFrameOrigin(NSPoint(
                        x: max(visible.minX, visible.maxX - window.frame.width),
                        y: window.frame.minY
                    ))
                }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

/// 单子那块底：`contentBackground` 材质，和 `List` 自己铺的那层是同一种东西。
///
/// 不能拿纯色（`textBackgroundColor`）代替：系统会拿壁纸给窗口的材质染一点色，纯色不跟着染，
/// 两块摆在一起差一个色调——原来单子头上那条颜色不一样的带子就是这么来的。
struct KairosCanvas: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .contentBackground
        view.blendingMode = .withinWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// 工具栏那一排底下的**收边**：单子往上滚，行在日期底下淡出去——不画线，也不画一条底色带。
///
/// 工具栏自己的底关掉了（见 `KairosWindow`），这里只补回它有用的那一半：盖住滚上去的行。
/// 盖的是和单子同一种材质，所以静止时它和底下是一块、看不见；最下面 16pt 渐隐，
/// 行是淡出去的，不是被一刀切掉。高度跟着安全区走，⌘N 那一行展开时一起盖到。
private struct ToolbarScrim: View {
    private static let fade: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            let top = proxy.safeAreaInsets.top
            KairosCanvas()
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: top / (top + Self.fade)),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .frame(height: top + Self.fade)
                .offset(y: -top)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 记一条。**顶上那一排唯一带颜色的那颗**——和手机右下角那颗橙色的 + 同一个意思、同一个颜色。
///
/// 这一屏上它是最高频的动作，所以它是那一排里唯一实心、唯一上色的；
/// 旁边搜索 / 筛选 / ⋯ 是一组灰的线条图标，一眼就分得出主次。
/// 32pt：工具栏里的玻璃底是 36pt 高，实心的圆看起来比半透明的玻璃大一圈，小两点才齐。
private struct NewItemButton: View {
    @ObservedObject var shell: KairosMacShell
    @ObservedObject var store: KairosStore

    var body: some View {
        Button {
            shell.newItem(store)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(KairosMacPalette.onAccent)
                .frame(width: 32, height: 32)
                .background(KairosMacPalette.attention, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help("记一条（⌘N）")
        .accessibilityLabel("记一条")
    }
}

/// 头上那三颗图标的统一样子：同尺寸、同分量、只有图形。说明文字在 tooltip 里。
///
/// 用它的按钮**不加 `.plain`**：它们住在工具栏那块玻璃上，系统的按钮样式给悬停、按下的反馈，
/// 间距也按工具栏的规则排；`.plain` 会把这些一起抹掉，点上去像点在一张图上。
private struct HeaderIcon: View {
    let symbol: String
    var tint: Color = .secondary
    var count: Int = 0

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
            if count > 0 {
                // 计数不加粗：它已经跟着图标一起变橙了，颜色就是强调。
                Text("\(count)")
                    .font(.system(size: T.TypeScale.caption).monospacedDigit())
            }
        }
        .foregroundStyle(tint)
        .frame(minWidth: 28, minHeight: 26)
        .padding(.horizontal, count > 0 ? 4 : 0)
        .contentShape(.rect)
    }
}

/// 搜索。**平时是一颗放大镜**，点一下或 ⌘F 才展开成框；清空、移开焦点就收回去。
///
/// 搜索是低频的——一天里大多数时候单子一眼就扫完了，不需要一个常驻的框
/// 占着头上最显眼的那块地方。但它又不能藏进菜单：真要找的时候得一下就够得着，
/// 所以就在原位，只是平时收成一颗图标。
private struct MacSearchField: View {
    @Binding var query: String
    @ObservedObject var shell: KairosMacShell
    @FocusState private var focused: Bool
    @State private var expanded = false

    private var isOpen: Bool { expanded || !query.isEmpty }

    var body: some View {
        Group {
            if isOpen {
                HStack(spacing: T.Spacing.xs) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索", text: $query)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onExitCommand { close() }
                    if !query.isEmpty {
                        Button(action: close) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清除")
                    }
                }
                .font(.system(size: T.TypeScale.body))
                .padding(.horizontal, T.Spacing.s)
                .padding(.vertical, T.Spacing.xs)
                .frame(width: 220)
                .background(T.Ink.fill, in: .capsule)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .trailing)))
            } else {
                Button(action: open) {
                    HeaderIcon(symbol: "magnifyingglass")
                }
                .help("搜索（⌘F）")
                .accessibilityLabel("搜索")
            }
        }
        .animation(T.Motion.easeOut, value: isOpen)
        .onChange(of: shell.searchTick) { open() }
        // 焦点移开时框是空的，就收回成图标；有字就留着——人还在看搜出来的结果。
        .onChange(of: focused) { _, now in
            if !now, query.isEmpty { expanded = false }
        }
    }

    private func open() {
        expanded = true
        DispatchQueue.main.async { focused = true }
    }

    private func close() {
        query = ""
        expanded = false
        focused = false
    }
}

/// 「存为视图」/「更新视图」。
///
/// **已经有的视图不该被再创建一遍**。三种状态，三副样子：
///
///   没改过任何筛选            什么都不画——没东西可存
///   改了，但不在任何视图上     「存为视图…」，建一个新的
///   改了，而且正站在某个视图上  一个菜单：**更新它**，或者**另存为新的**
///
/// 第三种是关键：你在「进度看板」上顺手改了筛选，原来那颗按钮还是「存为视图…」，
/// 一按就又多一个视图——**同一个视图被创建两遍**。Linear 在这里给的也是
/// 「Save / Save as new」两条路。
private struct SaveViewButton: View {
    @ObservedObject var shell: KairosMacShell

    var body: some View {
        if let active = shell.activeViewOnDisk {
            // 正站在一个存过的视图上。**一模一样就什么都不画**——
            // 这些筛选本来就是这个视图存着的，再问一句「要不要存」是白问
            // （第一版漏了这个分支：点进视图之后按钮还杵在那儿）。
            if !shell.matches(active) {
                changedMenu(active)
            }
        } else if shell.hasSavableState {
            Button("存为视图…") {
                shell.editingViewID = nil
                shell.savingView = true
            }
            .buttonStyle(.plain)
            .font(.system(size: T.TypeScale.body))
            .foregroundStyle(.secondary)
            .help("把现在的筛选和显示存成一个视图，点一下就回到这个样子")
        }
    }

    /// 改动了的那副样子：更新它，或者另存为新的。
    private func changedMenu(_ active: KairosMacView) -> some View {
        Menu {
                Button("更新「\(active.name)」") {
                    guard let index = shell.views.firstIndex(where: { $0.id == active.id }) else { return }
                    var updated = shell.snapshotView(named: active.name, symbol: active.symbol)
                    updated.id = active.id
                    shell.views[index] = updated
                    // 更新完，现在的样子就等于这个视图了，边栏照旧亮着它。
                    shell.activeViewID = active.id
                }
                Button("另存为新视图…") {
                    // 存新的：把「正在改哪个」清掉，不然那张表单会变成「改视图」。
                    shell.editingViewID = nil
                    shell.savingView = true
                }
        } label: {
            Text("视图有改动")
                .font(.system(size: T.TypeScale.body))
        }
        .menuStyle(.button)
        .buttonStyle(.accessoryBar)
        .fixedSize()
        .help("把改动存回「\(active.name)」，或者另存成一个新视图")
    }
}

/// 日期后面那颗连接点。**只报状态，不挂动作**：写信、设置在菜单栏里都有（⇧⌘N、⌘,），
/// 这里不给第二份入口。
private struct BeingStatusPill: View {
    @ObservedObject var store: KairosStore

    var body: some View {
        // 名字不写：那是 connection.json 里的 name，实际显示的是人类自己的名字，
        // 跟在日期后面既没用也误导。
        //
        // **只画「不对劲」，不画「正在跑」。**
        // 刷新和发送时不转圈——那个圈是多余的：
        //   · 发消息  房间里本来就有「being 在想」那三个点，那才是你正看着的地方；
        //   · 刷新    读的是本地文件，快到看不见，转一下反而像出了什么事。
        // 一个一闪而过的转圈不传递任何你能据此做决定的信息，只是让顶上那一排抖一下。
        // **尺寸恒定、颜色可以透明**：占着 7×7，好的时候画成透明，布局不跳。
        Circle()
            .fill(needsAttention ? connectionColor : .clear)
            .frame(width: 7, height: 7)
            .help(store.connectionState.label)
        .accessibilityLabel(store.connectionState.label)
    }

    private var needsAttention: Bool { store.connectionNeedsAttention }

    private var connectionColor: Color {
        switch store.connectionState {
        case .online: .green
        case .checking, .configured: .secondary
        // 系统橙 → 自己的橙：一屏上那个饱和色只有一份数值。
        case .notConfigured, .offline: KairosMacPalette.attention
        }
    }
}

/// 顶上那两颗按钮的**分界线**（参考同类工具）：
///
///     ▽ 筛选   看**哪些**条目 —— 范围、优先级、状态、来源
///     ☰ 显示   **怎么**看     —— 列表/看板、分组、显示已了结、行上显示哪几样
///
/// **两边内容不许重复。** 原来顶上是一条「全部 / 待办 / 消息」的分段，
/// 外加一个什么都装的「显示」面板——范围在分段里、筛选也在面板里，
/// 一件事两个地方，分段整个撤掉，范围并进「筛选」。
///
/// 两颗都用 popover 面板，不用系统菜单。这条是老账：系统菜单里点一下 Toggle
/// **整份菜单当场关掉**，筛四个来源要开四次菜单，而且每次都看不见单子被筛成什么样。
/// 同类工具能用菜单是因为 Radix 的 checkbox item 可以拦住那次关闭，AppKit 的菜单拦不住。
/// 面板留在原地：勾几下、扫一眼后面的单子、再顺手关掉（Esc 或点别处）。

/// ▽ 筛选。筛着东西的时候图标变实心、后面带个数——不然人会忘了自己筛过，以为待办丢了。
private struct FilterMenu: View {
    @ObservedObject var store: KairosStore
    @ObservedObject var shell: KairosMacShell
    @State private var showing = false

    /// 一共筛着几样。范围也算——它现在是筛选的一部分。
    private var activeCount: Int {
        shell.filter.tiers.count + shell.filter.statuses.count + shell.filter.sources.count
            + (shell.filter.scope == .all ? 0 : 1)
    }

    var body: some View {
        Button {
            showing = true
        } label: {
            // 只有图形（字在 tooltip 里）。**两种状态同一个图形**，筛着东西时只换成橙色、
            // 后面带个数——不然人会忘了自己筛过，以为待办丢了。
            HeaderIcon(
                symbol: "line.3.horizontal.decrease",
                tint: activeCount > 0 ? KairosMacPalette.attention : .secondary,
                count: activeCount
            )
        }
        .help("筛选：优先级、状态")
        // 不写的话旁白念的是符号自带的名字「过滤」——界面上这件事叫「筛选」。
        .accessibilityLabel(activeCount > 0 ? "筛选，筛着 \(activeCount) 样" : "筛选")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            FilterPanel(store: store, shell: shell)
        }
    }
}

private struct FilterPanel: View {
    @ObservedObject var store: KairosStore
    @ObservedObject var shell: KairosMacShell

    private var hasAny: Bool { shell.filter.isActive }

    /// **只剩优先级和状态两段**。
    ///
    /// 撤掉的是「范围（全部 / 待办 / 消息）」和「来源（待办 / 信 / 篝火 / 炉火）」：
    /// 这两段都在回答同一个问题——「这一条是不是一封信」。而人类这天的裁决是
    /// **全部都归到待办**，信不再是另一类东西，那两段于是在筛一个界面上已经不存在的区分。
    var body: some View {
        VStack(alignment: .leading, spacing: T.Spacing.l) {
            PanelSection("优先级") {
                ChipRow {
                    ForEach(KairosMacTier.all, id: \.self) { tier in
                        FilterChip(title: tier, on: toggle(\.tiers, tier))
                    }
                }
            }
            PanelSection("状态") {
                ChipRow {
                    // 只列还开着的那三个。「已完结」是「显示」那边那个开关的事。
                    ForEach(KairosStatus.open, id: \.self) { status in
                        FilterChip(title: KairosStatus.label(status), on: toggle(\.statuses, status))
                    }
                }
            }
            if hasAny {
                Divider()
                Button("清除筛选") {
                    shell.filter.tiers = []
                    shell.filter.statuses = []
                    shell.filter.sources = []
                    shell.filter.scope = .all
                }
                .buttonStyle(.plain)
                .font(.system(size: T.TypeScale.body))
                .foregroundStyle(T.Ink.secondary)
            }
        }
        .padding(T.Spacing.l)
        .frame(width: 300)
    }

    private func toggle(_ keyPath: WritableKeyPath<KairosMacFilter, Set<String>>, _ value: String) -> Binding<Bool> {
        Binding(
            get: { shell.filter[keyPath: keyPath].contains(value) },
            set: { on in
                if on { shell.filter[keyPath: keyPath].insert(value) }
                else { shell.filter[keyPath: keyPath].remove(value) }
            }
        )
    }
}

/// ☰ 显示。只管「怎么看」，一条筛选都没有。
private struct DisplayMenu: View {
    @ObservedObject var shell: KairosMacShell
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            // ⋯，不带圈（HIG: "Prefer system-provided symbols without borders"）。
            // iOS 26 的提醒事项把「排序方式 / 显示完成项目」收在同样一颗 ⋯ 里。
            HeaderIcon(symbol: "ellipsis")
        }
        .help("显示方式：分组、显示已了结、行上显示哪几样")
        .accessibilityLabel("显示方式")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            DisplayPanel(shell: shell)
        }
    }
}

private struct DisplayPanel: View {
    @ObservedObject var shell: KairosMacShell

    var body: some View {
        VStack(alignment: .leading, spacing: T.Spacing.l) {
            VStack(spacing: T.Spacing.m) {
                SettingRow("分组") {
                    Picker("分组", selection: $shell.grouping) {
                        ForEach(KairosMacGrouping.allCases) { grouping in
                            Text(grouping.title).tag(grouping)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingRow("显示已了结") {
                    Toggle("显示已了结", isOn: $shell.showClosed)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
            }

            // 参考同类看板工具的「卡片属性」：一行上显不显示这几样。
            // 它们是显示的事，所以在这边，不在「筛选」里。
            PanelSection("行上显示") {
                ChipRow {
                    ForEach(Array(KairosMacRowProperties.all.enumerated()), id: \.offset) { _, entry in
                        FilterChip(title: entry.1, on: Binding(
                            get: { shell.rowProperties.contains(entry.0) },
                            set: { on in
                                if on { shell.rowProperties.insert(entry.0) }
                                else { shell.rowProperties.remove(entry.0) }
                            }
                        ))
                    }
                }
            }
        }
        .padding(T.Spacing.l)
        .frame(width: 300)
    }
}

// MARK: - 两块面板共用的排版

/// 一个小标题 + 它底下那块东西。整块面板只有这一种小标题。
private struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        // 小标题 11 灰、底下药丸 13 墨：两级字号 + 两级灰就分得开，小标题不用再半粗。
        VStack(alignment: .leading, spacing: T.Spacing.s) {
            Text(title)
                .font(.system(size: T.TypeScale.caption))
                .foregroundStyle(T.Ink.secondary)
            content
        }
    }
}

/// 一排会换行的药丸。**必须换行**：面板 300pt 宽，「来源」那四颗各带一个图标，
/// 一排放不下——`HStack` 只会把它们压扁（`FlowLayout` 在 KairosRoomView）。
private struct ChipRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        FlowLayout(spacing: T.Spacing.s) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 一行设置：左边名字撑开，右边控件靠右，两个控件的右边缘对齐。
private struct SettingRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack(spacing: T.Spacing.s) {
            Text(title)
                .font(.system(size: T.TypeScale.body))
                .foregroundStyle(T.Ink.primary)
            Spacer(minLength: T.Spacing.s)
            control
        }
        .frame(minHeight: 22)
    }
}

private struct FilterChip: View {
    let title: String
    var symbol: String? = nil
    @Binding var on: Bool

    var body: some View {
        Button {
            on.toggle()
        } label: {
            HStack(spacing: T.Spacing.xs) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: T.TypeScale.caption, weight: .medium))
                }
                Text(title)
            }
            .font(.system(size: T.TypeScale.body))
            // 开着的药丸：墨色实底 + 反白字。关着：浅灰底 + 灰字。没有第三种颜色。
            // 开 / 关已经是「实底 vs 浅面」这么大的差，字不需要再加粗。
            .foregroundStyle(on ? KairosMacPalette.onDone : T.Ink.secondary)
            .padding(.horizontal, T.Spacing.s)
            .padding(.vertical, T.Spacing.xs)
            .background(on ? KairosMacPalette.doneFill : T.Ink.fill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

/// 存视图：就一个名字。
/// 存视图 / 改视图 —— **同一张表单**。
///
/// 这条参考同类工具的对话框设计：新建和编辑走同一个对话框，
/// 只是打底的来源不同（新建用当前面板的状态，编辑用那个视图自己的定义）。
/// 两个入口各写一张表单是重复，而且迟早长歪。
///
/// 名字和图标都是人自己定的、随时能改的东西 —— 它们和整份视图一起落在账本文件夹的
/// `views.json` 里，**不进账本、不进 being 协议**（完全是使用者自己的东西）。
private struct SaveViewSheet: View {
    @ObservedObject var shell: KairosMacShell
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var symbol = KairosMacView.defaultSymbol
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var editing: KairosMacView? {
        shell.editingViewID.flatMap { id in shell.views.first { $0.id == id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: T.Spacing.l) {
            Text(editing == nil ? "存为视图" : "改视图")
                .font(.system(size: T.TypeScale.headline, weight: .semibold))

            HStack(spacing: T.Spacing.s) {
                SymbolPicker(symbol: $symbol)
                TextField("名字", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(save)
            }

            if editing == nil {
                Text("把现在的筛选和显示存下来，点一下就回到这个样子。")
                    .font(.system(size: T.TypeScale.caption))
                    .foregroundStyle(T.Ink.secondary)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(editing == nil ? "存" : "好", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(T.Spacing.xl)
        .frame(width: 420)
        .onAppear {
            if let editing {
                name = editing.name
                symbol = editing.symbol
            }
            focused = true
        }
        // 表单一关就清掉，不然下次点「存为视图」会莫名其妙变成「改视图」。
        .onDisappear { shell.editingViewID = nil }
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        if let editing, let index = shell.views.firstIndex(where: { $0.id == editing.id }) {
            // 改的只是名字和图标，**不动这个视图存的那套设置**——
            // 要换设置有「用现在的样子覆盖」那一项，两件事别混。
            shell.views[index].name = trimmed
            shell.views[index].symbol = symbol
        } else {
            let view = shell.snapshotView(named: trimmed, symbol: symbol)
            shell.views.append(view)
            // 刚存下来的这个就是你现在站的地方，边栏直接亮它。
            shell.activeViewID = view.id
        }
        dismiss()
    }
}

/// 挑一个图标：一颗按钮弹一个网格。**不做全量 SF Symbols 浏览器**——
/// 十几个候选够用，挑图标不该变成一件要花时间的事。
private struct SymbolPicker: View {
    @Binding var symbol: String
    @State private var showing = false

    private let columns = Array(repeating: GridItem(.fixed(28), spacing: T.Spacing.s), count: 8)

    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: symbol)
                .font(.system(size: T.TypeScale.body))
                .frame(width: 34, height: 22)
        }
        .buttonStyle(.bordered)
        .help("换个图标")
        .accessibilityLabel("图标")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            LazyVGrid(columns: columns, spacing: T.Spacing.s) {
                ForEach(KairosMacView.symbolChoices, id: \.self) { choice in
                    Button {
                        symbol = choice
                        showing = false
                    } label: {
                        Image(systemName: choice)
                            .font(.system(size: T.TypeScale.body))
                            .frame(width: 28, height: 28)
                            .background(
                                choice == symbol ? KairosMacPalette.selection : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(T.Spacing.m)
            .frame(width: 304)
        }
    }
}

// MARK: - 边栏：项目

/// 「全部」+ 自己建的项目。项目能接住拖过来的待办（看板里的卡）。
private struct ProjectSidebar: View {
    @ObservedObject var store: KairosStore
    @ObservedObject var shell: KairosMacShell

    var body: some View {
        List(selection: selectionBinding) {
            AllItemsRow(store: store)
                .tag(KairosSidebarTag.all)

            Section {
                ForEach(store.macSidebarProjects(showClosed: shell.showClosed), id: \.self) { project in
                    ProjectRow(store: store, shell: shell, project: project)
                        .tag(project)
                }
            } header: {
                // 「+」就在「项目」这一行的右边：建的是项目，按钮就长在项目这一段上，
                // 不用跑到窗口底下去找。
                HStack(spacing: 4) {
                    Text("项目")
                    Spacer(minLength: 4)
                    Button {
                        shell.creatingProject = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: T.TypeScale.caption, weight: .semibold))
                            .frame(width: 18, height: 18)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("新建项目（⌥⌘N）")
                    .accessibilityLabel("新建项目")
                }
            }

            if !shell.views.isEmpty {
                Section("视图") {
                    ForEach(shell.views) { view in
                        Label(view.name, systemImage: view.symbol)
                            .foregroundStyle(.primary)
                            .tag(KairosSidebarTag.view(view.id))
                            .contextMenu {
                                Button("改名字和图标…", systemImage: "pencil") {
                                    shell.editingViewID = view.id
                                    shell.savingView = true
                                }
                                Button("用现在的样子覆盖", systemImage: "arrow.down.doc") {
                                    if let index = shell.views.firstIndex(where: { $0.id == view.id }) {
                                        var updated = shell.snapshotView(named: view.name, symbol: view.symbol)
                                        updated.id = view.id
                                        shell.views[index] = updated
                                    }
                                }
                                Button("删除视图", systemImage: "trash", role: .destructive) {
                                    shell.views.removeAll { $0.id == view.id }
                                    // 删掉的正好是亮着的那个 → 熄掉，不然边栏指着一个不存在的 id。
                                    if shell.activeViewID == view.id { shell.activeViewID = nil }
                                }
                            }
                    }
                    // 视图是本机的显示设置（存在 UserDefaults 里），顺序也归本机。
                    .onMove { offsets, destination in
                        shell.views.move(fromOffsets: offsets, toOffset: destination)
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(
            min: KairosMacLayout.sidebarMinWidth,
            ideal: KairosMacLayout.sidebarIdealWidth,
            max: KairosMacLayout.sidebarMaxWidth
        )
        .toolbar(removing: .sidebarToggle)
        // 和单子同一个理由：系统设置是「总是显示滚动条」，项目一多边栏右边就是一根带轨道的粗条。
        .scrollIndicators(.never)
        // 往下让 10pt：红绿灯那一排之下，三栏的第一行落在同一条水平线上——
        // 这里的「全部」、单子的第一个段头、右侧房间的标题。
        // 用 safeAreaInset 不用 contentMargins：边栏样式的 List 在 macOS 上不认后者。
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 10) }
        // **边栏只放「去哪儿」，不放动作**。顶上那一行撤了：
        // 「新建」搬到单子头上那颗橙色 +（`NewItemButton`，⌘N 同一件事）。
        // 剩下的就是全部 / 项目 / 视图三段，加底下一颗设置——一列纯粹的去处。
        .safeAreaInset(edge: .bottom) { footer }
    }

    /// 边栏底下这一格**只放设置**。
    ///
    /// 「新建」「新建项目」都上顶上去了——常用的动作放在手够得着的地方，
    /// 窗口底下那一格留给一年点两次的东西。
    private var footer: some View {
        HStack {
            SettingsLink {
                // 边栏是玻璃：留系统 .secondary（走 vibrancy），不换 Ink。
                Label("设置", systemImage: "gearshape")
                    .font(.system(size: T.TypeScale.body))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("设置（⌘,）")
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// 亮哪一行：点中的那个视图（`shell.activeView`），否则是项目或「全部」。
    private var selectionBinding: Binding<String?> {
        Binding(
            get: {
                if let view = shell.activeView { return KairosSidebarTag.view(view.id) }
                return shell.selectedProject ?? KairosSidebarTag.all
            },
            set: { tag in
                guard let tag else { return }
                if let id = KairosSidebarTag.viewID(tag) {
                    guard let view = shell.views.first(where: { $0.id == id }) else { return }
                    shell.activeViewID = id
                    shell.apply(view)
                } else {
                    // 点「全部」或某个项目 = **离开视图，并且回到默认**
                    // （切回全部，应该就是全部、是默认。）
                    // 原来只熄掉视图、清掉项目，上一个视图的筛选和分组会**留在身上**——
                    // 于是「全部」里看到的不是全部，而是上一个视图筛剩下的那些。
                    // `resetToDefaults` 里已经把 activeViewID 熄了，所以那个 bug 照旧是修着的。
                    shell.resetToDefaults()
                    if tag != KairosSidebarTag.all { shell.selectedProject = tag }
                }
            }
        )
    }
}

/// 边栏第一行。也是个落点：把待办拖到「全部」= 把它从项目里拿出来。
/// 有拖进项目就得有拖出来，不然进得去出不来，只能回右键菜单里找「项目 › 无」。
private struct AllItemsRow: View {
    @ObservedObject var store: KairosStore
    @State private var targeted = false

    var body: some View {
        Label("全部", systemImage: "tray.full")
            .foregroundStyle(.primary)
            .badge(store.macOpenCount(in: nil))
            .background(targeted ? KairosMacPalette.selection : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .dropDestination(for: KairosItemDragPayload.self) { payloads, _ in
                let ids = payloads.flatMap(\.itemIDs)
                guard !ids.isEmpty else { return false }
                store.macSetProject(ids, to: "")
                return true
            } isTargeted: { targeted = $0 }
            .animation(T.Motion.feedback, value: targeted)
    }
}

private struct ProjectRow: View {
    @ObservedObject var store: KairosStore
    @ObservedObject var shell: KairosMacShell
    let project: String
    /// 待办被拖到这一行上（= 换项目），整行亮。
    @State private var targeted = false
    /// 别的项目被拖到这一行上（= 插到我前面），画一条线，不整行亮——
    /// 两种拖拽落下去是两件事，反馈就不能长一个样。
    @State private var reordering = false

    var body: some View {
        Label(project, systemImage: store.macProjectSymbol(project))
            .foregroundStyle(.primary)
            .badge(store.macOpenCount(in: project))
            .background(targeted ? KairosMacPalette.selection : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .top) {
                if reordering {
                    Capsule()
                        .fill(T.Ink.secondary)
                        .frame(height: 2)
                        .offset(y: -3)
                }
            }
            .draggable(KairosProjectDragPayload(name: project)) {
                Label(project, systemImage: "folder")
                    .font(.system(size: T.TypeScale.body))
                    .padding(.horizontal, T.Spacing.m)
                    .padding(.vertical, T.Spacing.s)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            .dropDestination(for: KairosProjectDragPayload.self) { payloads, _ in
                guard let moved = payloads.first?.name, moved != project else { return false }
                var names = store.macProjects
                guard let from = names.firstIndex(of: moved) else { return false }
                names.remove(at: from)
                guard let to = names.firstIndex(of: project) else { return false }
                names.insert(moved, at: to)
                withAnimation(T.Motion.weighted) { store.macReorderProjects(names) }
                return true
            } isTargeted: { reordering = $0 }
            .dropDestination(for: KairosItemDragPayload.self) { payloads, _ in
                let ids = payloads.flatMap(\.itemIDs)
                guard !ids.isEmpty else { return false }
                store.macSetProject(ids, to: project)
                return true
            } isTargeted: { targeted = $0 }
            .animation(T.Motion.feedback, value: targeted)
            .animation(T.Motion.feedback, value: reordering)
            .contextMenu {
                // 只改图标，不改名字：项目名同时写在每条事项的 `project` 字段上，
                // 重命名要把所有条目一起改，那是一次数据迁移，不是一个菜单项。
                Menu("改图标", systemImage: "pencil") {
                    ForEach(KairosMacView.symbolChoices, id: \.self) { choice in
                        Button {
                            store.macSetProjectSymbol(project, to: choice)
                        } label: {
                            Label(choice, systemImage: choice)
                        }
                    }
                }
                Button("删除项目…", systemImage: "trash", role: .destructive) {
                    store.macDeleteProject(project)
                    if shell.selectedProject == project { shell.selectedProject = nil }
                }
            }
    }
}

/// 新建项目：就一个名字。图标颜色之类的先不要。
private struct NewProjectSheet: View {
    @ObservedObject var store: KairosStore
    @ObservedObject var shell: KairosMacShell
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var symbol = "folder"
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: T.Spacing.l) {
            Text("新项目").font(.system(size: T.TypeScale.headline, weight: .semibold))
            HStack(spacing: T.Spacing.s) {
                SymbolPicker(symbol: $symbol)
                TextField("名字", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(add)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("建立", action: add)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(T.Spacing.xl)
        .frame(width: 380)
        .onAppear { focused = true }
    }

    private func add() {
        guard !trimmed.isEmpty else { return }
        store.macAddProject(trimmed, symbol: symbol)
        shell.selectedProject = trimmed
        dismiss()
    }
}

// MARK: - 主屏：一张单子，列表或看板

/// 分组是显示层的事：优先级 P0–P3、状态（进行中 / 未开始 / 待定）、或者不分；已了结单独一组。
/// 列表和看板用同一份分组结果，看板的一列就是一组。
struct KairosMacGroup: Identifiable {
    enum Key: Hashable {
        case tier(String)
        case status(String)
        case open
        case closed
    }

    let key: Key
    let title: String
    let color: Color
    /// **单子上只有一种行**：一行就是一条 item（`KairosItem`），消息只是**带对方**
    /// 的那种（`KairosMessageRow`）。人类的第一条是「所有行必须一样，有一种行不能勾，
    /// 肌肉记忆就断了」。
    let rows: [KairosItem]

    var id: Key { key }
    var isClosed: Bool { key == .closed }
    var items: [KairosItem] { rows }
    var count: Int { rows.count }
}

private struct MainScreen: View {
    @ObservedObject var store: KairosStore
    @ObservedObject var shell: KairosMacShell
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isSearching: Bool {
        !store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if isSearching {
                SearchResultsList(store: store, shell: shell)
            } else {
                GroupedList(store: store, shell: shell)
            }
        }
        // **列表不画滚动条。** 这台机器的「显示滚动条」是「总是」（系统设置里选的），
        // 于是每个 app 都挂着一根带轨道的粗滚动条——单子右边那根把列和右侧面板之间
        // 生生劈出一道杠。
        // `ScrollerTamer` 想把它改成 overlay 细滚动条，但系统那个「总是」会把它改回去；
        // `.scrollIndicators(.never)` 是 SwiftUI 层的开关，系统设置覆盖不了。
        // 一张几十行的单子不需要位置指示，滚到哪儿看内容就知道。
        .scrollIndicators(.never)
        .overlay(alignment: .top) { ToolbarScrim() }
        // 记一条的输入框**长在单子最上面**，日期正下方，不在窗口最底下：
        // 眼睛是从左上角的日期开始读的，一个每天用十几次的动作不能放在视线最后才扫到的角落。
        // 左右让出 30pt，和底下每一行的圆圈、选中底对齐——它长得就是「将要多出来的那一行」。
        .safeAreaInset(edge: .top, spacing: 0) {
            if shell.composing {
                CaptureBar(store: store, shell: shell)
                    .padding(.horizontal, 30)
                    .padding(.top, T.Spacing.xs)
                    .padding(.bottom, T.Spacing.xs)
                    // 落笔（Motion.write）：从纸面浮起 y+8→0、scale 0.98→1，不从顶上整块滑下来。
                    .transition(reduceMotion ? .opacity : .offset(y: 8).combined(with: .scale(scale: 0.98)).combined(with: .opacity))
            }
        }
        .animation(T.Motion.reduced(T.Motion.enter, reduceMotion), value: shell.composing)
        .toolbar { toolbar }
        .background(ScrollerTamer())
        // Esc：先收输入行，再收右侧。
        .onExitCommand {
            if shell.inspectorShown { shell.closeInspector(store) }
        }
        .overlay(alignment: .bottom) {
            if let notice = store.undoNotice {
                UndoCapsule(notice: notice, store: store)
                    .padding(.horizontal, T.Spacing.l)
                    .padding(.bottom, T.Spacing.l)
                    // 进场 easeOut、退场 easeIn，不再一个节奏来回。
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity).animation(T.Motion.easeOut),
                        removal: .move(edge: .bottom).combined(with: .opacity).animation(T.Motion.easeIn)
                    ))
            }
        }
        .animation(T.Motion.reduced(T.Motion.easeOut, reduceMotion), value: store.undoNotice)
    }

    /// 单子这一栏的工具栏：**左边日期，右边一组安静的图标和一颗橙色的 +**——它就是窗口的顶。
    ///
    /// 日期和按钮原来垫在单子上面自己的一块头里，和工具栏叠成两条带子；现在它们就是工具栏本身，
    /// 和左边的红绿灯、右侧的「收起」站在同一排。
    ///
    /// 按使用频次排：这一屏真正高频的只有扫单子、点开一条、勾掉一条、记一条新的。
    /// 搜索、筛选、显示方式一天碰不了几次，缩成一组灰的图标（系统给它们一块玻璃底），
    /// 要用时才展开。「打开右侧」不在这儿：右侧只在点开一条时出现，没选中时没有东西可开。
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            DayHeader(store: store, project: shell.selectedProject)
        }
        // 日期是字，不是按钮：不垫玻璃。
        .sharedBackgroundVisibility(.hidden)

        ToolbarSpacer(.flexible)

        ToolbarItemGroup {
            SaveViewButton(shell: shell)
            MacSearchField(query: $store.query, shell: shell)
            FilterMenu(store: store, shell: shell)
            DisplayMenu(shell: shell)
        }

        ToolbarItem {
            NewItemButton(shell: shell, store: store)
        }
        // 它自己就是一颗实心的圆，再垫一层玻璃就是圆里套圆。
        .sharedBackgroundVisibility(.hidden)
    }
}

/// 顶上那一排：今天几号、星期几；选了项目就写项目名。像手机那样。
///
/// being 连不上时日期后面跟一颗小点（`BeingStatusPill`）。**长在日期这一项里，不单开一项**：
/// macOS 26 会给工具栏的每一项配底和分隔，好的时候那一项就是一格空气——
/// 分隔是那一项画的，不是那个视图画的，只有这一项根本不存在才干净。
private struct DayHeader: View {
    @ObservedObject var store: KairosStore
    let project: String?

    var body: some View {
        // 日期是这一屏的主角：展示档（23）半粗，后面的星期退到 headline（16）+ 系统灰——
        // 两者差两档（1.44 倍），不用 bold 再撑。数字等宽，换日子时日期那一块宽度不跳。
        // 工具栏是玻璃：灰字留系统 .secondary。
        HStack(alignment: .center, spacing: T.Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: T.Spacing.s) {
                if let project {
                    Text(project)
                        .font(.system(size: T.TypeScale.display, weight: .semibold))
                    Text(Self.formatted("MMMd") + " " + Self.formatted("EEEE"))
                        .font(.system(size: T.TypeScale.headline).monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text(Self.formatted("MMMd"))
                        .font(.system(size: T.TypeScale.display, weight: .semibold).monospacedDigit())
                    Text(Self.formatted("EEEE"))
                        .font(.system(size: T.TypeScale.headline))
                        .foregroundStyle(.secondary)
                }
            }
            if store.connectionNeedsAttention {
                BeingStatusPill(store: store)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private static func formatted(_ template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans")
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: Date())
    }
}

/// 记东西的地方：**头上那颗橙色 + 点开，出现在日期下面**，而且**只做记东西这一件事**。
///
/// （它先是右侧一整块面板，后来是窗口最底下常驻的一行——那一版人类第一眼没看到。
/// 眼睛从左上角的日期开始读，最高频的动作不能放在视线最后才扫到的角落。）
///
/// 它上一版一句话两个出口：回车记成待办、⌘回车「问 being」，问完右侧开出一块桌面对话。
/// 右边的和 being 对话，处理的还是不好——毛病在结构上，不在样子上：
///
///   · **同一个框两种意图**。人每打一个字之前都得先想「我这是在记，还是在问」，
///     而这一行存在的全部理由就是「想到什么直接打，不用想」。
///   · **两个聊天的地方**。点开一条待办，右侧本来就是和 being 聊**这件事**的房间；
///     再加一块不绑任何事的桌面对话，同一个 being 在一个窗口里有两个入口、两份记录。
///   · **和 loom 撞了**。不绑具体事情的闲聊，loom 就是干这个的（设计哲学里那张表：
///     loom = 对讲机，看板 = 仪表盘）。看板里再长一个对讲机，是重复。
///
/// 所以撤掉。想问 being 一件事：**记成一条，点开它，在它的房间里问**——
/// 这正是 Kairos 的方式（「想到什么就是一条事项」），问完这件事也有了归宿，不会散在一段闲聊里。
struct CaptureBar: View {
    @ObservedObject var store: KairosStore
    @ObservedObject var shell: KairosMacShell

    @State private var draft = ""
    /// 刚记下的那条，显示两秒。
    @State private var justAdded: String?
    @FocusState private var focused: Bool

    /// 保留键。真待办的房间键是它自己的 id（UUID），撞不上。
    private static let draftKey = "new"

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 打了一半的这句**要留住**，关了窗口再开还在（和房间那一处同一套）。
    private var draftBinding: Binding<String> {
        Binding(
            get: { draft },
            set: { value in
                draft = value
                store.setRoomDraft(value, for: Self.draftKey)
            }
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            StatusGlyph(status: KairosStatus.todo, closed: false)
                .opacity(0.45)
            TextField("记一条，回车记下", text: draftBinding)
                .textFieldStyle(.plain)
                .font(.system(size: T.TypeScale.body))
                .focused($focused)
                .onSubmit(add)
                // Esc：收起。打了一半的字留在草稿里，下次打开还在。
                .onExitCommand { close() }
            // 没有按钮：回车就是记。打了字之后右边淡淡提示一句，记下之后换成确认。
            // 一行里不放按钮，这一行空着的时候才真的是「一行灰提示」，不占视觉。
            if let justAdded {
                Text("已记下：\(justAdded)")
                    .font(.system(size: T.TypeScale.caption))
                    .foregroundStyle(T.Ink.secondary)
                    .lineLimit(1)
                    .transition(.opacity)
            } else if !trimmed.isEmpty {
                Text("↩︎ 记下")
                    .font(.system(size: T.TypeScale.caption))
                    .foregroundStyle(T.Ink.tertiary)
                    .transition(.opacity)
            }
        }
        // 左右 10：和 `ItemRow` 同一个内边距，圆圈正好落在底下每一行圆圈的那一竖列上。
        .padding(.horizontal, 10)
        .padding(.vertical, T.Spacing.s)
        // 输入框和房间 / 信的输入框同一档面（Ink.fill）：「能往里打字的地方」长一个样。
        .background(T.Ink.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(T.Motion.feedback, value: trimmed.isEmpty)
        .animation(T.Motion.feedback, value: justAdded)
        .onAppear {
            draft = store.roomDraft(Self.draftKey)
            // 出来就要光标：点 + 的意思就是「我要打字了」。
            DispatchQueue.main.async { focused = true }
        }
        // 已经开着时再按一次 + / ⌘N：把光标要回来。
        .onChange(of: shell.composeTick) { focused = true }
        // 点到别处、框是空的 → 收起；有字就留着，别把人打了一半的东西收走。
        .onChange(of: focused) { _, now in
            if !now, trimmed.isEmpty, justAdded == nil { close() }
        }
        .task(id: justAdded) {
            guard justAdded != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            justAdded = nil
            // 记完一条就点到别处去了：失焦那一刻「已记下」还亮着所以没收，
            // 两秒后确认消失，框空着、光标也不在——这时候再不收，它就永远杵在日期下面。
            if !focused, trimmed.isEmpty { close() }
        }
    }

    private func close() {
        focused = false
        shell.composing = false
    }

    private func add() {
        guard !trimmed.isEmpty else { return }
        let title = trimmed
        store.createItem(title: title, tier: "P2", project: shell.selectedProject ?? "")
        draft = ""
        store.setRoomDraft("", for: Self.draftKey)
        justAdded = title
        // 光标不走，接着打下一条。
        focused = true
    }
}

/// 列表：日期一行，然后每组一段；一行一条，长得一模一样，信靠信封图标认。
/// 同一段里能拖着排（只排待办）；换段走右键菜单。
private struct GroupedList: View {
    @ObservedObject var store: KairosStore
    @ObservedObject var shell: KairosMacShell

    var body: some View {
        let groups = store.macGroups(
            grouping: shell.grouping,
            showClosed: shell.showClosed,
            filter: shell.filter
        )
        List(selection: store.macSelectionBinding(shell)) {
            ForEach(groups) { group in
                Section {
                    rows(group)
                } header: {
                    GroupDropHeader(store: store, group: group)
                }
            }
        }
        .listStyle(.inset)
        // 系统自己的选中高亮每次都要关一遍：挂在这一层，选中一变这一层就重画、`ScrollerTamer`
        // 就重新跑。只挂在外面 `MainScreen` 上时，列表被重建（换项目、搜完回来）之后
        // 系统高亮会回来，点一行先闪一块系统色再换成我们自己的底——那就是「点一下先灰一下」的另一种来源。
        .background(ScrollerTamer())
        .overlay {
            if groups.allSatisfy({ $0.rows.isEmpty }) {
                Text(shell.filter.isActive ? "没有符合的事项" : "没有待办")
                    .font(.system(size: T.TypeScale.body))
                    .foregroundStyle(T.Ink.secondary)
            }
        }
        .animation(T.Motion.weighted, value: groups.map { $0.rows.map(\.id) })
    }

    @ViewBuilder
    private func rows(_ group: KairosMacGroup) -> some View {
        ForEach(group.rows) { item in
            DraggableItemRow(store: store, shell: shell, item: item, group: group)
                .tag(item.id)
                .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
                .listRowSeparator(.hidden)
        }
    }
}

/// 列表里的一行待办：能被拖走，也能被拖到它前面插进来。
///
/// 以前这里用的是 `List` 的 `.onMove`——只能在同一段里上下挪，**拖不出列表**：
/// 拖到边栏的项目上什么也不会发生，那是看板卡才有的本事。同一个动作在两个视图里
/// 能力不一样，人只会记住「拖拽不好使」。现在两边同一套：`.draggable` + 落点，
/// 落到哪儿由落点自己说了算（换项目 / 换段 / 排序），换段那一下 `macDrop` 早就写好了。
private struct DraggableItemRow: View {
    @ObservedObject var store: KairosStore
    @ObservedObject var shell: KairosMacShell
    let item: KairosItem
    let group: KairosMacGroup
    @State private var targeted = false

    var body: some View {
        ItemRow(
            store: store,
            item: item,
            showsProject: shell.selectedProject == nil,
            showsClosedTag: false
        )
        // 拖起来的那几条在原位变淡：这条正在被挪走，不是被复制。
        .opacity(shell.draggingIDs.contains(item.id) ? 0.35 : 1)
        .overlay(alignment: .top) {
            InsertionLine().opacity(targeted ? 1 : 0)
        }
        .draggable(beginDrag()) {
            DragPreview(count: store.macDragIDs(item).count, title: item.title)
        }
        .dropDestination(for: KairosItemDragPayload.self) { payloads, _ in
            let ids = payloads.flatMap(\.itemIDs).filter { $0 != item.id }
            shell.endDrag()
            guard !ids.isEmpty else { return false }
            store.macDrop(ids, into: group, before: item.id)
            return true
        } isTargeted: { targeted = $0 }
        .animation(T.Motion.feedback, value: targeted)
        .animation(T.Motion.feedback, value: shell.draggingIDs)
        .contextMenu {
            ItemMenuContent(store: store, item: item, groupKey: group.isClosed ? nil : group.key)
        }
    }

    /// `.draggable` 的第一个参数是 autoclosure —— 真正开始拖的那一刻才求值，
    /// 所以在这里记下「谁在被拖」是安全的，不会在每次 body 求值时乱设状态。
    private func beginDrag() -> KairosItemDragPayload {
        let ids = store.macDragIDs(item)
        shell.beginDrag(ids)
        return KairosItemDragPayload(itemIDs: ids)
    }
}

/// 落点提示：一条线加一个圆头，缩进到和标题对齐。
///
/// 原来是一条贴着行上沿的 2pt 光杆——太细，而且分不清它说的是「插在这一行上面」
/// 还是「这一行被选中了」。加个圆头就有了方向感，是 Linear 那类工具的做法。
private struct InsertionLine: View {
    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(T.Ink.secondary)
                .frame(width: 6, height: 6)
            Rectangle()
                .fill(T.Ink.secondary)
                .frame(height: 2)
        }
        .padding(.leading, 8)
        .offset(y: -3)
    }
}

/// 拖着走的时候手上那块东西。多选拖就说清楚是几条——拖着一张写着某一条标题的卡片
/// 却动了五条，是最容易让人误操作的一种「省事」。
private struct DragPreview: View {
    let count: Int
    let title: String

    var body: some View {
        Text(count > 1 ? "\(count) 条" : title)
            .font(.system(size: T.TypeScale.body).monospacedDigit())
            .lineLimit(2)
            .padding(.horizontal, T.Spacing.m)
            .padding(.vertical, T.Spacing.s)
            .frame(maxWidth: 280)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 段头也是落点：拖到「P1」「进行中」「已完结」那一行上 = 进这一段的末尾。
/// 列表视图里换优先级 / 换状态 / 了结，以前只能走右键菜单或者切到看板。
private struct GroupDropHeader: View {
    @ObservedObject var store: KairosStore
    let group: KairosMacGroup
    @EnvironmentObject private var shell: KairosMacShell
    @State private var targeted = false

    var body: some View {
        GroupSignpost(group: group)
            .background(
                targeted ? KairosMacPalette.selection : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .dropDestination(for: KairosItemDragPayload.self) { payloads, _ in
                let ids = payloads.flatMap(\.itemIDs)
                shell.endDrag()
                guard !ids.isEmpty else { return false }
                store.macDrop(ids, into: group, before: nil)
                return true
            } isTargeted: { targeted = $0 }
            .animation(T.Motion.feedback, value: targeted)
    }
}

/// 搜索时跨所有状态找，不分组、不筛；已了结的行尾标一下。信也搜（人名和内容）。
private struct SearchResultsList: View {
    @ObservedObject var store: KairosStore
    @ObservedObject var shell: KairosMacShell

    var body: some View {
        let items = store.searchAllStates(store.query).filter { shell.filter.allows(source: $0.source) }
        List(selection: store.macSelectionBinding(shell)) {
            ForEach(items) { item in
                ItemRow(store: store, item: item, showsProject: true, showsClosedTag: true)
                    .tag(item.id)
                    .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
                    .listRowSeparator(.hidden)
                    .contextMenu { ItemMenuContent(store: store, item: item, groupKey: nil) }
            }
        }
        .listStyle(.inset)
        .overlay {
            if items.isEmpty {
                Text("没搜到「\(store.query)」")
                    .font(.system(size: T.TypeScale.body))
                    .foregroundStyle(T.Ink.secondary)
            }
        }
    }
}

/// 段头：组名 + 条数，系统的段头样式；前面可以带一颗颜色点。
struct SectionSignpost: View {
    let title: String
    let count: Int
    let dot: Color?

    var body: some View {
        // 段头 = 行标题同一字号（13）+ 灰一档 + medium。原来是 subheadline（11）半粗：
        // 比行里的副行还小，却靠加粗压过行标题——层级是反的。现在它和行标题一样大，
        // 靠「灰 + 上方留白 + 颜色点」认出来是段头，medium 只留一点分量防止和副行混。
        HStack(spacing: T.Spacing.s) {
            if let dot {
                Circle()
                    .fill(dot)
                    .frame(width: 6, height: 6)
            }
            Text(title)
            Text("\(count)")
                .monospacedDigit()
                .foregroundStyle(T.Ink.tertiary)
        }
        .font(.system(size: T.TypeScale.body, weight: .medium))
        .foregroundStyle(T.Ink.secondary)
        .padding(.leading, 6)
        // 顶上 xs 不加大：第一个段头和边栏「全部」、右侧标题站在同一条水平线上（见 `ProjectSidebar`）。
        .padding(.top, T.Spacing.xs)
    }
}

private struct GroupSignpost: View {
    let group: KairosMacGroup

    @ViewBuilder
    var body: some View {
        if group.title.isEmpty {
            // 不分组：没有段头这回事。
            EmptyView()
        } else if case .tier = group.key {
            SectionSignpost(title: group.title, count: group.count, dot: group.color)
        } else {
            SectionSignpost(title: group.title, count: group.count, dot: nil)
        }
    }
}

/// 右键菜单：优先级、状态、项目、同段上下移、了结 / 重新打开、编辑、删除。
/// 说球权的话一句没有——要 being 管，进房间说一句就是了。
///
/// **选中一批之后右键其中一条，改的是这一批**（`macTargetIDs`）。只选中一条时它就退化成
/// 一条，和以前一模一样。多选本来只能用来拖，现在菜单也跟上了——不然「选 8 条一起改 P1」
/// 还是得点 8 次。菜单标题会把条数说出来，免得误伤。
/// 「编辑…」和上下移是单条的事（一次只能编一份字、排序也只对一条有意义），保持单条。
private struct ItemMenuContent: View {
    @ObservedObject var store: KairosStore
    let item: KairosItem
    /// 在哪一组里；nil = 这儿不能排序（搜索结果、已了结）。
    let groupKey: KairosMacGroup.Key?
    @EnvironmentObject private var shell: KairosMacShell

    /// 这次动的是哪几条。
    private var targets: [String] { store.macTargetIDs(item) }
    private var batch: Bool { targets.count > 1 }
    /// 「优先级」→「优先级（5 条）」。
    private func title(_ base: String) -> String {
        batch ? "\(base)（\(targets.count) 条）" : base
    }

    var body: some View {
        Menu(title("优先级"), systemImage: "flag") {
            ForEach(KairosMacTier.all, id: \.self) { value in
                Button {
                    store.macApply(targets, to: .tier(value))
                } label: {
                    // 一批里档位不一致时不打勾——打了就是在说「这批都是 P1」，那是假话。
                    if !batch, KairosMacTier.normalized(item.tier) == value {
                        Label(value, systemImage: "checkmark")
                    } else {
                        Text(value)
                    }
                }
            }
        }
        Menu(title("状态"), systemImage: "circle.lefthalf.filled") {
            // 只列还开着的那三个。「已完结」由下面「了结」那一项管——
            // 摆进来等于同一件事开两个入口。
            ForEach(KairosStatus.open, id: \.self) { value in
                Button {
                    store.macApply(targets, to: .status(value))
                } label: {
                    if !batch, KairosStatus.normalized(item.status) == value {
                        Label(KairosStatus.label(value), systemImage: "checkmark")
                    } else {
                        Text(KairosStatus.label(value))
                    }
                }
            }
        }
        ProjectPickerMenu(store: store, item: item, targets: targets, batch: batch)
        if let groupKey, !batch {
            Button("上移", systemImage: "arrow.up") { store.macMove(item, by: -1, in: groupKey, filter: shell.filter) }
            Button("下移", systemImage: "arrow.down") { store.macMove(item, by: 1, in: groupKey, filter: shell.filter) }
        }
        Divider()
        if item.isClosed {
            Button(title("重新打开"), systemImage: "arrow.uturn.backward") {
                store.macApply(targets, to: .open)
            }
        } else {
            Button(title("了结"), systemImage: "checkmark.circle") {
                store.macApply(targets, to: .closed)
            }
        }
        if !batch {
            Button("编辑…", systemImage: "square.and.pencil") { store.editingItem = item }
        }
        Divider()
        Button(title("删除") + "…", systemImage: "trash", role: .destructive) {
            shell.pendingDeleteIDs = targets
        }
    }
}

/// 「项目」子菜单：已有的项目 + 无。房间的胶囊和右键菜单共用。
struct ProjectPickerMenu: View {
    @ObservedObject var store: KairosStore
    let item: KairosItem
    /// 动哪几条。不传就是这一条——房间抬头那颗胶囊永远只管它自己那条。
    var targets: [String]? = nil
    /// 是不是一批。一批里项目不一致时不打勾：打了就是在说「这批都在某某项目里」。
    var batch = false

    private var ids: [String] { targets ?? [item.id] }

    var body: some View {
        Menu(batch ? "项目（\(ids.count) 条）" : "项目", systemImage: "folder") {
            Button {
                store.macSetProject(ids, to: "")
            } label: {
                if !batch, item.project.isEmpty {
                    Label("无", systemImage: "checkmark")
                } else {
                    Text("无")
                }
            }
            if !store.macProjects.isEmpty { Divider() }
            ForEach(store.macProjects, id: \.self) { project in
                Button {
                    store.macSetProject(ids, to: project)
                } label: {
                    if !batch, item.project == project {
                        Label(project, systemImage: "checkmark")
                    } else {
                        Text(project)
                    }
                }
            }
        }
    }
}

// MARK: - 行

/// 一条 = 一行（照 Linear）：行首一颗圈（形状说走到哪了、颜色说轻重、点一下了结）、
/// 标题、一句副行；右边项目和日期。
/// 副行是**现在要你干嘛**（要判断什么；没有的话给一句是什么），不写「下一步」——那是 being 的过程。
/// 选中是系统强调色的圆角淡底（访达边栏那种），不是整行一条。
private struct ItemRow: View {
    @ObservedObject var store: KairosStore
    let item: KairosItem
    var showsProject = false
    var showsClosedTag = false
    @EnvironmentObject private var shell: KairosMacShell

    private var isClosed: Bool { item.isClosed }
    /// 勾了、但还没到 2 秒的那一下。两端同一份状态（`KairosStore.toggleChecked`）。
    private var completing: Bool { store.isChecked(item) }
    private var tier: String { KairosMacTier.normalized(item.tier) }
    /// 行首那颗圈要不要说轻重。「行上显示 → 优先级」关掉就不上色——
    /// 圈本身不会消失，它是勾选框，**每一行都得有一颗，位置还不能挪**。
    private var rowTier: String? { shell.rowProperties.contains(.tier) ? tier : nil }
    private var conflicted: Bool { store.conflict(for: item.id) != nil }
    private var selected: Bool { store.selectedItemIDs.contains(item.id) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 要判断什么优先，其次是摘要；和标题雷同的不重复念。
    private var secondaryLine: String {
        item.displayAsk.isEmpty ? item.displaySummary : item.displayAsk
    }

    /// 有对方就把名字放在最前面（两个平台共用 `KairosItemRowTitle`）。
    private var titleLine: AttributedString { KairosItemRowTitle.line(item) }

    var body: some View {
        HStack(alignment: .top, spacing: T.Spacing.rowInset) {
            marker
            VStack(alignment: .leading, spacing: T.Spacing.hairline) {
                // 消息行的标题**以人开头**：「Judy · 周四那版能不能先看」。
                // 一百个人的时候，名字是唯一能快速扫的索引。
                // 名字不写进 `title`，由这里画——写进去会和 `counterpart.name` 重复，
                // 而且人改过标题之后名字就钉死在里面了。
                Text(titleLine)
                    .font(.system(size: T.TypeScale.body))
                    .foregroundStyle(completing ? T.Ink.secondary : T.Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    // 划账：划线**从左往右扫过去**（Motion.stroke），不是瞬间出现。
                    // `.strikethrough` 本身没有进度，所以叠一层只画线、字透明的同一段文字，
                    // 用从左侧展开的遮罩揭开——多行标题每一行同时被扫到，不会只划中间一条。
                    // 减弱动态效果：不扫，整条线直接淡入。
                    .overlay(alignment: .topLeading) {
                        Text(titleLine)
                            .font(.system(size: T.TypeScale.body))
                            .strikethrough(true, color: T.Ink.secondary)
                            .foregroundStyle(.clear)
                            .fixedSize(horizontal: false, vertical: true)
                            .mask(alignment: .leading) {
                                Rectangle()
                                    .scaleEffect(x: completing || reduceMotion ? 1 : 0, anchor: .leading)
                            }
                            .opacity(completing ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                if !secondaryLine.isEmpty {
                    Text(secondaryLine)
                        .font(.system(size: T.TypeScale.caption))
                        .foregroundStyle(T.Ink.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: T.Spacing.s)
            trailing
                .padding(.top, T.Spacing.hairline)
        }
        .padding(.horizontal, T.Spacing.rowInset)
        .padding(.vertical, T.Spacing.s)
        .background(
            selected ? KairosMacPalette.selection : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        // **只有已经了结的才整行变淡。** 刚点勾的那两秒（可以反悔的窗口）原来也整行压到 0.55——
        // 点一下，整行先灰一下，两秒后才消失，看着像卡了。
        // 现在点下去：圈立刻变实心勾、标题划掉变灰，行本身不闪；两秒后整行离场。
        .opacity(isClosed ? 0.55 : 1)
        .animation(T.Motion.reduced(T.Motion.strokeCurve, reduceMotion), value: completing)
        .contentShape(.rect)
        // 不把整行合成一个可访问元素：合了之后整行会被当成「了结」那颗按钮，
        // 辅助功能一按整条就了结了。
    }

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: T.Spacing.rowInset) {
            // 渠道只是行上一个小标记：信封 / 火焰 / 壁炉。不占勾选框的位置，也不进顶部分段
            // ——管子长什么样，和「谁在等你」是两个维度。
            // 账本直接建的（`todo`）不画：那是默认，画出来全是噪音。
            if conflicted {
                Image(systemName: "exclamationmark.triangle.fill")
                    // 语义色归 app：系统红在暗色下和 P0 圈不是同一个红，同屏撞色。
                    .foregroundStyle(KairosMacPalette.critical)
                    .font(.system(size: T.TypeScale.caption))
                    .accessibilityLabel("有冲突要你定")
            } else if let pulse = store.roomPulse(for: item) {
                RoomPulseMark(pulse: pulse, beingName: store.beingNameLeading)
            }
            if showsProject, shell.rowProperties.contains(.project), !item.project.isEmpty {
                ProjectPill(name: item.project, color: store.macProjectColor(item.project))
            }
            if isClosed, showsClosedTag {
                Text("已完结")
                    .font(.system(size: T.TypeScale.caption))
                    .foregroundStyle(T.Ink.tertiary)
            }
            if shell.rowProperties.contains(.date), let date = item.shortDate {
                Text(date)
                    .font(.system(size: T.TypeScale.caption).monospacedDigit())
                    .foregroundStyle(T.Ink.tertiary)
            }
        }
    }

    /// 行首：**每一行都是一颗勾选圈，一种都不例外。**
    ///
    /// 这儿原来分三支：已完结画静态圆点、消息（信 / 篝火 / 炉火）画渠道图标、只有待办
    /// 才给按钮。那是 09-09 的裁决，当时信还不是账本条目。09-11「消息也是账本上的一行」
    /// 之后它就过期了——`KairosMessageRow` 的文档里写着这次裁决的第一条：
    /// 「所有行必须一样：能勾、能拖、能改档位、能进项目。**有一种行不能勾，肌肉记忆就断了**」。
    /// 手机那边早就是一视同仁（`kairos-ios-src` 的 `ItemRow.marker` 不看 source），
    /// 只有 Mac 还留着旧分支：同一条 Judy 的信，手机上一滑就了结，Mac 上得右键找菜单
    ///
    /// 渠道图标不在这儿了——它在 `trailing` 里已经画了一遍。原来两处画的是同一个符号、
    /// 判断条件一字不差，所以一行开着的信左边一个信封、右边又一个信封。
    ///
    /// 已完结的不给点——它已经是终点。开着的点一下先打勾，半秒后了结；再点就是反悔。
    @ViewBuilder
    private var marker: some View {
        if isClosed {
            StatusGlyph(status: item.status, closed: true)
                .padding(.top, 1)
                .accessibilityLabel("已完结")
        } else {
            Button {
                store.toggleChecked(item)
            } label: {
                StatusGlyph(status: item.status, closed: completing, tier: rowTier)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 1)
            // 轻重现在只画在这颗圈的颜色上，而颜色念不出来、也没有 tooltip——
            // 三根柱子撤了之后，这两句是这一维在行上仅剩的出口。
            .help(completing ? "点一下反悔" : "了结 · \(tier) · \(KairosStatus.label(item.status))")
            .accessibilityLabel(completing ? "反悔" : "了结，\(tier)，\(KairosStatus.label(item.status))")
        }
    }
}

/// 行尾那一处：这条待办的房间此刻怎么样了（`KairosRoomPulse`）。两端同一套（iOS 的 `RoomPulseMark`）。
///
/// **在答、在等是临时的**：一个图形 + 一个词说清楚，气收了自己消失。常见的词都是三个字，
/// being 从「在思考」换到「在搜索」，行尾不跳。
/// **没看、没发出去是等你来的**：只给一个记号，点进这一条就没了。
/// 没看就是「在等你」那颗橙点——球回到你手上了，正是橙的意思（09-13 配色规则）。
private struct RoomPulseMark: View {
    let pulse: KairosRoomPulse
    /// `beingNameLeading`：拉丁字母的名字后面带一个空格。
    let beingName: String

    var body: some View {
        switch pulse {
        case .working(let label, let detail):
            HStack(spacing: T.Spacing.xs) {
                PulseDots()
                Text(label)
            }
            .font(.system(size: T.TypeScale.caption))
            .foregroundStyle(T.Ink.secondary)
            .help(detail.isEmpty ? "\(beingName)\(label)" : "\(beingName)\(label)\u{201C}\(detail)\u{201D}")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(beingName)\(label)")
        case .waiting(let label):
            // 钟是「还没发出去、在等」的通用记号（消息 app 里排着的那句就是一只钟）。不动：它还没开始。
            HStack(spacing: T.Spacing.xs) {
                Image(systemName: "clock")
                Text(label)
            }
            .font(.system(size: T.TypeScale.caption))
            .foregroundStyle(T.Ink.tertiary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
        case .unsent:
            // 和房间里「没发出去，点一下重发」同一个图形：点进去认得出是哪一句。
            Image(systemName: "exclamationmark.arrow.circlepath")
                .font(.system(size: T.TypeScale.caption))
                .foregroundStyle(KairosMacPalette.critical)
                .help("有一句没发出去，点进去重发")
                .accessibilityLabel("有一句没发出去")
        case .unread(let asking):
            Circle()
                .fill(KairosMacPalette.attention)
                .frame(width: 8, height: 8)
                .help(asking ? "\(beingName)在等你" : "\(beingName)回你了")
                .accessibilityLabel(asking ? "\(beingName)在等你" : "\(beingName)回你了，还没看")
        }
    }
}

/// 行尾的三个点：房间里那三个点（`ThinkingDots`）缩到一个字高，节拍一样——一眼认得出是同一件事。
private struct PulseDots: View {
    @State private var phase = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .frame(width: 3.5, height: 3.5)
                    // 减弱动态效果：不循环，三颗一样亮。
                    .opacity(reduceMotion || phase == index ? 1 : 0.3)
            }
        }
        .task(id: reduceMotion) {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(320))
                withAnimation(.easeOut(duration: T.Motion.stroke)) { phase = (phase + 1) % 3 }
            }
        }
    }
}

/// 行首那一颗，**一个图形说两件事**：形状说走到哪了，颜色说轻重。
///
/// 形状照 Linear 那套：空圈未开始、半圆进行中、虚线圈待定、实心勾已完结。
/// 颜色和粗细是轻重：P0 红且粗、P1 橙、P2 中性、P3 淡一档。
///
/// 轻重原来是行首另一颗图形（三根柱子的 `TierGlyph`），于是每一行开头有两样东西抢一眼，
/// 而人的手指本来就要落在这颗圈上（它就是勾选框）。合成一颗之后**眼睛落点和手指落点是
/// 同一个**，行首还窄了一截。
/// 两端同一套（iOS 的 `StatusRing`）。
///
/// **颜色只有 P0 / P1 出声**——P2 是常规、P3 是有空再说，它们靠环的深浅分；
/// 粗细是给分不出红橙的人留的第二条通道。进行中那半块跟着环走：整颗只有一个颜色，
/// 不然「颜色说轻重」这句话立刻就破了（原来那半块是系统强调色，一屏上凭空多一个蓝）。
struct StatusGlyph: View {
    let status: String
    let closed: Bool
    /// 轻重。`nil` = 这颗不表达轻重（房间抬头那颗、输入框里那颗、已完结的那颗）。
    var tier: String? = nil
    var size: CGFloat = 18

    private var level: String? { tier.map(KairosMacTier.normalized) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ink: Color {
        switch level {
        case "P0": KairosMacPalette.critical
        case "P1": KairosMacPalette.priority
        // 不敢再淡：这颗圈同时是勾选按钮（和 iOS 的 `StatusRing` 同一条理由）。
        case "P3": Color.secondary.opacity(0.45)
        default: Color.secondary.opacity(0.7)
        }
    }

    private var width: CGFloat {
        switch level {
        case "P0": 2
        case "P1": 1.6
        default: 1.2
        }
    }

    var body: some View {
        ZStack {
            if closed {
                // **不用系统强调色。** 这台机器的强调色是什么，是人在系统设置里选的
                // （这台是粉的），于是「已了结」在每台 Mac 上是不同的颜色，而手机上
                // 它永远是那个橙——同一条待办两端两个颜色，而且多出来的那个饱和色
                // 和 P1 的橙在一屏上打架。
                // 规则定死：**语义色归 app（橙 / 红），选中和焦点归系统**。
                Circle()
                    .fill(KairosMacPalette.doneFill)
            } else {
                switch KairosStatus.normalized(status) {
                case KairosStatus.doing:
                    Circle()
                        .strokeBorder(ink, lineWidth: width)
                    Circle()
                        .trim(from: 0, to: 0.5)
                        .fill(ink)
                        .rotationEffect(.degrees(-90))
                        .padding(size * 0.2)
                case KairosStatus.pending:
                    Circle()
                        .strokeBorder(style: StrokeStyle(lineWidth: width, dash: [2.4, 2.2]))
                        .foregroundStyle(ink)
                default:
                    Circle()
                        .strokeBorder(ink, lineWidth: width)
                }
            }
            // 勾号**描一笔**：实心圈先落（weighted），勾比圈晚 0.06s 从起笔描到收笔（stroke）。
            // 常驻在这里而不放进 `if closed`：放进去，已了结的行一出现就会重描一遍。
            // 减弱动态效果：不描，勾整颗跟着圈淡入。
            CheckStroke()
                .trim(from: 0, to: closed || reduceMotion ? 1 : 0)
                .stroke(KairosMacPalette.onDone,
                        style: StrokeStyle(lineWidth: size * 0.11, lineCap: .round, lineJoin: .round))
                .opacity(closed ? 1 : 0)
                .animation(reduceMotion ? T.Motion.feedback : T.Motion.strokeCurve.delay(0.06), value: closed)
                .accessibilityHidden(true)
        }
        .frame(width: size, height: size)
        // 临界阻尼，无过冲（bounce 禁用）。
        .animation(T.Motion.reduced(T.Motion.weighted, reduceMotion), value: closed)
    }
}

/// 勾号的一笔：左下起笔 → 底部拐点 → 右上收笔，坐标按圈的尺寸取比例。
private struct CheckStroke: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + rect.width * 0.29, y: rect.minY + rect.height * 0.52))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.44, y: rect.minY + rect.height * 0.67))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.72, y: rect.minY + rect.height * 0.36))
        return p
    }
}

/// 项目：一颗小圆点加名字，外面一圈很淡的边 —— 照 Linear 的标签。
/// 原来是一行裸灰字，和右边的日期分不出层次。
struct ProjectPill: View {
    let name: String
    let color: Color

    var body: some View {
        // **没有彩色点了**。原来每个项目一个颜色（项目甲蓝、being 青……），
        // 一屏几十行，右边一列就是一排蓝点青点——两种没有含义的颜色，名字本身已经说清是哪个项目。
        Text(name)
            .font(.system(size: T.TypeScale.caption))
            .lineLimit(1)
        .padding(.horizontal, T.Spacing.s)
        .padding(.vertical, T.Spacing.hairline)
        .foregroundStyle(T.Ink.secondary)
        .overlay(
            Capsule().stroke(Color(nsColor: .separatorColor), lineWidth: 0.8)
        )
        .accessibilityLabel("项目 \(name)")
    }
}

/// 优先级小标：P0 红、P1 橙、其余灰。
struct TierTag: View {
    let tier: String

    var body: some View {
        let value = KairosMacTier.normalized(tier)
        Text(value)
            .font(.system(size: T.TypeScale.caption, weight: .medium).monospacedDigit())
            .foregroundStyle(value == "P0" || value == "P1" ? KairosMacTier.color(value) : T.Ink.secondary)
    }
}

private struct UndoCapsule: View {
    let notice: KairosUndoNotice
    @ObservedObject var store: KairosStore

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.uturn.backward")
                .foregroundStyle(.secondary)
            // 胶囊是玻璃：字色留系统样式。说明常规体，「撤销」是这里唯一的动作，给 medium。
            Text(notice.title)
                .font(.system(size: T.TypeScale.body))
                .lineLimit(1)
            Spacer(minLength: T.Spacing.s)
            Button("撤销") { store.performUndo() }
                .font(.system(size: T.TypeScale.body, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .frame(maxWidth: 360)
        .glassEffect(.regular.interactive(), in: .capsule)
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        .task(id: notice.id) {
            try? await Task.sleep(for: .seconds(5))
            store.dismissUndoNotice(notice.id)
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - 编辑表单（详情是对话；这张表只管改字。改了的字段盖 human 戳，being 盖不动）

struct ItemEditor: View {
    @State private var draft: KairosItem
    @ObservedObject var store: KairosStore
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    init(item: KairosItem, store: KairosStore) {
        _draft = State(initialValue: item)
        self.store = store
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("待办") {
                    TextField("标题", text: $draft.title)
                    Picker("优先级", selection: $draft.tier) {
                        ForEach(KairosMacTier.all, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("状态", selection: $draft.status) {
                        ForEach(KairosStatus.all, id: \.self) { Text(KairosStatus.label($0)).tag($0) }
                    }
                    Picker("项目", selection: $draft.project) {
                        Text("无").tag("")
                        ForEach(store.macProjects, id: \.self) { Text($0).tag($0) }
                        if !draft.project.isEmpty, !store.macProjects.contains(draft.project) {
                            Text(draft.project).tag(draft.project)
                        }
                    }
                }
                Section("内容") {
                    TextField("是什么（一句）", text: $draft.summary, axis: .vertical).lineLimit(1...4)
                    TextField("背景（一段，\(store.beingNameInline)消化过的来龙去脉）", text: $draft.brief, axis: .vertical).lineLimit(2...8)
                    TextField("要判断什么", text: $draft.ask, axis: .vertical).lineLimit(1...4)
                    TextField("原话（源头原文，一字不改）", text: $draft.excerpt, axis: .vertical).lineLimit(2...8)
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("编辑待办")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(width: 580, height: 600)
    }

    private func save() {
        do {
            draft.tier = KairosMacTier.normalized(draft.tier)
            draft.status = KairosStatus.normalized(draft.status)
            try store.saveDraft(draft, isNew: false)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 设置：接哪个 being、叫什么；外观；数据

struct KairosSettingsView: View {
    @ObservedObject var store: KairosStore
    @ObservedObject var shell: KairosMacShell
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = true
    @State private var api: String
    @State private var token: String
    @State private var name: String
    @State private var saved = false
    @State private var probing = false
    @State private var probeResult: String?
    @State private var errorMessage: String?
    @State private var confirmingUnlink = false
    @State private var confirmingDisconnect = false
    @State private var requestingBeingRules = false
    @State private var showingRulesRequestConfirm = false

    init(store: KairosStore, shell: KairosMacShell) {
        self.store = store
        self.shell = shell
        _api = State(initialValue: store.connection?.api ?? "")
        _token = State(initialValue: store.connection?.token ?? "")
        _name = State(initialValue: store.connection?.name ?? "")
    }

    var body: some View {
        Form {
            Section("Being") {
                // 只要一个链接，token 从 ?token= 里拆（KairosConnection.normalized）。
                TextField("链接", text: $api, prompt: Text("粘整条 loom 链接"))
                    .onChange(of: api) { saved = false }
                Text(token.isEmpty ? "链接里要带 ?token=…" : "已从链接里读到 token")
                    .font(.system(size: T.TypeScale.caption)).foregroundStyle(T.Ink.secondary)
                TextField("名字", text: $name, prompt: Text("比如 Maple"))
                    .onChange(of: name) { saved = false }
                HStack {
                    Button(probing ? "正在问…" : "问一声在不在") { Task { await probe() } }
                        .disabled(store.connection == nil || probing)
                        .help("测一下通不通：能连上会显示它的名字")
                    Spacer()
                    Button("保存") { save() }.buttonStyle(.borderedProminent)
                }
                if store.connection != nil {
                    HStack {
                        Spacer()
                        Button("断开连接…", role: .destructive) { confirmingDisconnect = true }
                            .controlSize(.small)
                            .confirmationDialog(
                                "断开与 being 的连接？",
                                isPresented: $confirmingDisconnect,
                                titleVisibility: .visible
                            ) {
                                Button("断开连接", role: .destructive) { store.disconnectBeing() }
                                Button("取消", role: .cancel) {}
                            } message: {
                                Text("删除本机保存的连接信息（链接和 token）。账本、待办和消息都保留，重新填上链接即可恢复。")
                            }
                    }
                }
                if let probeResult {
                    Text(probeResult).font(.system(size: T.TypeScale.body))
                }
                // 始终显示：引导文案承诺这里有个按钮，未连上时也不能是幽灵。
                beingRulesDeliveryBlock
                if saved {
                    Label("已保存", systemImage: "checkmark.circle.fill")
                        .font(.system(size: T.TypeScale.body))
                        .foregroundStyle(.green)
                }
                if let errorMessage { Text(errorMessage).font(.system(size: T.TypeScale.body)).foregroundStyle(.red) }
            }

            Section("外观") {
                Picker("外观", selection: $shell.appearance) {
                    ForEach(KairosMacAppearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section {
                Button("重看引导") { hasSeenOnboarding = false }
            } footer: {
                // 引导现在是两页（见 `KairosOnboardingView`），这里原来还写着「三页」。
                Text("首启那两页说明，随时可再看一遍。")
            }

            // 账本在哪（v2.4）：**单机是默认，iCloud 是可选的关联。**
            // 以前这里只有一行「iCloud 云盘 › Kairos」，因为位置写死在代码里——
            // 没登 iCloud 就没有一条干净的路，「两台机器各用各的」也表达不出来。
            Section("账本") {
                LabeledContent("位置") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(store.isLedgerLinked ? "关联 · \(folderName)" : "本机")
                        Text(store.ledgerFilePath)
                            .font(.system(size: T.TypeScale.caption))
                            .foregroundStyle(T.Ink.secondary)
                            .textSelection(.enabled)
                    }
                }
                HStack {
                    Button("在访达中显示") { reveal(URL(fileURLWithPath: store.ledgerFilePath)) }
                        .controlSize(.small)
                    Spacer()
                    if store.isLedgerLinked {
                        Button("改回本机…") { confirmingUnlink = true }
                            .controlSize(.small)
                    } else {
                        Button("接到 iCloud 文件夹…") { chooseFolder() }
                            .controlSize(.small)
                    }
                }
                Text(store.isLedgerLinked
                     ? "和手机共用这个文件夹，两边记的都会合到一起。"
                     : "单机：账本只在这台 Mac 上，不登 iCloud 也照常用。接上共享文件夹之后才和手机互通。")
                    .font(.system(size: T.TypeScale.caption))
                    .lineSpacing(T.TypeScale.captionLineSpacing)
                    .foregroundStyle(T.Ink.secondary)
                Text("换位置前会自动备份到 ~/.kairos/backups/。")
                    .font(.system(size: T.TypeScale.caption))
                    .foregroundStyle(T.Ink.secondary)
            }

            KairosUpdateSection()
        }
        .formStyle(.grouped)
        // 设置窗口右边那根粗滚动条（系统「总是显示」）撤掉：一页设置，滚到哪看内容就知道。
        .scrollIndicators(.never)
        .padding(T.Spacing.l)
        .frame(width: 560, height: 520)
        .confirmationDialog(
            "把账本改回这台 Mac 本机？",
            isPresented: $confirmingUnlink,
            titleVisibility: .visible
        ) {
            Button("改回本机") { store.unlinkLedger() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("共享文件夹里那份不动（手机可能还在用），但手机的改动从此不会被这台 Mac 收进来。本机那份会用现在看到的内容覆盖，旧的先备份。")
        }
    }

    private var folderName: String {
        URL(fileURLWithPath: store.ledgerFolderPath).lastPathComponent
    }

    /// 探测成功或已经在线——才露出「规则」递送（纯手账本没连 being 时不显示）。
    private var beingLinkReadyForRules: Bool {
        guard store.connection != nil else { return false }
        if case .online = store.connectionState { return true }
        if let probeResult, probeResult.hasPrefix("连上了") { return true }
        return false
    }

    @ViewBuilder
    private var beingRulesDeliveryBlock: some View {
        VStack(alignment: .leading, spacing: T.Spacing.s) {
            // 表单行里的小标题：正文字号 + medium，不上 headline（16）——
            // 它在「Being」这一节里面，不能比节标题本身还大。
            Text("being 的规则")
                .font(.system(size: T.TypeScale.body, weight: .medium))
            if let delivered = store.beingRulesDeliveredAt {
                Text("已收下 · \(beingRulesDate(delivered))")
                    .font(.system(size: T.TypeScale.body).monospacedDigit())
                Button("重发请求") {
                    openRulesRequestConfirm()
                }
                .controlSize(.small)
                .disabled(requestingBeingRules)
            } else if store.beingRulesRequestedAt != nil {
                Text("已请求，等 \(beingDisplayName) 把 BEING-RULES 发回来。")
                    .font(.system(size: T.TypeScale.body))
                    .foregroundStyle(T.Ink.secondary)
                Button("再发一次") {
                    openRulesRequestConfirm()
                }
                .controlSize(.small)
                .disabled(requestingBeingRules)
            } else {
                Text("点一下，让 being 去读规则文档。")
                    .font(.system(size: T.TypeScale.caption))
                    .foregroundStyle(T.Ink.secondary)
                Button(requestingBeingRules ? "正在发…" : "请求规则") {
                    openRulesRequestConfirm()
                }
                .disabled(requestingBeingRules || !beingLinkReadyForRules)
                if !beingLinkReadyForRules {
                    Text("先在上面「问一声在不在」，连上后这里才点得动。")
                        .font(.system(size: T.TypeScale.caption))
                        .foregroundStyle(T.Ink.secondary)
                }
            }
            // 请求没发出去就在这儿说：规则那间房没有页面，原因不能画到哪条待办底下去。
            if let error = store.beingRulesSendError {
                Text(error)
                    .font(.system(size: T.TypeScale.caption))
                    .foregroundStyle(.red)
            }
        }
        .padding(.top, T.Spacing.s)
        .sheet(isPresented: $showingRulesRequestConfirm) {
            rulesRequestPreviewSheet
        }
    }

    private var beingDisplayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? store.beingNameInline : trimmed
    }

    private func beingRulesDate(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_Hans")))
    }

    private func requestBeingRulesFromSettings() async {
        requestingBeingRules = true
        defer { requestingBeingRules = false }
        await store.requestBeingRules()
    }

    private func openRulesRequestConfirm() {
        showingRulesRequestConfirm = true
    }

    private var rulesRequestPreviewSheet: some View {
        // 同一次写入结果同时用来判断「查看」是否可点、点下去打开哪个文件——
        // 避免每次视图重绘都重复落盘。
        let rulesURL = store.ensureRulesFileInLedger()
        return VStack(alignment: .leading, spacing: T.Spacing.m) {
            Text("发一条规则请求")
                .font(.system(size: T.TypeScale.headline, weight: .semibold))
            Text("BEING-RULES 是 Kairos 与 being 的工作约定：账本怎么记、增删改谁负责、事情怎么流转。发送后 being 会去读账本文件夹里的这份文件。")
                .font(.system(size: T.TypeScale.caption))
                .foregroundStyle(T.Ink.secondary)
            HStack {
                Button("查看") {
                    if let rulesURL { NSWorkspace.shared.open(rulesURL) }
                }
                .disabled(rulesURL == nil)
                Spacer()
                Button("取消", role: .cancel) { showingRulesRequestConfirm = false }
                Button("确认发送") {
                    showingRulesRequestConfirm = false
                    Task { await requestBeingRulesFromSettings() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(requestingBeingRules || !beingLinkReadyForRules)
            }
        }
        .padding(T.Spacing.l)
        .frame(width: 460)
    }

    /// 选一个文件夹当账本的家。默认打开 iCloud 云盘——十有八九是要选那儿的 Kairos。
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "接到这里"
        panel.message = "选 iCloud 云盘里的 Kairos 文件夹（手机接的是同一个）"
        let cloud = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if FileManager.default.fileExists(atPath: cloud.path) { panel.directoryURL = cloud }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.linkLedger(to: url)
    }

    private func save() {
        do {
            try store.updateConnection(KairosConnection(api: api, token: token, name: name))
            saved = true
            errorMessage = nil
        } catch {
            saved = false
            errorMessage = error.localizedDescription
        }
    }

    private func probe() async {
        probing = true
        defer { probing = false }
        probeResult = await store.macProbeBeing()
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - 细滚动条 + 关掉系统的整行选中高亮 + 段头不钉住
//
// 三件事，一个小黑招：往视图树里塞一个隐形 NSView，从它往上走几层再往下找。
//   · NSScrollView：系统设置「总是显示滚动条」时用的是带轨道的粗滚动条，改成 overlay 样式——细、滚的时候才出现。
//   · NSTableView：List 自带的选中高亮是整行一条；关掉它，选中态由行自己画：强调色的圆角淡底（访达边栏那种）。
//   · NSTableView：段头（P0 / P1…）不钉在顶上。钉住的段头系统会给它垫一条底、底下画一根线，
//     滚动时顶上就又多出一条带子；一张几十行的单子，段头跟着行一起走就够认了。
// 只改样式，不碰内容。
struct ScrollerTamer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.isHidden = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { Self.tame(around: view) }
    }

    private static func tame(around view: NSView) {
        var root: NSView? = view
        for _ in 0..<5 { root = root?.superview }
        guard let root else { return }
        func walk(_ node: NSView) {
            if let scroll = node as? NSScrollView {
                scroll.scrollerStyle = .overlay
                scroll.autohidesScrollers = true
            }
            // 边栏那张表不碰：它的选中就该是系统边栏那块底。
            // 往上走几层才往下找，走到哪儿取决于外面套了几层——右侧挂到分栏上之后，
            // 从单子这边就能走进边栏里去，「全部」那一行的选中底被一起关掉了。
            if let table = node as? NSTableView, table.style != .sourceList {
                table.selectionHighlightStyle = .none
                table.floatsGroupRows = false
            }
            for child in node.subviews { walk(child) }
        }
        walk(root)
    }
}

// MARK: - Mac 专属的 Store 扩展
//
// 和 kairos-ios-src/ItemsCompose.swift 里的同名扩展是一对：那份只进 iOS target，
// 这份只进 Mac 构建（run-tests.sh 也不编这个文件），互不相见，所以可以同名。

extension KairosStore {
    /// 一张单子里的选中：待办的 id 和信的 `mail:<人>` 混在同一个 tag 空间。
    /// 选了待办就开房间；选了信就开那个人的来往信；两者互斥。
    /// 单子里的选中。**是一批，不是一条。**
    ///
    /// 这儿原来是 `Binding<String?>`，setter 里一句 `selectedItemIDs = [tag]`——
    /// 于是 `selectedItemIDs` 永远只有 0 或 1 个，⌘点、⇧点在这张单子上根本不存在。
    /// 而 store 里 `select(_:visibleItems:modifiers:)` 那套多选逻辑是全的、
    /// `macDragIDs` 会把整批拖走、`DragPreview` 连「N 条」的样子都画好了——
    /// 整条流水线只差最前面这一个绑定没接上，视图层一次都没调过它们
    /// 选 8 条一起改 P1 做不到，得点 8 次右键菜单。
    ///
    /// 换成 `Set<String>` 之后 ⌘点 / ⇧点 由 `List` 自己给，下游全是现成的。
    /// 只选中一条才开右侧房间：选了一批是要批量改，不是要读某一条。
    func macSelectionBinding(_ shell: KairosMacShell) -> Binding<Set<String>> {
        Binding(
            get: { self.selectedItemIDs },
            set: { ids in
                self.selectedItemIDs = ids
                self.selection = ids.count == 1 ? ids.first : nil
                shell.roomShown = ids.count == 1
            }
        )
    }

    /// 这个动作作用在哪几条：**这一条，还是选中的那一批？**
    ///
    /// 和 `macDragIDs` 同一个判断，只是拖拽之外的动作（右键菜单里的优先级 / 状态 /
    /// 项目 / 了结 / 删除）也该照这个来——选中一批之后右键其中一条，改的是这一批。
    /// 不然多选出来只能用来拖，选中做了一半。
    func macTargetIDs(_ item: KairosItem) -> [String] {
        guard selectedItemIDs.count > 1, selectedItemIDs.contains(item.id) else { return [item.id] }
        let rank = Dictionary(uniqueKeysWithValues: snapshot.items.enumerated().map { ($0.element.id, $0.offset) })
        return selectedItemIDs.sorted { (rank[$0] ?? .max, $0) < (rank[$1] ?? .max, $1) }
    }

    /// 批量改优先级 / 状态 / 了结 / 重新打开。和拖到那一列落下去是同一条路（同一个撤销栈）。
    func macApply(_ ids: [String], to key: KairosMacGroup.Key) {
        macAssign(ids, to: key)
    }

    func macSelect(_ item: KairosItem) {
        selection = item.id
        selectedItemIDs = [item.id]
    }

    /// 直接建一条待办。球在自己手上；要不要 being 来管，在它的房间里说一句就行——
    /// 「交给 being」不再是一个状态动作。
    func createItem(title: String, tier: String = "P2", project: String = "") {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var draft = KairosItem()
        draft.title = trimmed
        draft.tier = KairosMacTier.normalized(tier)
        draft.project = project
        do {
            try saveDraft(draft, isNew: true)
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Mac 上也没有「想法」这一屏了：以前记下的想法一次性变成待办，一条不丢。
    func absorbSeedsIntoItems() {
        for seed in seeds { promoteSeed(seed) }
    }

    /// 「问一声在不在」：GET /api/status，把结果说成人话。
    func macProbeBeing() async -> String {
        guard let connection else { return "还没填链接。" }
        connectionState = .checking
        let started = Date()
        do {
            let reported = try await BeingClient(connection: connection).status()
            let elapsed = Date().timeIntervalSince(started)
            connectionState = .online(beingName)
            let who = reported.trimmingCharacters(in: .whitespacesAndNewlines)
            return "连上了，\(String(format: "%.1f", elapsed)) 秒回的。对面自报的名字是「\(who.isEmpty ? "没说" : who)」。"
        } catch {
            connectionState = .offline
            return "连不上：\(error.localizedDescription)"
        }
    }

    // MARK: 项目（第三个维度）

    /// 边栏里的项目：登记过的（`workspace.projects`，不算那个占位的 Default）∪ 待办身上写着的。
    /// being `set project=X` 写了个新名字，边栏就会多出来，不用先登记。
    var macProjects: [String] {
        var seen = Set<String>()
        var names: [String] = []
        let registry = snapshot.workspace.projects
            .filter { !$0.archived && $0.id != KairosWorkspace.defaultProjectID }
        let rank = Dictionary(uniqueKeysWithValues: snapshot.workspace.sidebarOrder.enumerated().map { ($0.element, $0.offset) })
        for project in registry.sorted(by: { (rank[$0.id] ?? Int.max, $0.name) < (rank[$1.id] ?? Int.max, $1.name) }) {
            if seen.insert(project.name).inserted { names.append(project.name) }
        }
        for item in snapshot.items where !item.project.isEmpty {
            if seen.insert(item.project).inserted { names.append(item.project) }
        }
        // 再叠一层本机拖出来的顺序。排过的在前，没排过的按原样缀在后面。
        let dragged = Dictionary(uniqueKeysWithValues: sidebarProjectOrder.enumerated().map { ($0.element, $0.offset) })
        let position = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.element, $0.offset) })
        return names.sorted {
            (dragged[$0] ?? Int.max, position[$0] ?? 0) < (dragged[$1] ?? Int.max, position[$1] ?? 0)
        }
    }

    /// 边栏里**该露面**的项目。
    ///
    /// 手动建的（`workspace.projects` 里登记过的）一直在——那是人说「我要这么一格」。
    /// 从待办身上冒出来的名字不一样：它只是个字段值，**没东西可看的时候就该消失**，
    /// 不该在边栏里留一行点进去是空的。
    ///
    /// 「有东西可看」跟着「显示已了结」走：默认只算开着的，开了就把已了结的也算上——
    /// 判断标准就是点进去那张单子空不空，不是账本里还有没有这个字。
    func macSidebarProjects(showClosed: Bool) -> [String] {
        let registered = Set(
            snapshot.workspace.projects
                .filter { !$0.archived && $0.id != KairosWorkspace.defaultProjectID }
                .map(\.name)
        )
        var hasSomething = Set<String>()
        for item in snapshot.items where !item.project.isEmpty {
            guard showClosed || !item.isClosed else { continue }
            hasSomething.insert(item.project)
        }
        return macProjects.filter { registered.contains($0) || hasSomething.contains($0) }
    }

    /// 今天了结的那几条，新的在前。
    ///
    /// 按 `updatedAt` 算「今天」——了结这个动作本身就会把它刷成现在，所以这个字段
    /// 对已完结的条目来说就是「什么时候完的」。没有第二个字段记完成时间，
    /// 也不打算加一个：这块地方只用来回答「我今天干了什么」，不精确到分秒也不影响。
    var macClosedToday: [KairosItem] {
        closedItems
            .filter { Calendar.current.isDateInToday(KairosClock.parse($0.updatedAt)) }
            .sorted { KairosClock.parse($0.updatedAt) > KairosClock.parse($1.updatedAt) }
    }

    var macClosedTodayCount: Int { macClosedToday.count }

    func macOpenCount(in project: String?) -> Int {
        snapshot.items.filter { !$0.isClosed && (project == nil || $0.project == project) }.count
    }

    /// 这个项目那颗小圆点是什么颜色。
    ///
    /// 登记过就用登记的颜色；**没登记过的按名字算一个**，不落回灰色。
    /// 一开始写的是「不认识就中性灰，不硬猜」——听着稳妥，实际上 示例项目 / 其他项目 / being
    /// 这几个都是 being 直接写出来的、本地没登记，于是**每颗点都是灰的**，
    /// 一个没有颜色的彩色圆点等于没画。
    ///
    /// 标签颜色本来就是任意的，不承载语义——所以按名字哈希挑一个就够，
    /// 只要求**稳定**：同一个项目每次都是同一个颜色，换台机器也一样。
    /// 用 `unicodeScalars` 自己加，不用 `hashValue`——后者每次进程启动都换种子。
    func macProjectColor(_ name: String) -> Color {
        let registered = snapshot.workspace.projects.first { $0.name == name && !$0.archived }?.color
        switch registered {
        case "blue": return .blue
        case "green": return .green
        case "orange": return KairosMacPalette.priority
        case "red": return KairosMacPalette.critical
        case "purple": return .purple
        case "pink": return .pink
        case "teal": return .teal
        case "yellow": return .yellow
        default: break
        }
        let palette: [Color] = [.blue, .purple, .teal, .green, .pink, .indigo, .cyan, .mint]
        let seed = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFFFF }
        return palette[seed % palette.count]
    }

    /// 这个项目在边栏上画哪个图标。没登记过的（being 直接写了个新项目名）落回文件夹。
    func macProjectSymbol(_ name: String) -> String {
        snapshot.workspace.projects.first { $0.name == name && !$0.archived }?.symbol ?? "folder"
    }

    /// 换图标。**只动 `workspace.projects`**——那是本地的工作区组织，
    /// 契约 §121 明写它不进 Being payload，所以换个图标不会惊动 being ，也不占 item rev。
    func macSetProjectSymbol(_ name: String, to symbol: String) {
        var next = snapshot
        guard let index = next.workspace.projects.firstIndex(where: { $0.name == name }) else { return }
        next.workspace.projects[index].symbol = symbol
        do { try commit(next) }
        catch { notice = error.localizedDescription }
    }

    func macAddProject(_ name: String, symbol: String = "folder") {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !macProjects.contains(trimmed) else { return }
        var next = snapshot
        let project = KairosProject(id: UUID().uuidString, name: trimmed, symbol: symbol, color: "blue", archived: false)
        next.workspace.projects.append(project)
        next.workspace.sidebarOrder.append(project.id)
        do { try commit(next) }
        catch { notice = error.localizedDescription }
    }

    /// 删项目：登记撤掉，里面的待办移出项目（待办本身不删）。
    func macDeleteProject(_ name: String) {
        var next = snapshot
        let ids = Set(next.workspace.projects.filter { $0.name == name }.map(\.id))
        next.workspace.projects.removeAll { ids.contains($0.id) }
        next.workspace.sidebarOrder.removeAll { ids.contains($0) }
        do { try commit(next) }
        catch { notice = error.localizedDescription; return }
        let members = snapshot.items.filter { $0.project == name }.map(\.id)
        macSetProject(members, to: "")
    }

    /// 把几条待办放进某个项目（"" = 移出）。业务字段，走普通编辑，盖 human 戳。
    func macSetProject(_ ids: [String], to project: String) {
        for id in ids {
            guard let item = snapshot.items.first(where: { $0.id == id }), item.project != project else { continue }
            var draft = item
            draft.project = project
            do { try saveDraft(draft, isNew: false) }
            catch { notice = error.localizedDescription }
        }
    }

    // MARK: 分组（显示层）

    /// 一组里有哪些。开着的按活动顺序（优先级 + 用户拖出来的顺序），已了结的按时间。
    func macItems(in key: KairosMacGroup.Key, filter: KairosMacFilter = KairosMacFilter()) -> [KairosItem] {
        func allowed(_ item: KairosItem) -> Bool { filter.allows(item) }
        switch key {
        case .tier(let tier):
            return activeItems.filter { allowed($0) && KairosMacTier.normalized($0.tier) == tier }
        case .status(let status):
            return activeItems.filter { allowed($0) && KairosStatus.normalized($0.status) == status }
        case .open:
            return activeItems.filter(allowed)
        case .closed:
            return closedItems.filter(allowed)
        }
    }

    func macGroups(
        grouping: KairosMacGrouping,
        showClosed: Bool,
        filter: KairosMacFilter
    ) -> [KairosMacGroup] {
        var groups: [KairosMacGroup] = []
        func add(_ key: KairosMacGroup.Key, _ title: String, _ color: Color) {
            let rows = macItems(in: key, filter: filter)
            if !rows.isEmpty {
                groups.append(KairosMacGroup(key: key, title: title, color: color, rows: rows))
            }
        }
        switch grouping {
        case .tier:
            for tier in KairosMacTier.all { add(.tier(tier), tier, KairosMacTier.color(tier)) }
        case .status:
            // 只排还开着的那三个；已完结是下面那个抽屉，不和它们并排。
            for status in KairosStatus.open {
                // 「进行中」不上系统强调色：那是多出来的一个颜色，而且 09-12 已经把
            // 行首那颗圈里的「进行中」从蓝改成跟着轻重走了，这儿是同一条账。
            add(.status(status), KairosStatus.label(status), .secondary)
            }
        case .none:
            // 标题留空：不分组时只有一组，给这一组起个名（原来叫「开着」）纯属噪音，
            // `GroupSignpost` 见到空标题就整行不画（不必要的文案不写）。
            add(.open, "", .secondary)
        }
        if showClosed { add(.closed, "已完结", .secondary) }
        return groups
    }

    // MARK: 排序（只动 workspace 里的顺序，不动任何业务字段）

    /// 把这一组的新顺序写回整条活动顺序：这组占的槽位不变，只把槽位里的顺序换成新的，
    /// 别的组一个不动。传进来的是这一组拖完之后的完整顺序。
    func macReorder(group: [KairosItem]) {
        let groupIDs = Set(group.map(\.id))
        var ids = activeItems.map(\.id)
        let slots = ids.enumerated().filter { groupIDs.contains($0.element) }.map(\.offset)
        let fresh = group.map(\.id).filter(groupIDs.contains)
        for (slot, id) in zip(slots, fresh) { ids[slot] = id }
        reorderActive(ids)
    }

    func macMove(_ item: KairosItem, by offset: Int, in key: KairosMacGroup.Key, filter: KairosMacFilter) {
        var section = macItems(in: key, filter: filter)
        guard let source = section.firstIndex(where: { $0.id == item.id }) else { return }
        let destination = min(max(source + offset, 0), section.count - 1)
        guard destination != source else { return }
        let value = section.remove(at: source)
        section.insert(value, at: destination)
        withAnimation(T.Motion.weighted) { macReorder(group: section) }
    }

    // MARK: 看板拖拽

    /// 拖到某一列 / 某张卡前面。先换组（优先级 / 状态 / 了结），再排到那个位置。
    func macDrop(_ ids: [String], into group: KairosMacGroup, before targetID: String?) {
        let known = ids.filter { id in snapshot.items.contains { $0.id == id } }
        guard !known.isEmpty else { return }
        macAssign(known, to: group.key)
        guard !group.isClosed else { return }
        let fresh = macItems(in: group.key)
        var section = fresh.filter { !known.contains($0.id) }
        let moved = known.compactMap { id in fresh.first { $0.id == id } }
        if let targetID, let index = section.firstIndex(where: { $0.id == targetID }) {
            section.insert(contentsOf: moved, at: index)
        } else {
            section.append(contentsOf: moved)
        }
        withAnimation(T.Motion.weighted) { macReorder(group: section) }
    }

    /// 拖的是这一条，还是选中的那一批？
    ///
    /// 选中好几条之后拖其中一条 = 拖整批——不然多选完还得一条一条拖，选中本身就白做了。
    /// 顺序按屏幕上的顺序给，不是 `Set` 的随机顺序：落下去之后它们之间的相对次序得和
    /// 拖之前一样，否则「拖一批」等于「打乱一批」。
    func macDragIDs(_ item: KairosItem) -> [String] { macTargetIDs(item) }

    /// 边栏里把项目拖成想要的顺序。只写本机——理由见 `sidebarProjectOrder`。
    func macReorderProjects(_ names: [String]) {
        setSidebarProjectOrder(names)
    }

    /// 换组 = 改优先级 / 改状态 / 了结。已了结的拖进开着的列 = 重新打开。可 ⌘Z。
    private func macAssign(_ ids: [String], to key: KairosMacGroup.Key) {
        var previous: [String: KairosFieldSnapshot] = [:]
        for id in ids {
            guard let item = snapshot.items.first(where: { $0.id == id }) else { continue }
            var draft = item
            switch key {
            case .tier(let tier):
                draft.tier = tier
                // 拖回某个档位 = 把它重新打开。以前这里是「球权回到 mine」，
                // 现在状态就一个字段：了结过的回到「未开始」，和 `reopen` 同一句话。
                if draft.isClosed { draft.status = KairosStatus.todo }
            case .status(let status):
                draft.status = status
            case .open:
                if draft.isClosed { draft.status = KairosStatus.todo }
            case .closed:
                draft.status = KairosStatus.closed
            }
            guard !draft.hasSameBusinessFields(as: item) else { continue }
            do {
                try saveDraft(draft, isNew: false)
                previous[id] = KairosFieldSnapshot(item)
            } catch {
                notice = error.localizedDescription
            }
        }
        guard !previous.isEmpty else { return }
        registerFieldUndo(previous, actionName: "移动待办")
        undoNotice = KairosUndoNotice(title: "已移动")
    }

}

// MARK: - 词汇与颜色

/// 优先级的词汇和颜色，列表、房间、新建三处共用一份（和 iOS 的 KairosTier 同一套）。
enum KairosMacTier {
    static let all = KairosTier.all

    static func normalized(_ raw: String) -> String { KairosTier.normalized(raw) }

    /// 三层：P0 红、P1 橙、P2/P3 中性。自己的颜色只有这两个语义色，其余全交给系统。
    static func color(_ tier: String) -> Color {
        switch tier {
        case "P0": KairosMacPalette.critical
        case "P1": KairosMacPalette.priority
        default: Color.secondary
        }
    }
}

/// 原生 Apple：底色、材质、选中、焦点全用系统的；自己只留两个语义色。
enum KairosMacPalette {
    /// P0，例外里的例外。
    static let critical = adaptive(
        light: (0.78, 0.10, 0.09),   // #C71A17 白字 5.86:1 · 当文字 5.67:1
        dark: (1.00, 0.42, 0.38)     // #FF6B61 墨字 6.22:1 · 当文字 6.60:1
    )
    /// P1，也是「要你注意」那一个饱和色。和 iOS 的 `KairosPalette.attention` **同一份数值**。
    ///
    /// 原来这两个是 `Color.red` / `Color.orange`，两端各写各的：同一条 P1 在 Mac 上是系统橙、
    /// 在手机上是自调的橙，同一颗「being 在等你」的点 Mac 画蓝、手机画橙。
    /// 现在两端一份数值、一套规则：**跟着深浅模式换一档，压上去的前景色跟着翻**（`onAccent`）——
    /// 中间调的橙白字压上去只有 2.52:1，它自己当文字画在浅底上只有 2.44:1，AA 要 4.5，两条都不到。
    static let priority = adaptive(
        light: (0.72, 0.33, 0.02),   // #B85405 白字 4.88:1 · 当文字 4.72:1
        dark: (0.97, 0.62, 0.23)     // #F79E3B 墨字 8.20:1 · 当文字 8.69:1
    )
    /// 「要你注意」和 P1 是同一个色——屏幕上只养得起一个饱和色。
    static let attention = priority
    /// 压在 `critical` / `priority` 上的那一层（胶囊里的字）。深色模式下那两个色是亮的一档，
    /// 白字压上去只有 2.1:1，所以这里要翻成墨色。
    static let onAccent = adaptive(light: (1, 1, 1), dark: (0.12, 0.10, 0.08))

    private static func adaptive(
        light: (CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat)
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    /// 选中：系统强调色的圆角淡底。
    /// 选中 / 拖拽落点 / 开着的筛选药丸：**中性灰**，不是系统强调色。
    ///
    /// 系统强调色是人在系统设置里选的——这台是粉的。于是被点中的那一行是一块粉，
    /// 旁边 P1 那颗圈是橙，两个饱和色在最显眼的地方打架，而「被选中」这件事根本不需要颜色：
    /// 边栏「全部」那行选中时就是一块浅灰，单子里被选中的那行和它同一种灰，一个窗口一套语言。
    static let selection = KairosTokens.Ink.fill            // 原 0.07，并入 Ink 面三档（0.06）
    /// 了结的那颗实心圈。**中性，不是橙**：橙是「要你动手」，而了结是这张单子上**最不需要你**的状态——
    /// 拿要你注意的颜色画已经完了的事，等于把那个颜色稀释掉。
    static let doneFill = Color.primary.opacity(0.82)
    static let onDone = Color(nsColor: .textBackgroundColor)
    /// 看板卡片：系统的控件底色。
    static let card = Color(nsColor: .controlBackgroundColor)
    /// 看板一列：比窗口底色深一度。
    static let column = KairosTokens.Ink.fillSubtle         // 原 0.045，并入 Ink 面三档（0.04）
}

// MARK: - 扩展

extension KairosItem {
    /// 「09/08」。Swift 写的是整秒、Node 写的带毫秒，`KairosClock.parse` 两种都认——
    /// 以前用裸 ISO8601DateFormatter，being 写过的条目就退成「2026-09-08」，一屏两种写法。
    var shortDate: String? {
        guard !updatedAt.isEmpty else { return nil }
        let date = KairosClock.parse(updatedAt)
        guard date != .distantPast else { return String(updatedAt.prefix(10)) }
        return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
    }
}
