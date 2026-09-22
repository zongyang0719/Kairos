import SwiftUI
import UIKit

/// 屏幕上只有两种颜色有含义，多一种颜色就不再是信号，只是装饰。
///
/// 两个语义色都**跟着深浅模式换一档，压在它们上面的前景色跟着翻**（`onAccent`）。
/// 一个中间调的橙做不了两份工——原来那个 `rgb(0.97,0.52,0.11)` 白字压上去只有 2.52:1，
/// 它自己当文字画在浅色页底上只有 2.44:1，WCAG AA 要的 4.5 两条都不到（实测：
/// 相对亮度对比度 (L1+.05)/(L2+.05)）。
/// 浅色用深一档配白字、深色用亮一档配墨字，四种组合都在 4.8 以上——
/// 而屏幕上仍然只有这一个饱和色，「一块屏幕只养得起一个」没破。
enum KairosPalette {
    /// 要你注意的颜色：P1、了结、新建按钮。一块屏幕只养得起一个饱和色。
    static let attention = adaptive(
        light: (0.72, 0.33, 0.02),   // #B85405 白字 4.88:1 · 当文字 4.72:1
        dark: (0.97, 0.62, 0.23)     // #F79E3B 墨字 8.20:1 · 当文字 8.69:1
    )
    /// 了结 / 刚勾上的那颗实心圈。**中性，不是橙**：
    /// 橙是「要你动手」，而了结是这张单子上最不需要你的状态。拿要你注意的颜色画已经完了的事，
    /// 等于把那个颜色稀释掉——一屏里勾掉五条，就是五颗橙，真正要人看的那颗 P1 反而不显眼了。
    static let done = Color(uiColor: .label).opacity(0.82)
    /// 压在 `done` 上的勾：跟着页面底色走（浅色是白勾，深色是黑勾）。
    static let onDone = Color(uiColor: .systemBackground)
    /// P0，例外里的例外。
    static let critical = adaptive(
        light: (0.78, 0.10, 0.09),   // #C71A17 白字 5.86:1 · 当文字 5.67:1
        dark: (1.00, 0.42, 0.38)     // #FF6B61 墨字 6.22:1 · 当文字 6.60:1
    )

    /// 压在 `attention` / `critical` 上的那一层（勾、箭头、胶囊里的字、自己发的气泡）。
    /// **不能写死成白**：深色模式下橙是亮的一档，白字压上去只有 2.12:1。
    static let onAccent = adaptive(light: (1, 1, 1), dark: (0.12, 0.10, 0.08))

    /// 给「前景色由系统画、我们说了不算」的地方——眼下就是 `swipeActions` 那几颗按钮的底。
    /// 系统在 tint 上一律画白字，`onAccent` 那套翻不进去，所以这里**两个模式都用深的那一档**，
    /// 白字稳在 4.88:1。深色模式下它是一颗更沉的橙，但那是一颗滑出来才看得见的按钮，
    /// 沉一点不碍事；字糊了才碍事。
    static let attentionSolid = Color(red: 0.72, green: 0.33, blue: 0.02)

    private static func adaptive(
        light: (CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat)
    ) -> Color {
        Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    /// 页面底色：**系统的分组背景**，不再自调一个暖灰渐变。
    ///
    /// 原来那句理由是「纯黑纯白都是没选颜色，暖一度就有人味」。落到屏幕上的结果是：
    /// 单子是一层偏黄的纸色，点进详情是系统白，Mac 那边是系统白——三块地方三种底，
    /// 而且「暖纸」这条路 09-08 已经被否过（太老气）。换成系统那两层：
    /// 页面 `systemGroupedBackground`、卡片 `secondarySystemGroupedBackground`——
    /// 就是「设置」和「提醒事项」的那两层，深浅模式、提高对比度都由系统管，不用自己算。
    static func canvas(_ scheme: ColorScheme) -> Color {
        Color(uiColor: .systemGroupedBackground)
    }

    /// 分组容器：一整组一块，不是一条一张卡。
    static func groupFill(_ scheme: ColorScheme) -> Color {
        Color(uiColor: .secondarySystemGroupedBackground)
    }
}

/// 顶上那几颗操作图标（不是内容，是界面本身）**同一个分量**。
///
/// 改之前每颗自己写 `.title3.weight(.medium)`——20pt medium，比系统导航栏那一档重一号：
/// 四颗并排时它们比旁边的搜索框还抢眼，而它们是 chrome，不该比内容响。
/// Apple 自己的提醒事项 / 邮件 / 备忘录，导航栏那一档是 **17pt**（对着系统提醒事项量的）。一个 token 管三件事：字号、字重、44×44 的命中区（HIG 最小点击尺寸）。
///
/// `hierarchical` 是第二件事：多层的符号（`person.crop.circle`、`line.3.horizontal.decrease.circle`）
/// 在单色模式下所有层一个浓度，糊成一团；hierarchical 让次要层自动淡一档，
/// 这是 Apple 对「工具栏里的多层符号」给的默认渲染。
extension View {
    func kairosChromeGlyph(tint: Color = .secondary) -> some View {
        self
            .font(.system(size: 17, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
    }
}

/// 单子怎么分段。**默认不分段**——顺序是 being 排的：账本里 `items` 什么次序，
/// 屏幕上就什么次序（README「顺序是 Being 排的」，2026-09-11 `3cdbbcc` 把排序器整个删了）。
///
/// 以前这一屏硬写成 P0/P1/P2/P3 四段，等于让一个四档旋钮盖掉 being 的整张排序：
/// 它把某条 P2 排到第一，也照样被压在所有 P1 底下——那条「tier 只管红点，不管顺序」
/// 就只在账本里成立，在人眼前不成立。轻重现在由行首那颗圈的颜色说，分堆是可选的。
enum KairosIOSGrouping: String, CaseIterable, Identifiable {
    case none, tier, status

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "不分组"
        case .tier: "按优先级"
        case .status: "按状态"
        }
    }

