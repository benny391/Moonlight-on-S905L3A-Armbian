# Moonlight-Embedded 客户端延迟优化调研报告

**调研对象**：CM311-1A / S905L3A，Armbian 5.15.225，moonlight-embedded `2.7.1-master-33142e5`（自编译）
**调研范围**：从客户端收到 Sunshine 发出的视频数据包开始，到画面上屏为止的客户端链路
**调研日期**：2026-11-17
**重要声明**：本次调研为**纯只读分析**。未修改设备上任何代码或配置。调研末尾设备 `<BOX_IP>` 已不可达（疑似 `idle-poweroff` 在串流停止 30 分钟后关机），部分结论基于设备离线前的实测数据 + 上游源码交叉验证。

---

## 一、先给结论

1. **在"收包→上屏"这段链路里，标准版 moonlight-common-c 已经做得很"零等待"了**——没有按时间戳刻意延迟、没有固定 10ms 抖动缓冲、没有 vsync 前的帧排队。帧一旦组齐立刻提交解码。这一段能压的空间很小。
2. **你设备上真正的大头不在解码，而在"呈现/显示"环节**：实测 `dec=0.5ms`（解码）vs `lat≈17.9ms`（整链路），解码只占约 3%。剩下约 17ms 中，很大一块是上一帧还在显示、等待刷新周期（一帧 16.7ms @60Hz）。
3. **能带来明显收益的手段，几乎都在客户端二进制之外**：FEC 比例（主机侧）、显示端 Game Mode / 刷新率、包大小与 socket 缓冲。客户端代码内部只有"是否减少一帧排队"这类小改动，收益量级为 1 帧以内。
4. **FEC 是双刃剑**：默认 20% 冗余在干净的有线局域网上是纯带宽浪费，且会拖慢"帧判定完成"的时刻；但降到 0 后任何丢包都要等 IDR 关键帧（延迟尖峰更大）。**在 100M 干净链路上，降到 5–10% 是低风险可试的**——但这是主机侧参数，不在客户端。

---

## 二、客户端收包链路：源码级实测结论

我逐段核对了 `moonlight-common-c`（版本与你二进制里的 `33142e5` 对应）的四个关键文件：

### 2.1 收包线程 `VideoStream.c`
```
recvUdpSocket()  →  AES-GCM 解密 →  RtpvAddPacket()
```
- socket 接收缓冲在 `bindUdpSocket()` 时按 `RTP_RECV_PACKETS_BUFFERED (2048) × (packetSize + RTP头)` 分配，1392 字节包约 **2.8 MB**。这个大小是为了"扛住 2–3 帧的突发"，不是延迟缓冲——**不要盲目加大**，加大只会让拥塞时排队更久。
- 无选择性丢弃、无按时间戳等待。`recvUdpSocket` 的超时 `UDP_RECV_POLL_TIMEOUT_MS` 只用于保活检测，不影响正常帧。

### 2.2 RTP/FEC 队列 `RtpVideoQueue.c`
- `RTP_QUEUE_DELAY 10` 这个常量在 `VideoStream.c` 里**只是定义了**，当前 `RtpVideoQueue.c` 中**完全没有使用**——没有任何 10ms 定时器、sleep 或超时判断。
- 组帧是**事件驱动**的：收到足够数据包（或被 FEC 修复）→ 立刻 `submitCompletedFrame()` → 交给解包器。
- 缺包时不会死等：新帧/新 FEC 块一到，旧的不完整帧直接丢弃并请求 RFI/IDR。
- **结论**：这一层没有"为了拼帧而固定等待"的延迟可优化。唯一的固有开销是 FEC——必须等齐 `bufferDataPackets` 个数据包（或用 parity 修复）才算一帧完整，因此帧完成时刻取决于**最慢到达的那个包**。

