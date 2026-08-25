# iOS 开发交接说明

## 工程源与构建

- `project.yml` 是 XcodeGen 工程源；不要手工维护或提交 `Sime.xcodeproj/`（已忽略）。
- 修改 `project.yml` 后执行：
  ```bash
  cd iOS
  xcodegen generate
  ```
- 生成工程会清空本地 `DEVELOPMENT_TEAM`。真机开发团队目前是 `MYHKW53N5T`，但不要将生成工程提交。
- 模拟器构建：
  ```bash
  cd iOS
  xcodebuild -project Sime.xcodeproj -scheme Sime -sdk iphonesimulator \
    -configuration Debug CODE_SIGNING_ALLOWED=NO build
  ```
- 双拼单测：
  ```bash
  xcodebuild -project iOS/Sime.xcodeproj -scheme Sime \
    -destination 'platform=iOS Simulator,id=3DACCA52-8DBE-48D9-BBED-2AFE9F42F1CB' test
  ```
  也可选择本机任意可用 Simulator。
- 真机请运行宿主 `Sime` scheme，而不是 extension scheme。

## 当前产品结构

- 当前仅有**一个** Keyboard Extension：系统名为“是语键盘”。
- `iOS/Sime/ContentView.swift` 的“微软双拼”开关控制输入方案：
  - 关闭：全拼；标准布局，第二行缩进且没有 `;`。
  - 开启：微软双拼；第二行含 `;`。
- 该开关通过 App Group `group.com.ismantic.sime` 共享；两个 entitlements 文件不可随意删除：
  - `Sime/Sime.entitlements`
  - `KeyboardExtension/SimeKeyboard.entitlements`
- iOS 不允许已安装的单一 extension 按 App 设置动态更改系统键盘菜单名称。若将来要求系统菜单分别列出“拼音/双拼”，只能重新拆成两个 extension；用户当前明确要求**不要拆分**。

## Sime 引擎

- 真正的 C++ 引擎来自 `require/Sime` 子模块；字典/模型为：
  - `require/Sime/save/sime.dict`
  - `require/Sime/save/sime.cnt`
- Extension 在 `project.yml` 编译 `../require/Sime/src/*.cc`，预构建脚本复制模型。
- C ABI 在 `iOS/Engine/sime_api.h/.cc`；Swift 适配为 `KeyboardExtension/NativePinyinDecoder.swift`。
- 子模块已包含本地引擎提交 `95fe731 Engine: retain requested character candidates`：`DecodeStr` 的状态容量随请求候选数扩展，避免单字 Top-20 截断。不要回退该子模块指针。

## 候选与组合交互

- `Composition.swift` 管理 raw 拼音、已选前缀、候选、逐字改选和 marked text 光标。
- 普通输入请求 60 条候选，保留首音节的完整单字集合，避免低频字（如 `shan` 的“删”）无法选择。
- 第一行：整句预览，每字可点；末尾追加可点 `checkmark`，等同空格确认上屏且随第一行横向滚动；第二行：候选横向滚动。
- 点第一行某字后：第二行上下文词/句优先，随后附完整单字候选（按文本去重）。
- 候选更新必须重置两行到左侧；`render()` 创建候选后须立即更新 candidate scroll view 的 `contentSize`，不要依赖下一轮 layout。
- 第二行候选**不要使用 UIButton**：此前按钮会与 `UIScrollView` 争抢拖动，造成字上/字间滚动不一致。当前实现以非交互 `UILabel` 手工布局候选，`candidateBar` 上单个 `UITapGestureRecognizer` 按 label frame 选词，横向拖动完全交由原生 `UIScrollView`。不要重新加入候选按钮或额外的惯性/长按手势拦截。
- 空格：有组合时上屏最佳句，无组合时插入空格。
- 换行：有组合时仅上屏，不插入换行；无组合时插入 `\n`。
- 锁屏可能重建 extension：`InputSettings.pendingRaw/pendingCommitted` 临时保存本地组合，`viewDidLoad` 恢复并重新解码；上屏/清空时删除。
- marked text 光标：`textDidChange` 尝试从 `documentContextBeforeInput/AfterInput` 同步位置；`Composition` 的插入/退格按该光标操作。真机须继续验证不同宿主 App 的 context 行为。

## 微软双拼

- 规则转换在 `Shared/InputScheme.swift` 的 `MicrosoftShuangpin.expand`。
- Sime 使用 `v` 表示 `ü`（例如 `nv`、`lve`），不要输出 Unicode `ü`。
- 已覆盖的关键例子（并有 XCTest）：
  - `wo -> wo`
  - `xcgo -> xiaoguo`（效果）
  - `xigw -> xigua`
  - `ys -> yong`（用）
  - `gv -> gui`、`js -> jiong`、`gd -> guang`
  - 零声母：`oa -> a`、`ol -> ai`、`oo -> o`
- 双拼是每个音节通常两键；例如“用”输入 `ys`，不是 `yong`。
- 双拼候选选中后按音节数 × 2 消耗 raw 按键，避免选第一个字时误删后续音节。
- 映射仍需用真实微软双拼表和真机持续回归；新增/修复规则必须补 `Tests/MicrosoftShuangpinTests.swift`。

## UI 注意事项

- 顶部候选区使用手工横向布局，不要改回 `UIStackView` 候选按钮，否则间距会被拉伸。
- 当前根 stack 顶部约束是 `constant: -6`，这是用户要求观察真机效果的试验值；若视觉异常，应先与用户确认再调整，不要默默恢复。
- 当前紧凑值：第一行 28pt、每字按钮 24pt、步进 27pt（实际按钮间距 3pt）；第一、二行间距 1pt；第二行候选间距 6pt，label 宽为文字 + 4pt。
- 地球键使用 `handleInputModeList(from:with:)` 接入系统菜单；不能自行实现 iPad 键盘位置菜单。

## 当前状态

- 最近候选触摸修复：`09ee1aa iOS: separate candidate tap from scrolling`。
- 单 extension + App 内方案开关：`f130653`。
- 工作区在写本文档前应是干净的；提交本文档后也应保持干净。
- 后续优先真机验证：锁屏恢复、marked text 光标重定位、微软双拼覆盖，以及候选栏长距离滚动/惯性后的触摸体验。
