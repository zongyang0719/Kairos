import Foundation

/// 消息也是账本上的一行。
///
/// ## 为什么要有这一层
///
/// 在这之前，单子上真的有两种行：待办是账本条目，信是从 `mailbox.json` 现合成的
/// （`KairosMacRow` 那个 enum 有两个 case）。信那种能勾，但**不能拖、不能改档位、
/// 不能进项目、不能和别的行链起来**——档位是显示层硬塞的 P2。
///
/// 人类定的第一条是「所有行必须一样：能勾、能拖、能改档位、能进项目。有一种行不能勾，
/// 肌肉记忆就断了」。要做到这条，只有一个办法：**消息进账本**。于是：
///
///     mailbox.json   降级成原始材料（原话、往来、投递状态），不再是行的来源
///     账本条目       唯一的行；消息就是带 `counterpart` 的条目
///
/// ## 谁建这一行，什么时候
///
/// **机械建行，收到就建，不等消化。** 判断力留给「拟回复」（入场券的第六项），
/// 不放在「要不要建行」上——那条路上 being 睡着的时候 Judy 来信就不出现，而每天回一百个人
/// 的人漏一个人比看到一行没拟稿的裸行严重得多。
///
/// 私信天然满足「欠一个动作」：有人写信给你，就是有人在等你回。所以私信一律建行。
/// 篝火（一个大渠道，只有 @ 你的才算）和炉火（小群，一间一行）需要判断，那是 being 的活，
/// 它写 `counterpart` 建条目即可，不走这里。
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

    /// 把邮箱镜像并进账本。**只在账本的写者那台机器上调用**（Mac）。
    ///
    /// 三条规矩，都是为了「机械」两个字站得住：
    ///
    /// 1. **人手改过的字段不覆盖**（规矩 2）。你把标题改成自己看得懂的说法、把档位提到 P0、
    ///    归了项目——下一封信来了不能把这些抹回去。
    /// 2. **删过的不再建**。tombstone 里有的跳过：他删了就是不要了。
    /// 3. **球权跟着「谁最后说话」走**，但只在有新动静时才动：
    ///    对面又说话了 → 回到 `mine`（人类第 5 条：对面回了，这一条自己回来，不是新建一条）；
    ///    我回过去了 → `closed`（球不在我这）。没有新动静就不动，
    ///    这样人手动勾掉 / 重新打开的决定不会被下一次刷新推翻。
    static func merging(
        _ snapshot: KairosSnapshot,
        threads: [KairosMailThread],
        channel: String = KairosSource.inbox
    ) -> KairosSnapshot {
        var next = snapshot
        let deleted = Set(snapshot.tombstones.map(\.id))

        for thread in threads {
            guard !thread.correspondent.isEmpty, let latest = thread.latest else { continue }
            let id = rowID(channel: channel, address: thread.correspondent)
            guard !deleted.contains(id) else { continue }

            let counterpart = KairosCounterpart(
                name: thread.correspondent,
                id: thread.correspondent,
                channel: channel,
                kind: KairosCounterpart.person
            )
            // 最后一句是谁说的：决定这一行走到哪了。三档，不是两档——
            // **写好还没发出去的那封在「进行中」**（being 下次醒来才去投递），
            // 草稿不另开一个视图，它是这一行上的一个状态。
            let status: String
            if latest.direction == .incoming {
                status = KairosStatus.todo        // 对面在等我回
            } else if latest.status == .pending {
                status = KairosStatus.doing       // 写好了，等 being 发出
            } else {
                status = KairosStatus.closed      // 已经发出去了，不欠这一封了
            }
            let waitingOnMe = latest.direction == .incoming
            let stamp = latest.createdAt

            // 先按稳定 id 找；找不到再按「同一条管子、同一个对方」找一遍——
            // ** being 也会建消息行**（篝火 @、炉火，还有它自己回掉留痕的那些）。
            // 只认 id 的话，同一个人会在单子上出现两行，而那正是人类最烦的那种垃圾。
            let existing = next.items.firstIndex { $0.id == id }
                ?? next.items.firstIndex {
                    $0.counterpart?.channel == channel && $0.counterpart?.id == thread.correspondent
                }
                ?? next.items.firstIndex { sameLetter($0, as: latest.content, channel: channel) }
            guard let index = existing else {
                var item = KairosItem(
                    id: id,
                    title: headline(latest.content),
                    // 原话一字不改：给人对着验证 being 有没有读偏，也保留它可能滤掉的上下文。
                    status: status,
                    excerpt: latest.content,
                    updatedAt: stamp,
                    counterpart: counterpart
                )
                // 信没有自己的档位，落中间那档；人和 being 都能改，改了就归他们（规矩 2）。
                item.tier = "P2"
                next.items.append(item)
                continue
            }

            var item = next.items[index]
            let locked = item.lastWriter
            // 有新动静才动。`stamp` 比这一行上次改动还早 = 这封信我们早就见过了。
            let fresh = KairosClock.parse(stamp) > KairosClock.parse(item.updatedAt)
            item.counterpart = counterpart
            if fresh {
                if locked["title"] != KairosField.human { item.title = headline(latest.content) }
                if locked["excerpt"] != KairosField.human { item.excerpt = latest.content }
                if locked["status"] != KairosField.human || waitingOnMe {
                    // 对面又说话了，人锁不住这一条的状态：他锁的是「我处理完了」，
                    // 而对面刚刚又来了一句。
                    item.status = status
                }
                item.updatedAt = stamp
            } else if locked["title"] != KairosField.human,
                      item.title == legacyHeadline(latest.content),
                      item.title != headline(latest.content) {
                // 迁移：09-13 之前机器按「前 40 个字」写的标题，换成第一句。
                // 只认一字不差是旧规则算出来的那种——人改过的、being 写的，都对不上，都不动。
                item.title = headline(latest.content)
            }
            next.items[index] = item
        }
        return next
    }
}
