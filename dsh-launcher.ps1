#requires -Version 5.1
<#
    DSH 启动器  (dsh-launcher.ps1)

    一个入口，全自动：
      1. DSH 已经在跑 -> 直接提示"DSH 在运行中"，按任意键退出（不检查、不联网）
      2. 否则自动检查 dsh 主体 / 内核 / 插件 / 模型 / 运行环境 有没有可升级项
         - 检查期间按任意键 = 跳过检查，直接启动
      3. 有可升级项就自动开始升级
         - 每项升级开始前按任意键 = 跳过剩余项，直接启动
         - 正在执行的那一步（npm/pnpm 写文件）不能中断，会提示"必须等待"
      4. 启动 DSH 并打开界面

    常用用法：
        启动 DSH.cmd                                     正常流程（全自动）
        powershell -File dsh-launcher.ps1 -SkipCheck     完全不检查，直接启动
        powershell -File dsh-launcher.ps1 -CheckOnly     只看检查结果，不改任何东西
        powershell -File dsh-launcher.ps1 -Stop          停止当前 DSH
        powershell -File dsh-launcher.ps1 -Restart       关闭 -> 检查 -> 启动
        powershell -File dsh-launcher.ps1 -DryRun        只打印将要执行的命令

    注意：本机只有 Windows PowerShell 5.1（没有 pwsh），脚本按 5.1 语法编写，
          并且必须存成 UTF-8 带 BOM（否则中文会被 5.1 按 GBK 读坏）。
#>
[CmdletBinding()]
param(
    [int]$Port = 0,
    [string]$DshHome = '',
    [string]$RuntimeDir = '',
    [string]$Registry = '',
    [string]$ProfileName = 'web',
    [switch]$CheckOnly,
    [switch]$Stop,
    [switch]$Restart,
    [switch]$SkipCheck,               # 跳过升级检查，直接启动
    [switch]$PatchOnly,               # 只给 dsh 重打补丁，不检查不启动
    [switch]$DryRun,
    [switch]$Silent
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
# 系统代理可能指向一个已经退出的 Clash（127.0.0.1:7890），会让国内源也连不上、每次都等超时。
# 这里把进程默认代理清空 = 直连；需要翻墙的 GitHub 请求会显式指定 -Proxy。
try { [System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy } catch { }

# ============================================================================
#  配置（想改路径/端口，改这里就行）
# ============================================================================
$script:Cfg = [ordered]@{}
$script:Cfg.DshHome    = if ($DshHome)    { $DshHome }    else { Join-Path $env:USERPROFILE '.dsh' }
$script:Cfg.RuntimeDir = if ($RuntimeDir) { $RuntimeDir } else { Join-Path $env:LOCALAPPDATA 'npm-cache\_npx\1e7f6d9597241db0' }
$script:Cfg.Registry   = if ($Registry)   { $Registry }   else { 'https://registry.npmmirror.com' }
$script:Cfg.Profile    = $ProfileName
$script:Cfg.Port       = if ($Port -gt 0) { $Port } else { 3080 }
$script:Cfg.DshPackage = '@deepseek-ai/dsh'
$script:Cfg.Proxy      = 'http://127.0.0.1:7890'      # 访问 GitHub 时用的本地代理（Clash）
$script:Cfg.NodeMirror = 'https://registry.npmmirror.com/-/binary/node'
$script:Cfg.LogDir     = Join-Path $env:LOCALAPPDATA 'dsh-launcher\logs'

$script:SB = New-Object System.Text.StringBuilder
$script:Items = @()
$script:UseProxy = $false
$script:GitHubFails = 0
$script:RunningPid = 0
$script:UpgradeLog = @()
$script:CheckAborted = $false      # 用户在检查过程中按了键
$script:SkippedUpgrade = $false    # 用户在升级过程中按键跳过了剩余项
$script:NodeVerCache = ''
$script:PatchMarker = 'dsh-launcher-patch: reveal-foreground v8'   # 补丁版本标记（改了补丁内容就升版本）
$script:LauncherVersion = 'v8'   # 启动器版本（横幅与诊断里会打印，方便远程确认用户跑的是哪一版）
$script:BridgePatchMarker = 'dsh-bridge-patch: question-answerer v5'  # 微信桥接补丁的版本标记（插件侧）
$script:BridgeDaemonPatchMarker = 'dsh-bridge-patch: qa-answer-short-circuit v1'  # 微信桥接补丁的版本标记（守护进程侧）

# ============================================================================
#  小工具
# ============================================================================
function Add-Line {
    param([string]$Text = '', [switch]$ReportOnly)
    [void]$script:SB.AppendLine($Text)
    if (-not $ReportOnly) { Write-Host $Text }
}

function Invoke-Safe {
    param([scriptblock]$Body, $Fallback = $null)
    try { return & $Body } catch { return $Fallback }
}

function ConvertTo-VerParts {
    param([string]$Version)
    $v = ([string]$Version).Trim()
    if ($v.StartsWith('v')) { $v = $v.Substring(1) }
    $pre = ''
    $main = $v
    $i = $v.IndexOf('-')
    if ($i -ge 0) { $main = $v.Substring(0, $i); $pre = $v.Substring($i + 1) }
    $nums = @()
    foreach ($p in $main.Split('.')) {
        $n = 0
        if (-not [int]::TryParse($p, [ref]$n)) { $n = 0 }
        $nums += $n
    }
    while ($nums.Count -lt 3) { $nums += 0 }
    return New-Object psobject -Property @{ Main = $nums; Pre = $pre }
}

function Compare-Ver {
    param([string]$A, [string]$B)
    $pa = ConvertTo-VerParts $A
    $pb = ConvertTo-VerParts $B
    for ($i = 0; $i -lt 3; $i++) {
        if ($pa.Main[$i] -ne $pb.Main[$i]) {
            if ($pa.Main[$i] -lt $pb.Main[$i]) { return -1 } else { return 1 }
        }
    }
    if ($pa.Pre -eq $pb.Pre) { return 0 }
    if ($pa.Pre -eq '') { return 1 }        # 正式版 > 预发布版
    if ($pb.Pre -eq '') { return -1 }
    $aa = $pa.Pre.Split('.')
    $bb = $pb.Pre.Split('.')
    $n = [Math]::Min($aa.Count, $bb.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $x = 0; $y = 0
        $xn = [int]::TryParse($aa[$i], [ref]$x)
        $yn = [int]::TryParse($bb[$i], [ref]$y)
        if ($xn -and $yn) {
            if ($x -ne $y) { if ($x -lt $y) { return -1 } else { return 1 } }
        } else {
            $c = [string]::Compare($aa[$i], $bb[$i], $false)
            if ($c -ne 0) { if ($c -lt 0) { return -1 } else { return 1 } }
        }
    }
    if ($aa.Count -ne $bb.Count) { if ($aa.Count -lt $bb.Count) { return -1 } else { return 1 } }
    return 0
}

function Get-PkgVersion {
    param([string]$Dir)
    $f = Join-Path $Dir 'package.json'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try {
        $txt = [System.IO.File]::ReadAllText($f)
        if ($txt -match '"version"\s*:\s*"([^"]+)"') { return $Matches[1] }
    } catch { }
    return $null
}

function Get-RemoteVersion {
    param([string]$Package, [string]$Tag = 'latest')
    $url = $script:Cfg.Registry.TrimEnd('/') + '/' + $Package + '/' + $Tag
    for ($i = 1; $i -le 2; $i++) {
        try {
            $r = Invoke-RestMethod -Uri $url -TimeoutSec 20 -Headers @{ 'Accept' = 'application/json' }
            if ($r.version) { return [string]$r.version }
        } catch { Start-Sleep -Milliseconds 400 }
    }
    return $null
}

function Get-GitHubHead {
    param([string]$Owner, [string]$Repo, [string]$Ref)
    # 没代理时国内直连 api.github.com 基本必超时，所以只给一次机会，别拖时间
    $budget = 2
    if (-not $script:UseProxy) { $budget = 1 }
    if ($script:GitHubFails -ge $budget) { return $null }
    $url = "https://api.github.com/repos/$Owner/$Repo/commits/$Ref"
    $h = @{ 'User-Agent' = 'dsh-launcher'; 'Accept' = 'application/vnd.github+json' }
    try {
        if ($script:UseProxy) { return [string](Invoke-RestMethod -Uri $url -TimeoutSec 12 -Headers $h -Proxy $script:Cfg.Proxy).sha }
        return [string](Invoke-RestMethod -Uri $url -TimeoutSec 5 -Headers $h).sha
    } catch {
        $code = 0
        try { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } } catch { }
        if ($code -ne 404) { $script:GitHubFails = $script:GitHubFails + 1 }
        return $null
    }
}

function Get-PortOwner {
    param([int]$Port)
    if (-not (Test-PortOpen -Port $Port)) { return 0 }      # 没开就秒回，省掉 Get-NetTCPConnection 的 0.5 秒
    try {
        $c = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
        if ($c) { return [int](($c | Select-Object -First 1).OwningProcess) }
    } catch { }
    try {
        $hit = & netstat -ano -p tcp | Select-String (":" + $Port + "\s") | Select-String 'LISTENING' | Select-Object -First 1
        if ($hit) {
            $parts = ($hit.ToString() -split '\s+') | Where-Object { $_ -ne '' }
            return [int]$parts[$parts.Count - 1]
        }
    } catch { }
    return 0
}

function Test-PortOpen {
    param([int]$Port)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(600)) { $client.EndConnect($iar); return $true }
        return $false
    } catch { return $false } finally { try { $client.Close() } catch { } }
}

# 本地代理（Clash）是否真的在监听 —— 比 Get-NetTCPConnection 快 1000 倍
function Test-ProxyAlive {
    $uri = [System.Uri]$script:Cfg.Proxy
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($uri.Host, $uri.Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(300)) { $client.EndConnect($iar); return $true }
        return $false
    } catch { return $false } finally { try { $client.Close() } catch { } }
}

