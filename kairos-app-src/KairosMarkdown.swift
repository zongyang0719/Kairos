import Foundation

/// 把 being 回的一段话切成「散文」和「表格」两种块。
///
/// ## 为什么要有这一层
///
/// SwiftUI 的 `Text` 是认 markdown 的，但只认**行内**那几样——粗体、斜体、链接、行内代码。
/// 块级的东西（表格、列表、标题）它一概不解析：`AttributedString(markdown:)` 底下那个
/// 解析器连 GFM 的表格语法都没有，就算解析出来了，`Text` 也没法把一张表排成一张表。
///
/// 于是一张表进了气泡，就是一堆竖线和横杠按比例字体折行，列全部对不上
/// 回复里带表格的话，信息会错乱。这不是 markdown 开关
/// 没打开，是 `Text` 这条路本来就到不了——表格只能自己排。
///
/// 所以这里只做一件事：**切块**。散文照旧交给 `Text` 的行内 markdown（那部分它做得挺好），
/// 表格交给 `Grid` 自己画。纯逻辑，不碰 SwiftUI，能单独编译进 `tests/native-markdown` 里验。
enum KairosMarkdownBlock: Equatable {
    case prose(String)
    case table(header: [String], rows: [[String]])
    /// 列表也是块级的，`Text` 同样不认——`- 三条` 原样显示成一个横杠加文字，
    /// 该换行的不换行、该缩进的不缩进——右侧可读性很差。
    /// `ordered` 只决定前面画圆点还是画序号，序号按顺序重排，不沿用原文里的数字。
    case list(ordered: Bool, items: [String])
}

