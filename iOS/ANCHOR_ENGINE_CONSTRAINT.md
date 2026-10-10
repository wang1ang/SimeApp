# 设计稿：锚点作为引擎硬约束（逐字改选重解）

状态：**仅设计，未改代码**。本文固定方案，供实现据此落地。

相关：`iOS/UNIFIED_MIXED_INPUT.md`（中英混输整段喂引擎）、`iOS/REGRESSION.md` 契约
12–24a / 40a、引擎 `require/Sime/src/sime.cc`。

---

## 1. 现状与问题（为什么要改）

现在"逐字改选锚点"**根本不传给引擎**，全在 Swift 层事后处理：

- `Composition.refresh()` 只把原始 `raw` 喂 `decodeComposition(raw)`，不带任何锚点；
  引擎吐出的候选与"没有锚点"时完全相同。
- 锚点效果靠两步 Swift 兜：
  1. `renderedText()` / `applyAnchors()`：把锚点文字**强行覆盖**到首选解码的对应
     字符区间上（位置由 `syllableRange → 字符区间` 映射推出）。
  2. `matchesAnchors()`：把"锚点位置对不上"的其余整句候选从第一行过滤掉
     （且只在字与段 1:1 对齐时才敢过滤）。

**后果（关键结论）：选锚点几乎不影响锚点以外的字。** 首选那条解码是未受约束的原
解码，锚点只是被盖了层字；非锚定部分不会在"锚点已定"的前提下重排。所以用户期望的
"把一个字钉对、句子其余跟着解得更好"**现在不发生**。这不只是治标，而是锚点对全句
几乎没有约束力。

唯一真正到达引擎的约束，是点某格进改选时 `correctionCandidatesForComposition` 把前
缀当 `fixedPrefix` 传入，只影响**那一格的替换候选列表**，不影响第一行整句首选。

目标：**把锚点作为硬约束穿进引擎的词格/束搜索，让 beam 只保留锚点一致的 path，非
锚定部分在"锚点已定"前提下由 LM/GRU 重新竞价。** 契约 21 的"GRU 只在满足全部锚点
约束的合法路径间重排"由此真正成立。

---

## 2. 锚点语义（本次定稿）

锚点一律用**输入字母坐标**表达（key 下标），不依赖任何"一个字 = N 个 key"的假定
（契约 23）：跨度一律来自解码器 spans（`segmentKeys`）。

### 2.1 中文锚点

- **逐字为单位**：每个锚点钉一个字 `X` + 它的输入字母区间 `[a,b)`。选中多字词时拆
  成多个单字锚点，各带各的 `[a,b)`。
- **判定（覆盖 + 包含，不碰字母子区间）**：一条 path 合法 ⟺ 对每个中文锚点，path 里
  有一条边 `e` **完整覆盖 `[a,b)`（`e.start<=a && e.end>=b`）且其输出文本含字 X**。
  **不还原词内每个字占几个字母**（trie 里没这信息、重算还踩契约 23）：词的输出顺序
  跟它的 code 顺序一致，所以"边覆盖了锚点输入区间、输出里有这个字"就够了。
- **端点不强制成为切分/词边界**：整词跨过 `a`/`b` 也行——`中国`（边 `[0,4)`）覆盖了
  `国` 的区间 `[2,4)`、输出含"国"，就命中 国@[2,4)。按**字（Unicode char）**比。
- **剪枝即约束**：删掉"与 `[a,b)` 相交但不是'覆盖+含 X'"的边后，任何跨越 `[a,b)` 的
  path 只能走一条覆盖边 → 锚点必然成立。

例子（均为合法 path，不该被误杀）：

- 输入 `vsgo` 锚"中"：`中(vs)+国(go)` 与整词 `中国`（边 `[0,4)` 覆盖 `[0,2)`、含"中"）都命中。
- 输入 `jiguanqiang` 锚"关"：整词 `机关枪` 也命中（边覆盖那段、输出含关）。
- 输入 `vsgorfqr` 锚"国人"→ 拆成"国""人"两个单字锚点：`中国|人权`、`中国人|权`、
  `中|国人|权` 全合法。若错误地把"国人"当**一个整体区间**锚，会误杀 `中国|人权`
  （国在词`中国`里、人在词`人权`里，分属两词，一个整体"国人"跨不过词边界对齐）——
  所以**必须拆成单字锚点**。

