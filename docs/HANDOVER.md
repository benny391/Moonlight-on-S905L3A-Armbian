> 本文是从项目维护笔记脱敏而来，作为完整运维手册。`<...>` 是占位符，按你的实际环境填写。

# AGENTS.md — Armbian Moonlight 串流瘦客户端

本工作区维护一台局域网内的 Armbian 盒子（CM311-1A / S905L3A，内核 5.15 aarch64），
专用于 moonlight-embedded 串流。所有调优已部署在设备上，本文件记录编排结构与操作约定，
供后续维护时参考。设备配置文件副本在 `armbian-autotune/` 下。

## 连接方式

- 地址：`<BOX_USER_HOST>`，password `<SSH_PASSWORD>`（弱密码，仅局域网）。
- 本机直连被本地代理拦截，需通过 SSH_ASKPASS 非交互登录。若 helper 不存在先重建：

```bash
printf '#!/bin/sh\necho <SSH_PASSWORD>\n' > /tmp/armbian_askpass.sh && chmod +x /tmp/armbian_askpass.sh
export SSH_ASKPASS=/tmp/armbian_askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    <BOX_USER_HOST> '命令'
```

- 设备配 `IDLE_POWEROFF_MINUTES=30`：串流停止 30 分钟后可能关机，连不上时先考虑这点，不要盲目改配置。

## 核心约束（不要违反）

1. 禁止全核 performance 锁频——原厂被动散热压不住，热降频反而更掉帧。
2. 任何锁频必须配合温度守护（当前：>70℃ 降 1512000、<55℃ 恢复 1704000，常态零写频）。
3. 用户明确要求过：**串流参数保持原样，不要擅自改**。不要改 `CODEC`、`BITRATE`、
   分辨率、FEC、`-platform`/`-codec` 等，除非用户当次明确指示。
4. 改任何设备配置前先备份（惯例：`<file>.bak-<标签>`）。

## 开机编排与依赖

四个服务均 `enabled` 且 `active`。`moonlight-autostart.service`（主串流）通过
`/etc/systemd/system/moonlight-autostart.service.d/` 下的三个 drop-in 拉起前置服务：

| drop-in | 前置服务 | 作用 |
|---|---|---|
| `10-autotune.conf` | `moonlight-autotune.service` | CPU/DDR/VPU 调优 + 温度守护 |
| `20-irq-affinity.conf` | `moonlight-irq-affinity.service` | 中断亲和性（oneshot） |
| `30-cpu-map.conf` | `moonlight-cpu-map.service` | 逐线程分核（常驻 watch） |

各服务为 `Wants=` + `After=`，保证顺序：调优 → 中断 → 分核 → 串流。

## 四核分核方案（每次启动 Moonlight 自动应用）

**这一点已核实：是的，每次启动都会应用，有两层保障——**

1. **整机启动**：三个 drop-in 的 `Wants/After` 保证 `irq-affinity`（oneshot，开机设一次）
   和 `cpu-map`（`Type=simple` + `Restart=always` 常驻）先于串流启动。
2. **串流进程重启（不重启整机）**：`moonlight-cpu-map.sh` 是常驻循环（`INTERVAL=1`，每秒），
   检测到新的 `[m]oonlight stream` PID 就打日志 `stream PID ... detected - applying CPU map`
   并逐线程重贴 affinity。中断亲和性是内核状态，不随进程重启丢失，故 oneshot 足够。

### 线程/中断映射（最终验证状态）

| 核心 | Moonlight 线程 | 中断 / 内核线程 |
|---|---|---|
| CPU0 | 主线程、控制/输入、`AudioRecv`、`AudioPing`、`SDLHotplugALSA` | `sugov:0`、ksoftirqd 等杂项 |
| CPU1 | `SDLAudioP2`（ALSA 播放线程，单独一核） | — |
| CPU2 | `VideoDec`、`ReqIdrFrame`、`InvRefFrames` | IRQ 15 HDMI / 18 audio / 21 CEC / 24 vdec / 25 esparser / 26 meson，及其线程化 handler `irq/*` |
| CPU3 | `VideoRecv`、`LossStats`、`VideoPing` | IRQ 14 eth0 + `napi/eth0-*` |

- 启动脚本 `/usr/local/bin/moonlight-autostart` 只保留 `chrt -f 30`（SCHED_FIFO prio 30），
  **已去掉**整进程 `taskset -c 0-1`；逐线程绑定完全交给 `cpu-map`。
- 原脚本备份：`/usr/local/bin/moonlight-autostart.bak-cpumap`。

### 相关文件（设备路径 / 工作区副本）

- `/usr/local/bin/moonlight-cpu-map.sh` + `/etc/systemd/system/moonlight-cpu-map.service`
  → 副本 `armbian-autotune/four-core/`
- `/usr/local/bin/moonlight-irq-affinity.sh` + `/etc/systemd/system/moonlight-irq-affinity.service`
  → 副本 `armbian-autotune/four-core/`
- 日志：`/var/log/moonlight-cpu-map.log`、`/var/log/moonlight-irq-affinity.log`

