# iOS 未自动覆盖的行为契约

本文只记录**现有自动测试尚未覆盖**、仍需人工审查或真机验证的 iOS 行为。已经由自动测试覆盖的行为以测试代码为唯一来源，不在这里重复描述。

修改前必须同时检查：

- `iOS/Tests/`
- `require/Sime/tests/`
- 本文

若某条人工契约新增了稳定自动测试，应在同一变更中从本文删除该条，避免双重来源。

## 工程、隐私与资源

1. `iOS/project.yml` 是唯一 Xcode 工程源，不提交生成的 `iOS/Sime.xcodeproj/`。
2. 键盘完全离线运行，不申请“完全访问”，不得上传或记录用户输入正文。
3. 系统只安装一个“乐言输入法”扩展；宿主 App 名称为“乐言输入法”。
4. 输入方案经 App 页面与键盘两处选择；无完全访问时，键盘端切换仍须在重新部署后生效，App 与键盘先后切换的读写规则由 `Tests/InputSettingsTests.swift` 覆盖。App 内通过 Picker 选择方案，系统键盘使用单一扩展和固定菜单名称。
5. 模型与 ncnn runtime 必须位于 Keyboard Extension 自身资源/链接范围内。
6. ncnn XCFramework 是本地生成物，不提交；新环境用 `iOS/scripts/build-ncnn-xcframework.sh` 构建。

## App Store 上架配置

61. 宿主 App 提供 `Sime/Assets.xcassets` 的 `AppIcon`（含 1024×1024），`project.yml` 通过 `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` 引用；键盘扩展不需要图标。
62. 宿主与扩展的 Info.plist 均声明 `ITSAppUsesNonExemptEncryption=false`；如未来引入非豁免加密须同步更新并补交合规文档。
63. 发布签名使用 `DEVELOPMENT_TEAM=8K3SQFBAJG`，`CODE_SIGN_STYLE=Automatic`。隐私政策 URL、隐私标签、截图等仅在 App Store Connect 维护，不入库。

## 真实模型与候选召回

7. 正式键盘必须使用真实 Sime 离线模型；仅模型缺失的开发环境允许 fallback。
8. 完整单字召回不能被整句 beam、Top-20 或 UI 首屏截断；低频同音字应可滚动到达。
9. 候选不能通过针对具体文字的白名单、黑名单或强塞首选来修复。
10. 模型更新导致候选顺序变化时必须人工审查，不能只机械更新快照。
11. iOS 与 macOS/Linux 的候选差异应来自明确的平台策略，不能来自重复拼接或隐式常数。

## 第一行改选与多锚点（当前最高优先级）

