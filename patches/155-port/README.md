# patches/155-port —— 155 升级用的预提取补丁

> 生成：2026-10-23 ｜ 状态：**已对上游 `hmos-155-adapter` 实测通过**（`git apply --check` + 实际应用均成功）

## 这是什么

把「本土独有、上游 155 没有」的两块优化，预先做成可以**直接打在上游 155 同名文件上**的补丁，
省掉升级时再人工比对。**只覆盖 overlay 类里不需要人工合并的两项**；其余项请看
`155升级-本土优化迁移清单.md`（工作区根）。

| 补丁 | 目标文件（仓库根相对） | 内容 |
|---|---|---|
| `ohos-155-touch-slop.patch` | `overlay/arkweb/ohos_nweb/src/aura_shell/ohos_aura_input_router.cc` | 3 处：① 新增 `kDefaultTouchRadiusDip=10.0f` / `kDefaultTouchForce=1.0f` 常量与注释；② 两条触摸分发路径的 `PointerDetails` 补上半径与 force（否则 `touch_major==0`，手势器把 tap slop ×4，8dp 变 ~112px 死区） |
| `ohos-155-vulkan-gate.patch` | `overlay/ui/ozone/platform/ohos/ohos_phone_gpu_channel.h` + `.cc` | 3 处：① 头文件在 `AllowOhosPhoneVulkan()` 后加 `IsOhosPhoneVulkanEnabled()` 声明；② `.cc` 增 `#include "base/command_line.h"` + 函数实现；③ `AllowOhosPhoneVulkan()` 首检由 `IsOhosPhoneGpuChild()` 换成 `IsOhosPhoneVulkanEnabled()` |

## 怎么用（155 到位后）

```bash
# 1) 先切到上游 155 适配层状态（这些 overlay 文件是上游 155 的原版）
# 2) 打补丁（在仓库根执行，路径已带 overlay/ 前缀）
git apply --check patches/155-port/ohos-155-touch-slop.patch
git apply         patches/155-port/ohos-155-touch-slop.patch
git apply --check patches/155-port/ohos-155-vulkan-gate.patch
git apply         patches/155-port/ohos-155-vulkan-gate.patch
# 3) 结果核对
grep -c kDefaultTouchRadiusDip overlay/arkweb/ohos_nweb/src/aura_shell/ohos_aura_input_router.cc   # 期望 3
grep -c IsOhosPhoneVulkanEnabled overlay/ui/ozone/platform/ohos/ohos_phone_gpu_channel.cc           # 期望 2（定义+调用）
grep -n "base/command_line.h" overlay/ui/ozone/platform/ohos/ohos_phone_gpu_channel.cc
```

## 三条注意

1. **不要打在 154 树上**：锚点取的是上游 155 版文件（行号/上下文只对 155 有效），154 用了会冲突——154 已有各自的实现，无需再打。
2. **不要注册进构建脚本**：这两个补丁是一次性迁移工具，不是构建清单成员；`patches/155-port/` 子目录也不会被任何脚本 glob 到（已确认）。
3. **补丁不含上游 155 的新特性**：上游 155 的 `ohos_phone_gpu_channel.cc` 比 154 多 297 行（HDR / output-color / Graphite / 图像分配等），
   补丁只做加法，不打掉上游任何东西。

## 一个待你确认的语义问题

上游 155 新增了 `AllowOhosPhoneGraphite()`（Dawn/Graphite 路径），我们 154 版没有这条路径。
当前补丁只让 `--ohos-disable-vulkan` 管住 `AllowOhosPhoneVulkan()`。
**设置里的「Vulkan 渲染加速」开关是否也应该同时管 Graphite？** 若应该，155 上需要再加一行同款闸门。
