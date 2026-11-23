# Chromium HarmonyOS 适配层（Orbira 开发线）

本分支 **`hmos-157-adapter`** 是 Orbira 浏览器的开发线：承载 155 的 HarmonyOS 适配迁移至 Chromium **157**，并已在手机真机完成验证。稳定构建保留在 `hmos-155-adapter`；历史 154 基线保留为 `hmos-154-adapter`。

应用壳（ArkUI 界面、面板、偏好设置与 HAP 打包）在本仓 `overlay/chromium-ui/` 维护；引擎适配源码在其旁的 `overlay/` 目录。这是独立、非官方项目，不代表 Google、Chromium、华为或 OpenHarmony 官方立场。

> **仅适配手机端。** 平板、2in1 等大屏路由沿用上游机制，但因无平板设备，未做适配与真机验证。手机包在平板上可通过鸿蒙兼容模式安装，安装后壳层仅提供手机 UI 形态。

## 基线

- Chromium：`157.0.8103.77`
- 上游提交：`7d4508cbfffd289d7015f7703bce215d3ab123bf`（`scripts/prepare-chromium-157.sh` 使用的 pin；迁移增量记录在 `patches/migration-157/manifest.json`）
- 目标系统：`ohos`，对 Chromium 呈现为 HarmonyOS
- 目标架构：`arm64`
- 产品：`kirin_pc`；本地原生构建输出目录 `out/plan_kirin_pc`
- V8：构建包含 JIT 编译器，启动时探测能否映射可执行内存，能则启用 JIT，不能则以 JITless 运行，此时 WebAssembly 由 DrumBrake 解释器执行
- UI：手机使用 ArkUI 移动壳；大屏 Aura/Views 路由仅存在于源码中，未适配、未验证（仅手机端）
- 媒体：AAC/H.264 构建开关已启用；不包含 Widevine CDM
- 公开身份：Chromium HarmonyOS Adapter。商业品牌和 AppGallery 签名保留在独立下游仓；公开源码树以 `com.orbira.browser` 作为参考 bundleName，下游发布前应替换为自身标识。

## 能力与当前状态

| 方向 | 集成内容 |
| --- | --- |
| 设备与界面 | 手机路由已适配并真机验证；平板/2in1 路由沿用上游、未适配（无设备）。ArkUI 外壳桥接与 Chromium Aura/Views 集成。 |
| JavaScript 与 WebAssembly | 启动时探测可执行内存能力，选择 JIT 或 JITless；JITless 下由 DrumBrake 执行 WebAssembly。 |
| 图形与媒体 | OpenGL/Vulkan 适配、HarmonyOS 媒体解码与 HDR 接入；格式与 HDR 可用性取决于设备、系统及所选渲染路径。 |
| 开发者工具 | Chromium DevTools 与本机 CDP 调试；应用壳提供移动端菜单和可展开、收起的悬浮入口。 |
| 内容防护 | 原生广告过滤、本地防钓鱼规则集成及 Chromium 签名数据组件更新。 |
| 分发 | 未签名引擎产物与 HAP 均为本地构建；打包与签名留在开发机。 |

### Chromium 数据组件

`chrome://components/` 按明确白名单接入八项组件：CRLSet、PKI Metadata、Safety Tips、Certificate Error Assistant、File Type Policies、Origin Trials、Hyphenation 和 Crowd Deny。更新保留 HTTPS 与 Chromium 固定发布者密钥的 CRX 签名校验。Origin Trials 更新后在重启时读取；Crowd Deny 为通知权限询问提供本地风险提醒。

组件已注册不代表数据已下载或生效。2026-11-05 的官方 OHOS 更新检查提供了 Hyphenation 和 Crowd Deny；File Type Policies、Origin Trials 返回"无更新"，保留内置策略和默认配置。

独立视频图层提升仍属实验能力，下游应用当前关闭此路径，视频由 Chromium 网页合成器合成。内核不包含 Widevine CDM，编解码及 DRM 边界沿用上游项目的媒体策略文档。

## HarmonyOS 集成

- 手机与折叠态窗口使用手机 UA 与 ArkUI 浏览器栏；大屏设备类别保留上游桌面内容路由，本线未做适配（仅手机端）。
- PWA 通过独立且不导出的 `PWASmallAppExperience` UIAbility 启动，使用沉浸式胶囊与 Chromium 原生 PWA 菜单模型。
- ArkUI 桥接 HarmonyOS 分享、投播、打印、文件选择、默认浏览器选择、AppGallery 更新、华为账号和钱包入口。
- Ozone 输入路径区分鼠标与触控，并在生命周期变化时清除陈旧捕获状态，同时转发 HarmonyOS 输入法焦点。
- CDP 与浏览内容 MCP 桥接默认只监听本机回环地址。

## 仓库内容

- `patches/migration-157/`：从 155 迁移的主仓与依赖适配；`manifest.json` 记录来源、校验值及已纳入的增量补丁。
- `patches/migration-155/`：保留的 155 适配快照。
- `patches/chromium-154-harmonyos.patch`：历史 154 基线。
- `overlay/`：新增的 HarmonyOS、ArkWeb、Ozone、Aura shell 与 ArkUI 源码；其中 `overlay/chromium-ui/` 为应用壳（engine HAR 与 entry）。
- `external/deps_code/webview/`：适配层需要的 WebView 接口源码。
- `config/args.plan_kirin_pc.gn`：真机验证构建使用的 GN 参数。
- `scripts/prepare-chromium-157.sh`：从 pin 的上游提交准备 157 的 WSL 源码树。
- `scripts/build-157-now.sh` / `scripts/build-stage-157.sh`：一键原生构建与引擎产物 staging 到 Windows HAP 工程。
- `scripts/package-157-hap.cmd`（测试包）/ `scripts/package-157-release.cmd`（正式包）：Windows 侧 HAP 打包，含线别护栏。
- `licenses/`：许可证正文与第三方许可证清单。

源码树不包含私有 HarmonyOS SDK 与签名材料；HAP 签名留在开发机。

## 本地构建

157 线在开发机本地构建：

1. `scripts/prepare-chromium-157.sh` —— 准备或刷新 WSL 源码树（`/home/administrator/chromium-157/src`，基于 pin 提交）。
2. `scripts/build-157-now.sh` —— WSL 内增量原生构建（`out/plan_kirin_pc`）。
3. `scripts/build-stage-157.sh` —— 将引擎产物 staging 到 Windows HAP 工程（`D:\hmos-build-157\chromium-ui`）。
4. `scripts/package-157-hap.cmd` 或 `scripts/package-157-release.cmd` —— 打包未签名 HAP（测试/正式包名）。

分支与路径约定见 [BUILDING.md](BUILDING.md)。DRM 与编解码边界沿用上游项目的媒体策略文档，账号与同步信任模型同样在上游文档中维护。

## 许可

Chromium 主体为 BSD-3-Clause，并包含其它许可下的第三方代码。本构建包含 LGPL 与 MPL 组件。详见 [OPEN_SOURCE_NOTICES.md](OPEN_SOURCE_NOTICES.md)、[SOURCE_OFFER.md](SOURCE_OFFER.md) 与 `licenses/THIRD_PARTY_LICENSES.html`。