extension KairosMarkdownBlock {
    /// 流着的时候，这一刻能放心画出来的那一截。
    ///
    /// **为什么要扣下结尾。** 正文是一段段流进来的，一条 `- 文案等设计稿` 要好几趟才到齐。
    /// 先到的那个光杆 `-` 不是列表项（`bullet` 要求标记后面有字），于是自成一段散文，
    /// 画在列表**底下**——散文的缩进、散文的行距；下一趟字一到，它又并回列表里去。
    /// **一条清单有几项就这么闪几下。** 表格更显眼：表头那行要等 `|-` 到了才算表，
    /// 在那之前是一行原样的竖杠。
    ///
    /// 所以流着的时候，结尾那一段「看着像块的开头、但还没成块」的行先不画，等它写完再进块——
    /// 屏幕上就不会先摆出一个马上要消失的样子。**普通散文不扣**：那是绝大多数，照常一个字一个字出来。
    ///
    /// 只在流的时候这么干。落进房间的消息走 `parse(_:)`，一个字都不少。
    static func streamingPrefix(_ text: String) -> String {
        var lines = text.components(separatedBy: .newlines)
        while !lines.isEmpty {
            // 光杆的 `-` / `*` / `+` / `1.` / `1)`：标记到了，字还没到。
            // **只认最后一行**：后面还有行，说明这一行已经写完了，那它就真是一段话。
            if isBareMarker(lines[lines.count - 1]) {
                lines.removeLast()
                continue
            }
            // 表头那行刚换完行、下一行还没开始写的时候，要看的是它上面那一行——
            // 只跳**一个**空行：连着两个空行说明这一块已经封口了，不会再变成表，那就照画。
            var last = lines.count - 1
            if lines[last].trimmingCharacters(in: .whitespaces).isEmpty, last > 0,
               !lines[last - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                last -= 1
            }
            // 结尾那一串竖杠行还没凑成一张表（缺分隔行）：整串先不画，别先摆一行竖杠。
            // 只认以 `|` 开头的——散文里那种「a | b」不扣，不然一句话会卡在半路上。
            guard lines[last].trimmingCharacters(in: .whitespaces).hasPrefix("|"),
                  !endsInTable(Array(lines[...last])) else { break }
            var start = last
            while start > 0, lines[start - 1].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                start -= 1
            }
            lines.removeSubrange(start...)
        }
        return lines.joined(separator: "\n")
    }

    /// 标记到了、字还没到的那一行。
    private static func isBareMarker(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if ["-", "*", "+"].contains(trimmed) { return true }
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty else { return false }
        let rest = trimmed.dropFirst(digits.count)
        return rest == "." || rest == ")"
    }

    /// 结尾那一串竖杠行已经是一张表了吗。是 = 可以画，不是 = 还在打字。
    private static func endsInTable(_ lines: [String]) -> Bool {
        var start = lines.count - 1
        while start > 0, lines[start - 1].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
            start -= 1
        }
        return table(at: start, in: lines) != nil
    }

    /// 切块。认不出表格的一律当散文原样留着——**宁可少认一张表，不可吃掉一段话**。
    static func parse(_ text: String) -> [KairosMarkdownBlock] {
        let lines = text.components(separatedBy: .newlines)
        var blocks: [KairosMarkdownBlock] = []
        var prose: [String] = []
        var index = 0

        func flushProse() {
            let joined = prose.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.prose(joined)) }
            prose = []
        }

        while index < lines.count {
            if let found = table(at: index, in: lines) {
                flushProse()
                blocks.append(.table(header: found.header, rows: found.rows))
                index = found.end
                continue
            }
            if let found = list(at: index, in: lines) {
                flushProse()
                blocks.append(.list(ordered: found.ordered, items: found.items))
                index = found.end
                continue
            }
            prose.append(lines[index])
            index += 1
        }
        flushProse()
        return blocks
    }

    /// 一串列表：连着的若干行，每行都是 `- ` / `* ` / `+ ` 或 `1. ` / `1) `。
    /// 有序无序不混排——第一行定调，换了样式就当新的一块，免得把两组并成一组。
    /// **认不出就当散文**，和表格一个原则：宁可少认一串，不可吃掉一段话。
    private static func list(
        at start: Int,
        in lines: [String]
    ) -> (ordered: Bool, items: [String], end: Int)? {
        guard let first = bullet(lines[start]) else { return nil }
        var items = [first.text]
        var index = start + 1
        while index < lines.count,
              let next = bullet(lines[index]),
              next.ordered == first.ordered {
            items.append(next.text)
            index += 1
        }
        return (first.ordered, items, index)
    }

    /// 一行是不是列表项，以及它是有序还是无序。标记后面必须有空白——
    /// `-30%` 和 `1.5 倍` 不是列表项，是话。
    private static func bullet(_ line: String) -> (ordered: Bool, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            let text = String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : (false, text)
        }
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        var rest = trimmed.dropFirst(digits.count)
        guard let separator = rest.first, separator == "." || separator == ")" else { return nil }
        rest = rest.dropFirst()
        guard let space = rest.first, space == " " else { return nil }
        let text = String(rest).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (true, text)
    }

    /// 一张表的入场条件：这一行是行、**下一行是分隔行**（`|---|---|`）。
    /// 光看竖线不够——散文里带个竖线的句子多得是，分隔行才是那个不会撞车的信号。
    private static func table(
        at start: Int,
        in lines: [String]
    ) -> (header: [String], rows: [[String]], end: Int)? {
        guard start + 1 < lines.count,
              isRow(lines[start]),
              isDelimiter(lines[start + 1]) else { return nil }
        let header = cells(lines[start])
        // 单列的「表」更可能是一句带竖线的话。两列起才算。
        guard header.count >= 2 else { return nil }

        var rows: [[String]] = []
        var index = start + 2
        while index < lines.count, isRow(lines[index]) {
            rows.append(normalize(cells(lines[index]), to: header.count))
            index += 1
        }
        return (header, rows, index)
    }

    /// 空行不是行——表格到空行为止，后面那段散文不会被吃进来。
    private static func isRow(_ line: String) -> Bool {
        line.contains("|")
    }

    private static func isDelimiter(_ line: String) -> Bool {
        let parts = cells(line)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { cell in
            var body = cell
            if body.hasPrefix(":") { body.removeFirst() }
            if body.hasSuffix(":") { body.removeLast() }
            return !body.isEmpty && body.allSatisfy { $0 == "-" }
        }
    }

    /// 拆格子。首尾那对竖线是装饰，去掉；`\|` 是格子里的竖线，不是分隔符。
    static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
        let guard_ = "\u{1}"
        return trimmed
            .replacingOccurrences(of: "\\|", with: guard_)
            .components(separatedBy: "|")
            .map {
                $0.replacingOccurrences(of: guard_, with: "|")
                    .trimmingCharacters(in: .whitespaces)
            }
    }

    /// 行的格子数对不上表头是常事（being 少打一个竖线）。补齐或截掉，
    /// **不因此把整张表判成散文**——那样人看到的是一屏竖线。
    private static func normalize(_ row: [String], to width: Int) -> [String] {
        if row.count == width { return row }
        if row.count > width { return Array(row.prefix(width)) }
        return row + Array(repeating: "", count: width - row.count)
    }
}

