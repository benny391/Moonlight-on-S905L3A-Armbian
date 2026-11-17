# Moonlight 显示扫描等待（decode→scanout）延迟压缩可行性调研

日期：2026-11-17 10:19–10:24　设备：<BOX_IP>（CM311-1A / S905L3A，内核 5.15）
性质：**纯只读调研，未修改设备上任何代码或配置。**

---

## 1. 先看清这 16.7ms 到底是什么

### 实测数据（当前会话 PID 12574，连续 15 分钟）

```
DRM: 33.5 fps at 3840x2160 pending<=0/1 drop=0 lat=16.9ms max=27.1ms dec=0.8ms
```

- `lat` 平均 **16.4–17.5ms**，min 8.2ms / max 32.8ms（跨会话统计）
- `dec` 只有 **0.5–0.9ms**
- `pending<=0/1`，`drop=0`

跨会话汇总行也一致：`decode->scanout avg 19.5–25.0ms, decoder avg 0.4ms (queue 1)`。

### 源码确认（设备上的自编译 fork，git `33142e5`）

呈现后端是 `/root/moonlight-embedded/src/video/drmzero.c`，关键事实：

1. **`lat` 的物理含义**（`account_flip()`，第 135–140 行）：
   ```
   double ts  = last_flip_ts > 0 ? last_flip_ts : now_s();
   double lat = (ts - inflight_t[0]) * 1000.0;
   ```
   - `last_flip_ts` 来自 `flip_handler()` 的 **vblank 时间戳**——内核给出的"这一帧真正打到面板"的时刻；
   - `inflight_t[0]` 是 **VPU 解码完成**的时刻（`newest_t = now_s()`）。
   - 所以 `lat = 解码完成 → 上屏`，是纯呈现段，**不含收包、不含解码**。源码注释原话：
     > "scanout is pinned to the refresh rate."

2. **提交方式**（第 839 行）：
   ```c
   uint32_t flags = DRM_MODE_ATOMIC_NONBLOCK | DRM_MODE_PAGE_FLIP_EVENT;
   ```
   **没有** `DRM_MODE_PAGE_FLIP_ASYNC`，没有 tearing/low-latency 标志。全文件 grep ASYNC/TEAR 只命中这一行。
   atomic commit 后必须等下一个 vblank 才 scanout——这就是那 16.7ms 的来源。

3. **队列已经压到最浅**（第 41–48 行注释）：
   > "Flips kept outstanding; the display retires them one per refresh. **One is enough: every extra pending flip is a whole refresh of added latency**, and a remote-desktop client would rather skip a frame than show a stale one."
   ```
   #define MAX_INFLIGHT_DEFAULT 1
   ```
   `pending<=0/1` 印证了这点。源码还主动丢弃堆积的旧帧、只提交最新帧（第 798 行）——这是低延迟串流的标准最优策略。

**结论：这 16.7ms = 60Hz 面板一个刷新周期的等待，是双缓冲呈现的物理节拍，不是排队、不是 CPU 慢、不是 bug。** 这段已经被这个 fork 设计得相当激进（最浅队列 + 丢旧帧 + 只提交最新帧），接近同步呈现的物理下限。

---

## 2. 理论上能压缩它的手段（按可行性排序）

### A. 提高输出刷新率 —— 唯一"无损"但当前不可行
把面板跑到 120Hz，一帧周期从 16.7ms 降到 8.3ms，等待自然减半，且无撕裂。
- **障碍**：EDID 是 SONY TV，当前只协商出 `3840x2160`，实测模式固定 60Hz；设备 `modetest`/`edid-decode` 都存在缺失。
- **附加障碍**：主机当前只推 **33fps**（不是 60），提高刷新率对端到端流畅度收益有限。
- 需换支持 4K120 的显示器和 HDMI 2.1 链路，S905L3A 的 HDMI 是否支持 4K120 存疑。**硬件层面，非配置可调。**