11a. 组合态只有 `raw` + 稀疏 `anchorSegments`，**无组合内前缀**。选候选 = 对其按键区间下锚点、保留 `raw`、整句重解、仍可编辑。`prefix`/`committed` 只指已上屏文本或宿主上下文。全拼与双拼走同一路径（`raw` 与引擎输入下标 1:1）；仅关闭「更正后整句重解」开关时回退到旧的前缀提交。
11b. 上屏（进宿主文档、清空组合）当且仅当选择覆盖到 `raw` 末位；否则只落锚点。
12. 逐字改选只显示从点选位置开始的可替换内容（气泡或第一行内联），不能把固定前缀显示进候选。
13. 点选位置之前的当前文字参与约束和排序，但只有用户明确选择过的范围成为永久锚点。
14. 新选择与旧锚点重叠时，只替换被覆盖范围，不能清空其他锚点。
15. 追加输入、退格、移动 marked-text 光标、切换宿主字段和锁屏恢复后，仍应保持合法锚点。
20. 第二行候选栏已移除，候选改由第一行承载。组合态第一行 = 首选逐字（每字可点）+ 回车确认符 + 其余整句候选（受锚点过滤，见 24a）；非组合态第一行显示联想候选。逐字改选交互：
    - 点第一行某字**弹出气泡**，气泡在该字下方以换行网格列出其替换候选（`UILabel` + 统一点击手势 + 竖向 `UIScrollView`）。候选态展示替换候选；再次点同一字进入拼音编辑态并显示原始按键；拼音编辑中**第三次点同一字退出编辑**（走下面的统一退出路径，不回到气泡）。
    - 气泡开着时**再点同一字**进入**拼音编辑**：气泡收起，该字标签切为用户实际按键（全拼保留原输入及分隔符，双拼显示原始双拼码），光标移到该音节末尾并同步到宿主 marked 光标，可退格/重打改拼音（与该音节重叠的锚点作废）。**退出活动状态（关气泡 / 退拼音编辑 / 取消高亮）走同一条退出路径**（关气泡+遮罩、光标回末尾、返回整句预览）；各入口只决定触发条件：拼音编辑中再点正在编辑的那个字；点候选区（第一行）非按钮非候选的空白处——只要有活动状态即退出（拼音编辑**任意段，含最后一段**）；空格/回车——拼音编辑且光标不在末尾时退出，光标在末尾时提交当前组合（见 40c）。
    - 气泡/内联里选一个候选后：若候选覆盖到组合最后一个音节，立即提交整句并结束组合；否则应用改选、气泡消失、**自动跳到下一字并保持高亮**，把下一字的替换候选**内联排在第一行句子后面**（不再弹气泡）；后续逐字改选一路内联。
    - 声调过滤：**仅气泡展开（候选态）时**在回车符后显示五个声调（`ˉ ˊ ˇ ˋ ˙`，一~四声+轻声），点一个只保留**首字声调**匹配的候选（声调由 Apple `CFStringTransform` 求得，多音字取默认读音、可能误筛）；内联/拼音编辑态不显示。切字/前进/退出清除过滤。
    - 点气泡以外的**键盘区域**消失并取消高亮（遮罩 overlay 只覆盖第一行下方，所以气泡开着时第一行本身仍可横向滚动看全长句、还可直接点字/候选，不能因气泡而锁死第一行滚动）；气泡开着时，点第一行非按钮、非候选的空白处应关闭气泡；点回车确认符上屏，点别的字则切换气泡，横向滚动仍正常。
    - 输入中（未改选）第一行自动横滚使回车符保持可见；进入改选后第一行不回跳。
20a. 逐字改选后若 Composition 仍在组合态，候选点选必须立即将更新后的预编辑文本和光标同步到宿主 marked text，不能只重绘候选栏、等待下一次按键才刷新。真机用 `woloveni` 点“洛”选 `love`，确认下划线更新为 `wo love ni`。
21. GRU 只能在满足全部锚点约束的合法路径之间重排。
22. 字选择和词选择必须走相同的 segment 状态转移，不得出现 UI 特判分支。
23. 锚点应携带原始按键范围、音节范围、显示文字和 token；人工审查不得出现以汉字长度反推拼音边界的逻辑。

## 候选栏触摸与布局

24. 第一行为整句逐字按钮 + 回车确认符 + 其余整句候选；第二行候选栏已删除（连同其 tap handler / 布局一并移除，不再每轮重建隐藏候选）。
24a. 已确认锚点视为 ground truth：第一行的整句候选中，凡在锚点位置与锚点文本不符的候选不显示（`Composition.matchesAnchors`；字与音节对不齐、无法映射的候选保守保留）。
25. 气泡候选与第一行内联候选都用 UILabel + 统一点击手势 + 原生 UIScrollView；不要恢复会抢滚动手势的候选 UIButton。**iOS 26 SDK（Xcode 27）下 `UIScrollView` 新增的 scroll edge effect 会在键盘透明背景上给矮候选条铺上一层玻璃材质，候选文字变成很重的毛玻璃、不可读**：`sentenceScrollView` 与气泡内部 `scroll` 均通过 `disableScrollEdgeEffects`（`#available(iOS 26.0)` 下隐藏四边 edge effect）关掉。真机已在 Xcode 27 构建上验证（bisect 确认此为唯一必要修复；`.system`/`.custom` 按钮类型与此无关）。按键用 `KeyButton` 且非滚动视图，故不受影响。
26. 点击候选和横向滚动互不冲突，首帧即可滚动；候选栏的横向拖动始终由原生 `UIScrollView` 处理。
26a. 在第一行首选上明显向上拖动应直接上屏首选：组合态提交首选整句（含锚点），非组合态提交第一条联想；只有首选区域的竖直上拖触发，不能影响点击、候选栏横向滚动或其他候选选择。组合态触摸响应区域包含整句及末尾回车符，但拖动高亮只覆盖首选文字、不覆盖回车符号；识别出上拖后，在拖动过程中高亮首选，松手上屏，取消则清除高亮。当前无 UI 自动化覆盖，需真机回归。
27. 候选文本宽度按实际显示文本计算。
27a. 相邻英文词在首选、整句候选、气泡里都以空格分开显示，上屏同样带空格（逻辑由 E2E 测试覆盖）。首选行里分属两个按钮的英文（如在 `bigass` 里选了 `big` 后的 `big` / `ass`）之间要留出一个空格宽度，需真机看。
28. 当前真机布局基线：顶部约束 `-1pt`、底部贴边 `0pt`、第一行 `28pt`、候选文字上移 `1pt`、逐字按钮最小 `24pt`、逐字间距 `3pt`、回车确认符后留白约 `14pt`、候选栏回车符 `11pt`、内联/整句候选间距 `6pt`；气泡候选格高 `34pt`、格间距 `6pt`。

