# hdc 诊断清单（凤凰资讯"打开慢 + 滑动掉帧"）

> 手机在手边时按顺序跑。目标是**一次拿到能定位的证据**，不用再反复打诊断包。
> 当前引擎已内置两处落盘（见文末），hdc 通了也可以直接拉。

---

## 0. 先确认能连

```bat
hdc list targets
```

- 有设备号 → 继续
- `[Empty]` → 手机没开 USB 调试 / 未授权 / 需 `hdc kill -r` 重启服务

记录包名（debug 包）：`com.orbira.browser11`

---

## 1. 清空日志，然后**手动操作**触发问题

```bat
hdc shell hilog -r
```

清空后，在手机上：打开凤凰那篇 → 慢加载完 → **上下滑 5 秒**。

```bat
hdc shell "hilog" > D:\aura-hilog.txt
```

（体量可能较大；只想看关键行可用下面的过滤版）

**关键行过滤版**：

```bat
hdc shell "hilog" | findstr /i "AuraShell adblock VSync browser_controls viewport inset Vulkan did\ stop"
```

### 这些行分别回答什么

| 日志片段 | 判读 |
|---|---|
| `AuraShell JIT available` / `disabled` / `unavailable` | JIT 状态（已用落盘确认是 available，正常） |
| `[adblock] renderer check type=… url=…` | 凤凰打开时有多少资源在过广告检查。**若刷出十几条 = 每个资源都多一次 IPC 往返** |
| `[adblock] renderer filter pipe disconnected, skip` | 广告管道没连上（= 没在拦，不影响速度） |
| `OHOS VSync: actual interval=` | 屏幕真实刷新间隔（8.3ms≈120Hz / 16.7ms≈60Hz） |
| `OHOS VSync: requested rate=` / `rate request failed expected=` | 帧率请求是否被系统拒绝。**这条最可能解释"顿"** |
| `OHOS browser controls: dropped settling ratio` | 顶栏比例事件是否被丢弃 |
| `OHOS viewport inset: resent bottom=` | 是否在反复重发视口内距（会触发 resize） |
| `OHOS nav start / finish`、`did stop loading: visible=` | 加载分段耗时，区分网络慢还是渲染慢 |
| `OHOS phone Vulkan: failed` | Vulkan 尝试过并失败回退 |

---

## 2. 抓 trace（**最有力，一次定位**）

滑动的**同一时刻**执行：

```bat
hdc shell hitrace -t 10 -b 32768 -o /data/local/tmp/t.ftrace gfx view sched freq
hdc file recv /data/local/tmp/t.ftrace D:\
```

拿 `D:\t.ftrace` 拖进 https://ui.perfetto.dev 打开，重点看：

- **renderer 主线程**是否有长任务（>16ms）
- **Compositor / Viz** 每帧是否超时
- **GPU 线程**是否有排队
- 哪一段占了大头，就是根因所在层

---

## 3. 看线程 CPU（判断"算不过来"还是"在等待"）

```bat
hdc shell "pidof com.orbira.browser11"
hdc shell "top -H -p <上一步的pid>"
```

滑动时看：
- renderer 主线程 CPU 打满 → 计算密集（Blink/JS/布局）
- 各线程都空转 → 在等 IPC 或 vsync

---

## 4. 直接拉引擎落盘诊断（省掉手动点复制）

```bat
hdc file recv /data/storage/el2/base/files/aura-viz-fps.txt D:\
hdc file recv /data/storage/el2/base/files/chromium-profile/aura-jit-diag.txt D:\
```

- `aura-viz-fps.txt`：`frames / mean_ms / fps / p50 / p95 / max / jank33`（每 120 帧刷新）
- `aura-jit-diag.txt`：JIT 探测结果

⚠️ 普通 `hdc shell` 是 shell 用户，读应用沙箱**可能没权限**。失败就用手动方式：
设置 → 高级 → 复制帧率诊断（会把两个文件内容一起拼出来）。

---

## 5. 判读路线（拿到数据后怎么走）

```
viz fps ≈ 120 且 jank33=0
   → 合成没丢帧："顿"不是丢帧，转查滚动动画 / 输入链路 / 视觉滞后

viz fps 低 或 jank33 高
   → 确认真丢帧，再用 trace 区分：
       renderer 主线程长任务 → Blink/JS/布局（继续查 157 vs 155 的上游差异）
       GPU 线程排队       → 光栅化/纹理上传（注意本机 libohos_video_overlay.so 只有 2272B stub，缺 NDK）
       Viz 合成超时       → 合成层
```

---

## 6. 已排除项（别重复查）

| 假设 | 结论 | 依据 |
|---|---|---|
| Vulkan | 排除 | `IsOhosPhoneVulkanEnabled()` 首行 `if (!IsOhosPhoneGpuChild()) return false;`，手机 in-process-gpu ⇒ 开关空转 |
| ArkUI 主线程 | 排除 | DisplaySync 实测 119~120fps、P95 8.3ms |
| JIT 降级 | 排除 | 落盘：`before_avail=1 after_avail=1 fallback_applied=0 js_flags=[]` |
| 页内钉住 | 排除 | 155 加了钉住后凤凰仍不顿；157 禁钉住后仍顿 |
| 控件命令 / ratio 推送 | 排除 | 拦截后无改善 |
| `TreesInViz` 等 feature | 排除 | 加上后无改善 |
| adblock renderer throttle | 排除 | 155 引擎该项与我们 157 **二进制完全一致**（adblock=26 / renderer check=1 / decision_throttle=1），155 不顿 |
| 引擎启动配置 | 排除 | 155/157 的 `ohos_chrome_main_runner.cc` 与 `aura_shell` 目录**逐字节相同** |
| 编译参数 | 排除 | 两条线 `args.gn` 相同（`optimize_for_size=true` 等） |
