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
3. 系统只安装一个“是语键盘”扩展；宿主 App 名称为“是语输入法”。
4. 输入方案（全拼 / 微软双拼 / 小鹤双拼 / 自然码 / 搜狗双拼）通过 App Group 共享；切换后不得混用旧 Composition 状态。方案由 `Shared/InputScheme.swift` 定义：双拼布局是数据驱动的 `ShuangpinLayout`（每方案给出键→韵母表与零声母约定，`ia/ua`、`iang/uang`、`ong/iong`、`uo/o`、`ui/ü`、`ue/üe`、`uai/ing` 等歧义按共享汉语音系规则解析）。App 内用 Picker 切换（不是开关），系统只保留单一扩展、菜单名不拆分。
5. 模型与 ncnn runtime 必须位于 Keyboard Extension 自身资源/链接范围内。
6. ncnn XCFramework 是本地生成物，不提交；新环境用 `iOS/scripts/build-ncnn-xcframework.sh` 构建。

## App Store 上架配置

61. 宿主 App 必须提供 `Sime/Assets.xcassets` 的 `AppIcon`（含 1024×1024），`project.yml` 通过 `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` 引用；键盘扩展不需要图标。当前 `AppIcon.png` 为占位图，正式上架前须替换为正式设计稿。
62. 宿主与扩展的 Info.plist 均声明 `ITSAppUsesNonExemptEncryption=false`；如未来引入非豁免加密须同步更新并补交合规文档。
63. 发布签名使用 `DEVELOPMENT_TEAM=8K3SQFBAJG`，`CODE_SIGN_STYLE=Automatic`。隐私政策 URL、隐私标签、截图等仅在 App Store Connect 维护，不入库。

## 真实模型与候选召回

7. 正式键盘必须使用真实 Sime 离线模型；仅模型缺失的开发环境允许 fallback。
8. 完整单字召回不能被整句 beam、Top-20 或 UI 首屏截断；低频同音字应可滚动到达。
9. 候选不能通过针对具体文字的白名单、黑名单或强塞首选来修复。
10. 模型更新导致候选顺序变化时必须人工审查，不能只机械更新快照。
11. iOS 与 macOS/Linux 的候选差异应来自明确的平台策略，不能来自重复拼接或隐式常数。

## 第一行改选与多锚点（当前最高优先级）

12. 逐字改选只显示从点选位置开始的可替换内容（气泡或第一行内联），不能把固定前缀显示进候选。
13. 点选位置之前的当前文字参与约束和排序，但只有用户明确选择过的范围成为永久锚点。
14. 新选择与旧锚点重叠时，只替换被覆盖范围，不能清空其他锚点。
15. 追加输入、退格、移动 marked-text 光标、切换宿主字段和锁屏恢复后，仍应保持合法锚点。
20. 第二行候选栏已移除，候选改由第一行承载。组合态第一行 = 首选逐字（每字可点）+ 回车确认符 + 其余整句候选（受锚点过滤，见 24a）；非组合态第一行显示联想候选。逐字改选交互：
    - 点第一行某字**弹出气泡**，气泡在该字下方以换行网格列出其替换候选（`UILabel` + 统一点击手势 + 竖向 `UIScrollView`，不用候选 `UIButton`）。展开气泡这一下只列候选、不显示拼音。
    - 气泡开着时**再点同一字**才把该字标签切换为用户实际按键（全拼保留原输入及分隔符，双拼显示原始双拼码），再点切回汉字。
    - 气泡里选一个候选后：应用改选、气泡消失、**自动跳到下一字并保持高亮**，把下一字的替换候选**内联排在第一行句子后面**（不再弹气泡）；此后逐字改选一路内联。无后续位置时退出改选、回到整句预览。
    - 点气泡外任意处消失并取消高亮；点回车确认符上屏；点别的字则把气泡切到那个字。
