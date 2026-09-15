# DSH 启动器

一个入口，全自动：双击桌面 **DSH 启动器** → 自动检查更新 → 自动升级 → 启动 DeepSeek Harness。
全程不需要点任何按钮；想省时间就按一下键盘。

## 流程

```
双击 DSH 启动器
   │
   ├─ DSH 已经在跑？ ── 是 ──> 提示"DSH 在运行中"，按任意键退出（不检查、不联网）
   │
   └─ 否
       ↓
   ① 检查更新（约 10 秒）
      按任意键 ──> 跳过检查，直接启动
       ↓
   ② 有可升级项？ —— 没有 ——> 直接启动
       │
      有
       ↓
   ③ 自动升级（逐项执行，控制台实时显示进度）
      每一项开始前 按任意键 ──> 跳过剩余升级项，直接启动
      正在执行的那一步 ⏳ ──> 不能中断，会提示"此步不可中断，请等待"
       ↓
   ④ 启动 DSH，自动打开 http://127.0.0.1:3080
```

**能跳过 / 不能跳过的边界**：按键只在"两步之间"生效。`npm install`、`pnpm up` 这类正在写文件的
动作中途不接受按键，脚本会先打印 `⏳ 正在执行，此步不可中断，请等待 ...`，等它跑完再响应按键。

## 文件

| 文件 | 作用 |
| --- | --- |
| `启动 DSH.cmd`（桌面：**DSH 启动器**） | 唯一入口，全自动流程 |
| `停止 DSH.cmd` | 停止正在运行的 DSH（连同它拉起的子进程，比如微信桥接） |
| `dsh-launcher.ps1` | 主逻辑 |
| `tests\test-bridge-daemon-patch.ps1` | 微信守护进程补丁的回归测试（补丁注入 / 幂等 / 语法） |

## 命令行用法

```powershell
# 完全不检查，直接启动
powershell -File .\dsh-launcher.ps1 -SkipCheck

# 只看检查结果，不改任何东西
powershell -File .\dsh-launcher.ps1 -CheckOnly

# 关掉现有的再走一遍完整流程
powershell -File .\dsh-launcher.ps1 -Restart

# 只打印将要执行的命令，不真的执行
powershell -File .\dsh-launcher.ps1 -DryRun

# 只重打补丁（dsh + 微信桥接两条），不检查不启动
powershell -File .\dsh-launcher.ps1 -PatchOnly

# 换端口（默认 3080）
powershell -File .\dsh-launcher.ps1 -Port 3099
```

## 给 DSH 打的补丁（reveal-foreground）

**症状**：GUI 文件卡片菜单里点「在文件资源管理器中显示」，看起来"没反应"。

**真因**（已用探针证实，不是 360 拦截）：DSH 上游实现只有一句
`explorer.exe /select,<文件>`，而发起者是后台的 node 进程 —— Windows 前台锁定不允许后台进程抢焦点，
于是新窗口被创建在**所有资源管理器窗口的最后面**。探针记录：用户点击后窗口数 11 → 12，窗口确实开了。

**补丁**：改 `@deepseek-ai/dsh-native-command/lib/index.js`，把那一行换成先调 `dshRevealInExplorer()`：

1. PowerShell 快照当前所有资源管理器窗口的 HWND；
2. 自己 `Start-Process explorer.exe -ArgumentList ('/select,' + $target)`；
3. 轮询最多 6 秒找出**新出现**的 HWND（取不到就退回"同目录窗口里取最后一个"）；
4. `ShowWindow(SW_RESTORE)` + `SetForegroundWindow`，没生效再补一发 `SwitchToThisWindow`。

失败就返回 false 走回上游原行为 —— 最差也只是回到"窗口在后面"。实测前台窗口从浏览器切到
「dsh up - 文件资源管理器」，耗时约 3.5 秒。PowerShell 命令用 `-EncodedCommand`（base64/UTF-16LE）传，
不用操心引号转义。

**维护**（重要）：

- dsh 升级会整包覆盖 `node_modules` ⇒ **启动器每次启动都会自检并重打**（`Invoke-DshPatches`）。
- 补丁带版本标记 `dsh-launcher-patch: reveal-foreground v2`（脚本里 `$script:PatchMarker`）；
  发现旧版标记时会先用 `.dshbak` 备份还原成原厂文件再注入，**绝不叠加**。改补丁内容要同步升版本号。
