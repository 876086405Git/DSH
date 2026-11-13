<#
.SYNOPSIS
  DeepSeek Harness 桌面端全自动升级修复工具（v4 本机适配版）
.DESCRIPTION
  全自动：查最新版 -> 下载 -> SHA512/签名校验 -> 清理占用 -> 验证目录 -> 安装 -> 核验 -> 启动
  内置自修复：断点续传重试、校验失败重下、目录占用重试、安装失败重试、失败回滚启动旧版
.NOTES
  v4 相对 v3 的 6 处本机适配修复（均基于本机实测）：
   1) 【致命】自动脱离 DSH 进程树：AI 代跑时脚本是 DSH 子进程，强行杀 DSH 会连带
      杀死脚本本身导致升级中断。现在检测到自己在 DSH 树内就用计划任务脱离执行。
   2) 备份清单补齐 pnpm-workspace.yaml / pnpm-lock.yaml（原版只备份 3 个文件，
      回滚后插件版本可能与新程序不匹配）。
   3) TEMP 预检清理：本机 TEMP 曾堆 5000+ 条目，安装器解压 7892 个文件时
      extract-failure（7-Zip 退出码 2）。现在 >1500 条就清 7 天前旧残留。
   4) 残留清理覆盖 .old- / .new- / .broken- / .upgrade-probe（原版只清 .old-）。
   5) 日志改为无 BOM UTF-8 追加（PS5.1 的 Add-Content -Encoding UTF8 会写 BOM）。
   6) 健康检查不再仅凭"3 分钟内有 crash 日志"就回滚：只统计升级完成之后的
      致命崩溃，且窗口仍稳定时判定可接受（避免白升）。
.PARAMETER Force
  目标版本 <= 当前版本时也强制重装
.PARAMETER ProbeLatest
  主动探测 bin 目录中更高的版本号（应对官方 feed 滞后）
.PARAMETER Silent
  静默安装（NSIS /S）
.PARAMETER NoStart
  安装后不启动 DSH
.PARAMETER DryRun
  只检查版本/空间/占用，不下载不安装
.PARAMETER InstallerPath
  跳过下载，直接使用指定安装包
#>
param(
    [switch]$Force,
    [switch]$ProbeLatest,
    [switch]$Silent,
    [switch]$NoStart,
    [switch]$DryRun,
    [switch]$RollbackOnly,
    [switch]$DetachedChild,
    [string]$InstallerPath = '',
    # 【v4.11 新增】按需恢复
    [switch]$Verify,              # 只体检：比对备份 vs 现装，不修改任何文件
    [switch]$Repair,              # 按需补齐：只复制缺失/损坏文件（默认预演，需配 -Confirm）
    [switch]$Confirm,             # 与 -Repair 配合，真正写盘
    [switch]$AllowCrossVersion,   # 允许跨版本修复（默认拒绝）
    [switch]$SkipHash             # 体检时只比大小不比哈希（快）
)

# 【v4.3 新增】未知参数校验。
# 背景：用 -File 方式调用时，拼错的参数（如 -Force2）会被 PowerShell 静默忽略，
# 脚本照常跑，用户以为加了某个选项其实没生效 —— 这是危险的静默失败。
# 这里显式检查未绑定的位置参数，发现就打中文提示并退出（退出码 22）。
if ($args.Count -gt 0) {
    Write-Host ''
    Write-Host '[错误] 检测到无法识别的参数：' -ForegroundColor Red
    foreach ($a in $args) { Write-Host ('        ' + $a) -ForegroundColor Red }
    Write-Host ''
    Write-Host '可用的参数有：' -ForegroundColor Yellow
    Write-Host '  -Force          强制重装（即使已是最新版本）'
    Write-Host '  -ProbeLatest    主动探测 bin 目录里的更新版本'
    Write-Host '  -Silent         静默安装（不弹安装向导）'
    Write-Host '  -NoStart        装完不自动启动 DSH'
    Write-Host '  -DryRun         仅预检，不下载不安装'
    Write-Host '  -RollbackOnly   仅从最近备份回滚，不升级（整目录全量）'
    Write-Host '  -InstallerPath  指定安装包路径'
    Write-Host ''
    Write-Host '  按需恢复（v4.11 新增）：' -ForegroundColor Cyan
    Write-Host '  -Verify         只体检：比对「备份 vs 现装」，列出缺失/损坏/多余，不修改任何文件'
    Write-Host '  -Repair         按需补齐：只复制缺失/损坏的文件，其余不动（默认预演，不写盘）'
    Write-Host '  -Confirm        与 -Repair 配合，真正写盘执行'
    Write-Host '  -AllowCrossVersion  允许跨版本修复（默认拒绝，防止文件混杂）'
    Write-Host '  -SkipHash       体检时只比大小不比 SHA256（大目录更快）'
    Write-Host ''
    Write-Host '提示：通常直接双击【一键升级-v4.bat】选菜单即可，不需要手敲参数。' -ForegroundColor Gray
    Write-Host ''
    exit 22
}

# 【v4 新增】标记本进程已脱离 DSH 进程树（由计划任务拉起），不再二次脱离。
if ($DetachedChild) { $env:DSH_UPGRADE_DETACHED = '1' }

# 【v4.1 新增·并发保护】单实例互斥锁。
# 风险：用户双击两次 .bat，两个实例会同时杀 DSH、同时抢装，导致安装器互相打架、
# 甚至把刚装好的目录再改坏。用系统级命名 Mutex 保证同一时刻只跑一个实例。
# 注意：子进程（-DetachedChild）需要拿到锁，父进程在脱离前会主动释放。
$script:UpgradeMutex = $null
if (-not $env:DSH_UPGRADE_MUTEX_HELD) {
    try {
        $createdNew = $false
        $script:UpgradeMutex = New-Object System.Threading.Mutex($true, 'Global\DSH-AutoUpgrade-SingleInstance', [ref]$createdNew)
        if (-not $createdNew) {
            Write-Host ''
            Write-Host '[ERROR] 已有一个 DSH 升级实例正在运行，本次退出以免两个安装器互相破坏。' -ForegroundColor Red
            Write-Host '        请等待上一个窗口跑完；若确认没有在跑，请重启电脑后再试。' -ForegroundColor Yellow
            exit 21
        }
        $env:DSH_UPGRADE_MUTEX_HELD = '1'
    } catch {
        # 拿不到互斥体（极少数权限场景）也继续，但不阻断升级
        $script:UpgradeMutex = $null
    }
}

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

# ===================== 配置 =====================
$Root       = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Root) { $Root = (Get-Location).Path }
$LogFile    = Join-Path $Root 'DSH-AutoUpgrade.log'
$DlDir      = Join-Path $Root 'downloads'
$InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness'
$ExePath    = Join-Path $InstallDir 'DeepSeek Harness.exe'
$ProfileDir = Join-Path $env:USERPROFILE '.dsh\profiles\desktop'
$FeedUrl    = 'https://download.deepseek.com/dsh-desk/feeds/win-x64/nightly.yml'
$BinBase    = 'https://download.deepseek.com/dsh-desk/bin/win-x64/'
# 回滚备份目录：自动跟随安装目录所在分区（同分区复制最快）
$RollbackDir = (Split-Path $InstallDir -Qualifier) + '\dsh-rollback'
$MaxKillRounds = 10
$MaxRenameTries = 4
$MaxDownloadTries = 4
$InstallerTimeoutMin = 15
$MinFreeGB = 3          # 兜底最小值；实际按 2x程序目录 + 1.5GB 动态计算
$RollbackWaitSec = 90   # 回滚后等窗口出现的上限

# 数据保护清单：以下路径【绝不】备份、删除或恢复（升级只动程序目录）
$ProtectedData = @(
    (Join-Path $env:USERPROFILE '.dsh\sessions'),
    (Join-Path $env:USERPROFILE '.dsh\attachments'),
    (Join-Path $env:USERPROFILE '.dsh\.credentials.yaml'),
    (Join-Path $env:USERPROFILE '.dsh\storages'),
    (Join-Path $env:USERPROFILE '.dsh\skills'),
    (Join-Path $env:USERPROFILE '.dsh\integrations'),
    (Join-Path $env:USERPROFILE '.dsh\rewind-snapshots'),
    (Join-Path $ProfileDir 'node_modules')
)
# 【v4 修复】只备份这 3 个文件会漏掉 pnpm 配置：
# 本机 profile 里有 pnpm-workspace.yaml（插件版本豁免，被 pnpm 频繁改写、曾写坏过）
# 和 pnpm-lock.yaml（锁定所有插件版本）。回滚时不恢复它们，插件状态会与新程序不匹配。
$ConfigFilesToBackup = @('package.json','cordis.yml','cordis.patch.yml','pnpm-workspace.yaml','pnpm-lock.yaml')

# ===================== 日志 =====================
# 【v4.9 修复·致命】Test-DshWebAlive 必须在 Restore-FromBackup 之前定义，
# 因为后者内部（回滚后的健康检查）会调用它。PowerShell 顺序执行，
# 定义在使用之后 = 函数不存在 = 调用抛错被吞 = 回滚后 Web 探测永远失败。
function Test-DshWebAlive {
    param([int]$TimeoutSec = 30)
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $TimeoutSec) {
        try {
            $pids = @(Get-DshProcesses | ForEach-Object { $_.Id })
            if ($pids.Count -eq 0) { return $null }
            # 找这些进程正在监听的本地 TCP 端口
            $listen = @()
            try {
                $listen = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
                    Where-Object { $pids -contains $_.OwningProcess -and $_.LocalAddress -match '^(127\.0\.0\.1|0\.0\.0\.0|::1|::)$' })
            } catch {}
            foreach ($l in $listen) {
                $port = $l.LocalPort
                # 只探测高位端口，避免误判系统端口
                if ($port -lt 1024) { continue }
                # 【v4.7 修复·致命】原来用 foreach ($host in @('127.0.0.1'))，
                # 但 $host 是 PowerShell 的只读内置变量（ConsoleHost），赋值直接抛
                # "无法覆盖变量 Host，因为该变量为只读变量或常量"，而该异常又被外层
                # catch {} 静默吞掉 —— 导致 Web 探测【从未生效过】，虚拟机里永远判定启动失败。
                # 修复：变量改名为 $probeHost。
                foreach ($probeHost in @('127.0.0.1')) {
                    try {
                        $r = Invoke-WebRequest -Uri ('http://' + $probeHost + ':' + $port + '/') -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
                        # 【v4.13 修复】PS 5.1 的 .Content 可能是 byte[]（同 feed 那个问题），
                        # 直接 -match '<html' 会失败，导致 200 响应被判成「不健康」。
                        $body = $r.Content
                        if ($body -is [byte[]]) {
                            try { $body = [System.Text.Encoding]::UTF8.GetString($body) } catch { $body = '' }
                        }
                        if ($body -isnot [string]) { $body = [string]$body }
                        if ($r.StatusCode -eq 200 -and $body -match '<html|<!doctype') {
                            return [pscustomobject]@{ Port = $port; Status = $r.StatusCode; Length = $body.Length }
                        }
                        # 200 但内容不含 html：也算服务活着（可能是 JSON / 重定向页），
                        # 只是长度记为 0，避免误判启动失败。
                        if ($r.StatusCode -eq 200) {
                            return [pscustomobject]@{ Port = $port; Status = $r.StatusCode; Length = $body.Length }
                        }
                    } catch {
                        # 401 也算「服务活着」（只是缺 token）
                        $code = 0
                        try { $code = [int]$_.Exception.Response.StatusCode } catch {}
                        if ($code -eq 401 -or $code -eq 403) {
                            return [pscustomobject]@{ Port = $port; Status = $code; Length = 0 }
                        }
                    }
                }
            }
        } catch {}
        Start-Sleep -Milliseconds 800
    }
    return $null
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    # 【v4 修复】PowerShell 5.1 的 Add-Content -Encoding UTF8 会写 BOM，
    # 且多次追加时中文可能被 ANI 码页误读导致乱码。改为显式无 BOM 追加。
    # 【v4.2 汉化】日志级别标签原本是 [OK]/[WARN]/[ERROR]/[STEP]/[INFO]，
    # 用户反馈看不懂英文，统一改成中文标签。
    $label = switch ($Level) {
        'OK'    { '成功' }
        'WARN'  { '注意' }
        'ERROR' { '失败' }
        'STEP'  { '步骤' }
        default { '信息' }
    }
    $line = "[$ts][$label] $Message"
    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::AppendAllText($LogFile, $line + [Environment]::NewLine, $utf8NoBom)
    } catch {}
    switch ($Level) {
        'OK'    { Write-Host $line -ForegroundColor Green }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'STEP'  { Write-Host $line -ForegroundColor Cyan }
        default { Write-Host $line -ForegroundColor Gray }
    }
}
function New-Section { param([string]$T) Write-Log ''; Write-Log ('========== ' + $T + ' ==========') 'STEP' }

