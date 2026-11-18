# Moonlight on S905L3A Armbian

> Moonlight 串流瘦客户端 · 面向 Amlogic S905L3A（G12A）电视盒的 Armbian 调优方案

把一台百元级安卓电视盒子（CM311-1A / S905L3A / G12A）改造成**开箱即连、零操作的 Moonlight 串流终端**：通电开机后自动发现局域网内的 Sunshine 主机、自动配对、自动串流，掉线或被踢会自动重连。为长时间串流做了硬解、分核、锁频、温控、开机速度和写盘磨损的整套调优。

> 本项目是**这套配置的记录与复刻工具**，不含 Moonlight / Sunshine 的二进制本体（见 [依赖](#依赖)）。所有敏感信息（IP、PIN、密码、UUID）均用 `<...>` 占位，部署前按 [配置](#4-配置) 填写。

---

## 它能做什么

| 能力 | 说明 |
|---|---|
| 开机自动串流 | 等网络/DRM/解码器就绪 → mDNS 发现 Sunshine → 必要时自动配对 → 串流指定 App |
| 永不放弃 | 主机没开、还在启动、串流中被踢（BUSY）、Sunshine 重启——都会自动恢复，无需人守在旁边 |
| VPU 硬解 + 零拷贝 | V4L2 M2M 解码直出 DMA-BUF，导入 DRM 用 overlay plane 扫描，不经过 CPU 拷贝 |
| 四核分工 | 解码/网络/音频分核，中断与线程化 handler 各自绑定，消除同核 RT 饿死 |
| 锁频 + 温控守护 | 静态锁 1.704GHz，运行期零 PLL 改动（规避网卡 watchdog）；>70℃ 降频保命 |
| CEC 联动 | 串流开始时唤醒电视并切到盒子 HDMI 口；OSD 名显示为 `Moonlight` |
| 空闲自动关机 | 30 分钟无串流/无 SSH 自动关机，省电省 eMMC 寿命 |
| 低写盘 | journald 写内存、rsyslog 关闭；initrd 用 zstd + 深度精简，开机更快 |

---

## 与上游的关系（为什么是自编译改版）

这里新增的零拷贝后端是 **out-of-tree** 的：没有进入上游 [moonlight-stream/moonlight-embedded](https://github.com/moonlight-stream/moonlight-embedded)，也不再尝试提交 PR。

上游对该项目的定位很明确——moonlight-embedded 只服务**使用厂商私有接口（amcodec、mpp 等）的老式嵌入式设备**；使用标准 V4L2 解码器 + DRM 渲染的设备，维护者的意见是改用 [moonlight-qt](https://github.com/moonlight-stream/moonlight-qt)。原文见 [PR #932](https://github.com/moonlight-stream/moonlight-embedded/pull/932)（同样是 V4L2 解码 + DRM 出图的思路，2026-05 提交、2026-11 关闭）：

> Moonlight Embedded is really just for those old embedded devices that use bespoke decoding/rendering APIs rather than the standard V4L2 stateful/stateless decoder and DRM renderer.

由此带来三条实际约束：

- **必须自行编译**。发行版仓库或上游仓库里的 `moonlight` 没有这些改动，装上去跑不出零拷贝路径，见[编译 moonlight 改版](#编译-moonlight-改版)。
- **升级靠 rebase**。分支基点固定在上游 `33142e5`（2026-11-11）；上游若改动 `src/sdl.c` / `src/video/sdl.c` / `CMakeLists.txt`，需要自己 rebase，冲突大概率集中在 `src/sdl.c` 那 9 处 DRM 分支。
- **有更省事的替代**。若目标设备能跑 moonlight-qt（有可用 KMS + EGL），它功能更全（HDR、vsync 可调、统计叠加）且跟得上上游。这套改版的价值在于**完全不需要 Qt 运行时**：一个 150 KB 的二进制直接接管显示，没有 X、没有 Wayland、没有窗口管理器。

已知限制（都是驱动侧决定的，不是实现取舍）：

- **10bit 源会丢色深**：`meson-vdec` 只输出 `NM12`（8bit），没有 P010，驱动内部降采样，HDR 内容能解但褪色成 SDR，不是花屏也不是失败。
- **AV1 无硬解**：`meson-vdec` 不支持 AV1，选 AV1 时不会走这条零拷贝路径（本项目固定 `CODEC=h265`）。
- **依赖两件事**：解码器能把 NV12 帧导出为 dma-buf，且 KMS 有能 import dma-buf 的 overlay plane（支持内部缩放更好，本项目 1440p → 4K 就是靠这个白拿的）。

---

## 硬件与软件环境

- **设备**：CM311-1A 电视盒（E900V22C-D 板型），Amlogic S905L3A（G12A），2GB RAM，eMMC
- **系统**：Armbian（Ubuntu 22.04 jammy, btrfs 根分区），`ophub` 内核 `5.15.225-ophub`
- **串流**：moonlight-embedded `2.7.1-master`（**改版自编译**，含 V4L2/dmabuf 零拷贝输出与 HDMI 热切改动，源码见 [benny391/moonlight-embedded](https://github.com/benny391/moonlight-embedded)）+ Sunshine
- **网络**：DHCP（不设静态 IP），mDNS（`_nvstream._tcp`）发现主机
- **显示**：HDMI，默认输出 3840x2160@60（按连接显示器 EDID 自动选择）

---

## 目录结构

```
.
├── README.md                      本文件
├── install.sh                     一键安装/部署脚本
├── config/                        /etc 下的配置与 systemd 单元
│   ├── moonlight-autostart.conf.example   串流主配置（脱敏样例，改成 /etc/moonlight-autostart.conf）
│   ├── moonlight-*.service                systemd 单元（5 个）
│   ├── cpufrequtils                       禁用 cpufrequtils 的 ENABLE=false
│   ├── initramfs.conf                     initrd 压缩=zstd, MODULES=dep
│   ├── initramfs-hook-zz-slim             initrd 深度精简 hook
│   ├── initramfs-postupdate-99-uboot      uInitrd 生成（mkimage -C zstd）
│   ├── journald-volatile.conf             日志写内存
│   └── uEnv.txt.example                   U-Boot 启动参数（脱敏样例）
├── dropins/                       systemd drop-in（服务启动顺序/依赖）
├── scripts/                       /usr/local/bin 下的脚本
│   ├── moonlight-autostart                开机自动连接/重连主脚本
│   ├── moonlight-autotune.sh              锁频 + 温控守护
│   ├── moonlight-cpu-map.sh               逐线程分核（常驻）
│   ├── moonlight-irq-affinity.sh          中断/线程亲和性（oneshot）
│   ├── moonlight-latency-apply.sh         网络/调度低延迟参数
│   ├── cec-tv-wake                        CEC 唤醒电视 + 切 HDMI 口
│   ├── idle-poweroff                      空闲关机看门狗
│   └── box-health                         只读健康检查工具
├── docs/                          设计与踩坑文档
│   ├── HANDOVER.md                        完整运维手册（部署/回滚/验证命令）
│   ├── BOOT-AND-FLOWER-SCREEN.md          开机花屏的定位过程与结论
│   └── TUNING-NOTES.md                    调优决策与踩坑记录（PLL/网卡 watchdog 等）
└── reports/                       调优过程中的实测报告
    ├── moonlight-latency-report.md
    └── moonlight-scanout-latency-report.md
```

---

## 安装

### 依赖

本项目不含二进制本体，以下组件需另行准备：

- Armbian + `ophub` 5.15 aarch64 内核（含 `CONFIG_DRM_MESON`、`CONFIG_RD_ZSTD`）
- **`moonlight` 可执行文件：必须用本项目配套的改版**（源码见 [benny391/moonlight-embedded](https://github.com/benny391/moonlight-embedded)；上游 `irtimmer/moonlight-embedded` `2.7.1-master` + 本项目的 V4L2/dmabuf 零拷贝与 HDMI 热切改动），编译后放在 `/usr/local/bin/moonlight`。原版不含这些改动，跑不出同样的延迟和画质。
- `sunshine` 主机在局域网内运行
- 工具：`cec-ctl`（v4l-utils）、`curl`、`avahi-daemon`、`ethtool`

### 编译 moonlight 改版

```bash
git clone --recurse-submodules https://github.com/benny391/moonlight-embedded.git
cd moonlight-embedded
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_SDL=ON -DENABLE_FFMPEG=ON \
  -DENABLE_CEC=ON -DENABLE_PULSE=ON -DENABLE_X11=OFF
cmake --build . -j4
sudo install -m755 moonlight /usr/local/bin/moonlight
```

- **`--recurse-submodules` 不能省**：`third_party/moonlight-common-c` 是 submodule，不拉下来 CMake 会在 `nanors/rs.c` 处报「Cannot find source file」。
- 基础依赖同上游 README，**额外需要 `libdrm-dev` 和 `libswscale-dev`**（配 `-DENABLE_SDL=ON` 时自动检测）。缺 libdrm 会静默退回普通输出路径，缺 libswscale 则硬解输出无法转 NV12→YUV420P。
- 编译产物需在 `meson-vdec` 可用的内核上运行（本项目的 5.15 ophub 内核）。**解码节点和 DRM 卡都是自动探测的**：扫描 `/dev/video0..63` 找同时支持 `M2M_MPLANE` 且能解 H.264/HEVC 的节点，扫描 `/dev/dri/card0..15` 找有 CRTC + connector 的卡（会跳过 panfrost 这类纯 GPU 节点）。串流日志里会打印 `V4L2: using ...` 与 `DRM: using ...`，可据此确认走的是哪一对设备。

### 步骤

```bash
git clone https://github.com/benny391/Moonlight-on-S905L3A-Armbian.git
cd Moonlight-on-S905L3A-Armbian
# 1. 先填配置（IP / PIN / Sunshine 账号密码 / root UUID）
cp config/moonlight-autostart.conf.example /tmp/moonlight-autostart.conf
$EDITOR /tmp/moonlight-autostart.conf
cp config/uEnv.txt.example /tmp/uEnv.txt
$EDITOR /tmp/uEnv.txt                       # 填 root=UUID=...（fmtedit / blkid 查）

# 2. 以 root 安装（在目标盒子 / 已挂载的根文件系统上执行）
sudo ./install.sh --conf /tmp/moonlight-autostart.conf --uenv /tmp/uEnv.txt

# 3. 重启
sudo reboot
```

`install.sh` 默认把设备当成本机（`/`）；可用 `--root /mnt/armbian` 指向挂载的目标根分区，用于从另一台机器给 eMMC 刷配置。加 `--dry-run` 只打印将要做的操作、不落盘。

开机后验证：

```bash
box-health                                   # 只读健康检查
systemctl is-active moonlight-{autotune,irq-affinity,cpu-map,autostart}.service
tail -f /var/log/moonlight-autotune.log
```

---

## 关键调优决策（速览）

这几条是踩坑换来的，**改动前先读 [TUNING-NOTES.md](docs/TUNING-NOTES.md)**：

1. **禁止全核 performance 锁频**——被动散热压不住，热降频反而更掉帧。静态锁 1.704GHz（1.5G 与 1.9G 之间的可用档），串流 idle >90%，无性能损失。
2. **锁单频是为了规避网卡 watchdog**：schedutil 运行期调频会改 6GHz sys_pll，长时间持锁卡住 `meson8b-dwmac` → `NETDEV WATCHDOG: eth0 tx timeout` → 控制流断。运行期零 PLL 改动。
3. **温度守护常态零写频**：只有 >70℃ 降 1512000、且 HOT 过后 <55℃ 才恢复 1704000。
4. **音频 IRQ 不能放 CPU1**：RT50 的 IRQ 线程会饿死同核 RT30 播放线程 → ALSA underrun。音频播放单独占 CPU1，音频 IRQ 放 CPU2。
5. **`cpufrequtils` 必须保持 `ENABLE=false`**，否则开机把 governor 改回 schedutil，锁频失效。
6. **串流参数由用户定，不要擅自改**——当前 `CODEC=h265`、`2560x1440@60`、`OUTPUT=auto`，码率历史上有 25/32/35/40M 的 A/B 测试，以 `config/moonlight-autostart.conf.example` 里的注释为准。
7. **开机花屏**：定位为电视侧对启动早期信号的响应差异（同盒子换 1080p 显示器不花），不改 U-Boot/内核，详见 [BOOT-AND-FLOWER-SCREEN.md](docs/BOOT-AND-FLOWER-SCREEN.md)。
8. **显示端延迟靠「提交即覆盖」压到一帧**：旧逻辑会锁死在两个周期（32.7ms）且不自愈；现在默认只保持一帧在飞，撞上未扫出就放弃该帧，延迟落在 9.6–24.9ms。代价是每 2–3 分钟有一轮约 30 秒的成簇丢帧（1.4–1.8%）。**不要**用调 host 帧率的方式去修，详见 [moonlight-overwrite-mode-report.md](reports/moonlight-overwrite-mode-report.md)。

---

## 回滚

每个被修改的系统文件在设备上都留有 `.bak-<标签>` 备份。`install.sh` 安装时也会自动生成时间戳备份（`*.bak-install-<timestamp>`）。完整回滚步骤见 [HANDOVER.md](docs/HANDOVER.md) 各章节末尾的「回滚」。

---

## 许可

配置脚本与文档按 MIT 许可发布（见 [LICENSE](LICENSE)）。

本项目依赖的 `moonlight-embedded` 是**修改后自行编译**的版本（上游 `irtimmer/moonlight-embedded`，**GPL-3.0**）。按 GPL 要求，分发二进制须能提供对应源码——**完整改版源码见 [benny391/moonlight-embedded](https://github.com/benny391/moonlight-embedded)**（改动：新增 `src/video/v4l2m2m.c` + `src/video/drmzero.c` 零拷贝后端）。`sunshine` 本体遵循其自身许可。