## Marked text 与宿主光标

> 状态：**未实现 / 已移除**。“点击宿主里的 marked 拼音定位光标 / 宿主 unmark 后恢复 marked”这套机制（`syncCompositionCursor` + `textDidChange` 里的恢复逻辑）在多个宿主上从未可靠工作：点那段下划线拼音会整段消失、再点会把键盘弄崩（伴 JetsamEvent/SystemMemoryReset）。相关代码已删除——`textDidChange` 仅保留回车键外观等刷新（宿主正文改在组合开始时读取，见 44），不再按宿主 context 重定位或在 unmark 后恢复/取消。29–34 保留为“目标但未实现”，将来重做需先解决崩溃/内存问题。

29. （未实现）点击宿主中的 marked 拼音应定位组合光标，不能让整段拼音消失。
30. 宿主只暴露光标前或光标后一侧 context 时，也应尽可能完成定位。
31. 中间插入、前后删除后，marked 光标、原始按键和第一行候选必须一致。
32. 未完成组合仅保存在内存（不再写入 UserDefaults 持久化）：锁屏、或在进程存活期间切 App 后回到**同一输入框**应仍恢复（`viewWillAppear`/`render` 重绘内存组合）。但扩展进程被系统回收（真正重建）后组合**不再恢复**——故意以此换取“绝不把旧拼音残留到磁盘/新输入框”的确定性（与旧契约“扩展重建后恢复”的取舍）。
33. （未实现）宿主临时 unmark 组合时应恢复 marked text，并避免 `textDidChange` 重入循环。
33a. （未实现）随 `syncCompositionCursor` 一并移除了“宿主 context 找不到 marked 拼音时取消本地 composition”的防串框逻辑。将来若重做定位功能，必须重新处理跨输入框不串框的问题。
34. （未实现）上述定位/恢复行为一旦重做，必须在备忘录及至少一个第三方文本框中真机验证。

## 空格、删除与回车 UI