要剪掉的：对齐到某锚点 `[a,b)` 的输出字 ≠ X 的 path（如该位解成"种""全"等）。

附带价值：非锚定自由字会在锚点约束下重排。如 `vsgorfqr` 只锚"国人"，自由尾字
`qr` 在"权/全"间竞价；引擎会倾向能把"权"撑起来的分词（`中国|人权`，权在词
`人权`内）而非孤立单字（易被高频"全"压过）。

### 2.2 英文锚点（临时方案）

- 把用户点中的那段英文**当一个整体**（不拆字）：锚点 = 输入字母区间 `[a,b)` → 英文
  串 `S`。
- **端点 `a`、`b` 是硬 path 边界**：禁止跨 `a`/`b` 的边（与中文相反）。
- path 必须在 `[a,b)` 上走"产出 S"的边。
- **匹配按文字串**（英文字面是 `NotToken`，无 token id）。
- 标注"临时"：以后再做英文内部更细的对齐/扩展。

### 2.3 可达性保证（锚点必须永远可生效）

锚点是用户显式选择，**必须永远可达**（旧 Swift overlay 靠"硬盖"永远显示得出；换引
擎约束后要用"造边"顶替这个保证）：

- **英文**：网里没有 `(a,b,S)` 边就**造一条**字面边（`NotToken`，text=S，跨
  `[a,b)`），并禁跨界。
- **中文**：**确保 `[a,b)` 上存在一条产出 X 的边**，网里没有就造一条单字边 X；
  但**不禁跨界**。于是：
  - "单字读法"这条 path 一定存在 → 引擎永远走得到锚点选的字；
  - 词内对齐命中 X 的整词 path 照常保留；
  - beam/GRU 在这些合法 path 里挑最好的。

因此"引擎完全走不到锚点选的东西"不会发生：单锚点必有解；多锚点即便互相冲突，各自
单字/整段边都在，最坏也能拼出"各锚点字 + 自由部分"的 path，不会空结果。

---

## 3. 实现方案

### 3.1 引擎 `require/Sime`（中文部分已实现）

`ApplyAnchors(net, input, anchors)`，在 `InitNet/InitNetSp` 建网之后、`ComputeEdge­
Penalties`/`PruneNode`/`Process` 之前调用。`struct Anchor { size_t a, b; bool
english; TokenID token; std::string text; }`。

- **中文锚点**（已实现）：对每个锚点 `[a,b)→X`（`want = TokenAt(token)[0]`），扫全网
  边：与 `[a,b)` 不相交的留；相交的只有"完整覆盖 `[a,b)` 且 `ToText(e)` 含 `want`"才留，
  其余删。若无任何覆盖边幸存→注入一条单字边 `(a,b,token)` 保证可达。——不算字母子
  区间（`EdgeCharSpans` 已废弃）：词输出顺序跟 code 一致，"覆盖+含字"即足够，且
  剪掉非覆盖边后，每条跨 `[a,b)` 的 path 必走覆盖边。
  - **建网时预过滤（性能）**：`InitNetSp` 收 `anchors`，在中文边 loop 里按 step-1 span
    几何先判——部分相交的 span 直接跳过（连 `GetEntry` 都不做），覆盖的 span 进
    `GetEntry` 后逐叶只判"含不含被覆盖锚点的字"，避免把同音字 fan-out 白建白删。
    `anchors` 为空时走原路径（普通解码不受影响）。`ApplyAnchors` 仍在其后跑，作为
    全部边类型的权威 + 可达性注入（此时中文边已被预过滤，复查为空转）。
- **英文锚点**（未实现 / phase 2）：删所有跨越 `a`/`b` 的边；`[a,b)` 内只留"恰好
  `(a,b)` 且产出 == S"的边，没有则造一条 `NotToken` 字面边。当前 `ApplyAnchors`
  遇到 `english` 锚点直接跳过。

