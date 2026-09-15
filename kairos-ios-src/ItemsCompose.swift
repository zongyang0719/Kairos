import SwiftUI

/// 新建一条事项。「想法」不再是一个单独的东西——想到什么，就是一条事项。
/// 建完它就在列表里；想让 being 管，点进去说一句就行。
///
/// **这里不问档位。** 原来这儿摆着一排 P0–P3，写死预选 `P2`。
/// 它跟产品方向是拧着的：契约 §五「新建时填的初值不算手动改」说得很清楚——
/// 人在这儿选的从来就只是初值，being 下一趟照样盖掉。所以那排胶囊什么也没决定，
/// 只是在人最不该动脑的那一秒（想到一件事，想赶紧记下来）请他先给这件事定个档。
/// 档位是 being 的活（BEING-RULES 规则 3），这一屏只收那句话。
struct ComposeItemSheet: View {
    @ObservedObject var store: KairosStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @FocusState private var focused: Bool

    private var ready: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                TextField("要做什么", text: $title, axis: .vertical)
                    .font(.title3)
                    .lineLimit(1...5)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(add)
                    // **竖向的 TextField 按回车不走 onSubmit，是往里插一个换行。**
                    // 键盘右下角明明写着「完成」，按下去标题里多了一个空行、表还开着
                    // 标题是一句话，不该有换行：看见换行就当作「完成」。
                    .onChange(of: title) { _, value in
                        guard value.contains("\n") else { return }
                        title = value.replacingOccurrences(of: "\n", with: "")
                        add()
                    }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .navigationTitle("新事项")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加", action: add)
                        .disabled(!ready)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .onAppear { focused = true }
    }

    private func add() {
        guard ready else { return }
        store.createItem(title: title)
        KairosHaptics.dropped()
        dismiss()
    }
}

/// 改一条已有的事项。
///
/// 补的是一块地板，不是新功能：在这之前 **iOS 根本改不了标题**——整个 kairos-ios-src
/// 里只有一处 `saveDraft`，在新建里，`isNew: true`。
/// 手机上随手记一条、打错一个字，唯一的出路是删掉重记，连带对话记录一起没。
/// Mac 那边有完整的 `ItemEditor`，手机这边一直是空的。
///
/// 放四样：标题、优先级、项目、状态。being 写的那几段（brief / excerpt / ask）不给改——
/// 那是它消化过的材料，人要改的是自己那句话。
///
/// 项目这一项本来是空着的：账本里「属于哪摊事」曾经有两套写法并存，手机接哪一套都可能
/// 往账本写脏数据。2026-09-11 把没人用的那套拆了（`KairosStore.activeItems` 上有完整交代），
/// 现在只剩 `item.project` 一个名字，手机和 Mac 读写的是同一个字段，才敢接上。
struct EditItemSheet: View {
    @ObservedObject var store: KairosStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: KairosItem
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    init(store: KairosStore, item: KairosItem) {
        self.store = store
        _draft = State(initialValue: item)
    }

