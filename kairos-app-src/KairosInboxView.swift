import AppKit
import SwiftUI

// MARK: - 信：Beings Town 邮局，混在同一张单子里
//
// 信也是待办——邮局进来的每一封都是「我和 being 的协作待办」，
// 所以它不单独占一屏：在同一张列表里一人一行，顶上「全部 / 待办 / 信」轻量区分。
// 点一行，右侧检查器出这个人的来往信；一封一张卡，底下回信。
//
// 收件箱的主权在 being 手里，Kairos 只是那扇窗——发出去的落款是 being ，不是人类，界面上得说出来。
// Mac 上和 Town 之间那段路只有 being 能走（Town 的 DM 按 IP 信任 being 的 Heart，Mac 打过去 401）：
// 镜像 mailbox.json 是 being 用 `ledger/cli.js mail-sync` 写的，这边只读；
// 写信只落进这台机器的草稿箱 `mail-outbox/<设备>.json`，being `mail-pending` 看到才真的投出去。
// 所以「待发送」是常态，不是错误状态；「叫 being 去一趟」是这里唯一会说话的动作。

// 这里原来还有三样：`MailRow`（列表里的一行信）、`MailBoardCard`（看板里的一张信卡）、
// `MailMenuContent`（信的右键菜单）。2026-09-11「消息也是账本上的一行」之后它们就空转了——
// 单子上只剩一种行（`ItemRow` 画 `KairosItem`），没有任何地方再去实例化那三个，
// 连带 `KairosViews` 里那个 `KairosMailRowTag`（给信行发的 `mail:` 前缀 tag）也没人发了。
// 一并撤掉，约 130 行。剩下的 `MailThreadScreen` 还活着：写完一封信之后右侧要打开
// 那个人的来往，走的是 `shell.selectedCorrespondent` 那条路。

// MARK: - 一个人的来往信（右侧检查器）

struct MailThreadScreen: View {
    @ObservedObject var store: KairosStore
    @EnvironmentObject private var shell: KairosMacShell
    let correspondent: String
    @State private var draft = ""
    @State private var sendError: String?
    /// 信是不是已经滚到抬头底下了——只用来决定抬头底下那条分界线画不画。
    @State private var scrolled = false

    /// 和房间同一套：草稿按人存（`mail:<谁>`）。这一屏也是 `.id(correspondent)` 建的，
    /// 换个人就整个重建，光靠 `@State` 一样会把写了一半的回信弄丢。
    private var draftBinding: Binding<String> {
        Binding(
            get: { draft },
            set: { value in
                draft = value
                store.setRoomDraft(value, for: "mail:" + correspondent)
            }
        )
    }

    private var thread: KairosMailThread? {
        store.mailThreads.first { $0.correspondent == correspondent }
    }