- 注入靠两个唯一锚点，锚点找不到（比如上游改了结构）就跳过并打印提示，不会写坏文件。
- **打完补丁要重启 DSH 才生效** —— 模块在 DSH 启动时就已经加载进内存了。

## 给微信桥接插件打的补丁（微信内回答提问）

**问题**：`ask_user_question` 走 `ctx.userQuestions` 的 waterfall，只有 GUI（浏览器）应答器；
在 GUI 会话里提问时，用户一旦离开电脑就没人答，那一轮会一直挂着。微信侧没有任何应答器。

**补丁**（只改插件，不动守护进程 —— 插件在 `/api/prompt` 就能看到入站原文）：

1. 在插件的 `apply(ctx)` 里注册 `user-questions/request` 应答器 —— **必须 `{ prepend: true }`**。
   cordis 的 waterfall 是"先注册先跑，不调 next 就否决后面"，GUI 应答器在 DSH 启动时就注册且从不调 next，
   后注册的**永远轮不到**（v1 就栽在这：两次提问一次都没推出去，日志里连失败都没有）。
2. 应答器行为（v5）：**先把问题推微信**（走守护进程 `/approval`，绕过节流），
   然后**头 60 秒只等微信**（这段时间不调用 `next()` ⇒ GUI 收不到请求 ⇒ 电脑上不会弹框）；
   答了就返回；**60 秒超时才 `next()` 交给 GUI**（电脑上此时才弹框），但**微信这条路继续有效**——
   之后在微信里回编号照样算数，谁先到用谁的。**推不出去（通道冷/守护进程没跑）立即交给 GUI**。
3. 在 `/api/prompt` 入口拦截"这是某个待答问题的输入"的消息：解析编号 → 裁决 →
   **返回后不建 turn**（否则这条回答会被当成新任务发给 agent）。

> 窗口时长不用改代码：`~\.dsh\wechat-bridge\question-handoff-ms.txt` 里写毫秒数，
> 插件每次提问都现读，**改完立刻生效、不用重启 DSH**（读不到才用代码里的默认 60000）。

## 给微信桥接守护进程打的补丁（答题短路）

第一轮实测（2026-09-14）暴露的副作用：插件把入站消息裁决成"某个提问的答案"、直接回了
`{ accepted: true, answered: true }`；但守护进程（`lib\bridge\main.js` 的 `sendToDsh`）此时
**已经 `startTyping()` 并在 await 流式 turn** —— 那个 turn 永远不会来，于是它一直挂着：
微信上「对方正在输入…」常亮不灭（实测 18:07:00 一直闪到 18:10:01，我手动重启守护进程才停），
并且静默 5 分钟后还会自动发一条"还在处理"的安抚消息。

补丁在 `client.prompt()` 的返回值判断后面加一条短路：认出 `answered` 就立刻 `return`，
走它自己的 `finally` 收尾（停 typing、会话回 idle）。实测第二轮：18:13:01 收到回答，
之后**一次 `sendtyping` 都没有**，微信里立刻安静。

守护进程只在 DSH 启动时由插件拉起，所以**启动器打完这条补丁不需要额外重启它**，下次启动自然生效。

> ⚠️ 已知取舍（两条，都是结构性的，撤不掉）：
> 1. 60 秒窗口内没在微信回，**电脑上就会弹框**；此后若改用微信回答，**那个框会留着**。
>    留着没危害：答案已经记下，在框里点任何东西都只是把它关掉，不会覆盖微信的答案。
> 2. 从手机看到推送再回复经常超过 60 秒（实测两次：44 秒、157 秒），想少见过期框就把上面
>    那个 ms 文件调大 —— 代价是坐在电脑前时要等更久才看到框。

判定规则：单问题回数字 `2` 映射到第 2 个选项；无选项的问题把自由文本放进 `custom`；
多个问题用 `2 1` 这种空格分隔。**有选项却回了不相关的话（或越界编号）一律不拦截**，
照常当新任务交给 agent —— 不会吞掉用户的消息。

> 为什么不能"两边同时弹、微信赢了再关掉电脑上的框"：客户端 `PendingQuestion` 只有三条结束路径
> （浏览器作答 / 客户端主动 delegate / `request.signal` abort），而那个 signal 归工具所有，
> 插件拿不到 controller，**撤不掉已经创建的框**。所以只能不让它创建。

