// copathy - エクスプローラーで選択中のファイル/フォルダのパスを Ctrl+Alt+C でコピーする常駐ツール
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("copathy")]
[assembly: AssemblyProduct("copathy")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

namespace copathy
{
    static class Program
    {
        public const string AppName = "copathy";
        public const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

        [STAThread]
        static void Main()
        {
            bool created;
            using (var mutex = new Mutex(true, @"Local\copathy_SingleInstance", out created))
            {
                if (!created) return; // 二重起動防止
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                SetAutoStart(true);
                Application.Run(new TrayContext());
            }
        }

        public static void SetAutoStart(bool enable)
        {
            try
            {
                using (var key = Registry.CurrentUser.OpenSubKey(RunKey, true))
                {
                    if (key == null) return;
                    if (enable) key.SetValue(AppName, "\"" + Application.ExecutablePath + "\"");
                    else if (key.GetValue(AppName) != null) key.DeleteValue(AppName);
                }
            }
            catch { }
        }

        public static string Version
        {
            get
            {
                var v = Assembly.GetExecutingAssembly().GetName().Version;
                return v.Major + "." + v.Minor + "." + v.Build;
            }
        }
    }

    class TrayContext : ApplicationContext
    {
        readonly NotifyIcon tray;
        readonly Control invoker;
        readonly KeyboardHook hook;

        public TrayContext()
        {
            invoker = new Control();
            invoker.CreateControl();

            var menu = new ContextMenuStrip();
            menu.Items.Add(new ToolStripMenuItem(Program.AppName) { Enabled = false });
            menu.Items.Add(new ToolStripMenuItem("v" + Program.Version) { Enabled = false });
            menu.Items.Add(new ToolStripMenuItem("Ctrl+Alt+C でパスをコピー") { Enabled = false });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(new ToolStripMenuItem("終了（自動起動も解除）", null, (s, e) => ExitApp()));

            tray = new NotifyIcon
            {
                Icon = MakeIcon(),
                Text = Program.AppName + " v" + Program.Version + "\nCtrl+Alt+C でパスをコピー",
                ContextMenuStrip = menu,
                Visible = true,
            };

            hook = new KeyboardHook(() => invoker.BeginInvoke((Action)CopySelection));
        }

        void CopySelection()
        {
            try
            {
                string text = ExplorerSelection.BuildText();
                if (string.IsNullOrEmpty(text)) return;
                for (int i = 0; i < 5; i++)
                {
                    try { Clipboard.SetText(text); return; }
                    catch (ExternalException) { Thread.Sleep(50); }
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine(ex);
            }
        }

        void ExitApp()
        {
            Program.SetAutoStart(false);
            hook.Dispose();
            tray.Visible = false;
            tray.Dispose();
            ExitThread();
        }

        static Icon MakeIcon()
        {
            using (var bmp = new Bitmap(32, 32))
            {
                using (var g = Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.Clear(Color.Transparent);
                    // フォルダ
                    using (var b = new SolidBrush(Color.FromArgb(255, 200, 70)))
                    {
                        g.FillRectangle(b, 2, 6, 12, 5);
                        g.FillRectangle(b, 2, 9, 28, 19);
                    }
                    // パスっぽい線
                    using (var p = new Pen(Color.FromArgb(40, 90, 200), 3))
                    {
                        g.DrawLine(p, 8, 15, 24, 15);
                        g.DrawLine(p, 8, 21, 19, 21);
                    }
                }
                IntPtr h = bmp.GetHicon();
                return Icon.FromHandle(h);
            }
        }
    }

    // 低レベルキーボードフック: エクスプローラーが前面のときだけ Ctrl+Alt+C を横取りする
    class KeyboardHook : IDisposable
    {
        const int WH_KEYBOARD_LL = 13;
        const int WM_KEYDOWN = 0x0100, WM_SYSKEYDOWN = 0x0104;
        const int VK_C = 0x43, VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12, VK_LWIN = 0x5B, VK_RWIN = 0x5C;

        delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);
        readonly HookProc proc; // GC 防止のため保持
        readonly IntPtr handle;
        readonly Action onHotkey;

        public KeyboardHook(Action onHotkey)
        {
            this.onHotkey = onHotkey;
            proc = Callback;
            handle = SetWindowsHookEx(WH_KEYBOARD_LL, proc, GetModuleHandle(null), 0);
        }

        IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam)
        {
            if (nCode >= 0 && (wParam == (IntPtr)WM_KEYDOWN || wParam == (IntPtr)WM_SYSKEYDOWN))
            {
                int vk = Marshal.ReadInt32(lParam);
                if (vk == VK_C && Down(VK_CONTROL) && Down(VK_MENU) && !Down(VK_SHIFT)
                    && !Down(VK_LWIN) && !Down(VK_RWIN) && ExplorerSelection.IsExplorerForeground())
                {
                    onHotkey();
                    return (IntPtr)1;
                }
            }
            return CallNextHookEx(handle, nCode, wParam, lParam);
        }

        static bool Down(int vk) { return (GetAsyncKeyState(vk) & 0x8000) != 0; }

        public void Dispose() { if (handle != IntPtr.Zero) UnhookWindowsHookEx(handle); }

        [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);
        [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hhk);
        [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vKey);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);
    }

    static class ExplorerSelection
    {
        public static bool IsExplorerForeground()
        {
            var sb = new StringBuilder(64);
            GetClassName(GetForegroundWindow(), sb, sb.Capacity);
            string c = sb.ToString();
            return c == "CabinetWClass" || c == "ExploreWClass";
        }

        public static string BuildText()
        {
            IntPtr fg = GetForegroundWindow();
            // Windows 11 のタブ: 先頭の ShellTabWindowClass がアクティブタブ
            IntPtr activeTab = FindWindowEx(fg, IntPtr.Zero, "ShellTabWindowClass", null);

            Type t = Type.GetTypeFromProgID("Shell.Application");
            dynamic shell = Activator.CreateInstance(t);
            try
            {
                dynamic windows = shell.Windows();
                int count = windows.Count;
                for (int i = 0; i < count; i++)
                {
                    dynamic w = windows.Item(i);
                    if (w == null) continue;
                    try
                    {
                        if (new IntPtr((long)w.HWND) != fg) continue;
                        if (activeTab != IntPtr.Zero && GetTabHandle((object)w) != activeTab) continue;
                        return Format(w.Document);
                    }
                    catch { }
                    finally { Marshal.ReleaseComObject(w); }
                }
            }
            finally { Marshal.ReleaseComObject(shell); }
            return null;
        }

        static string Format(dynamic doc)
        {
            var items = new List<string>();
            foreach (dynamic item in doc.SelectedItems())
            {
                string p = item.Path;
                if (!string.IsNullOrEmpty(p)) items.Add(p);
            }

            if (items.Count == 0) return null;

            // 親フォルダごとにまとめる。2つ以上あるグループは「親フォルダ + 名前の一覧」、
            // 1つだけのものは最後にフルパスでまとめて出す。ブロック間は空行で区切る。
            var groups = items
                .GroupBy(p => Path.GetDirectoryName(p) ?? "", StringComparer.OrdinalIgnoreCase)
                .OrderBy(g => g.Key, new LogicalComparer())
                .ToList();

            var blocks = new List<string>();
            var singles = new List<string>();
            foreach (var g in groups)
            {
                if (g.Count() == 1 || g.Key == "") { singles.AddRange(g); continue; }
                var sb = new StringBuilder(AddSlash(g.Key));
                foreach (var p in SortItems(g))
                {
                    string name = Path.GetFileName(p);
                    sb.Append("\r\n").Append(IsDir(p) ? name + "\\" : name);
                }
                blocks.Add(sb.ToString());
            }
            if (singles.Count > 0)
                blocks.Add(string.Join("\r\n", SortItems(singles).Select(p => IsDir(p) ? AddSlash(p) : p)));

            return string.Join("\r\n\r\n", blocks);
        }

        // フォルダが先、名前は数字を数として比較（file2 < file10）
        static IEnumerable<string> SortItems(IEnumerable<string> paths)
        {
            return paths.OrderBy(p => IsDir(p) ? 0 : 1).ThenBy(p => p, new LogicalComparer());
        }

        // zip は Shell 上 IsFolder=true になるため実ディレクトリで判定
        static bool IsDir(string p) { try { return Directory.Exists(p); } catch { return false; } }
        static string AddSlash(string p) { return p.EndsWith("\\") ? p : p + "\\"; }

        class LogicalComparer : IComparer<string>
        {
            public int Compare(string a, string b) { return StrCmpLogicalW(a, b); }
        }

        static IntPtr GetTabHandle(object browser)
        {
            try
            {
                var sp = (IServiceProvider)browser;
                Guid sid = new Guid("4C96BE40-915C-11CF-99D3-00AA004AE837"); // SID_STopLevelBrowser
                Guid iid = typeof(IShellBrowser).GUID;
                object o;
                if (sp.QueryService(ref sid, ref iid, out o) != 0 || o == null) return IntPtr.Zero;
                IntPtr h;
                ((IShellBrowser)o).GetWindow(out h);
                Marshal.ReleaseComObject(o);
                return h;
            }
            catch { return IntPtr.Zero; }
        }

        [ComImport, Guid("6D5140C1-7436-11CE-8034-00AA006009FA"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IServiceProvider
        {
            [PreserveSig] int QueryService(ref Guid guidService, ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object ppvObject);
        }

        [ComImport, Guid("000214E2-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IShellBrowser
        {
            void GetWindow(out IntPtr phwnd); // IOleWindow::GetWindow
        }

        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
        [DllImport("shlwapi.dll", CharSet = CharSet.Unicode)] static extern int StrCmpLogicalW(string a, string b);
    }
}
