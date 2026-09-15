# dsh-focus.ps1 —— 只做「把已打开的资源管理器窗口带到前台」（带诊断日志版）
#
# 为什么不在这里启动 explorer：
#   实测（2026-09-15，UI Automation 抓 360tray 的 Q360HIPSClass 弹窗）：
#     ① node 直接拉起 explorer.exe        -> 360 主动防御 0 次
#     ② PowerShell 只做置前(AppActivate)  -> 360 主动防御 0 次
#     ③ PowerShell 拉起 explorer.exe      -> 360 主动防御 1 次（每次必弹）
#   所以分工：explorer 由 node 侧拉起（见 dsh-launcher.ps1 的 reveal-foreground v3 补丁），
#   本脚本只负责置前，绝不自己启动 explorer。
#   本文件是独立进程、每次读盘执行 —— 改这里不需要重启 DSH 即可生效。
#
# 用法：powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File dsh-focus.ps1 -Path "C:\some\file.pptx"
# 退出码：0 = 已置前；1 = 没找到可置前的窗口

param([Parameter(Mandatory = $true)][string]$Path)

$ErrorActionPreference = 'SilentlyContinue'

$log = 'D:\deepseek\project\dsh up\_360diag\focus.log'
function Log([string]$m) { try { ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $m) | Add-Content -LiteralPath $log -Encoding UTF8 } catch { } }

Log ("focus 被调用 Path=「" + $Path + "」")

# 等 node 那边把窗口开出来
Start-Sleep -Milliseconds 700

$wsh = New-Object -ComObject WScript.Shell
$folder = Split-Path -Leaf (Split-Path -Parent $Path)
Log ("目录名 = 「" + $folder + "」")

# 首选：按目录名匹配窗口标题（资源管理器窗口标题就是目录名）
if ($folder) {
	if ($wsh.AppActivate($folder)) { Log "AppActivate(目录名) 成功 -> exit 0"; exit 0 }
	Log "AppActivate(目录名) 失败，走兜底"
}

# 兜底：按目录 URL 找到对应窗口，再用它的标题置前
try {
	$dir = Split-Path -Parent $Path
	$uri = ([uri]$dir).AbsoluteUri
	if (-not $uri.EndsWith('/')) { $uri += '/' }
	$sh = New-Object -ComObject Shell.Application
	$n = 0
	foreach ($w in @($sh.Windows())) {
		$n++
		try {
			Log ("  窗口" + $n + ": 「" + $w.LocationName + "」 " + $w.LocationURL)
			if ($w.LocationURL -and ($w.LocationURL -eq $uri -or $w.LocationURL -eq $uri.TrimEnd('/'))) {
				if ($wsh.AppActivate([string]$w.LocationName)) { Log "AppActivate(按URL匹配) 成功 -> exit 0"; exit 0 }
			}
		} catch { }
	}
	Log ("  共枚举到 " + $n + " 个窗口，未匹配到目标目录")
} catch { Log ("兜底异常: " + $_.Exception.Message) }

Log "未能置前 -> exit 1"
exit 1
