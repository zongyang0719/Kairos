import SwiftUI

/// 事项详情就是这条事项的对话：being 和我，在这一件事的上下文里说话。照 Loom 的样子——
/// 一条时间线、一个输入框，没有别的。
///
/// 事项本身的内容（是什么 / 为什么现在找你 / 要判断什么 / 真源）是 being 开的头，
/// 所以画成这条对话的第一个气泡，而不是一张表单。顶上只留标题和优先级；
/// 了结、删除藏在优先级旁边那个小「···」里，不占右上角。
struct ItemDetailView: View {
    @ObservedObject var store: KairosStore
    let itemID: String

    @State private var draft = ""
    @State private var confirmingDelete = false
    @State private var editing = false
    /// 内容里那个大标题是不是已经被滚出去了——只用来决定导航栏那行小标题浮不浮出来。
    @State private var titleScrolledAway = false
    @FocusState private var composing: Bool
    @Environment(\.dismiss) private var dismiss

    private var item: KairosItem? {
        store.snapshot.items.first { $0.id == itemID }
    }

    private var room: KairosRoom { store.room(for: itemID) }
    private var liveText: String? { store.liveReply[itemID] }

    var body: some View {
        if let item {
            ScrollViewReader { proxy in
                ScrollView {
                    // 不用 LazyVStack：房间封顶 500 条纯文本，非懒加载才能让 scrollTo 每次都准。
                    VStack(alignment: .leading, spacing: 12) {
                        header(item)
                        if let conflict = store.conflict(for: item.id) { conflictPanel(conflict) }
                        opening(item)
                        // 这一行有对方的时候，往来摆在开场和对话之间：先看清人家说了什么，
                        // 再往下是我和 being 在这件事上的对话。**只读**——这一屏只有一个
                        // 输入框，是对 being 说的（Mac 的房间同一条）。
                        MailCorrespondence(store: store, item: item)
                        ForEach(room.messages) { message in
                            bubble(message, item: item)
                                .id(message.id)
                        }
                        if let liveText {
                            liveBubble(liveText)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
                }
                // 打开时停在最新一句。不用 defaultScrollAnchor(.bottom)——内容不满一屏时
                // 它会把整段内容贴到底部，顶上空出一大块。
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: room.messages.count) { scrollToBottom(proxy) }
                .onChange(of: liveText ?? "") { scrollToBottom(proxy, animated: false) }
                .onChange(of: composing) { if composing { scrollToBottom(proxy) } }
                // 内容里那个大标题滚出去没有。30pt ≈ 一行 title2 的高度——
                // 和 Mac 的 `ItemRoomView` 用同一个 API（`onScrollGeometryChange`）。
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top > 30
                } action: { _, away in
                    withAnimation(.easeOut(duration: 0.15)) { titleScrolledAway = away }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            // 导航栏写这条事项，不写 being 的名字。原来每一条的标题栏都是「being」——
            // 而事项标题只在滚动内容的最顶上，往下翻两屏就不知道自己在哪条上了。
            // Mac 那边 09-09 专门为这件事把抬头钉死过（ItemRoomView 里那段注释），
            // 手机屏更小、更容易滚丢，反而没跟上这次修。
            //
            // **滚过去了才浮出来**，而不是一直挂着。两条路都试过、都不对：
            // 用系统大标题（`.large`）它只给一行，长标题当场截断——而这个项目的明文原则是
            // 「标题永远不截断，标题是内容本身」；改成一直挂着的 `.inline`，停在顶上时
            // 屏幕上就是上下紧挨着的两个同样的标题。所以走 Mac 那条路：内容里完整换行，
            // 导航栏那行只在**它已经被滚出屏幕**之后淡入。
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(KairosItemRowTitle.line(item))
                        .font(.headline)
                        .lineLimit(1)
                        .opacity(titleScrolledAway ? 1 : 0)
                        .accessibilityHidden(!titleScrolledAway)
                }
            }
            // 对话页把 tab bar 收起来：这一屏只做一件事，输入框贴底。
            .toolbar(.hidden, for: .tabBar)
            .safeAreaInset(edge: .bottom, spacing: 0) { composer(item) }
            .task { store.markRoomRead(item.id) }
            .onChange(of: room.messages.count) { store.markRoomRead(item.id) }
            .onDisappear { store.sendError = nil }
            .sheet(isPresented: $editing) {
                EditItemSheet(store: store, item: item)
            }
            .alert("删除这个事项？", isPresented: $confirmingDelete) {
                Button("删除", role: .destructive) {
                    // **先退出去，再删。** 原来是先删再 dismiss：这一条一没，这一屏当场重画成
                    // 「事项已不存在」那个问号，然后才开始往回推——删一条会先闪一下空白页
                    // 等推回动画走完再删，单子上那行直接淡出。
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        store.delete(item)
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("对话记录也会一起没有。")
            }
        } else {
            ContentUnavailableView("事项已不存在", systemImage: "questionmark.circle")
        }
    }

    // MARK: - 头：标题 + 优先级 + 一个小「···」

    /// 标题在这儿**完整画、要几行给几行**（`fixedSize` 关掉截断）。
    /// 滚出屏幕之后由导航栏那行小标题接力，见 `body` 里那段注释。
    private func header(_ item: KairosItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 和单子上那一行同一句话：消息行以人开头（「Judy · 周四那版……」）。
            // 原来单子上写着 Judy，点进来标题里没有 Judy——同一条事两个名字。
            Text(KairosItemRowTitle.line(item))
                .font(.title2.weight(.semibold))
                .tracking(-0.3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                tierChip(item)
                if !item.isClosed { statusChip(item) }
                moreMenu(item)
                if item.isClosed {
                    Text("已了结")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    /// 优先级在这里是可改的——点一下就换档。
    private func tierChip(_ item: KairosItem) -> some View {
        let tier = KairosTier.normalized(item.tier)
        return Menu {
            ForEach(KairosTier.all, id: \.self) { value in
                Button {
                    store.setTier(item, to: value)
                } label: {
                    if value == tier {
                        Label(value, systemImage: "checkmark")
                    } else {
                        Text(value)
                    }
                }
            }
        } label: {
            // 胶囊还是那么大一颗，外面套一圈透明的把命中区撑到 44 高（和「···」同一招）。
            Text(tier)
                .font(.footnote.monospaced().weight(.bold))
                .foregroundStyle(KairosPalette.onAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(KairosTier.color(tier), in: Capsule())
                .padding(.vertical, 9)
                .padding(.horizontal, 4)
                .contentShape(.rect)
        }
        .padding(.vertical, -9)
        .padding(.horizontal, -4)
        .accessibilityLabel("优先级 \(tier)")
    }

    /// 状态也在这儿可改，挨着优先级——两个都是 being 定、人也能改的一档旋钮，
    /// 摆在一起才看得出它们是同一类东西。
    ///
    /// **和优先级长得不一样：描边，不是实心。** 优先级那颗是有颜色的实心胶囊，
    /// 状态这颗只有环和字——一块屏幕上的饱和色已经派给「多要紧」了，
    /// 「走到哪了」再要一块底色，两颗胶囊就会互相抢，而它们轻重不一样。
    /// 已了结的时候整条不画它：那时候状态只有一个值，旁边那句「已了结」已经说了。
    private func statusChip(_ item: KairosItem) -> some View {
        let status = KairosStatus.normalized(item.status)
        return Menu {
            ForEach(KairosStatus.open, id: \.self) { value in
                Button {
                    store.setStatus(item, to: value)
                } label: {
                    if value == status {
                        Label(KairosStatus.label(value), systemImage: "checkmark")
                    } else {
                        Text(KairosStatus.label(value))
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                StatusRing(status: status, size: 11)
                Text(KairosStatus.label(status))
                    .font(.footnote.weight(.medium))
                    // **写死 `Color.secondary`，不用层级语义的 `.secondary`。**
                    // 它在 `Menu` 的 label 里会被按钮的 tint 染成蓝的——一块屏幕上
                    // 凭空多出第三个颜色，而且那个蓝什么也不表示。
                    .foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .padding(.vertical, 9)
            .padding(.horizontal, 4)
            .contentShape(.rect)
        }
        .padding(.vertical, -9)
        .padding(.horizontal, -4)
        .accessibilityLabel("状态 \(KairosStatus.label(status))")
    }

    /// 了结、编辑和删除：放出来，但藏一藏——一个不起眼的小点，不在右上角。
    /// 药丸还是 30×26 那么大一颗，外面套一圈透明的 padding 把命中区撑到 44（HIG 的硬线），
    /// 再用负 padding 把布局位置还回去——和列表那颗勾选圈同一招。
    private func moreMenu(_ item: KairosItem) -> some View {
        Menu {
            if item.isClosed {
                Button("重新打开", systemImage: "arrow.uturn.backward") {
                    store.reopen(item: item)
                }
            } else {
                Button("了结", systemImage: "checkmark.circle") {
                    KairosHaptics.ownershipChanged()
                    store.finish(item: item)
                }
            }
            // 改标题的唯一入口。手机上以前根本改不了（见 `EditItemSheet`）。
            Button("编辑…", systemImage: "square.and.pencil") { editing = true }
            Divider()
            Button("删除…", systemImage: "trash", role: .destructive) { confirmingDelete = true }
        } label: {
            // 和左边那两颗胶囊（P1 / 未开始）**同高同字号**：它们是一排的，
            // 原来这颗是 `.footnote.weight(.bold)` 压在 30×26 里、再乘 0.6 透明度——
            // 比邻居小一号又淡一档，看着像禁用的。三个点本来就细，不需要再加粗。
            // 颜色写死 `Color.secondary`：层级语义色在 `Menu` 的 label 里会被 tint 染蓝。
            Image(systemName: "ellipsis")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.secondary)
                .frame(width: 34, height: 28)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .padding(9)
                .contentShape(.rect)
        }
        .padding(-9)
        .accessibilityLabel("更多")
    }

    // MARK: - 开场：being 消化过的背景，就是这条对话的第一句

    /// 开场只画 `brief`——being 理解过的来龙去脉，一段话。真源链接不画。
    /// 老条目还没有 brief 的，退回画「为什么现在找你」；列表副行已经在念的那句（要判断什么 /
    /// 是什么）这里不再念一遍，两处信息错开，不重复。全是空的就什么都不画——空的对话就是空的。
    @ViewBuilder
    private func opening(_ item: KairosItem) -> some View {
        let lines = openingLines(item)
        if !lines.isEmpty || !item.options.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if !lines.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            richText(line)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 18))
                }

                if !item.options.isEmpty {
                    options(item)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func openingLines(_ item: KairosItem) -> [String] {
        let brief = item.brief.trimmingCharacters(in: .whitespacesAndNewlines)
        if !brief.isEmpty { return [brief] }
        var lines: [String] = []
        let reason = item.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reason.isEmpty, !KairosItem.isNearDuplicate(reason, of: item.title) {
            lines.append(reason)
        }
        // 列表副行念的是 ask（没有 ask 才念 summary）。这里只补列表没念的那一句。
        let shownInList = item.displayAsk.isEmpty ? item.displaySummary : item.displayAsk
        let summary = item.displaySummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty, summary != shownInList,
           !lines.contains(where: { KairosItem.isNearDuplicate(summary, of: $0) }) {
            lines.append(summary)
        }
        return lines
    }

    /// being 给的选项：一排可点的胶囊，点哪个就等于回它一句。
    private func options(_ item: KairosItem) -> some View {
        FlowChips(items: item.options.map(\.label)) { label in
            send(label, item: item)
        }
    }

    // MARK: - 气泡

    @ViewBuilder
    private func bubble(_ message: KairosRoomMessage, item: KairosItem) -> some View {
        switch message.origin {
        case KairosMessageOrigin.user:
            VStack(alignment: .trailing, spacing: 4) {
                Text(message.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    // 自己说的那句：浅灰底墨色字，不是橙底。一段对话一半的气泡是橙，
                    // 这一屏就是一片橙；橙只留给右下角那颗发送——那才是「要你动手」。
                    .foregroundStyle(.primary)
                    .background(Color.primary.opacity(0.08), in: .rect(cornerRadius: 18))
                // 红字只在**真的没发出去**的时候出现：还在路上的那几秒不算，
                // 不然按下发送就会看见它闪一下，而那一下它说的是假话。
                if !message.delivered, !store.sendingMessageIDs.contains(message.id) {
                    Button {
                        Task { await store.resend(message, in: item) }
                    } label: {
                        Label("没发出去，点一下重发", systemImage: "exclamationmark.arrow.circlepath")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isSending)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 48)
        case KairosMessageOrigin.app:
            // Kairos 自己写进房间的系统通知：一行灰字，居中，像 iMessage 的「已送达」。
            Text(message.text)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
        default:
            richText(message.text)
                .font(.callout)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 18))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 32)
        }
    }

    /// 正在流进来的那段。空的时候画三个点——「being 在想」就是这一刻，不是一个常驻状态。
    private func liveBubble(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if text.isEmpty {
                    ThinkingDots(beingName: store.beingName)
                } else {
                    richText(text)
                        .font(.callout)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 18))
            if let activity = store.liveActivity[itemID] {
                ActivityLine(activity: activity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 32)
    }

    // MARK: - 输入

    private func composer(_ item: KairosItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // 发不出去就地说，别弹全局弹窗——那个弹窗会把这一屏顶掉。
            if let error = store.sendError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 6)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("跟\(store.beingNameInline)说这件事", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .focused($composing)
                    .padding(.leading, 4)

                Button {
                    send(draft, item: item)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .frame(width: 36, height: 36)
                        .background(KairosPalette.attention, in: Circle())
                        .foregroundStyle(KairosPalette.onAccent)
                        .padding(4)
                        .contentShape(.circle)
                }
                .padding(-4)
                .buttonStyle(.plain)
                .disabled(draftEmpty || store.isSending)
                .opacity(draftEmpty || store.isSending ? 0.38 : 1)
                .accessibilityLabel("发送")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var draftEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send(_ text: String, item: KairosItem) {
        let outgoing = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !outgoing.isEmpty, !store.isSending else { return }
        draft = ""
        Task { await store.speak(outgoing, in: item) }
    }

    /// 线上多带一行引用：being 的房间还没分片，不带这一行收信方不知道你在说哪条。
    /// 房间里记的、屏幕上画的都是人自己那句，这一行只是运输标签。
    /// 回到底部。
    ///
    /// **正文流着的时候不能带动画。** being 一句话是几十段 delta，每段都 `withAnimation` 就是
    /// 每段开一个 0.25 秒的动画去打断上一个没跑完的——屏幕上是持续抖动，而不是「跟着往下走」
    /// （发消息时，右侧输入框和界面曾一直闪烁抖动。）
    /// 新来一整条消息是一次性的事件，那个照旧带动画。
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard animated else {
            proxy.scrollTo("bottom", anchor: .bottom)
            return
        }
        withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    // MARK: - 带表格的正文

    /// being 回的话里带表格时用这个，不用裸 `Text`。
    ///
    /// `Text` 只认行内 markdown，块级的一概不解析——一张表进气泡就是一堆竖线按比例字体
    /// 折行，列全部对不上（回复里带表格的话，信息会错乱）。
    /// 所以散文还是交给 `Text`，表格切出来自己用 `Grid` 排（切块在 `KairosMarkdownBlock`）。
    @ViewBuilder
    private func richText(_ text: String) -> some View {
        let blocks = KairosMarkdownBlock.parse(text)
        // 绝大多数回复里一张表都没有。那种情况原样走老路，一个多余的容器都不套。
        if blocks.count == 1, case .prose(let only) = blocks[0] {
            Text(markdown(only))
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .prose(let paragraph):
                        Text(markdown(paragraph))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .list(let ordered, let items):
                        list(ordered: ordered, items: items)
                    case .table(let header, let rows):
                        table(header: header, rows: rows)
                    }
                }
            }
        }
    }

    /// 一串列表。标记和正文分两列摆，正文自己折行时缩进对得上——
    /// 这是列表比散文好读的全部原因，挤成一列就白解析了。手机上跟 Mac 一套画法。
    private func list(ordered: Bool, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ordered ? "\(index + 1)." : "•")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: ordered ? 18 : 10, alignment: .trailing)
                    Text(markdown(item))
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// 一张表。列宽让 `Grid` 自己对齐，横向能划——手机屏窄，三列以上一定放不下，
    /// 硬塞的结果是每个格子挤成一列竖排的字，比不排还难读。
    private func table(header: [String], rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(markdown(cell))
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: 220, alignment: .leading)
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(markdown(cell))
                                .font(.caption)
                                .frame(maxWidth: 220, alignment: .leading)
                        }
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.vertical, 2)
        }
    }

    // MARK: - 冲突（少见；being 判断面写进账本的待裁决）

    private func conflictPanel(_ conflict: KairosConflict) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("两边改得不一样，你定", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
            HStack(alignment: .top, spacing: 10) {
                ConflictSide(title: "我这边", item: conflict.local)
                ConflictSide(title: "\(store.beingNameLeading)那边", item: conflict.remote)
            }
            HStack {
                Button("留我的") { store.resolve(conflict, choice: .keepLocal) }
                Button("用\(store.beingNameInline)的") { store.resolve(conflict, choice: .useBeing) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(Color.red.opacity(0.08), in: .rect(cornerRadius: 14))
    }
}

/// 三个点的呼吸。
///
/// 开了「减弱动态效果」就不跳了——三颗点匀亮着站在那儿，`accessibilityLabel` 照样念
/// 「being 在想」，信息一点不少。这是这一屏唯一一个**无限循环**的动画，列表转场和拖拽缩放
/// 早就判了 `reduceMotion`，只有它一直漏着。
private struct ThinkingDots: View {
    let beingName: String
    @State private var phase = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 7, height: 7)
                    .opacity(reduceMotion ? 0.55 : (phase == index ? 1 : 0.3))
            }
        }
        .frame(height: 20)
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(320))
                withAnimation(.easeInOut(duration: 0.25)) { phase = (phase + 1) % 3 }
            }
        }
        .accessibilityLabel("\(beingName)在想")
    }
}

/// 一排会换行的胶囊按钮。
private struct FlowChips: View {
    let items: [String]
    let tap: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.self) { label in
                Button {
                    tap(label)
                } label: {
                    Text(label)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct ConflictSide: View {
    let title: String
    let item: KairosItemPayload?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let item {
                Text(item.title).font(.callout.weight(.medium))
                if !item.summary.isEmpty {
                    Text(item.summary).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("（已删除）").font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// being 在干什么，一行。词和 loom 的 TUI 同一套（在思考 / 在搜索 / 在执行……），
/// 后面跟着在这个状态里待了多久——「它是不是卡住了」，人只能从这个数字上看出来。
private struct ActivityLine: View {
    let activity: BeingActivity

    var body: some View {
        TimelineView(.periodic(from: activity.startedAt, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(activity.startedAt)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(activity.label)
                    if !activity.arg.isEmpty {
                        Text("\u{201C}\(activity.arg)\u{201D}")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m\(String(format: "%02d", seconds % 60))s")
                        .monospacedDigit()
                }
                if !activity.preview.isEmpty {
                    Text(activity.preview).lineLimit(1)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}