### B. Async page flip / tearing —— 能真正跳过等待，但驱动和代码都不支持
用 `DRM_MODE_PAGE_FLIP_ASYNC` 让解码完立即 scanout，不等 vblank，理论上把这 16.7ms 压到接近 0，代价是**画面撕裂**。这是 PC 端 Moonlight "Disable V-Sync" 的同类手段，游戏场景通常可接受。
- **障碍 1（驱动）**：`/proc/kallsyms` 里**没有** `drm_atomic_async_check`，只有 `drm_atomic_helper_page_flip`；`CONFIG_DRM_MESON=y` 是 build-in 下游驱动，meson DRM 一般不支持 async flip，内核会在 atomic check 阶段拒绝，回退到同步。
- **障碍 2（代码）**：`drmzero.c` 当前 flags 里没有 ASYNC，需要改源码 + 重编译 + 重新部署二进制。
- **障碍 3（约束）**：你明确要求过"别在没有经过我同意就修改代码"。
- 即便可做，撕裂观感是否可接受需要你实测判断。**这是唯一能动摇这 16.7ms 的客户端手段，但门槛最高。**

### C. 更精确地的提交时机 —— 收益有限，风险高
让解码帧赶在当前 vblank 的 commit 窗口内提交，而不是错过后等一整帧。
- 目前 `FRAME_WAIT_MS=8`（HEVC 解码等待）+ 网络抖动，帧到达相位很难稳定卡在 vblank 前。
- `lat` min 8.2ms / max 32.8ms 说明相位有波动，但均值钉在 16.9ms——多数帧是"刚错过"。
- 要动呈现循环的时序逻辑，属于改代码，且对抖动敏感，**不建议**。

### D. 增大 `max_inflight` —— 反效果，别做
把 `MAX_INFLIGHT_DEFAULT` 从 1 调到 2+ 会让帧更早提交、减少丢帧，但源码注释明确说明这是**用延迟换吞吐**：每多一个 pending flip 就多一整帧延迟。当前 `drop=0`，没有丢帧问题，**调大只会让 lat 更差**。

### E. 降低输出分辨率（4K → 1440p/1080p）—— 对 lat 本身几乎无收益
`lat` 是等 vblank，与分辨率无关。但当前是 `2560x1440 → 3840x2160` 硬件放大输出，之前定位卡顿时发现过 `meson_clk_pll_set_rate: pll did not lock` 的 6GHz PLL 事件，疑似与 4K 输出时钟相关。
- 改成 1440p 原生输出**可能**减少 PLL 抖动、降低少数 `max=32ms` 的长尾；
- 但会改变你已确认的显示链路（TV 缩放），且属于"串流参数"范畴——按约定**不动**。

---

## 3. 诚实的结论

1. **这 16.7ms 基本压不下去，除非换硬件或接受撕裂。** 它是 60Hz 显示的物理刷新节拍，代码已经把它优化到同步呈现的下限（最浅队列、零排队、丢旧帧）。上游开发者在源码里就是这么设计的，且明确反对用延迟换吞吐。

2. **真正值得关注的不是这 16.7ms，而是当前 33fps。** 主机只推 33fps（帧间隔 30ms），这 16.7ms 的呈现等待完全被淹没在 30ms 的帧间隔里——玩家感知到的是"不够流畅"，不是这 16.7ms。而且配置里 `BITRATE` 已从 40000 降到 25000、输出从 1080p 变成 4K 放大（见 `/etc/moonlight-autostart.conf` 注释 "was 40000; 1080p display on 100Mbps LAN"）。**把帧率从 33 提到 60，收益远大于抠这 16.7ms。**

3. **显示器 Game Mode 仍是投入产出比最高的手段**（不在客户端，之前报告已提）：电视后处理常引入 20–50ms，远大于这里能抠出的任何数值。

4. **如果一定要试 B（async flip）**：需要先确认 meson DRM 驱动是否支持——最小成本是查驱动源码里 `drm_crtc_funcs.page_flip` / `.atomic_async_check` 是否实现；若支持再改 `drmzero.c` 的 flags 做 A/B。**这些都要你明确同意后才动。**

---

## 附：本次读到的关键源码位置

| 文件 | 行 | 内容 |
|---|---|---|
| `src/video/drmzero.c` | 41–48 | `MAX_INFLIGHT_DEFAULT 1` 及"每多一个 pending flip 多一帧延迟"注释 |
| 同上 | 84–114 | `last_flip_ts` / `flip_handler` / `wait_flip`（vblank 事件驱动） |
| 同上 | 135–140 | `lat = vblank时间戳 − 解码完成时刻` |
| 同上 | 795–806 | 丢旧帧、只保留最新帧 |
| 同上 | 815–864 | `while(icount>=max_inflight)` 等 flip + atomic commit（flags 无 ASYNC） |
| 同上 | 881–889 | fps/lat/dec 统计输出 |
