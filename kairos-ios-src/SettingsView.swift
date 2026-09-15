import SwiftUI
import UniformTypeIdentifiers

/// 「我」：接的是哪个 being、连不连得上、账本在哪。就这三件事。
///
/// 2026-09-13 它从一个 tab 变成**一张 sheet**（入口是单子右上角那颗头像，见
/// `ItemsView.meButton`）：这一屏是「设置好就走」，不是一个要常驻在底缘的去处。
/// 右上角一颗「完成」把它关掉——链接那一栏如果改了没存，「完成」顺手存（存不进就不关，
/// 错误留在那栏底下），所以不再需要单独那颗「保存」：一屏一个出口，人不用判断
/// 「关掉之前是不是得先按保存」。
///
/// 「账本在哪」那一节不能藏——
/// 藏了按钮等于开关永远配不上，being 在 Mac 上写的账本手机读不到，手机的 outbox 也没人收。
/// 单机仍是默认：不接就只有 loom 那条线，接上 being 才够得着账本。
struct MeSheet: View {
    @ObservedObject var store: KairosStore
    @State private var api: String
    @State private var token: String
    @State private var saved = false
    @State private var errorMessage: String?
    @State private var picking = false
    @State private var folderError: String?
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = true
    @Environment(\.dismiss) private var dismiss

    init(store: KairosStore) {
        self.store = store
        _api = State(initialValue: store.connection?.api ?? "")
        _token = State(initialValue: store.connection?.token ?? "")
    }