try {
    if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 512KB)) {
        Move-Item $LogFile ($LogFile + '.old') -Force -ErrorAction SilentlyContinue
    }
} catch {}
Write-Log '############################################################'
$cnBool = { param($v) if ($v) { '是' } else { '否' } }
Write-Log ('DSH 全自动升级工具 v4（本机适配）启动' + '  强制重装=' + (& $cnBool $Force) + '  探测最新=' + (& $cnBool $ProbeLatest) + '  静默安装=' + (& $cnBool $Silent) + '  仅预检=' + (& $cnBool $DryRun) + '  仅回滚=' + (& $cnBool $RollbackOnly) + '  体检=' + (& $cnBool $Verify) + '  按需修复=' + (& $cnBool $Repair))

# ===================== 工具函数 =====================

# 【v4 新增·致命修复】判断某进程是否在本脚本祖先链（=DSH 进程树）内。
# 背景：本工具常被用户在 DSH 会话里让 AI 代跑，此时 powershell 是 DSH 的子进程。
# 阶段3 强杀 DSH 会连带杀死本脚本，导致"升到一半就断"，DSH 停在半装状态。
function Test-InDshTree {
    param([int]$ProcessId)
    $cur = $ProcessId
    $depth = 0
    while ($cur -and $depth -lt 15) {
        $q = Get-CimInstance Win32_Process -Filter "ProcessId=$cur" -ErrorAction SilentlyContinue
        if (-not $q) { return $false }
        if ($q.Name -eq 'DeepSeek Harness.exe') { return $true }
        $cur = $q.ParentProcessId
        $depth++
    }
    return $false
}

function Get-DshProcesses { @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue) }

function Get-InstalledVersion {
    if (Test-Path $ExePath) {
        try { return (Get-Item $ExePath).VersionInfo.FileVersion } catch { return '' }
    }
    return ''
}

function Split-SemVer {
    param([string]$v)
    $v = $v.Trim().TrimStart('v')
    $core = $v; $pre = ''
    $d = $v.IndexOf('-')
    if ($d -ge 0) { $core = $v.Substring(0, $d); $pre = $v.Substring($d + 1) }
    $nums = @()
    foreach ($seg in $core.Split('.')) {
        $n = 0
        if ([int]::TryParse(($seg -replace '[^0-9]', ''), [ref]$n)) { $nums += $n } else { $nums += 0 }
    }
    while ($nums.Count -lt 3) { $nums += 0 }
    return @{ Core = $nums; Pre = $pre }
}

function Compare-SemVer {
    param([string]$A, [string]$B)
    if (-not $A) { return -1 }
    if (-not $B) { return 1 }
    $x = Split-SemVer $A
    $y = Split-SemVer $B
    for ($i = 0; $i -lt 3; $i++) {
        if ($x.Core[$i] -lt $y.Core[$i]) { return -1 }
        if ($x.Core[$i] -gt $y.Core[$i]) { return 1 }
    }
    if ($x.Pre -eq '' -and $y.Pre -ne '') { return 1 }
    if ($x.Pre -ne '' -and $y.Pre -eq '') { return -1 }
    # 【v4.1 修复】原来用 -eq，但 PowerShell 的 -eq 对字符串【大小写不敏感】，
    # 会把 'RC.2' 与 'rc.2' 误判为相等而提前 return 0，跳过后续有序比较。
    # SemVer 规范要求预发布标识区分大小写（按 ASCII 序），故改用 -ceq。
    if ($x.Pre -ceq $y.Pre) { return 0 }
    $px = @($x.Pre -split '\.')
    $py = @($y.Pre -split '\.')
    $n = [Math]::Min($px.Count, $py.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $nx = 0; $ny = 0
        $ix = [int]::TryParse($px[$i], [ref]$nx)
        $iy = [int]::TryParse($py[$i], [ref]$ny)
        if ($ix -and $iy) {
            if ($nx -lt $ny) { return -1 }
            if ($nx -gt $ny) { return 1 }
        } else {
            $c = [string]::CompareOrdinal($px[$i], $py[$i])
            if ($c -lt 0) { return -1 }
            if ($c -gt 0) { return 1 }
        }
    }
    if ($px.Count -lt $py.Count) { return -1 }
    if ($px.Count -gt $py.Count) { return 1 }
    return 0
}

function Start-Dsh {
    if ($NoStart) { Write-Log '按参数跳过启动'; return }
    if (Test-Path $ExePath) {
        Write-Log '启动 DSH...'
        try { Start-Process -FilePath $ExePath -WorkingDirectory $InstallDir | Out-Null } catch { Write-Log ('启动失败: ' + $_.Exception.Message) 'WARN' }
    }
}

