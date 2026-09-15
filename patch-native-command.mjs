// patch-native-command.mjs —— 给 DSH 的 @deepseek-ai/dsh-native-command 打「资源管理器置顶」补丁。
//
// 为什么单独做成 node 脚本（2026-09-15）：v4/v5 靠"上游函数体里的固定结构"定位，v6/v7 靠
// "顺着相对转发链找"，在用户的另一台电脑上都失败了（那个版本的包布局不一样：可能拆成了
// lib/path-opener.js、可能是 minify 的 bundle、可能转发到另一个包）。PowerShell 里写"整包搜索 +
// 多种模块解析"太笨重，用 node 写清楚、也能在本机直接测。
//
// 做法：不碰上游函数体，只在"真正声明/导出 revealNativePath 的那个文件"末尾追加一段包装，
// 重新赋值导出（ESM 活绑定 / CJS module.exports 两种都试，都失败就静默不动，绝不弄坏功能）。
// 找不到时把"扫过哪些文件、各自有没有该标识符"写进 patch-diag.txt，便于远程定位。
//
// 用法：
//   node patch-native-command.mjs --runtime <运行时目录> --shim <shim.cmd> --focus <dsh-focus.ps1> \
//        --marker "<补丁标记>" [--diag <诊断文件>] [--quiet]
// 输出：以 RESULT: OK|SKIP|NOTFOUND 开头的一行，其余为说明。
import fs from 'node:fs';
import path from 'node:path';

const argv = process.argv.slice(2);
const arg = (n, d) => { const i = argv.indexOf(n); return i >= 0 && argv[i + 1] ? argv[i + 1] : d; };
const runtime = arg('--runtime');
const shim = arg('--shim', '');
const focus = arg('--focus', '');
const marker = arg('--marker', 'dsh-launcher-patch: reveal-foreground v8');
const diagPath = arg('--diag', path.join(process.cwd(), 'patch-diag.txt'));
const IDENT = 'revealNativePath';
const MAX_DEPTH = 3;
const MAX_FILE_BYTES = 3 * 1024 * 1024;
const MAX_SCAN_FILES = 400;

const out = [];
const say = (s) => { out.push(s); };

if (!runtime) { console.log('RESULT: NOTFOUND 缺少 --runtime'); process.exit(0); }
const pkgDir = path.join(runtime, 'node_modules', '@deepseek-ai', 'dsh-native-command');
const entry = path.join(pkgDir, 'lib', 'index.js');
if (!fs.existsSync(entry)) { console.log('RESULT: NOTFOUND 没找到 ' + entry); process.exit(0); }

const readText = (f) => { try { const st = fs.statSync(f); if (st.size > MAX_FILE_BYTES) return null; return fs.readFileSync(f, 'utf8'); } catch { return null; } };

