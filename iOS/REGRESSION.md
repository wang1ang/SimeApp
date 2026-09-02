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
4. 全拼/微软双拼设置通过 App Group 共享；切换后不得混用旧 Composition 状态。
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

12. 第二行只显示从点选位置开始的可替换内容，不能把固定前缀显示进候选。
13. 点选位置之前的当前文字参与约束和排序，但只有用户明确选择过的范围成为永久锚点。
14. 新选择与旧锚点重叠时，只替换被覆盖范围，不能清空其他锚点。
15. 追加输入、退格、移动 marked-text 光标、切换宿主字段和锁屏恢复后，仍应保持合法锚点。
20. 第一行整句预览逐字可点，且分两段交互：第一次点某字**只高亮选中该字（变蓝色）**并在第二行列出其替换候选，第一行仍显示解码后的汉字，不变成拼音；**再点同一字**才把该字标签切换为用户实际按键（全拼保留原输入及分隔符，双拼显示原始双拼码）。点选其它字或改选后自动跳到下一字时，均按“首次点选”处理（重新高亮、不显示按键）。
21. GRU 只能在满足全部锚点约束的合法路径之间重排。
22. 字选择和词选择必须走相同的 segment 状态转移，不得出现 UI 特判分支。
23. 锚点应携带原始按键范围、音节范围、显示文字和 token；人工审查不得出现以汉字长度反推拼音边界的逻辑。

## 候选栏触摸与布局

24. 第一行为整句逐字按钮，第二行为横向滚动候选。
25. 第二行保持 UILabel + 统一点击手势 + 原生 UIScrollView；不要恢复会抢滚动手势的候选 UIButton。
26. 点击候选和横向拖动互不冲突，首帧即可长距离滚动。
27. 候选文本宽度按实际显示文本计算。
28. 当前真机布局基线：顶部 `-6pt`、第一行 `28pt`、按钮最小 `24pt`、第一行间距 `3pt`、第二行间距 `6pt`。

## Marked text 与宿主光标

29. 点击宿主中的 marked 拼音应定位组合光标，不能让整段拼音消失。
30. 宿主只暴露光标前或光标后一侧 context 时，也应尽可能完成定位。
31. 中间插入、前后删除后，marked 光标、原始按键和第一行候选必须一致。
32. 锁屏、切 App 或扩展重建后应恢复未完成组合。
33. 宿主临时 unmark 组合时应恢复 marked text，并避免 `textDidChange` 重入循环。
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
41b. 键盘为三页结构：字母页按 `123` 进数字页；数字页按 `#+=` 进符号页；符号页按 `123` 回数字页，按左下角切换键回字母页。符号页插入任意符号后保持在符号页（与系统键盘 #+= 一致）。左下角切换键在非字母页显示当前方案（全拼为“拼音”、微软双拼为“双拼”）。
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

## 微软双拼解码不变量

64. 微软双拼：**韵母不走扩展，单个声母才走扩展**。打全的音节韵母固定（`he` 只能是 喝/和，不能变 黑/很），只有末尾孤立声母才补全（`nghem` → 能喝吗，非 能很忙/能黑马）。用例与断言见 `iOS/Tests/ShuangpinEndToEndTests.swift`（真机引擎端到端）。

64b. 微软双拼下打完声母（当前音节只剩一个待配对键）时，字母页**高亮能与该声母组成合法音节的韵母键**（蓝色底）；音节打满或全拼不高亮。合法性以引擎为准：两键经 `MicrosoftShuangpin.expand` 展开后，须能作为单个音节返回汉字候选（`units` 恰好等于该拼音），否则不亮（`wuan`/`wue`/`wuai` 只回显字面或拆成 `wu'ai`）；不得用手写韵母白名单。高亮键还**吸附与相邻非高亮键之间的缝隙**（行内 4pt），双方都不侵入对方键面，也不破坏契约 63。**“上色”与“扩大命中区”相互独立**，由 `tintShuangpinFinalKeys` / `enlargeShuangpinFinalKeys` 分别控制。合法集合逻辑见 `iOS/Tests`（`testShuangpin*FinalKeys*`）；此处只留真机回归：不闪烁、不阻碍连打、缝隙偏向合法键，引擎换入/切方案后一致。

65. 微软双拼每个音节以撇号分隔发给引擎（`neng'he'ma`），撇号只表示**分词边界**：整句解码（`DecodeSentence`）必须**跨撇号保留 n-gram 上下文**（`Process(keep_sep_context=true)`），使同一串拼音带不带撇号打分一致（`neng'he'ma`=`nenghema`→能喝吗，`li'zhou`=`lizhou`→利州）。改选（`DecodeCorrection`）**保留**撇号处的上下文重置（`keep_sep_context=false`）——两条路径不可统一：全局去掉重置会破坏 `xing'jia'bi` 改选，去掉保留会让双拼整句排序退化。断言见 `iOS/Tests/ShuangpinEndToEndTests.swift`（双拼与全拼首选一致）与 `require/Sime/tests/correction_test.cc`（改选不变）。

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
