# copathy: エクスプローラーで Ctrl+Alt+C を押すと、選択中のファイル・フォルダのパスをまとめてコピーする。
# トレイに常駐し、自動起動を登録する。起動時と「更新を確認」で GitHub の最新リリースに更新する。
$Version = '2.5.0'
$AppName = 'copathy'
$Repo = 'ogura-ryoya/copathy'
$Usage = 'Ctrl+Alt+C でパスをコピー'
$Hint = 'エクスプローラーでファイルやフォルダを選んで Ctrl+Alt+C を押すと、パスをコピーできる。'  # 通知で使い方を知らせる
$checkEveryHours = 24  # 起動時のほか、動いている間もこの時間ごとに更新を確認する（スリープで使い続ける PC にも届くように）

$ps1 = $MyInvocation.MyCommand.Path
$appDir = Split-Path $ps1
# インストール先（名前は $AppName だけから作る。名前を変えた写しは本物とぶつからない）。ここ以外では、ショートカット・消すスクリプト・登録を作らない
$installDir = Join-Path $env:LOCALAPPDATA $AppName
$isInstalled = [IO.Path]::GetFullPath($appDir).TrimEnd('\') -ieq [IO.Path]::GetFullPath($installDir).TrimEnd('\')
$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) "$AppName.lnk"
$startMenuLnk = Join-Path ([Environment]::GetFolderPath('Programs')) "$AppName.lnk"
$icoPath = Join-Path $appDir "$AppName.ico"
$appId = "ogura-ryoya.$AppName"  # 通知でほかの PowerShell 製ツールと区別する ID
$installedFlag = Join-Path $appDir 'installed.flag'    # インストール直後
$updatedFlag = Join-Path $appDir 'updated.flag'        # 更新直後（中身は新しい版）
$rolledBackFlag = Join-Path $appDir 'rolledback.flag'  # 更新した版が起動できず戻した（中身はその版）
$skipFile = Join-Path $appDir 'skip-version.txt'       # 自動では更新しない版
$backupPs1 = Join-Path $appDir 'copathy.backup.ps1'    # 更新前の版
$uninstallPs1 = Join-Path $appDir 'uninstall.ps1'      # 消すスクリプト（正本はこのファイルの $uninstallScript。起動のたびに書き出す）
$uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$AppName"  # 「設定 > アプリ」の登録
$logFile = Join-Path $appDir 'log.txt'                # 問題があったときにユーザーが丸ごと Claude に貼る。100KB で log.old.txt に回す

function Write-Log($text) {
    try {
        if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 100KB) { Move-Item $logFile (Join-Path $appDir 'log.old.txt') -Force }
        Add-Content $logFile "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$PID] $($text -replace '\s*\r?\n\s*', ' | ')" -Encoding UTF8
    } catch {}
}
# 画面なしで動くので、止まったことは画面でも知らせる（WinForms を読む前でも出せる Popup を使う）
trap {
    Write-Log "想定外のエラーで止まった: $_ $($_.InvocationInfo.PositionMessage)"
    try { [void](New-Object -ComObject WScript.Shell).Popup("$AppName が想定外のエラーで止まった。`n`n$_`n`n理由はログに残した: $logFile", 0, $AppName, 16) } catch {}
    break
}

$conhost = "$env:WINDIR\System32\conhost.exe"
# 最後の headless は、画面なしで起動したことの目印
$launchArgs = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ps1`" headless"
$uninstallArgs = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$uninstallPs1`""

# 作業フォルダはユーザーのフォルダにする（展開したフォルダなどを握らない）
function New-Shortcut($path) {
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($path)
    $s.TargetPath = $conhost
    $s.Arguments = $launchArgs
    $s.IconLocation = "$icoPath,0"
    $s.WindowStyle = 7
    $s.WorkingDirectory = $env:USERPROFILE
    $s.Save()
}

function Start-App { Start-Process $conhost -ArgumentList $launchArgs -WorkingDirectory $env:USERPROFILE -PassThru }

# 裏に隠れないよう、最前面の見えないウィンドウを親にして出す。
# 出している間は更新を止める（止めると、閉じられたダイアログが初めの選択を返し、アンインストールなどが進んでしまう）
$script:dialogs = 0
function Show-Dialog($text, $title, [System.Windows.Forms.MessageBoxButtons]$buttons, [System.Windows.Forms.MessageBoxIcon]$icon,
    [System.Windows.Forms.MessageBoxDefaultButton]$default = 'Button1') {
    $script:dialogs++
    $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true; ShowInTaskbar = $false; Opacity = 0 }
    $owner.Show()
    $owner.Activate()
    try { [System.Windows.Forms.MessageBox]::Show($owner, $text, $title, $buttons, $icon, $default) } finally { $owner.Dispose(); $script:dialogs-- }
}

# 消すスクリプト（uninstall.ps1）が動いている（確認を出している間も）。あれば更新を始めない
function Test-Uninstalling {
    $m = $null
    try { if ([Threading.Mutex]::TryOpenExisting("Local\$($AppName)Uninstalling", [ref]$m)) { $m.Dispose(); return $true } } catch {}
    $false
}

# 画面なしの起動（目印の headless 付き）でなければ、画面なしで起動し直す
if ($args -notcontains 'headless') {
    [void](Start-App)
    return
}
# 起動した場所（古い版が起動したときは展開したフォルダ）を握り続けないよう、作業フォルダをユーザーのフォルダにする
try { Set-Location $env:USERPROFILE; [Environment]::CurrentDirectory = $env:USERPROFILE } catch {}

$mutex = New-Object System.Threading.Mutex($false, "Local\$AppName")
try {
    $acquired = $mutex.WaitOne(0)
} catch {
    # 前の copathy が強制終了されていると AbandonedMutexException になるが、所有権は得ている
    $ex = $_.Exception
    $acquired = ($ex -is [System.Threading.AbandonedMutexException]) -or ($ex.InnerException -is [System.Threading.AbandonedMutexException])
}
# 二重起動のときは、動いている copathy に知らせてもらう（黙って終わると反応が無いように見える）
$alreadyRunning = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, "Local\$($AppName)AlreadyRunning")
if (-not $acquired) { Write-Log 'すでに起動しているので、動いている copathy に知らせて終わる'; [void]$alreadyRunning.Set(); exit }
# インストールし直すとき、インストーラーがこれで終わってもらう
$quitEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, "Local\$($AppName)Quit")
$startedByUpdate = Test-Path $updatedFlag
Write-Log "起動 v$Version PowerShell $($PSVersionTable.PSVersion) Windows $([Environment]::OSVersion.Version) $ps1"