### 2.3 解包器 `VideoDepacketizer.c`
- 组好的帧通过 `LbqOfferQueueItem()` 送入一个**上限 15 个 decode unit** 的有界队列（`LbqInitializeLinkedBlockingQueue(&decodeUnitQueue, 15)`）。
- 时间戳（`presentationTimeUs` / `receiveTimeUs` / `enqueueTimeUs`）**只作为统计元数据记录**，没有任何 `presentationTimeUs vs now` 的比较、没有 sleep-until-PTS、没有按显示时间调度。
- 帧一完成（`FLAG_EOF`）立即入队；解码线程 `LiWaitForNextVideoFrame()` 取到就提交。
- **结论**：这一层也没有刻意延迟。15 帧队列是**上限**，只在本机解码跟不上时才堆积。你实测 `dec=0.5ms`、日志里 `pending<=0/1`，说明队列常年只有 0–1 帧——**这里不是瓶颈，改队列深度没有意义**。

### 2.4 解码后端 `src/video/aml.c`（上游版）
- 上游 aml 后端用的是 **libamcodec**（`codec_write()` / `codec_init()`），并设置 `codec_set_freerun_mode(1)`（自由运行，不等 vsync）。
- 但你设备实际加载的是 **V4L2 `meson-vdec` + dmabuf + DRM 零拷贝**（`/dev/video0` 打开、40 个 dmabuf fd、进程 maps 里无 libamcodec），日志格式 `DRM: ... pending<=... lat=... dec=...` 也不是上游内容。**这说明你的自编译二进制用的是改造过的 V4L2/DRM 后端**，与 CoreELEC 社区那套 "video backend drm / capture buffers from the decoder" 同源的可能性很高。
- **这对报告的影响**：下面凡是涉及"改 DRM 呈现逻辑"的建议，都需要先在设备上确认你的 fork 源码，而设备当前离线，我无法验证。**我不会在没看到源码前建议你改这里。**

### 2.5 关键判断：约 17ms 花在哪
你日志的典型值：`DRM: 35.9 fps ... pending<=0/1 drop=0 lat=17.9ms max=32.7ms dec=0.5ms`

| 指标 | 值 | 解读 |
|---|---|---|
| `dec=0.5ms` | 解码耗时 | VPU 硬解，极快，非瓶颈 |
| `pending<=0/1` | 待呈现帧 | 队列几乎空，非排队瓶颈 |
| `lat≈17.9ms` | 整链路 | 恰好接近 60Hz 一帧 16.7ms |
| `fps≈35` | 实际呈现 | 主机只推 ~35fps / 19Mbps |

**推断**：`lat` 的大头是"帧解码完成后，等待上一个显示周期结束 / 等待刷新沿"——即呈现同步（frame pacing / vsync）带来的最多一帧等待。这是 60Hz 显示下无法完全消除的物理量，除非提高刷新率或允许撕裂。

---

## 三、候选优化手段（按收益/风险排序）

> 标注 `[客户端]` 的可在本机做；`[主机侧]` 需改 Sunshine；`[显示侧]` 需改电视/显示器；`[需重编译]` 需改源码并重新构建 moonlight（**本次不动**）。

### A. 无代码改动、收益明确

| # | 手段 | 归属 | 预期收益 | 风险/代价 |
|---|---|---|---|---|
| A1 | **显示设备开 Game Mode / 低延迟模式** | 显示侧 | **最大**。电视后期处理常引入 20–50ms，关掉往往比任何客户端优化都有效 | 无，画质预设可能变化 |
| A2 | **确认盒子输出模式走 1:1 或最少缩放** | 客户端配置 | 每次 VPU 缩放可能引入 1 帧；1440p 屏配 2560×1440 输出可省一次缩放 | 你 `OUTPUT=auto` 已按 EDID 选 1080p/1440p/4K，逻辑合理；先确认实际接的屏分辨率再谈 |
| A3 | **`-remote no` 显式锁定 LAN 模式** | 客户端配置 | 避免 `auto` 误判走 WAN 优化（会改包大小/缓冲策略）。你的主机是 <LAN_IP>，本就该是 LAN | 极低。仅当主机未来改公网 IP 才需改回 |
| A4 | **packetsize 保持 1392** | 客户端/主机 | 100M 链路上 1392 是避免 IP 分片的合理值；**不要为了"减小延迟"调小**（包数变多、pps 升高反而更糟） | —— |
| A5 | **`AUDIO_SAMPLES` 从 512 调到 1024** | 客户端配置 | 主要降 CPU：音频中断从 94/s 减半到 ~47/s，`sugov` 占用从 ~7% 降到 ~3.5%。对**视频延迟几乎无改善** | 音频缓冲延迟从 ~21ms 增到 ~43ms；可能**恶化音画同步**。若已出现 ALSA underrun，增大反而更稳 |

