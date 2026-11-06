
$ErrorActionPreference = 'Stop'
function Run-Test($pattern, $file) {
  $out = & node --test --test-name-pattern=$pattern $file 2>&1 | Out-String
  if ($out -match 'not ok') { 'MUTANT_KILLED' } else { 'MUTANT_SURVIVED' }
}
$root = 'F:\开发\Dsh-chajian\dsh-session-watchdog'
Set-Location $root

'--- Mutation A: 关闭幂等去重（policy.js） ---'
$f = Join-Path $root 'lib\policy.js'
$orig = [IO.File]::ReadAllText($f)
try {
  $mut = $orig.Replace("if (processed.has(decision.id)) return deny('duplicate')", "if (false) return deny('duplicate')")
  if ($mut -eq $orig) { throw 'A: pattern not found' }
  [IO.File]::WriteAllText($f, $mut, (New-Object System.Text.UTF8Encoding($false)))
  Run-Test '幂等' 'test/policy.test.mjs'
} finally { [IO.File]::WriteAllText($f, $orig, (New-Object System.Text.UTF8Encoding($false))) }

'--- Mutation B: 去掉审批等待判定（detector.js） ---'
$f2 = Join-Path $root 'lib\detector.js'
$orig2 = [IO.File]::ReadAllText($f2)
try {
  $mut2 = $orig2.Replace("const awaitingUser = state.pendingApprovals > 0", "const awaitingUser = false")
  if ($mut2 -eq $orig2) { throw 'B: pattern not found' }
  [IO.File]::WriteAllText($f2, $mut2, (New-Object System.Text.UTF8Encoding($false)))
  Run-Test '审批' 'test/detector.test.mjs'
  Run-Test '等待用户审批' 'test/plugin.test.mjs'
} finally { [IO.File]::WriteAllText($f2, $orig2, (New-Object System.Text.UTF8Encoding($false))) }

'--- Mutation C: 去掉会话续跑预算（policy.js） ---'
$orig3 = [IO.File]::ReadAllText($f)
try {
  $mut3 = $orig3.Replace("else if (state.resumes.length >= config.maxResumesPerSession) resumeBlocked = 'session-budget'", "else if (false) resumeBlocked = 'session-budget'")
  if ($mut3 -eq $orig3) { throw 'C: pattern not found' }
  [IO.File]::WriteAllText($f, $mut3, (New-Object System.Text.UTF8Encoding($false)))
  Run-Test '每会话续跑预算' 'test/policy.test.mjs'
} finally { [IO.File]::WriteAllText($f, $orig3, (New-Object System.Text.UTF8Encoding($false))) }

'--- Mutation D: 设置保存后不即时应用（index.js） ---'
$f4 = Join-Path $root 'lib\index.js'
$orig4 = [IO.File]::ReadAllText($f4)
try {
  $mut4 = $orig4.Replace("if (next && typeof next === 'object') Object.assign(config, next)", "if (next && typeof next === 'object') { /* mutant: skip apply */ }")
  if ($mut4 -eq $orig4) { throw 'D: pattern not found' }
  [IO.File]::WriteAllText($f4, $mut4, (New-Object System.Text.UTF8Encoding($false)))
  Run-Test '保存后规则即时生效' 'test/plugin.test.mjs'
} finally { [IO.File]::WriteAllText($f4, $orig4, (New-Object System.Text.UTF8Encoding($false))) }

'--- Mutation E: 关闭任务完成提醒（policy.js） ---'
$f5 = Join-Path $root 'lib\policy.js'
$orig5 = [IO.File]::ReadAllText($f5)
try {
  $mut5 = $orig5.Replace("if (kind === 'completed' && !config.notifyOnCompletion) return deny('completion-muted')", "if (kind === 'completed') return deny('normal-end')")
  if ($mut5 -eq $orig5) { throw 'E: pattern not found' }
  [IO.File]::WriteAllText($f5, $mut5, (New-Object System.Text.UTF8Encoding($false)))
  Run-Test '任务完成' 'test/plugin.test.mjs'
} finally { [IO.File]::WriteAllText($f5, $orig5, (New-Object System.Text.UTF8Encoding($false))) }

