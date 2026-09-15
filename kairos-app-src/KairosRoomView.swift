import AppKit
import SwiftUI

private typealias T = KairosTokens

/// 事项详情就是这条事项的房间：being 和我，在这一件事的上下文里说话。照 Loom 的样子——
/// 一条时间线、一个输入框，没有别的。和 iOS 的 ItemDetailView 是同一个东西，
/// 只是按 Mac 的尺寸排。
///
/// 事项本身的内容（being 消化过的背景）是 being 开的头，所以画成这条对话的第一个气泡，
/// 而不是一张表单。顶上只留标题和优先级；了结、编辑、删除藏在优先级旁边那个小「···」里。
///
/// 房间号就是 `KairosItem.sessionId`：第一次在这条上开口，being 回哪个 session_id 就记哪个
/// （`KairosStore.bindSession`）。这里不碰它，只管说话和画。
struct ItemRoomView: View {
    @ObservedObject var store: KairosStore
    @EnvironmentObject private var shell: KairosMacShell
    let itemID: String

    @State private var draft = ""
    /// 对话是不是已经滚到抬头底下了——只用来决定抬头底下那条分界线画不画。
    @State private var scrolled = false

    /// 草稿存在 store 里按待办分（`KairosStore.roomDraft`），`@State` 只是这一屏的镜子。
    /// 这一屏是 `.id(item.id)` 建起来的：换一条待办就整个重建，纯 `@State` 的草稿会跟着没——
    /// 切换 Session 再切回来，敲过的字就没有了。
    private var draftBinding: Binding<String> {
        Binding(
            get: { draft },
            set: { value in
                draft = value
                store.setRoomDraft(value, for: itemID)
            }
        )
    }

    private var item: KairosItem? {
        store.snapshot.items.first { $0.id == itemID }
    }

    private var room: KairosRoom { store.room(for: itemID) }
    private var liveText: String? { store.liveReply[itemID] }

