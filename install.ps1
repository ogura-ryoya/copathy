# copathy インストーラー（「copathy をインストール」から実行される）
# 隣の copathy.ps1 を %LOCALAPPDATA%\copathy にコピーして起動する。画面を出さずに動くので、失敗はメッセージで知らせる
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
# 画面の拡大率に合わせて、くっきり表示する（しないと引き伸ばされてぼやける）。ウィンドウを作る前に呼ぶ。
# できなくても文字がぼやけるだけなので、インストールは続ける
try {
    Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();' -Name Dpi -Namespace Setup
    [void][Setup.Dpi]::SetProcessDPIAware()
} catch {}

# 裏に隠れないよう、最前面の見えないウィンドウを親にして表示する
function Show-Error($message) {
    $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true; ShowInTaskbar = $false; Opacity = 0 }
    $owner.Show()
    $owner.Activate()
    [void][System.Windows.Forms.MessageBox]::Show($owner, $message, 'copathy のインストール',
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    $owner.Dispose()
}

$dir = Join-Path $env:LOCALAPPDATA 'copathy'
$installedFlag = Join-Path $dir 'installed.flag'
$logFile = Join-Path $dir 'log.txt'
function Write-Log($text) {
    try {
        New-Item -ItemType Directory -Force $dir | Out-Null
        Add-Content $logFile "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$PID] インストール: $text" -Encoding UTF8
    } catch {}
}

# 起動の知らせ（Ready）を待つ。起動したプロセス（conhost は中の PowerShell と一緒に終わる）が先に終われば、起動できない版なので待たない。
# 返すのは ready（来た）、exited（先に終わった）、timeout（来なかった）
function Wait-Ready($ready, $process, $ms = 60000) {
    $until = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $until) {
        if ($ready.WaitOne(500)) { return 'ready' }
        if ($process.HasExited) { if ($ready.WaitOne(0)) { return 'ready' } else { return 'exited' } }
    }
    'timeout'
}
try {
    $source = Join-Path $PSScriptRoot 'copathy.ps1'
    if (-not (Test-Path $source)) {
        throw "copathy.ps1 が見つからない。ダウンロードした ZIP を展開し、展開したフォルダの中で実行する。"
    }
    $ps1 = Join-Path $dir 'copathy.ps1'

    # 動いている copathy に合図で終わってもらってから上書きする（前の版など、合図で終わらなければ止める）
    $quit = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, 'Local\copathyQuit')
    $mutex = New-Object System.Threading.Mutex($false, 'Local\copathy')
    [void]$quit.Set()
    try { $stopped = $mutex.WaitOne(15000) } catch { $stopped = $true }  # 強制終了されて放棄されたものも空いた扱い
    [void]$quit.Reset()
    if ($stopped) { $mutex.ReleaseMutex() } else {
        $findRunning = { @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { "$($_.CommandLine)".IndexOf($ps1, [StringComparison]::OrdinalIgnoreCase) -ge 0 }) }
        foreach ($p in (& $findRunning)) {
            Write-Log "動いている copathy（$($p.ProcessId)）が合図で終わらないので止める"
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
            Wait-Process -Id $p.ProcessId -Timeout 5 -ErrorAction SilentlyContinue
        }
        # 止められないまま進むと、新しい copathy は二重起動として終わってしまう
        if ((& $findRunning).Count -gt 0) {
            throw '動いている copathy を止められなかった。トレイの copathy を「終了」してから、もう一度インストールする。'
        }
    }

    New-Item -ItemType Directory -Force $dir | Out-Null
    Copy-Item $source $ps1 -Force
    Unblock-File $ps1
    # 前に途中で止まったときの印が残っていると、起動したときに更新や戻しの知らせが出てしまう
    Remove-Item (Join-Path $dir 'updated.flag'), (Join-Path $dir 'rolledback.flag') -ErrorAction SilentlyContinue
    New-Item -ItemType File -Force $installedFlag | Out-Null

    # 本体と同じく画面なしで起動し、起動の知らせ（copathyReady）を待つ
    $ready = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, 'Local\copathyReady')
    [void]$ready.Reset()
    $launch = Start-Process "$env:WINDIR\System32\conhost.exe" -PassThru -ArgumentList "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ps1`" headless"
    $result = Wait-Ready $ready $launch
    if ($result -ne 'ready') {
        throw "copathy を起動できなかった（$(if ($result -eq 'exited') { '起動してすぐ終わった' } else { '60 秒たっても起動しない' })）。理由はログに残した: $logFile"
    }
} catch {
    Remove-Item $installedFlag -ErrorAction SilentlyContinue
    Write-Log "失敗した: $_ $($_.InvocationInfo.PositionMessage)"
    Show-Error "インストールに失敗した。`n`n$($_.Exception.Message)"
    exit 1
}
