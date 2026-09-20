# VPS Initialization & Kernel Tuning Suite

面向 Debian/Ubuntu VPS 的纯净初始化工具，专注系统底座、跨洋 TCP、MSS、时区和 SWAP，不安装任何代理面板。

## 功能

- 持久启用 BBR、FQ 和双向 TCP Fast Open（值为 `3`）。
- 将 TCP 收发缓冲上限扩大到 16 MiB，并调整连接队列。
- 通过独立 systemd 服务固化 sysctl，避免普通重启后失效。
- 支持 `clamp-to-PMTU` 或固定值 MSS，同时覆盖本机流量和转发流量。
- 无现有 SWAP 时，根据内存自动创建 2 GiB 或 4 GiB SWAP，设置 `swappiness=10`。
- 通过三个 HTTPS 地理服务依次探测公网出口时区，并启用网络时间同步。
- 可选彻底清理 3X-UI 服务及已知数据目录。
- 完整初始化后安装 `vps-init` 快捷命令，随时打开菜单或执行子命令。

## 支持系统

- Debian 11/12 及更新版本
- Ubuntu 20.04/22.04/24.04 及更新版本
- systemd、Linux 内核 BBR 支持

## 推荐安装方式

先下载并检查脚本，再以 root 权限执行：

```bash
curl -fsSLO https://raw.githubusercontent.com/jaycen-0502/vps-init-suite/main/setup.sh
less setup.sh
chmod +x setup.sh
sudo ./setup.sh full
```

初始化成功后可直接使用快捷命令：

```bash
sudo vps-init
sudo vps-init status
```

需要交互式菜单：

```bash
sudo ./setup.sh menu
```

确认脚本内容后，也可以一行执行完整初始化：

```bash
curl -fsSL https://raw.githubusercontent.com/jaycen-0502/vps-init-suite/main/setup.sh | sudo bash -s -- full
```

## 命令

| 命令 | 说明 |
| --- | --- |
| `sudo ./setup.sh full` | 完整初始化，并自动探测公网出口时区 |
| `sudo ./setup.sh full Asia/Tokyo` | 完整初始化，并显式指定 IANA 时区 |
| `sudo ./setup.sh kernel` | 仅应用 BBR、FQ、TFO 和 TCP 参数 |
| `sudo ./setup.sh mss clamp` | 使用路径 MTU 自动钳制 MSS（默认） |
| `sudo ./setup.sh mss 1380` | 将 MSS 固定为 1380，可使用 1200-1460 |
| `sudo ./setup.sh swap` | 无现有 SWAP 时创建受管 SWAP |
| `sudo ./setup.sh timezone auto` | 自动探测时区并启用网络时间同步 |
| `sudo ./setup.sh timezone America/Los_Angeles` | 手动指定 IANA 时区 |
| `sudo ./setup.sh timezone keep` | 保留当前时区，仅启用网络时间同步 |
| `sudo ./setup.sh install` | 单独安装或刷新 `vps-init` 快捷命令 |
| `./setup.sh status` | 查看当前状态 |
| `sudo ./setup.sh uninstall-3xui` | 交互确认后清理 3X-UI |
| `sudo ./setup.sh update` | 更新仓库或下载最新脚本 |

## 设计与安全说明

- 项目只写入带 `vps-init-suite` 名称的 sysctl、systemd、SWAP 和 iptables 资源，不删除第三方调优文件。
- 快捷入口为 `/usr/local/bin/vps-init`，实际脚本保存在 `/usr/local/lib/vps-init-suite/setup.sh`。
- 时区探测依次查询 `ipwho.is`、`ipinfo.io` 和 `ipapi.co`；这些服务会看到 VPS 的公网出口 IP，但脚本不会向其发送其他机器数据。
- 所有探测请求强制使用 HTTPS，返回值必须存在于本机 IANA 时区数据库中才会应用。
- 无人值守模式探测失败时会保留当前时区；交互模式提供常用地区、任意 IANA 时区及保留现状选项。
- 每次重写项目自己的 sysctl 文件前，旧版本都会备份到 `/var/lib/vps-init-suite/backups/`。
- MSS 使用专用 `VPS_INIT_MSS` 链和注释标记，不保存或覆盖整套防火墙规则。
- 已存在任何活动 SWAP 时不会修改；磁盘余量不足时不会创建新文件。
- 3X-UI 清理是不可逆操作，交互模式要求输入 `REMOVE`；自动化必须显式传入 `--yes`。
- 内核不提供 BBR 时，脚本会停止并提示升级，不会伪装成成功。

## 修改后检查

项目使用 GitHub Actions 运行 ShellCheck。也可以在本地执行：

```bash
bash -n setup.sh
shellcheck setup.sh tests/timezone_test.sh
bash tests/timezone_test.sh
```

## 许可证

[MIT](LICENSE)