    var symbol: String {
        switch self {
        case .none: "list.bullet"
        case .tier: "flag"
        case .status: "circle.lefthalf.filled"
        }
    }
}

/// 事项列表。只回答一个问题：**下一条该看哪个**。
///
/// 一条列表，行长得一模一样——层级靠行首那颗圈的颜色和段头做，不靠把某些行写得大、
/// 某些行写得小。要分堆的话在「显示」里切（见 `KairosIOSGrouping`）。
/// 球在谁手上（mine / being）在这里根本不出现：being 在想是它的临时状态，不是事项的属性。
/// 标题永远不截断——标题是内容本身。
struct ItemsView: View {
    @ObservedObject var store: KairosStore
    /// 详情开着的时候，底下那颗新建按钮要让位（详情自己底下有输入框）。
    @Binding var detailOpen: Bool
    @State private var openItemID: String?
    @State private var query = ""
    @State private var filtering = false
    /// 搜索框出没出来。搜索是低频的：平时头上只有一颗放大镜，点了才出框。
    @State private var searching = false
    /// 「我」那张 sheet。归这一屏管：按钮长在这一屏的头上。
    @State private var showingMe = false
    /// 正在请 being 跑的是哪一趟。**不是 bool**：HIG 的 Generative AI 那页明写
    /// 「instead of 'Processing…', say 'Finding substitutions for ingredients'」——
    /// 一个转圈只说「在忙」，人不知道自己在等什么、该等多久。
    /// 状态归这一屏（谁点的谁记得），不进 store：账本不关心界面在等什么。
    @State private var askingWhat: String?
    @State private var draggingItemID: String?
    @State private var targetedItemID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    /// 「显示」里那两样，记在本机。**不进账本**：怎么看是这台设备的事，
    /// 不是这条待办的事——存进去就得和 being、和 Mac 对齐，而它一个字节的价值都没有。
    @AppStorage("kairos.ios.grouping") private var groupingRaw = KairosIOSGrouping.none.rawValue
    @AppStorage("kairos.ios.showClosed") private var showClosed = false
    /// 筛选也记在本机，和 Mac 的 `KairosMacFilter` 同名同义（范围复用 `KairosMacScope`，
    /// 那个 enum 在共用的 KairosModels.swift 里，两端一份定义——名字里的 Mac 是历史）。
    /// 存成逗号串而不是 `Set`：`@AppStorage` 只认基本类型，为这个引一套编解码不值。
    @AppStorage("kairos.ios.scope") private var scopeRaw = KairosMacScope.all.rawValue
    @AppStorage("kairos.ios.tiers") private var tiersRaw = ""
    @AppStorage("kairos.ios.statuses") private var statusesRaw = ""

