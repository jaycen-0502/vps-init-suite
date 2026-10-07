# VPS Initialization & Kernel Tuning Suite

面向 Debian/Ubuntu VPS 的纯净初始化工具，专注系统底座、跨洋 TCP、MSS、时区和 SWAP，不安装任何代理面板。

## 功能

- 持久启用 BBR、FQ 和双向 TCP Fast Open（值为 `3`）。
- 将 TCP 收发缓冲上限扩大到 16 MiB，并调整连接队列。
- 根据物理内存自动选择低内存高并发 4 MiB 安全档或标准 16 MiB 长肥管道档；1G 档使用较低 socket 默认缓冲、适度增大监听队列并放宽 TCP keepalive，避免 4000+ 长连接造成额外定时器压力。
- 通过独立 systemd 服务固化 sysctl，避免普通重启后失效。
- 开启 IPv4 转发；IPv6 转发由用户选择，默认关闭，同时保留普通 IPv6 主机连接能力。
- 支持 `clamp-to-PMTU` 或固定值 MSS，同时覆盖本机流量和转发流量。
- 无现有 SWAP 时，根据内存自动创建 2 GiB 或 4 GiB SWAP，设置 `swappiness=10`。
- 通过三个 HTTPS 地理服务依次探测公网出口时区，并启用网络时间同步。
- 优先使用 `systemd-timesyncd`，在 D-Bus/timesyncd 不可用时回退到 chrony 和本地时区软链接。
- 可选彻底清理 3X-UI 服务及已知数据目录。
- 可选安全调整 3X-UI 的 Xray `policy.levels[0]`：先停面板、备份 SQLite、修改后校验并重启，失败时保留备份并尝试恢复。
- 完整初始化后安装 `vps-init` 快捷命令，随时打开菜单或执行子命令。
- 提供首次安装、已安装机器交互选择、保留 SWAP 卸载和显式删除受管 SWAP。

## 支持系统

- Debian 11/12 及更新版本
- Ubuntu 20.04/22.04/24.04 及更新版本
- systemd、Linux 内核 BBR 支持

## 推荐安装方式

如果当前提示符是 `root@主机`，不要加 `sudo`。`less` 和 `sudo` 都不是脚本依赖；检查文件可以用 `sed` 或 `cat`：

> 下面的代码块每一行都是一条独立命令，请逐行粘贴并在每行按一次 Enter。不要把多行命令连成一行，否则 `curl` 会把后面的命令误当成 URL。

```bash
curl -fsSLO https://raw.githubusercontent.com/jaycen-0502/vps-init-suite/main/setup.sh
sed -n '1,260p' setup.sh
chmod +x setup.sh
./setup.sh full
```

root 用户也可以使用这一条命令直接下载并执行（不会依赖 `less` 或 `sudo`）：

```bash
curl -fsSL https://raw.githubusercontent.com/jaycen-0502/vps-init-suite/main/setup.sh -o /tmp/vps-init-setup.sh && chmod +x /tmp/vps-init-setup.sh && /tmp/vps-init-setup.sh full
```

如果之前误把多条命令粘成一行，先删除错误下载文件，再重新逐行执行：

```bash
rm -f setup.sh
curl -fsSLO https://raw.githubusercontent.com/jaycen-0502/vps-init-suite/main/setup.sh
chmod +x setup.sh
./setup.sh full
```

看到 `curl: (6) Could not resolve host: sed`、`Could not resolve host: chmod` 或下载内容开头是 `<html>` 时，说明命令粘贴方式有误；不要运行该文件。

如果你是普通用户，使用下面的方式；快捷命令对需要特权的操作会自动请求 `sudo`：

```bash
chmod +x setup.sh
sudo ./setup.sh full
```

初始化成功后可直接使用快捷命令：

```bash
vps-init
vps-init status
vps-init ipv6 on
```

不带参数直接输入 `vps-init` 会打开操作菜单，菜单中包含完整初始化、升级脚本、安装/修复快捷命令、开启/禁用 IPv6 转发、3X-UI policy 和卸载套件等选项。这里的“禁用 IPv6”仅关闭内核转发，不会关闭本机 IPv6 出站；也可以直接运行 `vps-init upgrade`、`vps-init install` 或 `vps-init uninstall`。

如果安装了 3X-UI，还可以在菜单中进入 `3X-UI / Xray connection policy`，查看或调整连接空闲策略。首次进入会按需安装 Python 辅助程序。

