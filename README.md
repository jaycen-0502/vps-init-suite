# vps-init-suite

> **纯净无防火墙 · 稳定满速版 Linux VPS 网络调优套件（v1.19.5）**  
> 专为代理节点（3x-ui / Xray / sing-box）与跨境高吞吐低抖动场景设计，**不启用任何防火墙拦截（端口全通）**，按「带宽 + 延迟 + 并发规模 + 物理内存 + 防撞墙软封顶」多维自适应计算内核参数，并内置严格 7 项自检。

* **适用系统**：Debian 12 / 13、Ubuntu 22.04 / 24.04、RHEL / AlmaLinux / Rocky 8 / 9
* **适用机型**：512MB / 1C1G 小内存机至大内存高带宽机器，兼容单队列与多核 `mq` 多队列网卡

---

## ✨ 核心特性（v1.19.4）

1. **2.5× BDP 精细窗口算法**：抵消 Linux `tcp_adv_win_scale=1` 约 50% 的内核元数据开销，新增 **12MB / 24MB** 过渡档，200M–500M 跨洋机器如实填参即可一步命中甜点；1G 小内存自动安全封顶防 OOM。
2. **智能防撞墙单流软封顶（`fq maxrate`）**：针对 200M / 250M / 500M 等中小端口跨洋机房常见的硬限速墙（Policer），默认 `smart` 模式自动按 90% 带宽施加单流软封顶，将 BBR 探速压在限速墙下方，实测可将满载重传率从 3%+ 压降至接近 `0.00%`；兼容单队列与多核 `mq` 网卡。
3. **跨洋自适应 `initcwnd` + 弱网多图容错**：亚太近程自动用 `32` 保证多图秒开，跨洋（≥100ms）降为 `20` 防止首包突发丢包，高并发档收紧为 `16`；`tcp_syn_retries` / `tcp_synack_retries` 放宽至 `3`，降低晚高峰多图网页（X/IG）裂图率；大内存极速档 `tcp_notsent_lowat` 放宽至 `64KB`，平滑 4K/8K 视频拉流。
4. **智能防覆写 ECS DNS**：自动适配 `systemd-resolved`（开启 0ms 本地缓存并从 `systemd-networkd` / `NetworkManager` 拦截 DHCP 抢占）或 `resolv.conf` 加锁，统一配置 `8.8.8.8` 主用 / `1.1.1.1` 备用。
5. **双栈防黑洞与 MSS 钳制**：自动探测残废 IPv6 并内核禁用，避免 3.6s 超时假死；有效双栈则同步开启 IPv4 `1380` / IPv6 `1340` TCP MSS 钳制防分片。
6. **防爆内存守护与精准授时**：按磁盘余量自动创建 1G–2G Swap（跳过 LXC/OpenVZ），为 `x-ui` 注入自适应 `GOMEMLIMIT` / `GOGC` / `OOMScoreAdjust`，限制 `journald` 日志体积，配置 Chrony 毫秒级时间同步保障 REALITY / TLS 握手。
7. **7 项落地自检**：逐项比对内核实测值与预期值，并直接检测主网卡 `tc qdisc` 是否已生效 `fq`（未生效时自动提示 `reboot`）。

---

## 🚀 快速开始

### 1. 交互式菜单（推荐首次使用）

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/jaycen-0502/vps-init-suite/main/init.sh?t=$(date +%s)")
```

### 2. 命令行一键直跑（无人值守）

```bash
# 语法格式: init.sh [带宽Mbps] [延迟ms] [并发档位1|2] [fq封顶策略(可选,默认smart)]

# 示例 1: 250M 美西精品线（自动命中 12MB + initcwnd 20 + fq maxrate 225Mbit）
bash <(curl -fsSL "https://raw.githubusercontent.com/jaycen-0502/vps-init-suite/main/init.sh?t=$(date +%s)") 250 160 1

# 示例 2: 500M 美西机器（2G+自动命中 24MB + 450Mbit；1C1G自动安全封顶 12MB + 450Mbit）
bash <(curl -fsSL "https://raw.githubusercontent.com/jaycen-0502/vps-init-suite/main/init.sh?t=$(date +%s)") 500 160 1

# 示例 3: 1C1G · 1G 日本/亚太机器（自动命中 12MB + initcwnd 32 + 关闭单流封顶）
bash <(curl -fsSL "https://raw.githubusercontent.com/jaycen-0502/vps-init-suite/main/init.sh?t=$(date +%s)") 1000 45 1

