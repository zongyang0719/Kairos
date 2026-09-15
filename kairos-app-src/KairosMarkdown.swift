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
