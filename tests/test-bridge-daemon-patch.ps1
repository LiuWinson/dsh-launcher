# Regression test for the launcher's WeChat-daemon patch (qa-answer-short-circuit v1).
# ASCII only on purpose: PowerShell 5.1 reads BOM-less .ps1 as GBK and Chinese breaks parsing.
#
# Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-bridge-daemon-patch.ps1
#
# What it does:
#   1. parses dsh-launcher.ps1 (catches BOM loss / syntax breakage)
#   2. restores lib\bridge\main.js from its pristine .dshbak backup
#   3. re-injects the patch using the launcher's own function
#   4. compares the result byte-for-byte with the known-good patched file
#   5. runs the injector a second time to prove idempotency
#   6. node --check on the patched file

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$launcher = Join-Path $repoRoot 'dsh-launcher.ps1'
$dshHome  = Join-Path $env:USERPROFILE '.dsh'
$profile_ = 'web'
$pkg      = Join-Path $dshHome "profiles\$profile_\node_modules\@lanbaolu\dsh-wechat-bridge"
$mainJs   = Join-Path $pkg 'lib\bridge\main.js'
$bak      = $mainJs + '.dshbak'
$snapshot = Join-Path $env:TEMP 'main.js.patched.snapshot'

if (-not (Test-Path -LiteralPath $launcher)) { throw "launcher not found: $launcher" }
if (-not (Test-Path -LiteralPath $mainJs))   { throw "daemon script not found: $mainJs (is the wechat bridge installed?)" }
if (-not (Test-Path -LiteralPath $bak))      { throw "pristine backup not found: $bak" }

# ---- 1) launcher syntax check (also catches a stripped UTF-8 BOM) ----
$tokens = $null; $errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) {
    '[1] SYNTAX ERRORS:'
    $errors | ForEach-Object { '    L' + $_.Extent.StartLineNumber + ': ' + $_.Message }
    exit 1
}
'[1] launcher syntax OK'

# ---- 2) load the launcher's function definitions only (strip the trailing try { Invoke-Main }) ----
$src  = [System.IO.File]::ReadAllText($launcher)
$i    = $src.LastIndexOf('Invoke-Main')
$j    = $src.LastIndexOf('try {', $i)
if ($i -lt 0 -or $j -lt 0) { throw 'could not locate the Invoke-Main section' }
$body = $src.Substring(0, $j)
$harness = $body + "`nInvoke-BridgeDaemonPatch -DshHome '$dshHome' -ProfileName '$profile_'"
'[2] exec section stripped, body length ' + $body.Length

# ---- 3) snapshot the patched file, restore pristine, re-inject with launcher code ----
Copy-Item -LiteralPath $mainJs -Destination $snapshot -Force
Copy-Item -LiteralPath $bak -Destination $mainJs -Force
'[3] restored pristine  ' + (Get-FileHash $mainJs -Algorithm SHA256).Hash.Substring(0, 16)

& ([scriptblock]::Create($harness))

$newHash = (Get-FileHash $mainJs -Algorithm SHA256).Hash
$oldHash = (Get-FileHash $snapshot -Algorithm SHA256).Hash
if ($newHash -eq $oldHash) {
    '[4] re-injected == hand-patched (byte-identical)  OK'
} else {
    '[4] MISMATCH new=' + $newHash.Substring(0,16) + ' old=' + $oldHash.Substring(0,16)
    Copy-Item -LiteralPath $snapshot -Destination $mainJs -Force
    '[4] rolled back to snapshot'
}

# ---- 4) idempotency ----
$before = (Get-FileHash $mainJs -Algorithm SHA256).Hash
& ([scriptblock]::Create($harness))
$after = (Get-FileHash $mainJs -Algorithm SHA256).Hash
if ($before -eq $after) { '[5] idempotent: 2nd run changed nothing  OK' } else { '[5] idempotency FAILED' }

# ---- 5) node syntax check ----
& node --check $mainJs
if ($LASTEXITCODE -eq 0) { '[6] node --check OK' } else { '[6] node --check FAILED' }

# ---- 6) content assertions ----
$txt = [System.IO.File]::ReadAllText($mainJs)
'[7] short-circuit marker present: ' + $txt.Contains('qa-answer-short-circuit v1')
'[8] short-circuit condition present: ' + $txt.Contains('accepted.answered')
'[9] backup file present: ' + (Test-Path -LiteralPath $bak)

$plugin = Join-Path $pkg 'lib\index.js'
if (Test-Path -LiteralPath $plugin) {
    '[10] plugin patch marker present: ' + ([System.IO.File]::ReadAllText($plugin)).Contains('dsh-bridge-patch: question-answerer v5')
} else {
    '[10] plugin not found, skipped'
}
