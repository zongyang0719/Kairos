import SwiftUI

@main
struct KairosApp: App {
    @StateObject private var store = KairosStore()
    @Environment(\.scenePhase) private var scenePhase
    /// 首启三页引导。看完写 true；「我」里「重看引导」会把它打回 false，全屏再播一遍。
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    /// 第二页「去连接」：引导关了就开「我」sheet，不经过单子右上角那颗按钮——人还在首启路径上。
    @State private var openMeAfterOnboarding = false

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView(store: store)
                    // 改动通知是攒几秒再发的（见 `KairosStore.announce`）。手机单机时这条
                    // 通知是改动到 being 那儿的一条主路，切出去之前把攒着的倒出去，别烂在内存里。
                    .onChange(of: scenePhase) { _, phase in
                        guard phase != .active else { return }
                        Task { await store.flushPendingAnnouncements() }
                    }

                if !hasSeenOnboarding {
                    OnboardingView { finish in
                        hasSeenOnboarding = true
                        if finish == .connectBeing {
                            openMeAfterOnboarding = true
                        }
                    }
                    .transition(.opacity)
                }
            }
            .animation(.snappy(duration: 0.28), value: hasSeenOnboarding)
            .sheet(isPresented: $openMeAfterOnboarding) {
                MeSheet(store: store)
            }
        }
    }
}
