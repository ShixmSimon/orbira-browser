# 本地原创引擎修改 — 保护机制说明

本目录是「同步上游时绝不丢失」的本地原创引擎改动的**独立保险**。

## 背景
上游 `miramira8295/chromium-hmos` 已重写历史，无法直接 `git merge`，只能文件级跟进。
我们的本地原创引擎修改**没有并进** `patches/chromium-154-harmonyos.patch` 总装件，
而是以独立文件存在（`overlay/` 引擎源 + 几个独立 `.patch`）。
一旦某次上游同步误把这些文件覆盖（例如 `sync-154.cmd` 的 `ff` 成功、或手动复制上游版本），
手感/行为类改动会悄悄丢失。

## 受保护的 4 块原创
| 块 | 内容 | 落点 |
|---|---|---|
| ① UA pin | desktop-site 按站点桌面 UA，对抗状态轮询打回 | `overlay/chrome/.../aura_shell_runtime_bridge.cc/.h` + `shell_store_user_agent_ohos.cc` |

> 注：`navigation_throttles.cc` 已在 `8de67840` 回退为 stock 文件，**不属原创**，已从保护清单移除；UA pin 的实际落点是 `shell_store_user_agent_ohos.cc`（git 历史全是 desktop-site 修复）。
| ② 底部裁切 + paint-hold | 底部固定条不裁切、冷启动/导航间隙不闪 | `patches/ohos-bottom-crop.patch` + `ohos-paint-hold-a/b.patch` |
| ③ touch slop | touch_major==0 导致的 4x tap slop 死区（滑动延迟根因） | `overlay/arkweb/.../ohos_aura_input_router.cc` |
| ④ Vulkan 闸门 | `--ohos-disable-vulkan` 开关原生尊重 | `overlay/ui/ozone/.../ohos_phone_gpu_channel.cc/.h` |

## 三道保险
1. **git 跟踪**：9 个文件全部 `git ls-files` 已跟踪（见仓库），普通 `git` 操作不会丢。
2. **本目录独立副本 + 指纹**：`snapshots/` 是未跟踪副本，`MANIFEST.txt` 记录每个文件的
   `git blob SHA`。即使 `git reset --hard` 或坏合并冲掉工作树，副本仍在（merge 只动跟踪文件）。
3. **sync-154.cmd 守卫**：fetch 后若上游改动了受保护文件，`git diff --quiet HEAD..FETCH_HEAD`
   返回非 0，脚本直接中止，禁止 `ff` 覆盖（见 `sync-154.cmd` 的 `[GUARD]` 段）。

## 事后核验（编译前必跑）
`scripts/verify-originals.sh <chromium-src>` 在打补丁+rsync 之后，对每块在 src 里的唯一标记
字符串做 grep，缺一块即报 `ORIGINALS_VERIFY_FAIL`。`打补丁-引擎.cmd` 已内置调用。

## 还原（万一被覆盖）
```bash
bash local-patches/restore.sh          # 从 snapshots 还原并校验指纹
# 或指定仓库根：
bash local-patches/restore.sh /d/WorkBuddy/鸿蒙Chrome/chromium-hmos
```
还原后务必再跑 `scripts/verify-originals.sh` 确认 src 里标记齐全。

## 新增/修改原创文件时
改完务必：
1. `git add` + `git commit`（保持工作树干净，否则 sync 守卫会拦）；
2. 重新生成快照与指纹：`python` 段见 `scripts/gen-snapshots` 思路，或手动
   `cp` 新文件到 `snapshots/` 并 `git hash-object` 更新 `MANIFEST.txt` 对应行。
