# 调优决策与踩坑记录

这份文档解释「为什么配置是这样」，尤其是那些反直觉、改错就出问题的地方。改任何配置前先读这里。

---

## 1. 锁频：为什么是 1.704GHz，而不是 performance

**踩过的坑**：一开始用 `schedutil` 动态调频。游戏过程中随机卡死，日志里出现：

```
NETDEV WATCHDOG: eth0 (meson8b-dwmac): transmit queue 0 timed out
```

**根因**：schedutil 运行期调频调用链 `sugov_work → dev_pm_opp_set_rate → clk_set_rate → meson_clk_pll_set_rate` 会改 6GHz 的 `sys_pll_dco`，长时间持有 regmap 自旋锁，卡住同芯片的 `meson8b-dwmac` 网卡 → 网卡 reset → Moonlight 控制流断开 → 卡死。

**解法**：静态锁单频 `userspace` governor，`min=max=setspeed=1704000`。运行期零 PLL 改动，问题消失。1704000 是 1.5G（1512000）与 1.9G（1908000）之间的中间可用档；串流 idle >90%，没有任何性能损失。

**为什么不用全核 performance**：原厂被动散热压不住，全核高频会触发热降频，反而更掉帧。

### 温度守护（状态机，常态零写频）

- >70℃ → 降到 1512000（保命）
- 只有真正 HOT 过之后、<55℃ 才恢复 1704000
- 10 秒轮询；健康态**不写任何 sysfs**，不碰 PLL
- 实现：`scripts/moonlight-autotune.sh` 的 `ensure_lock()`

### 开机被覆盖的两次修复（都是真踩过的）

1. `/etc/default/cpufrequtils` 原本 `ENABLE=true` / `GOVERNOR=schedutil`，LSB 服务开机在 autotune 之后把 governor 改回 schedutil。**已改 `ENABLE=false`，永远不要重新启用。**
2. 更隐蔽的一次：真正元凶是 `loadcpufreq.service`——开机加载 cpufreq 模块时把 governor 初始化成 ondemand，而 autotune 抢在模块加载前 apply，随后被重置；ondemand 下 `scaling_setspeed` 不可写，温控守护失效。解法：`moonlight-autotune.service.d/10-after-cpufreq.conf` 加 `After=loadcpufreq.service ...` + `Wants=loadcpufreq.service`，并由 `ensure_lock()` 每 10s 自检自愈。

验证：`journalctl` 里不应出现 `LOCK REPAIR:`；`scaling_governor` 四核都是 `userspace`，cur/min/max 都是 1704000。

---

## 2. 四核分核：音频 IRQ 的位置是试出来的

最终映射（每次启动 Moonlight 自动应用，见 `scripts/moonlight-cpu-map.sh` / `moonlight-irq-affinity.sh`）：

| 核心 | Moonlight 线程 | 中断 / 内核线程 |
|---|---|---|
| CPU0 | 主线程、控制/输入、AudioRecv/AudioPing、SDLHotplugALSA | sugov:0、ksoftirqd 等杂项 |
| CPU1 | SDLAudioP2（ALSA 播放线程，单独一核） | — |
| CPU2 | VideoDec、ReqIdrFrame、InvRefFrames | IRQ 15 HDMI / 18 audio / 21 CEC / 24 vdec / 25 esparser / 26 meson + 线程化 handler |
| CPU3 | VideoRecv、LossStats、VideoPing | IRQ 14 eth0 + napi/eth0-* |

**坑 1**：音频 IRQ（18）不能放 CPU1——RT50 的 IRQ 线程会饿死同核 RT30 的播放线程 → ALSA underrun。放 CPU2 后归零。
**坑 2**：把 `AudioRecv/AudioPing/SDLHotplugALSA` 和 `SDLAudioP2` 挤同一核也会 underrun，必须拆开。
**坑 3**：只改硬中断 `/proc/irq/N/smp_affinity` **不会**移动线程化 handler（`irq/15-*`、`napi/*`），必须单独 pin 那些内核线程的名字。

收益不是 IPI 下降（拆开后跨核唤醒是必然的，IPI 没降），而是四核均衡 + 消除同核 RT 饿死。延迟大头是显示扫描等待（`dec≈0.5ms`，`lat≈17ms` 的 vblank 地板），见 `reports/`。

---

## 3. 低延迟参数