function Wait-DshWindow {
    param([int]$TimeoutSec = 60)
    $t0 = Get-Date
    # 【v4.1 修复】原来用 $i -gt 20（约 10 秒）才开始判断"进程已死"，
    # 若 DSH 启动瞬间崩溃要白等 10 秒；且原逻辑只看"进程数=0"，
    # 漏掉"进程还在但反复重启、窗口永远出不来"的崩溃循环。
    # 现在：记录首轮进程数，若连续多轮进程数始终为 0 则立即返回失败。
    $deadRounds = 0
    for ($i = 0; $i -lt ($TimeoutSec * 2); $i++) {
        Start-Sleep -Milliseconds 500
        $pr = Get-DshProcesses
        if (@($pr | Where-Object { $_.MainWindowHandle -ne 0 }).Count -gt 0) {
            return [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
        }
        if ($pr.Count -eq 0) {
            $deadRounds++
            # 连续 6 次（约 3 秒）没有任何进程 => 启动失败，立刻返回
            if ($deadRounds -ge 6) { return -1 }
        } else {
            $deadRounds = 0
        }
    }
    return -1
}

# 备份程序目录 + profile 配置；失败返回 $null（调用方必须中止升级）
function Backup-Installation {
    param([string]$VersionTag)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeVer = ($VersionTag -replace '[^0-9A-Za-z.-]', '_')
    $bkRoot = Join-Path $RollbackDir ('app-' + $safeVer + '-' + $stamp)
    New-Item -ItemType Directory -Force -Path $bkRoot | Out-Null

    Write-Log ('备份程序目录 -> ' + $bkRoot)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & robocopy $InstallDir $bkRoot /E /NFL /NDL /NJH /NJS /R:1 /W:1 /MT:8 2>&1 | Out-Null
    $code = $LASTEXITCODE
    $sw.Stop()
    if ($code -ge 8) {
        Write-Log ('备份失败（robocopy 退出码 ' + $code + '）') 'ERROR'
        return $null
    }
    $srcCount = @(Get-ChildItem $InstallDir -Recurse -File -Force -ErrorAction SilentlyContinue).Count
    $dstCount = @(Get-ChildItem $bkRoot -Recurse -File -Force -ErrorAction SilentlyContinue).Count
    $sw2 = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    if ($srcCount -gt 0 -and $dstCount -lt [math]::Floor($srcCount * 0.99)) {
        Write-Log ('备份不完整: ' + $dstCount + '/' + $srcCount + ' 文件') 'ERROR'
        return $null
    }
    Write-Log ('备份完成: ' + $dstCount + '/' + $srcCount + ' 文件, ' + $sw2 + 's') 'OK'

    $cfgDir = Join-Path $bkRoot '_profile'
    New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
    $saved = @()
    foreach ($f in $ConfigFilesToBackup) {
        $src = Join-Path $ProfileDir $f
        if (Test-Path $src) {
            Copy-Item $src (Join-Path $cfgDir $f) -Force -ErrorAction SilentlyContinue
            $saved += $f
        }
    }
    Write-Log ('已备份 profile 配置: ' + ($saved -join ', '))

    $totalBytes = (Get-ChildItem $bkRoot -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    $meta = [ordered]@{
        version     = $VersionTag
        backupTime  = (Get-Date).ToString('o')
        installDir  = $InstallDir
        profileDir  = $ProfileDir
        fileCount   = $dstCount
        totalBytes  = $totalBytes
        configFiles = $saved
    }
    try { ($meta | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $bkRoot '_meta.json') -Encoding UTF8 } catch {}
    return $bkRoot
}

# 自动回滚：恢复程序目录与配置，并验证可用
function Restore-FromBackup {
    param([string]$BackupPath)

    New-Section '自动回滚 / 恢复升级前版本'
    if (-not $BackupPath -or -not (Test-Path $BackupPath)) {
        Write-Log '备份不存在，无法回滚' 'ERROR'
        return $false
    }
    Write-Log ('备份来源: ' + $BackupPath)

    # 1) 结束所有进程
    # 【v4.9 修复·致命】原来只做 $p.Kill() + catch{}，两个问题：
    #  a) Kill() 是异步的，立即检查「进程数=0」常常还没退干净就往下走；
    #  b) 杀失败的错误被 catch{} 静默吞掉，日志里完全看不出为什么回滚失败。
    # 实测（虚拟机 2026-11-13）：回滚 3 秒就 return false，日志零线索，
    # 真实原因是进程占着安装目录导致改名报「另一个进程正在使用此文件」。
    # 修复：Kill 后等待退出、失败重试、记录每步结果、失败时打印占用进程。
    $round = 0
    do {
        $round++
        $ps = @(Get-DshProcesses)
        if ($ps.Count -eq 0) { break }
        Write-Log ('结束进程 ' + $ps.Count + ' 个（第 ' + $round + ' 轮）')
        foreach ($p in $ps) {
            try { $p.Kill(); $null = $p.WaitForExit(5000) }
            catch { Write-Log ('  结束进程失败 PID=' + $p.Id + ': ' + $_.Exception.Message) 'WARN' }
        }
        Start-Sleep -Seconds 2
    } while ($round -lt 10)
    $left = @(Get-DshProcesses)
    if ($left.Count -gt 0) {
        Write-Log ('进程无法结束（剩余 ' + $left.Count + ' 个），回滚中止') 'ERROR'
        foreach ($p in $left) { Write-Log ('  仍在运行: PID=' + $p.Id + ' ' + $p.ProcessName) 'ERROR' }
        return $false
    }
    Write-Log '所有 DSH 进程已结束' 'OK'

    # 2) 现有（损坏的）目录改名留证据
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $brokenLeaf = (Split-Path $InstallDir -Leaf) + '.broken-' + $stamp
    $renamed = $false
    for ($t = 1; $t -le 4; $t++) {
        try {
            Rename-Item -LiteralPath $InstallDir -NewName $brokenLeaf -ErrorAction Stop
            $renamed = $true
            Write-Log ('损坏目录已改名: ' + $brokenLeaf) 'OK'
            break
        } catch {
            Write-Log ('改名失败(' + $t + '/4): ' + $_.Exception.Message) 'WARN'
            if ($t -eq 2) {
                # 【v4.9 新增】改名被占用时，用 taskkill /F /T 强杀整棵进程树兜底。
                # 实测 .Kill() 有时杀不掉子进程（GPU/utility 进程），taskkill /T 更彻底。
                Write-Log '  改用 taskkill /F /T 强制结束整棵进程树...' 'WARN'
                foreach ($pn in @('DeepSeek Harness')) {
                    & taskkill /F /T /IM ($pn + '.exe') 2>&1 | Out-Null
                }
                Start-Sleep -Seconds 3
            } else {
                Start-Sleep -Seconds 2
                Get-DshProcesses | ForEach-Object { try { $_.Kill() } catch {} }
            }
        }
    }
    if (-not $renamed) {
        Write-Log '无法改名，尝试就地覆盖恢复（风险较高）' 'WARN'
    }

    # 3) 复制备份回去
    Write-Log '从备份恢复程序目录（约 1 分钟，请稍候）...'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $excludeDir = Join-Path $BackupPath '_profile'
    & robocopy $BackupPath $InstallDir /E /NFL /NDL /NJH /NJS /R:1 /W:1 /MT:8 /XD $excludeDir 2>&1 | Out-Null
    $code = $LASTEXITCODE
    $sw.Stop()
    if ($code -ge 8) {
        Write-Log ('恢复复制失败（robocopy 退出码 ' + $code + '）') 'ERROR'
        Write-Log ('备份仍在: ' + $BackupPath) 'WARN'
        return $false
    }
    Write-Log ('恢复复制完成，耗时 ' + [math]::Round($sw.Elapsed.TotalSeconds, 1) + 's') 'OK'

    # 4) 恢复 profile 配置
    $cfgDir = Join-Path $BackupPath '_profile'
    if (Test-Path $cfgDir) {
        foreach ($f in $ConfigFilesToBackup) {
            $src = Join-Path $cfgDir $f
            if (Test-Path $src) {
                try { Copy-Item $src (Join-Path $ProfileDir $f) -Force -ErrorAction Stop; Write-Log ('已恢复配置: ' + $f) 'OK' } catch { Write-Log ('配置恢复失败: ' + $f) 'WARN' }
            }
        }
    }

    # 5) 启动并验证可用
    if (-not (Test-Path $ExePath)) {
        Write-Log '恢复后 exe 不存在' 'ERROR'
        return $false
    }
    Write-Log '启动恢复后的 DSH...'
    try { Start-Process -FilePath $ExePath -WorkingDirectory $InstallDir | Out-Null } catch { Write-Log ('启动失败: ' + $_.Exception.Message) 'ERROR'; return $false }
    $el = Wait-DshWindow -TimeoutSec $RollbackWaitSec
    if ($el -ge 0) {
        Write-Log ('回滚成功，主窗口已出现（' + $el + 's），版本 ' + (Get-InstalledVersion)) 'OK'
        return $true
    }
    # 【v4.7 修复·严重】回滚后的健康检查原来只看窗口，虚拟机/无GPU环境
    # （Electron 降级为 Web 模式、不建窗口）会被误判为「回滚失败」，
    # 进而触发「需要人工介入」，实际上服务跑得好好的。
    # 修复：窗口没出现时，同样走 Web 服务探测。
    Write-Log ('回滚后窗口未在 ' + $RollbackWaitSec + 's 内出现，改查 Web 服务模式...') 'WARN'
    $webOk = Test-DshWebAlive -TimeoutSec 40
    if ($webOk) {
        Write-Log ('回滚成功（Web 模式运行，端口 ' + $webOk.Port + '，HTTP ' + $webOk.Status + '），版本 ' + (Get-InstalledVersion)) 'OK'
        return $true
    }
    Write-Log ('回滚后窗口和 Web 服务均未就绪') 'ERROR'
    return $false
}

#  【v4.11 新增】按需恢复：Compare-BackupTree + Repair-FromBackup
#  背景：原工具只有「整目录全量覆盖」一种恢复方式。如果只是安装目录里
#        个别文件丢失/损坏（版本号对、app.asar 在、窗口也能起），阶段6
#        核验完全检测不出来，只能靠 -Force 整包重装（约 5 分钟）。
#  方案：
#    -Verify  只体检：逐文件比对「备份 vs 现装」，输出缺失/损坏/多余清单，
#             不做任何修改（零风险）。
#    -Repair  按需补齐：在 -Verify 结果基础上，只从备份复制缺失/损坏的文件，
#             其余不动。带版本一致性保护。
# =====================================================================

# 逐文件比对备份树与现装树，返回分类结果。不修改任何文件。
# 返回对象：BackupPath / BackupVersion / CurrentVersion / SameVersion
#           Missing  缺失（备份有、现装无）
#           Corrupt  损坏（两边都有但大小或 SHA256 不同）
#           Extra    多余（现装有、备份无）
#           Total    备份文件总数 / Checked 已比对 / Intact 完好
function Compare-BackupTree {
    param(
        [string]$BackupPath,
        [switch]$SkipHash          # 只比大小不比哈希（快，适合大目录初筛）
    )

    $res = [pscustomobject]@{
        BackupPath      = $BackupPath
        BackupVersion   = ''
        CurrentVersion  = ''
        SameVersion     = $false
        Missing         = @()
        Corrupt         = @()
        Extra           = @()
        Total           = 0
        Checked         = 0
        Intact          = 0
        Ok              = $false
        Reason          = ''
    }

    if (-not $BackupPath -or -not (Test-Path -LiteralPath $BackupPath)) {
        $res.Reason = '备份目录不存在'
        return $res
    }

    # 读备份元数据
    $metaFile = Join-Path $BackupPath '_meta.json'
    if (Test-Path -LiteralPath $metaFile) {
        try { $res.BackupVersion = (Get-Content -LiteralPath $metaFile -Raw | ConvertFrom-Json).version } catch {}
    }
    $res.CurrentVersion = Get-InstalledVersion
    if ($res.BackupVersion -and $res.CurrentVersion) {
        $res.SameVersion = ((Compare-SemVer $res.BackupVersion $res.CurrentVersion) -eq 0)
    }
    # 【v4.11】版本读不到时单独标记，便于上层给出准确提示
    if (-not $res.CurrentVersion) {
        $res.Reason = '无法读取现装版本（DSH 可能未安装，或 exe 无版本信息）'
    } elseif (-not $res.BackupVersion) {
        $res.Reason = '备份里没有版本信息（_meta.json 缺失或损坏）'
    }

    # 枚举备份里的所有文件（排除 _profile 和 _meta.json）
    $excludeProfile = Join-Path $BackupPath '_profile'
    $bkFiles = @(Get-ChildItem -LiteralPath $BackupPath -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike ($excludeProfile + '*') -and $_.Name -ne '_meta.json' })
    $res.Total = $bkFiles.Count
    if ($res.Total -eq 0) {
        $res.Reason = '备份里没有文件'
        return $res
    }

    $bkPrefixLen = (Resolve-Path -LiteralPath $BackupPath).Path.TrimEnd('\').Length + 1

    foreach ($bf in $bkFiles) {
        $rel = $bf.FullName.Substring($bkPrefixLen)
        $cur = Join-Path $InstallDir $rel
        $res.Checked++

        if (-not (Test-Path -LiteralPath $cur)) {
            $res.Missing += [pscustomobject]@{ Rel = $rel; Reason = '缺失'; Size = $bf.Length }
            continue
        }

        $cf = Get-Item -LiteralPath $cur -Force -ErrorAction SilentlyContinue
        if (-not $cf) {
            $res.Missing += [pscustomobject]@{ Rel = $rel; Reason = '无法访问'; Size = $bf.Length }
            continue
        }

        # 大小不同 => 直接判损坏
        if ($cf.Length -ne $bf.Length) {
            $res.Corrupt += [pscustomobject]@{ Rel = $rel; Reason = ('大小不同 ' + $cf.Length + ' != ' + $bf.Length); Size = $bf.Length }
            continue
        }

        # 大小相同：按需比对哈希（默认比，-SkipHash 时跳过）
        if (-not $SkipHash) {
            try {
                $h1 = (Get-FileHash -LiteralPath $bf.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
                $h2 = (Get-FileHash -LiteralPath $cur -Algorithm SHA256 -ErrorAction Stop).Hash
                if ($h1 -ne $h2) {
                    $res.Corrupt += [pscustomobject]@{ Rel = $rel; Reason = '内容不同'; Size = $bf.Length }
                    continue
                }
            } catch {
                $res.Corrupt += [pscustomobject]@{ Rel = $rel; Reason = '哈希计算失败'; Size = $bf.Length }
                continue
            }
        }

        $res.Intact++
    }

    # 现装里多出来的文件（只统计，不参与修复）
    try {
        $curFiles = @(Get-ChildItem -LiteralPath $InstallDir -Recurse -File -Force -ErrorAction SilentlyContinue)
        $bkRelSet = @{}
        foreach ($bf in $bkFiles) { $bkRelSet[$bf.FullName.Substring($bkPrefixLen)] = $true }
        $instPrefixLen = (Resolve-Path -LiteralPath $InstallDir).Path.TrimEnd('\').Length + 1
        foreach ($cf in $curFiles) {
            $rel = $cf.FullName.Substring($instPrefixLen)
            if (-not $bkRelSet.ContainsKey($rel)) {
                $res.Extra += [pscustomobject]@{ Rel = $rel; Size = $cf.Length }
            }
        }
    } catch {}

    $res.Ok = $true
    return $res
}

# 按需修复：只从备份复制缺失/损坏的文件，其余不动。
# 安全约束：
#   - 必须显式 -Confirm 才真正写盘（默认只报告）
#   - 版本不一致时默认拒绝，除非加 -AllowCrossVersion
#   - 修复前把要覆盖的文件备份到 <RollbackDir>\repair-<时间戳>\（可回退）
function Repair-FromBackup {
    param(
        [Parameter(Mandatory = $true)]$CompareResult,
        [switch]$Confirm,
        [switch]$AllowCrossVersion
    )

    if (-not $CompareResult -or -not $CompareResult.Ok) {
        Write-Log ('体检结果无效: ' + $(if ($CompareResult) { $CompareResult.Reason } else { '空' })) 'ERROR'
        return [pscustomobject]@{ Done = $false; Repaired = 0; Failed = 0; Reason = '体检结果无效' }
    }

    $need = @($CompareResult.Missing) + @($CompareResult.Corrupt)
    if ($need.Count -eq 0) {
        Write-Log '没有需要修复的文件（缺失 0，损坏 0）' 'OK'
        return [pscustomobject]@{ Done = $true; Repaired = 0; Failed = 0; Reason = '无需修复' }
    }

    # 版本一致性保护
    # 【v4.11】三档策略：
    #   a) 两边都读到版本且一致      => 放行
    #   b) 两边都读到版本但确实不一致 => 拒绝（除非 -AllowCrossVersion）
    #   c) 有一边读不到版本          => 拒绝（除非 -AllowCrossVersion）
    #      「读不到」不能当成「一致」：exe 无版本信息可能意味着安装本身已损坏，
    #      此时盲目补文件风险更高，必须让用户显式确认。
    $canCheckVer = ($CompareResult.BackupVersion -and $CompareResult.CurrentVersion)
    if (-not $canCheckVer -and -not $AllowCrossVersion) {
        Write-Log '无法确认版本一致性，拒绝按需修复：' 'ERROR'
        Write-Log ('  备份版本: ' + $(if ($CompareResult.BackupVersion) { $CompareResult.BackupVersion } else { '(读不到)' })) 'WARN'
        Write-Log ('  现装版本: ' + $(if ($CompareResult.CurrentVersion) { $CompareResult.CurrentVersion } else { '(读不到)' })) 'WARN'
        Write-Log '  无法确认版本时补文件可能造成文件混杂。' 'WARN'
        Write-Log '  如确认要修复，加 -AllowCrossVersion 参数显式放行。' 'WARN'
        Write-Log '  或者用 -RollbackOnly 整目录回滚到备份版本（最稳）。' 'WARN'
        return [pscustomobject]@{ Done = $false; Repaired = 0; Failed = 0; Reason = '无法确认版本' }
    }
    if ($canCheckVer -and -not $CompareResult.SameVersion -and -not $AllowCrossVersion) {
        Write-Log ('版本不一致，拒绝按需修复：备份 ' + $CompareResult.BackupVersion + ' vs 现装 ' + $CompareResult.CurrentVersion) 'ERROR'
        Write-Log '  跨版本补文件可能造成文件混杂、启动异常。' 'WARN'
        Write-Log '  如确认要跨版本修复，加 -AllowCrossVersion 参数。' 'WARN'
        Write-Log '  或者用 -RollbackOnly 整目录回滚到备份版本。' 'WARN'
        return [pscustomobject]@{ Done = $false; Repaired = 0; Failed = 0; Reason = '版本不一致' }
    }
    if (-not $canCheckVer) {
        Write-Log '已用 -AllowCrossVersion 放行：版本无法确认，按文件内容修复' 'WARN'
    }

    if (-not $Confirm) {
        Write-Log ('【预演】本次将修复 ' + $need.Count + ' 个文件（缺失 ' + @($CompareResult.Missing).Count + '，损坏 ' + @($CompareResult.Corrupt).Count + '）') 'WARN'
        Write-Log '  未加 -Confirm，不写盘。确认无误后加 -Confirm 重跑。' 'WARN'
        return [pscustomobject]@{ Done = $true; Repaired = 0; Failed = 0; Reason = '预演模式' }
    }

    $backupPath = $CompareResult.BackupPath
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeDir = Join-Path $RollbackDir ('repair-' + $stamp)
    # 【v4.12 修复】安全副本目录改为「按需创建」。
    # 原来无条件 New-Item，导致只修复「缺失」文件（原本就没有旧文件可备份）时
    # 也会留下一个空目录 —— 实测 3 个 repair-* 里 2 个是空的，纯垃圾。
    # 现在只有真的复制了旧文件才建目录。
    $safeDirCreated = $false

    $repaired = 0
    $failed = 0
    $failList = @()

    foreach ($item in $need) {
        $rel = $item.Rel
        $src = Join-Path $backupPath $rel
        $dst = Join-Path $InstallDir $rel

        if (-not (Test-Path -LiteralPath $src)) {
            Write-Log ('  跳过（备份里也没有）: ' + $rel) 'WARN'
            $failed++
            $failList += $rel
            continue
        }

        try {
            # 先把现有文件（若有）存到 repair-<时间戳> 便于回退
            if (Test-Path -LiteralPath $dst) {
                if (-not $safeDirCreated) {
                    New-Item -ItemType Directory -Force -Path $safeDir | Out-Null
                    $safeDirCreated = $true
                }
                $safeDst = Join-Path $safeDir $rel
                $safeParent = Split-Path $safeDst -Parent
                if (-not (Test-Path -LiteralPath $safeParent)) { New-Item -ItemType Directory -Force -Path $safeParent | Out-Null }
                try { Copy-Item -LiteralPath $dst -Destination $safeDst -Force -ErrorAction Stop } catch {}
            }
            # 确保目标父目录存在
            $dstParent = Split-Path $dst -Parent
            if (-not (Test-Path -LiteralPath $dstParent)) { New-Item -ItemType Directory -Force -Path $dstParent | Out-Null }
            # 复制
            Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop
            $repaired++
        } catch {
            Write-Log ('  修复失败: ' + $rel + ' -> ' + $_.Exception.Message) 'WARN'
            $failed++
            $failList += $rel
        }
    }

    Write-Log ('按需修复完成: 成功 ' + $repaired + '，失败 ' + $failed) $(if ($failed -eq 0) { 'OK' } else { 'WARN' })
    # 【v4.12 修复】副本位置提示交给上层统一输出，这里不再重复打印
    # （原来函数内 + 上层各打一次，实测日志里同一行出现两次）。
    if (-not $safeDirCreated -and $repaired -gt 0) {
        Write-Log '  本次修复的都是「原本缺失」的文件，没有旧文件需要备份' 'INFO'
    }
    if ($failList.Count -gt 0) {
        Write-Log '  失败清单：' 'WARN'
        foreach ($f in ($failList | Select-Object -First 20)) { Write-Log ('    ' + $f) 'WARN' }
        if ($failList.Count -gt 20) { Write-Log ('    ...还有 ' + ($failList.Count - 20) + ' 个') 'WARN' }
    }

    return [pscustomobject]@{ Done = ($failed -eq 0); Repaired = $repaired; Failed = $failed; Reason = ''; SafeDir = $(if ($safeDirCreated) { $safeDir } else { '' }) }
}

function Exit-WithRestore {
    param([int]$Code, [string]$Reason)
    Write-Log ('中止: ' + $Reason) 'ERROR'
    if ((Get-DshProcesses).Count -eq 0) { Start-Dsh }
    Write-Log ('退出码 ' + $Code)
    Write-Log '############################################################'
    exit $Code
}

# ---------- 【v4.11 新增】按需恢复模式：-Verify / -Repair ----------
# 与 -RollbackOnly（整目录全量覆盖）不同，这里只处理差异文件。

function Remove-DirRobust {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $Path)) { return $true }
    } catch {}
    # 兜底：robocopy 空目录镜像清空，再删空壳
    try {
        $empty = Join-Path $env:TEMP ('_empty_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $empty | Out-Null
        & robocopy $empty $Path /MIR /NFL /NDL /NJH /NJS /R:1 /W:1 2>&1 | Out-Null
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $empty -Recurse -Force -ErrorAction SilentlyContinue
        return (-not (Test-Path -LiteralPath $Path))
    } catch { return $false }
}

if ($Verify -or $Repair) {
    $mode = if ($Repair) { '按需修复' } else { '仅体检' }
    New-Section ($mode + ' / 比对备份与现装')

    # 【v4.13 新增】运行中检测：DSH 跑着的时候，exe / dll / asar 被进程占用，
    # 体检读得到（只读没问题），但 -Repair 写不进去会失败；
    # 更麻烦的是「造损坏」测试里连改都改不了，容易误判成「文件没坏」。
    # 这里提前告知，让用户知道修复可能需要先关 DSH。
    $runCount = @(Get-DshProcesses).Count
    if ($runCount -gt 0) {
        Write-Log ('检测到 DSH 正在运行（' + $runCount + ' 个进程）') 'WARN'
        if ($Repair) {
            Write-Log '  修复时被占用的文件（exe / dll / asar）会复制失败。' 'WARN'
            Write-Log '  建议先关闭 DSH 再跑 -Repair；只体检（-Verify）不受影响。' 'WARN'
        } else {
            Write-Log '  体检是只读操作，不受影响；但若之后要修复，请先关闭 DSH。' 'INFO'
        }
        Write-Log ''
    }

    # 1) 选备份
    # 【v4.11】优先选「版本与现装一致」的最近一份，而不是盲目取最新。
    # 原因：每次升级前都会备份旧版本，所以最新那份的版本往往正好是【升级前】的
    # 旧版本，与现装不符 —— 直接拿它比对会被版本保护拒绝，等于功能失效。
    # 策略：先在所有备份里找版本匹配的，取最近一份；找不到再退回最新一份。
    # 【v4.12 修复】原来的 -like 'app-*' 太宽松，会把 app-xxx.hidden、app-xxx.bak
    # 这类「被改名但前缀仍是 app-」的目录也选进来（实测：隐藏 rc.2 备份后仍选中它）。
    # 改为严格正则：只认 app-<版本>-<yyyyMMdd-HHmmss> 结尾的目录。
    $bkNamePattern = '^app-[0-9A-Za-z.\-]+-\d{8}-\d{6}$'
    $curVer = Get-InstalledVersion
    $allBk = @()
    if (Test-Path $RollbackDir) {
        $allBk = @(Get-ChildItem $RollbackDir -Directory -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -match $bkNamePattern } |
                   Sort-Object LastWriteTime -Descending)
    }
    if ($allBk.Count -eq 0) {
        Write-Log ('没有找到任何备份（目录: ' + $RollbackDir + '）') 'ERROR'
        Write-Log ('  只认形如 app-<版本>-<yyyyMMdd-HHmmss> 的目录；' + $bkNamePattern) 'WARN'
        Write-Log '无法比对。请先正常升级一次以生成备份。' 'WARN'
        Write-Log '############################################################'
        exit 16
    }

    $bk = $null
    if ($curVer) {
        foreach ($cand in $allBk) {
            $cm = Join-Path $cand.FullName '_meta.json'
            $cv = ''
            if (Test-Path -LiteralPath $cm) {
                try { $cv = (Get-Content -LiteralPath $cm -Raw | ConvertFrom-Json).version } catch {}
            }
            if ($cv -and ((Compare-SemVer $cv $curVer) -eq 0)) { $bk = $cand; break }
        }
        if ($bk) {
            Write-Log ('已选版本匹配的备份（现装 ' + $curVer + '）: ' + $bk.Name) 'OK'
        }
    }
    if (-not $bk) {
        $bk = $allBk[0]
        Write-Log ('未找到版本匹配的备份，退回最新一份: ' + $bk.Name) 'WARN'
        Write-Log ('  现装版本 ' + $(if ($curVer) { $curVer } else { '(读不到)' }) + '，此备份版本见下方；不一致时修复会被拒绝。') 'WARN'
        Write-Log ('  如需指定其他备份，把它的目录改名成 app-<版本>-* 或在 -Repair 前先对齐版本。') 'WARN'
    }
    Write-Log ('使用备份: ' + $bk.FullName)
    Write-Log ('备份时间: ' + $bk.LastWriteTime)
    Write-Log ('现装版本: ' + $(if ($curVer) { $curVer } else { '(读不到)' }))
    Write-Log ''

    # 2) 比对
    Write-Log ('开始比对（' + $(if ($SkipHash) { '仅比大小' } else { '大小 + SHA256' }) + '）...')
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $cmp = Compare-BackupTree -BackupPath $bk.FullName -SkipHash:$SkipHash
    $sw.Stop()
    Write-Log ('比对完成，耗时 ' + [math]::Round($sw.Elapsed.TotalSeconds, 1) + 's')

    if (-not $cmp.Ok) {
        Write-Log ('比对失败: ' + $cmp.Reason) 'ERROR'
        Write-Log '############################################################'
        exit 17
    }

    # 3) 输出结果
    Write-Log ''
    Write-Log ('备份版本: ' + $(if ($cmp.BackupVersion) { $cmp.BackupVersion } else { '(未知)' }) + '  现装版本: ' + $(if ($cmp.CurrentVersion) { $cmp.CurrentVersion } else { '(未知)' }))
    # 【v4.12 修复】原来只有「一致 / 不一致」两态，_meta.json 缺失导致版本未知时
    # 也报「版本不一致」，措辞误导（实测 D3 场景）。改为三态提示。
    $canCheckVer = ($cmp.BackupVersion -and $cmp.CurrentVersion)
    if (-not $canCheckVer) {
        Write-Log '版本无法确认（备份缺 _meta.json 或现装 exe 无版本信息）' 'WARN'
        Write-Log '  按需修复默认会拒绝执行，需加 -AllowCrossVersion 才放行。' 'WARN'
    } elseif ($cmp.SameVersion) {
        Write-Log '版本一致，可安全按需修复' 'OK'
    } else {
        Write-Log '版本不一致！按需修复会拒绝执行（除非加 -AllowCrossVersion）' 'WARN'
    }
    Write-Log ''
    Write-Log ('文件总数: ' + $cmp.Total + '   完好: ' + $cmp.Intact + '   缺失: ' + @($cmp.Missing).Count + '   损坏: ' + @($cmp.Corrupt).Count + '   多余: ' + @($cmp.Extra).Count)

    if (@($cmp.Missing).Count -gt 0) {
        Write-Log ''
        Write-Log ('--- 缺失文件（备份有、现装无）共 ' + @($cmp.Missing).Count + ' 个 ---') 'WARN'
        foreach ($m in (@($cmp.Missing) | Select-Object -First 30)) {
            Write-Log ('  [缺失] ' + $m.Rel + '  (' + [math]::Round($m.Size / 1KB, 1) + ' KB)') 'WARN'
        }
        if (@($cmp.Missing).Count -gt 30) { Write-Log ('  ...还有 ' + (@($cmp.Missing).Count - 30) + ' 个') 'WARN' }
    }

    if (@($cmp.Corrupt).Count -gt 0) {
        Write-Log ''
        Write-Log ('--- 损坏文件（内容或大小不一致）共 ' + @($cmp.Corrupt).Count + ' 个 ---') 'WARN'
        foreach ($m in (@($cmp.Corrupt) | Select-Object -First 30)) {
            Write-Log ('  [损坏] ' + $m.Rel + '  (' + $m.Reason + ')') 'WARN'
        }
        if (@($cmp.Corrupt).Count -gt 30) { Write-Log ('  ...还有 ' + (@($cmp.Corrupt).Count - 30) + ' 个') 'WARN' }
    }

    if (@($cmp.Extra).Count -gt 0) {
        Write-Log ''
        Write-Log ('--- 多余文件（现装有、备份无）共 ' + @($cmp.Extra).Count + ' 个（不参与修复，仅供参考）---') 'INFO'
        foreach ($m in (@($cmp.Extra) | Select-Object -First 10)) {
            Write-Log ('  [多余] ' + $m.Rel) 'INFO'
        }
        if (@($cmp.Extra).Count -gt 10) { Write-Log ('  ...还有 ' + (@($cmp.Extra).Count - 10) + ' 个') 'INFO' }
    }

    # 4) 结论
    # 【v4.12 修复·重要】版本不一致时，所谓「缺失/损坏」很可能只是版本差异
    # （新版本多了文件、旧版本没有），不是真损坏。原来直接输出「建议修复」，
    # 措辞误导 —— 实测 rc.1 现装 vs rc.2 备份报 309 个「问题」，全是版本差异。
    # 修复：版本无法确认或不一致时，结论单独措辞，并明确提示不要用 -Repair。
    Write-Log ''
    $needCount = @($cmp.Missing).Count + @($cmp.Corrupt).Count
    $verKnown = ($cmp.BackupVersion -and $cmp.CurrentVersion)
    $verSame = ($verKnown -and $cmp.SameVersion)

    if ($needCount -eq 0) {
        Write-Log ('体检结论: 安装目录完整，无需修复（完好 ' + $cmp.Intact + '/' + $cmp.Total + '）') 'OK'
        Write-Log '############################################################'
        exit 0
    }

    if (-not $verSame) {
        # 版本不一致 / 未知：差异很可能来自版本本身，不能当损坏
        Write-Log ('体检结论: 发现 ' + $needCount + ' 个差异文件，但【版本不一致或无法确认】，无法判断是真损坏还是版本差异') 'WARN'
        Write-Log ''
        # 上面 862 行已打印过版本对比，这里不重复；只在缺版本时补一句原因
        if (-not $verKnown) {
            Write-Log '  原因: 备份缺 _meta.json，或现装 exe 无版本信息。' 'WARN'
        }
        # 注意：日志里不要用 emoji（⚠️ 等），AppendAllText 写 UTF-8 后
        # 在部分终端/编码环境下会显示成 ?? ，用纯文字更稳。
        Write-Log '  [注意] 不建议用 -Repair：跨版本补文件会造成文件混杂、启动异常。' 'WARN'
        Write-Log '  正确做法（二选一）：' 'WARN'
        Write-Log '    a) 用 -RollbackOnly 整目录回滚到备份版本（最稳）' 'WARN'
        Write-Log '    b) 先升级到与备份相同的版本，再跑 -Verify 复查' 'WARN'
        Write-Log ''
        Write-Log '  若已确认要跨版本强补，可加 -AllowCrossVersion。' 'WARN'
        Write-Log '############################################################'
        exit 5
    }

    Write-Log ('体检结论: 发现 ' + $needCount + ' 个问题文件，建议修复') 'WARN'

    # 5) 若只体检，到此为止
    if (-not $Repair) {
        Write-Log ''
        Write-Log '要修复请运行:  -Repair -Confirm' 'WARN'
        Write-Log '（先不加 -Confirm 可预演，看会改哪些文件）' 'WARN'
        Write-Log '############################################################'
        exit 5
    }

    # 6) 执行按需修复
    Write-Log ''
    $rep = Repair-FromBackup -CompareResult $cmp -Confirm:$Confirm -AllowCrossVersion:$AllowCrossVersion

    Write-Log ''
    if ($rep.Done) {
        if ($rep.Reason -eq '预演模式') {
            Write-Log ('预演结束：将修复 ' + $needCount + ' 个文件。加 -Confirm 真正执行。') 'WARN'
            Write-Log '############################################################'
            exit 5
        }
        if ($rep.Repaired -gt 0) {
            Write-Log ('修复成功 ' + $rep.Repaired + ' 个文件') 'OK'
            if ($rep.SafeDir) {
                Write-Log ('  被覆盖的旧文件已存: ' + $rep.SafeDir) 'WARN'
                Write-Log '  如需回退这些文件，从上面目录复制回去即可。' 'WARN'
            } else {
                Write-Log '  本次补的都是原本缺失的文件，无旧文件需要备份。' 'INFO'
            }
        } else {
            Write-Log '没有文件被修复' 'OK'
        }
        Write-Log '############################################################'
        exit 0
    } else {
        Write-Log ('修复未完全成功：成功 ' + $rep.Repaired + '，失败 ' + $rep.Failed + $(if ($rep.Reason) { '，原因: ' + $rep.Reason } else { '' })) 'ERROR'
        Write-Log '############################################################'
        exit 18
    }
}

# =====================================================================


# ---------- 手动回滚模式：直接从最近备份恢复，不升级 ----------
# 【v4.9 修复·致命】这个块原来放在行 169，但 Restore-FromBackup 函数定义在行 367。
# PowerShell 是顺序执行的，此时函数还不存在，调用直接抛「无法将 Restore-FromBackup 项识别为...」，
# 而该异常又被静默吞掉 —— 导致 -RollbackOnly 永远失败（实测 4 秒返回 exit 6，日志零线索）。
# 修复：整块移到所有函数定义之后。
# ---------- 手动回滚模式：直接从最近备份恢复，不升级 ----------
if ($RollbackOnly) {
    New-Section '手动回滚模式 / 从最近备份恢复'
    $latest = $null
    if (Test-Path $RollbackDir) {
        $latest = Get-ChildItem $RollbackDir -Directory -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    if (-not $latest) {
        Write-Log ('没有找到任何备份（目录: ' + $RollbackDir + '）') 'ERROR'
        Write-Log '无法回滚。如果你的 DSH 还能用，说明不需要回滚。' 'WARN'
        Write-Log '############################################################'
        exit 16
    }
    Write-Log ('使用最近备份: ' + $latest.FullName)
    Write-Log ('备份时间: ' + $latest.LastWriteTime)
    $metaFile = Join-Path $latest.FullName '_meta.json'
    if (Test-Path $metaFile) {
        try { $m = Get-Content $metaFile -Raw | ConvertFrom-Json; Write-Log ('备份版本: ' + $m.version + '  文件数: ' + $m.fileCount) } catch {}
    }
    $okRollback = Restore-FromBackup -BackupPath $latest.FullName
    if ($okRollback) {
        Write-Log ('回滚成功，当前版本 ' + (Get-InstalledVersion)) 'OK'
        Write-Log '############################################################'
        Write-Host ''
        Write-Host '已恢复到升级前版本，可以正常使用。' -ForegroundColor Green
        exit 0
    }
    Write-Log '回滚失败，请按上面打印的手动步骤操作' 'ERROR'
    Write-Log '############################################################'
    exit 6
}


# 【v4.9 修复·致命】Test-DshWebAlive 原来定义在文件末尾（行 1081），但 Restore-FromBackup
# 函数内（行 443）就会调用它。PowerShell 顺序执行，此时函数不存在，回滚后的 Web 探测
# 必然失败。修复：整个函数移到所有函数定义区。

# ===================== 阶段1：确定目标版本 =====================
New-Section '阶段1 / 确定目标版本'

$current = Get-InstalledVersion
Write-Log ('当前已安装版本: ' + $(if ($current) { $current } else { '(未知)' }))

$target = $null

# 1.1 查官方 feed
try {
    Write-Log ('查询 feed: ' + $FeedUrl)
    $resp = Invoke-WebRequest -Uri $FeedUrl -UseBasicParsing -TimeoutSec 30 -Headers @{ 'User-Agent' = 'electron-updater'; 'Cache-Control' = 'no-cache' }
    # 【v4.13 修复·致命】PowerShell 5.1 的 Invoke-WebRequest 在部分环境下
    # （实测虚拟机 Win11 + PS 5.1.26100）.Content 返回的是 System.Byte[] 而不是字符串，
    # 直接对它 -match 永远失败 —— 表现为「feed 解析失败（无 version）」，
    # 但同一个 URL 用 curl 拿到的内容完全正常。这会让自动升级在 feed 有新版时也失败。
    # 修复：先判断类型，byte[] 就先转 UTF-8 字符串再解析。
    $yml = $resp.Content
    if ($yml -is [byte[]]) {
        try { $yml = [System.Text.Encoding]::UTF8.GetString($yml) } catch { $yml = '' }
    }
    if ($yml -isnot [string]) { $yml = [string]$yml }
    # 兜底：若 Content 为空但 RawContent 有值，用 RawContent
    if ([string]::IsNullOrWhiteSpace($yml) -and $resp.RawContent) {
        $yml = [string]$resp.RawContent
    }
    if ($yml -match '(?m)^version:\s*([0-9][^\s]*)') {
        $fv = $Matches[1].Trim("'").Trim('"')
        $furl = $null; $fsha = $null; $fsize = $null
        if ($yml -match "(?m)^\s*path:\s*>?-?\s*[\r\n]*\s*(\S+)") { $furl = $Matches[1] }
        if ($yml -match "(?m)^sha512:\s*>?-?\s*[\r\n]*\s*(\S+)") { $fsha = $Matches[1] }
        if ($yml -match "(?m)^\s*size:\s*(\d+)") { $fsize = [long]$Matches[1] }
        Write-Log ('feed 版本: ' + $fv)
        if ($furl) {
            $target = @{ Version = $fv; Url = $furl; Sha512 = $fsha; Size = $fsize; Source = 'feed' }
        } else {
            Write-Log 'feed 中未解析到下载地址' 'WARN'
        }
    } else {
        # 【v4.13】诊断信息更具体，便于排查（原来只说「无 version」）
        Write-Log ('feed 解析失败（内容里没有 version 行）') 'WARN'
        Write-Log ('  内容长度 = ' + $yml.Length + ' 字节') 'WARN'
        if ($yml.Length -gt 0) {
            $head = $yml.Substring(0, [Math]::Min(200, $yml.Length)) -replace "`r?`n", ' | '
            Write-Log ('  内容开头: ' + $head) 'WARN'
        } else {
            Write-Log '  内容为空（网络被拦截或返回空响应）' 'WARN'
        }
    }
} catch {
    Write-Log ('feed 查询失败: ' + $_.Exception.Message) 'WARN'
}

# 1.2 主动探测更高版本（feed 滞后时）
$needProbe = $ProbeLatest
if (-not $target) { $needProbe = $true }
if ($target -and $current -and ((Compare-SemVer $target.Version $current) -le 0)) { $needProbe = $true }

if ($needProbe) {
    Write-Log '启用版本探测（应对 feed 滞后）...'
    $base = if ($current) { $current } else { '0.2.2-rc.1' }
    $core = $base
    if ($base -match '^(\d+\.\d+\.\d+)') { $core = $Matches[1] }
    $cands = @($core)
    for ($i = 1; $i -le 8; $i++) { $cands += ($core + '-rc.' + $i) }
    for ($i = 1; $i -le 4; $i++) { $cands += ($core + '-alpha.' + $i) }

    $best = $null
    foreach ($v in $cands) {
        if ($current -and ((Compare-SemVer $v $current) -le 0)) { continue }
        $u = $BinBase + 'deepseek-harness-' + $v + '-win-x64.exe'
        try {
            $hr = Invoke-WebRequest -Uri $u -Method Head -UseBasicParsing -TimeoutSec 12 -Headers @{ 'User-Agent' = 'Mozilla/5.0' }
            if ($hr.StatusCode -eq 200) {
                if (-not $best -or ((Compare-SemVer $v $best.Version) -gt 0)) {
                    $best = @{ Version = $v; Url = $u; Sha512 = $null; Size = $null; Source = 'probe' }
                    Write-Log ('  探测到可用版本: ' + $v) 'OK'
                }
            }
        } catch {}
    }
    if ($best) {
        if (-not $target -or ((Compare-SemVer $best.Version $target.Version) -gt 0)) {
            Write-Log ('探测版本 ' + $best.Version + ' 高于 feed，采用探测结果') 'OK'
            $target = $best
        }
    }
}

if (-not $target) { Exit-WithRestore 12 '无法确定目标版本' }

Write-Log ('目标版本: ' + $target.Version + '  来源: ' + $target.Source) 'OK'
Write-Log ('下载地址: ' + $target.Url)
if ($target.Sha512) { Write-Log ('期望 SHA512: ' + $target.Sha512.Substring(0, [Math]::Min(24, $target.Sha512.Length)) + '...') }

$cmp = if ($current) { Compare-SemVer $target.Version $current } else { 1 }
Write-Log ('版本比较: 目标 ' + $target.Version + ' vs 当前 ' + $current + ' => ' + $cmp)

if (-not $Force -and $cmp -le 0) {
    Write-Log ''
    Write-Log ('已是最新版本（当前 ' + $current + '），无需升级。要强制重装请加 -Force') 'OK'
    Write-Log '############################################################'
    exit 0
}
if ($cmp -lt 0 -and $Force) { Write-Log '强制模式：允许降级' 'WARN' }

# 1.3 预检
Write-Log ''
if (-not (Test-Path $InstallDir)) { Exit-WithRestore 10 '安装目录不存在' }
$dirSizeMB = [math]::Round(((Get-ChildItem $InstallDir -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB), 1)
Write-Log ('安装目录体积: ' + $dirSizeMB + ' MB')
# 需要：回滚备份(1x) + 安装器自带备份(1x) + 安装包(~300MB) + 余量
$needMB = [math]::Ceiling($dirSizeMB * 2) + 800
$needGB = [math]::Round($needMB / 1024, 1)
if ($needGB -lt $MinFreeGB) { $needGB = $MinFreeGB }
try {
    $freeGB = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
    Write-Log ('C: 剩余空间: ' + $freeGB + ' GB（本次升级预计需要 ' + $needGB + ' GB）')
    if ($freeGB -lt $needGB) { Exit-WithRestore 11 ('磁盘空间不足：需要约 ' + $needGB + ' GB（含回滚备份），当前仅 ' + $freeGB + ' GB') }
} catch {}
$procs = Get-DshProcesses
Write-Log ('当前 DSH 进程数: ' + $procs.Count)

# 【v4 新增】TEMP 预检清理。
# 背景：本机实测安装器报 extract-failure（7-Zip 退出码 2 Cannot open output file），
# 根因之一是 TEMP 里堆了 5000+ 条目，解压 7892 个文件到临时目录时资源吃紧。
# 这里只清 7 天前、且明确属于旧解压残留的条目，不动近期文件。
try {
    $tempRoot = $env:TEMP
    $tempCount = @(Get-ChildItem $tempRoot -ErrorAction SilentlyContinue).Count
    Write-Log ('TEMP 条目数: ' + $tempCount)
    if ($tempCount -gt 1500) {
        Write-Log ('TEMP 条目偏多（' + $tempCount + '），清理 7 天前的旧残留以降低解压失败风险') 'WARN'
        $cutoff = (Get-Date).AddDays(-7)
        $stale = @(Get-ChildItem $tempRoot -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cutoff })
        $rm = 0
        foreach ($s in $stale) {
            try { Remove-Item $s.FullName -Recurse -Force -ErrorAction Stop; $rm++ } catch {}
        }
        Write-Log ('已清理 TEMP 旧条目: ' + $rm + ' 个，现有 ' + @(Get-ChildItem $tempRoot -ErrorAction SilentlyContinue).Count) 'OK'
    }
    # 顺手清掉安装器上次失败留下的 nsu*.tmp 解压残留
    $nsu = @(Get-ChildItem $tempRoot -Directory -Filter 'nsu*.tmp' -ErrorAction SilentlyContinue)
    foreach ($n in $nsu) {
        try { Remove-Item $n.FullName -Recurse -Force -ErrorAction Stop; Write-Log ('已清解压残留: ' + $n.Name) 'OK' } catch {}
    }
} catch { Write-Log ('TEMP 清理异常（忽略）: ' + $_.Exception.Message) 'WARN' }

if ($DryRun) {
    New-Section 'DryRun 结束（未下载、未安装）'
    Write-Log ('将升级: ' + $current + ' -> ' + $target.Version) 'OK'
    Write-Log '############################################################'
    exit 0
}

# ===================== 阶段2：下载 =====================
New-Section '阶段2 / 下载安装包'

$fileName = 'deepseek-harness-' + $target.Version + '-win-x64.exe'
$localPath = $null

if ($InstallerPath -and (Test-Path $InstallerPath)) {
    $localPath = (Resolve-Path $InstallerPath).Path
    Write-Log ('使用指定安装包: ' + $localPath) 'OK'
} else {
    New-Item -ItemType Directory -Force -Path $DlDir | Out-Null
    $localPath = Join-Path $DlDir $fileName
    $needDownload = $true

    if (Test-Path $localPath) {
        $existSize = (Get-Item $localPath).Length
        if ($target.Size -and ($existSize -eq $target.Size)) {
            Write-Log '已存在完整文件（大小一致），跳过下载' 'OK'
            $needDownload = $false
        } elseif ($target.Size -and ($existSize -gt $target.Size)) {
            Write-Log '本地文件偏大，删除重下'
            Remove-Item $localPath -Force -ErrorAction SilentlyContinue
        } else {
            Write-Log ('存在部分文件 ' + [math]::Round($existSize / 1MB, 1) + ' MB，将断点续传')
        }
    }

    if ($needDownload) {
        $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
        $ok = $false
        for ($try = 1; $try -le $MaxDownloadTries; $try++) {
            Write-Log ('--- 下载尝试 ' + $try + '/' + $MaxDownloadTries + ' ---')
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                if (Test-Path $curl) {
                    $curlArgs = @('-L', '--fail', '--retry', '3', '--retry-delay', '2',
                                  '--connect-timeout', '30', '-C', '-', '-o', $localPath, $target.Url)
                    $p = Start-Process -FilePath $curl -ArgumentList $curlArgs -PassThru -WindowStyle Hidden -ErrorAction Stop
                    $lastReport = 0
                    while (-not $p.HasExited) {
                        Start-Sleep -Seconds 3
                        if (Test-Path $localPath) {
                            $mb = [math]::Round((Get-Item $localPath).Length / 1MB, 1)
                            if (($mb - $lastReport) -ge 20) {
                                Write-Log ('    已下载 ' + $mb + ' MB ...')
                                $lastReport = $mb
                            }
                        }
                        if ($sw.Elapsed.TotalMinutes -gt 30) { try { $p.Kill() } catch {}; Write-Log '下载超 30 分钟，强制结束' 'WARN'; break }
                    }
                    $code = $p.ExitCode
                    Write-Log ('curl 退出码 ' + $code + '，耗时 ' + [math]::Round($sw.Elapsed.TotalSeconds) + 's')
                    if ($code -eq 0) { $ok = $true }
                } else {
                    Invoke-WebRequest -Uri $target.Url -OutFile $localPath -UseBasicParsing -TimeoutSec 1800
                    $ok = $true
                }
            } catch {
                Write-Log ('下载异常: ' + $_.Exception.Message) 'WARN'
            }
            $sw.Stop()
            if ($ok) {
                $sz = (Get-Item $localPath).Length
                if ($target.Size -and ($sz -ne $target.Size)) {
                    Write-Log ('大小不符（实际 ' + $sz + ' / 期望 ' + $target.Size + '），继续续传') 'WARN'
                    $ok = $false
                    Start-Sleep -Seconds 3
                    continue
                }
                break
            }
            Start-Sleep -Seconds 3
        }
        if (-not $ok) { Exit-WithRestore 13 ('下载失败（已重试 ' + $MaxDownloadTries + ' 次）') }
        Write-Log ('下载完成: ' + [math]::Round((Get-Item $localPath).Length / 1MB, 1) + ' MB') 'OK'
    }
}

# 2.2 SHA512 校验
if ($target.Sha512) {
    try {
        Write-Log '校验 SHA512...'
        $actual = (Get-FileHash -LiteralPath $localPath -Algorithm SHA512).Hash.ToUpper()
        $expectedBytes = [Convert]::FromBase64String($target.Sha512)
        $expected = (($expectedBytes | ForEach-Object { $_.ToString('X2') }) -join '')
        if ($actual -eq $expected) {
            Write-Log 'SHA512 校验通过' 'OK'
        } else {
            Write-Log ('SHA512 不匹配！期望 ' + $expected.Substring(0, 24) + '... 实际 ' + $actual.Substring(0, 24) + '...') 'ERROR'
            Remove-Item $localPath -Force -ErrorAction SilentlyContinue
            Exit-WithRestore 14 'SHA512 校验失败（安装包损坏，已删除，请重跑）'
        }
    } catch {
        Write-Log ('SHA512 校验异常: ' + $_.Exception.Message) 'WARN'
    }
} else {
    Write-Log '探测模式无 SHA512，改用签名校验'
}

# 2.3 签名
try {
    $sig = Get-AuthenticodeSignature $localPath
    Write-Log ('数字签名: ' + $sig.Status)
    if ($sig.SignerCertificate) { Write-Log ('签发者: ' + $sig.SignerCertificate.Subject.Split(',')[0]) }
    if ($sig.Status -ne 'Valid') {
        Write-Log '签名无效！请确认来源，5 秒后继续' 'WARN'
        Start-Sleep -Seconds 5
    }
} catch { Write-Log '签名检查失败（忽略）' 'WARN' }

# ===================== 阶段3：清理 =====================
New-Section '阶段3 / 清理进程与干扰项'

# 【v4 新增·致命修复】先判断自己是不是 DSH 的子进程；是则改用独立计划任务继续。
# 只有真正要杀进程时才需要，DryRun / 已是最新 都已经在更早处 exit 了。
if (-not $env:DSH_UPGRADE_DETACHED) {
    if (Test-InDshTree -ProcessId $PID) {
        $argsForChild = ''
        if ($Force) { $argsForChild += ' -Force' }
        if ($Silent) { $argsForChild += ' -Silent' }
        if ($NoStart) { $argsForChild += ' -NoStart' }
        if ($ProbeLatest) { $argsForChild += ' -ProbeLatest' }
        $childScript = $PSCommandPath
        if (-not $childScript) { $childScript = $MyInvocation.MyCommand.Path }
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $taskName = 'DSH-AutoUpgrade-Elevated'
        $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $childScript + '" -DetachedChild' + $argsForChild
        $act = '"' + $psExe + '" ' + $argLine

        Write-Log '【关键保护】检测到本脚本运行在 DSH 进程树内。' 'WARN'
        Write-Log '  若此处置强杀 DSH，本脚本会被连带杀死，升级中断在半途、DSH 停在半装状态。' 'WARN'
        Write-Log '  → 自动改用「独立计划任务」执行安装，彻底脱离 DSH 进程树。' 'OK'

        & schtasks /Delete /TN $taskName /F 2>&1 | Out-Null
        & schtasks /Create /TN $taskName /TR $act /SC ONCE /ST 23:59 /RU "$env:USERNAME" /RL HIGHEST /F 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            # 【v4.1】脱离前先释放本进程持有的互斥锁，否则子进程拿不到锁会直接退出(21)。
            if ($script:UpgradeMutex) {
                try { $script:UpgradeMutex.ReleaseMutex() } catch {}
                try { $script:UpgradeMutex.Dispose() } catch {}
                $script:UpgradeMutex = $null
                Remove-Item Env:\DSH_UPGRADE_MUTEX_HELD -ErrorAction SilentlyContinue
                Write-Log '已释放单实例锁，交给独立子进程'
            }
            Write-Log ('已创建独立任务: ' + $taskName)
            & schtasks /Run /TN $taskName 2>&1 | Out-Null
            Write-Log '已在独立会话中开始升级，本窗口保持观察（不会自己动手杀 DSH）...'
            Write-Log ('升级进度日志: ' + $LogFile)

            $t0 = Get-Date
            $seenRunning = $false
            while (((Get-Date) - $t0).TotalMinutes -lt 25) {
                Start-Sleep -Seconds 4
                $q = & schtasks /Query /TN $taskName /FO LIST /V 2>&1 | Out-String
                if ($q -match 'Status:\s*Running') { $seenRunning = $true; continue }
                if ($seenRunning -and $q -notmatch 'Status:\s*Running') { break }
            }
            $res = & schtasks /Query /TN $taskName /FO LIST /V 2>&1 | Out-String
            $lastResult = 'unknown'
            if ($res -match 'Last Result:\s*(-?\d+)') { $lastResult = $Matches[1] }
            & schtasks /Delete /TN $taskName /F 2>&1 | Out-Null

            Write-Log ('独立升级任务已结束，LastResult=' + $lastResult)
            New-Section '汇总（由独立任务执行）'
            foreach ($pd in $ProtectedData) {
                if (Test-Path $pd) { Write-Log ('  数据完好: ' + $pd) 'OK' }
                else { Write-Log ('  不存在(可能原本就没有): ' + $pd) 'WARN' }
            }
            Write-Log '############################################################'
            Write-Host ''
            Write-Host '升级已由独立任务执行完毕。请查看上方日志与 DSH 是否正常。' -ForegroundColor Green
            exit $(if ($lastResult -eq '0') { 0 } else { 5 })
        }
        Write-Log '创建独立任务失败，退化为原地执行（有中断风险）' 'ERROR'
    }
}

