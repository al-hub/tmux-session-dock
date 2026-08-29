// imemode.cs — tmux-session-dock IME helper for WSL2 (Windows side).
//
// Reads or sets the conversion mode (한/영, Hiragana/Alphanumeric, ...) of the
// IME attached to the current foreground window. Layout switchers such as
// im-select cannot do this: a Korean Windows setup usually has a single
// "Korean (Microsoft IME)" layout, and 한/영 is a mode inside it.
//
// Build (done by setup.sh; csc.exe ships with every Windows .NET Framework 4.x):
//   C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /optimize
//       /target:exe /out:%USERPROFILE%\...\imemode.exe imemode.cs
// Usage:
//   imemode.exe          -> prints "ko" (native/한글) or "en" (alphanumeric)
//   imemode.exe get      -> same
//   imemode.exe en       -> switch the foreground window's IME to alphanumeric
//   imemode.exe ko       -> switch it back to the native (한글) mode
using System;
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

    static int Main(string[] args)
    {
        IntPtr ime = ImmGetDefaultIMEWnd(GetForegroundWindow());
        if (ime == IntPtr.Zero) { Console.Error.WriteLine("imemode: no IME window on the foreground window"); return 2; }

        string verb = args.Length == 0 ? "get" : args[0];
        if (verb == "get")
        {
            long mode = (long)SendMessage(ime, WM_IME_CONTROL, (IntPtr)IMC_GETCONVERSIONMODE, IntPtr.Zero);
            Console.WriteLine((mode & IME_CMODE_NATIVE) != 0 ? "ko" : "en");
            return 0;
        }
        int target;
        if (verb == "en") target = 0;
        else if (verb == "ko") target = IME_CMODE_NATIVE;
        else { Console.Error.WriteLine("usage: imemode.exe [get|en|ko]"); return 1; }

        SendMessage(ime, WM_IME_CONTROL, (IntPtr)IMC_SETCONVERSIONMODE, (IntPtr)target);
        return 0;
    }
}
