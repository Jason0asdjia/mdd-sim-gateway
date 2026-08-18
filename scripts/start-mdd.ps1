<# Starts WSL2 MDD Sim Gateway and maintains usbipd auto-attach. Does not alter modem/eSIM settings. #>
[CmdletBinding()]
param(
  [string]$Distro = 'Ubuntu-24.04',
  [string]$ProjectPath = '',
  [switch]$OpenBrowser
)
$ErrorActionPreference = 'Stop'
$usbipd = Join-Path $env:ProgramFiles 'usbipd-win\usbipd.exe'
if (-not (Test-Path $usbipd)) { $command = Get-Command usbipd.exe -ErrorAction SilentlyContinue; if ($command) { $usbipd = $command.Source } }
Write-Host 'MDD 网关启动与检查 | MDD Sim Gateway — Windows + WSL startup' -ForegroundColor Cyan
if (-not $ProjectPath) {
  $scriptPath = $PSScriptRoot -replace '/', '\\'
  if ($scriptPath -match '^(?<drive>[A-Za-z]):(?<relative>\\.*)$') {
    $drive = Get-PSDrive -Name $Matches.drive -ErrorAction SilentlyContinue
    if ($drive -and $drive.DisplayRoot -like '\\*') {
      $scriptPath = $drive.DisplayRoot.TrimEnd('\') + $Matches.relative
    }
  }
  $escapedDistro = [regex]::Escape($Distro)
  if ($scriptPath -match "^\\\\(?:wsl\.localhost|wsl\$)\\$escapedDistro(?<path>\\.*)\\scripts$") {
    $ProjectPath = ($Matches.path -replace '\\', '/')
  } else {
    throw '无法自动确定 WSL 项目路径，请使用 -ProjectPath 指定 | Cannot derive the WSL project path. Pass -ProjectPath explicitly.'
  }
}
$probeArgs = @('-d', $Distro, '--exec', '/bin/true')
& wsl.exe @probeArgs
if (-not $?) { throw "WSL 启动失败，请检查发行版 | WSL distribution '$Distro' could not be started. Check: wsl -l -v" }
if (-not (Test-Path $usbipd)) {
  Write-Warning '未找到 usbipd-win，模块必须已附加到 WSL | usbipd-win was not found. WSL services will start, but the module must already be attached.'
} else {
  $usbList = ((& $usbipd list) -join [Environment]::NewLine)
  $moduleLines = @($usbList -split "`r?`n" | Where-Object { $_ -match '^\s*(\d+-\d+)\s+(2ca3:4006|2c7c:0125)\b' })
  if (-not $moduleLines.Count) {
    Write-Warning 'Windows 未发现受支持的 DJI 模块，请检查线缆和供电 | No supported DJI module (2ca3:4006 or 2c7c:0125) is visible to Windows. Check cable and module power.'
  }
  foreach ($line in $moduleLines) {
    $busId = ([regex]::Match($line, '^\s*(\d+-\d+)')).Groups[1].Value
    if ($line -match 'Not shared') {
      Write-Warning "模块位于 BUSID $busId，但尚未共享 | Module is on BUSID $busId but not shared. In Administrator PowerShell run: usbipd bind --busid $busId"
    } elseif ($line -notmatch 'Attached') {
      Write-Host "正在为模块 $busId 启用自动附加 | Starting usbipd auto-attach for module $busId..." -ForegroundColor Yellow
      Start-Process -FilePath $usbipd -ArgumentList @('attach', '--wsl', $Distro, '--busid', $busId, '--auto-attach') -WindowStyle Hidden
      Start-Sleep -Seconds 4
    } else {
      Write-Host "模块 $busId 已附加到 WSL | Module $busId is already attached to WSL." -ForegroundColor Green
    }
  }
}
Write-Host '正在启动并检查网关服务 | Starting and checking gateway services.' -ForegroundColor Yellow
$startArgs = @('-d', $Distro, '-u', 'root', '--exec', 'bash', "$ProjectPath/scripts/start-mdd-wsl.sh")
& wsl.exe @startArgs
if (-not $?) { throw '网关启动检查失败，请查看上方每项输出 | Gateway startup checks failed. Review the diagnostics above.' }
if ($OpenBrowser) {
  Write-Host '启动检查通过，正在打开管理页面 | Startup checks passed. Opening the MDD Sim Gateway…' -ForegroundColor Green
  Start-Process 'https://localhost:8443'
}
exit 0