解码入口 `DecodeSentenceWithAnchors(input, context, anchors, extra, expansion)`（不动
老 `DecodeSentence`，纯加法）：`InitNet*→ApplyAnchors→ComputeEdgePenalties→PruneNode
→Process→CollectCandidates`。注入的单字边 `pieces=nullptr`，`ComputeEdgePenalties`
对它 penalty=0（跳过 nullptr pieces），得到 anchor 字的正常 LM 分。

```cpp
std::vector<DecodeResult> DecodeSentenceWithAnchors(
    std::string_view input,
    const std::vector<TokenID>& context,
    const std::vector<Anchor>& anchors,
    std::size_t extra = 0, bool expansion = true) const;
```

> 注意：注入的锚点边在 `ApplyAnchors`（在 `PruneNode` 之前）里加；锚点列已被剪到只剩
> 覆盖边，所以注入边不会被 `PruneNode`（按分截 NodeSize）误删。

### 3.2 C ABI `iOS/Engine/sime_api.{h,cc}`

加 `sime_decode_sentence_with_anchors(handle, input, ctx*, ctx_n, SimeAnchor* anchors,
int anchor_n, extra, expansion)`；`SimeAnchor { int a, b; bool english; uint32_t
token; const char* text; }`。保持 noexcept 边界。

### 3.3 Swift

- `NativePinyinDecoder`：新增透传方法，组装 `SimeAnchor[]`。
- `Composition`：
  - `refresh()`（或改选后的重解路径）把 `anchorSegments` 转成引擎锚点传入：中文逐字
    `[a,b)`+token+text、英文整段 `[a,b)`+text。`[a,b)` 用锚点的 `sourceKeyRange`。
  - **去掉** `matchesAnchors` 过滤与 `renderedText`/`applyAnchors` 覆盖（改由引擎保
    证候选本身即锚点一致）；`select`/改选逻辑随之简化。
  - 第 7 节列出需要重验的交互。

---

## 4. 契约 / 文档联动

实现时同步更新 `iOS/REGRESSION.md`：

- 12–15、20–24a、40a 中"Swift 过滤/覆盖 (`matchesAnchors`/`renderedText`)"的描述改为
  "锚点作为引擎硬约束，候选本身即锚点一致"。
- 新增/改写：锚点语义（第 2 节）、可达性保证（2.3）、中英两类差异。
- 删除本设计稿与实现分叉：落地后把本文要点并入 `REGRESSION.md` 或留作历史。

---

## 5. 测试计划

- **引擎 probe**（类似现有 `/tmp/sptest`）：
  - 中文：`vsgo` 锚"中" → `中国` 与 `中(vs)+国` 都在；锚"种"位置的 path 被剪。
    `vsgorfqr` 锚"国""人" → `中国|人权` 等三种分词都在，`权` 不被"全"顶掉的分词胜出。
  - 英文：`Biexc` 锚整段"Bi"[0,2) → 只出以字面 `Bi` 开头、`[0,2)` 为硬边界的 path；
    `[2,)` 自由重解。
  - 可达性：锚一个网里本不产出的字 → 造边后仍可达、非空。
- **引擎单测**：`require/Sime/tests/` 加带 anchor 的用例。
- **iOS 测试**：`iOS/Tests/ShuangpinEndToEndTests` / `AnchorEndToEndTests` 覆盖"钉一字
  使其余重排"的端到端。
- **真机回归**：多锚点、改选、提交、marked text、内存（契约相应章节）。

---

## 6. 分步执行

1. 引擎：实现 `ApplyAnchors`（中/英两路）+ `DecodeSentenceWithAnchors`，probe 验证中英
   两类 + 可达性。**先只做引擎、不接 Swift**，确认引擎层正确。
2. C ABI + `NativePinyinDecoder` 透传。
3. `Composition.refresh()` 传锚点、去掉 Swift overlay/filter，简化 `select`/改选。
4. 补测试、更新 `REGRESSION.md`、真机回归。

---

## 7. 实现时要重验的交互（开关开启 = 引擎重解模式）