    private var dirty: Bool {
        api.trimmingCharacters(in: .whitespacesAndNewlines) != (store.connection?.api ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    identity
                }

                Section {
                    // 只要一个链接。token 藏在链接的 ?token= 里，KairosConnection.normalized 会拆出来。
                    TextField("Being 链接", text: $api, prompt: Text("粘整条 loom 链接"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.done)
                        .onSubmit { _ = save() }
                        .onChange(of: api) { saved = false }
                } header: {
                    Text("Being")
                } footer: {
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    } else if saved {
                        Text("已保存")
                    } else {
                        Text(token.isEmpty ? "链接里要带 ?token=…" : "已从链接里读到 token")
                    }
                }

                ledgerSection

                Section {
                    Button("重看引导") {
                        hasSeenOnboarding = false
                        dismiss()
                    }
                } footer: {
                    Text("首启那三页说明，随时可再看一遍。")
                }
            }
            .navigationTitle("我")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { done() }
                }
            }
        }
    }

    // MARK: - 账本在哪

    /// being 手上有没有这本账。
    ///
    /// 不接：手机单机，账本只在这台机器里。being 看不见，只能你按「跑一趟」时把清单念给它听，
    /// 它写的东西也只在那一趟回来。接上：being 在 Mac 上直接读写账本，你手机上的改动
    /// 走 `outbox/<设备>.json` 等它来收。
    ///
    /// **不是 8-30 那个 iCloud。** 那次是两边都写同一个文件，撞出 8 条真冲突。
    /// 现在手机绝不写账本，只写自己那个没有第二个写者的 outbox。
    @ViewBuilder
    private var ledgerSection: some View {
        Section {
            if store.isSharedFolderConfigured {
                LabeledContent("账本文件夹", value: store.sharedFolderName ?? "已接上")
                if store.pendingToMacCount > 0 {
                    LabeledContent("等\(store.beingNameInline)来收", value: "\(store.pendingToMacCount) 条改动")
                        .foregroundStyle(.secondary)
                }
                // 这一行是给排查用的：切换是自动的，不写出来人看不见自己在哪条路上，
                // 「being 怎么不动了」就没法自查。
                LabeledContent("\(store.beingNameLeading)走哪条路") {
                    Text(store.beingReachesLedger ? "在 Mac 上直接读写" : "对话线 · 那头没人来收")
                        .foregroundStyle(store.beingReachesLedger ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                }
                Button("断开，回到单机", role: .destructive) { store.forgetSharedFolder() }
            } else {
                // 单机时也要能看见账本在哪。「数据在哪、是不是自己的，得让人看得见」——
                // 文件 App → 我的 iPhone → Kairos 里就是这个文件。
                LabeledContent("位置", value: "本机 · 文件 App › 我的 iPhone › Kairos")
                    .font(.footnote)
                Button("接上 Mac 的账本") { picking = true }
            }
        } header: {
            Text("账本")
        } footer: {
            if let folderError {
                Text(folderError).foregroundStyle(.red)
            } else if store.isSharedFolderConfigured {
                Text(store.beingReachesLedger
                    ? "\(store.beingNameLeading)在 Mac 上读写这本账。你在手机上改的先落自己的 outbox，等 ta 来收——手机绝不直接写账本。断开时，此刻看到的这些会留在本机那份里。"
                    : "改动堆了半小时没人收，多半是 Mac 关着——\(store.beingNameLeading)读写账本靠的是在 Mac 上执行命令，Mac 一关这只手就没了。这段时间它改走对话线（单子顶上那颗「跑一趟」），Mac 一回来自动切回去。")
            } else {
                Text("现在是单机：账本只在这台手机里，不接 iCloud 也照常用，\(store.beingNameInline)看不见。接上 iCloud 里那个 Kairos 文件夹之后，单机期间攒的条目会排队等 Mac 收进共享账本，一条都不会丢。")
            }
        }
        // 选的是**文件夹**不是文件：手机要读账本、还要写自己的 outbox，
        // 只给一个文件的书签够不到同目录下别的文件。
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            do {
                guard case .success(let url) = result else { return }
                try store.adoptSharedFolder(url)
                folderError = nil
            } catch {
                folderError = error.localizedDescription
            }
        }
    }

    /// 名字只写一遍。头像是名字的第一个字，点一下重新连一次——它就是那颗「点」的意思。
    private var identity: some View {
        Button {
            Task { await store.checkBeing() }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    // 头像是中性灰底，不是橙色渐变：它是「这是谁」，不是「要你动手」。
                    Circle()
                        .fill(Color(uiColor: .tertiarySystemFill))
                        .frame(width: 44, height: 44)
                    Text(String(store.beingName.prefix(1)))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.beingName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(statusLine)
                        .font(.footnote)
                        .foregroundStyle(statusColor)
                }
                Spacer(minLength: 0)
                if case .checking = store.connectionState {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(store.connection == nil)
        .accessibilityLabel("\(store.beingName)，\(statusLine)，点一下重新连接")
    }

    /// 状态说状态，不再把名字念第二遍。
    private var statusLine: String {
        switch store.connectionState {
        case .notConfigured: "还没接入——把 loom 链接粘到下面"
        case .configured: "还没试过连不连得上，点一下试试"
        case .checking: "正在连接…"
        case .online: "已连接"
        case .offline: "连不上，稍后再点一下"
        }
    }

    private var statusColor: Color {
        switch store.connectionState {
        case .online: .green
        case .offline: .red
        default: .secondary
        }
    }

    /// 关掉这一屏。改了链接没存的话先存——存不进就留在这儿，让人看见那行红字。
    /// 别的开关（接账本、断开）都是当场生效的，没有「未保存」这回事。
    private func done() {
        if dirty, !api.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard save() else { return }
        }
        dismiss()
    }

    @discardableResult
    private func save() -> Bool {
        do {
            // 链接里没带 token 时沿用上次存的，别把人家配好的 token 清掉。
            let normalized = KairosConnection.normalized(KairosConnection(api: api, token: "", name: ""))
            let value = KairosConnection(
                api: normalized.api,
                token: normalized.token.isEmpty ? token : normalized.token,
                name: store.connection?.name ?? ""
            )
            try store.updateConnection(value)
            token = value.token
            saved = true
            errorMessage = nil
            return true
        } catch {
            saved = false
            errorMessage = error.localizedDescription
            return false
        }
    }
}
