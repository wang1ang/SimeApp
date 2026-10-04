# iOS 输入法：marked text 生命周期与假上屏方案

这是 iOS 输入法开发中的一个经典坑。先明确原因，再选择业界标准的处理方式。

## 原因

上屏的带下划线拼音，通常通过 `textDocumentProxy.setMarkedText(_:selectedRange:)`（iOS 13+）设置。这属于 **marked text（标记文本）**，生命周期由系统 UIKit 控制，不归键盘完全管理：

- 用户**点按文本区域**时，系统可能改变 selection，并自动对输入框调用 `unmarkText()`，把标记文本落格为普通文本或直接清掉，下划线因此消失。这是系统行为，键盘无法拦截。
- 自定义键盘无法拦截用户在宿主文本框中的点击手势，触摸事件归宿主 App 处理，因此“点拼音弹出候选或编辑”通常无法可靠实现。
- marked text 的支持程度取决于宿主 App。系统的 `UITextField` / `UITextView` 支持较好，但很多 WebView 或自绘输入框支持不完整，行为可能不一致。在备忘录里正常，不代表其他 App 也正常。

## 业界标准解法：假上屏

搜狗、百度等 iOS 输入法通常采用假上屏：**不把拼音放进文本框，而是只在键盘自己的 UI 中维护和显示拼音。**

1. 自己维护 `composingText` 状态变量。
2. 将拼音串绘制在键盘自己的 UI 中，例如候选栏左侧或键盘上方的 composing bar；下划线样式完全由键盘控制。
3. 用户点候选后，再通过 `insertText(最终中文)` 提交最终结果。
4. 自己处理删除逻辑：如果 `composingText` 非空，删除键只修改拼音状态，不调用 `deleteBackward()` 删除文档内容；文本框中此时实际上还没有输入汉字。

这种方式的行为不受宿主 App 影响，也能可靠支持“点拼音串重新编辑”等交互。

## 如果坚持使用系统 marked text

至少需要做好以下兜底：

- 实现 `textDidChange` / `selectionDidChange`，检查 `documentContextProxy.documentContextBeforeInput` 是否仍以当前拼音结尾。发现系统取消 marked text 后，用 restoring 标志位防止循环，再调用 `setMarkedText` 恢复。
- 连续更新拼音时直接再次调用 `setMarkedText`，不要先 `unmarkText()` 再 `insertText`。
- `selectedRange` 是相对于拼音串的 `NSRange`，其中 `location` 从拼音串起点计算。
- 切换文本框后，`textDocumentProxy` 可能已经改变；旧拼音串可能挂在新文档中，需要在 `textDidChange` 中清理状态。

## 快速自查清单

1. 先在系统“备忘录”中测试。如果备忘录正常、只有某个 App 中消失，通常是该 App 不完整支持 marked text，应考虑假上屏。
2. 全局搜索代码，确认没有误调用 `unmarkText()` 或覆盖性的 `insertText()`。
3. 确认点候选后没有再次触发 `setMarkedText("")`。

## 一句话总结

**系统提供的 marked text 是“借”来的，随时可能被系统收回；可控的做法是自己绘制拼音，只提交最终结果。** 这也是主流第三方 iOS 输入法普遍采用的交互模式。