快捷命令可直接由普通用户调用；需要改动系统的子命令会自动请求一次 `sudo`，无需手动重复输入 `sudo`。常规只读的 `status`、`version`、`help` 不需要 root；`xui-policy` 还要读取通常仅 root 可读的 3X-UI 数据库，因此会自动请求 root。若当前用户不是 root 且系统没有安装 `sudo`，请先切换到 root，或安装 sudo。

## 已安装机器：选择操作或卸载

旧版本先刷新脚本，再打开新菜单：

```bash
vps-init update
vps-init select
```

交互式选择操作：

```bash
vps-init select
```

直接卸载本套件（会要求输入确认短语）：

```bash
vps-init uninstall
```

卸载默认保留 SWAP。只有确定要删除本套件创建的 SWAP 时才使用：

```bash
vps-init uninstall --remove-swap
```

如果受管 SWAP 正在使用，脚本会拒绝删除，避免关闭活跃 swap 造成低内存 VPS OOM；对旧版本留下、无法证明归属的同名 swap 文件也会拒绝删除。卸载会移除本项目的 sysctl/systemd/MSS 规则和快捷命令，并尝试恢复此前备份的 sysctl 碎片及首次安装时记录的运行时 sysctl 值；备份目录 `/var/lib/vps-init-suite/backups/` 会保留。对于升级前已安装的旧版本，原始运行时值从未记录，脚本不会猜测，卸载时会提示重启以加载还原后的配置。系统时间和已安装依赖包不会自动回滚。卸载后建议重启并检查网络转发状态。

需要交互式菜单：

```bash
./setup.sh menu                 # 当前是 root
# 普通用户使用：sudo ./setup.sh menu
```

确认脚本内容后，也可以一行执行完整初始化：

```bash
curl -fsSL https://raw.githubusercontent.com/jaycen-0502/vps-init-suite/main/setup.sh | bash -s -- full
```

上面的管道命令仅适用于当前已经是 root 的会话；普通用户请将末尾改为 `| sudo bash -s -- full`。

## 命令

| 命令 | 说明 |
| --- | --- |
| `sudo ./setup.sh full` | 完整初始化；交互询问 IPv6 转发，默认关闭 |
| `sudo ./setup.sh full auto on` | 完整初始化并开启 IPv6 转发 |
| `sudo ./setup.sh full Asia/Tokyo off` | 完整初始化并关闭 IPv6 转发 |
| `sudo ./setup.sh kernel on` | 仅应用内核参数并开启 IPv6 转发 |
| `sudo ./setup.sh ipv6 off` | 关闭 IPv6 转发（默认策略） |
| `vps-init` 菜单中的“禁用 IPv6 转发” | 关闭 IPv6 forwarding，保留普通 IPv6 出站 |
| `sudo ./setup.sh mss clamp` | 使用路径 MTU 自动钳制 MSS（默认） |
| `sudo ./setup.sh mss 1380` | 将 MSS 固定为 1380，可使用 1200-1460 |
| `sudo ./setup.sh mss dual-fixed` | IPv4 固定 1380、IPv6 固定 1340 |
| `sudo ./setup.sh swap` | 无现有 SWAP 时创建受管 SWAP |
| `sudo ./setup.sh timezone auto` | 自动探测时区并启用网络时间同步 |
| `sudo ./setup.sh timezone America/Los_Angeles` | 手动指定 IANA 时区 |
| `sudo ./setup.sh timezone keep` | 保留当前时区，仅启用网络时间同步 |
| `sudo ./setup.sh install` | 单独安装或刷新 `vps-init` 快捷命令 |
| `vps-init upgrade` | 下载并安装最新脚本版本 |
| `vps-init select` | 已安装机器打开操作选择器 |
| `vps-init uninstall` | 卸载本套件，默认保留 SWAP |
| `vps-init uninstall --remove-swap` | 卸载并删除空闲的本套件 SWAP |
| `./setup.sh status` | 查看当前状态 |
| `vps-init xui-policy status` | 查看 3X-UI Xray policy（只读） |
| `vps-init xui-policy stable` | 设置稳定长连接档：`connIdle=300`、`uplinkOnly=2`、`downlinkOnly=5` |
| `vps-init xui-policy high-concurrency` | 设置 1G 高并发档：`connIdle=120`、`uplinkOnly=2`、`downlinkOnly=5` |
| `vps-init xui-policy set 120 2 5` | 交互确认后设置自定义 policy 值 |
| `vps-init xui-policy restore` | 交互确认后恢复最近一次已验证的 policy 备份 |
| `sudo ./setup.sh uninstall-3xui` | 交互确认后清理 3X-UI |
| `sudo ./setup.sh update` | 更新仓库或下载最新脚本 |

