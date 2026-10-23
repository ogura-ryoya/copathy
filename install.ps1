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
try {
    $source = Join-Path $PSScriptRoot 'copathy.ps1'
    if (-not (Test-Path $source)) {
        throw "copathy.ps1 が見つからない。ダウンロードした ZIP を展開し、展開したフォルダの中で実行する。"
    }
    $ps1 = Join-Path $dir 'copathy.ps1'

    # 動いている copathy を止めてから上書きする
    $findRunning = { @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*\copathy.ps1*' }) }
    foreach ($p in (& $findRunning)) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $p.ProcessId -Timeout 5 -ErrorAction SilentlyContinue
    }
    # 止められないまま進むと、新しい copathy は二重起動として終わってしまう
    if ((& $findRunning).Count -gt 0) {
        throw '動いている copathy を止められなかった。トレイの copathy を「終了」してから、もう一度インストールする。'
    }

    New-Item -ItemType Directory -Force $dir | Out-Null
    Copy-Item $source $ps1 -Force
    Unblock-File $ps1
    # 前に途中で止まったときの印が残っていると、起動したときに更新や戻しの知らせが出てしまう
    Remove-Item (Join-Path $dir 'updated.flag'), (Join-Path $dir 'rolledback.flag') -ErrorAction SilentlyContinue
    New-Item -ItemType File -Force $installedFlag | Out-Null

    # 起動の知らせ（copathyReady）を 60 秒待つ。-Wait は起動した copathy の終了まで待ってしまうので WaitForExit を使う
    $ready = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, 'Local\copathyReady')
    [void]$ready.Reset()
    (Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$ps1`"").WaitForExit()
    if (-not $ready.WaitOne(60000)) {
        throw 'copathy を起動できなかった。PC を再起動してから、もう一度インストールする。'
    }
} catch {
    Remove-Item $installedFlag -ErrorAction SilentlyContinue
    try { Add-Content (Join-Path $dir 'log.txt') "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$PID] インストールに失敗した: $_" -Encoding UTF8 } catch {}
    Show-Error "インストールに失敗した。`n`n$($_.Exception.Message)"
    exit 1
}
