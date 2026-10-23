# local-pipeline/ — 构建管线的 git 保险副本

本目录是「鸿蒙Chrome 引擎构建管线」脚本的 **git 跟踪保险副本**。原件全部在 git 之外
（工作区根目录与 `D:/hmos-build`），一旦工作区被误删、被清理脚本扫掉、或换机器，
这里的副本加上《引擎侧本地资产总账.md》就是恢复依据。

## 原件位置与作用

| 副本 | 原件 | 作用 | 丢了的影响 |
|---|---|---|---|
| `wb-wsl-stage3d-patches.sh` | 工作区根 | 55 个增量补丁的权威顺序 + overlay 同步 + gn gen（**构建管线的真正核心**） | 补丁顺序知识丢了；可对照 `scripts/ci-incremental-build.sh`（在 git 里）重建，但麻烦 |
| `wb-wsl-stage3c-build.sh` | 工作区根 | WSL 内数小时 native 编译入口 | 中：需按脚本内注释重写 |
| `wb-wsl-stage3e-resources.sh` | 工作区根 | 补编缺失的 pak/locale 并装配引擎运行时进构建树 | 中 |
| `wb-wsl-sync-fixes.sh` | 工作区根 | 把 6 个 overlay 修复文件同步进 WSL src（幂等） | 低（内容都在 overlay git 里） |
| `wb-wsl-save-local-patches.sh` | 工作区根 | 历史上从 src 树导出本地补丁的脚本 | 低（历史工具） |
| `Vulkan开关-一键构建.cmd` + `vulkan-toggle-build.ps1` | 工作区根 | Windows 一键构建总装（rsync overlay→src、清 4 处缓存、拷 .so、打 HAP、核验、读版本） | **高**：整个交付链路的的总装，重建成本最大 |
| `sync-154.cmd` | 工作区根 | 上游同步 + 受保护文件 GUARD（fetch 后禁止 ff 覆盖） | 高：同步上游时失去护栏 |
| `apply-engine-patches.py` | `D:/hmos-build` | Origin 补丁的热修工具（**已降级**：Origin 已固化为 git patch，桌面 5 处已过期，见文件头 STATUS） | 低 |
| `打补丁-引擎.cmd` | `D:/hmos-build` | patcher + verify-originals 二合一（ASCII+CRLF） | 低 |

## 规则

1. **原件优先**：日常只改原件，本目录是保险不是工作区。
2. 改完任何原件，跑 `bash local-pipeline/refresh.sh`，然后
   `git add local-pipeline && git commit`。refresh 会打印 git diff，有输出就是没同步。
3. 判断副本是否过期：跑 refresh.sh 看 diff；或直接对比两边 mtime。
4. 恢复方向是双向的：原件丢了就 `cp local-pipeline/<文件> <原件路径>`。

## 为什么不把脚本搬进 git 当唯一源

脚本之间用绝对路径互相引用（`/mnt/d/WorkBuddy/鸿蒙Chrome/wb-wsl-*.sh`），
且 `vulkan-toggle-build.ps1` 按「脚本与 Chromium 源码树同盘、与 overlay 仓同根」
的假设运行；搬进仓库会断这些引用，还会和上游 `scripts/` 在同步时相撞。
副本方案零风险，代价只是每次改原件多跑一次 refresh。

## 相关

- 《引擎侧本地资产总账.md》（本目录内）：引擎侧本地修改 + 管线资产 + src 树重建 SOP 的全账。
- `../local-patches/`：5 块本地原创引擎修改的独立副本 + 指纹 + restore.sh。