21. GRU 只能在满足全部锚点约束的合法路径之间重排。
22. 字选择和词选择必须走相同的 segment 状态转移，不得出现 UI 特判分支。
23. 锚点应携带原始按键范围、音节范围、显示文字和 token；人工审查不得出现以汉字长度反推拼音边界的逻辑。

## 候选栏触摸与布局

24. 第一行为整句逐字按钮 + 回车确认符 + 其余整句候选；第二行候选栏已删除（连同其 tap handler / 布局一并移除，不再每轮重建隐藏候选）。
24a. 已确认锚点视为 ground truth：第一行的整句候选中，凡在锚点位置与锚点文本不符的候选不显示（`Composition.matchesAnchors`；字与音节对不齐、无法映射的候选保守保留）。
25. 气泡候选与第一行内联候选都用 UILabel + 统一点击手势 + 原生 UIScrollView；不要恢复会抢滚动手势的候选 UIButton。
26. 点击候选和拖动互不冲突，首帧即可滚动。
27. 候选文本宽度按实际显示文本计算。
28. 当前真机布局基线：顶部 `-6pt`、第一行 `28pt`、逐字按钮最小 `24pt`、逐字间距 `3pt`、回车确认符后留白约 `14pt`、内联/整句候选间距 `6pt`；气泡候选格高 `34pt`、格间距 `6pt`。

## Marked text 与宿主光标

29. 点击宿主中的 marked 拼音应定位组合光标，不能让整段拼音消失。
30. 宿主只暴露光标前或光标后一侧 context 时，也应尽可能完成定位。
31. 中间插入、前后删除后，marked 光标、原始按键和第一行候选必须一致。
32. 未完成组合仅保存在内存（不再写入 UserDefaults 持久化）：锁屏、或在进程存活期间切 App 后回到**同一输入框**应仍恢复（`viewWillAppear`/`render` 重绘内存组合）。但扩展进程被系统回收（真正重建）后组合**不再恢复**——故意以此换取“绝不把旧拼音残留到磁盘/新输入框”的确定性（与旧契约“扩展重建后恢复”的取舍）。
33. 宿主临时 unmark 组合时应恢复 marked text，并避免 `textDidChange` 重入循环。
33a. `syncCompositionCursor()` 返回三态（`.matched` / `.missing` / `.unavailable`）：宿主暴露了光标前/后 context 但其中**完全找不到**当前 marked 拼音时（`.missing`，典型为用户切到了另一个输入框/App），必须**取消本地 composition**，绝不能把旧拼音无条件 `setMarkedText` 恢复到新输入框——否则既是定位错误，也造成跨输入框内容泄漏。仅在 `.matched`（找到并定位光标）或 `.unavailable`（宿主未暴露任何 context，无法判断）时才保留组合并按契约 33 恢复 marked text。此为真机契约：须在备忘录与第三方输入框之间来回切换验证旧拼音不串框。
34. 上述行为必须在备忘录及至少一个第三方文本框中真机验证。

## 空格、删除与回车 UI

35. 空闲时长按空格进入宿主光标移动模式，并给一次轻触感反馈。
36. 光标按手指位移细粒度连续移动；快速拖动不能漏步。
37. 组合状态下长按空格不能误移动宿主光标。
38. 删除键长按连续删除，松开或取消后 timer 必须停止。
39. 回车标题跟随宿主 `returnKeyType`，包括发送、搜索、完成、前往等语义。
40. 第一行确认按钮提交中文但不插入换行。
40b. Shift 仅影响字母大小写（单击一次性大写首字母、输入后自动取消，无大写锁定）。大写字母不直接上屏，而是进入组合——作为字面英文候选（保留大小写；双拼下为原始按键），与中文候选同走 segment/选字路径，按空格/回车/点选才上屏。字面英文候选的存在与排序（首字母大写→排首；全小写→追加在中文之后）由 `iOS/Tests` 覆盖；此处只留真机验证 Shift 键交互（一次性高亮与键帽大写、输入后回小写）。
40a. 回车是字面英文逃生通道：无任何选择时按原始按键上屏；但只要用户从第二行做过改选（组合中存在锚点），回车即视为提交中文，未锚定的音节必须随顶部候选整句解码，不能吐出原始双拼/全拼按键。断言由 `iOS/Tests` 覆盖；此处只保留真机契约——须在备忘录及第三方输入框中验证不同宿主 marked-text context 下结果一致。