# v1 の exe 版が使っていたレジストリの自動起動を消す
Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $AppName -ErrorAction SilentlyContinue

# 消すスクリプトの正本。自動更新で届くのは copathy.ps1 だけなので、起動のたびに uninstall.ps1 として書き出す。
# 本体が起動できなくなっても、「設定 > アプリ」からこれで消せる。@@APPNAME@@ は書き出すときに $AppName に置きかえる
$uninstallScript = @'
# copathy を消すスクリプト。copathy.ps1 が起動のたびに書き出す（ここを直しても上書きされる）
# -Yes: 確認しない / -Quiet: 画面を出さず確認もしない（結果は終了コードで返す）/ -HoldsLock: 呼んだ側（インストーラー）が排他を持っている
# 終了コード: 0 消えた / 1 消せなかったものがある / 2 インストールか消すが動いていて何もしなかった / 3 取りやめた
param([switch]$Yes, [switch]$Quiet, [switch]$HoldsLock)
$AppName = '@@APPNAME@@'
$dir = Join-Path $env:LOCALAPPDATA $AppName
$appId = "ogura-ryoya.$AppName"
$log = Join-Path $env:TEMP "$AppName-uninstall.log"   # フォルダごと消すので、ログは TEMP に置く
function Log($t) { try { Add-Content $log "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$PID] アンインストール: $($t -replace '\s*\r?\n\s*', ' | ')" -Encoding UTF8 } catch {} }
# 画面を出す前に、拡大率に合わせてくっきり表示する（しないと引き伸ばされてぼやける）。ウィンドウを作る前に呼ぶ。できなくても文字がぼやけるだけなので、消す処理は続ける
function Initialize-Ui {
    Add-Type -AssemblyName System.Windows.Forms
    if ($script:dpiDone) { return }
    $script:dpiDone = $true
    try {
        Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();' -Name Dpi -Namespace Uninst
        [void][Uninst.Dpi]::SetProcessDPIAware()
    } catch { Log "拡大率への対応を設定できなかった: $_" }
}
function Show($text, $icon) {
    if ($Quiet) { return }
    try {
        Initialize-Ui
        $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true; ShowInTaskbar = $false; Opacity = 0 }
        $owner.Show(); $owner.Activate()
        [System.Windows.Forms.MessageBox]::Show($owner, $text, "$AppName のアンインストール", 'OK', $icon) | Out-Null
        $owner.Dispose()
    } catch { Log "画面を出せなかった: $_" }
}
# 作業フォルダが消すフォルダの中だと消せない
Set-Location $env:TEMP
[Environment]::CurrentDirectory = $env:TEMP
try { if ((Test-Path $log) -and (Get-Item $log).Length -gt 100KB) { Remove-Item $log -ErrorAction SilentlyContinue } } catch {}
trap {
    Log "想定外のエラーで止まった: $_ $($_.InvocationInfo.PositionMessage)"
    Show "想定外のエラーで止まった。`n`n$_`n`n理由はログに残した: $log" 'Error'
    exit 1
}

# インストール・消すの排他（先に動いているほうが結果を知らせるので、後からのものは何もしない）
if (-not $HoldsLock) {
    $setup = New-Object System.Threading.Mutex($false, "Local\$($AppName)Setup")
    try { $got = $setup.WaitOne(0) } catch { $got = ($_.Exception -is [System.Threading.AbandonedMutexException]) -or ($_.Exception.InnerException -is [System.Threading.AbandonedMutexException]) }
    if (-not $got) {
        Log 'インストールか消す処理が動いているので、何もしないで終わる'
        # 相手がインストール（印を持っている）なら知らせる。相手が消す処理なら、先に動いているほうが結果を知らせる
        $other = $null; $installing = $false
        try { if ([Threading.Mutex]::TryOpenExisting("Local\$($AppName)Installing", [ref]$other)) { $other.Dispose(); $installing = $true } } catch {}
        if ($installing) {
            Show "$AppName のインストールが動いているので、何も消さなかった。それが終わってから、もう一度消す。" 'Information'
        }
        exit 2
    }
}
# 消し残したとき、消し直せるよう自分を書き戻すための控え
$selfText = $null
try { if ($PSCommandPath) { $selfText = [IO.File]::ReadAllText($PSCommandPath, (New-Object System.Text.UTF8Encoding $true)) } } catch {}
$selfPath = Join-Path $dir 'uninstall.ps1'
# フォルダは、自分（uninstall.ps1）を最後にして消す（途中で止まっても、自分が残って「設定 > アプリ」から消し直せる）
function Remove-Dir {
    $others = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop | Where-Object { $_.FullName -ine $selfPath })
    $first = $null
    foreach ($c in $others) { try { Remove-Item -LiteralPath $c.FullName -Recurse -Force -ErrorAction Stop } catch { if (-not $first) { $first = $_ } } }
    if ($first) { throw $first }
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop
}
# 動いている間（確認を出している間も）、copathy が更新を始めないよう印を持つ
$busy = New-Object System.Threading.Mutex($false, "Local\$($AppName)Uninstalling")
Log "開始 $dir $(if ($Quiet) { '画面なし' } elseif ($Yes) { '確認なし' } else { '確認あり' })"

if (-not ($Yes -or $Quiet)) {
    Initialize-Ui
    $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true; ShowInTaskbar = $false; Opacity = 0 }
    $owner.Show(); $owner.Activate()
    $answer = [System.Windows.Forms.MessageBox]::Show($owner, "$AppName をアンインストールする？`n`n自動起動、スタートメニューのショートカット、$dir（ログも含む）、通知の設定、「設定 > アプリ」の登録をすべて消す。元に戻せない。",
        "$AppName のアンインストール", 'YesNo', 'Warning', 'Button2')
    $owner.Dispose()
    if ($answer -ne 'Yes') { Log '取りやめた'; exit 3 }
}

