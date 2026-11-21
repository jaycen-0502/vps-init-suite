# Changelog

All notable changes to this project will be documented in this file.

## [v1.19.5] - 2026-11-21

### 修复
- **多队列网卡 `mq 0:` 兼容性修复**：修复多核 VPS 网卡默认无显式句柄 `qdisc mq 0: root` 导致子队列（`:1`, `:2`）无法挂载 `fq maxrate` 的问题。自动为 `root` 赋予显式句柄 `handle 1: mq` 并通过 `tc class show` 精准匹配子队列 class id，彻底解决多队列网卡上 `maxrate` 挂载被静默跳过的报错。

## [v1.19.4] - 2026-11-21

### 新增与优化
- **算法升级**：BDP 计算系数从 `1.5×` 提升至 `2.5×` 以抵消 Linux `tcp_adv_win_scale=1` 约 50% 元数据开销，新增 `12MB` / `24MB` 精细窗口阶梯；1G 小内存极速档上限优化为 `12MB` 兼顾速度与防爆。
- **防撞墙软封顶**：新增第 4 参数 `FQ_MAXRATE`（默认 `smart`），对 `≤500M` 跨洋线路自动按 90% 施加 `fq maxrate`，兼容 `mq` 多队列网卡，支持 `off` 干净回退。
- **多图网页与大带宽视频优化**：`initcwnd` 改为按延迟与并发档位自适应（`32 / 20 / 16`）；`tcp_syn_retries` / `tcp_synack_retries` 放宽至 `3`；大内存极速档 `tcp_notsent_lowat` 放宽至 `64KB`。
- **自检与修复**：自检第 2 项新增主网卡 `tc qdisc` 实时 `fq` 与 `maxrate` 校验及未生效重启提醒；修复 `/etc/security/limits.d/99-nofile.conf` 通配符格式问题（修正为 `*`）。

## [v1.19.3] - 2026-11-20

### 新增与优化
- **Google DNS 优选与防 DHCP 抢占**：统一调整 DNS 策略为 `8.8.8.8`（主用）+ `1.1.1.1`（备用），`systemd-resolved` 兜底调整为 `8.8.4.4 1.0.0.1`。新增 `systemd-networkd` `.network.d` 覆盖文件与 `NetworkManager` (`nmcli`) 接口级 DHCP DNS 拦截（不修改原始 Netplan YAML），并在 `/usr/local/sbin/vps-init-runtime.sh` 中追加开机及网卡重载 DNS 自动纠偏。
- **抗晚高峰丢包与首屏加速**：新增 `net.ipv4.tcp_no_metrics_save=1`、`net.ipv4.tcp_frto=2`、`net.ipv4.tcp_reordering=6`、`net.ipv4.tcp_base_mss=1024`，并持久化默认路由 `initcwnd 32 initrwnd 32`；双栈正常机型自动补齐 `ip6tables` TCP MSS 1340 钳制。
- **1GB 极速档余量微调与多队列保护**：1G 单线程极速档微调为 `GOMEMLIMIT=320MiB`、`tcp_mem` 硬顶 280MB，留出更充裕的物理内存缓冲；严格保护多核网卡原生 `mq + fq` 多队列调度不被强制降级覆盖。
- **严格自检升级**：自检报告先触发出站解析再核验 `resolvectl` 当前真实生效的首选与备用 DNS、内核实测缓冲/硬顶及 `x-ui.service` 实际加载的 `OOMScoreAdjust` 与 `GOMEMLIMIT`。

### 修复
- 修复旧版 `sysctl` 碎片按字母序覆盖新参数导致窗口与硬顶打架的问题，统一归档清理并收敛至 `/etc/sysctl.d/99-zzz-vps-init.conf`。
- 修复交互读取偶发超时粘连、`limits.d/99-nofile.conf` 通配符误写以及 `x-ui` drop-in 漏写 `GOMEMLIMIT` / `GOGC` 的问题。
- 优化无 NAT 场景下的内存与 CPU 占用，移除开机强制加载 `nf_conntrack`，仅在内核已启用时按内存分档写入上限。
