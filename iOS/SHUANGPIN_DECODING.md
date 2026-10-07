# 双拼解码流程

双拼在客户端（Swift 侧）先展开成全拼，再把全拼交给 C++ 引擎去查（trie 词典）。

## 路径（`Composition.swift:740-758`）

1. 双拼 raw 按键（如 `nihc`）每两键一组，用 `ShuangpinLayout.expand` 展开成全拼音节（`ni`、`hao`）。
2. 用 `'` 把音节拼起来 → `ni'hao`，再交给 `decoder.decode(...)`（C++ 引擎）。
3. 引擎在词典（trie）里查。

## 和全拼路径的三个关键差别

1. **显式音节边界**：双拼主动插 `'` 分隔符（`ni'hao`），因为双拼每音节恰好两键，边界是确定的。这样引擎**不会重新切分**（否则 `pie` 可能被切成 `pi`+`e`）。全拼路径（`Composition.swift:762`）则是整串丢进去，让引擎自己切。

2. **expansion 开关**：
   - 双拼：`expansion: hasLoneInitial`——只有在末尾落单一个声母（奇数键）时才让引擎补全；**打满的音节不扩展**（否则 `li` 会跑出“柳州”）。
   - 全拼：`expansion: true`——允许缩写/尾部补全。

   这对应契约 64“双拼韵母不走扩展，单个声母才走扩展”。

3. **末尾孤立声母**：落单的 `v/i/u` 通过 `shuangpin.initial(for:)` 展成 `zh/ch/sh`（`Composition.swift:752`）。

## 小结

- 双拼 = 客户端展开成「带显式边界的全拼」+ 受限扩展，再查引擎 trie。
- 全拼 = 原串 + 自由切分/扩展查 trie。