**维护**：插件补丁标记 `dsh-bridge-patch: question-answerer v5`（`$script:BridgePatchMarker`），
守护进程补丁标记 `dsh-bridge-patch: qa-answer-short-circuit v1`（`$script:BridgeDaemonPatchMarker`）——
两个文件分别由 `Invoke-BridgePluginPatch` / `Invoke-BridgeDaemonPatch` 处理，统一入口 `Invoke-BridgePatches`。
启动器每次启动自检重打，逻辑同 reveal-foreground（有 `.dshbak` 备份、发现旧版先还原、锚点找不到就跳过）。
**插件那条要重启 DSH 才生效**；守护进程那条下次启动自然生效。

自测：
- 逻辑：`node tools\done-notify\test-question-answerer.mjs`（19 项，含"微信答了绝不调用 GUI""超时才交接"
  "交接后微信答依然算数""推不出去直接兜底""不该拦截的反例"）。
- 补丁注入：`powershell -File tests\test-bridge-daemon-patch.ps1` —— 启动器语法检查、把守护进程还原成
  原厂文件再让启动器的代码重新注入、与手工补丁**逐字节比对**、跑第二遍验幂等、`node --check`。

## 自动升级哪些、跳过哪些

| 项 | 默认 | 说明 |
| --- | --- | --- |
| dsh 主体 `@deepseek-ai/dsh` | 自动升 | 只跟正式通道 `latest` |
| 内核 `@deepseek-ai/dsh-*`（约 230 个包） | 自动升 | `npm update` |
| 插件（web 配置档依赖） | 自动升 | npm 包升到 latest；GitHub 包拉分支最新提交 |
| 模型 | 不单独升 | 模型清单由内核提供，随内核升级 |
| dsh 预发布通道 `next` | **跳过** | 想上预发布自己手动装 |
| Node | **跳过** | 走 nvm 换版本风险大，需要手动确认 |

## 它检查什么

| 编号 | 检查项 | 数据来源 |
| --- | --- | --- |
| 1 | dsh 主体 | npm 源 `latest` / `next` tag |
| 2 | 内核全部核心包 | 本地 node_modules 扫最大版本 |
| 3 | 插件 | 包版本 + `pnpm-lock.yaml` 锁定提交 + GitHub API |
| 4 | 模型 | `~/.dsh/settings.yaml` + 内核里的模型清单 |
| 5 | Node | npmmirror 的 node 二进制索引 |

## 踩过的坑（改这个脚本前先看）

- **本机只有 Windows PowerShell 5.1，没有 pwsh**。`dsh-launcher.ps1` 必须保存为 **UTF-8 带 BOM**，
  否则 5.1 按 GBK 读，中文字符串会把脚本读成乱码（症状：`Unexpected token` + 乱码）。
  用编辑器或工具改完这个文件后，记得补 BOM：
  ```powershell
  $f = '.\dsh-launcher.ps1'
  $t = [IO.File]::ReadAllText($f, [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($f, $t, [Text.UTF8Encoding]::new($true))
  ```
- **系统代理指向已退出的 Clash**：`HKCU\...\Internet Settings\ProxyEnable=1` +
  `ProxyServer=127.0.0.1:7890`，而 Clash 没在跑时，PowerShell 的 `Invoke-RestMethod` 会走这个死代理，
  每次请求都要等超时重试（检查一次 20~30 秒，还经常"查询失败"）。
  脚本开头已经清掉进程默认代理（`[Net.WebRequest]::DefaultWebProxy = New-Object Net.WebProxy`），
  国内源直连、只有 GitHub 请求显式带 `-Proxy`。**这一条把检查从 30 秒降到 10 秒以内。**
