// imemode.cs — tmux-session-dock IME helper for WSL2 (Windows side).
//
// Reads or sets the conversion mode (한/영, Hiragana/Alphanumeric, ...) of the
// IME attached to the current foreground window. Layout switchers such as
// im-select cannot do this: a Korean Windows setup usually has a single
// "Korean (Microsoft IME)" layout, and 한/영 is a mode inside it.
//
// Build (done by setup.sh; csc.exe ships with every Windows .NET Framework 4.x):
//   C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /optimize
//       /target:exe /out:...\imemode.exe imemode.cs
// Usage:
//   imemode.exe [get]   -> prints "ko" (native/한글) or "en" (alphanumeric)
//   imemode.exe en      -> switch the foreground window's IME to alphanumeric
//   imemode.exe ko      -> switch it to the native (한글) mode
//   imemode.exe push    -> remember the current mode (with the window it
//                          belongs to), then switch to alphanumeric
//   imemode.exe pop     -> restore the remembered mode, but only if the same
//                          window is still in the foreground (never touch
//                          another application the user Alt-Tabbed to)
//
// push/pop state: %TEMP%\tmux-session-dock-imemode.state ("<hwnd> <mode>").
// A push while a state for the SAME window is pending does not overwrite it
// (sidebar focus regained after an Alt-Tab must not lose the original mode);
// a state left behind by another window is stale and is replaced.
using System;
using System.IO;
using System.Runtime.InteropServices;

static class ImeMode
{
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("imm32.dll")]  static extern IntPtr ImmGetDefaultIMEWnd(IntPtr hwnd);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    const uint WM_IME_CONTROL = 0x0283;
    const int IMC_GETCONVERSIONMODE = 0x0001;
    const int IMC_SETCONVERSIONMODE = 0x0002;
    const int IME_CMODE_NATIVE = 0x0001;

    static string StatePath()
    {
        return Path.Combine(Path.GetTempPath(), "tmux-session-dock-imemode.state");
    }

    static long GetMode(IntPtr ime)
    {
        return (long)SendMessage(ime, WM_IME_CONTROL, (IntPtr)IMC_GETCONVERSIONMODE, IntPtr.Zero);
    }

    static void SetNative(IntPtr ime, bool native)
    {
        SendMessage(ime, WM_IME_CONTROL, (IntPtr)IMC_SETCONVERSIONMODE, (IntPtr)(native ? IME_CMODE_NATIVE : 0));
    }

    static int Main(string[] args)
    {
        IntPtr hwnd = GetForegroundWindow();
        IntPtr ime = ImmGetDefaultIMEWnd(hwnd);
        if (ime == IntPtr.Zero) { Console.Error.WriteLine("imemode: no IME window on the foreground window"); return 2; }

        string verb = args.Length == 0 ? "get" : args[0];
        bool native = (GetMode(ime) & IME_CMODE_NATIVE) != 0;

        switch (verb)
        {
            case "get":
                Console.Out.Write(native ? "ko\n" : "en\n");   // LF only: callers are WSL shells
                return 0;
            case "en":
                SetNative(ime, false);
                return 0;
            case "ko":
                SetNative(ime, true);
                return 0;
            case "push":
            {
                string path = StatePath();
                bool keep = false;
                try
                {
                    if (File.Exists(path))
                    {
                        string[] parts = File.ReadAllText(path).Trim().Split(' ');
                        keep = parts.Length == 2 && parts[0] == hwnd.ToInt64().ToString();
                    }
                    if (!keep)
                        File.WriteAllText(path, hwnd.ToInt64() + " " + (native ? "ko" : "en"));
                }
                catch (Exception) { /* state is best effort; the switch below still happens */ }
                SetNative(ime, false);
                return 0;
            }
            case "pop":
            {
                string path = StatePath();
                try
                {
                    if (!File.Exists(path)) return 0;
                    string[] parts = File.ReadAllText(path).Trim().Split(' ');
                    if (parts.Length != 2) { File.Delete(path); return 0; }
                    if (parts[0] != hwnd.ToInt64().ToString()) return 0;   // another app is in front: leave it alone
                    File.Delete(path);
                    SetNative(ime, parts[1] == "ko");
                }
                catch (Exception) { }
                return 0;
            }
            default:
                Console.Error.WriteLine("usage: imemode.exe [get|en|ko|push|pop]");
                return 1;
        }
    }
}
