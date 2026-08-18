"""Safe, local WireGuard configuration import for the administrator UI."""
from __future__ import annotations

import os
import re
import subprocess
import tempfile
from pathlib import Path

_INTERFACE = re.compile(r"^[A-Za-z0-9_.-]{1,15}$")
_FORBIDDEN = re.compile(r"^\s*(?:PreUp|PostUp|PreDown|PostDown)\s*=", re.I | re.M)
_ALLOWED = {"privatekey", "address", "dns", "mtu", "table", "saveconfig",
            "listenport", "fwmark", "publickey", "presharedkey", "allowedips",
            "endpoint", "persistentkeepalive"}
WIREGUARD_DIR = Path(os.environ.get("MDD_WIREGUARD_DIR", "/etc/wireguard"))

class WireGuardError(RuntimeError):
    pass

def _validate(name: str, config: str) -> None:
    if not _INTERFACE.fullmatch(name):
        raise WireGuardError("WireGuard interface name is invalid")
    if len(config.encode("utf-8")) > 32_768:
        raise WireGuardError("WireGuard configuration is too large")
    if _FORBIDDEN.search(config):
        raise WireGuardError("PreUp/PostUp/PreDown/PostDown directives are not allowed")
    section = ""
    interfaces = 0
    peers = 0
    for raw in config.splitlines():
        line = raw.strip()
        if not line or line.startswith(("#", ";")):
            continue
        if line.lower() in {"[interface]", "[peer]"}:
            section = line.lower()
            interfaces += line.lower() == "[interface]"
            peers += line.lower() == "[peer]"
            continue
        if not section or "=" not in line:
            raise WireGuardError("WireGuard configuration is not valid")
        key = line.split("=", 1)[0].strip().lower()
        if key not in _ALLOWED:
            raise WireGuardError(f"WireGuard option {key!r} is not supported")
    if interfaces != 1 or peers < 1:
        raise WireGuardError("WireGuard configuration needs one [Interface] and at least one [Peer]")

def _project_only_config(config: str) -> str:
    """Force wg-quick to leave the host route table untouched."""
    lines = config.splitlines()
    try:
        start = next(index for index, line in enumerate(lines)
                     if line.strip().lower() == "[interface]")
    except StopIteration as exc:
        raise WireGuardError("WireGuard configuration needs an [Interface] section") from exc
    end = next((index for index in range(start + 1, len(lines))
                if lines[index].strip().startswith("[")), len(lines))
    interface_lines = []
    for line in lines[start + 1:end]:
        key = line.strip().split("=", 1)[0].strip().lower() if "=" in line else ""
        if key != "table":
            interface_lines.append(line)
    # Table=off is handled by wg-quick and prevents a full-tunnel peer from
    # adding a default route or policy rule for unrelated WSL processes.
    return "\n".join(lines[:start + 1] + interface_lines + ["Table=off"] + lines[end:]) + "\n"

def _write(path: Path, content: str) -> None:
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content.rstrip() + "\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass

def import_config(interface: str, config: str) -> dict:
    interface, config = str(interface or "").strip(), str(config or "")
    _validate(interface, config)
    config = _project_only_config(config)
    _validate(interface, config)
    directory = WIREGUARD_DIR
    if not directory.is_dir():
        raise WireGuardError("WireGuard is not installed on this host")
    if os.geteuid() != 0:
        raise WireGuardError("WireGuard import requires the native root control service")
    target = directory / f"{interface}.conf"
    prior = target.read_text(encoding="utf-8") if target.exists() else None
    service = f"wg-quick@{interface}"
    wrote = False
    try:
        was_active = subprocess.run(["systemctl", "is-active", "--quiet", service],
                                    timeout=8).returncode == 0
        stopped = subprocess.run(["systemctl", "disable", "--now", service],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 timeout=20)
        if stopped.returncode:
            raise WireGuardError("WireGuard interface could not be stopped safely")
        _write(target, config)
        wrote = True
        started = subprocess.run(["systemctl", "enable", "--now", service],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
        if started.returncode:
            raise WireGuardError("WireGuard interface did not start; check the configuration")
    except (OSError, subprocess.TimeoutExpired, WireGuardError) as exc:
        if wrote:
            try:
                subprocess.run(["systemctl", "disable", "--now", service],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               timeout=20)
                if prior is not None:
                    _write(target, prior)
                    if was_active:
                        subprocess.run(["systemctl", "enable", "--now", service],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                       timeout=30)
                else:
                    target.unlink(missing_ok=True)
            except (OSError, subprocess.TimeoutExpired):
                pass
        if isinstance(exc, WireGuardError):
            raise
        raise WireGuardError("WireGuard service could not be started") from exc
    return {"interface": interface, "active": True, "project_only": True}