### 关键经验（踩过的坑）

- 音频 IRQ（18）**不能放 CPU1**：RT50 的 IRQ 线程会饿死同核的 RT30 播放线程 → ALSA underrun。
  最终放在 CPU2。
- 把 `AudioRecv`/`AudioPing`/`SDLHotplugALSA` 与 `SDLAudioP2` 挤同一核同样会 underrun；
  拆开（前者 CPU0、后者 CPU1）后 underrun 归零。
- 只改硬中断 affinity **不会**移动线程化 handler（`irq/15-*`、`napi/*` 等），必须单独 pin 线程。
- 分核后 IPI 并未下降（约 2300/s）：流水线拆开后跨阶段唤醒本就跨核。收益是四核均衡 +
  消除同核 RT 饿死，不是 IPI。延迟大头是显示扫描等待（`dec≈0.5ms`，`lat≈17ms`）。

### 回滚

```bash
systemctl disable --now moonlight-cpu-map.service moonlight-irq-affinity.service
cp -a /usr/local/bin/moonlight-autostart.bak-cpumap /usr/local/bin/moonlight-autostart
rm -f /etc/systemd/system/moonlight-autostart.service.d/{20-irq-affinity,30-cpu-map}.conf
systemctl daemon-reload && systemctl restart moonlight-autostart.service
```

## 温度守护 / CPU 调优（moonlight-autotune）

- `/etc/moonlight-autotune.sh` + `moonlight-autotune.service`，日志 `/var/log/moonlight-autotune.log`。
  备份：`/etc/moonlight-autotune.sh.bak-lockpll`（锁频前的 schedutil 版本）。
- **2026-11-17 起改为静态锁频（重大根因修复）**：governor=`userspace`，
  `LOCK_FREQ=1704000`（min=max=setspeed 全锁，sugov 线程消失）。
  原因：schedutil 运行期调频调用链 `sugov_work → dev_pm_opp_set_rate →
  clk_set_rate → meson_clk_pll_set_rate`（改 6GHz `sys_pll_dco`）会长时间持有
  regmap 自旋锁，卡住 `meson8b-dwmac` 触发 `NETDEV WATCHDOG: eth0 tx timeout`
  → 网卡 reset → Moonlight 控制流断（重启后卡死的真因）。锁单频 = 运行期零 PLL 改动。
  1704000 是 1.5G(1512000) 与 1.9G(1908000) 之间的中间可用档；串流 idle >90%，无性能损失。
- 温度守护改成状态机且**常态零写频**：仅 >70℃ 降 `1512000`、且只有真正 HOT 过后
  <55℃ 才恢复 `1704000`（不是 cpuinfo_max 1908000）；冷机 50℃ 不会多写一次。10 秒轮询。
  这两条路径是唯一允许的 PLL 改动（极端保命），已合成温度验证通过。
- 该内核无 `/sys/class/devfreq/dmc`、无 vpu devfreq/`vpu_clk`，脚本按设计跳过并记日志。
- **2026-11-17 12:00 修复开机被覆盖**：`/etc/default/cpufrequtils` 原本 `ENABLE=true`、
  `GOVERNOR=schedutil`，LSB 服务 `cpufrequtils.service` 开机在 autotune 之后把 governor
  改回 schedutil（`sugov:0` 复活、cur/min=1512000/max=1908000），锁频失效、PLL 卡死风险回归。
  已改 `ENABLE=false`（备份 `/etc/default/cpufrequtils.bak-autotune-lock`），由 autotune 独占 cpufreq。
  重启整机验证：gov=userspace、cur/min/max=1704000、NO_SUGOV，四个核心全 1704000。**以后不要重新启用 cpufrequtils。**
- **2026-11-17 12:42 二次修复（上次没修对）**：12:00 改 `/etc/default/cpufrequtils` 的 ENABLE 其实生效了
  （`cpufrequtils.service` 第 58 行才 source 该 default，第 62 行据此 exit；实测重启该服务 governor 不变），
  真正元凶是 `loadcpufreq.service`——开机加载 cpufreq 内核模块时把 governor 初始化成 ondemand，且原本
  autotune 抢在模块加载之前 apply，随后被重置；ondemand 下 `scaling_setspeed` 不可写 → 温度守护失效。
  两处改动：① `/etc/systemd/system/moonlight-autotune.service.d/10-after-cpufreq.conf`
  加 `After=loadcpufreq.service cpufrequtils.service sysfsutils.service` + `Wants=loadcpufreq.service`；
  ② `/etc/moonlight-autotune.sh`（备份 `.bak-selfheal`）新增 `ensure_lock()`，daemon 每 10s 读检
  governor/cur/min/max，漂移才写回 userspace/目标档，健康态零 sysfs 写入（不额外动 PLL），
  日志标记 `LOCK REPAIR:`。故障注入验证：强改 ondemand 后 10s 内自动恢复 userspace/1704000。
  重启整机验证：开机顺序 loadcpufreq → autotune 正确，gov=userspace、四核全 1704000、NO_SUGOV、无 LOCK REPAIR。

