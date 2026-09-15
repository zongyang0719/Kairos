import SwiftUI

/// 首启两页引导（Mac）。
///
/// **结构**
///   1. 「一张单子」——账本唯一、being 是伙伴不是托管；一页循环示意把「你记 → being 记/定档/追问 → 你确认」画清楚。
///   2. 「边界」——一事项一房间、动作留信、可关权限、数据在本机/iCloud、不连也能用手账本；
///      **唯一出口**——「开始用」或「现在去连接 being」。
///
/// **为什么全屏必经、不用可跳过的小字链接**
///   首启时人还不知道「单子 / being / 房间」三条线怎么拧在一起。把契约压成两屏可读的文字，
///   比第一次打开单子面对空列表瞎摸便宜——也避免 being 已配好的人在空状态里找「链接在哪」。
///
/// **Mac 与 iOS 的交互差**
///   没有 `.page` 样式的 TabView，用分步 + 底栏「上一步 / 圆点 / 继续」翻页；两页必经，只有最后一页能结束引导。
///
/// **留给下一版的 AI native 增强（本版不做）**
///   已接入 being 的用户，最后一页「开始用」之后让 being 在第一条待办的房间里发第一封问候/对账信，
///   代替纯静态第三页——需要 store 在线且要有「首启已展示」与「being 已连」的联合条件，另开任务。
struct KairosOnboardingView: View {
    private typealias T = KairosTokens

    enum Finish {
        /// 正常结束，进单子。
        case startUsing
        /// 最后一页「现在去连接 being」：结束引导并打开设置（由 `OnboardingHost` 管）。
        case connectBeing
    }

    var onFinish: (Finish) -> Void