`scripts/moonlight-latency-apply.sh` 设置网络/调度相关 sysctl 以及 TX/RX 线程优先级。其中 TX 重试次数从 `seq 1 12` 压到 `seq 1 1`（`.bak-txretry` 是改前备份），实测开机延迟适用从约 3.2s 降到 0.5s。RX/线程化/sysctl 的参数保持原样，不要动。

---

## 4. 日志写内存（降 eMMC 磨损 / 抗掉电）

串流机长期运行、可能直接断电，减少写盘：

- `/etc/systemd/journald.conf.d/10-volatile.conf`：`Storage=volatile` + `RuntimeMaxUse=32M`（`/run` tmpfs 只有 195M，不能设 200M）
- `rsyslog.service` 已 disable（原本会把日志再写一份到 eMMC）
- `/var/log/moonlight-*.log` 是服务自身写的，**不受影响**，排障靠它们

**影响**：重启/掉电后 `journalctl -b` 没有历史日志。这是预期行为，不是故障。

---

## 5. initrd：换 zstd + 深度精简

实测这块机器上 43MB 未压缩 initrd：gzip 解压约 808ms，zstd 约 350ms（快 2.3 倍）。两处改动必须同步：

1. `/etc/initramfs-tools/initramfs.conf`：`COMPRESS=zstd`
2. `/etc/initramfs/post-update.d/99-uboot`：mkimage `-C gzip` → `-C zstd`（**只改前者会因头部压缩标记不匹配而起不来**）

新增 `config/initramfs-hook-zz-slim`：删 plymouth 图形栈、udev hwdb.bin（11MB）、bootsplash、dhclient，再多遍迭代按 `DT_SONAME` vs `DT_NEEDED` 剪除孤儿库。结果 uInitrd 16MB → 7.4MB，解压后 43MB → 16MB，动态库 119 → 43。

**坑**：库清理必须按 SONAME 比对，不能用文件名比对——`libcap.so.2`（NEEDED）≠ `libcap.so.2.44`（真实文件名），用文件名会把 udev/btrfs 依赖的库误删导致起不来；且单次扫描清不干净 so 互相引用的「假存活」，要多遍迭代到收敛。

重建：`update-initramfs -u -k 5.15.225-ophub`。恢复：先还原 conf 和 99-uboot 再重建，或用备份的 initrd/uInitrd。

---

## 6. CEC 联动

`scripts/cec-tv-wake` 两种模式：

- **开机模式**（timer 触发）：等 `mesondrmfb` 出现后发 `IMAGE_VIEW_ON` 唤醒电视，并在 +4/+8/+12s 重发 `ACTIVE_SOURCE phys-addr=0x4000` 切到盒子口（物理地址动态读拓扑，盒子插 HDMI4 → 4.0.0.0 → 0x4000；重发是电视唤醒慢，实测需要）。
- **串流模式**（`cec-tv-wake stream`，由 autostart wrapper 在每次串流时触发）：跳过 fb0/HPD 等待，立即切端；用 `flock -n /run/cec-tv-wake.lock` 与开机序列互斥。

OSD 名设为 `Moonlight`（`--playback --osd-name Moonlight`）。

**坑**：切端若发生在盒子还没出图时（DRM 起来前约 9-10s），电视切过来看到空信号，看起来像「切错口」。所以开机模式必须等 fb0。

---

## 7. 空闲关机

`/usr/local/bin/idle-poweroff` 每段时间检查：「无串流 + 无配对握手 + 无 SSH 登录 + 无 hold 文件」持续 `IDLE_POWEROFF_MINUTES`（默认 30）就关机。用 uptime 而非 wall clock（防 NTP 跳变误判）。临时禁用：`touch /run/idle-poweroff.hold`。调试：`IDLE_POWEROFF_DRY_RUN=1 idle-poweroff`。

> 注意：用户后来改为「每次使用都开机」的定位，但这条看门狗仍保留。连不上盒子时（比如你 SSH 前来不及），先想到它。

---

## 8. 串流参数

由用户明确指定，**不要擅自改**：

- `CODEC=h265`，`WIDTH=2560 HEIGHT=1440 FPS=60`，`OUTPUT=auto`
- 码率历史上有 25M → 32M → 35M → 40M 的 A/B 测试；以配置文件实值和注释为准（当前样例里是 32M，带 A/B 测试注释）
- `OUTPUT=auto` 的含义：按显示器 EDID 选输出模式——4K 屏用 3840x2160@60（VPU 放大），1440p 屏 1:1，1080p 及以下降到 1920x1080@60；串流分辨率始终是 2560x1440，与输出模式无关。