## 数字页与标点

41. 数字页输入数字后保持数字页；输入标点后回到字母页。
41b. 键盘为三页结构：字母页按 `123` 进数字页；数字页按 `#+=` 进符号页；符号页按 `123` 回数字页，按左下角切换键回字母页。符号页插入任意符号后保持在符号页（与系统键盘 #+= 一致）。左下角切换键在非字母页显示当前方案（全拼为“拼音”，任一双拼方案为“双拼”）。
41a. 点 `123` 切到数字/符号页不得立即上屏当前组合；组合保持 marked，直到真正插入数字或符号才上屏。若未插入任何字符就点“拼音”切回，组合应原样恢复。
42. 中文/半角标点策略需保持一致，成对引号状态不得因切页丢失。
43. 标点提交后退格撤销仍属于待实现行为。

## 宿主正文上下文与联想

44. `documentContextBeforeInput` 包含当前 marked 前缀时，必须先剔除 marked 部分再分词。
45. 宿主拒绝提供正文时，应回退到本键盘已有 token context。
46. 分词器不能在切换键盘、首次输入或点击第一行时造成明显卡顿或扩展内存峰值。
47. 分词器索引应延迟创建并有明确缓存/生命周期上限。
48. 句末标点清空联想 context 仍待实现。
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

55. 选择“是语键盘”时不能出现巨大空白按键后闪退。
56. 首次普通解码、打开第一行改选、连续联想均不能触发扩展 Jetsam。
57. 点击第一行不能临时创建大型分词索引。
58. 使用 `iOS/Tests/DeviceMemoryBaseline.md` 的固定 workload 做 Release 真机存活测试。
59. 设备日志出现 `SimeKeyboard` 的 `per-process-limit`、`exceeded mem limit` 或 Jetsam 即失败。
60. 已知设备上限为 77 MB；引擎资源或模型加载变更必须重新记录 footprint。
60a. 收到内存告警（`didReceiveMemoryWarning`）时键盘调 `sime_reset_caches()` 清引擎缓存（纯内存提示，不改解码结果）。注：`free` 后页不一定立即还给系统，此调用是尽力而为，不能依赖它降 footprint。
60b. 引擎 trie 的分隔符缓存（`sep_cache_`）必须稀疏存储（按访问到的节点 `unordered_map`），**不得恢复为按整棵 trie `size_` 预分配的稠密 `vector`**：后者在现版词典上首次解码就会分配 ~14MB 脏内存且不归还系统，是键盘撞 77MB 上限的主因之一。稀疏化不得改变解码结果（由引擎与 iOS 测试兑现）。

## 键盘激活响应

61. 切换到“是语键盘”时布局不得闪烁、按键不得在数百毫秒内失效。原生引擎（GRU embedding、ncnn 模型、score 表）加载昂贵，**不得在主线程/控制器属性初始化时同步构建**：`KeyboardViewController` 必须先用轻量 `BuiltinPinyinDecoder` 立即呈现可用键盘，再在后台队列加载 `NativePinyinDecoder` 并在就绪后换入、保留在打 raw。
62. 已加载的原生引擎须以 `NativePinyinDecoder.shared` 在扩展进程内跨控制器实例复用，避免每次切换重新加载。换入不得丢失/错位当前 marked 组合（沿用 `restore(raw:committed:)`）。
63. 缝隙点击需两个条件同时满足：根视图 `view` 近乎不透明（alpha 0.9，否则缝隙触摸穿透到宿主）；键用 `KeyButton()` 把 `point(inside:)` 向缝隙扩 ~8pt（否则缝隙下无键可接）。必须 `KeyButton()` 直接实例化，`UIButton(type:.system)` 不生成子类。