# 示例 4: 1C1G · 1G 美国机器（自动命中 12MB + initcwnd 20 + 关闭单流封顶）
bash <(curl -fsSL "https://raw.githubusercontent.com/jaycen-0502/vps-init-suite/main/init.sh?t=$(date +%s)") 1000 160 1

# 示例 5: 一键默认无人值守（等同 500 160 1 smart）
bash <(curl -fsSL "https://raw.githubusercontent.com/jaycen-0502/vps-init-suite/main/init.sh?t=$(date +%s)") --auto
```

> **提示**：向后兼容 3 参数调用；不传第 4 参数时默认启用 `smart` 策略。如果自检第 2 项提示主网卡当前非 `fq` 队列（常见于全新开机的系统），请执行一次 `reboot` 让 `fq` 队列和 BBR pacing 彻底生效。

---

## ⚙️ 参数说明

| 位置 | 参数名 | 默认值 | 可选值与含义 |
| :--- | :--- | :--- | :--- |
| 第 1 参 | `BW_MBPS` | `500` | VPS 真实出口带宽（单位 `Mbps`，如 `200`、`250`、`500`、`1000`） |
| 第 2 参 | `RTT_MS` | `160` | 到国内典型往返延迟（单位 `ms`：港/日/新填 `35–50`，美西直连填 `160`，国际落地填 `30`） |
| 第 3 参 | `CONN_TIER` | `1` | `1` = 常规/低中并发极速档（≤500 连接，单线程与 4K/8K 视频优先）<br>`2` = 多人高并发稳态档（1000–3000+ 连接，防爆内存与稳态优先） |
| 第 4 参 | `FQ_MAXRATE` | `smart` | `smart` = **智能模式**：`带宽 ≤ 500M 且 延迟 ≥ 100ms` 自动按 90% 带宽封顶，1G+ 大口子或近程不限速<br>`auto` = **强制 90%**：无视带宽/延迟，强制按 `BW_MBPS × 90%` 单流封顶（适合有硬限速墙的 1G 口）<br>`off` = **关闭封顶**：不设置 `maxrate`（如此前挂载过封顶，会自动干净清除）<br>`纯数字` = **自定义 Mbps**：手动指定精确单流软封顶（如 `225`、`450`） |

---

## 📊 常见机型自动匹配速查表

只需传入机器的**真实带宽与延迟**，脚本会自动探测内存并落盘最优组合：

| 常见机型与线路 | 推荐传参 | 自动命中 TCP 上限 | `tcp_notsent_lowat` | `initcwnd` | `fq maxrate` (`smart`) | 适用说明 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **1C1G · 1G 日本/香港** | `1000 45 1` | **12 MB**（1G 封顶） | `32 KB` | `32` | 关闭 | 近程秒开，吞吐主要受单核加密算力制约 |
| **1C1G · 1G 美国** | `1000 160 1` | **12 MB**（1G 封顶） | `32 KB` | `20` | 关闭 | 单流稳冲 280–300M，多线程吃满且防 OOM |
| **2G+ · 200M 美西** | `200 160 1` | **12 MB** | `64 KB` | `20` | **180 Mbit** | 避开 200M 硬限速墙，低重传满速 |
| **2G+ · 250M 美西** | `250 160 1` | **12 MB** | `64 KB` | `20` | **225 Mbit** | 实测单流 188M+ / 多流 234M+ 且 0.00% 重传 |
| **2G+ · 500M 美西** | `500 160 1` | **24 MB** | `64 KB` | `20` | **450 Mbit** | 满血单流 4K/8K 与低抖动平衡点 |
| **2G+ · 1G+ 亚太** | `1000 45 1` | **16 MB** | `64 KB` | `32` | 关闭 | 亚太近程大口子全速释放 |
| **2G+ · 1G+ 美西** | `1000 160 1` | **32 MB** | `64 KB` | `20` | 关闭 | 跨洋大带宽旗舰配置（若遇墙可加第 4 参 `auto`） |
| **1C1G · 多人高并发** | `500 160 2` | **4 MB**（<100ms 为 2MB） | `16 KB` | `16` | **450 Mbit** | 严格保活防爆内存 |
| **2G+ · 多人高并发** | `500 160 2` | **12 MB** | `32 KB` | `16` | **450 Mbit** | 大内存高并发稳态平衡 |

---

## 🔍 验收与日常排障命令

### 1. 测试 30 秒真实增量 TCP 重传率（避开开机累计误差）

在本地正常播放 4K/8K 视频或跑单线程测速的同时，在 VPS 执行：

```bash
read o1 r1 <<< $(awk '/^Tcp:/{if(++c==1){for(i=1;i<=NF;i++)h[$i]=i}else{print $(h["OutSegs"]), $(h["RetransSegs"])}}' /proc/net/snmp)
echo "开始 30 秒增量采样..." && sleep 30
read o2 r2 <<< $(awk '/^Tcp:/{if(++c==1){for(i=1;i<=NF;i++)h[$i]=i}else{print $(h["OutSegs"]), $(h["RetransSegs"])}}' /proc/net/snmp)
awk -v d_out=$((o2-o1)) -v d_ret=$((r2-r1)) 'BEGIN{printf "30秒增量发包:%d | 增量重传:%d | 真实重传率:%.2f%%\n", d_out, d_ret, (d_out>0?d_ret*100/d_out:0)}'
```

* **健康标准**：优质直连线路正常拉流应在 **`1.5%` 以内**（理想值 `< 0.5%`）。如果某台 1G 端口机器满速时增量重传率超过 `3%`，可重跑脚本并追加第 4 参数 `auto`（或手动微调封顶值）以避开机房上游限速墙。

### 2. 一键核对当前落地状态

```bash
DEV=$(ip -4 route show default | awk '{print $5; exit}')
sysctl net.core.rmem_max net.ipv4.tcp_notsent_lowat net.ipv4.tcp_syn_retries net.ipv4.tcp_congestion_control
ip -4 route show default | head -n1
tc -s qdisc show dev "$DEV"
```

---

## 📁 脚本托管文件清单

| 路径 | 作用 |
| :--- | :--- |
| `/etc/sysctl.d/99-zzz-vps-init.conf` | 核心内核与 TCP/UDP 调优参数（自动备份清理旧版冲突文件至 `/var/lib/vps-init-suite/backups`） |
| `/etc/default/vps-init-opt` | 持久化记录当前生效的带宽、RTT、档位、`initcwnd`、`fq maxrate` 等状态 |
| `/usr/local/sbin/vps-init-runtime.sh` | 开机/网卡重载执行的运行时规则（MSS 1380/1340、自适应 `initcwnd`、`fq maxrate`、DNS 纠偏） |
| `/etc/systemd/system/proxy-mss.service` | 开机自启守护服务（同时联动 `/etc/network/if-up.d/99-initcwnd`） |
| `/etc/systemd/system/x-ui.service.d/99-vps-init-opt.conf` | `x-ui` 内存上限、GC、句柄与 OOM 优先级防爆配置 |
| `/etc/systemd/resolved.conf.d/99-vps-init-dns.conf` | `systemd-resolved` 0ms 本地缓存与 ECS DNS 配置 |

---

## 📝 更新日志

### v1.19.5
* **多队列网卡 `mq 0:` 兼容性修复**：修复多核 VPS 网卡默认无显式句柄 `qdisc mq 0: root` 导致子队列（`:1`, `:2`）无法挂载 `fq maxrate` 的问题。自动为 `root` 赋予显式句柄 `handle 1: mq` 并通过 `tc class show` 精准匹配子队列 class id，彻底解决多队列网卡上 `maxrate` 挂载被静默跳过的报错。

### v1.19.4
* **算法升级**：BDP 计算系数从 `1.5×` 提升至 `2.5×` 以抵消 Linux 元数据开销，新增 `12MB` / `24MB` 精细窗口阶梯；1G 小内存极速档上限优化为 `12MB` 兼顾速度与防爆。
* **防撞墙软封顶**：新增第 4 参数 `FQ_MAXRATE`（默认 `smart`），对 `≤500M` 跨洋线路自动按 90% 施加 `fq maxrate`，兼容 `mq` 多队列网卡，支持 `off` 干净回退。
* **多图网页与大带宽视频优化**：`initcwnd` 改为按延迟与并发档位自适应（`32 / 20 / 16`）；`tcp_syn_retries` / `tcp_synack_retries` 放宽至 `3`；大内存极速档 `tcp_notsent_lowat` 放宽至 `64KB`。
* **自检与修复**：自检第 2 项新增主网卡 `tc qdisc` 实时 `fq` 与 `maxrate` 校验及未生效重启提醒；修复 `/etc/security/limits.d/99-nofile.conf` 通配符格式问题。

### v1.19.3
* 确立四维自适应网络计算框架，集成 `systemd-resolved` 接口级反 DHCP 抢占、自动禁用残废 IPv6、双栈 MSS 1380/1340 钳制及 7 项严格自检报告。
