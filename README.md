# vps-init-suite

专为 **3x-ui / Xray 代理与多级中转服务器** 打造的一键稳定性与速度深度调优套件。**全程不开启系统防火墙**，不拦截任何业务或转发端口，开箱即用。

---

## 🚀 一键执行命令（复制粘贴即可）

### 方式一：交互式菜单（小白推荐）
登录 VPS 终端（`root` 权限）后直接粘贴执行，弹出菜单输入 **`1`** 并回车：
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jaycen-0502/vps-init-suite/main/init.sh)
```

### 方式二：全自动静默执行（批量装机推荐）
无需按键确认，自动完成全部 6 项深度调优并打印自检报告：
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jaycen-0502/vps-init-suite/main/init.sh) --auto
```

> **提示：** 若精简版系统提示 `curl: command not found`，可用 `wget` 替代：
> ```bash
> bash <(wget -qO- https://raw.githubusercontent.com/jaycen-0502/vps-init-suite/main/init.sh) --auto
> ```

---

## 📋 新手使用三步走

1. **切换 root 权限：** SSH 登录 VPS 后执行 `sudo -i`，确认命令行前缀变为 `root@...`（已是 `root@` 开头可跳过）。
2. **运行一键命令：** 复制上方任意一条命令粘贴到终端按回车，等待约 20–40 秒自动完成。
3. **核对自检结果：** 屏幕末尾输出 5 项绿色 **`[PASS]`** 状态即代表全部优化生效。

---

## ✨ 自动完成的 6 项深度优化（无防火墙干扰）

* **自动屏蔽残废 IPv6：** 实测 IPv6 公网出口，若不通则自动禁用内核 IPv6，消除刷图与测速时白等 3.6 秒超时的卡顿与重置。
* **BBR + 32MB 大缓冲 + 零空闲重置：** 启用 `fq + bbr`，关闭 `tcp_slow_start_after_idle` 防止停顿后网速掉回慢启动，拉满跨洋高延迟首屏速度。
* **TCP MSS 1380 持久化钳制：** 仅在 `mangle` 表优化封包尺寸防止多层代理隧道大包丢弃，不开启防火墙、不拦截任何端口。
* **百万级文件句柄与连接追踪扩容：** 将 `nofile` 拉高至 `1048576`、加速 `TIME_WAIT` 端口复用，防止高并发与 XHTTP 分片断流。
* **2GB Swap + `x-ui` 防崩溃守护：** 自动创建 2GB 虚拟内存（`swappiness=10`），并为 `x-ui` 注入 `OOMScoreAdjust=-900` 与秒级自启保护。
* **Chrony 毫秒级校时 + 日志封顶：** 自动同步 NTP 时间（防止 REALITY / TLS 1.3 时间偏差握手失败），系统日志封顶 100MB 并每日凌晨自动清理。

---

## 💻 支持系统

* Debian 12 / Debian 13（推荐）
* Ubuntu 22.04 / Ubuntu 24.04
* RHEL / Rocky / AlmaLinux 8 / 9

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

## ⚙️ 进阶命令（Suite 专业版 `setup.sh`）

仓库同时保留了完整的模块化管理套件 `setup.sh`（提供交互状态面板、精确 BDP 计算、时区与连接策略调优）：

```bash
# 运行完整专业版套件
curl -fsSL https://raw.githubusercontent.com/jaycen-0502/vps-init-suite/main/setup.sh | bash -s high-conn
# 查看系统状态面板
vps-init status
```
