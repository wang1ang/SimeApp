# 双拼解码

微软/搜狗、小鹤和自然码通过各自的预建 Sime index 解码原始按键。双拼输入沿着 `KeyboardViewController` → `Composition.raw` → `NativePinyinDecoder` → 当前方案 Sime index 的路径传递；`NativePinyinDecoder` 负责绑定 index、转交原始按键并封装引擎结果。双拼键码到拼音单元的映射以该 index 的映射表为唯一来源，Sime 引擎依据映射结果完成解码。

## 运行流程

- `InputScheme.shuangpinIndexName` 选择当前 index：微软/搜狗共用 `sime.sp`，小鹤使用 `sime.xiaohe.sp`，自然码使用 `sime.ziranma.sp`；该选择决定整段组合使用的双拼映射。
- `NativePinyinDecoder` 按当前方案加载 index；方案切换时切换对应 binding，扩展进程缓存当前使用的 Native decoder，以控制引擎资源占用。
- Native decoder 加载期间，Builtin fallback 将原始按键作为可提交文本显示；Native decoder 就绪后，使用当前方案 index 继续解码保留的 raw composition。
- Decoder 返回候选的显示字符跨度和原始按键跨度；这组 spans 是候选分组、逐字改选和提交时的边界依据，`Composition` 全程沿用这些跨度。
- 中英混合输入由 decoder 接收完整原始输入，并在同一 lattice 中统一排序；`Composition` 根据 decoder 返回的候选与 units 展示预编辑内容。

## 映射与验证

索引映射由 `require/Sime/pipeline/` 中的脚本和映射表生成，运行时 index 位于 `require/Sime/save/`。重建小鹤/自然码 index：

```bash
python3 pipeline/gen_shuangpin_map.py xiaohe
python3 pipeline/gen_shuangpin_map.py ziranma
build/sime-spbuild save/sime.dict pipeline/xiaohe.map.txt save/sime.xiaohe.sp.index
build/sime-spbuild save/sime.dict pipeline/ziranma.map.txt save/sime.ziranma.sp.index
```

`ShuangpinCoverageTests` 使用生成映射表和实际 decoder index 验证全拼音节覆盖；`ShuangpinEndToEndTests` 验证方案切换、逐字改选和中英混合。C++ index 与改选断言位于 `require/Sime/tests/correction_test.cc`。
