# copathy: エクスプローラーで Ctrl+Alt+C を押すと、選択中のファイル・フォルダのパスをまとめてコピーする。
# トレイに常駐し、自動起動を登録する。起動時と「更新を確認」で GitHub の最新リリースに更新する。
$Version = '2.2.0'
$AppName = 'copathy'
$Repo = 'ogura-ryoya/copathy'
$checkEveryHours = 24  # 起動時のほか、動いている間もこの時間ごとに更新を確認する（スリープで使い続ける PC にも届くように）

$ps1 = $MyInvocation.MyCommand.Path
$appDir = Split-Path $ps1
$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) "$AppName.lnk"
$startMenuLnk = Join-Path ([Environment]::GetFolderPath('Programs')) "$AppName.lnk"
$icoPath = Join-Path $appDir "$AppName.ico"
$appId = "ogura-ryoya.$AppName"  # 通知でほかの PowerShell 製ツールと区別する ID
$installedFlag = Join-Path $appDir 'installed.flag'    # インストール直後
$updatedFlag = Join-Path $appDir 'updated.flag'        # 更新直後（中身は新しい版）
$rolledBackFlag = Join-Path $appDir 'rolledback.flag'  # 更新した版が起動できず戻した（中身はその版）
$skipFile = Join-Path $appDir 'skip-version.txt'       # 自動では更新しない版
$backupPs1 = Join-Path $appDir 'copathy.backup.ps1'    # 更新前の版
$logFile = Join-Path $appDir 'log.txt'                 # 問題があったときにユーザーが丸ごと Claude に貼る。100KB で log.old.txt に回す

function Write-Log($text) {
    try {
        if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 100KB) { Move-Item $logFile (Join-Path $appDir 'log.old.txt') -Force }
        Add-Content $logFile "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$PID] $($text -replace '\s*\r?\n\s*', ' | ')" -Encoding UTF8
    } catch {}
}
trap { Write-Log "想定外のエラーで止まった: $_ $($_.InvocationInfo.PositionMessage)"; break }

$conhost = "$env:WINDIR\System32\conhost.exe"
$launchArgs = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ps1`""

function New-Shortcut($path) {
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($path)
    $s.TargetPath = $conhost
    $s.Arguments = $launchArgs
    $s.IconLocation = "$icoPath,0"
    $s.WindowStyle = 7
    $s.Save()
}

function Start-Copathy { Start-Process $conhost -ArgumentList $launchArgs }

# 裏に隠れないよう、最前面の見えないウィンドウを親にして出す
function Show-Dialog($text, $title, [System.Windows.Forms.MessageBoxButtons]$buttons, [System.Windows.Forms.MessageBoxIcon]$icon) {
    $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true; ShowInTaskbar = $false; Opacity = 0 }
    $owner.Show()
    $owner.Activate()
    try { [System.Windows.Forms.MessageBox]::Show($owner, $text, $title, $buttons, $icon) } finally { $owner.Dispose() }
}

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
if (-not $acquired) { Write-Log 'すでに起動しているので終わる'; exit }
Write-Log "起動 v$Version PowerShell $($PSVersionTable.PSVersion) Windows $([Environment]::OSVersion.Version) $ps1"

# v1 の exe 版が使っていたレジストリの自動起動を消す
Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $AppName -ErrorAction SilentlyContinue

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

    // ZIP は Shell 上フォルダ扱いになるので、実際のフォルダかで判定する
    static bool IsDir(string p) { try { return Directory.Exists(p); } catch { return false; } }
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
try { New-Shortcut $startupLnk } catch { $autostartFailed = $true; Write-Log "自動起動を登録できなかった: $_" }

# 通知の見出しにアプリの名前とアイコンを出すため、同じ ID のショートカットをスタートメニューに作る（画面を作る前に行う）
$startMenuLnkIsNew = -not (Test-Path $startMenuLnk)
try {
    New-Shortcut $startMenuLnk
    [AppUserModel]::SetAppId($startMenuLnk, $appId)
} catch { Write-Log "スタートメニューのショートカットを作れなかった: $_" }

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
        Write-Log "選択中のファイルを取得できなかった: $_"
        $tray.ShowBalloonTip(5000, '選択中のファイルを取得できなかった', 'もう一度 Ctrl+Alt+C を押す。', $Warning)
        return
    }
    if ($paths.Count -eq 0) { return }
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
$logItem = New-Object System.Windows.Forms.ToolStripMenuItem 'ログを開く'
$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem '終了（自動起動も解除）'
$uninstallItem = New-Object System.Windows.Forms.ToolStripMenuItem 'アンインストール'
foreach ($mi in $nameItem, $versionItem, $hotkeyItem, (New-Object System.Windows.Forms.ToolStripSeparator), $githubItem, $updateItem, $logItem,
    (New-Object System.Windows.Forms.ToolStripSeparator), $exitItem, $uninstallItem) {
    [void]$menu.Items.Add($mi)
}
$tray.ContextMenuStrip = $menu

$githubItem.add_Click({ Start-Process "https://github.com/$Repo" })
$logItem.add_Click({ Start-Process notepad.exe "`"$logFile`"" })

$stop = {
    $updateTimer.Stop()
    $tray.Visible = $false
    $hk.Dispose()
    [System.Windows.Forms.Application]::Exit()
}