## 双拼解码不变量

64. 双拼（微软/小鹤/自然码/搜狗）：**韵母不走扩展，单个声母才走扩展**。打全的音节韵母固定（`he` 只能是 喝/和，不能变 黑/很），只有末尾孤立声母才补全（微软 `nghem` → 能喝吗，非 能很忙/能黑马）。逻辑对所有双拼方案共用（`Composition` 以 `shuangpin != nil` 判定，而非某个具体方案）。用例与断言见 `iOS/Tests/ShuangpinEndToEndTests.swift`（真机引擎端到端，当前以微软布局覆盖）。

64b. 双拼下打完声母（当前音节只剩一个待配对键）时，字母页**高亮能与该声母组成合法音节的韵母键**（蓝色底）；音节打满或全拼不高亮。合法性以引擎为准：两键经当前方案的 `ShuangpinLayout.expand` 展开后，须能作为单个音节返回汉字候选（`units` 恰好等于该拼音），否则不亮（如 `wuan`/`wue`/`wuai` 只回显字面或拆成 `wu'ai`）；不得用手写韵母白名单。高亮键还**吸附与相邻非高亮键之间的缝隙**（行内 4pt），双方都不侵入对方键面，也不破坏契约 63。**“上色”与“扩大命中区”相互独立**，由 `tintShuangpinFinalKeys` / `enlargeShuangpinFinalKeys` 分别控制。合法集合逻辑见 `iOS/Tests`（`testShuangpin*FinalKeys*`）；此处只留真机回归：不闪烁、不阻碍连打、缝隙偏向合法键，引擎换入/切方案后一致。

64c. **只有微软/搜狗布局使用 `;` 韵母键**（`InputScheme.usesSemicolonKey`）：其字母页 home 行含 `;` 且不缩进；小鹤/自然码/全拼的 home 行为 `asdfghjkl`（缩进），`;` 只作标点。切方案后须 `keyboardNeedsRebuild` 重建键盘。

64d. 各双拼方案的键→拼音映射由 `ShuangpinLayout.microsoft/xiaohe/ziranma` 表驱动，代表用例断言见 `iOS/Tests/MicrosoftShuangpinTests.swift`、`XiaoheShuangpinTests.swift`、`ZiranmaShuangpinTests.swift`。**自然码**当前实现按“与微软同键位、但 `ing` 移到 `y`（与 `uai` 共键，声母互斥不冲突）、零声母用韵母首字母（`爱=al`）”建模；**搜狗**默认布局按与微软完全一致处理。这两条布局细节尚未做真机长期回归，若与官方码表有出入，先改表与对应测试再改行为，不要让码表、测试与本条默默分叉。

64e. **双拼必须覆盖全拼音节全集**：标准普通话约 410 个音节清单在 `iOS/Tests/quanpin.txt`（唱作资源），`ShuangpinCoverageTests` 枚举每方案所有两键组合的 `expand` 结果，逐条断言清单均可产出（`ü`归一为 `v`）。唯一已知例外是双拼无法区分的稀见叹词 `lo`（→luo）、`yo`（→yuo），在测试中显式排除。`quanpin.txt` 是该清单的唯一来源，不要另处重建。

65. 双拼每个音节以撇号分隔发给引擎（`neng'he'ma`），撇号只表示**分词边界**：整句解码（`DecodeSentence`）必须**跨撇号保留 n-gram 上下文**（`Process(keep_sep_context=true)`），使同一串拼音带不带撇号打分一致（`neng'he'ma`=`nenghema`→能喝吗，`li'zhou`=`lizhou`→利州）。改选（`DecodeCorrection`）**保留**撇号处的上下文重置（`keep_sep_context=false`）——两条路径不可统一：全局去掉重置会破坏 `xing'jia'bi` 改选，去掉保留会让双拼整句排序退化。断言见 `iOS/Tests/ShuangpinEndToEndTests.swift`（双拼与全拼首选一致）与 `require/Sime/tests/correction_test.cc`（改选不变）。

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
