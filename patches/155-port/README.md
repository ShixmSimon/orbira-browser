# patches/155-port —— 155 升级用的预提取补丁

> 生成：2026-10-23 ｜ 最近修正：2026-10-24
> 修正点：`apply-our-155-mods.sh` 跑 touch-slop 报 `No such file` —— 根因是这两个 overlay 补丁
> **既冗余又路径前缀错误**，已从 apply 流程移除（详见下方「overlay 承载的两块」）。

## 这套目录里有什么

| 补丁 | 目标文件（155 src 根相对） | 由谁 apply | 状态 |
|---|---|---|---|
| `ohos-155-bottom-crop-painthold-a.patch` | `content/browser/renderer_host/render_widget_host_view_aura.cc` | `apply-our-155-mods.sh` 第 2 步 | 3-way 重锚产出，需打 |
| `ohos-155-paint-hold-b.patch` | `content/browser/renderer_host/delegated_frame_host.cc` | 同上 | 3-way 重锚产出，需打 |
| `ohos-155-extension-origin.patch` | `third_party/blink/.../resource_request.cc` + `services/network/cors/cors_url_loader.cc` | 同上 | 3-way 重锚产出，需打 |
| `ohos-155-touch-slop.patch` | `arkweb/ohos_nweb/src/aura_shell/ohos_aura_input_router.cc` | **不 apply** | 已在本仓 `overlay/` 内，见下 |
| `ohos-155-vulkan-gate.patch` | `ui/ozone/platform/ohos/ohos_phone_gpu_channel.h` + `.cc` | **不 apply** | 已在本仓 `overlay/` 内，见下 |

## overlay 承载的两块（touch-slop / vulkan-gate）—— 不要 apply

这两块打的是 **overlay 目录里的文件**（miramira 的 `arkweb/ohos_nweb` 与 `ui/ozone/platform/ohos`），
不是谷歌原版 chromium 树里的文件。

- `prepare-local-155.sh` 阶段 5 执行 `rsync -a --checksum --no-times overlay/ "$src/"`，
  把整个 `overlay/` **原样** 拷贝进 155 的 `src/`，落地时**去掉 `overlay/` 前缀**
  （所以 `overlay/arkweb/...` 落到 `src/arkweb/...`，`overlay/ui/ozone/...` 落到 `src/ui/ozone/...`）。
- 本仓 `overlay/` 目录**已经包含**我们对这两个文件的修改（touch-slop 的
  `kDefaultTouchRadiusDip`/`kDefaultTouchForce`，vulkan-gate 的 `IsOhosPhoneVulkanEnabled()`），
  是在 `130cded feat(155): 基于上游155绿头叠加本土引擎优化` 里一并提交进来的。

因此这两个补丁：

1. **冗余**：rsync 已经把改动带进 155 树，再 `git apply` 会报 `already applied`；
2. **旧路径前缀错误**：补丁头里写的是 `a/overlay/...`，但 155 树里文件在 `src/arkweb/...` /
   `src/ui/ozone/...`，`git apply` 会报 `No such file or directory`。

> 2026-10-24 已把这两份补丁头的前缀从 `overlay/...` 改正为根相对（`arkweb/...`、`ui/ozone/...`），
> 仅作**存档/文档**用；它们仍不参与 `apply-our-155-mods.sh`，由 overlay rsync 直接承载。

核对改动是否已在树里（在 WSL 的 155 src 下执行）：

```bash
grep -c kDefaultTouchRadiusDip arkweb/ohos_nweb/src/aura_shell/ohos_aura_input_router.cc   # 期望 3
grep -c IsOhosPhoneVulkanEnabled ui/ozone/platform/ohos/ohos_phone_gpu_channel.cc           # 期望 2（定义+调用）
```

## 真正要 apply 的三块（谷歌原版文件）

这三块改的是谷歌原版 chromium 文件（`content/`、`third_party/blink/`、`services/network/`），
**不在 overlay 里**，所以必须靠 `apply-our-155-mods.sh` 第 2 步叠加：

```bash
# 在 WSL 跑（需两棵树都在：154 用于重锚，155 用于落 patch）
export CHROMIUM_154_SRC=/home/administrator/chromium-work/chromium/src
export CHROMIUM_155_ROOT=/home/administrator/chromium-155
bash /mnt/d/WorkBuddy/鸿蒙Chrome/chromium-hmos-155/scripts/apply-our-155-mods.sh
```

- 第 1 步：3-way 重锚，把 154 的本土修改重锚到 155 基线，产出上面 3 个 `ohos-155-*.patch`。
- 第 2 步：只 apply 这 3 个；touch-slop / vulkan-gate 明确跳过（overlay 已承载）。
- 第 3 步：提示你手动合并 3 个特殊文件（见脚本输出）。

## 三条注意

1. **不要手动 `git apply` touch-slop / vulkan-gate**：它们已随 overlay 落地，重复打会失败。
2. **三块重锚 patch 不要打在 154 树上**：锚点取的是上游 155 版文件，只对 155 有效。
3. **补丁不含上游 155 的新特性**：上游 155 的 `ohos_phone_gpu_channel.cc` 比 154 多 297 行
   （HDR / output-color / Graphite / 图像分配等），我们的 vulkan-gate 只做加法，不打掉上游任何东西。

## 一个待你确认的语义问题

上游 155 新增了 `AllowOhosPhoneGraphite()`（Dawn/Graphite 路径），我们 154 版没有这条路径。
当前 vulkan-gate 只让 `--ohos-disable-vulkan` 管住 `AllowOhosPhoneVulkan()`。
**设置里的「Vulkan 渲染加速」开关是否也应该同时管 Graphite？** 若应该，155 上需要再加一行同款闸门。
