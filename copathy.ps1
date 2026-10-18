# copathy: エクスプローラーで Ctrl+Alt+C を押すと、選択中のファイル・フォルダのパスをまとめてコピーする。
# トレイに常駐し、自動起動を登録する。起動時と「更新を確認」で GitHub の最新リリースに更新する。
$Version = '2.0.0'
$AppName = 'copathy'
$Repo = 'ogura-ryoya/copathy'

$ps1 = $MyInvocation.MyCommand.Path
$appDir = Split-Path $ps1
$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) "$AppName.lnk"
$installedFlag = Join-Path $appDir 'installed.flag'    # インストール直後
$updatedFlag = Join-Path $appDir 'updated.flag'        # 更新直後（中身は新しい版）
$rolledBackFlag = Join-Path $appDir 'rolledback.flag'  # 更新した版が起動できず戻した（中身はその版）
$skipFile = Join-Path $appDir 'skip-version.txt'       # 自動では更新しない版
$backupPs1 = Join-Path $appDir 'copathy.backup.ps1'    # 更新前の版

$conhost = "$env:WINDIR\System32\conhost.exe"
$launchArgs = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ps1`""

function New-Shortcut($path) {
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($path)
    $s.TargetPath = $conhost
    $s.Arguments = $launchArgs
    $s.WindowStyle = 7
    $s.Save()
}

function Start-Copathy { Start-Process $conhost -ArgumentList $launchArgs }

# 画面なしの起動（conhost --headless 経由）でなければ、画面なしで起動し直す
$parentId = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId
if ((Get-CimInstance Win32_Process -Filter "ProcessId=$parentId").Name -ne 'conhost.exe') {
    Start-Copathy
    return
}

$mutex = New-Object System.Threading.Mutex($false, 'Local\copathy')
try {
    $acquired = $mutex.WaitOne(0)
} catch {
    # 前の copathy が強制終了されていると AbandonedMutexException になるが、所有権は得ている
    $ex = $_.Exception
    $acquired = ($ex -is [System.Threading.AbandonedMutexException]) -or ($ex.InnerException -is [System.Threading.AbandonedMutexException])
}
if (-not $acquired) { exit }  # すでに起動している

# v1 の exe 版が使っていたレジストリの自動起動を消す
Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $AppName -ErrorAction SilentlyContinue

$autostartFailed = $false
try { New-Shortcut $startupLnk } catch { $autostartFailed = $true }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
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
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint vk);
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
    bool registered;
    public event EventHandler Pressed;

    public ExplorerHotkey() {
        CreateHandle(new CreateParams());
        proc = (h, e, hwnd, o, c, t, tm) => Update(hwnd);
        hook = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, proc, 0, 0, 0);
        Update(GetForegroundWindow());
    }

    static bool IsExplorer(IntPtr h) {
        var s = new StringBuilder(64);
        GetClassName(h, s, 64);
        return s.ToString() == "CabinetWClass";
    }

    void Update(IntPtr fg) {
        bool want = IsExplorer(fg);
        if (want && !registered) registered = RegisterHotKey(Handle, 1, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, VK_C);
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
    public static Icon MakeIcon(int size) {
        using (var b = new Bitmap(size, size)) {
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
            return Icon.FromHandle(b.GetHicon());
        }
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

    // ZIP は Shell 上フォルダ扱いになるので、実際のフォルダかで判定する
    static bool IsDir(string p) { try { return Directory.Exists(p); } catch { return false; } }
    static string AddSlash(string p) { return p.EndsWith("\\") ? p : p + "\\"; }

    class Logical : IComparer<string> {
        public int Compare(string a, string b) { return StrCmpLogicalW(a, b); }
    }
}
"@

[ExplorerHotkey]::EnableDpiAwareness()

$shell = New-Object -ComObject Shell.Application
$hk = New-Object ExplorerHotkey
$Warning = [System.Windows.Forms.ToolTipIcon]::Warning
$Info = [System.Windows.Forms.ToolTipIcon]::Info

$hk.add_Pressed({
    try {
        $fg = [ExplorerHotkey]::Foreground()
        $wins = @($shell.Windows() | Where-Object { $_.HWND -eq $fg.ToInt64() })
        if ($wins.Count -eq 0) { return }
        # タブは同じウィンドウを共有するので、表示中のタブのものを選ぶ
        $tab = [PathText]::ActiveTab($fg)
        $w = $wins | Where-Object { [PathText]::TabOf($_) -eq $tab } | Select-Object -First 1
        if (-not $w) { $w = $wins[0] }
        $paths = [string[]]@($w.Document.SelectedItems() | ForEach-Object { $_.Path })
    } catch {
        $tray.ShowBalloonTip(5000, '選択中のファイルを取得できませんでした', 'もう一度 Ctrl+Alt+C を押してください。', $Warning)
        return
    }
    if ($paths.Count -eq 0) { return }
    try {
        [System.Windows.Forms.Clipboard]::SetDataObject([PathText]::Format($paths), $true, 5, 100)
    } catch {
        $tray.ShowBalloonTip(5000, 'コピーできませんでした', 'もう一度 Ctrl+Alt+C を押してください。', $Warning)
    }
})

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = [ExplorerHotkey]::MakeIcon([System.Windows.Forms.SystemInformation]::SmallIconSize.Width)
$Usage = 'Ctrl+Alt+C でパスをコピー'
$tray.Text = "$AppName v$Version`n$Usage"  # 63 文字まで

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$nameItem = New-Object System.Windows.Forms.ToolStripMenuItem $AppName
$nameItem.Font = New-Object System.Drawing.Font($nameItem.Font, [System.Drawing.FontStyle]::Bold)
$versionItem = New-Object System.Windows.Forms.ToolStripMenuItem "v$Version"
$hotkeyItem = New-Object System.Windows.Forms.ToolStripMenuItem $Usage
foreach ($mi in $nameItem, $versionItem, $hotkeyItem) { $mi.Enabled = $false }  # 表示だけ
$githubItem = New-Object System.Windows.Forms.ToolStripMenuItem 'GitHub を開く'
$updateItem = New-Object System.Windows.Forms.ToolStripMenuItem '更新を確認'
$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem '終了（自動起動も解除）'
foreach ($mi in $nameItem, $versionItem, $hotkeyItem, (New-Object System.Windows.Forms.ToolStripSeparator), $githubItem, $updateItem, $exitItem) {
    [void]$menu.Items.Add($mi)
}
$tray.ContextMenuStrip = $menu

