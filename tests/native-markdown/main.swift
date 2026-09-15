import Foundation

// 表格切块。被测的类型在 kairos-app-src/KairosMarkdown.swift，由 run-tests.sh 一起编。

func check(_ condition: Bool, _ what: String) {
    if !condition {
        FileHandle.standardError.write(Data("FAIL: \(what)\n".utf8))
        exit(1)
    }
}

// 一张干净的表：表头 + 分隔行 + 两行。
do {
    let text = """
    看下来是这样：

    | 服务 | 能存吗 | 为什么不行 |
    |---|---|---|
    | scrolls | 能 | 语义错位 |
    | workspace | 能 | 7 天过期 |

    所以只能新开一个。
    """
    let blocks = KairosMarkdownBlock.parse(text)
    check(blocks.count == 3, "散文 / 表格 / 散文 三块，实际 \(blocks.count)")
    check(blocks[0] == .prose("看下来是这样："), "第一块是开场白")
    guard case .table(let header, let rows) = blocks[1] else {
        check(false, "第二块该是表格"); exit(1)
    }
    check(header == ["服务", "能存吗", "为什么不行"], "表头三列：\(header)")
    check(rows.count == 2, "两行数据，实际 \(rows.count)")
    check(rows[1] == ["workspace", "能", "7 天过期"], "第二行：\(rows[1])")
    check(blocks[2] == .prose("所以只能新开一个。"), "第三块是结尾")
}

// 没有分隔行的一律不算表——散文里带竖线的句子多得是，不能把话吃掉。
do {
    let text = "这条路要么走 A|B，要么不走。"
    let blocks = KairosMarkdownBlock.parse(text)
    check(blocks == [.prose(text)], "带竖线的散文原样留着：\(blocks)")
}

// 单列不算表。
do {
    let text = """
    | 只有一列 |
    |---|
    | 所以是散文 |
    """
    let blocks = KairosMarkdownBlock.parse(text)
    guard case .prose = blocks.first else {
        check(false, "单列该当散文"); exit(1)
    }
    check(blocks.count == 1, "单列不切块")
}

// 行的格子数少一个：补齐，不因此把整张表判掉。
do {
    let text = """
    | a | b | c |
    | --- | :--- | ---: |
    | 1 | 2 |
    | 1 | 2 | 3 | 4 |
    """
    let blocks = KairosMarkdownBlock.parse(text)
    guard case .table(let header, let rows) = blocks.first else {
        check(false, "该认出表格"); exit(1)
    }
    check(header.count == 3, "三列表头")
    check(rows[0] == ["1", "2", ""], "少一格补空：\(rows[0])")
    check(rows[1] == ["1", "2", "3"], "多一格截掉：\(rows[1])")
}

// 首尾不带竖线的写法（GFM 允许）也认。
do {
    let text = """
    服务 | 能存吗
    --- | ---
    scrolls | 能
    """
    let blocks = KairosMarkdownBlock.parse(text)
    guard case .table(let header, let rows) = blocks.first else {
        check(false, "裸写法该认出来"); exit(1)
    }
    check(header == ["服务", "能存吗"], "表头：\(header)")
    check(rows == [["scrolls", "能"]], "数据行：\(rows)")
}

// 格子里的 `\|` 是内容，不是分隔符。
do {
    check(KairosMarkdownBlock.cells(#"| a \| b | c |"#) == [#"a | b"#, "c"], "转义竖线不拆格子")
}

// 空行结束一张表：后面那段散文不能被吞进去。
do {
    let text = """
    | a | b |
    |---|---|
    | 1 | 2 |

    这句话在表外面。
    """
    let blocks = KairosMarkdownBlock.parse(text)
    check(blocks.count == 2, "表 + 散文，实际 \(blocks.count)")
    check(blocks[1] == .prose("这句话在表外面。"), "表后的话还在：\(blocks[1])")
}

// 没有表格的一整段话：一块散文，原样。
do {
    let text = "就是一段话，\n带个换行。"
    check(KairosMarkdownBlock.parse(text) == [.prose(text)], "纯散文原样一块")
}

// 流式：表格只写到一半（分隔行还没到）时不能瞎认。
do {
    let text = "| 服务 | 能存吗 |"
    guard case .prose = KairosMarkdownBlock.parse(text).first else {
        check(false, "只有表头时当散文，等分隔行到了再说"); exit(1)
    }
}

print("native markdown tests: all checks passed")

// ── 列表 ─────────────────────────────────────────────────────
//
// 和表格一个原则：认不出就当散文。列表认错的代价比表格小，但「把一句话吃成列表项」
// 一样是丢信息——`-30%` 和 `1.5 倍开头的句子` 都不能当列表。

check(KairosMarkdownBlock.parse("- 一\n- 二\n- 三") == [.list(ordered: false, items: ["一", "二", "三"])],
       "连着的无序项并成一块")
check(KairosMarkdownBlock.parse("* 一\n+ 二") == [.list(ordered: false, items: ["一", "二"])],
       "* 和 + 也是无序标记")
check(KairosMarkdownBlock.parse("1. 一\n2. 二") == [.list(ordered: true, items: ["一", "二"])],
       "有序列表")
check(KairosMarkdownBlock.parse("1) 一\n2) 二") == [.list(ordered: true, items: ["一", "二"])],
       "右括号也算有序标记")
check(KairosMarkdownBlock.parse("3. 一\n7. 二") == [.list(ordered: true, items: ["一", "二"])],
       "原文的序号不沿用，渲染时重排")

check(KairosMarkdownBlock.parse("- 一\n1. 二")
       == [.list(ordered: false, items: ["一"]), .list(ordered: true, items: ["二"])],
       "有序无序不混排，换样式就是新的一块")

check(KairosMarkdownBlock.parse("开场\n- 一\n- 二\n收尾")
       == [.prose("开场"), .list(ordered: false, items: ["一", "二"]), .prose("收尾")],
       "列表前后的散文各自成块，不被吃掉")

check(KairosMarkdownBlock.parse("-30% 的降幅") == [.prose("-30% 的降幅")],
       "标记后面没空白就不是列表——这是话")
check(KairosMarkdownBlock.parse("1.5 倍不止") == [.prose("1.5 倍不止")],
       "小数开头的句子不是有序列表")
check(KairosMarkdownBlock.parse("- ") == [.prose("-")],
       "空的列表项不算列表")
check(KairosMarkdownBlock.parse("2026-09-09 定的") == [.prose("2026-09-09 定的")],
       "日期不是列表")

print("native markdown-list tests: all checks passed")