# 代理体检 —— 防止"Clash 没了 / 用全局模式"把整机网络带走（"百度打不开"的复发根因）
#   ① 系统代理指向 127.0.0.1:7890，但端口没人监听 -> 关掉系统代理（否则浏览器所有请求 502）
#   ② 端口活着，但 Clash 处于全局模式            -> 切回规则模式（国内直连，节点挂了也不影响百度）
# 只在这两种情况下动手，其余完全静默；任何异常都不影响启动。
function Repair-ProxyHealth {
    param([switch]$ReportOnly)
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    try {
        $cur = Get-ItemProperty -Path $key -ErrorAction Stop
        if ([int]$cur.ProxyEnable -ne 1) { return }
        if ([string]$cur.ProxyServer -notmatch '7890') { return }

        # ① 死代理：注册表说走代理，代理进程却不在
        if (-not (Test-ProxyAlive)) {
            if ($ReportOnly) {
                Write-Host '  [i] 代理体检：系统代理指向 127.0.0.1:7890 但内核没在跑（-DryRun 下不修改）。' -ForegroundColor Yellow
                return
            }
            Set-ItemProperty -Path $key -Name ProxyEnable -Value 0 -Type DWord
            # 通知已运行的程序（浏览器/微信）立刻重读代理设置，不然要等重启
            try {
                $sig = '[DllImport("wininet.dll", SetLastError=true)] public static extern bool InternetSetOption(IntPtr h, int opt, IntPtr buf, int len);'
                $w = Add-Type -MemberDefinition $sig -Name DshWinInet -Namespace Dsh -PassThru -ErrorAction Stop
                [void]$w::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)   # SETTINGS_CHANGED
                [void]$w::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)   # REFRESH
            } catch { }
            Add-Line '  [OK] 代理体检：7890 无人监听（死代理）-> 已自动关闭系统代理，国内网站直连恢复。'
            return
        }

        # ② 全局模式：会把百度这类国内站也塞进节点，节点一挂全断
        try {
            $cfgNow = Invoke-RestMethod -Uri 'http://127.0.0.1:9090/configs' -TimeoutSec 2 -ErrorAction Stop
            if ([string]$cfgNow.mode -eq 'global') {
                if ($ReportOnly) {
                    Write-Host '  [i] 代理体检：Clash 处于全局模式（-DryRun 下不修改）。' -ForegroundColor Yellow
                    return
                }
                $body = [Text.Encoding]::UTF8.GetBytes('{"mode":"rule"}')
                Invoke-RestMethod -Uri 'http://127.0.0.1:9090/configs' -Method Patch -Body $body -ContentType 'application/json' -TimeoutSec 3 -ErrorAction Stop | Out-Null
                Add-Line '  [OK] 代理体检：Clash 处于全局模式 -> 已切回规则模式（国内直连，不再受节点死活影响）。'
            }
        } catch { }
    } catch { }
}

# 任意按键 = 跳过当前阶段（检查 / 剩余升级项），直接启动
# 只在"可跳过的时刻"调用；正在执行的那一步（npm/pnpm 写文件）不检查按键，提示必须等待
function Test-SkipRequested {
    if ($script:SkipCheck) { return $true }
    try {
        if ([Console]::KeyAvailable) {
            [void][Console]::ReadKey($true)
            return $true
        }
    } catch { }
    return $false
}

function Stop-ProcessTree {
    param([int]$RootId)
    try {
        $kids = Get-CimInstance Win32_Process -Filter "ParentProcessId=$RootId" -ErrorAction SilentlyContinue
        foreach ($k in $kids) { Stop-ProcessTree -RootId ([int]$k.ProcessId) }
    } catch { }
    try { Stop-Process -Id $RootId -Force -ErrorAction SilentlyContinue } catch { }
}

# ============================================================================
#  各项检查
# ============================================================================
function Get-CoreVersion {
    param([string]$Runtime)
    $base = Join-Path $Runtime 'node_modules\@deepseek-ai'
    if (-not (Test-Path -LiteralPath $base)) { return $null }
    $max = $null
    $count = 0
    foreach ($d in (Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -notlike 'dsh-*') { continue }
        $v = Get-PkgVersion $d.FullName
        if (-not $v) { continue }
        $count++
        if (($null -eq $max) -or ((Compare-Ver $v $max) -gt 0)) { $max = $v }
    }
    if ($count -eq 0) { return $null }
    return New-Object psobject -Property @{ Version = $max; Count = $count }
}

function Get-ModelCatalog {
    param([string]$Runtime)
    $f = Join-Path $Runtime 'node_modules\@deepseek-ai\dsh-llm-deepseek\lib\index.js'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try { $txt = [System.IO.File]::ReadAllText($f) } catch { return $null }
    $i = $txt.IndexOf('const DEFAULT_MODELS = [')
    if ($i -lt 0) { return $null }
    $j = $txt.IndexOf('];', $i)
    if ($j -lt 0) { return $null }
    $block = $txt.Substring($i, $j - $i)
    $models = @()
    foreach ($m in [regex]::Matches($block, 'id:\s*"([^"]+)"')) {
        $id = $m.Groups[1].Value
        $name = $id
        $nm = [regex]::Match($block.Substring($m.Index), 'name:\s*"([^"]+)"')
        if ($nm.Success) { $name = $nm.Groups[1].Value }
        $models += New-Object psobject -Property @{ Id = $id; Name = $name }
    }
    if ($models.Count -eq 0) { return $null }
    return $models
}

function Get-DefaultModelConfig {
    param([string]$HomeDir)
    $f = Join-Path $HomeDir 'settings.yaml'
    $out = New-Object psobject -Property @{ Provider = ''; Model = ''; Effort = ''; File = $f }
    if (-not (Test-Path -LiteralPath $f)) { return $out }
    $lines = @(Get-Content -LiteralPath $f -Encoding UTF8 -ErrorAction SilentlyContinue)
    $inBlock = $false
    foreach ($ln in $lines) {
        if ($ln -match '^agent-default-model:\s*$') { $inBlock = $true; continue }
        if (-not $inBlock) { continue }
        if ($ln -match '^\s+\S') {
            if ($ln -match '^\s+provider:\s*(\S+)') { $out.Provider = $Matches[1] }
            elseif ($ln -match '^\s+model:\s*(\S+)') { $out.Model = $Matches[1] }
            elseif ($ln -match '^\s+reasoningEffort:\s*(\S+)') { $out.Effort = $Matches[1] }
        } elseif ($ln.Trim() -ne '') { break }
    }
    return $out
}

