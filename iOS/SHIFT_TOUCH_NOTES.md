# Shift 多指输入实验记录

## 目标

支持系统键盘式 Shift 行为：

- 短按 Shift，下一次字母输入大写（one-shot）。
- 按住 Shift，另一根手指连续点击字母，期间全部大写。
- Shift 手指松开后立即恢复小写。
- 不增加长按锁定，不增加 caps lock，不使用计时器猜测松开状态。

## 当前状态

本轮实验已全部回滚，正式代码仍使用原有 `UIButton` Shift 实现。未确认的实验代码没有提交。

## 已确认的问题

1. `UIButton/UIControl` 的触摸跟踪不适合 Shift + 另一根手指输入：第二根手指可能导致第一根 UIControl 触摸序列收到取消，`touchUpInside` 不可靠。
2. 在 `touchUpInside`、`touchCancel` 和定时器之间反复补丁，会在“第二个字母变小写”和“松手后仍大写”之间切换，不能作为最终方案。
3. 仅在 `ShiftKeyView` 或容器上开启 `isMultipleTouchEnabled`，仍不足以证明所有触摸序列都能稳定保留；需要真机验证每个触摸接收层的生命周期。
4. 在触摸期间调用 `render()` 或重建键盘可能导致键盘出现上下重复、布局异常或候选栏位置异常；Shift 触摸路径不能触发布局重建。
5. 当前实验包出现过键盘消失、上下重复键盘、候选栏跑到左侧等现象，均已通过回滚未提交改动并重新部署稳定版本处理。

## 本轮尝试及结果

### 失败方案

- 在 `KeyboardViewController` 中增加 `.held` 状态，并依赖 `UIButton` 的 `touchUpInside/touchCancel`。
- 增加 `UILongPressGestureRecognizer` 追踪 Shift。
- 使用输入停顿计时器自动恢复小写。
- 仅把 Shift 替换成自定义 `UIView`，字母键仍保留 `UIButton`。
- 仅设置根视图、`keyboardStack`、row 或按钮的 `isMultipleTouchEnabled`。

这些方案都没有在真机上稳定同时满足“连续大写”和“松手立即小写”，不得直接恢复。

## 下次建议

### 路径 A：短实验

在不改变现有事件分发的前提下，完整设置以下对象：

- 键盘根视图
- 根 `UIStackView`
- `keyboardStack`
- 每个 row
- 每个 `KeyButton`
- 自定义 Shift View（如果仍保留）

全部设置 `isMultipleTouchEnabled = true`，不添加新的手势、不在 Shift 触摸期间重建键盘，然后只做真机双指验证。若仍有任何触摸取消或释放丢失，立即停止路径 A。

### 路径 B：正式方案

建立 `KeyPlaneView`，让整个键区由一个自定义 `UIView` 接管触摸：

- 不再让字母、数字、删除、空格等键依赖 `UIButton/UIControl` 触摸跟踪。
- 用 `[UITouch: Key]` 映射维护每根手指对应的键。
- `touchesBegan` 触发按下。
- `touchesMoved` 处理滑出和重新命中。
- `touchesEnded` 触发字母/数字/符号/标点动作。
- `touchesCancelled` 使用 `event.allTouches` 区分系统打断和仍存活的触摸。
- 删除键保留按下/重复/释放 generation 防护。
- 空格长按光标模式迁移到自定义触摸路由，保留触感反馈。
- 地球键可继续保留 `UIButton`，因为系统菜单 API 需要 UIControl sender。
- 候选栏字符按钮、确认键、声调按钮暂时可保持现状，作为独立边界。

## 实现纪律

- 不使用时间阈值推断 Shift 是否松开。
- 不使用定时器模拟松开。
- 不在 Shift 触摸事件中调用会重建键盘的 `render()`。
- 每次实验只做一个可验证的小改动，真机通过后再继续。
- 实验失败立即回滚，不把未验证的 Shift 改动提交。
- 每次部署前确认 `git diff` 只包含本轮实验内容，并确认生成工程没有把实验文件遗漏或残留。