foreach ($taskName in @('DSH-RESTART')) {
    try {
        $t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($t) { Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue; Write-Log ('已停计划任务: ' + $taskName) 'OK' }
    } catch {}
}

try {
    $helpers = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'dsh-launch|restart-body|restart-dsh|restart-and-measure' })
    foreach ($hp in $helpers) {
        try { Stop-Process -Id $hp.ProcessId -Force -ErrorAction Stop; Write-Log ('已结束启动器 PID=' + $hp.ProcessId) 'OK' } catch {}
    }
} catch {}

$round = 0
do {
    $round++
    $procList = Get-DshProcesses
    if ($procList.Count -eq 0) { break }
    Write-Log ('第 ' + $round + ' 轮结束进程: ' + $procList.Count + ' 个')
    foreach ($p in $procList) { try { $p.Kill() } catch {} }
    Start-Sleep -Seconds 2
} while ($round -lt $MaxKillRounds)

$left = Get-DshProcesses
Write-Log ('清理后剩余: ' + $left.Count)
if ($left.Count -gt 0) {
    foreach ($p in $left) { Write-Log ('  残留 PID=' + $p.Id) 'ERROR' }
    Exit-WithRestore 20 '进程无法结束，请手动结束后重试'
}
Write-Log '所有 DSH 进程已结束' 'OK'
Start-Sleep -Seconds 2

