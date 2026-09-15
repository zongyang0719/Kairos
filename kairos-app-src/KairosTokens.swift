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

        /// 等比阶梯：从 base 向上/下走 n 步（步长 1.2），四舍五入取整
        static func scaled(_ base: CGFloat, steps: Int) -> CGFloat {
            (pow(1.2, CGFloat(steps)) * base).rounded()
        }
    }

    // MARK: - Spacing（4pt 基，等差）
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
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
    }

    // MARK: - Color（中性自持；accent 与语义色不在此定义、全跟随系统）
    enum Ink {
        // 中性骨架：label 色 alpha 梯度，亮暗自动各一套
        static let primary = Color.primary.opacity(0.92)
        static let secondary = Color.primary.opacity(0.55)
        static let tertiary = Color.primary.opacity(0.35)
        static let quaternary = Color.primary.opacity(0.18)
        // 基底：材质为主，颜色只做层次
        static let surface = Color(nsColor: .windowBackgroundColor)

        // accent —— 一律取 Color.accentColor（= 系统强调色，你=粉）
        // 语义动作 —— systemGreen(完成) / systemOrange(警告) / systemRed(错误) 按语义直取
    }
}
