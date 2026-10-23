# copathy インストーラー（「copathy をインストール」から実行される）
# 隣の copathy.ps1 を %LOCALAPPDATA%\copathy にコピーして起動する。画面を出さずに動くので、失敗はメッセージで知らせる
# 失敗したら元に戻す（前の版があれば前の版に、新しく入れたなら何も残さない）。ログは %TEMP%\copathy-install.log
$AppName = 'copathy'
$ErrorActionPreference = 'Stop'
$sourceDir = $PSScriptRoot
# 展開したフォルダを握らないよう、作業フォルダをユーザーのフォルダにする
Set-Location $env:USERPROFILE
[Environment]::CurrentDirectory = $env:USERPROFILE
Add-Type -AssemblyName System.Windows.Forms
# 画面の拡大率に合わせて、くっきり表示する（しないと引き伸ばされてぼやける）。ウィンドウを作る前に呼ぶ。
# できなくても文字がぼやけるだけなので、インストールは続ける
try {
    Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();' -Name Dpi -Namespace Setup
    [void][Setup.Dpi]::SetProcessDPIAware()
} catch {}

# 裏に隠れないよう、最前面の見えないウィンドウを親にして表示する
function Show-Message($message, $icon = 'Error') {
    # 自動のテスト用: 環境変数 SETUP_NO_UI=1 なら画面を出さず、ログに残すだけにする
    if ($env:SETUP_NO_UI -eq '1') { Write-Log "画面の知らせ（省略）: $message"; return }
    $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true; ShowInTaskbar = $false; Opacity = 0 }
    $owner.Show()
    $owner.Activate()
    [void][System.Windows.Forms.MessageBox]::Show($owner, $message, "$AppName のインストール",
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]$icon)
    $owner.Dispose()
}

# 名前はすべて $AppName から作る（名前を変えた写しは本物とぶつからない）
$dir = Join-Path $env:LOCALAPPDATA $AppName
$ps1 = Join-Path $dir 'copathy.ps1'
$previousPs1 = Join-Path $dir 'copathy.previous.ps1'   # 上書きの前の版（更新用の copathy.backup.ps1 とは別）
$installedFlag = Join-Path $dir 'installed.flag'
$uninstallPs1 = Join-Path $dir 'uninstall.ps1'
$logFile = Join-Path $dir 'log.txt'
$tempLog = Join-Path $env:TEMP "$AppName-install.log"  # 片づけでフォルダごと消すので、ログは TEMP に書く
$script:lines = New-Object System.Collections.Generic.List[string]
function Write-Log($text) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$PID] インストール: $($text -replace '\s*\r?\n\s*', ' | ')"
    [void]$script:lines.Add($line)
    try { Add-Content $tempLog $line -Encoding UTF8 } catch {}
}
try { if ((Test-Path $tempLog) -and (Get-Item $tempLog).Length -gt 100KB) { Remove-Item $tempLog -ErrorAction SilentlyContinue } } catch {}

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
# copathy.ps1 の $Version の行から版を読む（読めなければ '不明'）
function Get-Version($path) {
    try { $m = [regex]::Match([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8), "(?m)^\`$Version = '(\d+\.\d+\.\d+)'"); if ($m.Success) { return $m.Groups[1].Value } } catch {}
    '不明'
}
# 本体と同じく画面なしで起動する（作業フォルダはユーザーのフォルダ）
function Start-Copathy { Start-Process "$env:WINDIR\System32\conhost.exe" -PassThru -WorkingDirectory $env:USERPROFILE -ArgumentList "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ps1`" headless" }
# インストール先を含む copathy の PowerShell
function Find-Running { @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.ProcessId -ne $PID -and "$($_.CommandLine)".IndexOf($ps1, [StringComparison]::OrdinalIgnoreCase) -ge 0 }) }
function Stop-Running {
    foreach ($p in (Find-Running)) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $p.ProcessId -Timeout 5 -ErrorAction SilentlyContinue
    }
}

# インストール・消すの排他。もう一方が動いていたら何もしない（先に動いているほうが結果を知らせる）
$setup = New-Object System.Threading.Mutex($false, "Local\$($AppName)Setup")
try { $got = $setup.WaitOne(0) } catch { $got = ($_.Exception -is [System.Threading.AbandonedMutexException]) -or ($_.Exception.InnerException -is [System.Threading.AbandonedMutexException]) }
if (-not $got) {
    Write-Log 'すでにインストールか消す処理が動いているので、何もしないで終わる'
    # 相手が消す処理（確認を出している間など）なら、先に動いているほうはインストールのことを知らせないので、ここで知らせる
    # インストールの印があれば相手はインストール（片づけで消す処理を呼んでいる間も Uninstalling があるので、先に見る）。同じ種類なら黙る
    $other = $null; $otherInstall = $false
    try { if ([Threading.Mutex]::TryOpenExisting("Local\$($AppName)Installing", [ref]$other)) { $other.Dispose(); $otherInstall = $true } } catch {}
    try { if (-not $otherInstall -and [Threading.Mutex]::TryOpenExisting("Local\$($AppName)Uninstalling", [ref]$other)) { $other.Dispose(); Write-Log '相手は消す処理'; Show-Message "$AppName を消す処理が動いている（確認を出している間も）ので、今はインストールできない。それが終わってから、もう一度インストールする。" 'Information' } } catch {}
    exit 0
}
# 消す処理に「相手はインストール」と分かるよう、動いている間だけ印を持つ
$installing = New-Object System.Threading.Mutex($false, "Local\$($AppName)Installing")