# ===================== 阶段3.5：备份（回滚基础） =====================
New-Section '阶段3.5 / 升级前备份（回滚用）'

Write-Log '数据保护：本次升级【不会】触碰以下路径（只备份程序目录 + 3 个配置文件）'
foreach ($pd in $ProtectedData) { Write-Log ('  受保护: ' + $pd) }

$backupPath = Backup-Installation -VersionTag $current
if (-not $backupPath) {
    Exit-WithRestore 15 '升级前备份失败，为避免不可回滚已中止（这是保护措施）'
}
Write-Log ('备份就绪，可用于回滚: ' + $backupPath) 'OK'
Write-Log '--- 备份阶段完成，继续升级 ---'
Start-Sleep -Seconds 1

# ===================== 阶段4：门禁 =====================
New-Section '阶段4 / 验证安装目录可改名'

$parent = Split-Path $InstallDir -Parent
$leaf = Split-Path $InstallDir -Leaf
$probeName = $leaf + '.upgrade-probe'
$probePath = Join-Path $parent $probeName

$renameOk = $false
for ($try = 1; $try -le $MaxRenameTries; $try++) {
    try {
        if (Test-Path $probePath) { Remove-Item $probePath -Recurse -Force -ErrorAction SilentlyContinue }
        Rename-Item -LiteralPath $InstallDir -NewName $probeName -ErrorAction Stop
        Rename-Item -LiteralPath $probePath -NewName $leaf -ErrorAction Stop
        $renameOk = $true
        Write-Log ('第 ' + $try + ' 次验证: 可改名') 'OK'
        break
    } catch {
        Write-Log ('第 ' + $try + ' 次验证失败: ' + $_.Exception.Message) 'WARN'
        if ($try -lt $MaxRenameTries) {
            Start-Sleep -Seconds 3
            Get-DshProcesses | ForEach-Object { try { $_.Kill() } catch {} }
            Start-Sleep -Seconds 1
        }
    }
}

