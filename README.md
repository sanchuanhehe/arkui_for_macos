# arkui_for_macos

**ArkUI-X 的 macOS (Apple Silicon) 原生适配层** —— 即 `ace_engine` 的 `adapter/macos`，与 `adapter/android`、`adapter/ios` 同级。把标准 ArkUI(声明式 + 方舟运行时 + RenderService + skia)真正渲染、跑在原生 AppKit 窗口里。

> 这是一个**独立子仓**。它本身不是完整工程，而是被克隆进 ArkUI-X 源码树的 `foundation/arkui/ace_engine/adapter/macos/`。主工程(补丁集 + 构建脚本 + 复现步骤 + CI)在 **[sanchuanhehe/arkui-x-macos-native](https://github.com/sanchuanhehe/arkui-x-macos-native)** —— 它的 `scripts/apply_patches.sh` 会在末尾自动 `git clone` 本仓到位(`ace_engine` 的 `.gitignore: adapter/*` 忽略此目录，和 android/ios 适配层一致)。

## 为什么独立成仓

macOS 窗口层体量大(180+ 文件)且自成一体，作为补丁分发会很笨重。拆成独立仓后：补丁集只管 OHOS 各仓的**改动**，而 adapter/macos 这一**新增整层**用 `git clone` 引入 —— 干净、可独立迭代、对齐 iOS/Android 的目录习惯。

## 目录结构

| 目录 | 内容 |
|--|--|
| `entrance/` | App 壳与窗口层:`main.mm`、`MacAppDelegate.mm`、`WindowView`(NSView + CAOpenGLLayer 渲染 + NSTextInputClient IME + NSAccessibility)、`virtual_rs_window.mm`(Rosen::Window/子窗口 NSPanel)、`mac_text_input`(IME)、`mac_accessibility_bridge`(无障碍树桥接) |
| `osal/` | OS 抽象层:剪贴板/下载/资源/文件/输入法/无障碍/`advance/`(AI 图像分析等)、`mac_link_stubs.cpp` |
| `stage/` | Stage 模型:`StageViewController`、`StageConfigurationManager`(暗色/方向)、`ability/`、`uicontent/`(`ace_container_sg`) |
| `capability/` | 能力插件:`clipboard`(NSPasteboard)、`environment`(NSWorkspace)、`font`(CoreText) |
| `build/` | `BUILD.gn`(`ace_macos` 可执行 + NAPI kit 静态链接)、`package_app.sh`(组装可运行 `.app`:自动收集 dylib 依赖 + ICU data + Info.plist + 签名) |

## 构建

由主工程驱动(见 [arkui-x-macos-native 的构建节](https://github.com/sanchuanhehe/arkui-x-macos-native))。要点:

```bash
# 在 ArkUI-X 源码树根，apply_patches 之后:
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
gn gen out/arkui-x --args='target_os="mac" use_xcode_clang=true'
ninja -C out/arkui-x arkui/ace_engine/ace_macos
# 打包成可运行 .app:
bash foundation/arkui/ace_engine/adapter/macos/build/package_app.sh out/arkui-x ArkUI-X
```

页面用 DevEco 的 `ace build bundle` 产出 `modules.abc`，放进 `.app` 的资源目录即可运行。

## 能力状态(对齐 [macOS Roadmap](https://github.com/sanchuanhehe/arkui-x-macos-native/blob/main/docs/macos-roadmap.md))

- **M0/M1 地基+渲染** ✅:GN `target_os=mac`、NSOpenGL/CALayer 桌面渲染、`libace` 编通、AppKit 开窗、`.ets` 页面上屏(CoreText 中英文)。
- **M2 核心交互** ✅:输入分发、IME(候选框定位)、光标跟随、Cmd 快捷键。
- **M3 窗口/渲染** 🔶:暗色模式(启动读外观 + 实时切换)✅、resize 重排 ✅;子窗口走独立 `NSPanel`(可超出主窗口)框架就绪，透明 surface 攻坚中。
- **M4 能力插件** 🔶:剪贴板/存储/环境/下载/字体 ✅。
- **M7 系统 API** ✅:23 个 `@ohos.*` NAPI kit 静态链接自注册。
- **M8 i18n/无障碍/安全** 🔶:`@ohos.i18n`/`@ohos.intl` 全通(系统 API + ICU 日期/货币)、NSAccessibility 桥接 ✅、Info.plist 权限合规 ✅。
- **M9 打包** 🔶:`package_app.sh` 出可运行 `.app`(自动依赖收集 + ICU data + TCC 修复);Developer-ID 签名 + 公证待证书。

## 许可

Apache-2.0，与 ArkUI-X / OpenHarmony 一致。
