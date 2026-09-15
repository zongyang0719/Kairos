import AppKit
import SwiftUI

/// Kairos Design Tokens — 设计四表（Type/Spacing/Motion/Color）的唯一代码真源。
/// 哲学：动效是隐喻不是物理（bounce 禁用）；颜色「不定义即跟随」（accent 走系统强调色）；
/// 中性骨架自持，语义色各归其位。改值只改这里，不改调用点。
enum KairosTokens {

    // MARK: - Type（等比 1.2，body=13 起；13 以下等差微调）
    enum TypeScale {
        static let caption: CGFloat = 11      // 辅注、时间戳
        static let body: CGFloat = 13         // 正文（贴 OS 默认节奏）
        static let headline: CGFloat = 16     // 小节标题 = body × 1.2
        static let title: CGFloat = 19        // 页面标题 = headline × 1.2
        static let lineHeight: CGFloat = 1.45 // 正文行高倍数

        /// 展示档 = title 往上等比一步（23）。**不是第五档层级**：一屏只许一处用它——
        /// 工具栏的日期、引导页的那一句。它是「这一屏的主角」，不参与正文的层级比较。
        static var display: CGFloat { scaled(title, steps: 1) }

        /// 等比阶梯：从 base 向上/下走 n 步（步长 1.2），四舍五入取整
        static func scaled(_ base: CGFloat, steps: Int) -> CGFloat {
            (pow(1.2, CGFloat(steps)) * base).rounded()
        }

        /// 把「行高 1.45 倍」换成 SwiftUI `.lineSpacing` 要的**额外行距**。
        ///
        /// SwiftUI 的行距是加在字体自然行高上面的。自然行高要取**排版引擎实际给的那一个**
        /// （`NSLayoutManager.defaultLineHeight`，SF 13pt = 16），不是字体的 ascender − descender
        /// （15.5）——拿后者算，实测中文段落行距落在 1.51 倍，比设计值松半档。
        /// 中文字形由 PingFang 回退绘制，但行框按主字体算，所以中英混排一段话就是这一个数。
        /// 13pt → ≈2.85（行距 ≈18.85 = 13 × 1.45）；11pt → ≈2.95。
        static func lineSpacing(for size: CGFloat) -> CGFloat {
            let natural = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: size))
            return max(0, size * lineHeight - natural)
        }

        /// 正文（13pt）段落的额外行距。多行阅读的文字一律用它，不再各写各的 `lineSpacing(4)`。
        static let bodyLineSpacing: CGFloat = lineSpacing(for: body)
        /// 辅注（11pt）成段时的额外行距：设置里两三行的说明文字。
        static let captionLineSpacing: CGFloat = lineSpacing(for: caption)
    }

    // MARK: - Spacing（4pt 基，等差）
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32

        // 语义档（不在 4pt 阶梯上，是有意的例外，起名而不抹平）
        /// 行、输入框的水平内边距：保证输入框里的圈和列表行首的圈对齐成一竖列。别改成 8 / 12。
        static let rowInset: CGFloat = 10
        /// 行内上下两行文字之间（标题 ↔ 副行）、小胶囊的上下内边距。
        static let hairline: CGFloat = 2
    }

    // MARK: - Radius（一律配 `style: .continuous`；圆角不借 Spacing 表的值）
    enum Radius {
        /// 拖拽落点、小标记
        static let s: CGFloat = 6
        /// 输入框、气泡、面板
        static let m: CGFloat = 10
        /// 浮层卡片
        static let l: CGFloat = 12
    }

    // MARK: - Motion（隐喻动效：每个值绑一条产品语义，无语义不动）
    enum Motion {
        /// 数字滚动、accent 提亮
        static let instant: TimeInterval = 0.12
        /// 落笔：新建卡片从纸面浮起（y+8→0，scale 0.98→1）
        static let write: TimeInterval = 0.18
        /// 划账：笔画勾 + 划线扫过 + 行沉降；递信：状态点滑动
        static let stroke: TimeInterval = 0.24
        /// 销账落地：accent 微尘庆祝（只此一次，不循环）
        static let settle: TimeInterval = 0.30

        /// 出场/登场曲线（无过冲）
        static let easeOut = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)
        /// 退场曲线
        static let easeIn = Animation.timingCurve(0.4, 0, 1, 1, duration: 0.20)
        /// 临界阻尼弹簧：有重量反馈、无弹跳（bounce 禁用）
        static let weighted = Animation.spring(response: 0.35, dampingFraction: 1.0)

        /// 即时反馈：拖拽落点高亮、hover、「记下 / 已记下」切换。
        static let feedback = Animation.easeOut(duration: instant)
        /// 落笔登场（write 档）：记一条输入框出现。
        static let enter = Animation.timingCurve(0.22, 1, 0.36, 1, duration: write)
        /// 划账笔画（stroke 档）：划线扫过、勾号描画。
        static let strokeCurve = Animation.timingCurve(0.22, 1, 0.36, 1, duration: stroke)

        /// 减弱动态效果：开启时位移 / 缩放 / 描画一律退成一次短淡入淡出（instant 档）。
        /// 调用点读 `@Environment(\.accessibilityReduceMotion)` 传进来。
        static func reduced(_ animation: Animation, _ reduce: Bool) -> Animation {
            reduce ? .easeOut(duration: instant) : animation
        }
    }

    // MARK: - Color（中性自持；accent 与语义色不在此定义、全跟随系统）
    enum Ink {
        // 中性骨架：label 色 alpha 梯度，亮暗自动各一套
        static let primary = Color.primary.opacity(0.92)
        static let secondary = Color.primary.opacity(0.55)
        static let tertiary = Color.primary.opacity(0.35)
        static let quaternary = Color.primary.opacity(0.18)
        // 面：同一支 label 色的低 alpha 档，**只做底、不做字**（亮暗各自一套，等权成立）。
        // 三档对应「容器 → 元素 → 强调元素」：元素（0.06）放进容器（0.04）里仍然分得出层。
        static let fillStrong = Color.primary.opacity(0.08)  // 自己说的那句、胶囊描边
        static let fill = Color.primary.opacity(0.06)        // 气泡、胶囊、药丸、输入框、搜索框
        static let fillSubtle = Color.primary.opacity(0.04)  // 包住一组元素的容器（往来、引导循环图）
        // 基底：材质为主，颜色只做层次
        static let surface = Color(nsColor: .windowBackgroundColor)

        // accent —— 一律取 Color.accentColor（= 系统强调色，你=粉）
        // 语义色 —— 归 app，不取系统色：P0 / 冲突 / 要你拍板 → `KairosMacPalette.critical`，
        //   P1 / 要你注意 → `KairosMacPalette.priority`（两端一份数值）。表单里的系统错误文字可留系统红。
        //
        // **什么时候不用 Ink、留系统的 .secondary / .tertiary**：文字画在**材质或玻璃**上时——
        // 边栏、工具栏里的项、`glassEffect` 胶囊。系统的层级样式在材质上会走 vibrancy，
        // 玻璃还会按底下内容翻深浅；`Color.primary.opacity` 是一块死颜色，两样都跟不上。
        // 实底内容区（单子、房间、信、表单、弹层、引导）一律走 Ink。
    }
}