    @State private var step = 0

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0:
                    pageOne
                default:
                    pageThree
                }
            }
            .animation(.snappy(duration: 0.22), value: step)

            // 底栏和正文同一条左右边线（xl），翻页时按钮不会和上面的字错开。
            bottomBar
                .padding(.horizontal, T.Spacing.xl)
                .padding(.vertical, T.Spacing.l)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, Locale(identifier: "zh_Hans"))
        .tint(KairosMacPalette.attention)
    }

    private var bottomBar: some View {
        HStack {
            if step > 0 {
                Button("上一步") {
                    step -= 1
                }
                .buttonStyle(.bordered)
            } else {
                Color.clear.frame(width: 72, height: 1)
            }

            Spacer()

            HStack(spacing: T.Spacing.s) {
                ForEach(0 ..< 2, id: \.self) { index in
                    Capsule()
                        .fill(index == step ? AnyShapeStyle(KairosMacPalette.attention) : AnyShapeStyle(T.Ink.quaternary))
                        .frame(width: 8, height: 8)
                }
            }

            Spacer()

            if step < 1 {
                Button("继续") {
                    step += 1
                }
                .buttonStyle(.borderedProminent)
            } else {
                Color.clear.frame(width: 72, height: 1)
            }
        }
    }

    // MARK: - 页 1

    private var pageOne: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: T.Spacing.xl) {
                // 引导这一屏只有一个主角：展示档（23），半粗就够——字号已经把它和正文拉开了两档。
                Text("所有事，落进同一张单子。")
                    .font(.system(size: T.TypeScale.display, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)

                Text(
                    "你记的、being 从你话里听到的（你说「周五要交」，它记一条）、私信里欠的回复——"
                        + "都是这张单子上的一条。账本只有一份，在你手里。being 是伙伴，不是托管："
                        + "它帮你定优先级、追问缺口，但每一件事的球在谁手里，看得见。"
                )
                .font(.system(size: T.TypeScale.body))
                .lineSpacing(T.TypeScale.bodyLineSpacing)
                .foregroundStyle(T.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)

                ledgerCycle
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, T.Spacing.s)
            }
            .padding(.horizontal, T.Spacing.xl)
            .padding(.top, T.Spacing.xxl)
            .padding(.bottom, T.Spacing.xl)
        }
    }

    /// 你记 → being 记/定档/追问 → 你确认。只用 SF Symbols，不引图。
    private var ledgerCycle: some View {
        HStack(alignment: .center, spacing: T.Spacing.s) {
            cycleNode(symbol: "square.and.pencil", title: "你记")
            Image(systemName: "arrow.right")
                .font(.system(size: T.TypeScale.caption, weight: .semibold))
                .foregroundStyle(T.Ink.tertiary)
            cycleNode(symbol: "sparkles", title: "being\n记/定档/追问", multiline: true)
            Image(systemName: "arrow.right")
                .font(.system(size: T.TypeScale.caption, weight: .semibold))
                .foregroundStyle(T.Ink.tertiary)
            cycleNode(symbol: "checkmark.circle", title: "你确认")
        }
        .padding(T.Spacing.l)
        // 原来是 controlBackgroundColor：浅色模式下它和窗口底同是白，这块循环图没有边界，
        // 三个节点散在空白里。换成 Ink 的容器面，亮暗两档都看得出「这是一张图」。
        .background(T.Ink.fillSubtle, in: RoundedRectangle(cornerRadius: T.Spacing.l, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: T.TypeScale.caption))
                .foregroundStyle(T.Ink.quaternary)
                .padding(T.Spacing.s)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("循环：你记，being 记定档或追问，你确认")
    }

    private func cycleNode(symbol: String, title: String, multiline: Bool = false) -> some View {
        VStack(spacing: T.Spacing.s) {
            Image(systemName: symbol)
                .font(.system(size: T.TypeScale.title))
                .foregroundStyle(KairosMacPalette.attention)
                .frame(height: 28)
            // 节点名不加粗：橙色图标已经是视觉锚点，字只负责念出来。
            Text(title)
                .font(.system(size: T.TypeScale.caption))
                .multilineTextAlignment(.center)
                .foregroundStyle(T.Ink.primary)
                .lineLimit(multiline ? 3 : 2)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
    }

    private func bulletRow(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: T.Spacing.s) {
            Text("·")
                .font(.system(size: T.TypeScale.body, weight: .semibold))
                .foregroundStyle(KairosMacPalette.attention)
            Text(text)
                .font(.system(size: T.TypeScale.body))
                .lineSpacing(T.TypeScale.bodyLineSpacing)
                .foregroundStyle(T.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 页 3

    private var pageThree: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: T.Spacing.xl) {
                Text("being 做的每件事都有出处。")
                    .font(.system(size: T.TypeScale.display, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: T.Spacing.m) {
                    bulletRow("每条待办一个对话房：它的每个动作都留一条信，可追问、可撤销。")
                    bulletRow("改了什么，回执写明白，不静默。")
                    bulletRow("不想让它动哪块，关掉那块。账本始终是你的。")
                    bulletRow("先不连？完整的手账本，手记手排全都能用，随时可补连。")
                    bulletRow("数据在你自己的设备和 iCloud，没有第三方云。")
                }

                // 两颗按钮一样高：主次由「实心橙 / 描边」说，不靠高矮和字重再说一遍。
                // 主按钮留 medium——整个引导唯一的出口，这是真正该强调的地方。
                VStack(spacing: T.Spacing.m) {
                    Button {
                        onFinish(.startUsing)
                    } label: {
                        Text("开始用")
                            .font(.system(size: T.TypeScale.body, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, T.Spacing.m)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        onFinish(.connectBeing)
                    } label: {
                        Text("现在去连接 being")
                            .font(.system(size: T.TypeScale.body))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, T.Spacing.m)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, T.Spacing.m)

                Text("连上后，到设置 › Being 点一下「请求规则」，它才把规则全文发进来——请求以你的名义发出，不经你点不发。")
                    .font(.system(size: T.TypeScale.caption))
                    .foregroundStyle(T.Ink.secondary)
                    .padding(.top, T.Spacing.xs)
            }
            .padding(.horizontal, T.Spacing.xl)
            .padding(.top, T.Spacing.xxl)
            .padding(.bottom, T.Spacing.xl)
        }
    }
}
