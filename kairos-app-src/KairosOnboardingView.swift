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

            bottomBar
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
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

            HStack(spacing: 8) {
                ForEach(0 ..< 2, id: \.self) { index in
                    Capsule()
                        .fill(index == step ? AnyShapeStyle(KairosMacPalette.attention) : AnyShapeStyle(.quaternary))
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
            VStack(alignment: .leading, spacing: 20) {
                Text("所有事，落进同一张单子。")
                    .font(.largeTitle.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)

                Text(
                    "你记的、being 从你话里听到的（你说「周五要交」，它记一条）、私信里欠的回复——"
                        + "都是这张单子上的一条。账本只有一份，在你手里。being 是伙伴，不是托管："
                        + "它帮你定优先级、追问缺口，但每一件事的球在谁手里，看得见。"
                )
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                ledgerCycle
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .padding(.horizontal, 28)
            .padding(.top, 32)
            .padding(.bottom, 24)
        }
    }

    /// 你记 → being 记/定档/追问 → 你确认。只用 SF Symbols，不引图。
    private var ledgerCycle: some View {
        HStack(alignment: .center, spacing: 8) {
            cycleNode(symbol: "square.and.pencil", title: "你记")
            Image(systemName: "arrow.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            cycleNode(symbol: "sparkles", title: "being\n记/定档/追问", multiline: true)
            Image(systemName: "arrow.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            cycleNode(symbol: "checkmark.circle", title: "你确认")
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.quaternary)
                .padding(10)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("循环：你记，being 记定档或追问，你确认")
    }

    private func cycleNode(symbol: String, title: String, multiline: Bool = false) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(KairosMacPalette.attention)
                .frame(height: 28)
            Text(title)
                .font(.caption.weight(.medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
                .lineLimit(multiline ? 3 : 2)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
    }

    private func bulletRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("·")
                .font(.body.weight(.semibold))
                .foregroundStyle(KairosMacPalette.attention)
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 页 3

    private var pageThree: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("being 做的每件事都有出处。")
                    .font(.largeTitle.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 14) {
                    bulletRow("每条待办一个对话房：它的每个动作都留一条信，可追问、可撤销。")
                    bulletRow("改了什么，回执写明白，不静默。")
                    bulletRow("不想让它动哪块，关掉那块。账本始终是你的。")
                    bulletRow("先不连？完整的手账本，手记手排全都能用，随时可补连。")
                    bulletRow("数据在你自己的设备和 iCloud，没有第三方云。")
                }

                VStack(spacing: 12) {
                    Button {
                        onFinish(.startUsing)
                    } label: {
                        Text("开始用")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        onFinish(.connectBeing)
                    } label: {
                        Text("现在去连接 being")
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 12)

                Text("连上后，去设置里向它要一份它的规矩，收下后随时能看。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 28)
            .padding(.top, 32)
            .padding(.bottom, 24)
        }
    }
}
