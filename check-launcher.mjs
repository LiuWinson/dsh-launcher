// check-launcher.mjs —— 启动器自检：语法之外的"静态体检"。
//
// 起因（2026-09-15）：做「资源管理器置顶 v4」那轮改造时，误删了 Resolve-Executable /
// Invoke-ToolCmd / Invoke-NpmCmd / Invoke-PnpmCmd 四个函数。PowerShell 只用到的函数才会在
// 运行时解析，所以**语法检查全绿、启动也正常**，一直到某台机器真的需要"升级"时才炸：
// 「无法将 Invoke-NpmCmd 识别为 cmdlet」。这个脚本就是为了在改完立刻发现这类问题。
//
// 用法：node check-launcher.mjs [dsh-launcher.ps1 路径]
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const FILE = process.argv[2] || path.join(path.dirname(fileURLToPath(import.meta.url)), 'dsh-launcher.ps1');
const raw = readFileSync(FILE, 'utf8').replace(/^\uFEFF/, '');
const lines = raw.split(/\r?\n/);

// 已定义的函数
const defined = new Set();
lines.forEach((l) => { const m = /^function\s+([\w-]+)\s*\{/.exec(l); if (m) defined.add(m[1]); });

// PowerShell 内置 cmdlet / 常见别名（只列本启动器会用到的族，避免误报）
const BUILTIN = new Set([
  'Test-Path', 'Test-NetConnection', 'Test-Connection', 'Test-Json', 'Test-PSRemoting',
  'Resolve-Path', 'Resolve-DnsName',
  'Invoke-RestMethod', 'Invoke-WebRequest', 'Invoke-Expression', 'Invoke-Command', 'Invoke-Item',
  'Compare-Object', 'ConvertTo-Json', 'ConvertFrom-Json', 'ConvertTo-Html', 'ConvertTo-Csv',
  'Show-Command', 'Get-ChildItem', 'Get-Item', 'Get-ItemProperty', 'Get-ItemPropertyValue', 'Get-Content',
  'Get-Command', 'Get-Date', 'Get-Process', 'Get-CimInstance', 'Get-WmiObject', 'Get-NetTCPConnection',
  'Get-NetAdapter', 'Get-NetIPConfiguration', 'Get-DnsClientServerAddress', 'Get-Service', 'Get-Job',
  'Get-Event', 'Get-Host', 'Get-Acl', 'Get-FileHash', 'Get-Volume', 'Get-PSDrive', 'Get-Member',
  'Get-Variable', 'Get-Alias', 'Get-Help', 'Get-Location', 'Get-History', 'Get-Random', 'Get-Error',
  'Set-Item', 'Set-ItemProperty', 'Set-Content', 'Set-Location', 'Set-Service', 'Set-Acl', 'Set-DnsClientServerAddress',
  'Add-Content', 'Add-Member', 'Add-Type', 'Add-JobTrigger',
  'New-Item', 'New-ItemProperty', 'New-Object', 'New-PSDrive', 'New-JobTrigger', 'New-ScheduledTaskAction',
  'Remove-Item', 'Remove-ItemProperty', 'Remove-Variable', 'Remove-Job', 'Remove-Event',
  'Start-Process', 'Start-Sleep', 'Start-Job', 'Start-Service', 'Start-Transcript',
  'Stop-Process', 'Stop-Job', 'Stop-Service',
  'Write-Host', 'Write-Output', 'Write-Error', 'Write-Warning', 'Write-Verbose', 'Write-Debug', 'Write-Progress',
  'Read-Host', 'Out-Null', 'Out-String', 'Out-File', 'Out-Host', 'Out-Default',
  'Select-Object', 'Select-String', 'Where-Object', 'ForEach-Object', 'Sort-Object', 'Group-Object',
  'Measure-Object', 'Format-List', 'Format-Table', 'Format-Wide', 'Join-Path', 'Split-Path', 'Split-Path',
  'Copy-Item', 'Move-Item', 'Rename-Item', 'Clear-Content', 'Clear-Host', 'Push-Location', 'Pop-Location',
  'Register-ObjectEvent', 'Unregister-Event', 'Wait-Event', 'Wait-Job', 'Receive-Job', 'Expand-Archive',
  'Compress-Archive', 'Restart-Service', 'Restart-Computer', 'Send-MailMessage', 'Show-EventLog',
]);

// 找出所有 Verb-Noun 调用（跳过注释行与 here-string 内容里明显不是 PowerShell 的东西）
const callRe = /\b((?:Invoke|Repair|Resolve|Test|Show|Compare|ConvertTo|ConvertFrom|Get|Set|New|Add|Remove|Start|Stop|Write|Read|Update|Install|Uninstall)-[A-Za-z][\w]*)\b/g;
const calls = new Map(); // name -> [lineNumbers]
let inHereString = false;
lines.forEach((line, i) => {
  const t = line.trim();
  if (/^@['"]\s*$/.test(t)) { inHereString = !inHereString; return; }
  if (inHereString) return;                       // here-string 里是 JS/C#，跳过
  if (t.startsWith('#')) return;                  // 注释跳过
  if (/^function\s/.test(t)) return;              // 定义行跳过
  let m;
  callRe.lastIndex = 0;
  while ((m = callRe.exec(line)) !== null) {
    const n = m[1];
    if (defined.has(n) || BUILTIN.has(n)) continue;
    if (!calls.has(n)) calls.set(n, []);
    calls.get(n).push(i + 1);
  }
});

// 定义了但从未被调用的（提示用，不算错误）
const used = new Set();
lines.forEach((line) => { let m; callRe.lastIndex = 0; while ((m = callRe.exec(line)) !== null) used.add(m[1]); });
const unused = [...defined].filter((n) => !used.has(n) && !['Invoke-Main'].includes(n));

const missing = [...calls.entries()];
console.log(`文件: ${FILE}`);
console.log(`函数定义: ${defined.size} 个 | 发现未定义就调用的: ${missing.length} 个`);
if (missing.length > 0) {
  console.log('\n✗ 这些函数被调用但本文件里没有定义（运行时才会炸）：');
  for (const [n, ls] of missing) console.log(`   ${n}   第 ${ls.join(', ')} 行`);
}
if (unused.length > 0) console.log(`\n提示：定义了但没被调用（可能只是内部用）: ${unused.join(', ')}`);
console.log(missing.length === 0 ? '\n✓ 函数引用检查通过' : '\n✗ 有未定义引用，请先补齐再提交');
process.exit(missing.length === 0 ? 0 : 1);