    var body: some View {
        if let item {
            VStack(spacing: 0) {
                // 抬头钉在顶上，不跟着滚。
                // 一条待办的房间能有几十句，滚到底下还得知道自己在哪条上；改优先级 / 状态 /
                // 项目也不用先滚回去找。标题最多两行——钉住的那块地方是永久占用的，
                // 一个长标题不能把半屏对话挤没了；整句在 tooltip 里。
                // 左右边线 l（16）：抬头、对话、输入框、信的那一屏共用这一条。顶上 16 是三栏首行对齐线。
                header(item)
                    .padding(.horizontal, T.Spacing.l)
                    .padding(.top, T.Spacing.l)
                    .padding(.bottom, T.Spacing.s)
                    .overlay(alignment: .bottom) {
                        // 只有对话真的滚到抬头底下了才画这条线：没东西被挡住就不需要分界。
                        Divider().opacity(scrolled ? 1 : 0)
                    }

                ScrollViewReader { proxy in
                    // 不画滚动条：系统「总是显示」时这里是一根带轨道的粗条，贴着面板左边缘劈一道。
                    ScrollView(showsIndicators: false) {
                        // 不用 LazyVStack：房间封顶 500 条纯文本，非懒加载才能让 scrollTo 每次都准。
                        VStack(alignment: .leading, spacing: T.Spacing.m) {
                            if let conflict = store.conflict(for: item.id) { conflictPanel(conflict) }
                            correspondence(item)
                            opening(item)
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
                        .padding(.horizontal, T.Spacing.l)
                        .padding(.top, T.Spacing.s)
                        .padding(.bottom, T.Spacing.s)
                    }
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        geometry.contentOffset.y + geometry.contentInsets.top > 2
                    } action: { _, moved in
                        withAnimation(T.Motion.feedback) { scrolled = moved }
                    }
                    // 打开时停在最新一句。不用 defaultScrollAnchor(.bottom)——内容不满一屏时
                    // 它会把整段内容贴到底部，顶上空出一大块。
                    .onAppear {
                        draft = store.roomDraft(itemID)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                    .onChange(of: room.messages.count) { scrollToBottom(proxy) }
                    .onChange(of: liveText ?? "") { scrollToBottom(proxy, animated: false) }
                }

                // 输入框上面不画横线：左边边栏的底上没有，这里也不该有；
                // 输入框自己有底色，对话和输入的分界靠它就够了。
                composer(item)
            }
            .background(ScrollerTamer())
            .task(id: itemID) { store.markRoomRead(item.id) }
            .onChange(of: room.messages.count) { store.markRoomRead(item.id) }
            .onDisappear { store.sendError = nil }
        } else {
            ContentUnavailableView("事项已不存在", systemImage: "questionmark.circle")
        }
    }

    // MARK: - 头：标题 + 优先级 + 一个小「···」（钉在顶上，不滚）

    private func header(_ item: KairosItem) -> some View {
        VStack(alignment: .leading, spacing: T.Spacing.m) {
            // 和单子上那一行同一句话：消息行以人开头（「Judy · …」），两端共用 `KairosItemRowTitle`。
            Text(KairosItemRowTitle.line(item))
                .font(.system(size: T.TypeScale.title, weight: .semibold))
                .textSelection(.enabled)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help(item.title)

            HStack(spacing: T.Spacing.s) {
                tierChip(item)
                statusChip(item)
                projectChip(item)
                moreMenu(item)
                Spacer(minLength: 0)
            }
        }
        // 「收起」不在这儿：它在工具栏里、这一栏的正上方（`KairosWindow.inspectorColumn`），
        // 标题可以一直写到右边。
    }

    /// 状态在这里也是可改的——和优先级并排，两个维度都由 being 定，人也能动。
    private func statusChip(_ item: KairosItem) -> some View {
        let closed = item.isClosed
        let status = KairosStatus.normalized(item.status)
        return Menu {
            ForEach(KairosStatus.open, id: \.self) { value in
                Button {
                    store.setStatus(item, to: value)
                } label: {
                    if value == status, !closed {
                        Label(KairosStatus.label(value), systemImage: "checkmark")
                    } else {
                        Text(KairosStatus.label(value))
                    }
                }
            }
        } label: {
            // 胶囊一排统一 caption 常规体、同高：它们是「可以改」的属性，不是标题，不该带分量。
            HStack(spacing: T.Spacing.xs) {
                StatusGlyph(status: status, closed: closed, size: 12)
                Text(closed ? "已完结" : KairosStatus.label(status))
            }
            .font(.system(size: T.TypeScale.caption))
            .foregroundStyle(T.Ink.secondary)
            .padding(.horizontal, T.Spacing.s)
            .padding(.vertical, T.Spacing.xs)
            .background(T.Ink.fill, in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("状态 \(closed ? "已完结" : KairosStatus.label(status))")
    }

    /// 优先级在这里是可改的——点一下就换档。
    private func tierChip(_ item: KairosItem) -> some View {
        let tier = KairosMacTier.normalized(item.tier)
        return Menu {
            ForEach(KairosMacTier.all, id: \.self) { value in
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
            // 唯一保留半粗的胶囊：反白字压在饱和色上，细笔画会被底色吃掉。
            Text(tier)
                .font(.system(size: T.TypeScale.caption, weight: .semibold, design: .monospaced))
                .foregroundStyle(KairosMacPalette.onAccent)
                .padding(.horizontal, T.Spacing.s)
                .padding(.vertical, T.Spacing.xs)
                .background(KairosMacTier.color(tier), in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("优先级 \(tier)")
    }

    /// 项目：第三个维度，和前两个并排。
    private func projectChip(_ item: KairosItem) -> some View {
        ProjectPickerMenu(store: store, item: item)
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .labelStyle(.titleOnly)
            .font(.system(size: T.TypeScale.caption))
            .foregroundStyle(T.Ink.secondary)
            .padding(.horizontal, T.Spacing.s)
            .padding(.vertical, T.Spacing.xs)
            .background(T.Ink.fill, in: Capsule())
            .overlay {
                if item.project.isEmpty {
                    EmptyView()
                }
            }
            .help(item.project.isEmpty ? "还没归项目" : "项目：\(item.project)")
    }

    /// 了结、编辑和删除：放出来，但藏一藏——一个不起眼的小点，不在右上角。
    private func moreMenu(_ item: KairosItem) -> some View {
        Menu {
            if item.isClosed {
                Button("重新打开", systemImage: "arrow.uturn.backward") {
                    store.reopen(item: item)
                }
            } else {
                Button("了结", systemImage: "checkmark.circle") {
                    store.finish(item: item)
                }
            }
            Button("编辑…", systemImage: "square.and.pencil") { store.editingItem = item }
            Divider()
            Button("删除…", systemImage: "trash", role: .destructive) { shell.pendingDeleteIDs = [item.id] }
        } label: {
            // 用 Text 包图标：行高和旁边几颗胶囊的 caption 字一模一样，四颗胶囊同高，不靠手填 24。
            Text(Image(systemName: "ellipsis"))
                .font(.system(size: T.TypeScale.caption, weight: .bold))
                .foregroundStyle(T.Ink.secondary)
                .padding(.horizontal, T.Spacing.s)
                .padding(.vertical, T.Spacing.xs)
                .background(T.Ink.fill, in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("更多")
    }

    // MARK: - 开场：being 消化过的背景，就是这条对话的第一句

    /// 开场只画 `brief`——being 理解过的来龙去脉，一段话。真源链接不画。
    /// 老条目还没有 brief 的，退回画「为什么现在找你」；列表副行已经在念的那句（要判断什么 /
    /// 是什么）这里不再念一遍，两处信息错开，不重复。全是空的就什么都不画——空的对话就是空的。
    @ViewBuilder
    private func opening(_ item: KairosItem) -> some View {
        let lines = openingLines(item)
        if !lines.isEmpty || !item.options.isEmpty || !item.excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: T.Spacing.m) {
                if !lines.isEmpty {
                    VStack(alignment: .leading, spacing: T.Spacing.s) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            KairosRichText(text: line)
                                .font(.system(size: T.TypeScale.body))
                                .foregroundStyle(T.Ink.primary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.horizontal, T.Spacing.m)
                    .padding(.vertical, T.Spacing.s)
                    .background(T.Ink.fill, in: .rect(cornerRadius: T.Spacing.l))
                    .padding(.trailing, 40)
                }

                if !item.options.isEmpty {
                    options(item)
                }
                excerpt(item)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 往来（这一行有对方的时候才有）

    /// 和对方的往来。**只读**——这一屏没有第二个输入框。
    ///
    /// 2026-09-11 人类定的：**输入框只有一个，发给别人也是通过 being 发，没有额外的渠道。**
    /// 这条比我原来那版（两个框）更干净，而且更安全：Kairos 本来就够不着任何一条对外的管子
    /// （Town 的 DM 认 being 的 Heart，篝火炉火同理），所谓「直接回」不过是把草稿塞进
    /// 一个 being 迟早要来拿的文件。既然出手的永远是 being ，那就只有一个框——对 being 说。
    /// 回什么由 `options` 定：being 列几个判断，你点一个（见 `options(_:)`）。
    @ViewBuilder
    private func correspondence(_ item: KairosItem) -> some View {
        if let who = item.counterpart, !who.isEmpty {
            VStack(alignment: .leading, spacing: T.Spacing.m) {
                Label("和 \(who.name) 的往来", systemImage: KairosMacSource.symbol(who.channel))
                    .font(.system(size: T.TypeScale.caption))
                    .foregroundStyle(T.Ink.secondary)

                if !item.thread.isEmpty {
                    // 炉火像个小群、篝火是一条帖子底下的串：上下文是**多个人说的话**。
                    // 「长上下文要不要切开」的答案不是按长度切，是按「谁说的」切——
                    // 一段长 excerpt 是死的，一串带说话人的话是活的。
                    ForEach(Array(item.thread.enumerated()), id: \.offset) { _, said in
                        utterance(who: said.who, at: said.at, text: said.text, mine: false)
                    }
                }

            }
            .padding(T.Spacing.m)
            .background(T.Ink.fillSubtle, in: .rect(cornerRadius: T.Spacing.m))
        }
    }

    /// 往来里的一句：谁说的写在上面。同一个房间组件，多一种说话人的样式。
    private func utterance(who: String, at: String, text: String, mine: Bool) -> some View {
        VStack(alignment: .leading, spacing: T.Spacing.xs) {
            // 谁说的、几点：同一个 caption，层级只靠灰度（名字 secondary、时间 tertiary）。
            // 原来名字半粗 + 时间是 10pt 的最小档 + quaternary——10pt 中文在 0.18 的灰上基本读不出来。
            HStack(alignment: .firstTextBaseline, spacing: T.Spacing.s) {
                Text(who)
                    .font(.system(size: T.TypeScale.caption))
                    .foregroundStyle(T.Ink.secondary)
                Text(Self.shortTime(at))
                    .font(.system(size: T.TypeScale.caption).monospacedDigit())
                    .foregroundStyle(T.Ink.tertiary)
            }
            KairosRichText(text: text)
                .font(.system(size: T.TypeScale.body))
                .foregroundStyle(T.Ink.primary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func shortTime(_ stamp: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: KairosClock.parse(stamp))
    }

    /// 原话：源头原文，一字不改。和 being 的话分开画——左边一道线，像引用。给人对照验证 being 没读偏。
    @ViewBuilder
    private func excerpt(_ item: KairosItem) -> some View {
        let text = item.excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: T.Spacing.xs) {
                Text("原话 · \(KairosSource.label(item.source))")
                    .font(.system(size: T.TypeScale.caption))
                    .foregroundStyle(T.Ink.tertiary)
                Text(text)
                    .font(.system(size: T.TypeScale.body))
                    .lineSpacing(T.TypeScale.bodyLineSpacing)
                    .foregroundStyle(T.Ink.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, T.Spacing.m)
            .overlay(alignment: .leading) {
                Rectangle().fill(T.Ink.quaternary).frame(width: 2)
            }
            .padding(.trailing, 40)
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
    /// being 列的几个判断，点一个就出手。
    ///
    /// **回复不是拟稿，是选项**。一百个人的量上，读一段拟好的稿再改两个字，
    /// 和扫一眼三个选项点一个，差的是数量级——**这是唯一真正省时间的地方**。
    ///
    /// 点下去发的是一句人话，发给 being （这一屏只有这一条出路）：消息行说「回 Judy：能」，
    /// 待办行就是那个选项本身。真正出手的是 being——它替你发出去，然后按第 2 条把这一趟记进账。
    @ViewBuilder
    private func options(_ item: KairosItem) -> some View {
        // 带说明的（being 解释了每个选择意味着什么）竖着排，一行一个：要判断就得看得见代价。
        // 没说明的还是横着的小药丸，省地方。
        if item.options.contains(where: { !$0.detail.isEmpty }) {
            VStack(alignment: .leading, spacing: T.Spacing.s) {
                ForEach(item.options) { option in
                    Button {
                        send(optionSentence(option, item: item), item: item)
                    } label: {
                        // 选项名 13 墨色、代价 11 灰：两级差已经够，选项名不必再加粗。
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label)
                                .font(.system(size: T.TypeScale.body))
                                .foregroundStyle(T.Ink.primary)
                            if !option.detail.isEmpty {
                                Text(option.detail)
                                    .font(.system(size: T.TypeScale.caption))
                                    .foregroundStyle(T.Ink.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, T.Spacing.m)
                        .padding(.vertical, T.Spacing.s)
                        .background(T.Ink.fill, in: .rect(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.trailing, 40)
        } else {
            FlowChips(items: item.options.map(\.label)) { label in
                guard let option = item.options.first(where: { $0.label == label }) else { return }
                send(optionSentence(option, item: item), item: item)
            }
        }
    }

    /// 点一个选项，实际发出去的那句话。
    ///
    /// 消息行要说清楚是**回给谁**——being 拿着这句去出手，含糊一点就可能发错人。
    private func optionSentence(_ option: KairosOption, item: KairosItem) -> String {
        guard let who = item.counterpart, !who.isEmpty else { return option.label }
        return "回 \(who.name)：\(option.label)"
    }

    // MARK: - 气泡

    @ViewBuilder
    private func bubble(_ message: KairosRoomMessage, item: KairosItem) -> some View {
        switch message.origin {
        case KairosMessageOrigin.user:
            VStack(alignment: .trailing, spacing: T.Spacing.xs) {
                Text(message.text)
                    .font(.system(size: T.TypeScale.body))
                    .lineSpacing(T.TypeScale.bodyLineSpacing)
                    .textSelection(.enabled)
                    .padding(.horizontal, T.Spacing.m)
                    .padding(.vertical, T.Spacing.s)
                    // `onAccent` 而不是写死的白：深色模式下这个橙是亮的一档，
                    // 白字压上去只有 2.1:1（这条账 09-11 在别处已经还过一次）。
                    // 自己说的那句：**浅灰底、墨色字**，不是橙底。
                    // 一段对话里一半的气泡是橙的，房间就成了一屏橙——橙留给「要你动手」，
                    // 这儿唯一该带颜色的是右下角那颗发送。
                    // 自己那句比 being 的深一档面（fillStrong / fill）：左右位置之外，第二条分辨通道。
                    .foregroundStyle(T.Ink.primary)
                    .background(T.Ink.fillStrong, in: .rect(cornerRadius: T.Spacing.l))
                // 红字只在**真的没发出去**的时候出现：还在路上的那几秒不算，
                // 不然按下发送就会看见它闪一下，而那一下它说的是假话。
                if !message.delivered, !store.sendingMessageIDs.contains(message.id) {
                    Button {
                        Task { await store.resend(message, in: item) }
                    } label: {
                        Label("没发出去，点一下重发", systemImage: "exclamationmark.arrow.circlepath")
                            .font(.system(size: T.TypeScale.caption))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isSending)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 60)
        case KairosMessageOrigin.app:
            // Kairos 自己写进房间的系统通知：一行灰字，居中，像 iMessage 的「已送达」。
            // 原来是 10pt 的最小档，现在 caption（11pt）：系统通知也是要读的中文。
            Text(message.text)
                .font(.system(size: T.TypeScale.caption))
                .foregroundStyle(T.Ink.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
        default:
            KairosRichText(text: message.text)
                .font(.system(size: T.TypeScale.body))
                .foregroundStyle(T.Ink.primary)
                .textSelection(.enabled)
                .padding(.horizontal, T.Spacing.m)
                .padding(.vertical, T.Spacing.s)
                .background(T.Ink.fill, in: .rect(cornerRadius: T.Spacing.l))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 40)
        }
    }

    /// 正在流进来的那段。空的时候画三个点——「being 在想」就是这一刻，不是一个常驻状态。
    private func liveBubble(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: T.Spacing.s) {
            Group {
                if text.isEmpty {
                    ThinkingDots()
                } else {
                    KairosRichText(text: text)
                        .font(.system(size: T.TypeScale.body))
                        .foregroundStyle(T.Ink.primary)
                }
            }
            .padding(.horizontal, T.Spacing.m)
            .padding(.vertical, T.Spacing.s)
            .background(T.Ink.fill, in: .rect(cornerRadius: T.Spacing.l))
            if let activity = store.liveActivity[itemID] {
                ActivityLine(activity: activity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 40)
    }

    // MARK: - 输入

    private func composer(_ item: KairosItem) -> some View {
        VStack(alignment: .leading, spacing: T.Spacing.s) {
            // 发不出去就地说，别只靠全局弹窗——那个弹窗关掉就找不回来了。
            if let error = store.sendError {
                Text(error)
                    .font(.system(size: T.TypeScale.caption))
                    .foregroundStyle(.red)
                    .padding(.horizontal, T.Spacing.xs)
            }
            HStack(alignment: .bottom, spacing: T.Spacing.s) {
                ComposerBox(
                    text: draftBinding,
                    placeholder: "跟\(store.beingNameInline)说这件事",
                    heightKey: "composer.room.height"
                ) {
                    send(draft, item: item)
                }

                Button {
                    send(draft, item: item)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: T.TypeScale.body, weight: .bold))
                        .foregroundStyle(KairosMacPalette.onAccent)
                        .frame(width: 32, height: 32)
                        .background(KairosMacPalette.attention, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draftEmpty || store.isSending)
                .opacity(draftEmpty || store.isSending ? 0.38 : 1)
                .help("发送（回车 / ⌘回车）")
                .accessibilityLabel("发送")
            }
        }
        .padding(.horizontal, T.Spacing.l)
        .padding(.top, T.Spacing.m)
        // 底下只留 8：输入框的下沿和左边边栏那块玻璃的下沿在同一条线上（离窗口底都是 8）。
        .padding(.bottom, T.Spacing.s)
    }

    private var draftEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send(_ text: String, item: KairosItem) {
        let outgoing = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !outgoing.isEmpty, !store.isSending else { return }
        draft = ""
        store.setRoomDraft("", for: itemID)
        Task { await store.speak(outgoing, in: item) }
    }

    /// 线上多带一行引用：being 的房间还没分片，不带这一行收信方不知道你在说哪条。
    /// 房间里记的、屏幕上画的都是人自己那句，这一行只是运输标签（和 iOS 同一格式）。
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
        withAnimation(T.Motion.easeOut) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    // MARK: - 冲突（少见；being 判断面写进账本的待裁决）

    private func conflictPanel(_ conflict: KairosConflict) -> some View {
        VStack(alignment: .leading, spacing: T.Spacing.m) {
            // 冲突是这一屏唯一要你立刻拍板的东西：保留半粗，这是「真正需要强调」的那一处。
            Label("两边改得不一样，你定", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: T.TypeScale.body, weight: .semibold))
                // 语义色归 app（同列表行的冲突图标）：不跟系统红、不随强调色变。
                .foregroundStyle(KairosMacPalette.critical)
            HStack(alignment: .top, spacing: T.Spacing.s) {
                ConflictSide(title: "我这边", item: conflict.local)
                ConflictSide(title: "\(store.beingNameLeading)那边", item: conflict.remote)
            }
            HStack {
                Button("留我的") { store.resolve(conflict, choice: .keepLocal) }
                Button("用\(store.beingNameInline)的") { store.resolve(conflict, choice: .useBeing) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(T.Spacing.m)
        .background(KairosMacPalette.critical.opacity(0.08), in: .rect(cornerRadius: T.Radius.m, style: .continuous))
    }
}

// MARK: - 带表格的正文

/// being 回的话里带表格时用这个，不用裸 `Text`。
///
/// `Text` 只认行内 markdown，块级的一概不解析——一张表进气泡就是一堆竖线按比例字体
/// 折行，列全部对不上（回复里带表格的话，信息会错乱）。
/// 所以散文还是交给 `Text`，表格切出来自己用 `Grid` 排（切块在 `KairosMarkdownBlock`，
/// 有 tests/native-markdown 对着它）。
struct KairosRichText: View {
    let text: String

    var body: some View {
        let blocks = KairosMarkdownBlock.parse(text)
        // 绝大多数回复里一张表都没有。那种情况原样走老路，一个多余的容器都不套。
        if blocks.count == 1, case .prose(let only) = blocks[0] {
            // 行距：中文长段落没有行距就是一堵墙。行高 1.45 由 tokens 算（`bodyLineSpacing`）。
            Text(Self.markdown(only)).lineSpacing(T.TypeScale.bodyLineSpacing)
        } else {
            VStack(alignment: .leading, spacing: T.Spacing.m) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .prose(let paragraph):
                        Text(Self.markdown(paragraph))
                            .lineSpacing(T.TypeScale.bodyLineSpacing)
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

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    /// 一串列表。标记和正文分两列摆，正文自己折行时缩进对得上——
    /// 这是列表比散文好读的全部原因，挤成一列就白解析了。
    private func list(ordered: Bool, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: T.Spacing.xs) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: T.Spacing.s) {
                    Text(ordered ? "\(index + 1)." : "•")
                        .monospacedDigit()
                        .foregroundStyle(T.Ink.secondary)
                        .frame(minWidth: ordered ? 18 : 10, alignment: .trailing)
                    Text(Self.markdown(item))
                        .lineSpacing(T.TypeScale.bodyLineSpacing)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// 一张表。列宽让 `Grid` 自己对齐；Mac 气泡够宽，但列一多还是能横向划。
    private func table(header: [String], rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: T.Spacing.l, verticalSpacing: T.Spacing.s) {
                // 表头不加粗：表头底下那根分隔线 + 灰度已经说明「这一行是列名」。
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(Self.markdown(cell))
                            .font(.system(size: T.TypeScale.caption))
                            .foregroundStyle(T.Ink.secondary)
                            .frame(maxWidth: 320, alignment: .leading)
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(Self.markdown(cell))
                                .font(.system(size: T.TypeScale.caption).monospacedDigit())
                                .frame(maxWidth: 320, alignment: .leading)
                        }
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.vertical, 2)
        }
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
                HStack(spacing: T.Spacing.xs) {
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
            .font(.system(size: T.TypeScale.caption))
            .foregroundStyle(T.Ink.tertiary)
        }
    }
}

/// 输入框的芯子：一个 `NSTextView`。
///
/// 为什么不用 SwiftUI 的 `TextEditor` + `onKeyPress`：**中英混打时按回车，输入法还没上屏
/// 的那一截被吞掉，消息还直接发出去了**。`onKeyPress` 拦回车是拦在
/// 输入法**前面**的，可那一下回车本来的意思是「把候选词上屏」，不是「发送」。
///
/// AppKit 里这件事有正确答案：组字期间输入法自己把回车吃掉去上屏，压根走不到
/// `doCommandBy` 那条路——所以「回车 = 发送」写在那儿，天然不会抢输入法的回车。
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    /// 这个数每加一次，就把光标要回来一次（拖完高矮、拖进来一段文字之后用）。
    let focusTick: Int
    let onSend: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: T.TypeScale.body)
        // 打字时的行距和发出去之后气泡里的行距是同一个（1.45）：写的时候长什么样，发出去还是那样。
        // lineSpacing 加在行与行之间，第一行的位置不动，占位字照旧对得上。
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = T.TypeScale.bodyLineSpacing
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes[.paragraphStyle] = paragraph
        textView.textContainerInset = NSSize(width: 5, height: 7)
        textView.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.onSend = onSend
        // 组字中一个字都别动它：这时候改 `string` 会把输入法正在拼的那半截打断。
        if !textView.hasMarkedText(), textView.string != text {
            textView.string = text
        }
        if context.coordinator.focusTick != focusTick {
            context.coordinator.focusTick = focusTick
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, focusTick: focusTick) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        var focusTick: Int
        var onSend: () -> Void = {}

        init(text: Binding<String>, focusTick: Int) {
            self.text = text
            self.focusTick = focusTick
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // 组字中的那半截不算已经输入的字，别写出去——写出去了「发送」就会把它带走。
            guard !textView.hasMarkedText() else { return }
            text.wrappedValue = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.option) || flags.contains(.shift) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            // 候选词刚上屏那一下，`textDidChange` 可能还没轮到；先把最终文本同步出去再发。
            text.wrappedValue = textView.string
            onSend()
            return true
        }
    }
}

/// 输入框。**能滚、能拖着改高矮、能把文字拖进来。**
///
/// 原来是 `TextField(axis: .vertical)` + `lineLimit(1...8)`：粘一大段长文进去，超出的
/// 部分既看不见也滚不动，光标跑到框外，人以为是「发送不了」——其实字都在，只是这个
/// 框不肯让你看见。说清楚：Kairos 这边**没有长度上限**，
/// being 那边也不按字数拒收。
struct ComposerBox: View {
    @Binding var text: String
    let placeholder: String
    /// 高矮记在本机：一个人习惯多大的框，是这台机器的事，不进账本。
    @AppStorage private var storedHeight: Double
    let onSend: () -> Void

    /// 正在拖的那个高度。**拖动期间只动它，松手那一下才写 `AppStorage`**——
    /// 一次拖拽有几十帧，每帧写一次 UserDefaults 就是每帧把这个视图重画一次，
    /// 输入框跟着重建、焦点掉了：表现就是「拖完打不了字，还闪」。
    @State private var dragHeight: Double?
    /// 按下去那一刻的高度。拖动给的是累计位移，不记起点会越拖越飘。
    @State private var dragStart: Double?
    @State private var dropTargeted = false
    @State private var focusTick = 0

    init(
        text: Binding<String>,
        placeholder: String,
        heightKey: String,
        onSend: @escaping () -> Void
    ) {
        _text = text
        self.placeholder = placeholder
        _storedHeight = AppStorage(wrappedValue: 96, heightKey)
        self.onSend = onSend
    }

    private static let minHeight: Double = 52
    private static let maxHeight: Double = 460

    private var height: Double { dragHeight ?? storedHeight }

    var body: some View {
        VStack(spacing: 0) {
            grip
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: T.TypeScale.body))
                        .foregroundStyle(T.Ink.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .allowsHitTesting(false)
                }
                ComposerTextView(text: $text, focusTick: focusTick, onSend: onSend)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
            }
            .frame(height: height)
            .background(T.Ink.fill, in: RoundedRectangle(cornerRadius: T.Spacing.m))
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: T.Spacing.m)
                        .strokeBorder(T.Ink.secondary, lineWidth: 1.5)
                }
            }
            // 从别处拖一段文字进来 = 接在草稿后面。拖进来就等于要说它，顺手把光标给它。
            .dropDestination(for: String.self) { dropped, _ in
                let incoming = dropped.joined(separator: "\n").trimmingCharacters(in: .newlines)
                guard !incoming.isEmpty else { return false }
                if text.isEmpty { text = incoming }
                else { text += (text.hasSuffix("\n") ? "" : "\n") + incoming }
                focusTick += 1
                return true
            } isTargeted: { dropTargeted = $0 }
        }
    }

    /// 上边那道杠：拖着它改框的高矮。
    ///
    /// 光标形状用 `pointerStyle`，不用 `NSCursor.push()/pop()`——push/pop 靠 hover 进出配对，
    /// 拖动时 hover 会反复进出，配不平就是一路闪。
    private var grip: some View {
        // 把手用 Ink.quaternary（0.18）：原来系统 quaternary 约 0.1，浅色模式下几乎看不见，
        // 人不知道这条杠能拖。
        Capsule()
            .fill(T.Ink.quaternary)
            .frame(width: 30, height: 4)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(.rect)
            .pointerStyle(.frameResize(position: .top))
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = dragStart ?? storedHeight
                        if dragStart == nil { dragStart = base }
                        dragHeight = min(Self.maxHeight, max(Self.minHeight, base - value.translation.height))
                    }
                    .onEnded { _ in
                        if let dragHeight { storedHeight = dragHeight }
                        dragHeight = nil
                        dragStart = nil
                        // 拖杠子是点在框外面，光标会从输入框上掉下来，松手就还回去。
                        focusTick += 1
                    }
            )
            .accessibilityLabel("调整输入框高矮")
    }
}

/// 三个点的呼吸。
private struct ThinkingDots: View {
    @State private var phase = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(T.Ink.secondary)
                    .frame(width: 7, height: 7)
                    // 减弱动态效果：不循环，三颗一样亮，静止的「…」。
                    .opacity(reduceMotion || phase == index ? 1 : 0.3)
            }
        }
        .frame(height: 20)
        // 点的尺寸和 320ms 节拍是品牌节奏，保留；过渡曲线走 Motion 表（stroke 档）。
        .task(id: reduceMotion) {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(320))
                withAnimation(.easeOut(duration: T.Motion.stroke)) { phase = (phase + 1) % 3 }
            }
        }
        .accessibilityLabel("在想")
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
                    // 选项药丸是「点一下就回话」的按钮：正文字号、常规体，靠面 + 描边成形。
                    Text(label)
                        .font(.system(size: T.TypeScale.body))
                        .foregroundStyle(T.Ink.primary)
                        .padding(.horizontal, T.Spacing.m)
                        .padding(.vertical, T.Spacing.xs)
                        .background(T.Ink.fill, in: Capsule())
                        .overlay(Capsule().stroke(T.Ink.fillStrong, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 会换行的一排。房间的选项胶囊和「显示」面板的筛选药丸共用——
/// 一排药丸塞不下时必须往下折，`HStack` 只会把它们压扁。
struct FlowLayout: Layout {
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
        VStack(alignment: .leading, spacing: T.Spacing.xs) {
            Text(title).font(.system(size: T.TypeScale.caption)).foregroundStyle(T.Ink.secondary)
            if let item {
                Text(item.title).font(.system(size: T.TypeScale.body)).foregroundStyle(T.Ink.primary)
                if !item.summary.isEmpty {
                    Text(item.summary).font(.system(size: T.TypeScale.caption)).foregroundStyle(T.Ink.secondary)
                }
            } else {
                Text("（已删除）").font(.system(size: T.TypeScale.body)).foregroundStyle(T.Ink.secondary)
            }
        }
        .padding(T.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }
}