# 合図で copathy に終わってもらう
$quit = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, "Local\$($AppName)Quit")
$mutex = New-Object System.Threading.Mutex($false, "Local\$AppName")
[void]$quit.Set()
try { $stopped = $mutex.WaitOne(15000) } catch { $stopped = $true }  # 強制終了されて放棄されたものも空いた扱い
[void]$quit.Reset()
if ($stopped) { try { $mutex.ReleaseMutex() } catch {} }
# まだ残っているもの（合図で終わらない版、更新の途中で前の版と新しい版が両方いるとき）はインストール先を含むものをすべて止める
$findRunning = { @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.ProcessId -ne $PID -and "$($_.CommandLine)".IndexOf("$dir\", [StringComparison]::OrdinalIgnoreCase) -ge 0 }) }
foreach ($p in (& $findRunning)) {
    Log "動いている $AppName（$($p.ProcessId)）が合図で終わらないので止める"
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    Wait-Process -Id $p.ProcessId -Timeout 5 -ErrorAction SilentlyContinue
}

# 消す。登録は、ほかがすべて消えたときだけ最後に消す（残ったら「設定 > アプリ」から消し直せる）
$targets = @(
    (Join-Path ([Environment]::GetFolderPath('Startup')) "$AppName.lnk"),
    (Join-Path ([Environment]::GetFolderPath('Programs')) "$AppName.lnk"),
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\$appId",
    $dir)
$why = @{}
for ($i = 0; $i -lt 3; $i++) {
    foreach ($t in $targets) {
        if (Test-Path -LiteralPath $t) {
            if ($t -eq $dir -and @($targets | Where-Object { $_ -ne $dir -and (Test-Path -LiteralPath $_) }).Count -gt 0) { $why[$t] = 'ほかが消えていないので、消さずに残した'; continue }
            try { if ($t -eq $dir) { Remove-Dir } else { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction Stop }; $why.Remove($t) } catch { $why[$t] = "$($_.Exception.Message)" }
        }
    }
    if (@($targets | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0) { break }
    Start-Sleep -Seconds 1
}
# フォルダだけ残った（別のプロセスの作業フォルダなど）ときに自分が消えていたら、書き戻す
if ((Test-Path -LiteralPath $dir) -and $selfText -and -not (Test-Path -LiteralPath $selfPath)) {
    try { [IO.File]::WriteAllText($selfPath, $selfText, (New-Object System.Text.UTF8Encoding $true)); Log 'フォルダが残ったので uninstall.ps1 を書き戻した' } catch { Log "uninstall.ps1 を書き戻せなかった: $_" }
}
$left = @($targets | Where-Object { Test-Path -LiteralPath $_ })
if ($left.Count -eq 0) {
    $regKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$AppName"
    try { if (Test-Path -LiteralPath $regKey) { Remove-Item -LiteralPath $regKey -Recurse -Force -ErrorAction Stop } } catch { $why[$regKey] = "$($_.Exception.Message)" }
    if (Test-Path -LiteralPath $regKey) { $left = @($regKey) }
}
if ($left.Count -eq 0) {
    Log '消した'
    # すべて消せたので、調べるためのログは要らない（インストーラーが片づけに呼んだときは、失敗の理由なので残す）
    if (-not $HoldsLock) { Remove-Item -LiteralPath $log, (Join-Path $env:TEMP "$AppName-install.log") -Force -ErrorAction SilentlyContinue }
    exit 0
}
foreach ($t in $left) { Log "消せなかった: $t（$($why[$t])）" }
$leftText = ($left | ForEach-Object { $_ -replace '^HKCU:', 'HKEY_CURRENT_USER' }) -join "`n"
if (Test-Path -LiteralPath $selfPath) {
    Show "消せなかったものがある。使っているものを閉じてから、「設定 > アプリ」の $AppName をもう一度アンインストールする。`n`n消せなかったもの:`n$leftText`n`n理由はログに残した: $log" 'Warning'
} else {
    Show "消せなかったものがある。消すスクリプトも無いので、次のものを手で消す。`n`n$leftText`n`nレジストリの登録（HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall\$AppName）が残っていれば、それも消す。理由はログに残した: $log" 'Warning'
}
exit 1
'@

# 消すスクリプトと「設定 > アプリ」の登録を、ショートカットより先に書く（インストール先でだけ）。書けなかったことはログに残す
if ($isInstalled) {
    try {
        $utf8Bom = New-Object System.Text.UTF8Encoding $true
        $scriptText = $uninstallScript.Replace('@@APPNAME@@', $AppName)
        $current = if (Test-Path $uninstallPs1) { [IO.File]::ReadAllText($uninstallPs1, $utf8Bom) } else { $null }
        if ($current -cne $scriptText) { [IO.File]::WriteAllText($uninstallPs1, $scriptText, $utf8Bom) }
    } catch { Write-Log "消すスクリプト（uninstall.ps1）を書けなかった: $_" }
    try {
        if (-not (Test-Path -LiteralPath $uninstallKey)) { [void](New-Item $uninstallKey -Force) }
        $entries = [ordered]@{
            DisplayName = $AppName; DisplayVersion = $Version; Publisher = 'ogura-ryoya'; DisplayIcon = $icoPath
            InstallLocation = $appDir; URLInfoAbout = "https://github.com/$Repo"
            UninstallString = "`"$conhost`" $uninstallArgs"
        }
        foreach ($name in $entries.Keys) { Set-ItemProperty -LiteralPath $uninstallKey -Name $name -Value $entries[$name] -ErrorAction Stop }
        foreach ($name in 'NoModify', 'NoRepair') { Set-ItemProperty -LiteralPath $uninstallKey -Name $name -Value 1 -Type DWord -ErrorAction Stop }
    } catch { Write-Log "「設定 > アプリ」の登録を書けなかった: $_" }
} else {
    Write-Log "$appDir はインストール先（$installDir）でないので、ショートカット・消すスクリプト・登録は作らない"
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

// エクスプローラー（CabinetWClass）が前面にある間だけ Ctrl+Alt+C を登録する
public class ExplorerHotkey : NativeWindow, IDisposable {
    delegate void WinEventProc(IntPtr hook, uint ev, IntPtr hwnd, int obj, int child, uint thread, uint time);
    [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr mod, WinEventProc proc, uint pid, uint tid, uint flags);
    [DllImport("user32.dll")] static extern bool UnhookWinEvent(IntPtr h);
    [DllImport("user32.dll", SetLastError = true)] static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);

    public static IntPtr Foreground() { return GetForegroundWindow(); }

    // 拡大率に合わせてくっきり表示する。ウィンドウを作る前に呼ぶ
    public static void EnableDpiAwareness() { SetProcessDPIAware(); }

    const uint EVENT_SYSTEM_FOREGROUND = 3, MOD_ALT = 1, MOD_CONTROL = 2, MOD_NOREPEAT = 0x4000, VK_C = 0x43;
    readonly WinEventProc proc;
    readonly IntPtr hook;
    bool registered, failureReported;
    public event EventHandler Pressed;
    public event EventHandler RegisterFailed;  // 登録できなかった（ほかのアプリが Ctrl+Alt+C を使っているなど）。1 回だけ
    public int LastError { get; private set; }

    public ExplorerHotkey() {
        CreateHandle(new CreateParams());
        proc = (h, e, hwnd, o, c, t, tm) => Update(hwnd);
        hook = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, proc, 0, 0, 0);
    }

    // RegisterFailed をつないでから呼ぶ（つなぐ前に登録に失敗すると知らせが出ない）
    public void Start() { Update(GetForegroundWindow()); }

    static bool IsExplorer(IntPtr h) {
        var s = new StringBuilder(64);
        GetClassName(h, s, 64);
        return s.ToString() == "CabinetWClass";
    }

    void Update(IntPtr fg) {
        bool want = IsExplorer(fg);
        if (want && !registered) {
            registered = RegisterHotKey(Handle, 1, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, VK_C);
            if (!registered && !failureReported && RegisterFailed != null) {
                LastError = Marshal.GetLastWin32Error();
                failureReported = true;
                RegisterFailed(this, EventArgs.Empty);
            }
        }
        else if (!want && registered) { UnregisterHotKey(Handle, 1); registered = false; }
    }

    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312 && Pressed != null) Pressed(this, EventArgs.Empty);
        base.WndProc(ref m);
    }

    public void Dispose() {
        if (registered) UnregisterHotKey(Handle, 1);
        UnhookWinEvent(hook);
        DestroyHandle();
    }

    // 黄色いフォルダに青い線。32×32 を基準に拡大・縮小する
    static Bitmap Draw(int size) {
        var b = new Bitmap(size, size);
        using (var g = Graphics.FromImage(b))
        using (var folder = new SolidBrush(Color.FromArgb(255, 200, 70)))
        using (var pen = new Pen(Color.FromArgb(40, 90, 200), 3f)) {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.ScaleTransform(size / 32f, size / 32f);
            g.FillRectangle(folder, 2, 6, 12, 5);
            g.FillRectangle(folder, 2, 9, 28, 19);
            g.DrawLine(pen, 8, 15, 24, 15);
            g.DrawLine(pen, 8, 21, 19, 21);
        }
        return b;
    }

    public static Icon MakeIcon(int size) {
        using (var b = Draw(size)) return Icon.FromHandle(b.GetHicon());
    }

    // 32×32 の PNG を 1 枚だけ入れた .ico を書き出す（ヘッダー 6 バイト＋項目 16 バイトのあとに PNG）
    public static void SaveIco(string path) {
        byte[] png;
        using (var b = Draw(32))
        using (var ms = new MemoryStream()) { b.Save(ms, ImageFormat.Png); png = ms.ToArray(); }
        using (var w = new BinaryWriter(File.Create(path))) {
            w.Write(new byte[] { 0, 0, 1, 0, 1, 0, 32, 32, 0, 0, 1, 0, 32, 0 });
            w.Write(png.Length);
            w.Write(22);
            w.Write(png);
        }
    }
}

// 通知の見出しの名前とアイコンは、同じ ID を持つスタートメニューのショートカットから取られる
public static class AppUserModel {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int SetCurrentProcessExplicitAppUserModelID(string id);
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore {
        void GetCount(out uint n);
        void GetAt(uint i, IntPtr key);
        void GetValue(IntPtr key, IntPtr value);
        void SetValue(ref PropertyKey key, ref PropVariant value);
        void Commit();
    }
    struct PropertyKey { public Guid fmtid; public uint pid; }
    [StructLayout(LayoutKind.Explicit)]
    struct PropVariant { [FieldOffset(0)] public ushort vt; [FieldOffset(8)] public IntPtr p; [FieldOffset(16)] public IntPtr pad; }

    // ショートカットが無いとき（インストール先以外）は、このプロセスに ID だけ設定する
    public static void SetProcessId(string id) { SetCurrentProcessExplicitAppUserModelID(id); }

    // ショートカットに ID を書き込み、このプロセスにも同じ ID を設定する
    public static void SetAppId(string lnkPath, string id) {
        var link = (System.Runtime.InteropServices.ComTypes.IPersistFile)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("00021401-0000-0000-C000-000000000046")));
        link.Load(lnkPath, 2);  // STGM_READWRITE
        var key = new PropertyKey { fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), pid = 5 };  // System.AppUserModel.ID
        var value = new PropVariant { vt = 31, p = Marshal.StringToCoTaskMemUni(id) };  // VT_LPWSTR
        try {
            var store = (IPropertyStore)link;
            store.SetValue(ref key, ref value);
            store.Commit();
            link.Save(lnkPath, true);
        } finally { Marshal.FreeCoTaskMem(value.p); Marshal.ReleaseComObject(link); }
        SetCurrentProcessExplicitAppUserModelID(id);
    }
}

public static class PathText {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("shlwapi.dll", CharSet = CharSet.Unicode)] static extern int StrCmpLogicalW(string a, string b);

    [ComImport, Guid("6D5140C1-7436-11CE-8034-00AA006009FA"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IServiceProvider {
        [PreserveSig] int QueryService(ref Guid service, ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object obj);
    }

    [ComImport, Guid("000214E2-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellBrowser {
        void GetWindow(out IntPtr hwnd);  // IOleWindow::GetWindow
    }

    // Windows 11 のタブ: 先頭の ShellTabWindowClass が表示中のタブ
    public static IntPtr ActiveTab(IntPtr window) { return FindWindowEx(window, IntPtr.Zero, "ShellTabWindowClass", null); }

    // Shell.Application の Windows() の要素が、どのタブのものかを返す
    public static IntPtr TabOf(object browser) {
        try {
            var service = new Guid("4C96BE40-915C-11CF-99D3-00AA004AE837");  // SID_STopLevelBrowser
            var iid = typeof(IShellBrowser).GUID;
            object o;
            if (((IServiceProvider)browser).QueryService(ref service, ref iid, out o) != 0 || o == null) return IntPtr.Zero;
            IntPtr h;
            ((IShellBrowser)o).GetWindow(out h);
            return h;
        } catch { return IntPtr.Zero; }
    }

    // 親フォルダごとにまとめる。2 つ以上あるものは「親フォルダ + 名前の一覧」、
    // 1 つだけのものは最後にフルパスでまとめて出す。まとまりの間は空行で区切る
    public static string Format(string[] paths) {
        var blocks = new List<string>();
        var singles = new List<string>();
        var groups = paths
            .GroupBy(p => Path.GetDirectoryName(p) ?? "", StringComparer.OrdinalIgnoreCase)
            .OrderBy(g => g.Key, new Logical());
        foreach (var g in groups) {
            if (g.Count() == 1 || g.Key == "") { singles.AddRange(g); continue; }
            var sb = new StringBuilder(AddSlash(g.Key));
            foreach (var p in Sort(g)) {
                string name = Path.GetFileName(p);
                sb.Append("\r\n").Append(IsDir(p) ? name + "\\" : name);
            }
            blocks.Add(sb.ToString());
        }
        if (singles.Count > 0) blocks.Add(string.Join("\r\n", Sort(singles).Select(p => IsDir(p) ? AddSlash(p) : p)));
        return string.Join("\r\n\r\n", blocks);
    }

    // フォルダが先、名前は数字を数として比べる（file2 < file10）
    static IEnumerable<string> Sort(IEnumerable<string> paths) {
        return paths.OrderBy(p => IsDir(p) ? 0 : 1).ThenBy(p => p, new Logical());
    }

    // ZIP は Shell 上フォルダ扱いになるので、実際のフォルダかで判定する。
    // 長いパスが有効でない PC では 248 文字以上のフォルダが見えないので、\\?\ を付けて確かめる
    static bool IsDir(string p) {
        try {
            if (p.Length >= 248 && !p.StartsWith(@"\\?\")) p = p.StartsWith(@"\\") ? @"\\?\UNC\" + p.Substring(2) : @"\\?\" + p;
            return Directory.Exists(p);
        } catch { return false; }
    }
    static string AddSlash(string p) { return p.EndsWith("\\") ? p : p + "\\"; }

    class Logical : IComparer<string> {
        public int Compare(string a, string b) { return StrCmpLogicalW(a, b); }
    }
}
"@

[ExplorerHotkey]::EnableDpiAwareness()

# ショートカットのアイコンに使うので先に作る
try { [ExplorerHotkey]::SaveIco($icoPath) } catch { Write-Log "アイコンを作れなかった: $_" }
$autostartFailed = $false
$startMenuLnkIsNew = $false
if ($isInstalled) {
    try { New-Shortcut $startupLnk } catch { $autostartFailed = $true; Write-Log "自動起動を登録できなかった: $_" }

    # 通知の見出しにアプリの名前とアイコンを出すため、同じ ID のショートカットをスタートメニューに作る（画面を作る前に行う）
    $startMenuLnkIsNew = -not (Test-Path $startMenuLnk)
    try {
        New-Shortcut $startMenuLnk
        [AppUserModel]::SetAppId($startMenuLnk, $appId)
    } catch { Write-Log "スタートメニューのショートカットを作れなかった: $_" }
} else {
    [AppUserModel]::SetProcessId($appId)  # ショートカットは作らない（通知の見出しは ID になる）
}

$shell = New-Object -ComObject Shell.Application
$hk = New-Object ExplorerHotkey
$Warning = [System.Windows.Forms.ToolTipIcon]::Warning
$Info = [System.Windows.Forms.ToolTipIcon]::Info

$hk.add_RegisterFailed({
    Write-Log "Ctrl+Alt+C を登録できなかった（Windows のエラー $($hk.LastError)）。ほかのアプリが Ctrl+Alt+C を使っているかもしれない"
    $tray.ShowBalloonTip(8000, 'Ctrl+Alt+C が使えない',
        'ほかのアプリが Ctrl+Alt+C を使っているかもしれない。そのアプリを終了してから、エクスプローラーを選び直す。', $Warning)
})

$hk.add_Pressed({
    try {
        $fg = [ExplorerHotkey]::Foreground()
        $wins = @($shell.Windows() | Where-Object { $_.HWND -eq $fg.ToInt64() })
        if ($wins.Count -eq 0) { Write-Log "Ctrl+Alt+C: 前面のエクスプローラー（$fg）が Shell.Windows に見つからない"; return }
        # タブは同じウィンドウを共有するので、表示中のタブのものを選ぶ
        $tab = [PathText]::ActiveTab($fg)
        $w = $wins | Where-Object { [PathText]::TabOf($_) -eq $tab } | Select-Object -First 1
        if (-not $w) {
            # タブが 1 つならそれ。複数あってどれか分からないときは、別のタブの選択をコピーしないよう止める
            if ($wins.Count -gt 1) { throw "表示中のタブが分からない（タブ $($wins.Count) 個）" }
            $w = $wins[0]
        }
        $paths = [string[]]@($w.Document.SelectedItems() | ForEach-Object { $_.Path })
    } catch {
        Write-Log "選択中のファイルを取得できなかった: $_"
        $tray.ShowBalloonTip(5000, '選択中のファイルを取得できなかった', 'もう一度 Ctrl+Alt+C を押す。', $Warning)
        return
    }
    # コントロールパネルなどは ::{…}、ごみ箱は中の名前（$Recycle.Bin\…\$R…）になり、使えるパスにならない。
    # PC やライブラリの中は実際のパスが取れるので止めない
    $bad = @($paths | Where-Object { $_.StartsWith('::') -or $_ -like '*\$Recycle.Bin\*' })
    if ($bad.Count -gt 0) {
        Write-Log "Ctrl+Alt+C: パスにならないものが選ばれている（$($bad[0])）"
        $tray.ShowBalloonTip(5000, 'この場所のパスはコピーできない', 'ごみ箱やコントロールパネルなどは、ファイルのパスにならない。', $Info)
        return
    }
    if ($paths.Count -eq 0) {
        Write-Log 'Ctrl+Alt+C: 何も選ばれていない'
        $tray.ShowBalloonTip(5000, '何も選ばれていない', 'エクスプローラーでファイルやフォルダを選んでから Ctrl+Alt+C を押す。', $Info)
        return
    }
    try {
        [System.Windows.Forms.Clipboard]::SetDataObject([PathText]::Format($paths), $true, 5, 100)
        Write-Log "Ctrl+Alt+C: $($paths.Count) 個のパスをコピーした"
    } catch {
        Write-Log "コピーできなかった（$($paths.Count) 個）: $_"
        $tray.ShowBalloonTip(5000, 'コピーできなかった', 'もう一度 Ctrl+Alt+C を押す。', $Warning)
    }
})

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = [ExplorerHotkey]::MakeIcon([System.Windows.Forms.SystemInformation]::SmallIconSize.Width)
$tray.Text = "$AppName v$Version`n$Usage"  # 63 文字まで

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$nameItem = New-Object System.Windows.Forms.ToolStripMenuItem $AppName
$nameItem.Font = New-Object System.Drawing.Font($nameItem.Font, [System.Drawing.FontStyle]::Bold)
$versionItem = New-Object System.Windows.Forms.ToolStripMenuItem "v$Version"
$hotkeyItem = New-Object System.Windows.Forms.ToolStripMenuItem $Usage
foreach ($mi in $nameItem, $versionItem, $hotkeyItem) { $mi.Enabled = $false }  # 表示だけ
$githubItem = New-Object System.Windows.Forms.ToolStripMenuItem 'GitHub を開く'
$updateItem = New-Object System.Windows.Forms.ToolStripMenuItem '更新を確認'
$logItem = New-Object System.Windows.Forms.ToolStripMenuItem 'ログをコピー'
$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem '終了（自動起動も解除）'
$uninstallItem = New-Object System.Windows.Forms.ToolStripMenuItem 'アンインストール'
foreach ($mi in $nameItem, $versionItem, $hotkeyItem, (New-Object System.Windows.Forms.ToolStripSeparator), $githubItem, $updateItem, $logItem,
    (New-Object System.Windows.Forms.ToolStripSeparator), $exitItem, $uninstallItem) {
    [void]$menu.Items.Add($mi)
}
$tray.ContextMenuStrip = $menu

$githubItem.add_Click({ Start-Process "https://github.com/$Repo" })
# ログを、手がかり（版・Windows・場所）と前のログの終わりも付けてクリップボードに入れる（そのまま Claude に貼る）
$logItem.add_Click({
    $old = Join-Path $appDir 'log.old.txt'
    $text = @("$AppName v$Version PowerShell $($PSVersionTable.PSVersion) Windows $([Environment]::OSVersion.Version) $ps1")
    if (Test-Path $old) { $text += '--- log.old.txt（終わりの 200 行）'; $text += @(Get-Content $old -Encoding UTF8 -Tail 200) }
    if (Test-Path $logFile) { $text += '--- log.txt'; $text += @(Get-Content $logFile -Encoding UTF8) }
    [System.Windows.Forms.Clipboard]::SetDataObject(($text -join "`r`n"), $true, 5, 100)
    $tray.ShowBalloonTip(5000, 'ログをコピーした', '送り先に貼り付ける。', $Info)
})

$script:stopping = $false
$stop = {
    $script:stopping = $true
    $updateTimer.Stop()
    $tray.Visible = $false
    $hk.Dispose()
    [System.Windows.Forms.Application]::Exit()
}

# 終了はファイルとスタートメニューのショートカットを残す（そこから起動し直すと自動起動も登録し直す）
$exitItem.add_Click({
    # インストール先以外で動かしたものは、インストールした分の自動起動に触らない
    if (-not $isInstalled) { Write-Log "終了（$appDir はインストール先でないので、自動起動には触らない）"; & $stop; return }
    Remove-Item $startupLnk -ErrorAction SilentlyContinue
    if (Test-Path $startupLnk) {
        Write-Log "終了（自動起動を外せなかった: $startupLnk）"
        [void](Show-Dialog "自動起動を外せなかった。次のショートカットを手で消す。`n`n$startupLnk" "$AppName の終了" OK Warning)
    } else { Write-Log '終了（自動起動を外した）' }
    & $stop
})

$uninstallItem.add_Click({
    # インストール先でなければ（リポジトリから直接動かしたときなど）消すものがない
    if (-not $isInstalled) {
        Write-Log "アンインストール（$appDir はインストール先でないので何もしない）"
        [void](Show-Dialog "$AppName は $appDir から直接動かしていて、インストールされていないので、消すものがない。" "$AppName のアンインストール" OK Information)
        return
    }
    $answer = Show-Dialog "$AppName をアンインストールする？`n`n自動起動、スタートメニューのショートカット、$appDir（ログも含む）、通知の設定、「設定 > アプリ」の登録をすべて消す。元に戻せない。" `
        "$AppName のアンインストール" YesNo Warning Button2
    # 出している間に終了や更新で止まったときも、ダイアログが閉じられて答えが返るので、止まっていれば何もしない
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes -or $script:stopping) { return }
    # 消すのは uninstall.ps1 に任せる（確認なしの -Yes で起動して、自分は終わる。消せなかったものは uninstall.ps1 が画面で知らせる）
    try {
        if (-not (Test-Path $uninstallPs1)) { throw "$uninstallPs1 が無い" }
        [void](Start-Process $conhost -ArgumentList "$uninstallArgs -Yes" -WorkingDirectory $env:TEMP)
    } catch {
        Write-Log "アンインストールを始められなかった: $_"
        [void](Show-Dialog "アンインストールを始められなかった。消すスクリプトが無いときは「設定 > アプリ」からも消せないので、https://github.com/$Repo の README の「アンインストール」にある、手で消す場所を消す。`n`n$_" "$AppName のアンインストール" OK Warning)
        return
    }
    Write-Log 'アンインストールを uninstall.ps1 に任せて終わる'
    & $stop
})

# ---- 自動更新 ----
# 最新リリースの copathy.ps1 をダウンロードし、中の $Version が今より新しければ返す（なければ $null）。
# 通信の失敗や壊れたファイルは例外にする。$skip の版には、自動の確認では更新しない。
# 画面が固まらないよう、別のスレッドで実行する
$checkUpdate = {
    param($repo, $current, $skip, $manual, $tmpName = 'copathy-update.ps1')
    $ErrorActionPreference = 'Stop'
    # 古い既定（Ssl3, Tls）なら TLS 1.2 を足す。SystemDefault なら Windows に任せる（1.3 も使える）
    if ([Net.ServicePointManager]::SecurityProtocol -ne 'SystemDefault') {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    $release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'copathy' } -TimeoutSec 15
    $tmp = Join-Path $env:TEMP $tmpName
    try {
        Invoke-WebRequest "https://raw.githubusercontent.com/$repo/$($release.tag_name)/copathy.ps1" -OutFile $tmp -UseBasicParsing -TimeoutSec 30
        $text = [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8)
    } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errors)
    $match = [regex]::Match($text, "(?m)^\`$Version = '(\d+\.\d+\.\d+)'")
    if ($errors.Count -gt 0 -or -not $match.Success) { throw 'ダウンロードした copathy.ps1 が壊れている' }
    $latest = [version]$match.Groups[1].Value
    if ($latest -le [version]$current -or (-not $manual -and "$latest" -eq $skip)) { return $null }
    [pscustomobject]@{ Version = "$latest"; Text = $text }
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

# 新しい版に入れ替えて起動し、起動の知らせ（copathyReady）を待つ。来なければ元の版に戻す
$applyUpdate = {
    param($update)
    # ファイルを入れ替えてから画面を閉じる。入れ替えに失敗したら元に戻し、今の版のまま動き続ける
    Copy-Item $ps1 $backupPs1 -Force -ErrorAction Stop
    try {
        [IO.File]::WriteAllText($ps1, $update.Text, (New-Object System.Text.UTF8Encoding $true))
        Set-Content $updatedFlag $update.Version -Encoding UTF8 -ErrorAction Stop
    } catch {
        Copy-Item $backupPs1 $ps1 -Force -ErrorAction SilentlyContinue
        Remove-Item $updatedFlag -ErrorAction SilentlyContinue
        throw
    }
    Write-Log "v$($update.Version) に入れ替えて起動する"
    $script:stopping = $true
    $updateTimer.Stop()
    $tray.Visible = $false
    $hk.Dispose()
    $ready = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, "Local\$($AppName)Ready")
    [void]$ready.Reset()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
    $result = Wait-Ready $ready (Start-App)
    if ($result -ne 'ready') {
        Write-Log "v$($update.Version) が$(if ($result -eq 'exited') { '起動してすぐ終わった' } else { ' 60 秒で起動しなかった' })ので v$Version に戻す"
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
            Where-Object { $_.ProcessId -ne $PID -and "$($_.CommandLine)".IndexOf($ps1, [StringComparison]::OrdinalIgnoreCase) -ge 0 } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        # 戻せないとトレイも無く何も動いていない状態になるので、画面で知らせる
        try {
            Copy-Item $backupPs1 $ps1 -Force -ErrorAction Stop
            Remove-Item $updatedFlag -ErrorAction SilentlyContinue
            Set-Content $skipFile $update.Version -Encoding UTF8 -ErrorAction Stop
            Set-Content $rolledBackFlag $update.Version -Encoding UTF8 -ErrorAction Stop
            # 起動の途中でこちらが終わると巻き込まれて消えることがあるので、知らせが来るまで待つ(来なければもう一度)
            $back = 'exited'
            for ($i = 0; $i -lt 2 -and $back -ne 'ready'; $i++) { [void]$ready.Reset(); $back = Wait-Ready $ready (Start-App) }
            if ($back -ne 'ready') { throw "戻した v$Version が起動しない（$back）" }
        } catch {
            Write-Log "v$Version に戻せなかった: $_"
            [void](Show-Dialog "v$($update.Version) に更新できず、v$Version にも戻せなかった。$AppName をインストールし直す。" "$AppName の更新" OK Error)
        }
    } else {
        # 前の版を消すのは、新しい版の起動を確かめたこちらの役目（新しい版が消すと、待ちが切れて戻すときにぶつかる）
        Remove-Item $backupPs1 -ErrorAction SilentlyContinue
    }
    $ready.Dispose()
    [System.Windows.Forms.Application]::Exit()
}

# $manual は「更新を確認」が押されたとき。このときは更新がなくても結果を通知する
$startCheck = {
    param($manual)
    if ($script:checking) { return }
    $updateItem.Enabled = $false
    $updateItem.Text = '更新を確認中…'
    $skip = if (Test-Path $skipFile) { (Get-Content $skipFile -Encoding UTF8 -TotalCount 1) } else { '' }
    $shellForCheck = [powershell]::Create().AddScript($checkUpdate).AddArgument($Repo).AddArgument($Version).AddArgument($skip).AddArgument($manual).AddArgument("$AppName-update.ps1")
    $script:checking = @{ Shell = $shellForCheck; Async = $shellForCheck.BeginInvoke(); Manual = $manual }
}
$updateItem.add_Click({ & $startCheck $true })

# 起動直後と、そのあと $checkEveryHours ごとに確認する。失敗したら 1 分後にやり直し（最大 5 回）、すべて失敗したら通知する。
# スリープから戻ったときは時刻が過ぎているので、すぐ確認する
$script:nextCheckAt = Get-Date
$script:retries = 5
$script:checking = $null
$updateTimer = New-Object System.Windows.Forms.Timer
$updateTimer.Interval = 1000
$updateTimer.add_Tick({
    if ($quitEvent.WaitOne(0)) { Write-Log 'インストールし直すので終わる'; & $stop; return }
    if ($alreadyRunning.WaitOne(0)) {
        $tray.ShowBalloonTip(5000, "$AppName はもう動いている", $Hint, $Info)
    }
    if ($script:dialogs -gt 0 -or (Test-Uninstalling)) { return }  # ダイアログを出している間や、消すスクリプトが動いている間は更新しない
    # 手動の確認中は待つ（先に予定を消すと、次の自動の確認がなくなる）
    if ($script:nextCheckAt -and (Get-Date) -ge $script:nextCheckAt -and -not $script:checking) {
        $script:nextCheckAt = $null
        & $startCheck $false
    }
    if (-not $script:checking -or -not $script:checking.Async.IsCompleted) { return }

    $manual = $script:checking.Manual
    $update = $null
    $failed = $false
    try { $update = @($script:checking.Shell.EndInvoke($script:checking.Async)) | Where-Object { $_ } | Select-Object -First 1 } catch {
        $failed = $true
        Write-Log "更新を確認できなかった（$(if ($manual) { '手動' } else { "自動、残りのやり直し $script:retries 回" })）: $_"
    }
    $script:checking.Shell.Dispose()
    $script:checking = $null
    $updateItem.Text = '更新を確認'
    $updateItem.Enabled = $true

    if ($update) {
        Write-Log "v$($update.Version) が見つかった"
        try { & $applyUpdate $update } catch {
            Write-Log "v$($update.Version) に入れ替えられなかった: $_"
            $tray.ShowBalloonTip(5000, '更新できなかった', "v$($update.Version) に入れ替えられなかった。v$Version のまま使える。", $Warning)
        }
    } elseif ($failed -and -not $manual -and $script:retries -gt 0) {
        $script:retries--
        $script:nextCheckAt = (Get-Date).AddMinutes(1)
        return
    } elseif ($failed) {
        $tray.ShowBalloonTip(5000, '更新を確認できなかった', 'インターネットの接続を確かめ、あとでトレイの「更新を確認」からやり直す。', $Warning)
    } else {
        Write-Log "最新版（$(if ($manual) { '手動' } else { '自動' })）"
        if ($manual) { $tray.ShowBalloonTip(5000, "$AppName は最新版だ", "v$Version", $Info) }
    }
    if (-not $manual) {
        $script:retries = 5
        $script:nextCheckAt = (Get-Date).AddHours($checkEveryHours)
    }
})
$updateTimer.Start()

$tray.Visible = $true
$hk.Start()

# メニューやタイマーの中のエラーは trap に届かず .NET のエラー画面になるので、ここで受けてログと通知にする
[System.Windows.Forms.Application]::add_ThreadException([System.Threading.ThreadExceptionEventHandler]{
    param($s, $e)
    $err = $e.Exception
    Write-Log "想定外のエラー: $($err.GetType().Name) $($err.Message) $(if ($err.ErrorRecord) { $err.ErrorRecord.InvocationInfo.PositionMessage })"
    $tray.ShowBalloonTip(8000, '想定外のエラーが起きた', "$($err.Message)`n理由はログに残した。", $Warning)
})

# 初めて作ったショートカットは Windows への登録に数秒かかる。登録前に通知すると見出しが ID になるので待つ。
# 待つ間はホットキーが効かないので、新しく作ったときだけにする
if ($startMenuLnkIsNew) {
    $apps = $shell.Namespace('shell:AppsFolder')
    for ($i = 0; $i -lt 20 -and -not $apps.ParseName($appId); $i++) { Start-Sleep -Milliseconds 500 }
}

if (Test-Path $installedFlag) {
    Remove-Item $installedFlag -ErrorAction SilentlyContinue
    Write-Log 'インストールした'
    $tray.ShowBalloonTip(8000, "$AppName をインストールした",
        $Hint, $Info)
} elseif (Test-Path $updatedFlag) {
    $newVersion = (Get-Content $updatedFlag -Encoding UTF8 -TotalCount 1)
    Remove-Item $updatedFlag, $skipFile -ErrorAction SilentlyContinue
    Write-Log "v$newVersion に更新した"
    $tray.ShowBalloonTip(8000, "$AppName を v$newVersion に更新した",
        $Hint, $Info)
} elseif (Test-Path $rolledBackFlag) {
    $failedVersion = (Get-Content $rolledBackFlag -Encoding UTF8 -TotalCount 1)
    Remove-Item $rolledBackFlag -ErrorAction SilentlyContinue
    Write-Log "v$failedVersion から戻した。この版には自動で更新しない"
    $tray.ShowBalloonTip(8000, "v$failedVersion に更新できなかった",
        "新しい版が起動できなかったので、v$Version に戻した。この版には自動では更新しない。", $Warning)
} elseif ($autostartFailed) {
    $tray.ShowBalloonTip(8000, '自動起動を登録できなかった',
        '次にサインインしたとき、copathy が自動で起動しないことがある。もう一度インストールする。', $Warning)
}

# 起動できたことを知らせる（更新直後は前の copathy が待っている）。この処理は消さないこと。
# 画面の処理が回り始めてから知らせる（それより前に落ちる版は、前の copathy が戻す）
$readyTimer = New-Object System.Windows.Forms.Timer
$readyTimer.Interval = 1
$readyTimer.add_Tick({
    $readyTimer.Stop()
    $script:readySignal = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, "Local\$($AppName)Ready")
    [void]$script:readySignal.Set()
    # 更新の途中でなければ、前に残った前の版は要らない（更新の途中なら、待っている前の copathy が消す）
    if (-not $startedByUpdate) { Remove-Item $backupPs1 -ErrorAction SilentlyContinue }
})
$readyTimer.Start()
[System.Windows.Forms.Application]::Run()
$tray.Dispose()