// MARK: - 抬头那段背景里的真源

/// 抬头那段背景（`brief`）里拎出来的一条链接。
struct KairosBriefLink: Equatable, Hashable, Identifiable {
    /// 胶囊上写的那几个字。being 在链接前面写了短标签（「📄 PRD 全文：」）就用标签——
    /// 它比文件名短、比文件名准；没写才退回链接自己的文字（多半就是文件名）。
    var label: String
    var url: String

    var id: String { label + "\u{0}" + url }

    /// tooltip 和「拷贝」用的那一份：百分号编码还原成人读得懂的路径。
    var readable: String { url.removingPercentEncoding ?? url }
}

/// 把 being 写的那段背景拆成「读的」和「点的」。
///
/// ## 为什么要拆
///
/// being 习惯在 `brief` 末尾单起一段挂真源：
/// 「📄 PRD 全文：[xxx.md](file:///…)　·　调研：[yyy.md](file:///…)」。
/// 跟正文挤在一起有两处不对：抬头里的背景默认只露三行，而这一段永远排在最后——
/// **它正好就是每次被折掉的那一段**；就算点开，它也还是一整块可选中文字里的一小截蓝字，
/// 点不点得中全看手准。人看到的结果就是「有链接，但完全点不了」。
///
/// 所以在画之前就分开：正文归正文（照旧折叠），链接归链接——一排按钮钉在正文底下，
/// 不参与折叠，点的是按钮不是字。
///
/// ## 什么算「链接段」
///
/// 整段除了链接只剩标签：每一截非链接的文字，去掉装饰（emoji、`·`、冒号、空格）后不超过
/// 8 个字，而且不带句末标点。「详见 [文档](url)，我的判断是……」这种链接长在句子里的**不动**——
/// 把它挖出来，剩下的半句话就不成话了。那种链接仍旧留在正文里，还是 `Text` 的行内链接。
enum KairosBrief {
    /// 拆。`prose` 是照旧要折叠的正文，`links` 按出现顺序、同一个 url 只留一条。
    static func split(_ text: String) -> (prose: String, links: [KairosBriefLink]) {
        var prose: [String] = []
        var links: [KairosBriefLink] = []
        for paragraph in paragraphs(text) {
            guard let picked = linksOnly(paragraph) else {
                prose.append(paragraph)
                continue
            }
            for link in picked where !links.contains(where: { $0.url == link.url }) {
                links.append(link)
            }
        }
        return (prose.joined(separator: "\n\n"), links)
    }