function resolveRelative(fromFile, spec) {
  const base = path.resolve(path.dirname(fromFile), spec);
  const cands = [base, base + '.js', base + '.mjs', base + '.cjs', path.join(base, 'index.js'), path.join(base, 'index.mjs'), path.join(base, 'index.cjs')];
  for (const c of cands) { try { if (fs.statSync(c).isFile()) return c; } catch { } }
  return null;
}
function resolveBare(fromFile, spec) {
  let dir = path.dirname(fromFile);
  for (let i = 0; i < 8; i++) {
    const nm = path.join(dir, 'node_modules');
    const p = path.join(nm, spec);
    try {
      if (fs.statSync(p).isDirectory()) {
        const pj = path.join(p, 'package.json');
        if (fs.existsSync(pj)) {
          const j = JSON.parse(fs.readFileSync(pj, 'utf8'));
          const main = (j.exports && typeof j.exports === 'string' && j.exports) || j.module || j.main;
          if (main) { const r = resolveRelative(pj, './' + main.replace(/^\.\//, '')); if (r) return r; }
        }
        for (const c of [path.join(p, 'index.js'), path.join(p, 'lib', 'index.js'), path.join(p, 'dist', 'index.js')]) {
          try { if (fs.statSync(c).isFile()) return c; } catch { }
        }
      } else {
        for (const c of [p + '.js', p + '.mjs', p + '.cjs']) { try { if (fs.statSync(c).isFile()) return c; } catch { } }
      }
    } catch { }
    const up = path.dirname(dir);
    if (up === dir) break;
    dir = up;
  }
  return null;
}

const specRe = /(?:from|require\()\s*["']([^"']+)["']/g;
function followChain(startFile) {
  const seen = new Set();
  const queue = [[startFile, 0]];
  const files = [];
  while (queue.length > 0 && files.length < 60) {
    const [file, depth] = queue.shift();
    if (seen.has(file)) continue;
    seen.add(file);
    const txt = readText(file);
    if (txt === null) continue;
    files.push({ file, txt, depth });
    if (depth >= MAX_DEPTH) continue;
    specRe.lastIndex = 0;
    let m;
    while ((m = specRe.exec(txt)) !== null) {
      const spec = m[1];
      const next = spec.startsWith('.') ? resolveRelative(file, spec) : resolveBare(file, spec);
      if (next && !seen.has(next)) queue.push([next, depth + 1]);
    }
  }
  return files;
}

function scanDir(dir, label) {
  const found = [];
  const walk = (d, depth) => {
    let entries = [];
    try { entries = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      if (found.length >= MAX_SCAN_FILES) return;
      const p = path.join(d, e.name);
      if (e.isDirectory()) { if (e.name !== 'node_modules' && depth < 4) walk(p, depth + 1); continue; }
      if (!/\.(js|mjs|cjs)$/i.test(e.name)) continue;
      const txt = readText(p);
      if (txt === null) continue;
      found.push({ file: p, txt, hasIdent: txt.includes(IDENT), label });
    }
  };
  walk(dir, 0);
  return found;
}

// ① 顺着转发链；② 整包搜索；③ 兄弟 @deepseek-ai/* 包搜索（都可能承载实现）
let candidates = followChain(entry);
let chosen = candidates.find((c) => c.txt.includes(IDENT));
let scope = 'follow-chain';
if (!chosen) {
  scope = 'package-scan';
  candidates = scanDir(pkgDir, 'pkg');
  chosen = candidates.find((c) => c.hasIdent) || null;
}
if (!chosen) {
  scope = 'sibling-scan';
  const scopeDir = path.join(runtime, 'node_modules', '@deepseek-ai');
  const sib = scanDir(scopeDir, 'sibling');
  candidates = candidates.concat(sib);
  chosen = sib.find((c) => c.hasIdent) || null;
}

function writeDiag(note) {
  try {
    const lines = [];
    lines.push('DSH 启动器 · dsh-native-command 补丁诊断  ' + new Date().toLocaleString('sv'));
    lines.push('运行时目录: ' + runtime);
    lines.push('入口文件: ' + entry + (fs.existsSync(entry) ? '（' + fs.statSync(entry).size + ' 字节）' : '（不存在）'));
    lines.push('扫描范围: ' + scope + '，检查了 ' + candidates.length + ' 个文件');
    lines.push('结论: ' + note);
    const pj = path.join(pkgDir, 'package.json');
    if (fs.existsSync(pj)) lines.push('包信息: ' + fs.readFileSync(pj, 'utf8').replace(/\s+/g, ' ').slice(0, 400));
    lines.push('');
    lines.push('扫过的文件（★ = 含 ' + IDENT + '）:');
    for (const c of candidates.slice(0, 120)) {
      lines.push('  ' + (c.txt.includes(IDENT) ? '★' : ' ') + ' ' + path.relative(runtime, c.file) + '  ' + c.txt.length + ' 字符' + (c.label ? ' [' + c.label + ']' : ''));
    }
    const ex = candidates.find((c) => c.label !== 'sibling') || candidates[0];
    if (ex) {
      lines.push('');
      lines.push('入口文件首 25 行:');
      ex.txt.split(/\r?\n/).slice(0, 25).forEach((l, i) => lines.push('  ' + (i + 1) + '| ' + l));
      const exp = ex.txt.split(/\r?\n/).filter((l) => /export|module\.exports/.test(l)).slice(0, 20);
      lines.push('');
      lines.push('导出相关行（最多 20 行）:');
      exp.forEach((l) => lines.push('  | ' + l.trim()));
    }
    fs.writeFileSync(diagPath, lines.join('\r\n'), 'utf8');
    say('      · 诊断已写入：' + diagPath + '（把它发给 DSH 就能定位）');
  } catch (e) {
    say('      · 诊断写入失败：' + e.message);
  }
}

function esc(s) { return String(s).replace(/\\/g, '\\\\'); }

const wrapper = `
/* ${marker} —— 由 DSH 启动器注入（文件末尾包装），dsh 升级后启动器会自动重打 */
const __dshRevealOriginal = (typeof ${IDENT} === "function") ? ${IDENT}
	: (typeof module !== "undefined" && module.exports && typeof module.exports.${IDENT} === "function" ? module.exports.${IDENT} : undefined);
async function dshRevealWrapped(path, signal, internals = {}) {
	try {
		if ((internals.platform ?? process.platform) === "win32" && typeof __dshRevealOriginal === "function") {
			const run = internals.run ?? (typeof runNativeCommand === "function" ? runNativeCommand : null);
			if (run) {
				const target = String(path);
				try { await run("cmd.exe", ["/c", "${esc(shim)}", target], signal); }
				catch (launchError) { if (!(launchError && launchError.code === 1)) throw launchError; }
				try {
					const shell = (process.env.SystemRoot || "C:\\\\Windows") + "\\\\System32\\\\WindowsPowerShell\\\\v1.0\\\\powershell.exe";
					await run(shell, ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", "${esc(focus)}", "-Path", target], signal);
				} catch { }
				return;
			}
		}
	} catch { /* 任何异常都退回原实现，绝不把功能弄坏 */ }
	if (typeof __dshRevealOriginal === "function") return __dshRevealOriginal(path, signal, internals);
}
try { if (typeof ${IDENT} === "function") ${IDENT} = dshRevealWrapped; } catch { }
try { if (typeof module !== "undefined" && module.exports && typeof module.exports.${IDENT} === "function") module.exports.${IDENT} = dshRevealWrapped; } catch { }
`;

function patchFile(file, txt) {
  if (txt.includes(marker)) { say('  [OK] 补丁：资源管理器窗口置顶 v8（已就位）'); return 'OK'; }
  if (txt.includes('dshRevealWrapped') || txt.includes('function dshRevealInExplorer(')) {
    const bak = file + '.dshbak';
    if (fs.existsSync(bak)) {
      fs.copyFileSync(bak, file);
      txt = fs.readFileSync(file, 'utf8');
      say('  [i] 补丁：发现旧版补丁，已用备份还原，准备注入 v8');
    } else {
      say('  [!] 补丁：有旧版补丁但没有备份，跳过（避免叠加）');
      return 'SKIP';
    }
  }
  // 必须先能"包装"：文件里得有 revealNativePath 的声明（函数/变量）才能重新赋值。
  // 只有 `export { a as revealNativePath }` 这种 minify/bundle 形式时不要注入 ——
  // 那种情况注入等于没生效（甚至可能撞重复导出），如实报告比假成功好。
  const declaresFn = new RegExp('(?:async\\s+)?function\\s+' + IDENT + '\\b').test(txt);
  const declaresVar = new RegExp('(?:const|let|var)\\s+' + IDENT + '\\b').test(txt);
  if (!declaresFn && !declaresVar) {
    say('  [!] 补丁：' + file.split(/[\\/]/).pop() + ' 里只有 "' + IDENT + '" 的名字、没有可包装的声明（多半是打包/压缩过的 bundle），跳过（功能退回原样）');
    return 'SKIP';
  }
  const eol = txt.includes('\r\n') ? '\r\n' : '\n';
  fs.copyFileSync(file, file + '.dshbak');
  fs.writeFileSync(file, txt.replace(/\s*$/, '') + eol + eol + wrapper.split('\n').join(eol), 'utf8');
  const chk = fs.readFileSync(file, 'utf8');
  if (chk.includes('dshRevealWrapped') && chk.includes(marker)) {
    say('  [OK] 补丁：资源管理器窗口置顶 v8（已注入 ' + path.basename(file) + '，原文件备份为 .dshbak）');
    return 'OK';
  }
  say('  [!] 补丁：写入后自检没过，已留 .dshbak 备份');
  return 'SKIP';
}

if (!chosen) {
  say('  [!] 补丁：这个版本的 dsh-native-command 里找不到 ' + IDENT + '，跳过（功能退回原样）');
  writeDiag('整个包 + 兄弟 @deepseek-ai 包都没找到 ' + IDENT);
  console.log('RESULT: NOTFOUND');
  console.log(out.join('\n'));
  process.exit(0);
}

const hit = chosen;
if (hit.file !== entry) say('  [i] 补丁：实现不在入口文件，已定位到 ' + path.relative(runtime, hit.file));
const res = patchFile(hit.file, hit.txt);
if (res === 'SKIP') writeDiag('定位到 ' + hit.file + '，但注入/自检失败');
console.log('RESULT: ' + res);
console.log(out.join('\n'));
process.exit(0);