    /// 和房间（ItemRoomView）同一个骨架：抬头钉在顶上不跟着滚，底下一条输入。别用 `.bar` 底、
    /// 别用 `.roundedBorder` 输入框——那两样在检查器里都会把整列撑宽再被裁掉。
    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 10)
                .overlay(alignment: .bottom) {
                    // 只有信真的滚到抬头底下了才画这条线：没东西被挡住就不需要分界。
                    Divider().opacity(scrolled ? 1 : 0)
                }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(thread?.entries ?? []) { entry in
                            MailCard(entry: entry, correspondent: correspondent, store: store)
                                .id(entry.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top > 2
                } action: { _, moved in
                    withAnimation(.easeOut(duration: 0.15)) { scrolled = moved }
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: thread?.entries.count ?? 0) {
                    withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            // 和房间一样，输入框上面不画横线。
            replyBar
        }
        .background(ScrollerTamer())
        .task(id: correspondent) {
            draft = store.roomDraft("mail:" + correspondent)
            store.markMailThreadRead(correspondent)
        }
        .onChange(of: thread?.unreadCount ?? 0) { store.markMailThreadRead(correspondent) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(correspondent)
                .font(.title2.weight(.semibold))
                .padding(.trailing, 34)
            Text("\(store.beingNameLeading)代收代发 · 上次去邮局\(KairosMailWording.relative(store.mailbox.syncedAt))")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 6) {
                if let thread {
                    // 看完就在这儿收掉，不用回列表右键——处理完那一刻手就在这一屏上。
                    Button {
                        if thread.isDone {
                            store.reopenMailThread(correspondent)
                        } else {
                            store.markMailThreadDone(correspondent)
                            shell.closeInspector(store)
                        }
                    } label: {
                        // 底圆还是 26，命中区 32：背景画在 26 那一层上，撑开的 padding
                        // 在它外面，所以圆没变大、只是更好按。
                        Image(systemName: thread.isDone ? "arrow.uturn.backward" : "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 26, height: 26)
                            .background(Color.primary.opacity(0.06), in: .circle)
                            .padding(3)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(-3)
                    .help(thread.isDone ? "重新打开" : "了结")
                    .accessibilityLabel(thread.isDone ? "重新打开" : "了结")
                }
            }
        }
    }

    private var replyBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 发不出去就地说，别只靠全局弹窗——那个弹窗关掉就找不回来了。
            if let sendError {
                Text(sendError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            // 和房间的输入框同一套（`ComposerBox`）：能滚、能拖着改高矮、能把文字拖进来。
            // 别用 `.roundedBorder` 的多行 TextField——它在检查器里会要一个比列宽还大的
            // 最小宽度，把整列撑宽再被居中裁掉（右边会切掉半个「发送」）。
            HStack(alignment: .bottom, spacing: 10) {
                ComposerBox(
                    text: draftBinding,
                    placeholder: "回信",
                    heightKey: "composer.mail.height",
                    onSend: send
                )
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(KairosMacPalette.attention, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draftEmpty)
                .opacity(draftEmpty ? 0.38 : 1)
                .help("放进草稿箱，等\(store.beingNameInline)发出（回车 / ⌘回车）")
                .accessibilityLabel("发送")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        // 和房间的输入框一样：下沿对齐左边边栏玻璃的下沿。
        .padding(.bottom, 8)
    }

    private var draftEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard !draftEmpty else { return }
        do {
            try store.sendMail(to: correspondent, content: draft)
            draft = ""
            store.setRoomDraft("", for: "mail:" + correspondent)
            sendError = nil
        } catch {
            sendError = error.localizedDescription
        }
    }
}

/// 一封信一张卡（「邮件」的会话视图那样）：抬头是谁、几点、状态，下面是正文。
private struct MailCard: View {
    let entry: KairosMailEntry
    let correspondent: String
    @ObservedObject var store: KairosStore

    private var outgoing: Bool { entry.direction == .outgoing }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(outgoing ? store.beingName : correspondent)
                    .font(.subheadline.weight(.semibold))
                if let status = statusLabel {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }
                Spacer(minLength: 0)
                Text(entry.date, format: .dateTime.month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(entry.content)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = entry.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KairosMacPalette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .contextMenu {
            if let draftID = entry.draftID {
                Button("撤回", systemImage: "arrow.uturn.backward", role: .destructive) {
                    store.discardMailDraft(draftID)
                }
            }
        }
    }

    /// 投递状态原样说人话。Town 以后加新状态，这里显示它的原文，不吞掉。
    private var statusLabel: String? {
        switch entry.status {
        case .none: nil
        case .pending: "等\(store.beingNameInline)发出"
        case .delivered: "已送达"
        // 对方拒收不是故障，是邮局许诺给对方的权利（「你能拒收某个人」）。
        // 说成「失败」会让人以为该重发——那正好是最不该做的事。
        case .rejected: "对方拒收"
        case .failed: "没送到"
        case .other(let raw): raw
        }
    }

    private var statusColor: Color {
        switch entry.status {
        case .failed, .rejected: .orange
        default: .secondary
        }
    }
}

// MARK: - 写新的一封

struct MailComposerSheet: View {
    @ObservedObject var store: KairosStore
    @ObservedObject var shell: KairosMacShell
    @Environment(\.dismiss) private var dismiss
    @State private var recipient = ""
    @State private var content = ""
    @State private var sendError: String?
    @FocusState private var focused: Bool

    private var ready: Bool {
        !recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("写信").font(.headline)
            Form {
                TextField("收件人", text: $recipient, prompt: Text("对方的名字"))
                    .focused($focused)
                TextField("正文", text: $content, prompt: Text("写点什么"), axis: .vertical)
                    .lineLimit(5...12)
            }
            .formStyle(.columns)
            // 收件人解析规则照抄 Town 的 /api/messages/help：
            // being_id 精确 > 显示名精确 > 忽略大小写，必须唯一命中。
            Text("名字就行，不用记编号；重名会退回来让你说清是谁。落款是\(store.beingNameTrailing)，先进草稿箱，ta 下次去邮局才投出去。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let sendError {
                Text(sendError).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("放进草稿箱", action: send)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!ready)
            }
        }
        .padding(22)
        .frame(width: 520)
        .onAppear { focused = true }
    }

    private func send() {
        guard ready else { return }
        do {
            try store.sendMail(to: recipient, content: content)
            shell.closeInspector(store)
            shell.selectedCorrespondent = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
            dismiss()
        } catch {
            sendError = error.localizedDescription
        }
    }
}

// MARK: - 措辞

enum KairosMailWording {
    /// 「12 分钟前」。镜像不是实时的，不说清楚照镜子的时间，人会把陈旧当成没有新信。
    static func relative(_ timestamp: String?) -> String {
        guard let brief = brief(timestamp) else { return "——还没去过" }
        return " " + brief
    }

    /// 只有「多久以前」那几个字，前半句由摆在旁边的东西自己说。
    /// 说不出来就回 nil——「还没去过」和「不知道」在不同的地方有不同的说法。
    static func brief(_ timestamp: String?) -> String? {
        guard let timestamp, let date = KairosMailClock.parse(timestamp) else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_Hans")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
