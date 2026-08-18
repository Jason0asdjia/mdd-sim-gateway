#!/usr/bin/env bash
# Starts and validates a native MDD Sim Gateway installation. Never changes modem/eSIM settings.
set -u -o pipefail
control=mdd-sim-gateway-control.service
orchestrator=mdd-sim-gateway-orchestrator.service
ok=0; warning=0; failed=0
zh_message() {
  case "$1" in
    "WSL systemd is active") printf 'WSL systemd 已启动' ;;
    "pcscd is running") printf 'PC/SC 服务已启动' ;;
    "DJI modem serial interfaces detected"*) printf '已检测到 DJI 模块串口' ;;
    "No modem serial ports were found in WSL.") printf 'WSL 未检测到模块串口' ;;
    "Run scripts\\start-mdd.ps1"*) printf '请在 Windows 运行启动脚本或确认模块已附加' ;;
    "mdd-sim-gateway-orchestrator.service is active") printf '网关协调服务已启动' ;;
    "mdd-sim-gateway-control.service is active") printf '网关控制服务已启动' ;;
    *"did not start. Inspect:"*) printf '网关服务启动失败，请查看日志' ;;
    "ModemManager claimed the cellular module") printf 'ModemManager 已认领蜂窝模块' ;;
    "ModemManager is active but has not created"*) printf 'ModemManager 尚未创建模块对象，VoWiFi 短信暂不可用' ;;
    "ModemManager is not active."*) printf 'ModemManager 未启动，VoWiFi 短信需要此服务' ;;
    "SIM bridge is visible through PC/SC"*) printf 'SIM 桥接已在 PC/SC 中就绪' ;;
    "Modem is present but the PC/SC SIM bridge is not ready."*) printf '模块存在，但 SIM 桥接尚未就绪' ;;
    "WireGuard still owns"*) printf 'WireGuard 仍接管 WSL 全局路由' ;;
    "Normal WSL traffic uses eth0; WireGuard is not the default route") printf 'WSL 常规流量走 eth0，WireGuard 未接管默认路由' ;;
    "Could not confirm eth0"*) printf '无法确认 WSL 常规默认路由' ;;
    "Active WireGuard interface service(s):"*) printf '已启用 WireGuard 接口服务' ;;
    "Web control plane responds"*) printf 'Web 控制台响应正常' ;;
    "Web control plane did not respond"*) printf 'Web 控制台未响应' ;;
    "Could not start pcscd."*) printf '无法启动 PC/SC 服务' ;;
    "WSL systemd is inactive."*) printf 'WSL systemd 未启动' ;;
    *) printf '检查结果' ;;
  esac
}
pass() { local english="$*"; printf '  [正常] %s | [OK] %s\n' "$(zh_message "$english")" "$english"; ok=$((ok + 1)); }
warn() { local english="$*"; printf '  [提示] %s | [!!] %s\n' "$(zh_message "$english")" "$english"; warning=$((warning + 1)); }
fail() { local english="$*"; printf '  [失败] %s | [XX] %s\n' "$(zh_message "$english")" "$english"; failed=$((failed + 1)); }
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then exec sudo --preserve-env=PATH "$0" "$@"; fi
printf '\nMDD 网关启动与硬件检查 | MDD Sim Gateway — startup and hardware check\n\n'
if [[ $(ps -p 1 -o comm= 2>/dev/null) != systemd ]]; then
  fail 'WSL systemd is inactive. Set [boot] systemd=true in /etc/wsl.conf, then run wsl --shutdown in Windows.'; exit 1
fi
pass 'WSL systemd is active'
systemctl enable --now pcscd.service >/dev/null 2>&1 || { fail 'Could not start pcscd. Run: systemctl status pcscd'; exit 1; }
pass 'pcscd is running'
for _ in {1..12}; do compgen -G '/dev/ttyUSB*' >/dev/null && break; sleep 1; done
tty_count=$(compgen -G '/dev/ttyUSB*' | wc -l)
if (( tty_count == 0 )); then
  fail 'No modem serial ports were found in WSL.'
  warn 'Run scripts\start-mdd.ps1 in Windows. Otherwise confirm usbipd list shows the DJI module as Attached.'
else
  pass "DJI modem serial interfaces detected (${tty_count} ttyUSB ports)"
fi
systemctl enable "$orchestrator" "$control" >/dev/null 2>&1 || true
systemctl restart "$orchestrator" "$control"
sleep 4
for service in "$orchestrator" "$control"; do
  if systemctl is-active --quiet "$service"; then pass "$service is active"; else fail "$service did not start. Inspect: journalctl -u $service -n 80 --no-pager"; fi
done
if (( tty_count > 0 )); then
  mm_ready=0
  for _ in {1..35}; do
    if systemctl is-active --quiet ModemManager.service && mmcli -L 2>/dev/null | grep -q "/Modem/"; then
      mm_ready=1
      break
    fi
    sleep 1
  done
  if (( mm_ready )); then
    pass 'ModemManager claimed the cellular module'
  elif systemctl is-active --quiet ModemManager.service; then
    warn 'ModemManager is active but has not created a modem object yet; VoWiFi SMS stays unavailable until it claims the module.'
  else
    fail 'ModemManager is not active. VoWiFi SMS requires it; inspect: journalctl -u ModemManager -n 80 --no-pager'
  fi
fi
readers=0
if command -v pcsc_scan >/dev/null 2>&1; then readers=$(timeout 6 pcsc_scan -n 2>/dev/null | grep -c '^ Reader [0-9].*VoWiFi Modem' || true); fi
if (( readers > 0 )); then pass "SIM bridge is visible through PC/SC (${readers} reader(s))"; elif (( tty_count > 0 )); then warn 'Modem is present but the PC/SC SIM bridge is not ready. Wait 15 seconds and run again.'; fi
if ip -4 rule show | grep -q 'not from all fwmark 0xca6c lookup 51820'; then
  warn 'WireGuard still owns the global WSL route table (51820). Set Table=off inside the [Interface] section for project-only routing.'
elif ip route get 1.1.1.1 2>/dev/null | grep -q 'dev eth0'; then
  pass 'Normal WSL traffic uses eth0; WireGuard is not the default route'
else
  warn 'Could not confirm eth0 as the normal WSL default route'
fi
active_wg=$(systemctl list-units --type=service --state=active 'wg-quick@*.service' --no-legend 2>/dev/null | wc -l)
if (( active_wg > 0 )); then pass "Active WireGuard interface service(s): $active_wg"; fi
http_code=$(curl -k -sS -o /dev/null -w '%{http_code}' --max-time 5 https://127.0.0.1:8443/ 2>/dev/null || true)
if [[ $http_code == 200 || $http_code == 401 || $http_code == 302 ]]; then pass "Web control plane responds on https://localhost:8443 (HTTP $http_code)"; else fail "Web control plane did not respond on port 8443 (HTTP ${http_code:-none})"; fi
printf '\n[结果] 正常 %d、提示 %d、失败 %d | Result: %d OK, %d warning(s), %d failure(s).\n' "$ok" "$warning" "$failed" "$ok" "$warning" "$failed"
(( tty_count == 0 )) && printf '[提示] 模块检测需要 Windows 重新附加 USB | Services are started, but SIM detection needs Windows to re-attach the USB module to WSL.\n'
exit "$failed"