### B. 有收益但要谨慎评估

| # | 手段 | 归属 | 预期收益 | 风险/代价 |
|---|---|---|---|---|
| B1 | **FEC 从 20% 降到 5–10%** | 主机侧 | 干净 LAN 上少发冗余包、帧完成更快到达；100M 链路也更宽松 | 一旦有丢包就会等 IDR，延迟尖峰更大。**你链路当前 0 丢包、19Mbps，是最适合试的环境**。改前先确认主机到盒子无丢包 |
| B2 | **提高刷新率/帧率到 120fps** | 显示+主机+客户端 | 一帧周期从 16.7ms 降到 8.3ms，呈现等待上限减半 | S905L3A 的 VPU / HDMI 是否稳跑 1440p120 未知；主机编码压力翻倍；屏必须支持 |
| B3 | **关掉 Moonlight 的 frame pacing / 允许撕裂** | `[需重编译]`/fork 选项 | 可省掉"等太久的帧"的对齐延迟，理论上亚帧级 | 上游 moonlight-embedded 无此开关；你的 fork 是否有未知。会引入撕裂 |

### C. 明确不推荐 / 无效

| # | 手段 | 原因 |
|---|---|---|
| C1 | 加大 socket 接收缓冲 / `rmem_max` | CoreELEC 那套是给 4K 高码率突发用的，你 100M / 19Mbps 无突发。加大缓冲只会让拥塞时排队更久 |
| C2 | 调 `decodeUnitQueue` 深度（15） | 你的队列常年 0–1 帧，不是瓶颈；调小反而可能因抖动触发 IDR |
| C3 | 在 common-c 里加 10ms 抖动缓冲 | 上游已移除该逻辑（`RTP_QUEUE_DELAY` 成了死常量），加回去等于主动增加 10ms 延迟 |
| C4 | 换回 libamcodec 路径 | 你当前 V4L2 硬解 `dec=0.5ms` 已是极优；换路径无收益且可能退化 |
| C5 | 提 CPU 频率 / min 锁频 | 解码只占 0.5ms，提频不影响这块；当前 49℃、1.9GHz 已够，锁频只剩散热风险 |

---

## 四、最优先的三步（按投入产出）

1. **先确认显示端**：电视/显示器开 Game Mode；确认它原生分辨率和刷新率。这一步零成本、收益最大，且不在 Moonlight 代码内。
2. **主机侧试 `fec_percentage 5`**：你链路实测 0 丢包，当前 20% 冗余在 100M 上属于纯浪费。改前记录基线，改后看 `drop=` 是否仍为 0；若开始丢包/卡顿立即回退。
3. **客户端显式 `-remote no`**：消除 `auto` 误判的可能，配置层面零风险。

以上三步**均不需要改 moonlight 二进制源码**。若你希望进一步压低呈现延迟，需要先让设备上线，并提供/确认你自编译 fork 的源码——尤其是 V4L2/DRM 呈现那一层是否有 frame pacing 开关。在拿到源码前，我不会对二进制做任何改动。

---

## 五、调研方法与证据来源

- **设备实测**（离线前）：`moonlight help` 参数表、进程 maps/fd、`/proc/interrupts`、ALSA `hw_params`、DRM/温度/网络/频率采样、autostart 日志
- **上游源码**：`moonlight-common-c` 的 `VideoStream.c`、`RtpVideoQueue.c`、`VideoDepacketizer.c`、`ControlStream.c`；`moonlight-embedded` 的 `config.c`、`src/video/aml.c`
- **官方配置参考**：Sunshine `advanced_usage.rst`（`fec_percentage` 默认 20、`nv_preset`/`nv_tune` 等）、Moonlight 官方 FAQ 的延迟指标定义
- **社区佐证**：CoreELEC moonlight-embedded 论坛关于 DRM 后端与 socket 缓冲的讨论

**再次声明：本次未修改任何设备代码或配置。**
