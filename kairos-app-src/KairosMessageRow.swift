import Foundation

/// 消息也是账本上的一行。
///
/// being 在 Town 的活动（篝火 @ 你、炉火、私信）要出现在单子上，落点就是带
/// `counterpart` 的账本条目。**行由 being 建**（它写 `counterpart` 建条目即可），
/// 这里只剩行 id 的稳定规则：一个人在一条管子里只有一行，不是每句话一行。
///
/// 2026-09-11 人类定的原则：「所有行必须一样：能勾、能拖、能改档位、能进项目」——
/// 那时候信是第二种行（不能拖、不能进项目），消息进账本就是为了干掉这种特例。
/// 2026-09-15 起，单子上只有一种行。
enum KairosMessageRow {
    /// 一个人在一条管子里只有一行，id 由此稳定。**不是每封信一行**：
    /// Judy 一天问三件事是一行（欠她一个回复），不是三行——一百个人的时候，按封分是灾难。
    /// 她问出来的两件真正的活另起两行待办（人类的第 7 条）。
    static func rowID(channel: String, address: String) -> String {
        "msg:\(channel):\(address)"
    }

    /// 一封信的**第一句**，拿来当这一行的标题。
    ///
    /// 标题里**不带人名**——名字是 `counterpart.name`，由行自己画在前面
    /// （「Judy · 周四那版能不能先看」）。写进标题会重复，而且人改过标题之后名字就钉死在里面了。
    ///
    /// **2026-09-13 从「前 40 个字」改成「第一句」。** 40 个字在一行里放不下：
    /// 「上次说的那个插件接口，我这边空出下周二一整天，你看要不要一起过一遍。」35 个字整段进了标题，
    /// 单子上一封信占三行，标题成了正文。现在：到第一个句末标点为止；这一句本身还长（中文口语
    /// 常常一逗到底），就在第一个逗号处断；再长才硬截。剩下的话由副行接着说（`displaySummary`）。
    static func headline(_ text: String, limit: Int = 24) -> String {
        let flat = flatten(text)
        guard !flat.isEmpty else { return "（空信）" }
        let enders: Set<Character> = ["。", "！", "？", "!", "?", "；", ";", "…"]
        var sentence = flat
        if let cut = flat.firstIndex(where: { enders.contains($0) }) {
            let head = String(flat[..<cut]).trimmingCharacters(in: .whitespaces)
            if !head.isEmpty { sentence = head }
        }
        if sentence.count > limit,
           let comma = sentence.firstIndex(where: { "，,、".contains($0) }),
           sentence.distance(from: sentence.startIndex, to: comma) >= 6 {
            sentence = String(sentence[..<comma])
        }
        return sentence.count <= limit ? sentence : String(sentence.prefix(limit)) + "…"
    }

    /// 标题之后剩下的那些话，给副行用。标题是第一句，这里就是从第二句起；
    /// 标题是硬截的（没有标点可断），剩下的就是空——副行不重复念标题。
    static func remainder(_ text: String, after title: String) -> String {
        let flat = flatten(text)
        let head = title.hasSuffix("…") ? String(title.dropLast()) : title
        guard !head.isEmpty, flat.hasPrefix(head) else { return "" }
        let rest = flat.dropFirst(head.count)
            .drop(while: { "。！？!?；;…，,、 ".contains($0) })
        return String(rest).trimmingCharacters(in: .whitespaces)
    }

    /// 旧规则（整段前 40 个字）。**只给迁移用**：认得出「这一行的标题是不是当年机器写的」，
    /// 是才换成新规则，人自己改过的标题一个字都不碰。
    static func legacyHeadline(_ text: String, limit: Int = 40) -> String {
        let flat = flatten(text)
        guard !flat.isEmpty else { return "（空信）" }
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }

    private static func flatten(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 老条目没有 `counterpart`（那时候还没这个字段），但**原话对得上**就是同一件事。
    ///
    /// 真实例子：being 早先给 maple 那封信建过一条「Maple 打招呼」并了结了，
    /// 它的 `excerpt` 和镜像里那封的正文一字不差。不认这一条的话，
    /// 单子上会出现两行 maple——一行是它了结过的，一行是机械建的「在等你回」，
    /// 而后者是假的：那封信早就处理完了。
    ///
    /// 只认**整段原话**对得上（长度够长才比，短句子容易撞）。宁可漏认一条留下重复，
    /// 也不能错认两件不同的事、把它们并成一行。
    private static func sameLetter(_ item: KairosItem, as content: String, channel: String) -> Bool {
        guard item.counterpart == nil else { return false }   // 有对方的走上面那条精确的路
        guard KairosSource.normalized(item.source) == channel else { return false }
        let mine = item.excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        let letter = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mine.count >= 12, letter.count >= 12 else { return false }
        return mine == letter || mine.contains(letter) || letter.contains(mine)
    }

}
