# 双拼解码

微软/搜狗、小鹤和自然码都通过各自的预建 index 解码原始键码。Swift 不将双拼码展开成全拼，也不生成拼音分隔符。

## 运行流程

- `InputScheme.shuangpinIndexName` 选择 index：微软/搜狗共用 `sime.sp`，小鹤使用 `sime.xiaohe.sp`，自然码使用 `sime.ziranma.sp`。
- `NativePinyinDecoder` 只加载当前方案对应的 index。切换方案时卸载旧 binding，扩展内不会同时保留多个双拼 index 或全拼 engine。
- Native decoder 尚未就绪时，Builtin 只保留原始键作为可提交文本；不会走双拼转全拼的回退路径。
- Decoder 返回候选的显示字符范围和原始键范围。Composition 用这些跨度做候选分组、逐字改选和提交，不按键数或汉字长度重建边界。
- 中英混合输入作为完整原始输入送给 decoder，在同一 lattice 中竞价；Composition 不按大写位置切分或手工排序英文尾巴。

## 映射与验证

索引映射由 `require/Sime/pipeline/` 中的脚本和映射表生成，运行时 index 位于 `require/Sime/save/`。重建小鹤/自然码 index：

```bash
python3 pipeline/gen_shuangpin_map.py xiaohe
python3 pipeline/gen_shuangpin_map.py ziranma
build/sime-spbuild save/sime.dict pipeline/xiaohe.map.txt save/sime.xiaohe.sp.index
build/sime-spbuild save/sime.dict pipeline/ziranma.map.txt save/sime.ziranma.sp.index
```

`ShuangpinCoverageTests` 用生成映射表和实际 decoder index 覆盖全拼音节；`ShuangpinEndToEndTests` 覆盖方案切换、逐字改选和中英混合。C++ index/改选断言位于 `require/Sime/tests/correction_test.cc`。
