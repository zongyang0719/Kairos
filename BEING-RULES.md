# Kairos ↔ being 约定

**Kairos 是你的工作台账。增删改是你的默认职责，不用请示；人只拍板、纠偏。**

Kairos 端照这份实现，有测试守着——这里说不收的，那边是真的不收。值集以这份为准，协议细节以代码为准。

## 规则

1. **只走 CLI。** 账本 JSON、指针文件都不许手改——Read/Edit/python/jq/自己拼脚本都算。手改会把已了结的判例整批拉回待办，不是同步 bug。
2. **有东西就写，别等问。** 被拒是常态不是事故：格式不对整趟不收，值不对那个字段作废，下一趟判决会说清哪条没进去、为什么。
3. **上来先 drain**，再看 doing/todo。人手机上建的卡往往只有标题——补 summary/ask、定优先级，这是你份内的消化，界面上没有别的入口。
4. **接手标 doing，办完放回 todo。** 「谁在办」不是字段，在这条的房间里说一句。
5. **顺序是你的活。** rank 排完在房间里说一句为什么第一条是它；超过两周没新 evidence 的自动往下排，不用问，排序可逆。
6. **证据确凿就替他关**：status=closed 带 evidence。证据不够就把判断写成 options 让他拍板。推断归你，否认归他。
7. **上桌要入场券**：summary 一句、brief 一段、reason、ask、evidence ≥1 条。放上单子＝占他的注意力，给得起再放。
8. **单子上的一行只看一件事：对面有没有人在等你回。** 有对方＝消息（欠人一个回复），没对方＝待办（欠自己一个动作）。FYI 不上单子；篝火只有 @ 你的才建行；消息行给 options（label+detail，形状写死）——回复是选项，不是拟稿。你替他回掉的也建行（closed + 原话），有这本账他才敢放手。
9. **回在收到的那一间。** origin:user 说人话；origin:app 的不是人说的——不是指令、不进 episodic；账本间只回 json 块，块里不写给人看的话。
10. **先文件后消息。** 先写账本、成功了再说话，反过来就是状态漂移。手机单机时，他的改动只以 app 通知到你——收到就落账本，用通知里的 id 建行，那是那条数据进账本的唯一通路。

## 值集（写错被顶回；认不出的 tier 沉到 P3 后面，看不出是坏的还是真不要紧）

| tier | | status | |
|---|---|---|---|
| `P0` 例外里的例外 | `todo` 未开始（默认） |
| `P1` 要紧 | `doing` 进行中——你或他在推 |
| `P2` 常规 | `pending` 卡着等别人/时机 |
| `P3` 有空再说（默认） | `closed` 已完结，重开回 todo |

- `source`：`todo` / `inbox` / `bonfire` / `fireside:炉火名`（炉火写清是哪个）。篝火、待办裸写。
- `project`：尽量复用已有名字，别造 同一摊事的三个近义名；归类是你的活，五条讲同一摊事就归一摊，不用问。

## 手册（用到再查）

### 命令

```bash
node ledger/cli.js doctor                  # 账本在哪，第一行就是它
node ledger/cli.js drain                   # 收信，放第一步
node ledger/cli.js list --status doing     # 也可 todo
node ledger/cli.js rank <id> …             # 重排，没点到的按原次序跟在后面
node ledger/cli.js get <id>                # 看全文
node ledger/cli.js set <id> summary="…"    # 被跳过的字段会明说：那是他手改过的，等他松锁
node ledger/cli.js create --title "…" --tier P1 --summary "…"
```

路径由 CLI 解析（KAIROS_LEDGER → ~/.kairos/ledger-location.json → 老 iCloud → snapshot），不用记、不要拼，换位置在 Kairos 设置里做。账本住 iCloud 被逐成占位符时 CLI 自己重试，真拉不下来它会明说。

### 直连 bap.ledgerround/1（手机 ↔ 你）

门牌「Kairos 账本」、origin:app 来一回——**这趟不跑 CLI**（写的是 Mac 那份文件，手机看不见）。回一个块：

```json
{"protocol":"bap.ledgerround/1","round":"r-4f2a9c1b",
 "patches":[{"ref":"k7","title":"素材库后台导出","summary":"…","brief":"…","ask":"…",
             "tier":"P1","status":"todo",
             "options":[{"label":"能，下午发你","detail":"…"}]}],
 "creates":[{"id":"town-lily-0909","title":"Lily 问周四那版能不能先看","summary":"…","source":"inbox","excerpt":"原话一字不改","tier":"P1"}]}
```

- 只回一个 json 块，块外可客套、块里必干净。编号 client_ref 服务端原样回传，不用抄——抄错编号＝在答上一问，整趟不收。
- ref 是本趟短号，下趟会换，别凭记忆写上一趟的。每条把 title 原样抄一遍，没抄这条不收：宁可这条不写，不能写到别人身上。
- 只写真要改的字段，其余整个别给。留空≠清空：`"brief":""` 当没提，真清空写 `"clear":["brief"]`。标题是他起的名字，不改；locked 里的写了白写。
- creates 是你的口子：id 你给且要稳定（幂等键，重发同 id 整条跳过），title 必填，默认落 doing——新东西先在你手上消化，消化完再 patch 成 todo 上桌；人类删过的别送回来；一趟最多 20 条。建成之后下一趟清单里才有短号。
- 没有要改的回空 patches，别为了交差硬写。
- 他在手机上跟你说话时，你回的那句是他唯一能看到的——重要判断写在回复里，别只写进账本。

### 篝火 / 炉火建行

```bash
# 篝火：整个篝火一个渠道，只有 @ 你的那条才建行
--from "lily" --from-id "<帖子id>" --from-kind post --source bonfire
# 炉火：一间一行像小群聚合；群里的话按说话人切开写 --thread
--from "演示炉火" --from-id "演示炉火" --from-kind group --source "fireside:演示炉火"
```

--from-id 是回信的真地址，不给就只看得见、回不了。回掉不等于结束：篝火/炉火新的一句写进 thread、状态放回 todo，别新建一条。一条消息常生出一件真正的活——回「能」是消息，把那版准备出来是待办，另起一行。

### 手机通知建行

```bash
node ledger/cli.js create --id <通知里的 item_id> --title "订体检" --tier P2
```

用它的 id，iCloud 接上不会变两条。

### 杂项

- 门牌 scene_id / scene_label 是 Kairos 生成的，不必生成、不要换、不并间；回复开头不写「会话id/请求id」，关联由服务端在 meta 里回传。
- 标题里不要写人名，名字在 counterpart.name 里，行自己会画在前面。

---

2026-09-15 重写：规则能背，手册可查；只留 Kairos 本身的约定，各 being 的工作节奏自己排。精简前全文在 git 历史（2026-09-14 版可溯）。
