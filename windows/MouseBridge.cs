// KeyBridge: captures the laptop's touchpad/mouse on Windows and streams it to keybridge.py (in WSL2),
// which sends it to the host as a Bluetooth mouse. Loaded by Start-KeyBridge.ps1 with Add-Type,
// so it runs inside that (elevated) PowerShell window. Windows PowerShell 5.1 -> C# 5 syntax only.
//
// Link: TCP 127.0.0.1:<port>; keybridge.py listens (WSL forwards localhost), we connect.
//   keybridge.py -> here : "G1" = capture the pointer for the host, "G0" = give it back
//   here -> keybridge.py : "M dx dy" movement, "B mask" buttons (1 left, 2 right, 4 middle, 8 back, 16 forward),
//                           "W v h" wheel in Windows units (120 = one notch), "R" = released by itself
// While captured, a low-level mouse hook swallows all mouse input, so the laptop pointer stays put
// and clicks don't land on Windows. It lets go by itself if another window comes to the front
// (Alt+Tab, Win key), if the link drops, or when Stop() is called.
using System;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace KeyBridge
{
    public static class MouseBridge
    {
        const int WH_MOUSE_LL = 14;
        const uint WM_QUIT = 0x0012;
        const int WM_MOUSEMOVE = 0x200, WM_LBUTTONDOWN = 0x201, WM_LBUTTONUP = 0x202,
            WM_RBUTTONDOWN = 0x204, WM_RBUTTONUP = 0x205, WM_MBUTTONDOWN = 0x207, WM_MBUTTONUP = 0x208,
            WM_MOUSEWHEEL = 0x20A, WM_XBUTTONDOWN = 0x20B, WM_XBUTTONUP = 0x20C, WM_MOUSEHWHEEL = 0x20E;

        delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
        [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
        [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int Size; public RECT Monitor, Work; public uint Flags; }
        [StructLayout(LayoutKind.Sequential)] struct MSLLHOOKSTRUCT { public POINT Pt; public uint MouseData, Flags, Time; public IntPtr Extra; }
        [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr Hwnd; public uint Message; public IntPtr WParam, LParam; public uint Time; public POINT Pt; }

        [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookEx(int id, HookProc fn, IntPtr mod, uint thread);
        [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
        [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr w, IntPtr l);
        [DllImport("user32.dll")] static extern int GetMessage(out MSG msg, IntPtr hwnd, uint min, uint max);
        [DllImport("user32.dll")] static extern bool PeekMessage(out MSG msg, IntPtr hwnd, uint min, uint max, uint remove);
        [DllImport("user32.dll")] static extern bool PostThreadMessage(uint thread, uint msg, IntPtr w, IntPtr l);
        [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
        [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(POINT p, uint flags);
        [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr mon, ref MONITORINFO mi);
        [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
        [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
        [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
        [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string name);

        static readonly object Sync = new object();       // guards the pending input below
        static readonly object GrabSync = new object();   // guards grab/release
        static readonly AutoResetEvent Wake = new AutoResetEvent(false);
        static readonly StringBuilder Pending = new StringBuilder();
        static int dx, dy, wheel, hwheel, buttons;
        static volatile bool grabbed, running;
        static IntPtr grabWindow;
        static POINT savedPos;
        static HookProc proc;                              // kept in a field so the GC can't collect it
        static uint hookThreadId;
        static volatile TcpClient client;
        static int port;

        public static bool HookInstalled { get; private set; }
        public static bool Connected { get { return client != null; } }
        public static bool Grabbed { get { return grabbed; } }

        public static void Start(int tcpPort)
        {
            if (running) return;
            running = true;
            port = tcpPort;
            proc = HookCallback;
            // The hook reports positions in physical pixels. Inside the hook callback GetCursorPos follows
            // the PROCESS's DPI mode (not the thread's), so with display scaling (e.g. 150%) the two
            // disagree and the pointer races off. Making the whole process per-monitor aware fixes that.
            try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch { }   // PER_MONITOR_AWARE_V2
            ManualResetEvent ready = new ManualResetEvent(false);
            Thread hookThread = new Thread(delegate ()
            {
                PerMonitorDpi();                           // hook coordinates are physical pixels
                MSG m;
                PeekMessage(out m, IntPtr.Zero, 0, 0, 0);  // create this thread's message queue
                hookThreadId = GetCurrentThreadId();
                IntPtr hook = SetWindowsHookEx(WH_MOUSE_LL, proc, GetModuleHandle(null), 0);
                HookInstalled = hook != IntPtr.Zero;
                ready.Set();
                while (GetMessage(out m, IntPtr.Zero, 0, 0) > 0) { }
                if (hook != IntPtr.Zero) UnhookWindowsHookEx(hook);
            });
            hookThread.IsBackground = true;
            hookThread.Start();
            ready.WaitOne(3000);
            StartThread(NetLoop);
            StartThread(SendLoop);
        }

        public static void Stop()
        {
            running = false;
            PerMonitorDpi();
            Release();
            if (hookThreadId != 0) PostThreadMessage(hookThreadId, WM_QUIT, IntPtr.Zero, IntPtr.Zero);
            TcpClient c = client;
            if (c != null) c.Close();
            Wake.Set();
        }

        static void StartThread(ThreadStart fn)
        {
            Thread t = new Thread(fn);
            t.IsBackground = true;
            t.Start();
        }

        static void PerMonitorDpi()
        {
            try { SetThreadDpiAwarenessContext(new IntPtr(-4)); } catch { }   // PER_MONITOR_AWARE_V2
        }

        static string Num(int v) { return v.ToString(CultureInfo.InvariantCulture); }

        // Runs on the hook thread for every mouse event in the system. Must return quickly.
        static IntPtr HookCallback(int code, IntPtr w, IntPtr l)
        {
            if (code < 0 || !grabbed) return CallNextHookEx(IntPtr.Zero, code, w, l);
            try
            {
                MSLLHOOKSTRUCT d = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(l, typeof(MSLLHOOKSTRUCT));
                int hi = (short)(d.MouseData >> 16);
                lock (Sync)
                {
                    switch (w.ToInt32())
                    {
                        case WM_MOUSEMOVE:
                            // The pointer is held still, so (where it would go) - (where it is) = the movement.
                            POINT c;
                            GetCursorPos(out c);
                            dx += d.Pt.X - c.X;
                            dy += d.Pt.Y - c.Y;
                            break;
                        case WM_MOUSEWHEEL: wheel += hi; break;
                        case WM_MOUSEHWHEEL: hwheel += hi; break;
                        case WM_LBUTTONDOWN: Button(1, true); break;
                        case WM_LBUTTONUP: Button(1, false); break;
                        case WM_RBUTTONDOWN: Button(2, true); break;
                        case WM_RBUTTONUP: Button(2, false); break;
                        case WM_MBUTTONDOWN: Button(4, true); break;
                        case WM_MBUTTONUP: Button(4, false); break;
                        case WM_XBUTTONDOWN: Button(hi == 1 ? 8 : 16, true); break;
                        case WM_XBUTTONUP: Button(hi == 1 ? 8 : 16, false); break;
                    }
                }
                Wake.Set();
            }
            catch { }
            return (IntPtr)1;   // swallow it: the laptop pointer doesn't move and nothing gets clicked
        }

        // Caller holds Sync. Movement before a click is queued first, so clicks land where expected,
        // and every press/release is kept even if it was shorter than one send.
        static void Button(int mask, bool down)
        {
            int nb = down ? (buttons | mask) : (buttons & ~mask);
            if (nb == buttons) return;
            FlushMotion();
            buttons = nb;
            Pending.Append("B ").Append(Num(buttons)).Append('\n');
        }

        static void FlushMotion()   // caller holds Sync
        {
            if (dx == 0 && dy == 0) return;
            Pending.Append("M ").Append(Num(dx)).Append(' ').Append(Num(dy)).Append('\n');
            dx = dy = 0;
        }

        static void SendLoop()
        {
            PerMonitorDpi();
            while (running)
            {
                Wake.WaitOne(50);
                if (grabbed && GetForegroundWindow() != grabWindow)
                {
                    Release();                              // user switched windows: give the pointer back
                    lock (Sync) Pending.Append("R\n");
                }
                string text;
                lock (Sync)
                {
                    FlushMotion();
                    if (wheel != 0 || hwheel != 0)
                    {
                        Pending.Append("W ").Append(Num(wheel)).Append(' ').Append(Num(hwheel)).Append('\n');
                        wheel = hwheel = 0;
                    }
                    text = Pending.ToString();
                    Pending.Length = 0;
                }
                TcpClient c = client;
                if (text.Length == 0 || c == null) continue;
                try
                {
                    byte[] b = Encoding.ASCII.GetBytes(text);
                    c.GetStream().Write(b, 0, b.Length);
                }
                catch { }   // NetLoop notices the broken link and reconnects
            }
        }

        // Connects to keybridge.py (retrying until it is up) and follows its G1/G0 commands.
        static void NetLoop()
        {
            PerMonitorDpi();
            while (running)
            {
                TcpClient c = new TcpClient();
                try
                {
                    c.NoDelay = true;
                    c.Connect(IPAddress.Loopback, port);
                    client = c;
                    NetworkStream s = c.GetStream();
                    byte[] buf = new byte[64];
                    StringBuilder line = new StringBuilder();
                    int n;
                    while (running && (n = s.Read(buf, 0, buf.Length)) > 0)
                    {
                        for (int i = 0; i < n; i++)
                        {
                            if (buf[i] != (byte)'\n') { line.Append((char)buf[i]); continue; }
                            string cmd = line.ToString().Trim();
                            line.Length = 0;
                            if (cmd == "G1") Grab();
                            else if (cmd == "G0") Release();
                        }
                    }
                }
                catch { }
                client = null;
                Release();
                c.Close();
                if (running) Thread.Sleep(1000);
            }
        }

        static void Grab()
        {
            lock (GrabSync)
            {
                if (grabbed) return;
                GetCursorPos(out savedPos);
                grabWindow = GetForegroundWindow();
                // Park the pointer mid-screen so there is room to move in every direction.
                MONITORINFO mi = new MONITORINFO();
                mi.Size = Marshal.SizeOf(typeof(MONITORINFO));
                if (GetMonitorInfo(MonitorFromPoint(savedPos, 2 /* nearest */), ref mi))
                    SetCursorPos((mi.Monitor.Left + mi.Monitor.Right) / 2, (mi.Monitor.Top + mi.Monitor.Bottom) / 2);
                lock (Sync) { dx = dy = wheel = hwheel = buttons = 0; Pending.Length = 0; }
                grabbed = true;
            }
        }

        static void Release()
        {
            lock (GrabSync)
            {
                if (!grabbed) return;
                grabbed = false;
                lock (Sync) { dx = dy = wheel = hwheel = buttons = 0; Pending.Length = 0; }
                SetCursorPos(savedPos.X, savedPos.Y);
            }
        }
    }
}