# 終了はファイルとスタートメニューのショートカットを残す（そこから起動し直すと自動起動も登録し直す）
$exitItem.add_Click({
    Remove-Item $startupLnk -ErrorAction SilentlyContinue
    if (Test-Path $startupLnk) {
        Write-Log "終了（自動起動を外せなかった: $startupLnk）"
        [void](Show-Dialog "自動起動を外せなかった。次のショートカットを手で消す。`n`n$startupLnk" "$AppName の終了" OK Warning)
    } else { Write-Log '終了（自動起動を外した）' }
    & $stop
})

$uninstallItem.add_Click({
    $answer = Show-Dialog "$AppName をアンインストールする？`n`n自動起動、スタートメニューのショートカット、$appDir（ログも含む）をすべて消す。元に戻せない。" `
        "$AppName のアンインストール" YesNo Warning
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $targets = @($startupLnk, $startMenuLnk)
    Remove-Item $targets -ErrorAction SilentlyContinue
    # インストール先でなければ（リポジトリから直接動かしたときなど）フォルダは消さない
    if ($appDir -eq (Join-Path $env:LOCALAPPDATA $AppName)) {
        [Environment]::CurrentDirectory = $env:TEMP
        Set-Location $env:TEMP
        Remove-Item $appDir -Recurse -Force -ErrorAction SilentlyContinue
        $targets += $appDir
    } else { Write-Log "アンインストール（$appDir はインストール先でないので消さない）" }
    # 消せなかったものは知らせる（フォルダが残っていればログも残っている）
    $left = @($targets | Where-Object { Test-Path $_ })
    if ($left.Count -gt 0) {
        Write-Log "アンインストールで消せなかった: $($left -join ', ')"
        [void](Show-Dialog "消せなかったものがある。$AppName は終了するので、次のものを手で消す。`n`n$($left -join "`n")" "$AppName のアンインストール" OK Warning)
    }
    & $stop
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
    # ファイルを入れ替えてから画面を閉じる。入れ替えに失敗したら元に戻し、今の版のまま動き続ける
    try {
        Copy-Item $ps1 $backupPs1 -Force -ErrorAction Stop
        try {
            Copy-Item $update.Path $ps1 -Force -ErrorAction Stop
            Set-Content $updatedFlag $update.Version -Encoding UTF8 -ErrorAction Stop
        } catch {
            Copy-Item $backupPs1 $ps1 -Force -ErrorAction SilentlyContinue
            Remove-Item $updatedFlag -ErrorAction SilentlyContinue
            throw
        }
    } finally { Remove-Item $update.Path -ErrorAction SilentlyContinue }
    Write-Log "v$($update.Version) に入れ替えて起動する"
    $updateTimer.Stop()
    $tray.Visible = $false
    $hk.Dispose()
    $ready = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, 'Local\copathyReady')
    [void]$ready.Reset()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
    Start-Copathy
    if (-not $ready.WaitOne(60000)) {
        Write-Log "v$($update.Version) が 60 秒で起動しなかったので v$Version に戻す"
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
            Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*\copathy.ps1*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        # 戻せないとトレイも無く何も動いていない状態になるので、画面で知らせる
        try {
            Copy-Item $backupPs1 $ps1 -Force -ErrorAction Stop
            Remove-Item $updatedFlag -ErrorAction SilentlyContinue
            Set-Content $skipFile $update.Version -Encoding UTF8 -ErrorAction Stop
            Set-Content $rolledBackFlag $update.Version -Encoding UTF8 -ErrorAction Stop
            Start-Copathy
        } catch {
            Write-Log "v$Version に戻せなかった: $_"
            [void](Show-Dialog "v$($update.Version) に更新できず、v$Version にも戻せなかった。$AppName をインストールし直す。" "$AppName の更新" OK Error)
        }
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

# 起動直後と、そのあと $checkEveryHours ごとに確認する。失敗したら 1 分後にやり直し（最大 5 回）、すべて失敗したら通知する。
# スリープから戻ったときは時刻が過ぎているので、すぐ確認する
$script:nextCheckAt = Get-Date
$script:retries = 5
$script:checking = $null
$updateTimer = New-Object System.Windows.Forms.Timer
$updateTimer.Interval = 1000
$updateTimer.add_Tick({
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

# 起動できたことを知らせる（更新直後は前の copathy が待っている）。この処理は消さないこと
$readySignal = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, 'Local\copathyReady')
[void]$readySignal.Set()
Remove-Item $backupPs1 -ErrorAction SilentlyContinue

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
        'エクスプローラーでファイルやフォルダを選んで Ctrl+Alt+C を押すと、パスをコピーできる。', $Info)
} elseif (Test-Path $updatedFlag) {
    $newVersion = (Get-Content $updatedFlag -Encoding UTF8 -TotalCount 1)
    Remove-Item $updatedFlag, $skipFile -ErrorAction SilentlyContinue
    Write-Log "v$newVersion に更新した"
    $tray.ShowBalloonTip(8000, "$AppName を v$newVersion に更新した",
        '引き続き、エクスプローラーで Ctrl+Alt+C を押すとパスをコピーできる。', $Info)
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
[System.Windows.Forms.Application]::Run()
$tray.Dispose()
