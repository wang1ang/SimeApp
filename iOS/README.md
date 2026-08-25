# 是语输入法（iOS）

这是“是语输入法”的 iOS App 与键盘扩展。包含离线 Sime 拼音引擎、两行候选栏、逐字改选、上屏后联想、全拼与微软双拼；默认不申请“完全访问”，不上传输入内容。

- 宿主 App 名称：**是语输入法**
- 系统键盘名称：**是语键盘**

## 生成与运行

```bash
brew install xcodegen        # 只需首次安装
cd iOS
xcodegen generate
open Sime.xcodeproj
```

在 Xcode 的 Signing & Capabilities 中为 `Sime` 和 `SimeKeyboard` 选择同一 Development Team，再运行 `Sime` target 到真机。随后按宿主 App 指引在系统设置中启用“是语键盘”。键盘扩展不能在模拟器中完整验证，需使用真机。

## 输入方案

在宿主 App“是语输入法”中切换：

- **全拼**：标准拼音键盘布局。
- **微软双拼**：双拼布局（含 `;` 的 `ing` 键）。

## 解码器与资源

`KeyboardExtension/Composition.swift` 是 UI 组合状态与引擎的边界，`NativePinyinDecoder.swift` 通过 `Engine/sime_api.{h,cc}` 调用 bundled Sime C++ 引擎。

构建时会把 `require/Sime/save/sime.dict` 和 `require/Sime/save/sime.cnt` 复制进 keyboard extension；运行时和模型必须位于扩展 target 内，不能依赖宿主 App 进程。上屏后会用已确认的 token 调用 `sime_next_tokens` 显示离线联想；点联想词会继续更新短期上下文。不要启用网络或把输入内容传出扩展。