if (-not $renameOk) {
    Write-Log '目录仍被占用，列出可能占用者：' 'ERROR'
    try {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | ForEach-Object {
            $hit = ($_.ExecutablePath -and ($_.ExecutablePath -like ($InstallDir + '*'))) -or
                   ($_.CommandLine -and ($_.CommandLine -like ('*' + $InstallDir + '*')))
            if ($hit) { Write-Log ('  PID=' + $_.ProcessId + ' ' + $_.Name) 'ERROR' }
        }
    } catch {}
    Exit-WithRestore 30 '安装目录被占用（关闭资源管理器/杀软，或重启后立刻运行）'
}

# 【v4 修复】原来只清 .old-*，但本机实测安装器还会留下 .new-*（解压失败时）
# 和 .broken-*（回滚时留的证据目录），这些每个都占 1GB+，堆几个就吃满空间。
# 【v4.1 修正】.broken-* 是回滚失败时的故障现场，全删会丢掉排错依据：
# 改为「保留最近 1 个 .broken-，其余清理」，兼顾空间与可诊断性。
# 【v4.10 修复】残留目录里可能有文件名损坏（实测 4669 个文件里有一个路径
# 含非法名 "pagepanenoselmaster.xml"，Remove-Item 报「未能找到路径的一部分」
# 直接失败），导致 498 MB 垃圾永远删不掉。
# 兜底方案：用 robocopy 拿一个空目录 /MIR 镜像过去（会把目标清空），
# 再删空壳。这是 Windows 上删「删不掉的目录」的标准做法。