$overwritten = $false  # 上書きを始めたら、失敗したとき元に戻す
$hadPrevious = $false
$newVersion = '不明'
$oldVersion = 'なし'
$result = 'なし'
$failure = $null
$restored = $false
try {
    $source = Join-Path $sourceDir 'copathy.ps1'
    if (-not (Test-Path $source)) {
        throw "copathy.ps1 が見つからない。ダウンロードした ZIP を展開し、展開したフォルダの中で実行する。"
    }
    $newVersion = Get-Version $source
    if (Test-Path $ps1) { $oldVersion = Get-Version $ps1; $hadPrevious = $true }
    Write-Log "開始 元=$sourceDir 新=v$newVersion 前=$(if ($hadPrevious) { "v$oldVersion" } else { 'なし' })"

    # 動いている copathy に合図で終わってもらってから上書きする（前の版など、合図で終わらなければ止める）
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $wasRunning = @(Find-Running).Count -gt 0
    $quit = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, "Local\$($AppName)Quit")
    $mutex = New-Object System.Threading.Mutex($false, "Local\$AppName")
    [void]$quit.Set()
    try { $stopped = $mutex.WaitOne(15000) } catch { $stopped = $true }  # 強制終了されて放棄されたものも空いた扱い
    [void]$quit.Reset()
    if ($stopped) {
        $mutex.ReleaseMutex()
        Write-Log $(if ($wasRunning) { "前の copathy を合図で終わらせた($([math]::Round($watch.Elapsed.TotalSeconds, 1)) 秒)" } else { '動いている前の copathy は無かった' })
    }
    # 合図で終わらなかったもの、合図がすぐ戻ったときに残っているもの（自動更新で起動しかけの新しい版など）は止める
    foreach ($p in (Find-Running)) { Write-Log "動いている copathy（$($p.ProcessId)）が合図で終わらないので止める" }
    Stop-Running
    # 止められないまま進むと、新しい copathy は二重起動として終わってしまう
    if (@(Find-Running).Count -gt 0) {
        throw '動いている copathy を止められなかった。トレイの copathy を「終了」してから、もう一度インストールする。'
    }

    New-Item -ItemType Directory -Force $dir | Out-Null
    # 失敗したら戻せるよう、前の版を取っておく
    Remove-Item $previousPs1 -ErrorAction SilentlyContinue
    if ($hadPrevious) { Copy-Item $ps1 $previousPs1 -Force }
    $overwritten = $true
    Copy-Item $source $ps1 -Force
    Unblock-File $ps1
    # 前に途中で止まったときの印が残っていると、起動したときに更新や戻しの知らせが出てしまう
    Remove-Item (Join-Path $dir 'updated.flag'), (Join-Path $dir 'rolledback.flag') -ErrorAction SilentlyContinue
    New-Item -ItemType File -Force $installedFlag | Out-Null

    # 本体と同じく画面なしで起動し、起動の知らせ（Ready）を待つ
    $ready = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, "Local\$($AppName)Ready")
    [void]$ready.Reset()
    $watch.Restart()
    $launch = Start-Copathy
    $result = Wait-Ready $ready $launch
    Write-Log "起動を待った $([math]::Round($watch.Elapsed.TotalSeconds, 1)) 秒 結果=$result"
    if ($result -ne 'ready') {
        throw "copathy を起動できなかった（$(if ($result -eq 'exited') { '起動してすぐ終わった' } else { '60 秒たっても起動しない' })）。"
    }
    Remove-Item $previousPs1 -ErrorAction SilentlyContinue
    Write-Log '成功'
    # 成功したときだけ、インストール先の log.txt にも写す（失敗して片づけたあとにフォルダを作り直さない）
    try { Add-Content $logFile $script:lines -Encoding UTF8 } catch {}
} catch {
    $failure = $_
    Write-Log "失敗: $_ $($_.InvocationInfo.PositionMessage)"
    if ($result -eq 'timeout') {
        Write-Log '起動しかけた copathy を止める'
        Stop-Running
    }
    $note = "理由は $tempLog に残した。"
    if (-not $overwritten) {
        # 何も上書きしていない
    } elseif ($hadPrevious) {
        # 前の版に戻す。2.5.0 が作った uninstall.ps1 と登録は残す（戻した先が持たない版なら、戻したあとに消す）
        Remove-Item $installedFlag -ErrorAction SilentlyContinue
        try {
            Copy-Item $previousPs1 $ps1 -Force
            Remove-Item (Join-Path $dir 'updated.flag'), (Join-Path $dir 'rolledback.flag') -ErrorAction SilentlyContinue
            $ready = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, "Local\$($AppName)Ready")
            [void]$ready.Reset()
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $back = Wait-Ready $ready (Start-Copathy)
            Write-Log "前の版を起動して待った $([math]::Round($watch.Elapsed.TotalSeconds, 1)) 秒 結果=$back"
            if ($back -ne 'ready') { Stop-Running; throw "戻した v$oldVersion が起動しない（$back）" }
            # 戻した先が「設定 > アプリ」の仕組みを持たない版（2.4.x 以前）なら、押しても何も起きない項目を残さない
            $prevHasUninstall = $false
            try { $prevHasUninstall = [IO.File]::ReadAllText($previousPs1, [Text.Encoding]::UTF8).Contains('$uninstallScript') } catch {}
            Remove-Item $previousPs1 -ErrorAction SilentlyContinue
            Write-Log "戻した v$oldVersion"
            if (-not $prevHasUninstall) {
                Remove-Item $uninstallPs1 -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$AppName" -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log '戻した版は消すスクリプトを持たないので、uninstall.ps1 と「設定 > アプリ」の登録を消した'
            }
            $note = "v$newVersion を起動できなかったので、前の v$oldVersion に戻した。前の版のまま使える。直らなければ、ログを送る。`n`n$note"
            $restored = $true
        } catch {
            Write-Log "戻せなかった: $_"
            $note = "v$oldVersion にも戻せなかった。トレイの copathy があれば「終了」してから、もう一度インストールする。それでもだめなら、$dir を消してからインストールし直す。`n`n$note"
        }
    } else {
        # 新しく入れたので、作ったものを残さない（消すスクリプトがあればそれで。排他は持ったまま渡す）
        Write-Log '片づける'
        try {
            if (Test-Path $uninstallPs1) {
                $code = (Start-Process powershell.exe -PassThru -Wait -WindowStyle Hidden -WorkingDirectory $env:TEMP `
                    -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$uninstallPs1`" -Quiet -HoldsLock").ExitCode
                Write-Log "消すスクリプトの結果=$code"
            }
            # 消すスクリプトが無い・消しきれなかったときは、残りを直接消す。登録は、フォルダが消えたあとに消す（フォルダが残れば、消し直せるよう登録も残す）
            $lnks = @((Join-Path ([Environment]::GetFolderPath('Startup')) "$AppName.lnk"), (Join-Path ([Environment]::GetFolderPath('Programs')) "$AppName.lnk"))
            $regKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$AppName"
            # uninstall.ps1 が残っているなら消すスクリプトが消しきれなかったので、フォルダは触らない（uninstall.ps1 まで消すと、残る登録から消し直せない）
            try { if ((Test-Path $dir) -and -not (Test-Path $uninstallPs1)) { Remove-Item $dir -Recurse -Force -ErrorAction Stop } } catch { Write-Log "フォルダを消せなかった: $_" }
            Remove-Item -LiteralPath $lnks -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path $dir)) { Remove-Item -LiteralPath $regKey -Recurse -Force -ErrorAction SilentlyContinue }
            # 消えたかを確かめてから知らせる
            $left = @($lnks + $dir + $regKey | Where-Object { Test-Path -LiteralPath $_ })
            if ($left.Count -gt 0) { throw "残っている: $($left -join ', ')" }
            Write-Log '片づけた'
            $note = "作ったものは消した。もう一度インストールする。直らなければ、ログを送る。`n`n$note"
        } catch {
            Write-Log "片づけきれなかった: $_"
            $note = if (Test-Path $uninstallPs1) {
                "作ったものを消しきれなかった。使っているもの（$dir の中を開いているアプリなど）を閉じてから、「設定 > アプリ」の $AppName をアンインストールする。`n`n$note"
            } else {
                "作ったものを消しきれなかった。$dir と、スタートアップ・スタートメニューの $AppName.lnk、レジストリの登録を手で消す（README の「アンインストール」にある場所）。`n`n$note"
            }
        }
    }
    Show-Message "インストールに失敗した。`n`n$($failure.Exception.Message)`n`n$note" $(if ($restored) { 'Warning' } else { 'Error' })
    $setup.ReleaseMutex()
    exit 1
}
$setup.ReleaseMutex()
