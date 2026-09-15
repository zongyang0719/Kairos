import SwiftUI

/// 信不再单占一屏。
///
/// 在这之前手机上有一个 Inbox tab：它按**人**列 `mailbox.json` 里的往来，和单子完全并行。
/// 那是和 Mac 分叉的一处——Mac 09-11 就定了「消息也是账本上的一行」，信在那边只是
/// 单子上带 `counterpart` 的条目，点开在房间里看往来。两端于是对同一封信有两套模型：
/// 手机上一个人一个 thread，Mac 上一个人一行待办，能勾能拖能改档位。
///
/// 现在统一到 Mac 那一套：**手机也只有一张单子**。这个文件只剩两样东西——
/// 详情里那一段「和某某的往来」（`MailCorrespondence`）。
/// 写信那张表撤了——取信整个功能没了，只出不进的信箱是骗人的。
/// 原来的 `InboxTabView` / `ThreadRow` / `MailThreadView` 一起撤了。
///
/// 收件箱的主权在 being 手里，Kairos 只是那扇窗：发出去的落款是 being ，不是人类。
/// 信也不是在这里发出去的——写完只落进这台设备的草稿箱，being 下次醒来才真的投递
/// （Kairos 够不着 Town，理由见 KairosMail.swift）。所以「等 being 发出」是常态，不是错误。

/// 详情里的「和某某的往来」。**只读**——这一屏只有一个输入框，是对 being 说的。
///
/// 2026-09-11 人类定的（Mac 的 `KairosRoomView.correspondence` 同一条）：
/// 发给别人也是通过 being 发，没有第二条渠道。Kairos 本来就够不着任何一条对外的管子，
/// 所谓「直接回」不过是把草稿塞进一个 being 迟早要来拿的文件——既然出手的永远是 being ，
/// 那就只有一个框。
struct MailCorrespondence: View {
    @ObservedObject var store: KairosStore
    let item: KairosItem

    var body: some View {
        if let who = item.counterpart, !who.isEmpty {
            let entries = mailEntries(for: who)
            if !entries.isEmpty || !item.thread.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label("和 \(who.name) 的往来", systemImage: symbol(who.channel))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !entries.isEmpty {
                        ForEach(entries) { entry in
                            said(
                                who: entry.direction == .incoming ? who.name : "我",
                                at: entry.createdAt,
                                text: entry.content,
                                mine: entry.direction == .outgoing,
                                pending: entry.status == .pending
                            )
                        }
                    } else {
                        // 炉火像个小群、篝火是一条帖子底下的串：上下文是**多个人说的话**。
                        // 长上下文不按长度切，按「谁说的」切——一段长 excerpt 是死的，
                        // 一串带说话人的话是活的。
                        ForEach(Array(item.thread.enumerated()), id: \.offset) { _, line in
                            said(who: line.who, at: line.at, text: line.text, mine: false, pending: false)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 18))
            }
        }
    }

    private func said(who: String, at: String, text: String, mine: Bool, pending: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(who)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.secondary)
                Text(Self.shortTime(at))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if pending {
                    // 「待发送」是常态：Kairos 够不着 Town，得等 being 下次醒来去投。
                    Label("等\(store.beingNameInline)发出", systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func mailEntries(for who: KairosCounterpart) -> [KairosMailEntry] {
        guard who.channel == KairosSource.inbox else { return [] }
        // 先按真地址找（`KairosMessageRow` 建的行 id 就是对方在邮箱里的键，一定对得上）；
        // 找不到再按名字兜一次——being 手写的那些行有可能把 `id` 写成显示名，
        // 对不上就整段往来不画，那比偶尔认错一个重名的人严重。
        let threads = store.mailThreads
        return (threads.first { $0.correspondent == who.id }
                ?? threads.first { $0.correspondent == who.name })?.entries ?? []
    }

    private func symbol(_ channel: String) -> String {
        switch KairosSource.normalized(channel) {
        case KairosSource.inbox: "envelope"
        case KairosSource.bonfire: "flame"
        case KairosSource.fireside: "fireplace"
        default: "circle"
        }
    }

    static func shortTime(_ stamp: String) -> String {
        guard let date = KairosMailClock.parse(stamp) else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}