35. 空闲时长按空格进入宿主光标移动模式。键盘未申请完全访问，第三方键盘无法触发触感反馈（真机已验证 `UIImpactFeedbackGenerator` 无效），不要再加按键或空格触感。
66. 按键按下即播放系统按键音（`playInputClick`），跟随系统“键盘反馈 → 声音”与静音键，不需要完全访问（真机已验证）。依赖 `UIInputView` 与 `KeyButton` 声明 `enableInputClicksWhenVisible`。
36. 光标按手指位移细粒度连续移动；快速拖动不能漏步。
37. 组合状态下长按空格不能误移动宿主光标。
38. 删除键长按连续删除（timer 停止、无可删内容自停、滑到其他键松开结束 ⌫ 见 `DeleteRepeatTests`）。仅真机覆盖：键盘重建、按下任意其他键时也必须停止，否则之后每打一个字都会被立即删掉（复现：`ctrloss` 改选 loss 上屏后长按删除删光再打字）。已知限制：从其他键滑动到删除键再松手不会触发删除；需正常按下删除键。
39. 回车标题跟随宿主 `returnKeyType`（发送/搜索/完成/前往/加入/继续/路线/紧急呼叫等）；`.google/.yahoo` 归为“搜索”。**但只要当前有组合（marked 拼音），动作键先显示“确定”（确认上屏），上屏/无组合后才恢复宿主语义。**组合状态变化需即时刷新键帽（`refreshReturnKeyAppearance` 同时感知 `returnKeyType` 与是否组合）。
40. 第一行确认按钮（回车确认符）**无论有无锚点，总是提交首选整句中文**（`renderedText` 套用锚点：锚定位置用锚点文本，其余随首选整句解码），但不插入换行。
40c. **逐字拼音编辑态（组合光标不在末尾）下，空格和回车都是“退出编辑”**：取消逐字高亮、光标回到末尾、回到整句预览，**不上屏、不插空格/换行**；判据仅为“光标不在末尾”（`composition.cursor < raw.count`）。纯选字高亮（光标在末尾）不算编辑态，空格/回车照常提交，不做特殊处理。
40b. Shift 只影响字母键大小写：单击后一次性大写，输入后自动回小写，不提供大写锁定。真机仅需检查 Shift 高亮和一次性状态；字母大小写、中英混输候选由解码器决定，断言以 `iOS/Tests` 为准。
40a. 有组合时，回车键帽显示“确定”。无锚点时，回车将原始按键作为字面文本上屏；有锚点时，回车提交整句中文：锚定位置采用锚点文本，其余音节采用顶部候选解码结果。此时回车与第一行确认符的上屏结果一致；第一行确认符始终提交中文。断言由 `iOS/Tests` 覆盖；真机须在备忘录及第三方输入框中验证不同宿主 marked-text context 下的结果。
40d. 纯 ASCII 文本（英文、原样字母）经任一上屏路径（回车、空格、点候选栏、气泡选字）上屏后，宿主下划线必须消失且不得重复上屏；统一由 `commit(_:)` 先清空 marked 再延后插入。真机须在备忘录及知乎等第三方输入框验证（如打 `B` 从气泡选 BBC）。

## 数字页与标点

41. 数字页输入数字后保持数字页；输入半角 `.` `-` `/` `*` `+` `=` 时，仅当光标前一字符为数字才保持数字页，否则（含组合态先上屏拼音的情况）回到字母页；输入其他标点后回到字母页。判定规则由 `Tests/CalculatorTests.swift` 的 `NumberPagePolicy` 用例兑现，页面切换本身需真机回归。
41b. 数字页第三排为 `[#+=, *, +, =, 、, ！, ., ⌫]`。键盘为三页结构：字母页按 `123` 进数字页；数字页按 `#+=` 进符号页；符号页按 `123` 回数字页，按左下角切换键回字母页。符号页插入任意符号后保持在符号页（与系统键盘 #+= 一致）。左下角切换键在非字母页显示当前方案（全拼为“拼音”，任一双拼方案为“双拼”）。微软/搜狗双拼字母页使用 `;` 韵母键，小鹤/自然码和全拼字母页显示 `asdfghjkl` home 行。最下一排在三页统一为 `[mode, ，, 空格, 。, ？, 回车]`（字母页 mode=`123`，非字母页 mode=方案标签）；，。？ 宽度锚定本页顶排按键；回车宽度 = `rowWidth×(2/9) − 28/9`，使其左缘恒落在字母页第三排 m 键（index 7，4pt 间距）的列位，三页一致且不随各页第三排变化。App 内「空格旁标点」开关（`InputSettings.punctuationBesideSpace`，默认开）关闭时，三页最下一排为 `[mode, 空格, 回车]`：间距与回车宽度同上，mode 与回车等宽（右缘落在 z 键列位），空格占满其余；数字页第三排同时还原为 `[#+=, 。, ，, 、, ？, ！, ., ⌫]`；键盘在 `viewWillAppear` 发现开关变化时重建。
41a. 点 `123` 切到数字/符号页不得立即上屏当前组合；组合保持 marked，直到真正插入数字或符号才上屏。若未插入任何字符就点“拼音”切回，组合应原样恢复。
42. 中文/半角标点策略保持一致，成对引号状态跨切页保留。组合态输入标点时，组合文本与标点合并为一次上屏，顺序为组合文本后接标点；在备忘录及至少一个第三方输入框真机验证。
43. 标点提交后退格撤销仍属于待实现行为。
43a. 数字页与符号页的顶部候选区右侧显示「全拼/双拼」切换开关（`UISegmentedControl`，字母页隐藏）。选「全拼」切到 `fullPinyin`；选「双拼」切到**上次使用的双拼方案**（无记录时默认微软双拼）。开关只做全拼↔双拼二选一，不轮换四种双拼。组合中切换方案时，真机须确认宿主正文不上屏、marked text 留在输入框中，候选即时按目标方案更新；左下角「拼音/双拼」同步显示。原始按键重新解码、旧改选锚点清除由 `Tests/CompositionBehaviorTests.swift` 覆盖。

