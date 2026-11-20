# HEVC Main10 会把整机锁死 —— 10bit 路线的真实成本

这份文档记录一次**失败且有代价**的实测：把一段 HEVC **Main10** 视频喂给 `meson-vdec` 的 V4L2 M2M 路径，盒子不是降采样、不是报错、不是丢帧，而是**整机硬挂**——ARP 不回、watchdog 不拉、无 Oops、2 分钟不恢复，只能拔电。

它推翻了一条曾经写进 README 的结论（"10bit 能解，只是被降采样成 8bit，画面褪色"）。**那条是错的**，本文是修正后的版本。

---

## TL;DR

| 问题 | 答案 |
|---|---|
| Main10 能在这台机器上解码吗 | **不能**。一喂就整机锁死，SoC 级死锁 |
| 是"解了但截成 8bit"吗 | **不是**。挂掉发生在解码内部，`-f null -`（不出图）一样挂 |
| 是硬件坏了吗 | 不是。同一颗解码器解 8bit HEVC 完全正常 |
| 能靠改格式表修好吗 | 不能。缺的是四件事，其中一件（AMFBC→10bit 解压）mainline 没有实现 |
| 今天该怎么办 | **Sunshine 里不要开 Main10 / HDR**，固定 Main 8bit |
| 想再啃需要什么 | **UART 串口**。没有它连失败原因都拿不到（详见[第 6 节](#6-为什么取证通道全都不通)） |

---

## 1. 环境

| 项 | 值 |
|---|---|
| 设备 | CM311-1A（S905L3A / G12A），2GB RAM，CMA 256MB |
| 系统 | Armbian，`ophub` 内核 `5.15.225-ophub`（mainline staging `meson-vdec`） |
| 用户态 | Debian 12 arm64，`ffmpeg 7:5.1.9`（含 `hevc_v4l2m2m`） |
| 解码节点 | `/dev/video0` = `meson-vdec`（V4L2 M2M，stateful） |
| 实测日期 | 2026-11-20 |

解码器自报能力（崩溃前采集，可信）：

```
$ v4l2-ctl -d /dev/video0 --list-formats-out
    [HEVC]          ← 输入：HEVC 可以
$ v4l2-ctl -d /dev/video0 --list-formats
    [NM12]          ← 输出：只有 NV12M，没有 P010 / 10bit 容器
```

---

## 2. 复现

> **警告：以下命令会让整机锁死，必须拔电恢复。**
> 硬掉电可能丢数据——本次实测后，U 盘上的 8bit 样本文件就消失了（`ext4 data=writeback`，脏页未落盘）。
> **在没有 UART 串口的情况下不建议复现**，见[第 6 节](#6-为什么取证通道全都不通)。

### 2.1 造样本

```bash
apt-get install -y ffmpeg

# Main10（10bit 4:2:0）
ffmpeg -y -f lavfi -i "testsrc2=size=1920x1080:rate=60:duration=3" \
  -pix_fmt yuv420p10le -c:v libx265 -preset ultrafast -crf 18 \
  -x265-params log-level=error -b:v 0 m10_1080p60.mp4

# 8bit 孪生对照（只改 -pix_fmt）
ffmpeg -y -f lavfi -i "testsrc2=size=1920x1080:rate=60:duration=3" \
  -pix_fmt yuv420p -c:v libx265 -preset ultrafast -crf 18 \
  -x265-params log-level=error -b:v 0 m8_1080p60.mp4
```

样本属性（`ffprobe` 确认）：`codec_name=hevc`、`profile=Main 10`、`pix_fmt=yuv420p10le`、1920x1080、60fps、180 帧、约 6.3 MB。

### 2.2 喂给硬件解码器

```bash
# 先跑 8bit 对照组（应当成功）
ffmpeg -c:v hevc_v4l2m2m -i m8_1080p60.mp4 -f null -

# 再跑 10bit（整机锁死）
ffmpeg -c:v hevc_v4l2m2m -i m10_1080p60.mp4 -f null -
```

### 2.3 结果

| 输入 | 结果 |
|---|---|
| `m8_1080p60.mp4`（Main） | 正常解完，退出码 0 |
| `m10_1080p60.mp4`（Main 10） | **整机锁死**：SSH 断、ping 不通、ARP 不回应，2 分钟内无任何恢复，只能断电重插 |

注意 `-f null -` 表示**不写任何输出**——不涉及 DRM、不涉及 HDMI、不涉及显示。**崩溃发生在解码器内部**，与出图路径无关。

---

## 3. 失败现象：不是报错，是消失

- 没有任何用户态错误输出，`ffmpeg` 连一行都没来得及打印；
- 内核**没有 Oops / panic**，console 上没有栈；
- watchdog **没有触发**（说明不是单纯的 CPU 饿死，而是总线/内存子系统被打死）；
- 网络先断（ARP 层就没了），说明中断处理也已停止；
- 断电重启后，`journalctl -b -1` 为空——**日志根本没留下**（journald 当时是易失的，见第 6 节）。

这种"无 panic、无 watchdog、网络先死"的组合，在 Amlogic 平台上通常指向 **AXI 总线挂死或 DMA 写到非法物理地址**，而不是软件异常。

---

## 4. 为什么会这样：10bit 走的是 MMU + FBC，不是"多两个 bit"

在 mainline `codec_hevc_common.h` 里，10bit 的三个开关是一起打开的（`pixfmt` 为 HEVC、`is_10bit=1`）：

```c
static inline int codec_hevc_use_fbc(u32 pixfmt, int is_10bit)        { return is_10bit; }
static inline int codec_hevc_use_downsample(u32 pixfmt, int is_10bit) { return is_10bit; }
static inline int codec_hevc_use_mmu(u32 rev, u32 pixfmt, int is_10bit)
{
    return rev >= VDEC_REVISION_G12A && codec_hevc_use_fbc(pixfmt, is_10bit);
}
```

即：**10bit = 帧压缩写入（AMFBC）+ MMU 页表 + 内部降采样**。这三件事在 8bit 路径里一件都不开，所以 8bit 稳、10bit 死，是两条不同的硬件路径，不是同一路径的参数差别。

### 4.1 10bit 额外要的东西（按 1080p 估算）

| 对象 | 大小 | 来源 |
|---|---|---|
| 每输出 buffer 的 `fbc_buffer` | ≈ 4.2 MB（64×32 块 × 4096 B，约 1020 块） | `codec_hevc_common.c` 用 `amvdec_amfbc_size()` 向 `dma_alloc_coherent()` 申请，随 capture buffer 数量成倍增加 |
| `mmu_header` | 0x48000（288 KB） | 同上 |
| `mmu_map` | 0x4800（18 KB ≈ 4608 个页表项） | `fill_mmu_map()` 逐项填 `fbc_buffer_paddr >> PAGE_SHIFT` |
| 解压开关 | `HEVCD_MPP_DECOMP_CTL1 BIT(4)` | `vdec_helpers.c` |

4 个 1080p 输出 buffer 就是 ~17 MB 的 coherent 内存——在 CMA 256MB 里能申请到（实测开机时 CMA 分配失败过 10 次，但流本身能跑），所以**不是"申请不到内存"这么简单**。

### 4.2 三个可疑点（候选，未定性）

1. **`mmu_map` 容量贴上限。** 4608 个页表项，1080p10bit 用 ~1050 项，4K10bit 约 4083 项——已经贴着 4608 的天花板。越界写页表 = DMA 到任意物理地址 = 正是"无 panic 硬挂"的形状。
2. **分配与释放的尺寸口径不一致。** `free_fbc_buffers` 用 `sess->bitdepth` 计算尺寸，而分配时用的是 `is_10bit` 参数。源中途变化（resolution change）会让两者错配 → 释放错尺寸 → 堆/CMA 区被破坏。
3. **`setup_buffers` 每次 resume 重新分配 `mmu_map` 且不释放。** 反复启停会持续泄漏 coherent 内存，最终把 CMA 吃干净（表现会是分配失败，不是这次的挂死，但同样是 bug）。

> 这三点都必须靠栈才能定性，而栈需要 UART。**没有证据之前不要动这些代码**——盲改一个能锁死 SoC 的路径，代价是每次试错都要拔电。

---

## 5. 缺的不是"一个格式"，是四件事

即使把上面的 bug 全修掉，**10bit 输出**仍然不成立。真正的缺口是：

| 环节 | mainline 现状 | 缺什么 |
|---|---|---|
| 10bit 解码 | 有（今天证明了它甚至能解到锁死） | 修 bug（第 4.2 节） |
| AMFBC → 10bit 帧（解压） | **没有**（`meson_osd_afbcd.c` 是 OSD 的 AFBC，不是视频的 AMFBC） | 需要重写 vendor `vpp` 的等价模块，**格式无文档** |
| VIU 支持 P010 | 没有，plane 只吃 NV12 / RGB888 | 内核 DRM 侧新增格式 + 色彩管理 |
| HDMI 10bit 输出 | 没有，`meson_dw_hdmi_out_bus_fmts` 只有 YUV8 / UYYVYY8 | 增加 10bit bus format + 深色输出 |
| HDR 元数据 | **有**（dw-hdmi 挂 `HDR_OUTPUT_METADATA`，`max_bpc` 也在） | 不缺，但没东西可承载 |

最后一行值得单独说：**HDR 的信令 mainline 已经有了，缺的是它要承载的 10bit 像素**。现在把 HDR 元数据发出去，输出仍是 8bit NV12，等于给电视贴个假标签——比不贴更糟。

---

## 6. 为什么取证通道全都不通

这是本文最该被记住的部分：**这次挂机什么证据都没留下**。逐条排查过：

| 通道 | 结果 | 原因 |
|---|---|---|
| `pstore` | 空 | cmdline 里**没有 `ramoops`**，内核没有预留崩溃区 |
| `journalctl -b -1` | 空 | journald 是**易失模式**（`/var/log/journal` 不存在），重启即丢。**已改 `Storage=persistent` 并重启 journald** |
| netconsole | 配成功了，**0 个包** | `eth0` 是 USB 千兆网卡（RTL8153 / `r8152`），netconsole 的 netpoll 在这种驱动上发不出去。同机用普通 UDP 打向监听端能收到，netconsole 不能——排除防火墙、排除配置 |
| dmesg | 只有 vdec 模块加载那一行 | 崩溃发生在运行期，没有留下 ring buffer 内容 |
| 串口 | **未接** | cmdline 里其实已经有 `console=ttyAML0,115200n8`，只缺一根 USB-TTL 线 |

结论：**下一次想拿到栈，必须先接 UART**（CH340 / CP2102 / FT232 均可，接 GND / TX / RX 三根），否则重复试验只是重复白挂，并且每次都在赌 eMMC 的文件系统（本次已丢过一个测试文件）。

---

## 7. 如果你还是想推进

正确的顺序（不要跳步）：

1. **接 UART**，确认 `console=ttyAML0,115200n8` 有输出；
2. 把样本降到 **720p、单帧、Main10**，先确认最小触发条件（是否与分辨率/帧数相关）；
3. 拿到栈后，对照第 4.2 节定位是 MMU 页表、FBC 缓冲还是解压器；
4. 只有第 3 步定位了，才谈"改代码"。

反过来的顺序（先改代码再试）在这台机器上是不可接受的：每次失败都要拔电，且可能损坏文件系统。

---

## 8. 替代路线：vendor 栈的 10bit 是另一套东西

CoreELEC（kernel 4.9）能播 10bit/HDR，**不是因为它的 `meson-vdec` 更好**，而是因为 G12A 上这一整套能力只存在于 4.9 的 BSP 里：

- 解码走 `amcodec`（`/dev/amstream_*` ioctl），不是 V4L2 M2M；
- 10bit 解压 + 输出在 `vpp` / `amvideo`；
- HDR infoframe 由 `amhdmitx` 从播放器传入的 `hdr_info` 生成。

所以：

| | 这台（mainline 5.15） | CoreELEC（vendor 4.9） |
|---|---|---|
| 10bit 解码 | 会锁死 | 能（另一条代码路径，与本文的 bug 无关） |
| 10bit 输出 / HDR | 无 | 有（且是 Kodi 播放器路径） |
| 零拷贝 + DRM 提交 | 有 | **无**（没有视频 plane，latch 在驱动里） |
| 延迟可测/可控 | 有（`lat`/`miss`、2ms 有界等待） | **无** |

**两条路不能混**：CE 上真正给你 10bit+HDR 的是 Kodi addon，不是自编译的 moonlight-embedded 客户端。用这个客户端去 CE 上求 10bit，方向本身是错的。

---

## 9. 安全口径（必须遵守）

1. **Sunshine 里不要开 Main10，也不要把 HDR 打开**。只要 host 按 Main10 发流，盒子会在开流几秒内整机锁死。
2. 已经改过 Sunshine 配置的，**先改回 Main（8bit）再连接**。
3. 判断当前流是什么 profile：客户端日志里的 `streaming '...' (... h265, ...)` 只说明编码器，**不说明 profile**；要看 Sunshine 的 `Latest Session` 或 `ffprobe` 抓包。

---

## 10. 对应到上游代码的文件清单

| 文件 | 相关点 |
|---|---|
| `drivers/staging/media/meson/vdec/codec_hevc_common.h` | `codec_hevc_use_fbc` / `use_downsample` / `use_mmu` |
| `drivers/staging/media/meson/vdec/codec_hevc_common.c` | fbc buffer / mmu_header / mmu_map 的分配与释放、`fill_mmu_map` |
| `drivers/staging/media/meson/vdec/codec_hevc.c` | `setup_buffers`、解压开关 |
| `drivers/staging/media/meson/vdec/vdec_helpers.c` | `amvdec_amfbc_size()`、`amvdec_src_change()`（`sess->bitdepth` 赋值处） |
| `drivers/gpu/drm/meson/meson_plane.c` | plane 支持的格式表（无 P010） |
| `drivers/gpu/drm/meson/meson_dw_hdmi.c` | `meson_dw_hdmi_out_bus_fmts`（仅 8bit） |

以上对应 `unifreq/linux-5.15.y` 分支，与 `ophub` 内核基本一致。

---

## 附：一条被推翻的旧结论

README 曾写：

> **10bit 源会丢色深**：`meson-vdec` 只输出 `NM12`（8bit），没有 P010，驱动内部降采样，HDR 内容能解但褪色成 SDR，不是花屏也不是失败。

这个判断是从 `codec_hevc_use_downsample()` 的返回值推出来的，**没有实测**。实测结果是整机锁死。已在 README 中修正并指向本文。

留在这里的意思是：**"驱动里有个函数看起来会做 X"和"这条路径真的能跑"，中间隔着一次实测。**
