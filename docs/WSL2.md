# Windows 11 + WSL2 部署

WSL2 可以运行 MDD Sim Gateway，但 USB 模块必须交给 WSL2，Docker 也必须运行在同一个
Ubuntu 发行版内。它不是纯 Windows 程序：ModemManager、pcscd、udev、TUN 和主机路由
仍由 Linux 负责，Windows 只负责 USB 转发和打开 Web 控制台。

## 已知可行的组合

- Windows 11（Build 22000 或更新）与最新版商店版 WSL；
- WSL2 Ubuntu，已启用 systemd；
- `usbipd-win` 5.x；
- WSL2 内核包含 `option`、`qmi_wwan`、`cdc-wdm` 与 `tun` 驱动；
- Docker Engine 安装并运行在这个 Ubuntu 内，而不是使用 Docker Desktop 的远程 daemon。

先在 Windows 管理员 PowerShell 更新 WSL，再检查发行版状态：

```powershell
wsl --update
wsl --status
wsl -l -v
```

先在 WSL 中确认 PID 1 是 systemd：

```bash
ps -p 1 -o comm=
```

如果不是，在 `/etc/wsl.conf` 中加入以下内容，然后从 PowerShell 执行 `wsl --shutdown`：

```ini
[boot]
systemd=true
```

## 把模块连接给 WSL2

在 Windows 管理员 PowerShell 中安装 usbipd-win，并查看模块的 BUSID：

```powershell
winget install --interactive --exact dorssel.usbipd-win
usbipd list
usbipd bind --busid <BUSID>
```

`bind` 只需以管理员身份执行一次并会跨重启保留。之后使用普通 PowerShell：

```powershell
wsl -d Ubuntu-24.04 --exec /bin/true
usbipd attach --wsl Ubuntu-24.04 --busid <BUSID> --auto-attach
```

`attach` 不会跨 Windows/WSL 重启保留；`--auto-attach` 进程需要保持运行，才能在模块复位
或重新插入后自动接回。可在确认手动流程稳定后，将上面两条命令放进“任务计划程序”的
登录任务。模块交给 WSL2 后，Windows 本身不能同时使用它。

在 WSL 中验证：

```bash
sudo apt update
sudo apt install -y usbutils
lsusb
lsusb -t
```

第一代模块可能显示为出厂 ID `2ca3:4006`，也可能已被改为标准 EC25 ID `2c7c:0125`。
本项目安装时会为 `2ca3:4006` 安装 udev 规则并自动绑定串口驱动，不要求先永久修改 USB
ID。应能看到接口 2 对应的 `/dev/ttyUSB*`；项目按 USB 接口而非易变的 tty 编号定位它。
这条路径先保证串口/SIM/VoWiFi 能被发现；完整 4G/QMI 还需要 `qmi_wwan`/`cdc-wdm`
正确绑定并且 `mmcli -L` 列出 modem 对象。

## Docker 与安装

不要让这个 Ubuntu 的 `docker` 命令连接 Docker Desktop。设备、D-Bus、pcscd 和网络路由
必须与 MDD 的 Docker daemon 位于同一个 WSL2 Linux 环境。若尚未安装 Docker，直接运行
项目安装器，它会从 Ubuntu 仓库安装并启动原生 `docker.io`：

```bash
cd ~/mdd-sim-gateway
unset DOCKER_HOST
sudo ./install.sh install
```

Ubuntu 的 ModemManager 服务默认拒绝在被识别为容器的环境中启动，而 systemd 会把 WSL2
归入这一类。项目安装器会仅在检测到 WSL 时清除这条启动条件；其他容器和普通 Linux 主机
仍保留发行版的默认保护。

安装后从 Windows 浏览器打开 `https://localhost:8443`。Windows 到 WSL 的 localhost 转发
通常自动可用；如果要让局域网其他设备访问，需另外配置 Windows 防火墙与端口转发，并把
`MDD_ADVERTISE_ADDR` 设置成这些客户端能访问的地址。

## Windows 一键启动

完成一次安装和 `usbipd bind` 后，可从 Windows 资源管理器打开项目的 `scripts` 目录，双击
`Start-MDD-Gateway.cmd`。脚本会从自身 UNC 路径自动推导 WSL 项目位置，启动
`Ubuntu-24.04`、为所有可见的 `2ca3:4006`/`2c7c:0125` 模块维持自动附加，并以 root
执行 `start-mdd-wsl.sh` 检查服务。仓库移动后无需修改脚本。

发行版名称不是 `Ubuntu-24.04` 时，从 PowerShell 显式执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-mdd.ps1 -Distro Ubuntu
```

首次发现模块为 `Not shared` 时，脚本会显示对应 BUSID；仍需在管理员 PowerShell 运行一次
`usbipd bind --busid <BUSID>`。之后的附加与复位重连不需要管理员权限。

## WireGuard 国家出口

代理库可以导入标准 WireGuard `.conf`，或引用已启动的系统接口。导入时拒绝任何
`PreUp`/`PostUp`/`PreDown`/`PostDown` 命令，并强制写入 `Table=off`，防止 VPN 替换整个
WSL 的默认路由。每个国家出口使用不同的 packet mark、路由表和规则优先级，多条
WireGuard 出口不会互相覆盖。是否能承载 VoWiFi 仍应在分配国家出口后用国家出口的 UDP
测试和实际线路注册确认。

## 限制与排查

- WSL2 只有在发行版启动时才运行这些服务。要做常开网关，登录任务应先启动 WSL，再启动
  usbipd 的自动重连；长期无人值守仍更推荐树莓派或迷你 Linux 主机。
- 更换物理 USB 口会改变 BUSID，需要重新执行 `usbipd list`、`bind` 和 `attach`。
- 如果 `lsusb` 有模块但没有串口，检查
  `journalctl -u systemd-udevd -u ModemManager -n 100` 和 `dmesg | tail -100`。
- 如果切换 eSIM 配置文件后模块从 WSL 消失，先确认 `usbipd attach --auto-attach`
  进程仍在 Windows 中运行。配置文件切换会复位 USB 模块，没有自动重连就无法完成桥接恢复。
- 如果需要完整 4G/QMI，而 ModemManager 无法接管出厂 ID，可在确认 AT 命令返回值并做好
  回退方案后，再把模块 USB ID 改成 `2c7c:0125`。这会写模块 NVRAM，不属于 WSL2 的必要
  步骤，也不应盲目执行。
- “eSIM 配置文件启用/切换”由 lpac 完成；“板载 eSIM 与实体 SIM 槽的硬件选择”取决于模块
  固件是否暴露对应命令，两者不是同一功能。未验证具体固件前，不要把前者当成后者。
