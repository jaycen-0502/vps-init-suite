# Changelog

All notable changes to this project will be documented in this file.

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
