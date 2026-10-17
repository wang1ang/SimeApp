# 是语输入法应用

SimeApp 包含是语输入法的 Android、macOS 和 Fcitx5 前端。C++ 输入引擎、CLI
工具及模型训练流水线位于独立的
[Sime](https://github.com/Ismantic/Sime) 仓库。

## 安装

- Android 和 macOS 的正式版本可以直接去 [Release 页面](https://github.com/Ismantic/SimeApp/releases) 下载。

## Android 界面

<p align="center">
  <img src="fastlane/metadata/android/en-US/images/phoneScreenshots/01-onboarding.jpg" width="45%" alt="启用是语输入法" />
  <img src="fastlane/metadata/android/en-US/images/phoneScreenshots/02-tools.jpg" width="45%" alt="输入工具面板" />
</p>
<p align="center">
  <img src="fastlane/metadata/android/en-US/images/phoneScreenshots/03-layouts.jpg" width="45%" alt="全键盘与九宫格布局" />
  <img src="fastlane/metadata/android/en-US/images/phoneScreenshots/04-t9.jpg" width="45%" alt="九宫格输入" />
</p>

## 0.17.0

- Android 新增手写键盘，使用 Handwritten NCNN 模型在设备本地识别。

## 0.16.0

- 新增本地 GRU 整句排序器，提升全拼和九宫格整句准确率；模型完全离线运行。
- 保留此前的九宫格解码延迟优化，GRU 使用单线程 ncnn CPU 推理。
- Arch Linux 可以直接安装 [AUR](https://aur.archlinux.org/packages/fcitx5-sime) 包。
- 开发或自行编译时，请从源码构建。

### 准确率评测

在四个固定测试集（全拼、九宫格各两套，共 7,917 条）的 Top-1 测试中，Sime
（含 GRU 排序器）整句准确率为 **56.68%**，字准确率为 **88.60%**。

| 测试集 | 条数 | 整句准确率 | 字准确率 |
|---|---:|---:|---:|
| 全拼 cases.1 | 1999 | 76.49%（1529） | 95.28% |
| 全拼 cases.2 | 2000 | 50.20%（1004） | 88.27% |
| 九宫格 cases.num.1 | 1955 | 66.45%（1299） | 91.36% |
| 九宫格 cases.num.2 | 1963 | 33.37%（655） | 78.33% |
| 全拼合计 | 3999 | **63.34%** | **91.96%** |
| 九宫格合计 | 3918 | **49.87%** | **85.15%** |

对比其它开源输入法，还在三个全拼集合（共 5,354 条）上测试了最新版雾凇拼音配合
万象 LTS 语言模型。两边均使用空用户词库，不加载历史调频，也不在评测过程中提交候选。

| 输入方案 | 整句准确率 | 字准确率 |
|---|---:|---:|
| Sime GRU | **64.74%**（3466/5354） | **91.89%** |
| 万象 LTS | 59.25%（3172/5354） | 89.08% |

声明：这只是特定测试集合和固定配置下的参考结果，不代表所有输入场景中的体验。不同方案
在词库覆盖、用户调频、功能和资源规模上各有侧重。评测环境、逐集合结果、模型校验值
和已知限制见
[完整报告](https://github.com/Ismantic/Sime/blob/main/pipeline/gru/RIME_ICE_EVALUATION.md)。


### Arch Linux

使用 `yay` 安装：

```bash
yay -S fcitx5-sime
```

安装完成后重启 Fcitx5：

```bash
fcitx5 -r
```

打开 `fcitx5-configtool`，搜索并添加“Sime”，随后即可切换使用。后续版本会随
常规的 `yay -Syu` 一起更新。

## 目录

- `Android/`：Android IME、JNI 适配层及 JUnit 测试。
- `macOS/`：InputMethodKit 前端、Swift UI 和安装包脚本。
- `Linux/fcitx5/`：Fcitx5 插件。
- `Linux/package/`：Arch Linux 打包文件。
- `cmake/`：定位并引入 Sime 引擎的共享 CMake 模块。

## 源码

克隆时请一并取得源码依赖：

```bash
git clone --recurse-submodules https://github.com/Ismantic/SimeApp.git
cd SimeApp
```

已克隆的工作区可用 `git submodule update --init --recursive` 补齐
`require/Sime`、`require/ncnn` 与 `require/Handwritten`。构建默认使用这些子模块；
也可以用 `SIME_ENGINE_ROOT` 或 CMake 的
`-DSIME_ENGINE_ROOT=/path/to/Sime` 指向本地 Sime 源码。

## 构建

如果你想自己编译或修改代码，可以从源码构建。

Android：

```bash
cd Android
./gradlew testDebugUnitTest
./gradlew assembleDebug -PincludeHandwriting=false
```

上面的独立构建不含手写模型。启用手写时，还需要准备含模型资产的
[Handwritten](https://github.com/Ismantic/Handwritten) 工作树，并通过
`HANDWRITTEN_ROOT=/path/to/Handwritten` 或 `-PhandwrittenRoot=/path/to/Handwritten`
指定它。

用于 F-Droid 的 Release 构建为：

```bash
./gradlew --no-daemon clean :app:assembleRelease -PincludeHandwriting=false
```

Fcitx5：

```bash
cmake -S Linux/fcitx5 -B build/fcitx5 \
  -DCMAKE_BUILD_TYPE=Release
cmake --build build/fcitx5
```

macOS：

```bash
cmake -S macOS -B build/macos -G Xcode
cmake --build build/macos --config Release
```

Android、macOS 与 Fcitx5 均从 Sime 子模块的 `save/` 读取版本化运行时模型；无需
手动复制模型。原始训练语料和中间产物不在应用仓库中。

## 隐私

所有输入和用户数据仅在本机处理。完整说明见 [PRIVACY.md](PRIVACY.md)。

## License

[Apache-2.0](LICENSE)