## 宿主正文上下文与联想

44. 宿主正文在四个时机读取：键盘出现（`viewWillAppear`）、非组合态退格之后（真机验证：`deleteBackward` 返回后立即读到的已是删除后的文字，所以退格后同步读取）、非组合态的 `textDidChange`（真机验证：键盘弹出、移动光标、中文上屏后会触发；键盘自己退格、英文上屏不触发），以及每次组合的第一个按键、写入 marked 之前（`textDidChange` 在组合中几乎不触发，所以读到的文本不含 marked 前缀）。非组合态读到后直接发布联想，输入前即可补全。微信、备忘录已真机验证能读到。宿主正文结尾等于本键盘 context 文本时保留已有切分，否则以宿主为准，由 `Tests/CompositionBehaviorTests.swift` 覆盖。
45. 宿主拒绝提供正文时，应回退到本键盘已有 token context。
46. 分词器不能在切换键盘、首次输入或点击第一行时造成明显卡顿或扩展内存峰值。
47. iOS 不建任何分词索引：分词每次扫描词表（`CutByScan`），不常驻额外内存（见 47a）。
47a. **分词器调用点白名单，增删改任何一处都必须先和用户沟通**。iOS 侧只有以下地方调用分词（引擎 `Sime::Tokenize` → `sime_tokenize_text` → `NativePinyinDecoder.tokenize`）：
   - 宿主正文上下文：`Composition.updateHostContext`（由 `KeyboardViewController.refreshHostContext` 在 #44 的四个时机传入光标前最多 128 字；结尾等于已有 context 文本时不分词。只分最后一个空白之后的部分，但英文后面的单个空格不切断，继续向前读（包括末尾的空格），每段分别分词；英文不拆成 word piece，引擎切出的相邻英文片段合并为整词精确匹配，匹配不到或词头被截断即为断开）。
   - 非组合态退格：`Composition.settleContextFragment`，被截短的末尾 token 剩余部分精确匹配不到、且没被选补全（补不出或用户没选）时，仅对**中文**剩余部分分词；英文不分词。
   - 旧 overlay 锚点上屏：`Composition.recordSentenceCommit`，锚点不走引擎路径时对上屏文本重新分词。
   - 引擎内部：`Sime::DecodeCorrection` 对改选的固定前缀 `fixed_prefix` 用 `CutByScan` 求上下文。

   iOS 不得构建引擎 `Cutter`（整词表字节 DAT，真机峰值 +23–41 MB，会触发 Jetsam）；引擎内 `Cutter` 只留给 iOS 不调用的用户句子迁移（`LoadUserSentence`）与 `sime-cut` 工具。宿主上下文、退格、改选三处的内存峰值由 `Tests/MemoryPeakTests.swift` 覆盖（overlay 上屏走同一个 `Tokenize`，未单独测），`CutByScan` 与 `Cutter` 分词一致由引擎 `tests/correction_test.cc` 覆盖。