    /// 空行分段——和 markdown 一样。段内的换行原样留着。
    private static func paragraphs(_ text: String) -> [String] {
        var result: [String] = []
        var current: [String] = []
        for line in text.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty {
                    result.append(current.joined(separator: "\n"))
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { result.append(current.joined(separator: "\n")) }
        return result
    }

    /// 这一段是不是「除了链接只剩标签」。是就把链接按出现顺序交出来；
    /// 不是就返回 nil——那一段原样留在正文里，一个字都不动。
    private static func linksOnly(_ paragraph: String) -> [KairosBriefLink]? {
        let found = scan(paragraph)
        guard !found.isEmpty else { return nil }

        var links: [KairosBriefLink] = []
        var cursor = paragraph.startIndex
        for one in found {
            guard let tag = labelTag(String(paragraph[cursor..<one.range.lowerBound])) else { return nil }
            cursor = one.range.upperBound
            let fallback = one.label.isEmpty ? fileName(one.url) : one.label
            links.append(KairosBriefLink(label: tag.isEmpty ? fallback : tag, url: one.url))
        }
        // 最后一条链接后面的尾巴也得是标签，不能是半句话。
        guard labelTag(String(paragraph[cursor...])) != nil else { return nil }
        return links
    }

    /// 链接之间那一截文字。是短标签就交出干净的那几个字（可能是空字符串），
    /// 是正经话就 nil。
    private static func labelTag(_ raw: String) -> String? {
        if raw.contains(where: { "。！？；!?;".contains($0) }) { return nil }
        // 留字、留数字、留半角空格（「PRD 全文」中间那个），其余一律是装饰：
        // emoji、间隔号、全角空格、冒号、竖线、逗号。
        let tidy = String(raw.filter { $0.isLetter || $0.isNumber || $0 == " " })
            .trimmingCharacters(in: .whitespaces)
        return tidy.count <= 8 ? tidy : nil
    }

    /// 扫出一段里的链接：`[文字](地址)`，以及裸写的一条 http / file。
    ///
    /// 不用正则：`[` 和 `]` 之间可以有中文标点、地址里有一大串百分号编码，
    /// 一条能把这些都照顾到的正则比这段循环难读得多，也没法单独验。
    /// 从左往右一次过，markdown 链接整体先被吃掉——里面那截地址不会再被当成裸链接数一遍。
    private static func scan(_ paragraph: String) -> [(range: Range<String.Index>, label: String, url: String)] {
        var found: [(range: Range<String.Index>, label: String, url: String)] = []
        var i = paragraph.startIndex
        while i < paragraph.endIndex {
            if paragraph[i] == "[", let link = markdownLink(paragraph, from: i) {
                found.append(link)
                i = link.range.upperBound
                continue
            }
            if let scheme = schemes.first(where: { paragraph[i...].hasPrefix($0) }) {
                var end = paragraph.index(i, offsetBy: scheme.count)
                while end < paragraph.endIndex, !isURLEnd(paragraph[end]) {
                    end = paragraph.index(after: end)
                }
                let url = String(paragraph[i..<end])
                found.append((range: i..<end, label: "", url: url))
                i = end
                continue
            }
            i = paragraph.index(after: i)
        }
        return found
    }

    private static let schemes = ["https://", "http://", "file://"]

    /// 地址到哪儿为止：空白、右括号，以及中文行文里紧跟在后面的那几个标点。
    private static func isURLEnd(_ char: Character) -> Bool {
        char.isWhitespace || "()（）、，。；！？".contains(char)
    }

    /// `[文字](地址)`。地址里不许有空白和括号——有就不是一条链接，原样当文字。
    private static func markdownLink(
        _ paragraph: String,
        from start: String.Index
    ) -> (range: Range<String.Index>, label: String, url: String)? {
        guard let close = paragraph[start...].firstIndex(of: "]") else { return nil }
        let open = paragraph.index(after: close)
        guard open < paragraph.endIndex, paragraph[open] == "(" else { return nil }
        var end = paragraph.index(after: open)
        while end < paragraph.endIndex, paragraph[end] != ")" {
            guard !paragraph[end].isWhitespace, paragraph[end] != "(" else { return nil }
            end = paragraph.index(after: end)
        }
        guard end < paragraph.endIndex else { return nil }
        let label = String(paragraph[paragraph.index(after: start)..<close])
        let url = String(paragraph[paragraph.index(after: open)..<end])
        guard !url.isEmpty else { return nil }
        return (
            range: start..<paragraph.index(after: end),
            label: label.trimmingCharacters(in: .whitespaces),
            url: url
        )
    }

    /// 没有标签时退回的那几个字：路径最后一段。长文件名在 460pt 的那一栏里会把
    /// 一排胶囊顶出去，所以自己先从中间省掉——截断交给这里，画的地方不用再猜宽度。
    private static func fileName(_ url: String) -> String {
        let decoded = url.removingPercentEncoding ?? url
        let tail = decoded.split(separator: "/").last.map(String.init) ?? decoded
        let name = tail.isEmpty ? decoded : tail
        guard name.count > 24 else { return name }
        return name.prefix(14) + "…" + name.suffix(8)
    }
}