- 逐字改选气泡 / 第一行内联、自动前进到下一字。
- 多锚点共存、追加输入 / 退格 / 切输入框 / 锁屏恢复后锚点仍合法（契约 13–15、32）。
- 提交路径（第一行回车确认符、回车键"确定"、空格）产出的中文与锚点一致（契约 40、40a）。
- 英文锚点跨段提交（本次已修的 `commitCandidateAsPrefix` 路径）与新引擎约束不打架。

---

## 8. 两种模式共存（开关切换，不拆 overlay）

**不拆除强行覆盖**。新引擎约束和老 overlay 两种模式都保留，用一个 App 开关切换：

- 开关：**“手动更正后整句重新解码”，默认开**。App Group 共享（同 `predictionEnabled`
  / `scheme` 的做法），键盘 `viewWillAppear` 刷到 `Composition`。
- **开（默认）**：锚点走引擎——`refresh()` 调 `DecodeSentenceWithAnchors` 把锚点当硬约束
  传进去，候选本身即锚点一致；此模式下**不走** `renderedText`/`matchesAnchors` 覆盖过滤（
  锚点位置的文字已由引擎保证）。
- **关**：完全走现在的老路——普通 `decodeComposition`（不带锚点）+ `renderedText` 强行
  覆盖 + `matchesAnchors` 过滤。

好处：灰度安全、随时回退；不用一次性证明所有路径都不再依赖 overlay。代价：Swift 侧
两套路径长期并存。契约文档要说明两模式均存在、开关默认开。

> 实现点：`InputSettings` 加一个布尔键（如 `reDecodeOnCorrection`，默认 true）；App
> `ContentView` 加一个 Toggle；`KeyboardViewController.viewWillAppear` 读入并刷到
> `Composition`；`Composition.refresh()` / 改选重解路径按此分支。

## 9. 未定 / 以后扩展

语义层已定稿（中文逐字 / 英文整段 / 可达性造边）。以下为**实现时才拍板的不确定点**，
先记录，遇到具体问题具体分析：

1. **（已解决）中文约束怎么算**。最终采用**建网后按"覆盖+包含"剪边**（见 3.1），
   不算字母子区间、不改 `Process`：剪掉非覆盖边后 beam 自然只剩合法 path，GRU 也只
   见合法 path。原来担心的 piece→字母对齐、边界落在区间内、`align` 失败回退等难点
   都因为改用"覆盖+包含"而**不再存在**。

2. **造出来的锚点边怎么公平打分 / 不被 prune 误删**。注入的单字边/字面边要补
   `pieces`/`penalty`，并豁免 `PruneNode` 和两轨 tier 过滤，否则可能被剪掉或 LM 分不合理。

3. **Swift `decodeComposition` 包装层的额外候选**（`NativePinyinDecoder.decode` 里并入的
   `DecodeStr` 整词候选 + 首/尾单字候选）现在**不受锚点约束**——有锚点时这些要一起
   按锚点裁剪或跳过。

4. **英文锚点的 S 是否恒等于 `raw[a,b)`**。双拼英文是字面透传（text==原始字节），
   应当成立；要确认没有"显示文本 ≠ 原始子串"的词典英文情形。

5. **Composition 现有锚点模型是按 `syllableRange`（段序号）组织的**，很多逻辑（重叠判
   定、`uncommit`、改选前进）依赖它。改成"按 key 区间喂引擎 + 去 overlay"后，要保证
   `sourceKeyRange` 在追加/退格/`invalidateAnchorsForSourceEdit`/锁屏恢复后仍准确；
   段序号那套逻辑哪些能删、哪些要留要过一遍。

6. **灰度策略**：第一版要不要**暂时保留** `matchesAnchors`/`renderedText` 作兜底、引擎
   约束验证稳了再按第 8 节拆除；还是一步到位。影响回归风险。

### 语义扩展

- 英文锚点内部的更细对齐（当前临时整段 + 硬边界）。
- 中文锚点约束放在 `Process` 状态里 vs `CollectCandidates` 过滤的最终取舍（倾向前者，
  让 GRU 只见合法 path）。
- `ApplyAnchors` 与 `PruneNode`/tier 过滤顺序对锚点边的豁免处理细节。