function Get-PluginStatus {
    param([string]$ProfileDir)
    $result = @()
    $pkgFile = Join-Path $ProfileDir 'package.json'
    if (-not (Test-Path -LiteralPath $pkgFile)) { return $result }
    $json = $null
    try { $json = Get-Content -LiteralPath $pkgFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $result }
    if (-not $json.dependencies) { return $result }
    $lock = ''
    $lockFile = Join-Path $ProfileDir 'pnpm-lock.yaml'
    if (Test-Path -LiteralPath $lockFile) {
        try { $lock = [System.IO.File]::ReadAllText($lockFile) } catch { $lock = '' }
    }
    foreach ($prop in $json.dependencies.PSObject.Properties) {
        $name = $prop.Name
        $spec = [string]$prop.Value
        $installed = Get-PkgVersion (Join-Path $ProfileDir ("node_modules\" + $name))
        $item = New-Object psobject -Property @{
            Name = $name; Spec = $spec; Installed = $installed
            Kind = 'npm'; Latest = $null; Locked = $null; Head = $null; Upgradeable = $false; Note = ''
        }
        if ($spec -match '^github:(?<o>[^/]+)/(?<r>[^#]+)#(?<ref>.+)$') {
            $owner = $Matches['o']; $repo = $Matches['r']; $ref = $Matches['ref']
            $item.Kind = 'git'
            $needle = [regex]::Escape($name + '@https://codeload.github.com/' + $owner + '/' + $repo + '/tar.gz/')
            $m = [regex]::Match($lock, $needle + '([0-9a-f]{7,40})')
            if ($m.Success) { $item.Locked = $m.Groups[1].Value }
            $item.Head = Get-GitHubHead -Owner $owner -Repo $repo -Ref $ref
            if ($item.Head -and $item.Locked) {
                $item.Upgradeable = ($item.Locked -ne $item.Head)
            }
        } else {
            $latest = Get-RemoteVersion -Package $name -Tag 'latest'
            $item.Latest = $latest
            if ($latest -and $installed) { $item.Upgradeable = ((Compare-Ver $latest $installed) -gt 0) }
            elseif ($latest -and -not $installed) { $item.Upgradeable = $true }
        }
        $result += $item
    }
    return $result
}

function Get-NodeLatest {
    param([int]$Major)
    $url = $script:Cfg.NodeMirror + '/latest-v' + $Major + '.x/'
    $r = $null
    for ($i = 1; $i -le 2; $i++) {
        try { $r = Invoke-RestMethod -Uri $url -TimeoutSec 20; break } catch { Start-Sleep -Milliseconds 400 }
    }
    if (-not $r) { return $null }
    $best = $null
    foreach ($f in $r) {
        $nm = [string]$f.name
        if ($nm -match '^node-v(\d+\.\d+\.\d+)-win-x64\.zip$') {
            $v = $Matches[1]
            if (($null -eq $best) -or ((Compare-Ver $v $best) -gt 0)) { $best = $v }
        }
    }
    return $best
}

# ============================================================================
#  检查汇总
# ============================================================================
function Invoke-StatusCheck {
    $cfg = $script:Cfg
    $script:Items = @()

    Write-Host ''
    Write-Host '正在检查各组件版本 ...' -ForegroundColor Cyan
    Write-Host '（想跳过检查直接启动，按 Esc）' -ForegroundColor DarkGray

    # 代理（GitHub 检查用）
    $script:UseProxy = Test-ProxyAlive

    # ---- 运行环境 / 端口状态 ----
    $script:RunningPid = Get-PortOwner -Port $cfg.Port
    $binPath = Join-Path $cfg.RuntimeDir 'node_modules\@deepseek-ai\dsh\lib\bin.js'
    $runtimeReady = Test-Path -LiteralPath $binPath

    if (Test-SkipRequested) { $script:CheckAborted = $true; return @() }

    # ---- (1) dsh 主体 ----
    $dshInstalled = Get-PkgVersion (Join-Path $cfg.RuntimeDir 'node_modules\@deepseek-ai\dsh')
    $dshLatest = Get-RemoteVersion -Package $cfg.DshPackage -Tag 'latest'
    $dshNext = Get-RemoteVersion -Package $cfg.DshPackage -Tag 'next'
    $dshTarget = $dshLatest                      # 默认只跟正式通道 latest
    $dshUpgrade = $false
    if ($dshTarget -and $dshInstalled) { $dshUpgrade = ((Compare-Ver $dshTarget $dshInstalled) -gt 0) }
    elseif ($dshTarget -and -not $runtimeReady) { $dshUpgrade = $true }
    $dshNextUpgrade = $false                     # 预发布通道 next（默认不勾选）
    if ($dshNext -and $dshInstalled) { $dshNextUpgrade = ((Compare-Ver $dshNext $dshInstalled) -gt 0) }

    # ---- (2) 内核 ----
    $core = Get-CoreVersion -Runtime $cfg.RuntimeDir
    $corePublished = $dshLatest
    if ($dshNext -and (($null -eq $corePublished) -or ((Compare-Ver $dshNext $corePublished) -gt 0))) { $corePublished = $dshNext }
    $coreUpgrade = $false
    if ($core -and $corePublished) { $coreUpgrade = ((Compare-Ver $corePublished $core.Version) -gt 0) }
    if (-not $runtimeReady) { $coreUpgrade = $true }

    if (Test-SkipRequested) { $script:CheckAborted = $true; return @() }

    # ---- (3) 插件 ----
    $profileDir = Join-Path $cfg.DshHome ('profiles\' + $cfg.Profile)
    $plugins = @(Get-PluginStatus -ProfileDir $profileDir)

    # ---- (4) 模型 ----
    $modelCatalog = Get-ModelCatalog -Runtime $cfg.RuntimeDir
    $modelCfg = Get-DefaultModelConfig -HomeDir $cfg.DshHome
    $modelKnown = $null
    if ($modelCatalog -and $modelCfg.Model) {
        $modelKnown = $false
        foreach ($mm in $modelCatalog) { if ($mm.Id -eq $modelCfg.Model) { $modelKnown = $true } }
    }

    if (Test-SkipRequested) { $script:CheckAborted = $true; return @() }

    # ---- (5) 运行环境 ----
    $nodeCurrent = ''
    try { $nodeCurrent = (& node -v 2>$null | Out-String).Trim() } catch { }
    $nodeMajor = 0
    if ($nodeCurrent -match '^v(\d+)\.') { $nodeMajor = [int]$Matches[1] }
    $nodeLatest = $null
    if ($nodeMajor -gt 0) { $nodeLatest = Get-NodeLatest -Major $nodeMajor }
    $nodeUpgrade = $false
    if ($nodeLatest -and $nodeCurrent) {
        $nodeUpgrade = ((Compare-Ver $nodeLatest $nodeCurrent) -gt 0)
    }
    $nvm = Get-Command nvm.exe -ErrorAction SilentlyContinue
    if (-not $nvm) { $nodeUpgrade = $false }
    $pnpmVer = ''
    try { $pnpmVer = (& pnpm --version 2>$null | Out-String).Trim() } catch { }

    # ---- 报告 ----
    $now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Line ('DSH 启动器 · 启动前检查        ' + $now)
    Add-Line ('==================================================================')
    Add-Line ('运行目录    ' + $cfg.RuntimeDir)
    Add-Line ('DSH_HOME    ' + $cfg.DshHome)
    Add-Line ('配置档      ' + $cfg.Profile + '      端口 ' + $cfg.Port)
    Add-Line ('npm 源      ' + $cfg.Registry)
    Add-Line ('本地代理    ' + $(if ($script:UseProxy) { '127.0.0.1:7890 已开启（GitHub 检查走它）' } else { '未开启（跳过 GitHub 检查，直接启动不受影响）' }))
    Add-Line ('------------------------------------------------------------------')

    # (1)
    Add-Line ('[1] DSH 主体  ' + $cfg.DshPackage)
    if (-not $runtimeReady) {
        Add-Line ('    尚未安装（首次启动会自动下载安装）')
    } else {
        Add-Line ('    已安装 ' + $dshInstalled + '      发布通道 latest ' + $(if ($dshLatest) { $dshLatest } else { '查询失败' }) + '  /  next ' + $(if ($dshNext) { $dshNext } else { '查询失败' }))
        if (-not $dshLatest) { Add-Line ('    [?] 连不上 npm 源，本次不判断是否需要升级') }
        elseif ($dshUpgrade) { Add-Line ('    [!] 可升级到 ' + $dshTarget) } else { Add-Line ('    [OK] 已是最新（正式通道 latest）') }
        if ($dshNextUpgrade) { Add-Line ('    [i] 预发布通道 next 有 ' + $dshNext + '（默认不勾选）') }
    }

    # (2)
    Add-Line ('[2] 内核  @deepseek-ai/dsh-* 核心包')
    if ($core) {
        Add-Line ('    已安装 ' + $core.Version + '（' + $core.Count + ' 个包）    发布通道 ' + $(if ($corePublished) { $corePublished } else { '查询失败' }))
        if (-not $corePublished) { Add-Line ('    [?] 连不上 npm 源，本次不判断是否需要升级') }
        elseif ($coreUpgrade) { Add-Line ('    [!] 可升级到 ' + $corePublished) } else { Add-Line ('    [OK] 已是最新') }
    } else {
        Add-Line ('    未检测到已安装的内核')
    }

    # (3)
    Add-Line ('[3] 插件  配置档 ' + $cfg.Profile + '（' + $plugins.Count + ' 个）')
    if ($plugins.Count -eq 0) {
        Add-Line ('    该配置档没有声明插件依赖')
    }
    foreach ($p in $plugins) {
        if ($p.Kind -eq 'git') {
            $sha1 = ''
            $sha2 = ''
            if ($p.Locked) { $sha1 = $p.Locked.Substring(0, [Math]::Min(7, $p.Locked.Length)) }
            if ($p.Head) { $sha2 = $p.Head.Substring(0, [Math]::Min(7, $p.Head.Length)) }
            $desc = $p.Name + '  版本 ' + $(if ($p.Installed) { $p.Installed } else { '?' }) + '   GitHub ' + $p.Spec.Replace('github:', '')
            if ($p.Head -and $p.Locked) {
                $desc += '  锁定 ' + $sha1 + ' / 远端 ' + $sha2
                if ($p.Upgradeable) { $desc = '    [!] ' + $desc + '  ->  有新提交' } else { $desc = '    [OK] ' + $desc }
            } else {
                $desc = '    [?] ' + $desc + '  ->  GitHub 无法访问，本次不检查'
            }
            Add-Line $desc
        } else {
            $desc = '版本 ' + $(if ($p.Installed) { $p.Installed } else { '未安装' }) + '  ->  ' + $(if ($p.Latest) { $p.Latest } else { '查询失败' })
            if ($p.Upgradeable) { $desc = '    [!] ' + $p.Name + '  ' + $desc } else { $desc = '    [OK] ' + $p.Name + '  ' + $desc }
            Add-Line $desc
        }
    }

    # (4)
    Add-Line ('[4] 模型  供应商 ' + $(if ($modelCfg.Provider) { $modelCfg.Provider } else { '(未配置)' }))
    if ($modelCatalog) {
        $ids = @()
        foreach ($mm in $modelCatalog) { $ids += $mm.Id }
        Add-Line ('    当前默认模型 ' + $(if ($modelCfg.Model) { $modelCfg.Model } else { '(未配置)' }) + '   ' + $(if ($modelKnown -eq $true) { '[OK] 在模型清单中' } elseif ($modelKnown -eq $false) { '[!] 不在模型清单中，请到设置里重新选择' } else { '[?] 无法比对' }))
        Add-Line ('    可用模型清单 ' + ($ids -join ', '))
    } else {
        Add-Line ('    未能读取模型清单（内核未安装？）')
    }
    Add-Line ('    说明：模型清单由内核提供，随内核升级自动更新，无需单独升级')

    # (5)
    Add-Line ('[5] 运行环境')
    $nodeState = '[OK] 已是最新'
    if (-not $nodeLatest) { $nodeState = '[?] 查询失败，本次不判断' }
    elseif ($nodeUpgrade) { $nodeState = '[!] 可升级' }
    elseif (-not $nvm) { $nodeState = '[i] 有更新版本，但没装 nvm，无法自动升级' }
    Add-Line ('    Node ' + $(if ($nodeCurrent) { $nodeCurrent } else { '未检测到' }) + '   同系列最新 ' + $(if ($nodeLatest) { 'v' + $nodeLatest } else { '查询失败' }) + '   ' + $nodeState)
    Add-Line ('    pnpm ' + $(if ($pnpmVer) { $pnpmVer } else { '未检测到' }) + '    Node 路径 ' + $(Invoke-Safe { (Get-Command node.exe -ErrorAction SilentlyContinue).Source } '-'))
    Add-Line ('------------------------------------------------------------------')
    if ($script:RunningPid -gt 0) {
        Add-Line ('当前状态    DSH 正在运行（端口 ' + $cfg.Port + '，PID ' + $script:RunningPid + '）')
    } else {
        Add-Line ('当前状态    DSH 未运行')
    }

    # ---- 汇总升级项 ----
    $items = @()

    if (-not $runtimeReady) {
        $items += New-Object psobject -Property @{
            Id = 'bootstrap'; Checked = $true; Target = $dshTarget
            Label = '安装 DSH 运行环境 ' + $dshTarget + '（首次，需下载，约几分钟）'
        }
    } elseif ($dshUpgrade) {
        $items += New-Object psobject -Property @{
            Id = 'dsh'; Checked = $true; Target = $dshTarget
            Label = 'DSH 主体 ' + $dshInstalled + ' -> ' + $dshTarget
        }
    }

    if ($runtimeReady -and $dshNextUpgrade -and ($dshNext -ne $dshLatest)) {
        $items += New-Object psobject -Property @{
            Id = 'dsh'; Checked = $false; Target = $dshNext
            Label = 'DSH 主体 ' + $dshInstalled + ' -> ' + $dshNext + '（预发布通道 next，默认跳过）'
        }
    }

    if ($runtimeReady -and $coreUpgrade) {
        $items += New-Object psobject -Property @{
            Id = 'core'; Checked = $true; Target = $corePublished
            Label = '内核核心包 ' + $core.Version + ' -> ' + $corePublished
        }
    }

    foreach ($p in $plugins) {
        if (-not $p.Upgradeable) { continue }
        if ($p.Kind -eq 'git') {
            $lbl = $p.Name + '（GitHub 有新提交）'
        } else {
            $lbl = $p.Name + ' ' + $p.Installed + ' -> ' + $p.Latest
        }
        $items += New-Object psobject -Property @{ Id = 'plugin:' + $p.Name; Checked = $true; Target = $p.Latest; Label = $lbl }
    }

    if ($nodeUpgrade) {
        $items += New-Object psobject -Property @{
            Id = 'node'; Checked = $false; Target = $nodeLatest
            Label = 'Node ' + $nodeCurrent + ' -> v' + $nodeLatest + '（默认跳过，需手动升级）'
        }
    }

    $autoCount = @($items | Where-Object { $_.Checked }).Count
    $summary = '可升级项 ' + $items.Count + ' 个，自动升级 ' + $autoCount + ' 个'
    if ($items.Count -gt $autoCount) { $summary += '（预发布通道 / Node 默认跳过）' }
    Add-Line $summary
    $script:Items = $items
    $script:Status = New-Object psobject -Property @{
        RuntimeReady = $runtimeReady
        Plugins = $plugins
        NodeTarget = $nodeLatest
    }
    return $items
}

# ============================================================================
#  升级动作
# ============================================================================
#  DSH 补丁：让 GUI 的「在文件资源管理器中显示」真的打开窗口并置顶
#
#  上游实现：explorer.exe /select,<文件URL>。两个问题：
#    1) 调用方是后台进程（node 跑着 dsh web），Windows 前台锁定不让它抢焦点，
#       窗口会沉在别的资源管理器窗口后面 —— 用户看到"点了没反应"；
#    2) 更关键：node 直接 execFile("explorer.exe") 会带 STARTUPINFO 的 SW_HIDE，
#       explorer 收到后**静默什么都不做**（还会留下一堆僵尸 explorer 进程）。
#
#  2026-09-15 实测（每种写法都用 UI Automation 核对真实窗口，不靠 Shell COM 缓存）：
#    · node execFile explorer.exe /select,...            -> 开不出窗口（假成功）
#    · node execFile explorer.exe 传 file:// URL         -> 开出的是「桌面」（错）
#    · PowerShell Start-Process explorer.exe             -> 能开，但会触发 360 主动防御弹窗
#    · node -> cmd /c <shim.cmd> <路径>                  -> ✅ 正确开窗，带空格/中文都对，360 弹窗 0
#  所以 v4 分工：
#    · 开窗：node 调 cmd 执行 dsh-reveal.cmd（内部 explorer.exe /select,"%~1"），绕开 SW_HIDE
#    · 置前：PowerShell 调 dsh-focus.ps1，只做 AppActivate，绝不自己启动 explorer
# ============================================================================
function Get-RevealPatchHelper {
    return @'
/* dsh-launcher-patch: reveal-foreground v7 —— 由 DSH 启动器注入（文件末尾"包装"注入），dsh 升级后启动器会自动重打 */
const __dshRevealOriginal = revealNativePath;
revealNativePath = async function dshRevealWrapped(path, signal, internals = {}) {
	try {
		if ((internals.platform ?? process.platform) === "win32") {
			// runner 优先用调用方传进来的（internals.run），没有再看本模块的 runNativeCommand，
			// 两者都没有就退回原实现 —— 这样不同版本打包方式都能用。
			const run = internals.run ?? (typeof runNativeCommand === "function" ? runNativeCommand : null);
			if (run) {
				const target = String(path);
				// ① 开窗：经 cmd 转一手，让 explorer 拿到正常启动信息（node 直接 execFile 会被 SW_HIDE 吃掉）
				try { await run("cmd.exe", ["/c", "__SHIM_CMD__", target], signal); }
				catch (launchError) { if (!(launchError && launchError.code === 1)) throw launchError; }
				// ② 置前：PowerShell 只做 AppActivate，不自己启动 explorer（否则触发 360）
				try {
					const shell = (process.env.SystemRoot || "C:\\Windows") + "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe";
					await run(shell, ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", "__FOCUS_PS1__", "-Path", target], signal);
				} catch { }
				return;
			}
		}
	} catch { /* 任何异常都退回原实现，绝不把功能弄坏 */ }
	return __dshRevealOriginal(path, signal, internals);
};
'@
}

# 补丁失败时把诊断落到文件，用户可以直接把文件发回来（控制台内容不好复制）
# 补丁失败时把诊断落到文件，用户可以直接把文件发回来（控制台内容不好复制）
function Write-PatchDiag {
    param([string]$File, [string]$Text, [string]$Note)
    try {
        $diag = Join-Path $PSScriptRoot 'patch-diag.txt'
        $lines = @()
        $lines += 'DSH 启动器 · 补丁诊断  ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        $lines += '启动器版本: ' + $script:LauncherVersion + '（置顶补丁 ' + $script:PatchMarker + '）'
        $lines += '目标文件: ' + $File
        if (Test-Path -LiteralPath $File) { $lines += ('文件大小: ' + (Get-Item -LiteralPath $File).Length + ' 字节') }
        $lines += '本次匹配情况: ' + $Note
        $pkgDir = Split-Path -Parent (Split-Path -Parent $File)
        $pkg = Join-Path $pkgDir 'package.json'
        if (Test-Path -LiteralPath $pkg) {
            $ver = (Get-Content -LiteralPath $pkg -Raw -ErrorAction SilentlyContinue) -replace '\s+', ' '
            if ($ver.Length -gt 300) { $ver = $ver.Substring(0, 300) }
            $lines += '包信息: ' + $ver
        }
        $lines += '首 6 行:'
        $head = @($Text -split "`n" | Select-Object -First 6)
        foreach ($h in $head) { $lines += ('  | ' + $h.TrimEnd()) }
        $lines += ''
        $lines += '候选线索（含 reveal / explorer / export / from 的行，最多 30 行）:'
        $hits = @($Text -split "`n" | Select-String -Pattern 'reveal|explorer|export |from ' | Select-Object -First 30)
        if ($hits.Count -eq 0) { $lines += '  (一行都没有 —— 说明这个版本根本不是同一套实现)' }
        foreach ($h in $hits) { $lines += ('  ' + $h.LineNumber + ': ' + $h.Line.Trim()) }
        [System.IO.File]::WriteAllText($diag, ($lines -join "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
        Write-Host ('      · 诊断已写入：' + $diag) -ForegroundColor DarkGray
    } catch {
        Write-Host ('      · 诊断写入失败：' + $_.Exception.Message) -ForegroundColor DarkGray
    }
}

function Invoke-DshPatches {
    param([string]$RuntimeDir)
    $entry = Join-Path $RuntimeDir 'node_modules\@deepseek-ai\dsh-native-command\lib\index.js'
    if (-not (Test-Path -LiteralPath $entry)) {
        Write-Host '  [i] 补丁：没找到 dsh-native-command，跳过' -ForegroundColor DarkGray
        return $false
    }
    # 两个外部脚本：开窗 shim（必须放无空格路径，cmd 才不出错）+ 置前脚本
    $focus = Join-Path $PSScriptRoot 'dsh-focus.ps1'
    $shim  = Join-Path $env:USERPROFILE '.dsh\dsh-reveal.cmd'
    if (-not (Test-Path -LiteralPath $focus)) {
        Write-Host ("  [!] 补丁：缺少 dsh-focus.ps1（应在 {0}），窗口能开但不会自动置前" -f $focus) -ForegroundColor Yellow
    }
    if (-not (Test-Path -LiteralPath $shim)) {
        $dir = Split-Path -Parent $shim
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        [System.IO.File]::WriteAllText($shim, "@echo off`r`nexplorer.exe /select,`"%~1`"`r`n", [System.Text.Encoding]::ASCII)
        Write-Host ("  [i] 补丁：已创建开窗 shim {0}" -f $shim) -ForegroundColor DarkGray
    }

    # v8：注入逻辑整体搬到 node 脚本 patch-native-command.mjs ——
    # v4/v5 靠上游固定结构、v6/v7 靠相对转发链，在另一台电脑（包布局不同）都失败了。
    # node 脚本里做的是：顺着转发链找 → 整包搜索 → 兄弟 @deepseek-ai 包搜索，
    # 找到真正声明 revealNativePath 的文件再在末尾追加包装，失败时自己写 patch-diag.txt。
    $helper = Join-Path $PSScriptRoot 'patch-native-command.mjs'
    $node   = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
    if (-not (Test-Path -LiteralPath $helper)) {
        Write-Host '  [!] 补丁：找不到 patch-native-command.mjs（应与启动器同目录），跳过（功能退回原样）' -ForegroundColor Yellow
        return $false
    }
    if (-not $node) {
        Write-Host '  [!] 补丁：找不到 node.exe，跳过（功能退回原样）' -ForegroundColor Yellow
        return $false
    }
    $diag = Join-Path $PSScriptRoot 'patch-diag.txt'
    $raw  = & $node $helper --runtime $RuntimeDir --shim $shim --focus $focus --marker ([string]$script:PatchMarker) --diag $diag 2>&1
    $text = (($raw | ForEach-Object { [string]$_ }) -join "`n")
    $result = 'UNKNOWN'
    foreach ($line in ($text -split "`n")) {
        if ($line.StartsWith('RESULT: ')) { $result = $line.Substring(8).Trim(); continue }
        if ($line.Trim().Length -eq 0) { continue }
        $color = 'Gray'
        if ($line -match '\[OK\]') { $color = 'Green' } elseif ($line -match '\[!\]') { $color = 'Yellow' } elseif ($line -match '\[i\]') { $color = 'DarkGray' }
        Write-Host $line -ForegroundColor $color
    }
    # NA = 这个 DSH 版本本来就没有 revealNativePath（补丁不适用），不是失败
    if ($result -eq 'OK' -or $result -eq 'NA') { return $true }
    return $false
}

# ============================================================================
#  微信桥接补丁：让 GUI 会话里的提问也能在微信上回答
#
#  背景：ask_user_question 走 ctx.userQuestions 的 waterfall，只有 GUI（浏览器）应答器；
#        微信侧没有任何应答器，所以在 GUI 会话里提问 → 用户离开电脑就没人答，任务卡死。
#
#  补丁做两件事（只改插件，不动守护进程 —— 插件在 /api/prompt 就能看到入站原文）：
#    1) 在插件的 apply(ctx) 里注册 user-questions/request 应答器：
#       把问题+编号选项推到微信，然后和 GUI 应答器赛跑，谁先给答案用谁的；
#    2) 在 /api/prompt 入口拦截"这是某个待答问题的回答"的消息，直接裁决并
#       **不建 turn**（否则会当成一条新任务发给 agent）。
#
#  插件升级会整包覆盖，所以启动器每次启动都自检重打。
# ============================================================================
function Get-BridgePatchHelper {
    return @'
    /* dsh-bridge-patch: question-answerer v5 —— 由 DSH 启动器注入；插件升级后启动器会自动重打 */
    let questionAnswerer = null;
    function createQuestionAnswerer(deps) {
        const timeoutMs = deps.timeoutMs ?? 600000;
        let pending = null;
        const describe = (request) => {
            const qs = request.questions ?? [];
            const out = [];
            qs.forEach((q, i) => {
                const head = q.header ? q.header + '：' : '';
                out.push((qs.length > 1 ? (i + 1) + ') ' : '') + head + q.question);
                (q.options ?? []).forEach((o, j) => out.push('   ' + (j + 1) + '. ' + o.label));
            });
            return out.join('\n');
        };
        const settle = (entry) => {
            if (pending === entry) pending = null;
            clearTimeout(entry.timer);
        };
        // 等微信的窗口：优先读运行时配置文件（`<dataDir>/question-handoff-ms.txt`），
        // 读不到才用安装时写死的默认值 —— 这样以后调窗口只要改文件，**不用重启 DSH**。
        const windowMs = () => {
            if (typeof deps.readWindowMs === 'function') {
                const n = Number(deps.readWindowMs());
                if (Number.isFinite(n) && n >= 0) return n;
            }
            return deps.handoffMs ?? 60000;
        };
        async function handle(request, next) {
            if (pending) return next();                       // 已经有一个待答：交给 GUI，微信上不排队
            const qs = (request && request.questions) || [];
            if (qs.length === 0) return next();
            const box = Promise.withResolvers();
            const entry = { request, box };
            entry.timer = setTimeout(() => {
                if (pending === entry) { pending = null; box.resolve(null); }
            }, timeoutMs);
            pending = entry;
            let pushed = false;
            try {
                await deps.push('【需要你回答一个问题】\n' + describe(request)
                    + '\n\n在微信里回复编号即可。'
                    + Math.round(windowMs() / 1000) + ' 秒内没等到你回复，我会在电脑界面上再弹一次这个提问框。');
                pushed = true;
            } catch (err) {
                deps.log('question push failed', { error: String(err) });
            }
            if (!pushed) {                                    // 推不出去（通道冷/守护进程没跑）→ 直接交给 GUI，别耽误用户
                settle(entry);
                return next();
            }
            // 头 handoffMs 只等微信：这段时间**不调用 next()**，所以 GUI 不会创建提问框
            // （用户要求：微信答完电脑上别留着框）。
            const wxFirst = await Promise.race([
                box.promise,
                new Promise((r) => setTimeout(() => r(null), windowMs())),
            ]);
            if (wxFirst) { settle(entry); return wxFirst; }
            // 超时了：把问题交给 GUI（此时电脑上才弹框）。但微信这条路**继续有效** ——
            // 在微信里回编号照样算数（谁先到用谁的）。代价：若微信后答，电脑上那个框会留着
            // （客户端 PendingQuestion 撤不掉，只能不让它创建）。权衡见 README。
            const gui = Promise.resolve().then(() => next()).then((a) => a ?? null, () => null);
            try {
                const wx = await Promise.race([box.promise, gui]);
                if (wx) return wx;
                return await gui;
            } finally {
                settle(entry);
            }
        }
        /** 入站消息是不是当前待答问题的回答？是就裁决掉并返回 true（调用方不要再建 turn）。 */
        function tryResolve(text) {
            const entry = pending;
            if (!entry) return false;
            const raw = String(text ?? '').trim();
            if (!raw) return false;
            const qs = entry.request.questions ?? [];
            const answers = [];
            if (qs.length === 1) {
                const q = qs[0];
                const opts = q.options ?? [];
                const n = /^\d+$/.test(raw) ? Number(raw) : NaN;
                if (!Number.isNaN(n) && n >= 1 && n <= opts.length) answers.push({ id: q.id, selected: [opts[n - 1].label] });
                else if (opts.length === 0) answers.push({ id: q.id, selected: [], custom: raw });
                else return false;                            // 有选项却回了别的话：当新任务交给 agent
            } else {
                const parts = raw.split(/[\s,，、]+/).filter(Boolean);
                if (parts.length !== qs.length) return false;
                for (let i = 0; i < qs.length; i++) {
                    const q = qs[i];
                    const opts = q.options ?? [];
                    const n = /^\d+$/.test(parts[i]) ? Number(parts[i]) : NaN;
                    if (!Number.isNaN(n) && n >= 1 && n <= opts.length) answers.push({ id: q.id, selected: [opts[n - 1].label] });
                    else if (opts.length === 0) answers.push({ id: q.id, selected: [], custom: parts[i] });
                    else return false;
                }
            }
            if (pending === entry) pending = null;
            clearTimeout(entry.timer);
            entry.box.resolve({ answers });
            return true;
        }
        return { handle, tryResolve };
    }
    try {
        questionAnswerer = createQuestionAnswerer({
            timeoutMs: 600000,
            handoffMs: 60000,          // 头 60 秒只等微信；超时才在电脑上弹提问框
            push: async (message) => {
                const acct = latestAccountId();
                const key = acct ? `${acct}::${ownerUserIdOf(acct)}` : '';
                return await pushApprovalMessage(message, key);
            },
            log: debugLog,
        });
        // 关键：必须 prepend。cordis 的 waterfall 是"先注册先跑，不调 next 就否决后面"
        // （cordis/lib/index.js: "Listeners run outermost-first; a listener that does not
        //  call next() vetoes the rest of the chain"）。GUI 应答器在 DSH 启动时就注册好了，
        // 不插队的话永远轮不到我们 —— 2026-09-14 实测踩过：两次提问一次都没推出去。
        // 注册在根 ctx 上（_hooks 沿原型链共享），作用域过滤后对所有 agent 生效。
        // 窗口可在运行时调：改这个文件即可，不用重启 DSH（读不到就用上面的 handoffMs 默认值）
        const windowFile = join(dataDir, 'question-handoff-ms.txt');
        const readWindowMs = () => {
            try {
                const n = Number(String(readFileSync(windowFile, 'utf8')).trim());
                return Number.isFinite(n) && n >= 0 ? n : NaN;
            } catch {
                return NaN;
            }
        };
        ctx.on('user-questions/request', (req, next) => questionAnswerer.handle(req, next), { prepend: true });
        debugLog('wechat question answerer installed (prepend)');
    } catch (err) {
        debugLog('question answerer setup failed', { error: String(err) });
    }
'@
}

function Get-BridgeDaemonPatchHelper {
    return @'
        // [dsh-bridge-patch: qa-answer-short-circuit v1] 微信答题短路：这条消息已经被插件
        // 裁决成"某个提问的回答"，不会再跑 turn。必须立刻返回，否则守护进程会一直等一个
        // 永远不来的流式 turn —— 微信上"正在输入"常亮不灭，5 分钟后还会收到一条安抚消息。
        // return 会走下面的 finally：停 typing、会话回 idle。
        if (accepted && typeof accepted === 'object' && accepted.answered)
            return;
'@
}

function Invoke-BridgePluginPatch {
    param([string]$DshHome, [string]$ProfileName)
    $file = Join-Path $DshHome ('profiles\' + $ProfileName + '\node_modules\@lanbaolu\dsh-wechat-bridge\lib\index.js')
    if (-not (Test-Path -LiteralPath $file)) {
        Write-Host '  [i] 微信补丁：这台机器没装微信桥接插件，跳过' -ForegroundColor DarkGray
        return $false
    }
    $txt = [System.IO.File]::ReadAllText($file)
    if ($txt.Contains([string]$script:BridgePatchMarker)) {
        Write-Host '  [OK] 微信补丁：微信内回答提问 v5（已就位）' -ForegroundColor Green
        return $true
    }
    if ($txt.Contains('function createQuestionAnswerer(')) {
        $bak = $file + '.dshbak'
        if (Test-Path -LiteralPath $bak) {
            Copy-Item -LiteralPath $bak -Destination $file -Force
            $txt = [System.IO.File]::ReadAllText($file)
            Write-Host '  [i] 微信补丁：发现旧版补丁，已用备份还原，准备注入新版' -ForegroundColor DarkGray
        } else {
            Write-Host '  [!] 微信补丁：有旧版补丁但没有备份，跳过（避免叠加）' -ForegroundColor Yellow
            return $false
        }
    }
    # 注入点 1：审批管理器之后（同一函数作用域，路由看得见）
    $anchorA = '    ctx.effect(() => () => approvalManager?.dispose());'
    # 注入点 2：/api/prompt 里 text 校验之后
    $anchorB = @'
                if (!text) {
                    sendJson(res, 400, { ok: false, error: 'text is required' });
                    return;
                }
'@
    $anchorB = $anchorB.Replace("`r`n", "`n").TrimEnd("`n")
    if (-not $txt.Contains($anchorA)) {
        Write-Host '  [!] 微信补丁：找不到注入点 A（审批管理器那行），插件结构变了，跳过' -ForegroundColor Yellow
        return $false
    }
    if ($txt.Contains("`r`n")) {
        $anchorB = $anchorB.Replace("`n", "`r`n")
        $anchorA = $anchorA
    }
    if (-not $txt.Contains($anchorB)) {
        Write-Host '  [!] 微信补丁：找不到注入点 B（/api/prompt 的 text 校验），插件结构变了，跳过' -ForegroundColor Yellow
        return $false
    }
    $helper = (Get-BridgePatchHelper).Replace("`r`n", "`n").TrimEnd("`n")
    $intercept = @'
                // [dsh-bridge-patch: qa-intercept v1] 先看这是不是对某个待答问题的回答
                if (questionAnswerer) {
                    let answered = false;
                    try { answered = questionAnswerer.tryResolve(text); } catch { answered = false; }
                    if (answered) {
                        sendJson(res, 200, { accepted: true, answered: true });
                        return;
                    }
                }
'@
    $intercept = $intercept.Replace("`r`n", "`n").TrimEnd("`n")
    if ($txt.Contains("`r`n")) {
        $helper = $helper.Replace("`n", "`r`n")
        $intercept = $intercept.Replace("`n", "`r`n")
    }
    $out = $txt.Replace($anchorA, $anchorA + "`n" + $helper).Replace($anchorB, $anchorB + "`n" + $intercept)
    Copy-Item -LiteralPath $file -Destination ($file + '.dshbak') -Force
    [System.IO.File]::WriteAllText($file, $out)
    $chk = [System.IO.File]::ReadAllText($file)
    if ($chk.Contains('function createQuestionAnswerer(') -and $chk.Contains('{ prepend: true }')) {
        Write-Host '  [OK] 微信补丁：微信内回答提问 v5（已注入，原文件备份为 .dshbak）' -ForegroundColor Green
        return $true
    }
    Write-Host '  [!] 微信补丁：写入后自检没过，已留 .dshbak 备份' -ForegroundColor Red
    return $false
}

# ---------------------------------------------------------------------------
#  微信桥接补丁（守护进程侧）：答题短路
#  背景：插件把入站消息裁决成"某个提问的回答"后直接回了 { answered: true }，但守护进程
#  （lib\bridge\main.js）此时已经 startTyping 并 await 流式 turn —— 那个 turn 永远不会来，
#  于是微信里"正在输入"常亮不灭、5 分钟后还多发一条安抚消息。这里加一条短路让它立刻收尾。
#  注意：守护进程只在 DSH 启动时由插件拉起，所以启动器打完补丁后无需额外重启它。
# ---------------------------------------------------------------------------
function Invoke-BridgeDaemonPatch {
    param([string]$DshHome, [string]$ProfileName)
    $file = Join-Path $DshHome ('profiles\' + $ProfileName + '\node_modules\@lanbaolu\dsh-wechat-bridge\lib\bridge\main.js')
    if (-not (Test-Path -LiteralPath $file)) {
        Write-Host '  [i] 微信补丁：没找到守护进程脚本 lib\bridge\main.js，跳过' -ForegroundColor DarkGray
        return $false
    }
    $txt = [System.IO.File]::ReadAllText($file)
    if ($txt.Contains([string]$script:BridgeDaemonPatchMarker)) {
        Write-Host '  [OK] 微信补丁：答题短路（守护进程，已就位）' -ForegroundColor Green
        return $true
    }
    $bak = $file + '.dshbak'
    if ($txt.Contains('accepted.answered')) {
        if (Test-Path -LiteralPath $bak) {
            Copy-Item -LiteralPath $bak -Destination $file -Force
            $txt = [System.IO.File]::ReadAllText($file)
            Write-Host '  [i] 微信补丁：守护进程发现旧版短路补丁，已用备份还原，准备注入新版' -ForegroundColor DarkGray
        } else {
            Write-Host '  [!] 微信补丁：守护进程有旧版补丁但没备份，跳过（避免叠加）' -ForegroundColor Yellow
            return $false
        }
    }
    # 注入点：sendToDsh 里"DSH 未接受"那段的后面（紧跟 client.prompt 的返回值判断）
    $anchor = @'
        if (!accepted) {
            await sender.sendText(fromUserId, contextToken, '消息已收到，但 DSH 未接受处理请求。');
            session.state = 'idle';
            sessionStore.save(fromUserId, session);
            return;
        }
'@
    $anchor = $anchor.Replace("`r`n", "`n").TrimEnd("`n")
    $inject = (Get-BridgeDaemonPatchHelper).Replace("`r`n", "`n").TrimEnd("`n")
    if ($txt.Contains("`r`n")) {
        $anchor = $anchor.Replace("`n", "`r`n")
        $inject = $inject.Replace("`n", "`r`n")
    }
    if (-not $txt.Contains($anchor)) {
        Write-Host '  [!] 微信补丁：守护进程找不到注入点（if (!accepted) 那一段），上游结构变了，跳过' -ForegroundColor Yellow
        return $false
    }
    Copy-Item -LiteralPath $file -Destination $bak -Force
    [System.IO.File]::WriteAllText($file, $txt.Replace($anchor, $anchor + "`n" + $inject))
    $chk = [System.IO.File]::ReadAllText($file)
    if ($chk.Contains('accepted.answered') -and $chk.Contains([string]$script:BridgeDaemonPatchMarker)) {
        Write-Host '  [OK] 微信补丁：答题短路（守护进程，已注入，原文件备份为 .dshbak）' -ForegroundColor Green
        return $true
    }
    Write-Host '  [!] 微信补丁：守护进程写入后自检没过，已留 .dshbak 备份' -ForegroundColor Red
    return $false
}

# ---------------------------------------------------------------------------
#  微信桥接补丁（守护进程侧）：多通道推送扇出
#  背景：微信 ClawBot 机器人会话不触发手机系统通知（安卓上机器人与公众号消息被
#  "通知分类"静默，与免打扰无关），主动通知必须另走一条能弹横幅的通道。
#  本补丁给守护进程加 fanoutPush()：每条主动通知（wechat_notify / 看门狗 / 提问 /
#  审批）发微信的同时，镜像到 ~\.dsh\wechat-bridge\push-channels.json 里配置的通道
#  （钉钉群机器人 / ntfy / 飞书 / PushPlus）。补丁脚本本身幂等；改配置即时生效，
#  改代码才需要重启。用户 2026-09-14 验收：钉钉"通了"。
# ---------------------------------------------------------------------------
function Invoke-BridgePushFanoutPatch {
    param([string]$DshHome, [string]$ProfileName)
    $patchScript = 'C:\Users\Huawei\Documents\DSH\tools\wechat-bridge-patch\patch-push-fanout.mjs'
    if (-not (Test-Path -LiteralPath $patchScript)) {
        Write-Host '  [i] 推送扇出补丁：找不到补丁脚本，跳过' -ForegroundColor DarkGray
        return $false
    }
    $out = & node $patchScript 2>&1
    $rc = $LASTEXITCODE
    $line = (($out | ForEach-Object { [string]$_ }) -join ' ').Trim()
    if ($rc -eq 0 -and $line -match 'PATCHED|SKIP') {
        Write-Host ('  [OK] 推送扇出补丁：' + $line) -ForegroundColor Green
        return $true
    }
    Write-Host ('  [!] 推送扇出补丁：执行异常（exit ' + $rc + '）：' + $line) -ForegroundColor Yellow
    return $false
}
# ---------------------------------------------------------------------------
#  微信桥接补丁（插件侧）：stale-done-guard —— 别让上一轮的 turn/end 关掉本轮的回传流
#  现象：桥接守护进程的 SSE 流被提前关闭，只发「DSH 无返回内容。」，我的正文回不到微信。
#  根因：插件每次 session turn/end 都 broadcast(done) → closeStreams()，包括上一轮残留的
#  turn/end。修法：给每条 SSE 连接记「是否已收到正文」，只有本轮转发过正文才收尾关流。
#  补丁脚本幂等；改的是插件 lib\index.js，需要重启 DSH 才生效。
# ---------------------------------------------------------------------------
function Invoke-BridgeStaleDonePatch {
    param([string]$DshHome, [string]$ProfileName)
    $patchScript = 'C:\Users\Huawei\Documents\DSH\tools\wechat-bridge-patch\patch-stale-done-guard.mjs'
    if (-not (Test-Path -LiteralPath $patchScript)) {
        Write-Host '  [i] stale-done 补丁：找不到补丁脚本，跳过' -ForegroundColor DarkGray
        return $false
    }
    $out = & node $patchScript 2>&1
    $rc = $LASTEXITCODE
    $line = (($out | ForEach-Object { [string]$_ }) -join ' ').Trim()
    if ($rc -eq 0 -and $line -match 'PATCHED|SKIP') {
        Write-Host ('  [OK] stale-done 补丁：' + $line) -ForegroundColor Green
        return $true
    }
    Write-Host ('  [!] stale-done 补丁：执行异常（exit ' + $rc + '）：' + $line) -ForegroundColor Yellow
    return $false
}
# ---------------------------------------------------------------------------
#  微信桥接补丁（插件侧）：sse-heartbeat —— 给回传流发心跳，别让 5 分钟空闲掐死它
#  现象：长回合最后只收到「处理消息时出错，请稍后重试。」，日志报
#        Error in sendToDsh {"error":"terminated"}（实测都卡在 5 分 05 秒）。
#  根因：/api/stream 建连后除了一行 retry 就不再发字节，守护进程用 Node 全局 fetch
#        （undici）读流，bodyTimeout 默认 300 秒 → 空闲 5 分钟响应体被掐掉。
#  修法：每条 SSE 连接挂 20 秒的注释心跳（`: ping`），客户端忽略、但足以续命。
#  补丁脚本幂等；改的是插件 lib\index.js，需要重启 DSH 才生效。
# ---------------------------------------------------------------------------
function Invoke-BridgeSseHeartbeatPatch {
    param([string]$DshHome, [string]$ProfileName)
    $patchScript = 'C:\Users\Huawei\Documents\DSH\tools\wechat-bridge-patch\patch-sse-heartbeat.mjs'
    if (-not (Test-Path -LiteralPath $patchScript)) {
        Write-Host '  [i] SSE 心跳补丁：找不到补丁脚本，跳过' -ForegroundColor DarkGray
        return $false
    }
    $out = & node $patchScript 2>&1
    $rc = $LASTEXITCODE
    $line = (($out | ForEach-Object { [string]$_ }) -join ' ').Trim()
    if ($rc -eq 0 -and $line -match 'PATCHED|SKIP') {
        Write-Host ('  [OK] SSE 心跳补丁：' + $line) -ForegroundColor Green
        return $true
    }
    Write-Host ('  [!] SSE 心跳补丁：执行异常（exit ' + $rc + '）：' + $line) -ForegroundColor Yellow
    return $false
}
# ---------------------------------------------------------------------------
#  微信桥接补丁（守护进程侧）：notify-hardening —— 通知不再延迟成串、不再静默丢失
#  现象：同一时刻收到多条旧通知（实测 2026-09-15 10:19 三条，内容是我 20~35 分钟前的回复）。
#  链条：长任务的"安抚消息"直连微信 API → 微信限流(ret:-2) → 全局熔断 30 秒 →
#        队列里的正式通知发送失败且旧代码"不重试直接丢" → 熔断恢复后一起冲出去。
#  修法：① notify.js 失败改为退避重试(≤5 次,15s→300s) ② main.js 安抚消息改走通知队列。
#  补丁脚本幂等；改的是守护进程代码，重启守护进程即生效（不用重启 DSH）。
# ---------------------------------------------------------------------------
function Invoke-BridgeNotifyHardeningPatch {
    param([string]$DshHome, [string]$ProfileName)
    $patchScript = 'C:\Users\Huawei\Documents\DSH\tools\wechat-bridge-patch\patch-notify-hardening.mjs'
    if (-not (Test-Path -LiteralPath $patchScript)) {
        Write-Host '  [i] 通知加固补丁：找不到补丁脚本，跳过' -ForegroundColor DarkGray
        return $false
    }
    $out = & node $patchScript 2>&1
    $rc = $LASTEXITCODE
    $line = (($out | ForEach-Object { [string]$_ }) -join ' ').Trim()
    if ($rc -eq 0 -and $line -match 'DONE') {
        Write-Host ('  [OK] 通知加固补丁：' + $line) -ForegroundColor Green
        return $true
    }
    Write-Host ('  [!] 通知加固补丁：执行异常（exit ' + $rc + '）：' + $line) -ForegroundColor Yellow
    return $false
}
# ---------------------------------------------------------------------------
#  微信桥接补丁（守护进程侧）：fanout-policy —— 正文镜像只发微信，不震第二遍钉钉
#  用户 2026-09-15 定的策略（方案 3）：真正的提醒（跑完/提问/审批）照旧微信+钉钉双发；
#  "我回复完了：<整轮正文>"这类正文镜像只发微信。开关：push-channels.json 的 mirrorReplies。
#  必须排在 push-fanout 之后执行（改的是它注入的那段代码）。改完重启守护进程即生效。
# ---------------------------------------------------------------------------
function Invoke-BridgeFanoutPolicyPatch {
    param([string]$DshHome, [string]$ProfileName)
    $patchScript = 'C:\Users\Huawei\Documents\DSH\tools\wechat-bridge-patch\patch-fanout-policy.mjs'
    if (-not (Test-Path -LiteralPath $patchScript)) {
        Write-Host '  [i] 扇出策略补丁：找不到补丁脚本，跳过' -ForegroundColor DarkGray
        return $false
    }
    $out = & node $patchScript 2>&1
    $rc = $LASTEXITCODE
    $line = (($out | ForEach-Object { [string]$_ }) -join ' ').Trim()
    if ($rc -eq 0 -and $line -match 'PATCHED|SKIP') {
        Write-Host ('  [OK] 扇出策略补丁：' + $line) -ForegroundColor Green
        return $true
    }
    Write-Host ('  [!] 扇出策略补丁：执行异常（exit ' + $rc + '）：' + $line) -ForegroundColor Yellow
    return $false
}
function Invoke-BridgePatches {
    param([string]$DshHome, [string]$ProfileName)
    $a = Invoke-BridgePluginPatch -DshHome $DshHome -ProfileName $ProfileName
    $b = Invoke-BridgeDaemonPatch -DshHome $DshHome -ProfileName $ProfileName
    $c = Invoke-BridgePushFanoutPatch -DshHome $DshHome -ProfileName $ProfileName
    $d = Invoke-BridgeStaleDonePatch -DshHome $DshHome -ProfileName $ProfileName
    $e = Invoke-BridgeSseHeartbeatPatch -DshHome $DshHome -ProfileName $ProfileName
    $f = Invoke-BridgeNotifyHardeningPatch -DshHome $DshHome -ProfileName $ProfileName
    $g = Invoke-BridgeFanoutPolicyPatch -DshHome $DshHome -ProfileName $ProfileName
    return [bool]($a -or $b -or $c -or $d -or $e -or $f -or $g)
}

function Invoke-Upgrades {
    param($Chosen, $Plugins)

    $cfg = $script:Cfg
    $ok = $true
    $script:UpgradeLog = @()

    # 升级前必须先停掉正在运行的 DSH，否则 Windows 上文件占用会导致替换失败
    if ($script:RunningPid -gt 0) {
        Write-Host ''
        Write-Host ('[停止] 先关闭正在运行的 DSH（PID ' + $script:RunningPid + '）...') -ForegroundColor Yellow
        if (-not $DryRun) {
            Stop-ProcessTree -RootId $script:RunningPid
            $wait = 0
            while ((Test-PortOpen -Port $cfg.Port) -and $wait -lt 20) { Start-Sleep -Milliseconds 500; $wait++ }
        }
        $script:RunningPid = 0
    }

    $total = @($Chosen).Count
    $idx = 0
    foreach ($it in $Chosen) {
        $idx++
        # 可跳过的时刻：上一步已经结束，按键就放弃剩余项
        if (Test-SkipRequested) {
            Write-Host ''
            Write-Host ('  [i] 收到按键：跳过剩余 ' + ($total - $idx + 1) + ' 项升级，直接启动 DSH') -ForegroundColor Yellow
            $script:SkippedUpgrade = $true
            break
        }
        Write-Host ''
        Write-Host ('  [' + $idx + '/' + $total + '] ' + $it.Label) -ForegroundColor White
        Write-Host '        ⏳ 正在执行，此步不可中断，请等待 ...' -ForegroundColor DarkGray
        switch -Regex ($it.Id) {
            '^bootstrap$' {
                $ver = $it.Target
                if (-not $ver) { $ver = Get-RemoteVersion -Package $cfg.DshPackage -Tag 'latest' }
                if (-not $ver) { $ver = 'latest' }
                if (-not $DryRun -and -not (Test-Path -LiteralPath $cfg.RuntimeDir)) {
                    New-Item -ItemType Directory -Force -Path $cfg.RuntimeDir | Out-Null
                }
                $pj = Join-Path $cfg.RuntimeDir 'package.json'
                if (-not $DryRun -and -not (Test-Path -LiteralPath $pj)) {
                    Set-Content -LiteralPath $pj -Value '{"name":"dsh-runtime","private":true}' -Encoding UTF8
                }
                $rc = Invoke-NpmCmd -WorkDir $cfg.RuntimeDir -Arguments @('install', ($cfg.DshPackage + '@' + $ver), '--no-audit', '--no-fund', '--registry', $cfg.Registry) -Title ('安装 ' + $cfg.DshPackage + '@' + $ver)
                if ($rc -ne 0) { $ok = $false; $script:UpgradeLog += ('安装失败 (exit ' + $rc + ')') } else { $script:UpgradeLog += ('已安装 ' + $ver) }
            }
            '^dsh$' {
                $ver = $it.Target
                if (-not $ver) { $ver = Get-RemoteVersion -Package $cfg.DshPackage -Tag 'latest' }
                $rc = Invoke-NpmCmd -WorkDir $cfg.RuntimeDir -Arguments @('install', ($cfg.DshPackage + '@' + $ver), '--no-audit', '--no-fund', '--registry', $cfg.Registry) -Title ('DSH 主体 -> ' + $ver)
                if ($rc -ne 0) { $ok = $false; $script:UpgradeLog += ('DSH 主体升级失败 (exit ' + $rc + ')') } else { $script:UpgradeLog += ('DSH 主体已升到 ' + $ver) }
            }
            '^core$' {
                $rc = Invoke-NpmCmd -WorkDir $cfg.RuntimeDir -Arguments @('update', '--no-audit', '--no-fund', '--registry', $cfg.Registry) -Title '内核核心包'
                if ($rc -ne 0) { $ok = $false; $script:UpgradeLog += ('内核升级失败 (exit ' + $rc + ')') } else { $script:UpgradeLog += '内核核心包已更新' }
            }
            '^node$' {
                $ver = $it.Target
                if (-not $ver) { $ver = $script:Status.NodeTarget }
                if ($ver) {
                    Write-Host ''
                    Write-Host ('[升级] Node -> v' + $ver) -ForegroundColor Yellow
                    if (-not $DryRun) {
                        & nvm install $ver 2>&1 | ForEach-Object { Write-Host ('       ' + $_) }
                        & nvm use $ver 2>&1 | ForEach-Object { Write-Host ('       ' + $_) }
                    }
                    $script:UpgradeLog += ('Node 已切到 v' + $ver)
                }
            }
            '^plugin:' {
                $name = $it.Id.Substring(7)
                $p = $null
                foreach ($x in $Plugins) { if ($x.Name -eq $name) { $p = $x } }
                $profileDir = Join-Path $cfg.DshHome ('profiles\' + $cfg.Profile)
                if ($p -and $p.Kind -eq 'git') {
                    $rc = Invoke-PnpmCmd -WorkDir $profileDir -Arguments @('up', $name) -Title ('插件 ' + $name + '（GitHub 分支最新提交）')
                } else {
                    $rc = Invoke-PnpmCmd -WorkDir $profileDir -Arguments @('up', $name, '--latest') -Title ('插件 ' + $name)
                }
                if ($rc -ne 0) { $ok = $false; $script:UpgradeLog += ($name + ' 升级失败 (exit ' + $rc + ')') } else { $script:UpgradeLog += ($name + ' 已升级') }
            }
        }
    }
    return $ok
}

# ============================================================================
#  启动 / 停止
# ============================================================================
function Start-DshServer {
    param([int]$Port)
    $cfg = $script:Cfg
    $bin = Join-Path $cfg.RuntimeDir 'node_modules\@deepseek-ai\dsh\lib\bin.js'

    if (Test-Path -LiteralPath $bin) {
        $exe = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
        if (-not $exe) { throw '找不到 node.exe，无法启动 DSH' }
        $argList = @($bin, 'web', '--port', "$Port", '--no-open')
    } else {
        $exe = (Get-Command npx.cmd -ErrorAction SilentlyContinue).Source
        if (-not $exe) { throw '找不到 npx.cmd，无法启动 DSH' }
        $argList = @('-y', ($cfg.DshPackage + '@latest'), 'web', '--port', "$Port", '--no-open')
        Write-Host '[提示] 运行环境未安装，改用 npx 临时启动（建议下次选择安装/升级）' -ForegroundColor Yellow
    }

    if ($DryRun) {
        Write-Host ''
        Write-Host ('[DRY-RUN] ' + $exe + ' ' + ($argList -join ' ')) -ForegroundColor Magenta
        return $null
    }

    if (-not (Test-Path -LiteralPath $cfg.LogDir)) { New-Item -ItemType Directory -Force -Path $cfg.LogDir | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $outLog = Join-Path $cfg.LogDir ('dsh-' + $stamp + '.out.log')
    $errLog = Join-Path $cfg.LogDir ('dsh-' + $stamp + '.err.log')

    Write-Host ''
    Write-Host '[启动] 正在启动 DSH ...' -ForegroundColor Cyan
    Write-Host ('       日志 ' + $outLog)
    $proc = Start-Process -FilePath $exe -ArgumentList $argList -WindowStyle Hidden `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru

    # v5 修"第一次打开页面显示连接不到服务器"：
    #   ① 首次运行（运行环境还没装、走 npx 现场下载）动辄几分钟，原来固定等 90 秒必然放弃；
    #   ② "端口开了"不等于"HTTP 能应答"，端口刚开就拉浏览器就会看到连不上。
    $firstRun    = -not (Test-Path -LiteralPath $bin)
    $waitSeconds = 900
    if (-not $firstRun) { $waitSeconds = 150 }
    $start    = Get-Date
    $deadline = $start.AddSeconds($waitSeconds)
    $ready    = $false
    $lastNote = 0
    while ((Get-Date) -lt $deadline) {
        if (Test-PortOpen -Port $Port) { $ready = $true; break }
        if ($proc -and $proc.HasExited) { break }
        $elapsed = [int]((Get-Date) - $start).TotalSeconds
        if ($elapsed - $lastNote -ge 15) {
            $lastNote = $elapsed
            if ($firstRun) { Write-Host ('       …已等待 ' + $elapsed + ' 秒（首次运行正在下载运行环境，属正常，请勿关窗）') -ForegroundColor DarkGray }
            else { Write-Host ('       …已等待 ' + $elapsed + ' 秒') -ForegroundColor DarkGray }
        }
        Start-Sleep -Milliseconds 700
    }

    if ($ready) {
        # 端口通了再等 HTTP 真能出页面（最多 60 秒），避免浏览器一开就是"连接不到服务器"
        $httpOk = $false
        $hdeadline = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $hdeadline) {
            try {
                $resp = Invoke-WebRequest -Uri ('http://127.0.0.1:' + $Port + '/') -UseBasicParsing -TimeoutSec 5
                if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 500) { $httpOk = $true; break }
            } catch { }
            Start-Sleep -Milliseconds 800
        }
        Write-Host ('[OK] DSH 已就绪： http://127.0.0.1:' + $Port) -ForegroundColor Green
        if (-not $httpOk) { Write-Host '       [提示] 端口已通但页面还没应答；浏览器若显示"连接不到服务器"，等几秒刷新即可' -ForegroundColor Yellow }
        try { Start-Process ("http://127.0.0.1:" + $Port) } catch { }
        return $proc
    }

    # 超时也不让用户干等：挂一个后台守候，DSH 真起来时自动开浏览器（最多再等 15 分钟）
    $waiter = "for (`$i=0; `$i -lt 450; `$i++) { try { `$r = Invoke-WebRequest -Uri 'http://127.0.0.1:$Port/' -UseBasicParsing -TimeoutSec 5; if (`$r.StatusCode -ge 200 -and `$r.StatusCode -lt 500) { Start-Process 'http://127.0.0.1:$Port'; break } } catch { } Start-Sleep -Seconds 2 }"
    try { Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-Command', $waiter -WindowStyle Hidden | Out-Null } catch { }
    Write-Host ('[!] ' + $waitSeconds + ' 秒内没等到端口就绪，DSH 可能还在下载/启动。') -ForegroundColor Red
    Write-Host ('       [提示] 已挂后台守候：DSH 起来后会自动打开浏览器（也可手动刷新 http://127.0.0.1:' + $Port + '）') -ForegroundColor Yellow
    Write-Host '以下为最后 30 行日志：' -ForegroundColor Red
    if (Test-Path -LiteralPath $outLog) { Get-Content -LiteralPath $outLog -Tail 30 | ForEach-Object { Write-Host ('   ' + $_) } }
    if (Test-Path -LiteralPath $errLog) { Get-Content -LiteralPath $errLog -Tail 30 | ForEach-Object { Write-Host ('   ' + $_) -ForegroundColor DarkYellow } }
    return $null
}

function Stop-DshServer {
    $cfg = $script:Cfg
    $owner = Get-PortOwner -Port $cfg.Port
    if ($owner -le 0) {
        Write-Host ('[i] 端口 ' + $cfg.Port + ' 上没有正在运行的 DSH。') -ForegroundColor Yellow
        return
    }
    Write-Host ('[停止] 正在关闭 DSH（PID ' + $owner + '）...') -ForegroundColor Yellow
    if ($DryRun) { Write-Host ('[DRY-RUN] Stop-ProcessTree ' + $owner) -ForegroundColor Magenta; return }
    Stop-ProcessTree -RootId $owner
    Start-Sleep -Seconds 1
    if (Test-PortOpen -Port $cfg.Port) {
        Write-Host '[!] 端口仍被占用，可能有残留进程。' -ForegroundColor Red
    } else {
        Write-Host '[OK] 已停止。' -ForegroundColor Green
    }
}

# ============================================================================
#  主流程
# ============================================================================
function Show-Banner {
    Write-Host ''
    Write-Host '  ══════════════════════════════════════════════════════════════════' -ForegroundColor DarkCyan
    Write-Host '    D S H   启动器  ·  DeepSeek Harness' -ForegroundColor Cyan
    Write-Host ('    启动器 ' + $script:LauncherVersion + '  ·  置顶补丁 ' + $script:PatchMarker) -ForegroundColor DarkGray
    Write-Host '  ══════════════════════════════════════════════════════════════════' -ForegroundColor DarkCyan
}

function Invoke-Main {
    $cfg = $script:Cfg

    Show-Banner

    if ($PatchOnly) {
        [void](Invoke-DshPatches -RuntimeDir $script:Cfg.RuntimeDir)
        [void](Invoke-BridgePatches -DshHome $script:Cfg.DshHome -ProfileName $script:Cfg.Profile)
        return
    }

    if ($Stop) { Stop-DshServer; return }
    if ($Restart) { Stop-DshServer; Start-Sleep -Seconds 1 }

    # ---- 1. DSH 已经在运行 -> 直接提示，按任意键退出（不做任何检查，秒退）----
    $script:RunningPid = Get-PortOwner -Port $cfg.Port
    $explicit = ($Stop -or $Restart -or $CheckOnly -or $DryRun -or $SkipCheck)
    if ($script:RunningPid -gt 0 -and -not $explicit) {
        Write-Host ''
        Write-Host ('  DSH 在运行中  ·  端口 ' + $cfg.Port + '  ·  PID ' + $script:RunningPid) -ForegroundColor Green
        Write-Host ('  界面地址： http://127.0.0.1:' + $cfg.Port) -ForegroundColor Gray
        Write-Host ''
        if (-not $Silent) {
            Write-Host '  按任意键退出 ...' -ForegroundColor DarkGray
            try { [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') }
            catch { try { [void](Read-Host) } catch { } }
        }
        return
    }

    # ---- 1.5 代理体检：死代理 / 全局模式 自动纠正（静默，绝不影响启动）----
    Repair-ProxyHealth -ReportOnly:$DryRun

    # ---- 2. 自动检查更新（任意键 = 跳过检查，直接启动）----
    if ($SkipCheck) {
        Write-Host ''
        Write-Host '  [i] 已跳过更新检查（-SkipCheck），直接启动。' -ForegroundColor Yellow
    } else {
        [void](Invoke-StatusCheck)

        if ($CheckOnly) { return }

        $all = @($script:Items)
        $items = @($all | Where-Object { $_.Checked })     # 只自动升级默认勾选的项

        if ($script:CheckAborted) {
            Write-Host ''
            Write-Host '  [i] 收到按键：跳过更新检查，直接启动 DSH' -ForegroundColor Yellow
        } elseif ($items.Count -eq 0) {
            Write-Host ''
            if ($all.Count -gt 0) {
                Write-Host '  [i] 只有预发布 / 需手动确认的升级项，本次全部跳过，直接启动。' -ForegroundColor Yellow
            } else {
                Write-Host '  [OK] 所有组件都是最新，无需升级，直接启动。' -ForegroundColor Green
            }
        } else {
            Write-Host ''
            Write-Host ('  ── 发现 ' + $items.Count + ' 项可升级，开始自动升级 ' + '─' * 30) -ForegroundColor Cyan
            Write-Host '     升级过程中按任意键可跳过剩余项，直接启动 DSH；' -ForegroundColor DarkGray
            Write-Host '     正在执行的那一步不能中断，会提示你等待。' -ForegroundColor DarkGray

            $ok = Invoke-Upgrades -Chosen $items -Plugins $script:Status.Plugins

            Write-Host ''
            if ($script:SkippedUpgrade) {
                Write-Host '  [i] 已跳过剩余升级项，继续启动。' -ForegroundColor Yellow
            } elseif ($ok) {
                Write-Host '  [OK] 升级完成。' -ForegroundColor Green
            } else {
                Write-Host '  [!] 部分升级失败，见上面日志（仍会继续启动）。' -ForegroundColor Red
            }
            foreach ($l in $script:UpgradeLog) { Write-Host ('      - ' + $l) }
            Write-Host ''
            Write-Host '  ── 升级后版本 ──' -ForegroundColor Cyan
            $nv = Get-PkgVersion (Join-Path $cfg.RuntimeDir 'node_modules\@deepseek-ai\dsh')
            $nc = Get-CoreVersion -Runtime $cfg.RuntimeDir
            Write-Host ('     DSH 主体 ' + $(if ($nv) { $nv } else { '?' }))
            if ($nc) { Write-Host ('     内核     ' + $nc.Version + '（' + $nc.Count + ' 个包）') }
        }
    }

    # ---- 3. 维护补丁（dsh / 插件升级会覆盖 node_modules，每次启动都补一遍）----
    if (-not $DryRun -and -not $CheckOnly) {
        [void](Invoke-DshPatches -RuntimeDir $cfg.RuntimeDir)
        [void](Invoke-BridgePatches -DshHome $cfg.DshHome -ProfileName $cfg.Profile)
    }

    # ---- 4. 启动 ----
    if ($script:RunningPid -gt 0 -and (Test-PortOpen -Port $cfg.Port)) {
        Write-Host ''
        Write-Host ('  [i] DSH 已经在运行，直接打开界面： http://127.0.0.1:' + $cfg.Port) -ForegroundColor Green
        if (-not $DryRun) { try { Start-Process ("http://127.0.0.1:" + $cfg.Port) } catch { } }
        return
    }

    [void](Start-DshServer -Port $cfg.Port)
}

# ============================================================================
try {
    Invoke-Main
} catch {
    Write-Host ''
    Write-Host ('[错误] ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    # 兜底：检查/升级环节出任何意外，也要尽力把 DSH 拉起来（用户点启动器就是为了用它）
    if (-not $CheckOnly -and -not $Stop -and -not $DryRun) {
        Write-Host ''
        Write-Host '  [i] 上面这步出错了，但仍然继续尝试启动 DSH ...' -ForegroundColor Yellow
        try { [void](Start-DshServer -Port $script:Cfg.Port) }
        catch { Write-Host ('  [!] 启动也失败了：' + $_.Exception.Message) -ForegroundColor Red }
    }
}

if (-not $Silent -and -not $CheckOnly) {
    Write-Host ''
    Write-Host '按回车键关闭窗口 ...' -ForegroundColor DarkGray
    try { [void](Read-Host) } catch { }
}