48. 所有上屏内容都进入 context，丢弃前文只有一条规则：token 断开。解码上屏（含锚点）直接使用解码 tokens；标点、数字、符号和原样上屏的按键追加在已有 context 后，整段精确匹配为一个 token（引擎 `ContextToken`）；空格、换行没有 token：换行和非英文后面的空格清空 context；英文后面的单个空格（手动输入、键盘插入、宿主读到的都一样）不切断，此时联想只出下一个词。context 只有 token、不含空格，默认相邻英文 token 之间有一个空格；光标前是否真有空格由另一个变量记录（本键盘最后上屏的字符：空格、换行、数字、符号或文字；读到宿主正文时以宿主末字符为准）：英文联想（非补全）上屏前补一个空格，前面已有空格则不补，退格删掉的是空格时 context 不变，补在非英文之后的空格同样断开 context；非组合态退格从 context 末尾删一个字符，剩余部分精确匹配为 token 则照常，否则联想改为该片段的单词补全（只显示待插入部分，如「钵钵」→「鸡」、`iPhon` →「e」），补不出或没选补全就继续时，英文清空 context（英文 token 无 word piece，不能拆），中文只对这段剩余部分 `Tokenize`，之前的 token 不动；宿主文本由引擎 `Tokenize` 分词，英文按整词匹配（见 47a）；无法匹配或语言模型打不了分的位置由引擎记为 `NotToken` 分隔，键盘在 App 层直接丢弃它及其之前的 context。断言由 `Tests/CompositionBehaviorTests.swift`、`Tests/PredictionTests.swift` 与引擎 `tests/correction_test.cc` 覆盖。
49. context 上限最终应读取 `sime_context_size`，不能永久硬编码。
50. 宿主正文对候选排序的实际影响需用真实模型和真机文本场景验证。
50a. 联想（`NativePinyinDecoder.predict`）必须过滤纯标点/符号 token：n-gram 里几乎任何字最高频后继都是 `，。、！？`，不过滤会占满联想栏名额、把有用词挤掉，表现为“联想全错”。实现方式为多取候选（约 limit×6，上限 60）后剔除纯标点再取前 N。由 `Tests/PredictionTests.swift` 兑现。
50c. 联想可由 App 内“联想”开关关闭：`InputSettings.predictionEnabled`（App Group `group.com.ismantic.sime`，默认开），键盘在 `viewWillAppear` 刷新到 `Composition.predictionEnabled`。关闭时 `publishPredictions` 不查询、不显示，且立即清空已有联想候选。由 `Tests/CompositionBehaviorTests` 兑现。
50b. 极稀有字（如“狐”）的稀疏 bigram 噪声（“狐→阿尔法”）属引擎/模型层面的已知残留，非 iOS 接线问题；如需治本应在 Sime 引擎侧改进（unigram 插值 / 计数阈值 / GRU 参与联想重排），已验证简单 unigram 插值无改善。

## GRU / ncnn

51. iOS 使用 CPU-only ncnn，并定义 `SIME_ENABLE_NCNN=1`。
52. GRU 的 embedding、pinyin/t9 param/bin 必须全部打包到扩展。`gru.embedding.i8` 以只读 `mmap`（非读入堆内存）加载，以降低常驻；换回读取式加载必须重新记录 footprint。
53. Simulator arm64/x86_64 与真机 arm64 都必须可链接构建。
54. GRU 只重排候选，不负责键盘页选择，也不能突破锚点约束。

## 闪退与内存真机回归

55. 选择“乐言输入法”时不能出现巨大空白按键后闪退。
56. 首次普通解码、打开第一行改选、连续联想均不能触发扩展 Jetsam。
57. 点击第一行不能临时创建大型分词索引。
58. 使用 `iOS/Tests/DeviceMemoryBaseline.md` 的固定 workload 做 Release 真机存活测试。
59. 设备日志出现 `SimeKeyboard` 的 `per-process-limit`、`exceeded mem limit` 或 Jetsam 即失败。
60. 已知设备上限为 77 MB；引擎资源或模型加载变更必须重新记录 footprint。
60a. 收到内存告警（`didReceiveMemoryWarning`）时键盘调 `sime_reset_caches()` 清引擎缓存（纯内存提示，不改解码结果）。注：`free` 后页不一定立即还给系统，此调用是尽力而为，不能依赖它降 footprint。
60b. 引擎 trie 的分隔符缓存（`sep_cache_`）必须稀疏存储（按访问到的节点 `unordered_map`），**不得恢复为按整棵 trie `size_` 预分配的稠密 `vector`**：后者在现版词典上首次解码就会分配 ~14MB 脏内存且不归还系统，是键盘撞 77MB 上限的主因之一。稀疏化不得改变解码结果（由引擎与 iOS 测试兑现）。