    private var ready: Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("标题") {
                    TextField("要做什么", text: $draft.title, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($focused)
                }
                Section("优先级") {
                    TierPicker(tier: $draft.tier)
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                }
                Section("项目") {
                    // 现在能给了：账本里「属于哪摊事」原来有两套写法并存，手机这边不敢接；
                    // 2026-09-11 拆掉了没人用的那套（见 `KairosStore.activeItems` 上的注释），
                    // 只剩 `item.project` 这一个名字，手机和 Mac 读写的是同一个字段。
                    Picker("项目", selection: $draft.project) {
                        Text("无").tag("")
                        ForEach(store.projectNames, id: \.self) { Text($0).tag($0) }
                        // being 写了个新名字、但还没在别处登记过时，别让它从这个 Picker 里掉出去
                        // ——掉出去就等于一存就被清空。
                        if !draft.project.isEmpty, !store.projectNames.contains(draft.project) {
                            Text(draft.project).tag(draft.project)
                        }
                    }
                    .labelsHidden()
                }
                Section("状态") {
                    Picker("状态", selection: $draft.status) {
                        // 只列还开着的那三个。「已完结」不在这儿——那是「了结」那颗按钮的活，
                        // 摆进来等于给同一件事开两个入口，还会让人以为状态和了结是两回事。
                        ForEach(KairosStatus.open, id: \.self) { value in
                            Text(KairosStatus.label(value)).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("编辑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("存") { save() }
                        .disabled(!ready)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // 不自动弹键盘：进「编辑」多半是来改优先级或状态的，一进来键盘先占掉半屏，
        // 下面那两排选项被顶到看不见（medium 高度下）。要改标题点一下标题就行。
    }

    private func save() {
        guard ready else { return }
        draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.tier = KairosTier.normalized(draft.tier)
        draft.status = KairosStatus.normalized(draft.status)
        do {
            try store.saveDraft(draft, isNew: false)
            KairosHaptics.dropped()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 四档优先级，一排胶囊。选中的那颗用它自己的颜色（P0 红、P1 橙、P2/P3 中性）。
struct TierPicker: View {
    @Binding var tier: String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(KairosTier.all, id: \.self) { value in
                let selected = value == tier
                Button {
                    tier = value
                    KairosHaptics.pickedUp()
                } label: {
                    Text(value)
                        .font(.subheadline.monospaced().weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        // 选中的 P2 / P3 原来是「次级灰底 + 白字」——白字压在 60% 的灰上
                        // 对比度只有 3 左右，一眼看过去像是禁用的。中性档选中改成墨色实底反白。
                        .background(
                            selected ? selectedFill(value) : Color.primary.opacity(0.06),
                            in: Capsule()
                        )
                        .foregroundStyle(selected ? selectedInk(value) : Color.primary.opacity(0.75))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .animation(.snappy(duration: 0.18), value: tier)
    }

    private func selectedFill(_ value: String) -> Color {
        value == "P0" || value == "P1" ? KairosTier.color(value) : KairosPalette.done
    }

    private func selectedInk(_ value: String) -> Color {
        value == "P0" || value == "P1" ? KairosPalette.onAccent : KairosPalette.onDone
    }
}

/// 优先级的颜色，列表、详情、新建三处共用一份。
/// 词汇（`all` / `normalized`）在 KairosModels.swift 的 `KairosTier`，两个平台同一份。
extension KairosTier {
    /// 三层：P0 红、P1 橙、P2/P3 中性。屏幕上只有这两种颜色有含义。
    static func color(_ tier: String) -> Color {
        switch tier {
        case "P0": KairosPalette.critical
        case "P1": KairosPalette.attention
        // 和 Mac 的 `KairosMacTier.color` 对齐用 `.secondary`，不再是
        // `Color.primary.opacity(0.55)`：段头「P2」是**当文字画在页面底色上**的，
        // 自己调的半透明灰没人担保它的对比度，系统的次级标签色是调过的。
        default: Color.secondary
        }
    }
}

extension KairosStore {
    /// 直接建一条事项。球在自己手上；要不要 being 来管，在它的房间里说一句就行——
    /// 「交给 being」不再是一个状态动作。
    ///
    /// **落 `P2` 而不是模型默认的 `P3`。** 新建面板不再问档位（见 `ComposeItemSheet`），
    /// 所以这个值现在是唯一的落点，得选一个在 being 还没看过时也站得住的：
    /// `P3` 是「有空再说」，一句真话——人刚决定要记下来的事，直接沉到列表最后一段，
    /// 而没接 being、或者 being 没在跑的时候它就永远沉在那儿。`P2` 是「常规」，
    /// 等于「还没人判断过，先按普通的算」，being 下一趟照样盖得掉（新建不盖 human 戳）。
    func createItem(title: String, tier: String = "P2") {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var draft = KairosItem()
        draft.title = trimmed
        draft.tier = KairosTier.normalized(tier)
        do { try saveDraft(draft, isNew: true) }
        catch { notice = error.localizedDescription }
    }

    /// 账本里出现过的项目名。和 Mac 的 `macProjects` 同一个来源——登记过的（`workspace.projects`）
    /// 加上事项身上写着的，去重。手机这边不需要边栏那套排序，所以就这么短。
    var projectNames: [String] {
        var seen = Set<String>()
        var names: [String] = []
        for project in snapshot.workspace.projects
        where !project.archived && project.id != KairosWorkspace.defaultProjectID {
            if seen.insert(project.name).inserted { names.append(project.name) }
        }
        for item in snapshot.items where !item.project.isEmpty {
            if seen.insert(item.project).inserted { names.append(item.project) }
        }
        return names
    }

    /// 手机上没有「想法」这一屏了：以前记下的想法一次性变成事项（P3），一条不丢。
    func absorbSeedsIntoItems() {
        for seed in seeds { promoteSeed(seed) }
    }
}