'--- Mutation F: 续跑指令永远用固定上下文拼装（resume-instruction.js） ---'
$f6 = Join-Path $root 'lib\resume-instruction.js'
$orig6 = [IO.File]::ReadAllText($f6)
try {
  $mut6 = $orig6.Replace("if (config.resumePromptMode === 'context') return fallback()", "return fallback()")
  if ($mut6 -eq $orig6) { throw 'F: pattern not found' }
  [IO.File]::WriteAllText($f6, $mut6, (New-Object System.Text.UTF8Encoding($false)))
  Run-Test 'llm 模式' 'test/resume-instruction.test.mjs'
  Run-Test '由对应会话的真实内容经模型生成' 'test/plugin.test.mjs'
} finally { [IO.File]::WriteAllText($f6, $orig6, (New-Object System.Text.UTF8Encoding($false))) }

'--- Mutation G: 续跑时直接读 ctx.llm（v0.3.0 崩溃写法） ---'
$f7 = Join-Path $root 'lib\index.js'
$orig7 = [IO.File]::ReadAllText($f7)
try {
  $mut7 = $orig7.Replace("llm: readService(ctx, 'llm'),", "llm: ctx.llm,")
  if ($mut7 -eq $orig7) { throw 'G: pattern not found' }
  [IO.File]::WriteAllText($f7, $mut7, (New-Object System.Text.UTF8Encoding($false)))
  Run-Test '插件未声明 inject' 'test/plugin.test.mjs'
} finally { [IO.File]::WriteAllText($f7, $orig7, (New-Object System.Text.UTF8Encoding($false))) }

'--- Mutation H: 崩溃恢复不补读会话日志（上下文为空） ---'
$f8 = Join-Path $root 'lib\index.js'
$orig8 = [IO.File]::ReadAllText($f8)
try {
  $mut8 = $orig8.Replace("await hydrateStartupDecision(decision)", "void hydrateStartupDecision(decision)")
  if ($mut8 -eq $orig8) { throw 'H: pattern not found' }
  [IO.File]::WriteAllText($f8, $mut8, (New-Object System.Text.UTF8Encoding($false)))
  Run-Test '崩溃恢复' 'test/plugin.test.mjs'
} finally { [IO.File]::WriteAllText($f8, $orig8, (New-Object System.Text.UTF8Encoding($false))) }

'--- Mutation I: 卡片回到右上角（client 定位） ---'
$f9 = Join-Path $root 'lib\client.js'
$orig9 = [IO.File]::ReadAllText($f9)
try {
  $mut9 = $orig9.Replace("bottom: '12px',", "top: '12px',")
  if ($mut9 -eq $orig9) { throw 'I: pattern not found' }
  [IO.File]::WriteAllText($f9, $mut9, (New-Object System.Text.UTF8Encoding($false)))
  Run-Test '固定在右下角' 'test/client-sound.selftest.mjs'
} finally { [IO.File]::WriteAllText($f9, $orig9, (New-Object System.Text.UTF8Encoding($false))) }

'--- Mutation J: 宿主标题回退到「未命名会话」 ---'
$f10 = Join-Path $root 'lib\index.js'
$orig10 = [IO.File]::ReadAllText($f10)
try {
  $mut10 = $orig10.Replace("title: decision.title || context.title || '',", "title: decision.title || context.title || '未命名会话',")
  if ($mut10 -eq $orig10) { throw 'J: pattern not found' }
  [IO.File]::WriteAllText($f10, $mut10, (New-Object System.Text.UTF8Encoding($false)))
  Run-Test '异常结束' 'test/plugin.test.mjs'
} finally { [IO.File]::WriteAllText($f10, $orig10, (New-Object System.Text.UTF8Encoding($false))) }

'--- 还原后回归 ---'
$out = & node --test 2>&1 | Out-String
($out -split "\r?\n" | Select-String '# pass|# fail') -join ' | '