$stalePatterns = @('.old-', '.new-', '.upgrade-probe')
$cleanedAny = 0
foreach ($pat in $stalePatterns) {
    $staleDirs = @(Get-ChildItem $parent -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match ('^' + [regex]::Escape($leaf) + [regex]::Escape($pat)) })
    foreach ($od in $staleDirs) {
        $szMB = [math]::Round(((Get-ChildItem $od.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB), 1)
        if (Remove-DirRobust -Path $od.FullName) {
            Write-Log ('已删残留: ' + $od.Name + ' (' + $szMB + ' MB)') 'OK'
            $cleanedAny++
        } else {
            Write-Log ('残留删除失败（已尝试 robocopy 兜底）: ' + $od.Name + ' (' + $szMB + ' MB)') 'WARN'
        }
    }
}
# .broken-* 单独处理：留最近 1 个作故障现场
$brokenDirs = @(Get-ChildItem $parent -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match ('^' + [regex]::Escape($leaf) + [regex]::Escape('.broken-')) } |
    Sort-Object LastWriteTime -Descending)
if ($brokenDirs.Count -gt 0) {
    Write-Log ('发现 ' + $brokenDirs.Count + ' 个 .broken- 故障现场，保留最近 1 个用于排错:') 'WARN'
    Write-Log ('  保留: ' + $brokenDirs[0].Name)
    foreach ($bd in ($brokenDirs | Select-Object -Skip 1)) {
        $szMB = [math]::Round(((Get-ChildItem $bd.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB), 1)
        if (Remove-DirRobust -Path $bd.FullName) {
            Write-Log ('  已删旧现场: ' + $bd.Name + ' (' + $szMB + ' MB)') 'OK'
            $cleanedAny++
        } else {
            Write-Log ('  删除失败（已尝试 robocopy 兜底）: ' + $bd.Name) 'WARN'
        }
    }
}
if ($cleanedAny -eq 0) { Write-Log '无旧残留需要清理' }

# ===================== 阶段5：安装 =====================
New-Section '阶段5 / 安装'

$swInst = [System.Diagnostics.Stopwatch]::StartNew()
$installOk = $false
for ($it = 1; $it -le 2; $it++) {
    Write-Log ('--- 安装尝试 ' + $it + '/2 ---')
    try {
        $proc = if ($Silent) { Start-Process -FilePath $localPath -ArgumentList '/S' -PassThru -ErrorAction Stop }
                else { Start-Process -FilePath $localPath -PassThru -ErrorAction Stop }
        Write-Log ('安装器 PID=' + $proc.Id + '，等待退出（上限 ' + $InstallerTimeoutMin + ' 分钟）')
        $finished = $proc.WaitForExit($InstallerTimeoutMin * 60 * 1000)
        if ($finished) {
            Write-Log ('安装器退出码: ' + $proc.ExitCode + '，耗时 ' + [math]::Round($swInst.Elapsed.TotalSeconds) + 's')
            if ($proc.ExitCode -eq 0) { $installOk = $true }
        } else {
            Write-Log '安装器超时' 'WARN'
            # 【v4.6 修复·严重】超时后必须强制清理，否则半装目录会让后续重试继续失败。
            # 实测（2026-11-13 虚拟机）：第 2 次安装 180 秒超时后未清理任何东西，
            # 安装目录停在半损坏状态，最终版本被降级到 rc.1。
            Write-Log '  强制结束安装器进程并清理半装残留...' 'WARN'
            # 1) 杀掉本次安装器进程
            try {
                if ($proc -and -not $proc.HasExited) { $proc.Kill() }
            } catch {}
            # 2) 杀掉同目录可能残留的安装器进程（NSIS 常会留下子进程）
            try {
                $instName = [IO.Path]::GetFileNameWithoutExtension($localPath)
                Get-Process -ErrorAction SilentlyContinue |
                    Where-Object { $_.ProcessName -eq $instName } |
                    ForEach-Object {
                        Write-Log ('  结束残留安装进程 PID=' + $_.Id) 'WARN'
                        try { $_.Kill() } catch {}
                    }
            } catch {}
            Start-Sleep -Seconds 3
            # 3) 清理本次产生的 .new-/.tmp- 残留（绝不碰正式安装目录）
            foreach ($pat in @('.new-', '.tmp-', '.upgrade-probe')) {
                @(Get-ChildItem $parent -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match ('^' + [regex]::Escape($leaf) + [regex]::Escape($pat)) }) |
                    ForEach-Object {
                        try { Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop; Write-Log ('  已清理残留: ' + $_.Name) 'WARN' } catch {}
                    }
            }
            # 4) 检查 exe 是否还在，判断目录是否被打坏
            if (-not (Test-Path (Join-Path $InstallDir 'DeepSeek Harness.exe'))) {
                Write-Log '  严重: 安装目录里 exe 已丢失，继续重试风险高' 'ERROR'
            }
            $swInst.Restart()
        }
    } catch {
        Write-Log ('安装器启动失败: ' + $_.Exception.Message) 'ERROR'
    }
    Start-Sleep -Seconds 3
    $vNow = Get-InstalledVersion
    # 【v4.9 修复·致命】$target 是【对象】（含 Version/Source/Url 属性），不是字符串。
    # v4.8 误写成 Compare-SemVer $vNow $target，传进去的对象被 Split-SemVer 当成
    # 空版本处理 => 永远返回 -1 => 版本明明已达目标却判「未达到」，白跑第二次安装。
    # 修复：所有比较一律用 $target.Version。
    $reachedTarget = ($installOk -and $vNow -and $target -and ((Compare-SemVer $vNow $target.Version) -eq 0))
    if ($reachedTarget) {
        if ((Compare-SemVer $target.Version $current) -gt 0) {
            Write-Log ('版本已变为 ' + $vNow) 'OK'
        } elseif ((Compare-SemVer $target.Version $current) -eq 0) {
            Write-Log ('强制重装完成，版本保持 ' + $vNow + '（这是预期结果）') 'OK'
        } else {
            Write-Log ('强制降级完成: ' + $current + ' -> ' + $vNow + '（-Force 允许降级，这是预期结果）') 'OK'
        }
        break
    }
    if ($it -lt 2) {
        Write-Log ('版本未达到目标（当前 ' + $(if($vNow){$vNow}else{'未知'}) + '，目标 ' + $target.Version + '），清理后重试一次...') 'WARN'
        Get-DshProcesses | ForEach-Object { try { $_.Kill() } catch {} }
        Start-Sleep -Seconds 4
        @(Get-ChildItem $parent -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match ('^' + [regex]::Escape($leaf) + '\.old-') }) |
            ForEach-Object { try { Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop } catch {} }
    }
}

# ===================== 阶段6：核验 =====================
New-Section '阶段6 / 核验'

# 【v4 新增】记录安装完成时刻，供阶段7 健康检查只统计"升级之后"的崩溃。
$installFinishedAt = Get-Date
$pass = $true
$verAfter = Get-InstalledVersion
Write-Log ('升级前: ' + $current)
Write-Log ('升级后: ' + $verAfter)

if (-not $verAfter) { Write-Log 'exe 不存在' 'ERROR'; $pass = $false }
elseif ($target -and ((Compare-SemVer $verAfter $target.Version) -eq 0)) {
    # 【v4.9 修复】核验标准改为「装完后版本 == $target.Version」，
    # 覆盖升级 / 同版本重装 / -Force 降级三种情况。
    if ((Compare-SemVer $target.Version $current) -gt 0) {
        Write-Log ('版本变化: ' + $current + ' -> ' + $verAfter) 'OK'
    } elseif ((Compare-SemVer $target.Version $current) -eq 0) {
        Write-Log ('强制重装完成：版本保持 ' + $verAfter + '（预期结果，非失败）') 'OK'
    } else {
        Write-Log ('强制降级完成: ' + $current + ' -> ' + $verAfter + '（-Force 允许降级，预期结果）') 'OK'
    }
}
elseif ($current -and ($verAfter -eq $current)) {
    Write-Log ('版本未达到目标：仍是 ' + $verAfter + '，目标 ' + $target.Version) 'ERROR'; $pass = $false
}
else { Write-Log ('版本变化但未达目标: ' + $current + ' -> ' + $verAfter + '，目标 ' + $target.Version) 'WARN' }

$asar = Join-Path $InstallDir 'resources\app.asar'
if (Test-Path $asar) { Write-Log ('app.asar: ' + [math]::Round((Get-Item $asar).Length / 1MB, 1) + ' MB') 'OK' }
else { Write-Log 'app.asar 缺失' 'ERROR'; $pass = $false }

try {
    $logDir = Join-Path $env:APPDATA '@deepseek-ai\dsh-desktop\logs'
    $cut = (Get-Date).AddMinutes(-15)
    $crashes = @(Get-ChildItem $logDir -Filter 'crash-*' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $cut })
    if ($crashes.Count -eq 0) { Write-Log '无新崩溃' 'OK' }
    else { foreach ($c in $crashes) { Write-Log ('崩溃日志: ' + $c.Name) 'WARN' } }
} catch {}

if (Test-Path (Join-Path $ProfileDir 'package.json')) {
    try {
        $pj = Get-Content (Join-Path $ProfileDir 'package.json') -Raw | ConvertFrom-Json
        Write-Log ('profile 保留: bundles=' + $pj.dsh.profile.bundles.Count) 'OK'
    } catch {}
}