## 键盘激活响应

61. 切换到“乐言输入法”时布局不得闪烁、按键不得在数百毫秒内失效。原生引擎（GRU embedding、ncnn 模型、score 表）加载昂贵，**不得在主线程/控制器属性初始化时同步构建**：`KeyboardViewController` 必须先用轻量 `BuiltinPinyinDecoder` 立即呈现可用键盘，再在后台队列加载 `NativePinyinDecoder` 并在就绪后换入、保留在打 raw。
62. 已加载的原生引擎须以 `NativePinyinDecoder.shared` 在扩展进程内跨控制器实例复用，避免每次切换重新加载。换入不得丢失/错位当前 marked 组合（沿用 `restore(raw:committed:)`）。
63. 缝隙点击依赖键盘根视图与 `KeyboardHitTestStackView` 本身保持可 hit-test（`alpha > 0.01`、未隐藏且启用交互）；`backgroundColor` 的透明度不等于视图 `alpha`。真机已验证背景色用 `secondarySystemBackground.withAlphaComponent(0.05)` 时缝隙仍能接住点击。按键必须用 `KeyButton()`，不能用 `UIButton(type:.system)`。普通相邻键按实际行间距平分命中扩展（各行间距均为 4pt，两侧各 2pt；命中逻辑动态读 row.spacing，不写死），行首/行尾外侧保留8pt；全拼 home 行 `a` 左侧和 `l` 右侧扩展至行边缘（18pt）。双拼合法韵母键可独占其方向的整段间隙，相邻非合法键让出该段，不得重叠键面。
65. 屏幕左右边缘的按键（如 `q`/`p`/`a`/`l`）按下须立即高亮并响应，不得被宿主窗口的系统边缘手势闸门延迟到约 1 秒后或抬起时才触发：`viewDidAppear` 中把 `view.window` 上所有手势识别器的 `delaysTouchesBegan` 设为 `false`。需真机验证（模拟器不复现）。

## 双拼解码路径

64. 真机验证微软/搜狗/小鹤/自然码方案切换与 Native decoder 异步换入：raw composition 保持连续，并始终由当前方案对应的 index 解码。

64b. 双拼输入待配对声母后，合法韵母键的触摸范围可扩展到相邻键缝；完整音节和全拼输入时恢复常规命中范围。合法韵母不再用颜色高亮（此前仅为调试）。真机检查常规键色不变、连打顺畅、键缝命中与合法韵母状态一致，并在方案切换及 Native decoder 换入后保持正确。

64c. 微软/搜狗布局将 `;` 作为韵母键，字母页 home 行包含 `;` 且不缩进；小鹤/自然码/全拼使用缩进的 `asdfghjkl` home 行，`;` 作为标点键。方案切换时由 `keyboardNeedsRebuild` 重建键盘。



## 人工验证命令

真实引擎测试、iOS XCTest 的具体断言以测试源码为准。提交前先运行全部自动测试，再执行真机构建：

```bash
cmake -S require/Sime -B /tmp/sime-test \
  -DSIME_BUILD_TOOLS=OFF -DBUILD_TESTING=ON
cmake --build /tmp/sime-test
ctest --test-dir /tmp/sime-test --output-on-failure

cd iOS
xcodegen generate
xcodebuild -project Sime.xcodeproj -scheme Sime \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.4' test
xcodebuild -project Sime.xcodeproj -scheme Sime \
  -sdk iphoneos -configuration Debug build
```

真机重点检查本文的多锚点、marked text、候选触摸、宿主正文和内存章节。