## 设计与安全说明

- 项目只写入带 `vps-init-suite` 名称的 sysctl、systemd、SWAP 和 iptables 资源，不删除第三方调优文件。
- 对附件中列出的已知历史 sysctl 碎片会先备份到 `/var/lib/vps-init-suite/backups/`，再删除，避免被旧脚本覆盖；不会覆盖 `/etc/sysctl.conf`。
- 低于 1500 MiB 内存使用 4 MiB 缓冲和较低队列，高于或等于 1500 MiB 使用 16 MiB 缓冲；这只是内核基准，应用自身仍需按内存规划。
- 低内存档的监听队列为 `somaxconn=8192`、`tcp_max_syn_backlog=4096`、`netdev_max_backlog=8192`，不是无限增大；若 `ListenOverflows` 持续增长，应优先检查应用监听 backlog、CPU steal 和上游连接突发。
- 低内存档的 TCP keepalive 为 `300/15/3`；应用层心跳和 NAT 超时可能需要独立调整，内核 keepalive 不替代 Xray/3X-UI 的连接策略。
- IPv6 默认不做路由转发；选择 `on` 时开启 forwarding 并使用 `accept_ra=2`，适合中转/路由节点。该选项不会关闭普通 IPv6 出站连接。
- `nf_conntrack` 仅在内核实际暴露对应 sysctl 节点时配置；精简内核或容器环境会安全跳过，不会导致整套初始化失败。
- MSS 规则会分别探测 IPv4/IPv6 的 `mangle` 表；受限容器或不支持该表的 VPS 会跳过 MSS 并继续完成其余初始化。
- 快捷入口为 `/usr/local/bin/vps-init`，实际脚本保存在 `/usr/local/lib/vps-init-suite/setup.sh`。
- 时区探测依次查询 `ipwho.is`、`ipinfo.io` 和 `ipapi.co`；这些服务会看到 VPS 的公网出口 IP，但脚本不会向其发送其他机器数据。
- 所有探测请求强制使用 HTTPS，返回值必须存在于本机 IANA 时区数据库中才会应用。
- 无人值守模式探测失败时会保留当前时区；交互模式提供常用地区、任意 IANA 时区及保留现状选项。
- 每次重写项目自己的 sysctl 文件前，旧版本都会备份到 `/var/lib/vps-init-suite/backups/`。
- MSS 使用专用 `VPS_INIT_MSS` 链和注释标记，不保存或覆盖整套防火墙规则。
- 完整初始化默认使用 `clamp-to-PMTU`；只有明确执行 `mss dual-fixed` 才会使用 IPv4 1380 / IPv6 1340 固定值。
- 已存在任何活动 SWAP 时不会修改；磁盘余量不足时不会创建新文件。
- 3X-UI policy 工具只支持 SQLite，默认读取 `/etc/x-ui/x-ui.db`，也会识别 `XUI_DB_FOLDER`；检测到 PostgreSQL 等其他后端时会拒绝修改。
- 3X-UI policy 工具只修改 `xrayTemplateConfig` 中的 `policy.levels[0]`，不会覆盖入站、出站、路由或用户数据；修改前会停止 `x-ui.service` 并创建完整性校验过的备份。
- `connIdle` 是空闲连接超时，不是连接总生命周期；活跃流量、LINE/Telegram/WebSocket/HTTP2 心跳可能让连接继续保持。过短的 `uplinkOnly` 或 `downlinkOnly` 可能造成正常长连接重连，建议先使用稳定档。
- policy 修改会重启 `x-ui.service`，现有代理连接可能短暂重连；若重启失败，脚本会尝试恢复之前的 policy 并重新启动服务。备份保留在 `/var/lib/vps-init-suite/backups/3xui/`。
- 3X-UI 清理是不可逆操作，交互模式要求输入 `REMOVE`；自动化必须显式传入 `--yes`。
- 内核不提供 BBR 时，脚本会停止并提示升级，不会伪装成成功。

## 修改后检查

项目使用 GitHub Actions 运行 ShellCheck。也可以在本地执行：

```bash
bash -n setup.sh
shellcheck setup.sh tests/timezone_test.sh tests/profile_test.sh
bash tests/timezone_test.sh
bash tests/profile_test.sh
python3 -m py_compile xui-policy.py tests/xui_policy_test.py
python3 tests/xui_policy_test.py
```

## 许可证

[MIT](LICENSE)
