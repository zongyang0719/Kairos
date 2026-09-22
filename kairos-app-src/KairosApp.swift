import SwiftUI

@main
struct KairosApp: App {
    @StateObject private var store = KairosStore()
    @StateObject private var shell = KairosMacShell()

    init() {
        // 启动 8 秒后静默查一次 GitHub Release（24h 限一次），结果只显示在设置「软件更新」里。
        KairosUpdater.shared.scheduleLaunchCheck()
    }

    var body: some Scene {
        WindowGroup {
            OnboardingHost(store: store, shell: shell)
        }
        .defaultSize(width: 1240, height: 820)
        // **整个窗口只有一行顶**：红绿灯、日期、单子的按钮、右侧的「收起」站在同一排。
        //
        // 必须是 `.unified`，而且工具栏里得真有东西。没有工具栏时 macOS 画的是一条老式标题栏，
        // 横贯整个窗口：边栏的玻璃被压在它底下、红绿灯悬在玻璃外面，单子自己再垫一块头——
        // 顶上就叠出两条带子。有了工具栏，边栏才是贴满整高的那块玻璃（红绿灯在它里面），
        // 顶上那一排就是日期和按钮本身，不再是一块另外的地方。
        //
        // 标题不画（app 名在菜单栏和 Dock 上都写着）；位置由工具栏里那颗弹性空白排，
        // 撤掉标题那一格不会把按钮挤到左边去。
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { commands }

        Settings {
            KairosSettingsView(store: store, shell: shell)
        }
    }

    @CommandsBuilder
    private var commands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建待办") { shell.newItem(store) }
            .keyboardShortcut("n")
            Button("新建项目…") { shell.creatingProject = true }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }

        // ⌘F。搜索框从窗口工具栏挪到了单子头上（`MacSearchField`），
        // `.searchable` 白送的那个快捷键也跟着没了，在这儿补回来。
        CommandGroup(after: .textEditing) {
            Button("搜索") { shell.searchTick += 1 }
                .keyboardShortcut("f")
        }

        // 显示相关的都进系统的「View」菜单，不另开一个。
        CommandGroup(after: .sidebar) {
            Divider()
            Picker("分组", selection: $shell.grouping) {
                ForEach(KairosMacGrouping.allCases) { grouping in
                    Text(grouping.title).tag(grouping)
                }
            }
            Toggle("显示已了结", isOn: $shell.showClosed)
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("存为视图…") { shell.savingView = true }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button(shell.inspectorShown ? "收起右侧" : "打开右侧") {
                if shell.inspectorShown {
                    shell.closeInspector(store)
                } else if store.selectedItem != nil {
                    shell.roomShown = true
                }
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(!shell.inspectorShown && store.selectedItem == nil)
        }

        CommandMenu("待办") {
            if let item = store.selectedItem, item.isClosed {
                Button("重新打开") { store.reopen(item: item) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            } else {
                Button("了结") {
                    if let item = store.selectedItem {
                        store.finish(item: item)
                    }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(store.selectedItem == nil)
            }
            Menu("状态") {
                ForEach(KairosStatus.open, id: \.self) { value in
                    Button(KairosStatus.label(value)) {
                        if let item = store.selectedItem { store.setStatus(item, to: value) }
                    }
                }
            }
            .disabled(store.selectedItem == nil)
            Menu("优先级") {
                ForEach(KairosMacTier.all, id: \.self) { value in
                    Button(value) {
                        if let item = store.selectedItem { store.setTier(item, to: value) }
                    }
                }
            }
            .disabled(store.selectedItem == nil)
            Menu("项目") {
                Button("无") {
                    if let item = store.selectedItem { store.macSetProject([item.id], to: "") }
                }
                ForEach(store.macProjects, id: \.self) { project in
                    Button(project) {
                        if let item = store.selectedItem { store.macSetProject([item.id], to: project) }
                    }
                }
            }
            .disabled(store.selectedItem == nil)
            Button("编辑…") { store.editingItem = store.selectedItem }
                .keyboardShortcut("e")
                .disabled(store.selectedItem == nil)
            Button("删除…") { shell.pendingDeleteIDs = Array(store.selectedItemIDs) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(store.selectedItem == nil)
            Divider()
            Button("刷新账本") { Task { await store.refresh() } }
                .keyboardShortcut("r")
                .disabled(store.isRefreshing)
        }
    }
}

/// 主窗口 + 首启引导 sheet。
///
/// `openSettings` 是 SwiftUI 环境值，只能在 `View` 里取，不能挂在 `@main` 的 `App` 上，
/// 所以用一层 Host 包住 `KairosWindow`。
///
/// `onChange(of: hasSeenOnboarding)` 与 `onAppear` 一起驱动 sheet：设置里「重看引导」会把
/// `hasSeenOnboarding` 打回 `false`，主窗必须再次弹出引导，不能只靠首次 `onAppear`。
private struct OnboardingHost: View {
    @ObservedObject var store: KairosStore
    @ObservedObject var shell: KairosMacShell
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var showOnboarding = false
    @State private var openSettingsAfterOnboarding = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        KairosWindow(store: store, shell: shell)
            // 右侧开着时窗口至少要这么宽，不然分栏放不下、来回算到 app 被杀（`KairosMacLayout`）。
            // 窄窗口里点开一条，系统会顺着这个最小宽度把窗口撑开，不用自己算。
            .frame(
                minWidth: shell.showsRoom(store) ? KairosMacLayout.windowMinWidthWithRoom : KairosMacLayout.windowMinWidth,
                minHeight: KairosMacLayout.windowMinHeight
            )
            .onAppear { showOnboarding = !hasSeenOnboarding }
            .onChange(of: hasSeenOnboarding) { _, seen in showOnboarding = !seen }
            .sheet(isPresented: $showOnboarding) {
                // 三页都看完才结束；`onFinish` 只会在第 3 页触发，此处统一写入 hasSeenOnboarding。
                KairosOnboardingView { finish in
                    hasSeenOnboarding = true
                    if finish == .connectBeing {
                        openSettingsAfterOnboarding = true
                    }
                }
                .interactiveDismissDisabled()
                .frame(width: 640, height: 560)
            }
            .onChange(of: openSettingsAfterOnboarding) { _, open in
                guard open else { return }
                openSettingsAfterOnboarding = false
                openSettings()
            }
    }
}
