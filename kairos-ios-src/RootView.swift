import SwiftUI

/// 根：**一张单子，底下没有 tab 条**。
///
/// 09-12 把 Inbox 并进单子之后，底下那条胶囊只剩「事项 / 我」两格。两格的标签栏有两处不对：
///
///   一、HIG 的标签栏是给**三到五个同级去处**的。剩两个的时候，那条胶囊一半的宽度在说
///       「你还可以去别的地方」，而其实没有别的地方。
///   二、更要紧的是这两格**不同级**。「事项」是这个 App 本身；「我」是接哪个 being、
///       账本在哪——一个月动两次。让它长期占住底缘（拇指唯一扫得顺的那条），
///       等于把最贵的一块地分给了最少做的事。
///
/// 所以：**单子不再需要一颗按钮去**（人已经站在上面了），「我」挪到单子顶上那行的右上角
/// （Apple 自己把账号放在右上角；图形还是原来 tab 上那颗 `person.crop.circle`，不用重新认，
/// 见 `ItemsView.meButton`），底下只留新建那一颗。底部于是只剩一件东西，它就是这一屏
/// 唯一的动作，也不用再跟任何胶囊压中线了（原来那个 -11pt 就是为了跟 tab 条对齐量出来的）。
///
/// **新建没有搬到中间去「突出」。** 中间突出那一路（Instagram、一堆 Android App）是把动作
/// 塞进导航条：一颗长在去处中间、按下去却不换屏的东西，破的是「长得一样的东西行为也一样」。
/// HIG 也明写标签栏只放去处、不放动作。何况 tab 条一撤，本来就没有「中间」可站了。
/// Apple 自己的单子型 App 都把新建放在**底缘**：提醒事项在左下、带文字；备忘录在右下、一颗圆。
/// 这儿跟备忘录——右下是右手拇指最顺的地方，一颗 56 的圆，长按多一条「写信…」。
///
/// 「想法」那一屏更早就没了：想到什么就是一条事项，直接在单子上建。
struct RootView: View {
    @ObservedObject var store: KairosStore
    @State private var watcher: CloudLedgerWatcher?
    /// 新建那张 sheet 归这一层管：那颗按钮浮在单子上面，不在单子那一屏里。
    @State private var composing = false
    /// 单子那一屏有没有 push 出详情。详情底下自己有一个输入框（跟 being 说这件事），
    /// 这颗新建按钮压在它右边就是两颗按钮抢同一块地方——所以详情一开它就让位。
    /// 这一层看不见 NavigationStack 里发生了什么，由那一屏自己说（`ItemsView`）。
    @State private var detailOpen = false
    @Environment(\.undoManager) private var environmentUndoManager
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack { ItemsView(store: store, detailOpen: $detailOpen) }
            // 日期跟着界面走中文。必须挂在 NavigationStack **外面**：挂在里面
            // 只管得到列表那一屏，push 出去的详情由 stack 托管，拿不到这个
            // environment，于是往来的时间戳会变回「Sep 7 at 21:35」（实测）。
            .environment(\.locale, Locale(identifier: "zh_Hans"))
            // 系统控件（「完成」「取消」「添加」、链接、开关）跟 app 那一个橙走，不跟系统蓝走：
            // 原来「我」那张表里「接上 Mac 的账本」是蓝的、新建表的「添加」是蓝的——
            // 一个 app 两个强调色。备忘录用黄统一所有控件，这里用橙。Mac 那边同一条（`.tint`）。
            .tint(KairosPalette.attention)
            .alert(
                "提示",
                isPresented: Binding(
                    get: { store.notice != nil },
                    set: { if !$0 { store.notice = nil } }
                ),
                presenting: store.notice
            ) { _ in
                Button("好") { store.notice = nil }
            } message: { notice in
                Text(notice)
            }
            .overlay(alignment: .bottom) {
                if let notice = store.undoNotice {
                    UndoCapsule(notice: notice, store: store)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 76)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                // 新建那张表开着的时候也让位：iOS 26 的 sheet 是半透玻璃，这颗橙色的圆
                // 会从表的右下角透出来一团糊橙。
                if !detailOpen, !composing {
                    composeButton
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .sheet(isPresented: $composing) {
                ComposeItemSheet(store: store)
            }
            .animation(.snappy(duration: 0.24), value: detailOpen)
            .animation(.snappy(duration: 0.2), value: composing)
            .animation(.snappy(duration: 0.28), value: store.undoNotice)
            .onAppear {
                if KairosDebugLaunch.compose { composing = true }
                if let environmentUndoManager {
                    store.undoManager = environmentUndoManager
                }
                // 以前记在「想法」里的东西一次性变成事项，别让它们随那一屏一起消失。
                store.absorbSeedsIntoItems()
            }
            // iCloud 是自动同步的，但手机 App 得自己去看：回到前台读一次，前台期间盯着云上的新版本。
            // 只读本机文件，不发任何网络请求——「打开应用零通信」不破。
            .onChange(of: scenePhase, initial: true) { _, phase in
                switch phase {
                case .active:
                    store.reloadFromDisk()
                    // 没接 iCloud 的时候手机就是单机，没什么可盯的。
                    guard SharedLedgerFolder().isConfigured else { break }
                    if watcher == nil {
                        watcher = CloudLedgerWatcher { [store] in
                            store.reloadFromDisk()
                        }
                    }
                    watcher?.start()
                case .background:
                    watcher?.stop()
                default:
                    break
                }
            }
    }
}

private extension RootView {
    /// 一颗按钮，一件事：记一条事项。
    ///
    /// 它原来是个菜单（长按多一条「写信…」）。2026-09-13 取信整个功能撤了，写信跟着撤——
    /// 只出不进的信箱是骗人的：你写出去，对方回的那封你在 Kairos 里永远看不到。
    /// 要回某个人，那就是单子上的一条待办。菜单没了之后这颗回到最简单的形态：**点一下就是记**。
    var composeButton: some View {
        Button {
            composing = true
        } label: {
            // 这一颗是 `onAccent` 的例外，白字写死：底是固定的深橙（`attentionSolid`），
            // 前景两个模式都用白，稳在 4.88:1。
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        // **实色，不是玻璃**。玻璃的 tint 不是实底，它把橙掺进身后的东西里，
        // 深色模式下掺出来发闷——而这是全屏唯一的主操作，它该是最确定的那一块颜色。
        // Apple 自己在同一个位置用的就是实色：iOS 26 提醒事项右下角那颗是实心蓝圆 + 白 plus。
        .background(KairosPalette.attentionSolid, in: .circle)
        .shadow(color: KairosPalette.attentionSolid.opacity(0.35), radius: 16, y: 8)
        .padding(.trailing, 16)
        // tab 条撤了之后这颗不再跟谁压中线，照安全区站。
        .padding(.bottom, 2)
        .accessibilityLabel("新事项")
    }
}

private struct UndoCapsule: View {
    let notice: KairosUndoNotice
    @ObservedObject var store: KairosStore

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.uturn.backward")
                .foregroundStyle(.secondary)
            Text(notice.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("撤销") { store.performUndo() }
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
        .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
        .task(id: notice.id) {
            try? await Task.sleep(for: .seconds(5))
            store.dismissUndoNotice(notice.id)
        }
        .accessibilityElement(children: .contain)
    }
}

/// 只在 Debug 包里认的启动参数，给截图和自动化用：`SIMCTL_CHILD_KAIROS_DEBUG_TAB=me`、
/// `…_OPEN=<事项 id>`、`…_COMPOSE=1`。Release 包里这几个永远是 nil / false。
///
/// `KAIROS_DEBUG_TAB` 这个名字留着没改：tab 条撤了，但「一上来就打开『我』」这件事还在
/// （现在它是一张 sheet），已有的截图脚本不必跟着改。
enum KairosDebugLaunch {
    static var openMe: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment["KAIROS_DEBUG_TAB"] == "me"
#else
        false
#endif
    }

    static var openItemID: String? {
#if DEBUG
        ProcessInfo.processInfo.environment["KAIROS_DEBUG_OPEN"]
#else
        nil
#endif
    }

    static var compose: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment["KAIROS_DEBUG_COMPOSE"] == "1"
#else
        false
#endif
    }
}