$githubItem.add_Click({ Start-Process "https://github.com/$Repo" })

$exitItem.add_Click({
    Remove-Item $startupLnk -ErrorAction SilentlyContinue
    $updateTimer.Stop()
    $tray.Visible = $false
    $hk.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

# ---- 自動更新 ----
# 最新リリースの copathy.ps1 をダウンロードし、中の $Version が今より新しければ返す（なければ $null）。
# 通信の失敗や壊れたファイルは例外にする。$skip の版には、自動の確認では更新しない。
# 画面が固まらないよう、別のスレッドで実行する
$checkUpdate = {
    param($repo, $current, $skip, $manual)
    $ErrorActionPreference = 'Stop'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'copathy' } -TimeoutSec 15
    $tmp = Join-Path $env:TEMP 'copathy-update.ps1'
    Invoke-WebRequest "https://raw.githubusercontent.com/$repo/$($release.tag_name)/copathy.ps1" -OutFile $tmp -UseBasicParsing -TimeoutSec 30

    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($tmp, [ref]$null, [ref]$errors)
    $match = [regex]::Match([IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8), "(?m)^\`$Version = '(\d+\.\d+\.\d+)'")
    if ($errors.Count -gt 0 -or -not $match.Success) {
        Remove-Item $tmp -ErrorAction SilentlyContinue
        throw 'ダウンロードした copathy.ps1 が壊れている'
    }
    $latest = [version]$match.Groups[1].Value
    if ($latest -le [version]$current -or (-not $manual -and "$latest" -eq $skip)) {
        Remove-Item $tmp -ErrorAction SilentlyContinue
        return $null
    }
    [pscustomobject]@{ Version = "$latest"; Path = $tmp }
}

# 新しい版に入れ替えて起動し、起動の知らせ（copathyReady）を 60 秒待つ。来なければ元の版に戻す
$applyUpdate = {
    param($update)
    Copy-Item $ps1 $backupPs1 -Force
    Copy-Item $update.Path $ps1 -Force
    Remove-Item $update.Path -ErrorAction SilentlyContinue
    Set-Content $updatedFlag $update.Version -Encoding UTF8
    $updateTimer.Stop()
    $tray.Visible = $false
    $hk.Dispose()
    $ready = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, 'Local\copathyReady')
    [void]$ready.Reset()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
    Start-Copathy
    if (-not $ready.WaitOne(60000)) {
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
            Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*\copathy.ps1*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Copy-Item $backupPs1 $ps1 -Force
        Remove-Item $updatedFlag -ErrorAction SilentlyContinue
        Set-Content $skipFile $update.Version -Encoding UTF8
        Set-Content $rolledBackFlag $update.Version -Encoding UTF8
        Start-Copathy
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
    $shellForCheck = [powershell]::Create().AddScript($checkUpdate).AddArgument($Repo).AddArgument($Version).AddArgument($skip).AddArgument($manual)
    $script:checking = @{ Shell = $shellForCheck; Async = $shellForCheck.BeginInvoke(); Manual = $manual }
}
$updateItem.add_Click({ & $startCheck $true })

# 起動直後に確認する。失敗したら 1 分後にやり直し（最大 5 回）、すべて失敗したら通知する
$script:startupCheckAt = Get-Date
$script:startupRetries = 5
$script:checking = $null
$updateTimer = New-Object System.Windows.Forms.Timer
$updateTimer.Interval = 1000
$updateTimer.add_Tick({
    if ($script:startupCheckAt -and (Get-Date) -ge $script:startupCheckAt) {
        $script:startupCheckAt = $null
        & $startCheck $false
    }
    if (-not $script:checking -or -not $script:checking.Async.IsCompleted) { return }

    $manual = $script:checking.Manual
    $update = $null
    $failed = $false
    try { $update = @($script:checking.Shell.EndInvoke($script:checking.Async)) | Where-Object { $_ } | Select-Object -First 1 } catch { $failed = $true }
    $script:checking.Shell.Dispose()
    $script:checking = $null
    $updateItem.Text = '更新を確認'
    $updateItem.Enabled = $true

    if ($update) {
        try { & $applyUpdate $update } catch {
            $tray.ShowBalloonTip(5000, '更新できませんでした', "v$($update.Version) に入れ替えられませんでした。v$Version のまま使えます。", $Warning)
        }
    } elseif ($failed -and -not $manual -and $script:startupRetries -gt 0) {
        $script:startupRetries--
        $script:startupCheckAt = (Get-Date).AddMinutes(1)
    } elseif ($failed) {
        $tray.ShowBalloonTip(5000, '更新を確認できませんでした', 'インターネットの接続を確認して、あとでトレイの「更新を確認」からもう一度お試しください。', $Warning)
    } elseif ($manual) {
        $tray.ShowBalloonTip(5000, "$AppName は最新版です", "v$Version", $Info)
    }
})
$updateTimer.Start()

$tray.Visible = $true

# 起動できたことを知らせる（更新直後は前の copathy が待っている）。この処理は消さないこと
$readySignal = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, 'Local\copathyReady')
[void]$readySignal.Set()
Remove-Item $backupPs1 -ErrorAction SilentlyContinue