    private var grouping: KairosIOSGrouping {
        KairosIOSGrouping(rawValue: groupingRaw) ?? .none
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var scope: KairosMacScope { KairosMacScope(rawValue: scopeRaw) ?? .all }
    private var tierFilter: Set<String> { Self.decode(tiersRaw) }
    private var statusFilter: Set<String> { Self.decode(statusesRaw) }
    /// 筛着几样。按钮上那个数字就是它——不显示的话人会忘了自己筛过，以为待办丢了。
    private var activeFilterCount: Int {
        (scope == .all ? 0 : 1) + tierFilter.count + statusFilter.count
    }

    private static func decode(_ raw: String) -> Set<String> {
        Set(raw.split(separator: ",").map(String.init))
    }

    private static func encode(_ values: Set<String>) -> String {
        values.sorted().joined(separator: ",")
    }

    private func allowed(_ item: KairosItem) -> Bool {
        guard scope.allows(item) else { return false }
        if !tierFilter.isEmpty, !tierFilter.contains(KairosTier.normalized(item.tier)) { return false }
        if !statusFilter.isEmpty, !statusFilter.contains(KairosStatus.normalized(item.status)) { return false }
        return true
    }

    private var items: [KairosItem] {
        (isSearching ? store.searchAllStates(query) : store.activeItems).filter(allowed)
    }

    /// 一段 = 段头 + 一组行。`key` 是这一段的身份，拖拽只在同一段里认（nil = 整张单子一段）。
    private struct Segment: Identifiable {
        let key: String?
        let title: String
        let color: Color
        let status: String?
        let rows: [KairosItem]

        var id: String { key ?? "全部" }
    }

    private var segments: [Segment] {
        switch grouping {
        case .none:
            return [Segment(key: nil, title: "", color: .secondary, status: nil, rows: items)]
        case .tier:
            return KairosTier.all.map { tier in
                Segment(
                    key: tier,
                    title: tier,
                    color: KairosTier.color(tier),
                    status: nil,
                    rows: items.filter { KairosTier.normalized($0.tier) == tier }
                )
            }
        case .status:
            return KairosStatus.open.map { status in
                Segment(
                    key: status,
                    title: KairosStatus.label(status),
                    color: .secondary,
                    status: status,
                    rows: items.filter { KairosStatus.normalized($0.status) == status }
                )
            }
        }
    }

    private func rows(inSegment key: String?) -> [KairosItem] {
        guard let key else { return items }
        return segments.first { $0.key == key }?.rows ?? []
    }

    var body: some View {
        List {
            if isSearching {
                searchSection
            } else {
                ForEach(segments) { segment in
                    section(segment)
                }
                if showClosed {
                    closedSection
                }
            }
            // 最后一张卡别被右下角那颗 + 挡住，垫一段尾巴。
            Color.clear
                .frame(height: 72)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .listSectionSpacing(2)
        .scrollContentBackground(.hidden)
        .background(KairosPalette.canvas(scheme).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        // **标准推入，不用 zoom 转场**。zoom 那一下要先把整张单子压暗、
        // 再从那一行里「长」出详情——点一下，屏幕先灰一下，这是「点击的时候会先灰一下」
        // 在手机上的来源。zoom 是给照片、卡片这种「内容本身就是那块图」的场景的；
        // 一行字点进一页字，Apple 自己的提醒事项、备忘录、邮件都是普通推入。
        .navigationDestination(item: $openItemID) { id in
            ItemDetailView(store: store, itemID: id)
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .overlay { if items.isEmpty { emptyState } }
        // 新建那颗按钮不在这一屏——它浮在右下角，长在 `RootView` 上。
        .refreshable { await store.refresh() }
        // 打字的时候往下滚就收键盘：搜索框常驻之后，人是一边看结果一边改词的。
        .scrollDismissesKeyboard(.interactively)
        .animation(.snappy(duration: 0.24), value: store.undoNotice)
        .onChange(of: openItemID, initial: true) { detailOpen = openItemID != nil }
        .onAppear {
            if let id = KairosDebugLaunch.openItemID, openItemID == nil { openItemID = id }
            if KairosDebugLaunch.openMe { showingMe = true }
        }
    }

    // MARK: - 分段

    @ViewBuilder
    private func section(_ segment: Segment) -> some View {
        if !segment.rows.isEmpty {
            Section {
                if grouping != .none {
                    signpost(segment)
                }
                ForEach(Array(segment.rows.enumerated()), id: \.element.id) { index, item in
                    row(for: item, segment: segment.key) {
                        ItemRow(
                            store: store,
                            item: item,
                            isFirst: index == 0,
                            isLast: index == segment.rows.count - 1,
                            showsStatus: grouping != .status
                        ) { openItemID = item.id }
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                }
            }
        }
    }

    /// 已了结的抽屉。**默认收着**，在「显示」里打开——「留着要给理由」是对还开着的事说的，
    /// 完了的事连给理由的机会都不该占屏。按时间倒序（`store.closedItems`），不叠手工顺序。
    @ViewBuilder
    private var closedSection: some View {
        let rows = store.closedItems.filter(allowed)
        if !rows.isEmpty {
            Section {
                signpost(Segment(key: nil, title: "已了结", color: .secondary, status: nil, rows: rows))
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                    row(for: item, segment: nil) {
                        ItemRow(
                            store: store,
                            item: item,
                            isFirst: index == 0,
                            isLast: index == rows.count - 1
                        ) { openItemID = item.id }
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                }
            }
        }
    }

    @ViewBuilder
    private var searchSection: some View {
        Section {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                row(for: item, segment: nil) {
                    ItemRow(
                        store: store,
                        item: item,
                        isFirst: index == 0,
                        isLast: index == items.count - 1
                    ) { openItemID = item.id }
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
            }
        }
    }

    /// 段头就写这一段是什么：优先级写 P0 红、P1 橙、P2/P3 中性——三层，四个词；
    /// 状态写「进行中 / 未开始 / 待定」，前面那颗圆点直接用行上那套环，图形和行首对得上。
    /// 做成普通行而不是 Section header——.plain 列表会把 header 钉在顶上，
    /// 一个「P2」浮在正在读的那条上面，是噪音不是路标。
    private func signpost(_ segment: Segment) -> some View {
        HStack(spacing: 6) {
            if let status = segment.status {
                StatusRing(status: status, size: 8)
            } else {
                Circle()
                    .fill(segment.color)
                    .frame(width: 6, height: 6)
            }
            Text(segment.title)
                .font(.caption.monospaced().weight(.bold))
                .tracking(1.2)
                .foregroundStyle(segment.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowInsets(EdgeInsets(top: 22, leading: 24, bottom: 8, trailing: 20))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - 每行共用的手势 / 菜单 / 滑动

    @ViewBuilder
    private func row<Content: View>(
        for item: KairosItem,
        segment: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .contextMenu { menu(for: item) }
            .draggable(beginDrag(item)) {
                ItemDragPreview(item: item)
            }
            .dropDestination(for: String.self) { ids, _ in
                guard let sourceID = ids.first else { return false }
                return drop(sourceID, before: item, in: segment)
            } isTargeted: { targeted in
                targetedItemID = targeted ? item.id : nil
            }
            .scaleEffect(!reduceMotion && targetedItemID == item.id ? 1.015 : 1)
            .animation(.smooth(duration: 0.18), value: targetedItemID)
            // 了结在左滑（可以一滑到底），删除在右滑——都藏在手势里，不占一个像素。
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                closeAction(for: item)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("删除", systemImage: "trash", role: .destructive) {
                    store.delete(item)
                }
            }
            .accessibilityAction(named: "上移") { move(item, by: -1, in: segment) }
            .accessibilityAction(named: "下移") { move(item, by: 1, in: segment) }
    }

    /// 这条现在画在哪一段里。菜单上的「上移 / 下移」按它认邻居——按什么分的堆，
    /// 就在什么堆里挪，别挪出人眼睛看见的那一列。
    private func segmentKey(of item: KairosItem) -> String? {
        switch grouping {
        case .none: nil
        case .tier: KairosTier.normalized(item.tier)
        case .status: KairosStatus.normalized(item.status)
        }
    }

    @ViewBuilder
    private func menu(for item: KairosItem) -> some View {
        Menu("优先级", systemImage: "flag") {
            ForEach(KairosTier.all, id: \.self) { tier in
                Button {
                    store.setTier(item, to: tier)
                } label: {
                    if KairosTier.normalized(item.tier) == tier {
                        Label(tier, systemImage: "checkmark")
                    } else {
                        Text(tier)
                    }
                }
            }
        }
        // 状态是 being 和人共管的一档（和优先级同形），手机上以前**根本改不了**——
        // 行上看不见、详情里没有、菜单里也没有，等于这一维只有 Mac 有。
        Menu("状态", systemImage: "circle.lefthalf.filled") {
            ForEach(KairosStatus.open, id: \.self) { status in
                Button {
                    store.setStatus(item, to: status)
                } label: {
                    if KairosStatus.normalized(item.status) == status {
                        Label(KairosStatus.label(status), systemImage: "checkmark")
                    } else {
                        Text(KairosStatus.label(status))
                    }
                }
            }
        }
        if !item.isClosed {
            let key = segmentKey(of: item)
            Button("上移", systemImage: "arrow.up") { move(item, by: -1, in: key) }
            Button("下移", systemImage: "arrow.down") { move(item, by: 1, in: key) }
        }
        Divider()
        closeAction(for: item)
        Button("删除", systemImage: "trash", role: .destructive) { store.delete(item) }
    }

    @ViewBuilder
    private func closeAction(for item: KairosItem) -> some View {
        if item.isClosed {
            Button("重新打开", systemImage: "arrow.uturn.backward") {
                KairosHaptics.ownershipChanged()
                store.reopen(item: item)
            }
            .tint(KairosPalette.attentionSolid)
        } else {
            Button("了结", systemImage: "checkmark") {
                KairosHaptics.ownershipChanged()
                store.finish(item: item)
            }
            .tint(KairosPalette.attentionSolid)
        }
    }

    // MARK: - 拖拽与排序（只在同一段里挪；换段是改优先级，走菜单）

    private func beginDrag(_ item: KairosItem) -> String {
        draggingItemID = item.id
        targetedItemID = nil
        KairosHaptics.pickedUp()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            if draggingItemID == item.id { finishDrag() }
        }
        return item.id
    }

    private func finishDrag() {
        draggingItemID = nil
        targetedItemID = nil
    }

    /// 挪一条只写一条的位置。**不重排它以外的任何一条**——
    /// 以前这里是「把当前这一段重排完，再按 P0…P3 的次序把四段拼成整张单子」，
    /// 于是分着堆看的时候挪一下，账本里 being 排的那张顺序就被拍平成了按档位排
    /// 现在不分组是默认，那一拍会直接改掉人下一眼看见的东西。
    private func reorder(_ item: KairosItem, toLandBefore target: KairosItem, after: Bool = false) {
        var ids = store.activeItems.map(\.id)
        ids.removeAll { $0 == item.id }
        guard let index = ids.firstIndex(of: target.id) else { return }
        ids.insert(item.id, at: after ? index + 1 : index)
        withAnimation(.smooth(duration: 0.24)) { store.reorderActive(ids) }
        KairosHaptics.dropped()
    }

    private func drop(_ sourceID: String, before target: KairosItem, in segment: String?) -> Bool {
        guard let source = items.first(where: { $0.id == sourceID }),
              source.id != target.id,
              // 分着堆看的时候只在同一堆里挪：拖到别的堆等于改档位 / 改状态，那是菜单的事，
              // 手一滑不该改掉一条待办的轻重。不分组时整张单子就是一堆，随便挪。
              segmentKey(of: source) == segment,
              segmentKey(of: target) == segment
        else {
            finishDrag()
            return false
        }
        // 存的是整条活动列表的顺序，别因为搜索时只看得见一部分就把看不见的丢了。
        reorder(source, toLandBefore: target)
        finishDrag()
        return true
    }

    private func move(_ item: KairosItem, by offset: Int, in segment: String?) {
        let section = rows(inSegment: segment)
        guard let index = section.firstIndex(where: { $0.id == item.id }) else { return }
        let neighbor = index + offset
        guard section.indices.contains(neighbor) else { return }
        reorder(item, toLandBefore: section[neighbor], after: offset > 0)
    }

    // MARK: - 头部

    /// 头是**两行**，和 Mac 的 `ListHeader` 同一个结构：
    ///
    ///     第一行  今天是几号（时钟不写——系统状态栏就在上面）
    ///     第二行  搜索框、筛选、显示
    ///
    /// 搜索**常驻**，不再是一颗放大镜点开之后把整行日期顶掉。那一版有两处不对：
    /// 一是它把「今天是几号」这个锚点在搜索时整个拿走，二是它自己得维护一个
    /// 「在不在搜索」的状态，而那个状态和 `query` 是不是空的说的是同一件事。
    /// 常驻之后这一屏少一个状态、多一个随时能点的框，行数不变（原来那颗放大镜也占一行）。
    /// **一行。**（按使用频次重排）
    ///
    /// 这一屏上高频的是：扫单子、点开一条、勾掉一条、记一条（右下角那颗）。
    /// 搜索、筛选、分组方式、请 being 看账本都是一天碰不了几次的——原来它们占着第二整行
    /// （常驻的搜索框 + 两颗图标），外加第一行一颗「跑一趟」，头比单子的第一条还高。
    /// 现在头只剩日期和三颗图标：🔍（点了才出框）、⋯（低频的全收在里面）、我。
    /// 省下来的那一行还给单子。
    ///
    /// 两件事**不许藏**，所以会在日期下面冒出来：正在搜（搜索框 + 取消）、
    /// 正在筛（一颗橙色小胶囊「筛选中 · 2 项 ✕」——不然人会以为待办丢了）。
    private var header: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Self.dayLine
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    searchButton
                    moreMenu
                    meButton
                }
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
                .padding(.trailing, -11)
            }
            if searching || isSearching {
                HStack(spacing: 12) {
                    SearchField(query: $query, autofocus: true)
                    Button("取消") {
                        query = ""
                        searching = false
                    }
                    .font(.body)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if activeFilterCount > 0, !isSearching {
                filterChip
                    .transition(.opacity)
            }
            if let askingWhat, store.isAskingBeing {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text(askingWhat)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.22), value: store.isAskingBeing)
        .animation(.snappy(duration: 0.24), value: searching)
        .animation(.snappy(duration: 0.22), value: activeFilterCount)
        .onChange(of: store.isAskingBeing) { _, asking in
            if !asking { askingWhat = nil }
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            if store.isRefreshing || store.isAskingBeing {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(height: 2)
                    .transition(.opacity)
            }
        }
        .background(.ultraThinMaterial)
        .animation(.snappy(duration: 0.22), value: store.isRefreshing)
        .sheet(isPresented: $filtering) {
            FilterSheet(
                scope: $scopeRaw,
                tiers: Binding(get: { tierFilter }, set: { tiersRaw = Self.encode($0) }),
                statuses: Binding(get: { statusFilter }, set: { statusesRaw = Self.encode($0) }),
                waiting: store.waitingPeopleCount
            )
            .presentationDetents([.height(260)])
            .presentationDragIndicator(.visible)
        }
    }

    private var searchButton: some View {
        Button {
            searching = true
        } label: {
            Image(systemName: "magnifyingglass")
                .kairosChromeGlyph()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("搜索")
    }

    /// 筛着东西时日期下面那颗小胶囊。点它改筛选，点 ✕ 清掉。
    private var filterChip: some View {
        HStack(spacing: 6) {
            Button {
                filtering = true
            } label: {
                Label("筛选中 · \(activeFilterCount) 项", systemImage: "line.3.horizontal.decrease")
                    .font(.footnote.weight(.medium))
            }
            .buttonStyle(.plain)
            Button {
                tiersRaw = ""
                statusesRaw = ""
                scopeRaw = KairosMacScope.all.rawValue
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.footnote)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("清除筛选")
        }
        .foregroundStyle(KairosPalette.attention)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(KairosPalette.attention.opacity(0.12), in: .capsule)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// ⋯：**所有低频的都在这里**——筛选、分组方式、显示已了结、请 being 看一眼账本。
    ///
    /// iOS 26 的提醒事项在同一个位置、用同一颗裸的 ⋯ 收「排序方式 / 显示完成项目」
    /// 字形不带圈：HIG 的 Toolbars 那页
    /// "Prefer system-provided symbols without borders"。
    private var moreMenu: some View {
        Menu {
            Button(activeFilterCount > 0 ? "筛选（\(activeFilterCount)）…" : "筛选…",
                   systemImage: "line.3.horizontal.decrease") {
                filtering = true
            }
            Picker("分组", selection: groupingBinding) {
                ForEach(KairosIOSGrouping.allCases) { value in
                    Label(value.title, systemImage: value.symbol).tag(value)
                }
            }
            .pickerStyle(.inline)
            // `eye`：提醒事项那颗「显示完成项目」用的就是眼睛；勾已经被行首那颗圈占着说「完了」。
            Toggle("显示已了结", systemImage: "eye", isOn: $showClosed)
            // 请 being 看一眼账本。只在它够不着账本时有（单机 / 对话线）——
            // 它在 Mac 上直接读写的时候，这一条按下去只会弹「不用我递给它」。
            if !store.beingReachesLedger {
                Divider()
                Button("请\(store.beingNameInline)看一眼账本", systemImage: "arrow.triangle.2.circlepath") {
                    askingWhat = "正在请\(store.beingNameInline)看一眼账本…"
                    Task { await store.nudgeLedgerRound() }
                }
                .disabled(store.isAskingBeing)
            }
        } label: {
            Image(systemName: "ellipsis")
                .kairosChromeGlyph()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("更多")
    }

    /// 「我」：接的是哪个 being、账本在哪。
    ///
    /// 2026-09-13 从底下那条 tab 挪到这儿。**图形没换**——还是原来 tab 上那颗
    /// `person.crop.circle`，位置照 Apple 自己把账号放右上角的规则（音乐、App Store、健身
    /// 都在这个点上）。换位置不换图形，人认的是那颗头像，重新认一遍的成本就是零。
    ///
    /// 为什么不留在底下：那一格一个月动两次，而底缘是拇指唯一扫得顺的一条带子
    /// （理由全文见 `RootView`）。为什么不塞进 ⋯：⋯ 里是「怎么看这张单子」，
    /// 这儿是「ta 是谁、这本账在哪」，两件事混一颗按钮，就得靠读菜单才知道点进去会发生什么。
    ///
    /// **也不许再往下藏。** 09-08 藏过一次「账本在哪」，结果是 Mac 上写的账本手机读不到，
    /// 而人根本找不到开关——这颗按钮就是那条链的入口，它必须一直在屏幕上看得见。
    private var meButton: some View {
        Button {
            showingMe = true
        } label: {
            Image(systemName: "person.crop.circle")
                .kairosChromeGlyph()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("我")
        .sheet(isPresented: $showingMe) {
            MeSheet(store: store)
        }
    }

    private var groupingBinding: Binding<KairosIOSGrouping> {
        Binding(
            get: { grouping },
            set: { groupingRaw = $0.rawValue }
        )
    }

    @ViewBuilder
    private var emptyState: some View {
        if isSearching {
            ContentUnavailableView("没搜到「\(query)」", systemImage: "magnifyingglass")
        } else {
            // 不写「今天」。这张单子**根本不按天筛**——它是全部还开着的事。
            // 顶上那个大日期是个锚点，不是筛选条件；空状态再说一句「今天没有事」，
            // 人第一天就会发现单子里躺着上周的东西，然后就再也不信那行日期了。
            if activeFilterCount > 0 {
                // 筛空了和真的没事是两回事。不说清楚，人会以为待办丢了——
                // 而他自己刚按下的那几个筛选就在上面那颗按钮里亮着数字。
                ContentUnavailableView(
                    "这几个条件下没有事",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("上面那颗「筛选」里清一下。")
                )
            } else {
                ContentUnavailableView(
                    "没有开着的事",
                    systemImage: "checkmark",
                    description: Text("想到什么，点右下角记一条。")
                )
            }
        }
    }

    /// 「9月3日」+「星期四」分两段写，靠字重和字号拉开对比——同一句话，两个层级。
    /// 用文本样式而不是写死的 34 / 19：`largeTitle` 默认正好是 34pt、`title3` 是 20pt，
    /// 和原来一模一样，但它们**跟着「文字大小」走**。写死的那两个数，在把字号调大的人
    /// 眼里就是一整屏的字都变大了、只有顶上这一行纹丝不动。
    private static var dayLine: Text {
        Text(formatted("MMMd"))
            .font(.largeTitle.weight(.bold))
            .foregroundColor(.primary)
        + Text("  " + formatted("EEEE"))
            .font(.title3)
            .foregroundColor(.secondary)
    }

    private static func formatted(_ template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans")
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: Date())
    }
}

/// 常驻的搜索框。原来它是点放大镜才出现、出现就把整行日期顶掉的一版，
/// 还带一颗「取消」。现在它一直在第二行躺着，所以不需要「取消」——不搜的时候它是空的，
/// 空的就是没在筛。留一颗清除给打错字的人（系统的 `.searchable` 免费给这一颗，
/// 这一屏用不了它：它要挂在导航栏上，而这一屏的导航栏是整个藏掉的）。
private struct SearchField: View {
    @Binding var query: String
    /// 点了放大镜才出来的框，一出来就要光标。
    var autofocus = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                // 放大镜是 `.secondary` 不是 `.tertiary`：系统搜索框里那颗是看得清的一档，
                // 淡到 tertiary 之后整个框读起来像是禁用的。
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索", text: $query)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($focused)
                if !query.isEmpty {
                    Button {
                        query = ""
                        focused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .frame(width: 32, height: 32)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, -8)
                    .accessibilityLabel("清除")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            // 胶囊，不是 12pt 圆角矩形：iOS 26 的搜索框是**全圆角**的
            // （系统的 `.searchable` 和相册 / 设置里那一条都是），12pt 在 38 高的框上
            // 看着方了一点点——就是那种「像原生但不是原生」的别扭。
            .background(Color.primary.opacity(0.06), in: .capsule)
        }
        .font(.body)
        .onAppear {
            if autofocus { focused = true }
        }
    }
}

/// 筛选面板：**看哪些**。三段，和 Mac 的 `FilterPanel` 同名同序（少一段「来源」）。
///
/// 做成 sheet 而不是菜单，是老账（Mac 那边同一条）：系统菜单里点一下 Toggle
/// **整份菜单当场关掉**，筛三个档位要开三次菜单，而且每次都看不见单子被筛成什么样。
/// sheet 半屏停着，勾几下、扫一眼后面的单子、再滑掉。
private struct FilterSheet: View {
    @Binding var scope: String
    @Binding var tiers: Set<String>
    @Binding var statuses: Set<String>
    /// 在等你的人数。摆在「消息」那一段上，和 Mac 一样——那个数字是原来 Inbox 角标
    /// 唯一真正有用的部分：不是有几封信，是**有几个人在等你**。
    let waiting: Int
    @Environment(\.dismiss) private var dismiss

    private var hasAny: Bool { !tiers.isEmpty || !statuses.isEmpty }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                // 「范围（全部 / 待办 / 消息）」那一段撤了：它在回答
                // 「这一条是不是一封信」，而人类这天的裁决是**全部都归到待办**，
                // 信不再是另一类东西，那一段于是在筛一个已经不存在的区分。
                section("优先级") {
                    chips(KairosTier.all, selected: $tiers) { $0 }
                }
                section("状态") {
                    chips(KairosStatus.open, selected: $statuses) { KairosStatus.label($0) }
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("筛选")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("清空") {
                        scope = KairosMacScope.all.rawValue
                        tiers = []
                        statuses = []
                    }
                    .disabled(!hasAny)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func chips(_ values: [String], selected: Binding<Set<String>>, label: @escaping (String) -> String) -> some View {
        HStack(spacing: 8) {
            ForEach(values, id: \.self) { value in
                let on = selected.wrappedValue.contains(value)
                Button {
                    var next = selected.wrappedValue
                    if on { next.remove(value) } else { next.insert(value) }
                    selected.wrappedValue = next
                    KairosHaptics.pickedUp()
                } label: {
                    Text(label(value))
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        // 开着：墨色实底反白字；关着：浅灰底。**不用橙**——
                        // 筛选开着不是「要你动手」，它只是一个开关的状态。
                        .background(
                            on ? KairosPalette.done : Color.primary.opacity(0.06),
                            in: Capsule()
                        )
                        .foregroundStyle(on ? KairosPalette.onDone : Color.primary.opacity(0.75))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 行

/// 行首那一颗，**一个图形说两件事**：形状说走到哪了，颜色说轻重。
///
/// 走到哪了是形状：整圈未开始、半实心进行中、虚线待定——和 Mac 的 `StatusGlyph`
/// 同一套词汇（Linear 那套），两端认同一个图形。
///
/// 轻重是这颗圈自己的颜色和粗细：P0 红且粗、P1 橙、P2 中性、P3 淡一档。
/// 以前它在容器左缘另画一道色条，于是行首有两样东西抢一眼——而人的手指本来就要
/// 落在这颗圈上（它就是勾选框）。合成一颗之后，**眼睛落点和手指落点是同一个**，
/// 一列圈扫下来颜色深浅就是轻重次序，没多占一个像素。
///
/// **颜色只有 P0 / P1 出声**（`KairosPalette` 那条「一块屏幕只养得起一个饱和色」没破）：
/// P2 是常规、P3 是有空再说，它们靠环的深浅分，不争那一眼。轻重不进形状、进度不借颜色，
/// 两个维度各走各的通道，才叠得住。
struct StatusRing: View {
    let status: String
    /// 轻重。`nil` = 这颗不表达轻重（段头那颗点）。
    var tier: String? = nil
    var size: CGFloat = 21

    private var level: String? { tier.map(KairosTier.normalized) }

    /// 环的颜色。P2/P3 用 `Color.primary` 的半透明而不是 `.secondary`：
    /// 这是条细线，不是文字，要的是压在卡片底上的确定深浅。
    private var ink: Color {
        switch level {
        case "P0": KairosPalette.critical
        case "P1": KairosPalette.attention
        // P3 淡一档，但**不敢再淡**：这颗圈同时是勾选按钮，深色模式下白色压到 0.17
        // 就快看不见按哪儿了（深色下实测）。0.20 和 P2 的 0.30 并排还分得出。
        case "P3": Color.primary.opacity(0.20)
        default: Color.primary.opacity(0.30)
        }
    }

    /// 粗细是颜色之外的第二条通道——分不出红橙的人，也分得出粗细。
    private var width: CGFloat {
        switch level {
        case "P0": 2
        case "P1": 1.6
        default: 1.2
        }
    }

    /// 进行中那半块实心。跟着环走，整颗只有一个颜色。
    private var fill: Color {
        switch level {
        case "P0": KairosPalette.critical
        case "P1": KairosPalette.attention
        case "P3": Color.primary.opacity(0.30)
        default: Color.primary.opacity(0.45)
        }
    }

    var body: some View {
        Group {
            switch KairosStatus.normalized(status) {
            case KairosStatus.doing:
                ZStack {
                    Circle().strokeBorder(ink, lineWidth: width)
                    Circle()
                        .trim(from: 0, to: 0.5)
                        .fill(fill)
                        .rotationEffect(.degrees(-90))
                        .padding(size * 0.22)
                }
            case KairosStatus.pending:
                Circle()
                    .strokeBorder(style: StrokeStyle(lineWidth: width, dash: [2.4, 2.2]))
                    .foregroundStyle(ink)
            default:
                Circle().strokeBorder(ink, lineWidth: width)
            }
        }
        .frame(width: size, height: size)
    }
}

/// 一条 = 一行，四段里长得一模一样：勾选圈、标题、一句副行——**现在要你干嘛**
/// （要判断什么；没有的话给一句是什么）。只留一行，扫得过去就行；背景在详情里，两处不重复。
/// 副行不写「下一步」——那是 being 的过程，不是给人看的。
/// being 有话要人拍板、或者答完了你还没看时，行尾亮一颗橙点；例行动静不亮（规则 5）。
/// being 正在答、你的话还在排队时，行尾是一个会消失的小状态（`RoomPulseMark`）。
struct ItemRow: View {
    @ObservedObject var store: KairosStore
    let item: KairosItem
    var isFirst = true
    var isLast = true
    /// 按状态分堆的时候关掉：段头已经写了「进行中」，每行再写一遍就是把同一句话说两次。
    var showsStatus = true
    let open: () -> Void

    @Environment(\.colorScheme) private var scheme
    /// 勾选圈跟着动态字体一起长。写死 21pt 的话，字号调到 AX 档时整行的字都变大了，
    /// 只有行首这颗圈还是原来那么小，看着像掉队的一粒。
    @ScaledMetric(relativeTo: .body) private var markerSize: CGFloat = 21

    private var checked: Bool { store.isChecked(item) }
    private var isClosed: Bool { item.isClosed }
    /// **只有已经了结的才整行变淡。** 刚勾上的那两秒（可以反悔）原来也整行压到 0.5——
    /// 点一下，整行先灰一下，两秒后才消失，看着像卡住了。
    /// 现在点下去只是圈变实心勾、标题划掉变灰，行本身不闪。
    private var dimmed: Bool { isClosed }
    private var tier: String { KairosTier.normalized(item.tier) }

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            marker
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // 消息行的标题以人开头：「Judy · 周四那版能不能先看」。名字不写进 title，
                    // 由行自己画（一百个人的时候，名字是唯一能快速扫的索引）。
                    Text(KairosItemRowTitle.line(item))
                        .font(.body.weight(.medium))
                        .lineSpacing(2)
                        .strikethrough(checked)
                        .foregroundStyle(checked ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    // 房间此刻怎么样了压过「已了结」：了结的那条也能进去问，问了就得看得见它在答。
                    if let pulse = store.roomPulse(for: item) {
                        RoomPulseMark(pulse: pulse, beingName: store.beingNameLeading)
                    } else if isClosed {
                        Text("已了结")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                if !secondaryLine.isEmpty || !statusLabel.isEmpty {
                    secondaryText
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .strikethrough(checked)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        // 一整组共用一块容器：首尾收圆角，中间平接，所以看起来是一块，不是 24 张卡。
        .background(KairosPalette.groupFill(scheme), in: containerShape)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 0.5)
                    .padding(.leading, 48)
            }
        }
        .opacity(dimmed ? 0.5 : 1)
        .contentShape(.rect)
    }

    private var containerShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: isFirst ? 20 : 0,
            bottomLeadingRadius: isLast ? 20 : 0,
            bottomTrailingRadius: isLast ? 20 : 0,
            topTrailingRadius: isFirst ? 20 : 0,
            style: .continuous
        )
    }

    /// 要判断什么优先，其次是摘要；和标题雷同的不重复念。
    private var secondaryLine: String {
        item.displayAsk.isEmpty ? item.displaySummary : item.displayAsk
    }

    /// 走到哪了。**只有非默认的两档出声**：未开始是默认，写出来等于每一行都顶一个
    /// 「未开始」，那就不是信号了；已了结由标题行尾那句和整行的淡出说。
    private var statusLabel: String {
        let value = KairosStatus.normalized(item.status)
        guard showsStatus, !isClosed, value != KairosStatus.todo else { return "" }
        return KairosStatus.label(value)
    }

    /// 副行 = 状态 + 现在要你干嘛。两段挤一行，状态靠字重分出来，不靠颜色也不靠胶囊——
    /// 一行里塞一个带底色的小标签，扫的时候先看见那块底色，而底色说的是最不重要的那件事。
    private var secondaryText: Text {
        guard !statusLabel.isEmpty else { return Text(secondaryLine) }
        let head = Text(statusLabel).fontWeight(.semibold)
        return secondaryLine.isEmpty ? head : head + Text("  ·  ") + Text(secondaryLine)
    }


    /// 已了结的不给勾——它已经是终点。
    /// 勾选圈自绘而不用 SF Symbol：细一档的环 + 勾上去时的回弹，是这一屏唯一的手感。
    ///
    /// **命中区 44×44，画出来还是 21。** 这是全 app 按得最多的一颗按钮，原来
    /// `.buttonStyle(.plain)` 加一个 22pt 的 frame，可点的就只有那 22pt——比 HIG 的
    /// 硬线小一半，而且它紧挨着「点这一行打开详情」：没按准不是没反应，是**进了详情**，
    /// 一个待办 app 里最恼人的误操作。
    /// 撑开靠 `.padding(11)` 造命中区、再用 `.padding(-11)` 把布局位置还回去，
    /// 所以这一行的排版一个像素没动。右边 11pt 落在 HStack 那 13pt 的间隙里，
    /// 吃不到标题的点击区。
    @ViewBuilder
    private var marker: some View {
        if isClosed {
            // **已了结也是这一套图形里的一档**。原来它是一个光秃秃的勾，
            // 没有圈——四档状态里唯一一个不长在圆上的，于是「这颗圈说走到哪了」那条
            // 在终点处断了。填满的圈加一个勾，和 Mac 的 `StatusGlyph(closed:)` 一样，
            // 一列扫下来是完整的一条：空环 → 半实心 → 实心勾。
            // 整行已经淡到 0.5，这里不用再压一次颜色。
            Circle()
                .fill(KairosPalette.done)
                .frame(width: markerSize, height: markerSize)
                .overlay(
                    Image(systemName: "checkmark")
                        .font(.system(size: markerSize * 0.52, weight: .bold))
                        .foregroundStyle(KairosPalette.onDone)
                )
                .frame(width: markerSize + 1, height: markerSize + 1)
                .accessibilityLabel("已了结")
        } else {
            Button {
                store.toggleChecked(item)
            } label: {
                ZStack {
                    StatusRing(status: item.status, tier: tier, size: markerSize)
                        .opacity(checked ? 0 : 1)
                    Circle()
                        .fill(KairosPalette.done)
                        .frame(width: markerSize, height: markerSize)
                        .overlay(
                            Image(systemName: "checkmark")
                                .font(.system(size: markerSize * 0.52, weight: .bold))
                                .foregroundStyle(KairosPalette.onDone)
                        )
                        .scaleEffect(checked ? 1 : 0.4)
                        .opacity(checked ? 1 : 0)
                }
                .frame(width: markerSize + 1, height: markerSize + 1)
                .animation(.spring(response: 0.32, dampingFraction: 0.58), value: checked)
                .padding(11)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(-11)
            .padding(.top, 1)
            // 颜色和粗细念不出来，所以轻重在这儿补一句：屏幕朗读也要拿得到这一维。
            .accessibilityLabel(checked ? "取消勾选" : "勾选待了结，\(tier)")
        }
    }
}

/// 标题行尾那一处：这条待办的房间此刻怎么样了（`KairosRoomPulse`）。和 Mac 的 `RoomPulseMark` 同一套。
///
/// 在答、在等是临时的：一个图形 + 一个词，气收了自己消失；常见的词都是三个字，换词时标题不重排。
/// 没看、没发出去是等你来的：只给一个记号，点进这一条就没了。没看就是「在等你」那颗橙点。
private struct RoomPulseMark: View {
    let pulse: KairosRoomPulse
    /// `beingNameLeading`：拉丁字母的名字后面带一个空格。
    let beingName: String

    var body: some View {
        switch pulse {
        case .working(let label, _):
            HStack(spacing: 4) {
                PulseDots()
                Text(label)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(beingName)\(label)")
        case .waiting(let label):
            // 钟：还没发出去、在等。不动——它还没开始。
            HStack(spacing: 3) {
                Image(systemName: "clock")
                Text(label)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
        case .unsent:
            // 和详情里「没发出去，点一下重发」同一个图形。
            Image(systemName: "exclamationmark.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(KairosPalette.critical)
                .accessibilityLabel("有一句没发出去")
        case .unread(let asking):
            Circle()
                .fill(KairosPalette.attention)
                .frame(width: 8, height: 8)
                .accessibilityLabel(asking ? "\(beingName)在等你" : "\(beingName)回你了，还没看")
        }
    }
}

/// 行尾的三个点：详情里那三个点（`ThinkingDots`）缩到一个字高，节拍一样。
private struct PulseDots: View {
    @State private var phase = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .frame(width: 3.5, height: 3.5)
                    .opacity(reduceMotion ? 0.55 : (phase == index ? 1 : 0.3))
            }
        }
        .task(id: reduceMotion) {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(320))
                withAnimation(.easeInOut(duration: 0.25)) { phase = (phase + 1) % 3 }
            }
        }
    }
}

private struct ItemDragPreview: View {
    let item: KairosItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
                .font(.body.weight(.semibold))
                .lineLimit(2)
            let detail = item.displayAsk.isEmpty ? item.displaySummary : item.displayAsk
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(width: 280, alignment: .leading)
        .padding(16)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .shadow(color: .black.opacity(0.2), radius: 22, y: 12)
    }
}

enum KairosHaptics {
    static func pickedUp() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    static func dropped() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }

    static func ownershipChanged() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
    }
}
