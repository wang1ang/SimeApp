# iOS 输入法

这是可直接生成 Xcode 工程的 iOS 输入法扩展：包含宿主 App、中文拼音候选栏、QWERTY 键盘、中英切换、删除、换行和系统键盘切换；默认不申请“完全访问”。

## 生成与运行

```bash
brew install xcodegen        # 只需首次安装
cd iOS
xcodegen generate
open Sime.xcodeproj
```

在 Xcode 的 Signing & Capabilities 中为 `Sime` 和 `SimeKeyboard` 选择同一 Development Team，再运行 `Sime` target 到真机。随后按宿主 App 的指引在系统设置中启用键盘。键盘扩展不能在模拟器中完整验证，需使用真机。

## 解码器接入

`KeyboardExtension/Composition.swift` 里的 `PinyinDecoder` 是 UI 与引擎的边界；当前 `BuiltinPinyinDecoder` 让工程在未打包模型时也可运行。量产时请用 Sime C++ 引擎实现该协议，并将 `sime.dict`、`sime.cnt` 作为 keyboard extension 的资源打包。引擎运行时和模型必须位于扩展 target 内，不能依赖宿主 App 进程。

`macOS/api/sime_api.{h,cc}` 已提供可复用的 C ABI 设计；iOS 适配应将其编译为 extension 链接的静态库，并在 Swift 中调用。不要启用网络或把输入内容传出扩展。