try {
    $old = @(Get-ChildItem $DlDir -Filter '*.exe' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $localPath } | Sort-Object LastWriteTime -Descending)
    foreach ($o in $old) { Remove-Item $o.FullName -Force -ErrorAction SilentlyContinue; Write-Log ('清理旧下载: ' + $o.Name) }
} catch {}

# ===================== 阶段7：启动与健康检查 =====================
New-Section '阶段7 / 启动与健康检查'

Start-Dsh
$winElapsed = Wait-DshWindow -TimeoutSec 90
$healthy = $false

# 【v4.4 新增·虚拟机/无GPU环境修复】Web 服务健康探测
# 背景：2026-11-13 在 Hyper-V 虚拟机（Microsoft Hyper-V Video 虚拟显卡）实测发现：
#   Electron 在无真实 GPU 的环境下会自动降级为「Web 模式」运行 —— 服务正常、
#   能返回完整界面 HTML，但【不创建任何窗口】（EnumWindows 也查不到）。
#   此时 $winElapsed 永远是 -1，旧逻辑会误判为「启动失败」并触发自动回滚，
#   把一次成功的升级回滚掉。
# 修复：窗口没出来时，再查 DSH 是否以 Web 模式在跑（主进程监听本地端口且可访问），
#       若能访问则同样判定为健康。

if ($winElapsed -ge 0) {
    Write-Log ('主窗口已出现 ' + $winElapsed + 's') 'OK'
    # 检查致命崩溃（main / host）
    # 【v4 修复】原来只要 3 分钟内有 crash-*-main/host.log 就回滚，
    # 但本机实测存在「窗口已正常出现、却留下历史 host 崩溃记录」的情况（如插件报
    # CODEX_AUTH_REQUIRED 后 host 重启过一次）。窗口都起来了还被回滚，等于白升。
    # 改为：先看窗口，再只看「本次升级之后新产生」的崩溃，且要求是致命类型。
    $fatal = @()
    try {
        $logDir = Join-Path $env:APPDATA '@deepseek-ai\dsh-desktop\logs'
        $cut = $installFinishedAt
        if (Test-Path $logDir) {
            $fatal += @(Get-ChildItem $logDir -Filter 'crash-*-main.log' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $cut })
            $fatal += @(Get-ChildItem $logDir -Filter 'crash-*-host.log' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $cut })
        }
    } catch {}
    if ($fatal.Count -eq 0) {
        $healthy = $true
        Write-Log '健康检查通过（窗口正常 + 升级后无致命崩溃）' 'OK'
    } else {
        # 窗口已出现却仍有致命崩溃：再给 15 秒观察，确认 DSH 没有反复重启
        Write-Log ('检测到升级后致命崩溃日志 ' + $fatal.Count + ' 个，等待 15 秒确认是否反复崩溃...') 'WARN'
        Start-Sleep -Seconds 15
        $stillAlive = @(Get-DshProcesses | Where-Object { $_.MainWindowHandle -ne 0 })
        if ($stillAlive.Count -gt 0) {
            $healthy = $true
            Write-Log '窗口仍稳定存在，判定为可接受（崩溃发生在启动早期，已自恢复）' 'WARN'
            foreach ($f in $fatal) { Write-Log ('  参考: ' + $f.Name) 'WARN' }
        } else {
            Write-Log '窗口已消失，确认致命' 'ERROR'
        }
    }
} else {
    Write-Log '主窗口未在 90 秒内出现，改查 Web 服务模式（虚拟机/无GPU环境常见）...' 'WARN'
    $web = Test-DshWebAlive -TimeoutSec 40
    if ($web) {
        # Web 模式活着 => 再确认没有致命崩溃
        $fatalW = @()
        try {
            $logDirW = Join-Path $env:APPDATA '@deepseek-ai\dsh-desktop\logs'
            if (Test-Path $logDirW) {
                $fatalW += @(Get-ChildItem $logDirW -Filter 'crash-*-main.log' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $installFinishedAt })
                $fatalW += @(Get-ChildItem $logDirW -Filter 'crash-*-host.log' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $installFinishedAt })
            }
        } catch {}
        if ($fatalW.Count -eq 0) {
            $healthy = $true
            Write-Log ('健康检查通过（Web 模式运行，端口 ' + $web.Port + '，HTTP ' + $web.Status + '）') 'OK'
            Write-Log '说明：该环境无真实 GPU，Electron 自动降级为 Web 模式，服务正常运行。' 'WARN'
            Write-Log ('      用浏览器打开 http://127.0.0.1:' + $web.Port + '/ 即可使用。') 'WARN'
        } else {
            Write-Log ('Web 服务在跑，但检测到升级后致命崩溃 ' + $fatalW.Count + ' 个') 'WARN'
            foreach ($f in $fatalW) { Write-Log ('  参考: ' + $f.Name) 'WARN' }
        }
    } else {
        Write-Log '窗口和 Web 服务均未就绪，判定启动失败' 'ERROR'
    }
}

# ===================== 阶段8：失败自动回滚 =====================
$rolledBack = $false
$rollbackFailed = $false
if (-not $healthy) {
    Write-Log ''
    Write-Log '升级后健康检查未通过，启动自动回滚保护' 'ERROR'
    $rolledBack = Restore-FromBackup -BackupPath $backupPath
    if ($rolledBack) {
        $restoredVer = Get-InstalledVersion
        Write-Log ('已自动回滚到 ' + $restoredVer + '，功能恢复正常') 'OK'
        $verAfter = $restoredVer
        $pass = $false
    } else {
        Write-Log '自动回滚未成功，需要人工介入' 'ERROR'
        # 【v4.7 修复·致命】原来这里只打日志，没有把 $pass 置为 $false，
        # 导致汇总时 $pass 仍是阶段6 留下的 $true，最终输出「结果: 升级成功」+ 退出码 0
        # —— 回滚都失败了却报成功，这是最危险的假绿。
        # 修复：回滚失败必须 $pass=$false，并置 $rollbackFailed 标记，汇总时单独说明。
        $pass = $false
        $rollbackFailed = $true
        Write-Log ('备份目录: ' + $backupPath) 'WARN'
        Write-Log '手动恢复步骤：' 'WARN'
        Write-Log ('  1) 确认所有 DeepSeek Harness.exe 已结束') 'WARN'
        Write-Log ('  2) 删除/改名: ' + $InstallDir) 'WARN'
        Write-Log ('  3) 把 ' + $backupPath + ' 下所有文件（不含 _profile）复制到 ' + $InstallDir) 'WARN'
        Write-Log ('  4) 把 ' + (Join-Path $backupPath '_profile') + ' 下 3 个配置文件复制回 ' + $ProfileDir) 'WARN'
    }
} else {
    Write-Log '无需回滚' 'OK'

    # 【v4.13 修复·架构级】升级成功后，为【新版本】补一份备份。
    # 背景：备份是在「升级前」做的，所以备份的永远是【旧版本】。升级到新版本后，
    # 磁盘上没有任何与新版本同版本的备份 —— 而 -Verify / -Repair 要求版本一致，
    # 于是对新版本彻底失效（实测：升到 rc.3 后 -Verify 拿 rc.2 备份比对，
    # 报 26 缺失 + 9 损坏 + 13 多余，全是版本差异，无法判断真损坏）。
    # 修复：健康检查通过后，若没有当前版本的备份，就现场补一份。
    try {
        $verNow = Get-InstalledVersion
        if ($verNow) {
            $hasSame = $false
            if (Test-Path $RollbackDir) {
                foreach ($cand in @(Get-ChildItem $RollbackDir -Directory -ErrorAction SilentlyContinue |
                                    Where-Object { $_.Name -match '^app-[0-9A-Za-z.\-]+-\d{8}-\d{6}$' })) {
                    $cm = Join-Path $cand.FullName '_meta.json'
                    if (Test-Path -LiteralPath $cm) {
                        try {
                            $cv = (Get-Content -LiteralPath $cm -Raw | ConvertFrom-Json).version
                            if ($cv -and ((Compare-SemVer $cv $verNow) -eq 0)) { $hasSame = $true; break }
                        } catch {}
                    }
                }
            }
            if ($hasSame) {
                Write-Log ('已有 ' + $verNow + ' 的备份，无需补充') 'INFO'
            } else {
                Write-Log ('为当前版本 ' + $verNow + ' 补充一份备份（供 -Verify / -Repair 使用）...') 'INFO'
                $newBk = Backup-Installation -VersionTag $verNow
                if ($newBk) {
                    Write-Log ('已补充 ' + $verNow + ' 的备份: ' + $newBk) 'OK'
                } else {
                    Write-Log '补充备份失败（不影响已完成的升级，但 -Verify/-Repair 对新版本不可用）' 'WARN'
                }
            }
        }
    } catch { Write-Log ('补充备份出错: ' + $_.Exception.Message) 'WARN' }
}

# 清理旧备份
# 【v4.12 修复·严重】原来只写 Get-ChildItem $RollbackDir -Directory（无过滤），
# 会把 v4.11 新增的 repair-<时间戳> 安全副本目录也算进「最近 2 份」。
# 实测：rollback 目录里有 2 个 repair-* + 2 个 app-* 时，
# 排序后跳过前 2 个，真正需要保留的 2 个 app-* 备份反而被删掉 —— 数据丢失级 bug。
# 修复：只统计 app-* 备份；repair-* 单独按「保留最近 3 份」清理。
# 【v4.13 调整】保留份数从 2 提高到 3，并用严格正则匹配目录名。
# 原因：升级成功后会为新版本补一份备份，若仍只留 2 份，
# 旧版本备份刚补完就被清掉，回滚能力变弱。
try {
    $bks = @(Get-ChildItem $RollbackDir -Directory -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -match '^app-[0-9A-Za-z.\-]+-\d{8}-\d{6}$' } |
             Sort-Object LastWriteTime -Descending)
    foreach ($b in ($bks | Select-Object -Skip 3)) {
        if (Remove-DirRobust -Path $b.FullName) {
            Write-Log ('清理旧备份: ' + $b.Name)
        } else {
            Write-Log ('清理旧备份失败: ' + $b.Name) 'WARN'
        }
    }
    # repair-* 安全副本：保留最近 3 份（用于回退被修复的文件）
    $reps = @(Get-ChildItem $RollbackDir -Directory -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -like 'repair-*' } |
              Sort-Object LastWriteTime -Descending)
    foreach ($r in ($reps | Select-Object -Skip 3)) {
        if (Remove-DirRobust -Path $r.FullName) {
            Write-Log ('清理旧修复副本: ' + $r.Name)
        }
    }
} catch {}

# ===================== 汇总 =====================
New-Section '汇总'
if ($rolledBack) {
    Write-Log ('结果   : 升级失败，已自动回滚到 ' + $verAfter) 'WARN'
} elseif ($rollbackFailed) {
    Write-Log '结果   : 升级失败，且自动回滚也失败，需要人工介入' 'ERROR'
} elseif ($pass) {
    Write-Log ('结果   : 升级成功') 'OK'
} else {
    Write-Log '结果   : 装完但有警告' 'WARN'
}
Write-Log ('版本   : ' + $current + ' -> ' + $verAfter)
Write-Log ('安装包 : ' + $localPath)
Write-Log ('来源   : ' + $target.Source + ' / ' + $target.Version)
Write-Log ('备份   : ' + $backupPath)
Write-Log ('日志   : ' + $LogFile)
Write-Log '--- 数据安全检查 ---'
foreach ($pd in $ProtectedData) {
    if (Test-Path $pd) { Write-Log ('  完好: ' + $pd) 'OK' }
    else { Write-Log ('  不存在(可能原本就没有): ' + $pd) 'WARN' }
}
Write-Log '############################################################'
Write-Host ''
if ($rolledBack) {
    Write-Host '升级失败，已自动回滚到升级前版本，数据完好可用。' -ForegroundColor Yellow
} elseif ($rollbackFailed) {
    Write-Host '升级失败，自动回滚也没成功！请按上面 4 步手动恢复，备份在:' -ForegroundColor Red
    Write-Host ('  ' + $backupPath) -ForegroundColor Red
} elseif ($pass) {
    Write-Host '升级完成，DSH 已启动。' -ForegroundColor Green
} else {
    Write-Host '升级完成但有警告，请看日志。' -ForegroundColor Yellow
}
if ($rolledBack) { exit 6 }
if ($rollbackFailed) { exit 7 }
exit $(if ($pass) { 0 } else { 5 })