if (Test-Path $installedFlag) {
    Remove-Item $installedFlag -ErrorAction SilentlyContinue
    $tray.ShowBalloonTip(8000, "$AppName をインストールしました",
        'エクスプローラーでファイルやフォルダを選んで Ctrl+Alt+C を押すと、パスをコピーできます。', $Info)
} elseif (Test-Path $updatedFlag) {
    $newVersion = (Get-Content $updatedFlag -Encoding UTF8 -TotalCount 1)
    Remove-Item $updatedFlag, $skipFile -ErrorAction SilentlyContinue
    $tray.ShowBalloonTip(8000, "$AppName を v$newVersion に更新しました",
        '引き続き、エクスプローラーで Ctrl+Alt+C を押すとパスをコピーできます。', $Info)
} elseif (Test-Path $rolledBackFlag) {
    $failedVersion = (Get-Content $rolledBackFlag -Encoding UTF8 -TotalCount 1)
    Remove-Item $rolledBackFlag -ErrorAction SilentlyContinue
    $tray.ShowBalloonTip(8000, "v$failedVersion に更新できませんでした",
        "新しい版が起動できなかったため、v$Version に戻しました。この版には自動では更新しません。", $Warning)
} elseif ($autostartFailed) {
    $tray.ShowBalloonTip(8000, '自動起動を登録できませんでした',
        '次にサインインしたとき、copathy が自動で起動しないことがあります。もう一度インストールしてください。', $Warning)
}
[System.Windows.Forms.Application]::Run()
$tray.Dispose()
