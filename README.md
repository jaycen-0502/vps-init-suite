# vps-init-suite

## 项目简介

`vps-init-suite (init.sh)` 是一套面向代理节点的**纯净无防火墙 Linux 网络与稳定性深度优化脚本**，不接管或拦截任何端口，专注解决跨境直连场景下的晚高峰丢包降速、多图网页首屏慢、高并发爆内存及 DNS 解析绕路问题。

- **适用系统**：Debian 12/13、Ubuntu 22.04/24.04、RHEL / AlmaLinux / Rocky 8/9
- **当前版本**：`v1.19.3`

---

## 核心特性

- **四维自适应内核调优**：自动检测 CPU 与内存，结合手动输入的带宽、典型 RTT 与并发档位（低中并发极速 / 多人高并发稳态），按 1.5 倍 BDP 动态计算 TCP 缓冲与 `tcp_mem` 硬顶，1GB 小内存与大内存机型精准分档防爆。
- **BBR 抗晚高峰丢包与首屏加速**：启用 BBR + FQ（严格保留多核网卡原生 `mq + 独立 fq` 多队列调度，不降级覆盖）；开启 `tcp_slow_start_after_idle=0`、`tcp_no_metrics_save=1`、`tcp_frto=2`、`tcp_reordering=6` 及默认路由 `initcwnd/initrwnd 32`，避免晚高峰偶发丢包后持续降速并加快多图首屏加载。
- **Google DNS 优选与防 DHCP 抢占**：统一配置 **Google DNS (`8.8.8.8`) 主用 + Cloudflare (`1.1.1.1`) 备用**，兼顾 ECS 就近 CDN 解析与高速兜底：
  - `systemd-resolved` 环境：开启本地 0ms 缓存，通过 `.network.d` drop-in 或 `nmcli` 禁用网卡 DHCP DNS 覆盖（不修改原始 Netplan YAML），并配合开机纠偏守护防止续租回弹。
  - 纯 `resolv.conf` 环境：自动解除软链接并加 `chattr +i` 锁，免疫重启与 DHCP 覆写。
- **防分片与残废 IPv6 处理**：自动探测 IPv6 公网连通性，无有效出口时自动禁用防假死黑洞；双栈可用时同步启用 IPv4 MSS 1380 与 IPv6 MSS 1340 幂等钳制。
- **防爆内存与 `x-ui` 守护增强**：写入内核参数前自动备份清理旧版冲突 `sysctl` 碎片并收敛至单文件 `99-zzz-vps-init.conf`；按磁盘余量自适应创建 Swap；为 `x-ui.service` 注入分档 `GOMEMLIMIT`、`GOGC`、`OOMScoreAdjust` 与高文件句柄；启用 Chrony 毫秒级授时保障 REALITY/TLS 握手。
- **真实运行态严格自检**：直接读取内核实时参数、`systemctl` 服务属性与 `resolvectl` 实际生效 DNS，与目标预期逐项比对，杜绝配置被覆盖却误报 `[PASS]`。

---

## 🚀 快速使用

```bash
# 1. 交互式菜单（推荐：一键调优 / 状态自检 / 安装 3x-ui）
bash <(curl -fsSL https://raw.githubusercontent.com/jaycen-0502/vps-init-suite/main/init.sh)

# 2. 命令行直接传参：<带宽Mbps> <典型延迟ms> <并发档位 1=极速/2=高并发>
bash <(curl -fsSL https://raw.githubusercontent.com/jaycen-0502/vps-init-suite/main/init.sh) 500 160 1

# 3. 无人值守默认模式（500Mbps / 160ms / 档位 1）
bash <(curl -fsSL https://raw.githubusercontent.com/jaycen-0502/vps-init-suite/main/init.sh) --auto
```

> **提示：** 若精简版系统提示 `curl: command not found`，可用 `wget` 替代：
> ```bash
> bash <(wget -qO- https://raw.githubusercontent.com/jaycen-0502/vps-init-suite/main/init.sh) --auto
> ```

---

## 🛠️ 3x-ui 面板与客户端（v2rayN）配套落地清单

VPS 跑完调优后，按以下 4 项收尾即可把整条链路的稳定性与速度拉满：

1. **3x-ui 出站强制走 IPv4：** 进入 **Xray 配置 → 出站规则（Outbounds）**，确保 `direct`（`freedom`）出站的 `domainStrategy` 为 **`UseIPv4`**，避免任何潜在的 IPv6 绕路。
2. **双协议组合 + 加密中转：**
   * **主力节点：** `VLESS + xtls-rprx-vision + REALITY`（高位冷门端口、选用本地 TLS 握手 `< 15ms` 的 `dest`/`SNI`）。
   * **保底节点：** `VLESS + XHTTP + TLS`（走 Cloudflare 固定冷门优选 IP，如 `172.64.229.107` 与 `172.64.229.11`，在 CF WAF 为 `/xhttp_stream` 添加 `Skip` 放行规则）。
   * **多级中转铁律：** 跨墙转发链路段严禁使用明文 `socks` 协议，统一改为 `VLESS + REALITY` 或 `Shadowsocks-2022` 加密对接。
3. **v2rayN 客户端 3 项必配：**
   * **参数设置 → Core 基础设置：** 取消勾选 **启用 Mux 多路复用**。
   * **路由设置 → 阻止（Block）：** 拦截端口 `443`、网络 `udp`（禁用 QUIC 避免刷图卡顿回退）。
   * **XHTTP 节点保活：** 在节点 `extra` 参数中保留 `"xmux":{"hKeepAlivePeriod":30}`，防止空闲 100 秒被 Cloudflare 断开底层连接。
4. **已误开防火墙的机器清理：** 若此前在机器上跑过带防火墙的旧版脚本，执行一次 `ufw disable 2>/dev/null; systemctl disable --now firewalld 2>/dev/null` 即可彻底恢复无防火墙状态。

---

## ⚙️ 进阶命令（Suite 专业管理版 `setup.sh` / `init.sh` v1.19.3）

仓库同时提供完整的模块化管理套件 `setup.sh`（支持 `vps-init` 全局快捷命令、精确 BDP 计算、时区与连接策略调优）：

```bash
# 1. 美西 1G 内存 + 500M 带宽（自动放开至 16MB 缓冲上限 + 320MB 硬顶，单线程拉满）
curl -fsSL "https://raw.githubusercontent.com/jaycen-0502/vps-init-suite/main/setup.sh" | bash -s high-conn us 500 160 speed

# 2. 国际千兆落地机（1000M 带宽 / 30ms 延迟 / speed 极速模式）
curl -fsSL "https://raw.githubusercontent.com/jaycen-0502/vps-init-suite/main/setup.sh" | bash -s high-conn intl 1000 30 speed

# 3. 亚太优化多人高并发（200M / 40ms / high 模式，严格 2M/4M 封顶防爆 CPU）
curl -fsSL "https://raw.githubusercontent.com/jaycen-0502/vps-init-suite/main/setup.sh" | bash -s high-conn cn 200 40 high

# 4. 交互式选择与查看系统状态
vps-init status
```
