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
- **判定（按字，piece 级对齐）**：一条 path 合法 ⟺ 对每个中文锚点，**词内 piece 对
  齐到输入 `[a,b)` 的那个输出字 == X**。
- **端点不强制成为切分/词边界**：整词跨过 `a`/`b` 也行，只要词内对齐到 `[a,b)` 的字
  是 X。按**字（Unicode char）**比，不是按 token——因为锚点字可能被包在一个整词
  token 里（如 `中国`、`机关枪`），只能看词内对齐出的那个字。

例子（均为合法 path，不该被误杀）：

- 输入 `vsgo` 锚"中"：`中(vs)+国(go)` 与整词 `中国`（letter 2 处无边界）都命中。
- 输入 `jiguanqiang` 锚"关"：整词 `机关枪` 也命中（词内对齐到那段的字是关）。
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

### 3.1 引擎 `require/Sime`

新增 `ApplyAnchors(net, anchors)`，在 `InitNet/InitNetSp` 建网之后、`Process` 之前调
用。`anchors` 每条：`{ size_t a, size_t b, bool is_english, TokenID token /*中文*/,
std::string text /*英文/校验*/ }`。

- **英文锚点**（`is_english`）：
  1. 删除所有跨越 `a` 或 `b` 的边（`s<a<e` 或 `s<b<e`）。
  2. `[a,b)` 内只保留"恰好 `(a,b)` 且产出 == S"的边；没有则造一条 `NotToken` 字面边
     `(a,b)`（text 即 raw 的 `[a,b)` 子串）。
- **中文锚点**：**不剪边界**。作为**输出一致性约束带进 beam/状态**：一条 path 到达
  覆盖 `[a,b)` 的位置时，按词内 piece 对齐求出对齐到 `[a,b)` 的那个字，≠ X 的状态
  剪掉。并**确保存在**一条在 `[a,b)` 产出 X 的边（没有则造单字边），保证可达。
  - 实现细节待定：优先在 `Process` 的状态扩展里判定（这样 GRU 只见合法 path）；
    次选在 `CollectCandidates` 收集时按 piece 对齐过滤（实现简单但 GRU 可能先在非法
    path 上排过）。倾向前者。

新增解码入口（不动老 `DecodeSentence`，纯加法）：

```cpp
std::vector<DecodeResult> DecodeSentenceWithAnchors(
    std::string_view input,
    const std::vector<TokenID>& context,
    const std::vector<Anchor>& anchors,
    std::size_t extra = 0, bool expansion = true) const;
```

流程：`InitNet/InitNetSp` → `ApplyAnchors` → `ComputeEdgePenalties` → `PruneNode`
→ `Process` → `CollectCandidates`。

> 注意：`ApplyAnchors` 与 `PruneNode`/两轨 tier 过滤的先后顺序要保证造出来的锚点边
> 不被 prune 误删（锚点边应豁免或最后加）。

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

## 7. 实现时要重验的交互（Swift 去掉 overlay 后）

- 逐字改选气泡 / 第一行内联、自动前进到下一字。
- 多锚点共存、追加输入 / 退格 / 切输入框 / 锁屏恢复后锚点仍合法（契约 13–15、32）。
- 提交路径（第一行回车确认符、回车键"确定"、空格）产出的中文与锚点一致（契约 40、40a）。
- 英文锚点跨段提交（本次已修的 `commitCandidateAsPrefix` 路径）与新引擎约束不打架。

---

## 8. 清理目标：拆除强行覆盖

引擎约束就位、候选本身即锚点一致后，**尝试彻底拆除 Swift 的强行覆盖**
（`renderedText`/`applyAnchors` 对锚点位置的 overlay，以及 `matchesAnchors` 过滤）。
这是本次改动的收尾目标，标注"尝试"：拆之前要确认没有路径再依赖 overlay——

- 首选预览、第一行确认符 / 回车"确定" / 空格的提交结果，应直接等于引擎返回的锚点
  一致候选，无需 Swift 侧再盖字；
- 英文整段锚点经引擎造边后产出的文本，确认与旧 overlay 一致；
- `commitBestOrRaw` / `commitPreeditLiterally` / `sentencePreview` 等不再调用
  `renderedText` 覆盖。

若某条路径暂时仍需 overlay 兜底，记录原因，不要默默保留。

## 9. 未定 / 以后扩展

语义层已定稿（中文逐字 / 英文整段 / 可达性造边）。以下为**实现时才拍板的不确定点**，
先记录，遇到具体问题具体分析：

1. **中文约束放哪、怎么算（最大分叉）**。要让 GRU 只见合法 path，就得在
   `Process` 状态扩展里判"对齐到 `[a,b)` 的字 == X"；次选在 `CollectCandidates` 过
   滤（实现简单但 GRU 可能先在非法 path 上排过）。实现前建议先做最小 probe 比一比再定。
   难点：
   - beam 过程中要对跨/覆盖 `[a,b)` 的边现算 piece→字母对齐（`ExtractSegments` 现在是
     事后算的，搬进搜索有性能 / 复用问题）；
   - 边界落在 `[a,b)` **内部**时的规则：若某 path 在 `[a,b)` 中间断成两条边、没有
     单个字恰好对齐 `[a,b)` → 判不满足、剪掉（倾向这样，但要写死）；
   - 有些词 `align` 会失败回退，对齐求不出时怎么判（保守保留还是剪）。

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