- **同一病根的第二个变种（2026-09-14 复发，已根治）**：这次不是"死代理"，而是
  **Clash 活着但处于全局模式 + 出口节点失效** —— 7890 正常监听却对每个请求回 `502`。
  浏览器、微信全部走系统代理 → "百度打不开"，而**直连百度 200 / 0.13 秒**，网络本身没问题。
  - 真正的开关在 Clash Verge 自己的配置里（**注意：配置目录是 `C:\Users\Huawei\.config\clash-verge\`，
    不在 AppData 下**）：`verge.yaml` 的 `enable_system_proxy: true` 每次启动都会把系统代理
    指向 `127.0.0.1:7890`；`clash-verge.yaml` / `config.yaml` 里的 `mode: global` 会把**国内站点
    也塞进节点**，于是节点一挂整机断网。
  - 已做：① 两处 `mode: global` → `mode: rule`（规则里 `GeoIP CN → DIRECT`，国内直连，
    节点死活都不影响百度）；② `GLOBAL` 组出口从失效的 `🇺🇸US2` 切到可用节点。
  - 已加：启动器里的 `Repair-ProxyHealth` 函数（`Invoke-Main` 第 1.5 步调用，
    `-DryRun` 时只报告）。它只在两种情况下动手：**7890 没人监听 → 关掉系统代理**（并广播
    `InternetSetOption` 让浏览器立刻生效）；**内核在跑但模式是 global → 切回 rule**。
    其余情况完全静默，实测健康态耗时 154ms。
  - 改 `dsh-launcher.ps1` 后**务必补 UTF-8 BOM**：edit 类工具会把 BOM 削掉，而 PS 5.1 会按 GBK
    误读中文，症状是 `Parser::ParseFile` 报上百处莫名其妙的语法错误（本次报了 122 处）。
    校验方法：`[IO.File]::ReadAllBytes($f)[0..2]` 必须是 `EF BB BF`。
  - Clash Verge **不是开机自启**（HKCU/HKLM Run、启动文件夹都没有它），是"用的时候才被拉起来"，
    所以这类故障总是在某次手动/脚本启动它之后出现。
- **从资源管理器双击启动时 PATH 可能是旧的**（踩过一次）：`nvm use` 换版本后 explorer 不刷新自己的
  环境变量，双击启动器拿到的 PATH 里可能只有 `nvm\.nodejs`；而那个目录里只有 `pnpm.exe`（nvm 的 shim），
  **没有 `pnpm.cmd`**。于是 `Get-Command pnpm.cmd` 找不到 → 回退成裸字符串 `pnpm.cmd` → 报
  `The term 'pnpm.cmd' is not recognized`，整个启动器崩掉。
  现在用 `Resolve-Executable` 同时查 **进程 PATH + 注册表 Machine/User PATH**，
  并依次尝试 `pnpm.cmd / pnpm.exe / pnpm.bat / pnpm`（npm 同理）。
- **升级失败绝不能拖垮启动**：`Invoke-ToolCmd` 内部 try/catch，找不到工具返回 127 跳过这一步；
  最外层 `catch` 也会兜底再尝试启动一次 DSH —— 用户点启动器是为了用 DSH，不是为了升级。
- **npmmirror 整包元数据接口不能用**：`https://registry.npmmirror.com/@scope/pkg` 太大，
  PS 5.1 会报"基础连接已经关闭"，只能用 `/latest`、`/next` 这种小接口。
- **按键检测**：只用 `[Console]::KeyAvailable`，它在"输入被重定向"的环境里会抛异常，
  所以必须包 try/catch（脚本里已经包了；重定向时自动降级为"不能跳过"而不是崩掉）。
- **PowerShell 大小写不敏感**：`$HDR` 和 `$hdr` 是同一个变量。
- **逗号比加减号优先级高**：`New-Object Size($W - 58, $h)` 会被解析成数组减法而报
  `op_Subtraction`，要写成 `($W - 58)`。
- **桌面新建的 .lnk 会被删掉**（这台机器上是 360 的快捷方式保护）。绕过办法：
  先在目标位置 `New-Item -ItemType File` 占一个 0 字节的坑，再 `Copy-Item` 把做好的 .lnk 覆盖上去。
- **升级前会先关掉正在运行的 DSH**（Windows 文件占用会导致替换失败）。因为"DSH 在运行中"会直接退出，
  正常路径下不会发生；`-Restart` 是显式走这条路的。

## 改配置

脚本开头 `$script:Cfg`：

```powershell
$script:Cfg.DshHome    = "$env:USERPROFILE\.dsh"
$script:Cfg.RuntimeDir = "$env:LOCALAPPDATA\npm-cache\_npx\1e7f6d9597241db0"   # 就是现在实际在跑的这份 dsh
$script:Cfg.Registry   = 'https://registry.npmmirror.com'
$script:Cfg.Profile    = 'web'
$script:Cfg.Port       = 3080
$script:Cfg.Proxy      = 'http://127.0.0.1:7890'
```

## 日志

启动日志在 `%LOCALAPPDATA%\dsh-launcher\logs\dsh-<时间>.out.log`（错误在 `.err.log`）。
启动 90 秒还没就绪会把最后 30 行打出来。