## 开机显示 / 花屏

- **花屏本身无法从软件消除**：U-Boot（mainline s905）无 bmp/logo/vout 显示命令，
  内核无 `CONFIG_FB_SIMPLE`、DT 无 framebuffer 节点 → 从内核起到 meson-drm 建 fb0
  约 10 秒是 HDMI 电气空窗，电视看到花屏/噪点。`/boot/boot.bmp` 是用不上的素材。
  要根治需换带 earlyfb/更早初始化 DRM 的内核或 DT（大工程，不建议）。
  2026-11-17 曾从 `/boot/uEnv.txt` 删 `console=tty0`（备份 `uEnv.txt.bak-notty0`，
  只留串口 ttyAML0）——对空窗花屏无效，但无害，保留。启动脚本读 uEnv.txt 的
  APPEND，改它无需重新 mkimage boot.scr。
- **"电视切到错误 HDMI 端"已修（2026-11-17）**：真凶是 `cec-tv-wake.service` +
  timer（OnBootSec=3s），开机发 `IMAGE_VIEW_ON` 唤醒 Sony 电视，并在 +4/+8/+12s
  连发 `ACTIVE_SOURCE phys-addr=0x4000` 切端。物理地址 4.0.0.0 正确（盒子插 HDMI4），
  问题是切端发生在盒子 DRM 尚未出图时（~9-10s），电视切过来看到空信号像切错口。
  已在 `/usr/local/bin/cec-tv-wake`（备份 `.bak-seq`）发序列前插入「等
  `/sys/class/graphics/fb0/name` 含 mesondrmfb（最多 20s）」；原 +4/+8/+12 重发别动
  （电视唤醒慢，实测需要）。cec-ctl 拓扑：TV 0.0.0.0 → playback 4.0.0.0，逻辑地址 4。
  用户要求保留「唤醒并自动切到盒子口」。
- **每次串流开始都切端（2026-11-17 18:42）**：开机那次 CEC 只在开机跑，电视若中途
  待机/被切到别的输入就没人再切回。已让 wrapper `/usr/local/bin/moonlight-autostart`
  在 `exec moonlight stream` 前后台触发 `cec-tv-wake stream`（备份 `.bak-cechook`），
  因 systemd `Restart=always` 每次会话重跑 wrapper，从而覆盖每次串流开始。
  `cec-tv-wake stream`（备份 `.bak-streammode`）跳过开机 fb0/HPD 等待，`ASSERT_AT=
  "0 4 8 12"` 立即发 ACTIVE_SOURCE 再覆盖待机唤醒窗口；用 `flock -n /run/
  cec-tv-wake.lock` 与开机序列互斥（并发时后者跳过）。物理地址仍动态读拓扑（4.0.0.0
  → 0x4000）。无参数/开机 timer 调用行为不变。实测 stream 模式发送成功、flock 生效。

- **日志全走内存（2026-11-17，串流专用机降写盘/抗掉电）**：`/etc/systemd/journald.conf.d/
  10-volatile.conf` 设 `Storage=volatile` + `RuntimeMaxUse=32M`（/run tmpfs 仅 195M，
  不可设 200M），journald 只写 /run 内存盘；`rsyslog.service` 已 disable（原本会把日志
  再写一份到 eMMC 的 syslog/auth.log）。`/var/log/sysstat/` 死归档已清。
  **影响：重启/掉电后 `journalctl -b` 无历史日志**，排障要靠服务自身写在盘上的
  `/var/log/moonlight-{autotune,cpu-map,irq-affinity,latency-tune}.log`（不受影响）。
  实测写入速率降到 0 sector/10s。回退：`rm /etc/systemd/journald.conf.d/10-volatile.conf
  && systemctl enable --now rsyslog.service && systemctl restart systemd-journald`。
  主配置 `/etc/systemd/journald.conf.bak-before-volatile` 为原始备份（未改动）。

## 常用验证命令

```bash
systemctl is-enabled moonlight-{autotune,irq-affinity,cpu-map,autostart}.service
systemctl is-active  moonlight-{autotune,irq-affinity,cpu-map,autostart}.service
# 逐线程 affinity
P=$(pgrep -f '[m]oonlight stream' | head -1)
for d in /proc/$P/task/*; do printf '%-18s %s\n' "$(cat $d/comm)" "$(taskset -cp ${d##*/} | awk -F: '{print $2}')"; done
# 中断落点
for i in 14 15 18 21 24 25 26; do echo "IRQ$i $(cat /proc/irq/$i/smp_affinity_list)"; done
# 卡顿/告警
journalctl -u moonlight-autostart.service --since '-10min' --no-pager | grep -E 'Waiting for IDR|queue overflow|decoder stalled|underrun|Unrecoverable'
```

## 调研产物

- `armbian-autotune/moonlight-latency-report.md`：客户端延迟优化调研（纯只读）。
  结论：收包链路无刻意等待，延迟大头在显示呈现；提升手段多在 Moonlight 之外
  （显示器 Game Mode、主机 FEC 20→5~10、显式 `-remote no`）。
