// DeskGlide's input helper. DeskGlideService (SYSTEM) starts it in the console session and talks to it over the two
// anonymous pipes it inherits as standard input and output: no named pipe or socket that another program could open. It
// injects only what the service sends, on whichever desktop has the input (the normal desktop, a UAC prompt, the lock or
// sign-in screen), and reports the monitors back. It never opens a network socket. Compiled on its own into
// DeskGlideHelper.exe, and into the service for HelperProto.
using System; using System.IO; using System.Text; using System.Threading; using System.Collections.Concurrent;
using System.Collections.Generic; using System.Runtime.InteropServices;

// Frames between the service and the helper: [type][payload length, 2 bytes LE][payload], int32 fields little-endian.
// Service -> helper: 'K' key (vk, sc, flags), 'M' mouse (x, y, data, flags; x and y in pixels when ABSOLUTE), 'L' lock.
// Helper -> service: 'D' monitors (left, top, right, bottom, dpi for each), 'G' a log line (UTF-8).
public static class HelperProto {
  public const int Max = 1024;
  public const int KeyFlags = 0x1 | 0x2 | 0x8;   // EXTENDEDKEY, KEYUP, SCANCODE
  // MOVE, the five buttons down/up, XDOWN/XUP, WHEEL, HWHEEL, VIRTUALDESK, ABSOLUTE
  public const int MouseFlags = 0x1 | 0x2 | 0x4 | 0x8 | 0x10 | 0x20 | 0x40 | 0x80 | 0x100 | 0x800 | 0x1000 | 0x4000 | 0x8000;
  public static byte[] Frame(byte type, byte[] payload) {
    if (payload.Length > Max) throw new ArgumentException("frame too long");
    var f = new byte[3 + payload.Length]; f[0] = type; f[1] = (byte)payload.Length; f[2] = (byte)(payload.Length >> 8);
    payload.CopyTo(f, 3); return f;
  }
  public static byte[] Ints(byte type, params int[] v) { return Frame(type, ToBytes(v)); }
  public static byte[] ToBytes(params int[] v) { var p = new byte[4 * v.Length]; for (int i = 0; i < v.Length; i++) BitConverter.GetBytes(v[i]).CopyTo(p, 4 * i); return p; }
  public static int[] ToInts(byte[] p) { var v = new int[p.Length / 4]; for (int i = 0; i < v.Length; i++) v[i] = BitConverter.ToInt32(p, 4 * i); return v; }
  // false at the end of the stream (the other side is gone); throws on a frame that is cut short or too long
  public static bool Read(Stream s, out byte type, out byte[] payload) {
    type = 0; payload = null;
    var h = new byte[3]; int got = Fill(s, h);
    if (got == 0) return false;
    if (got < 3) throw new IOException("frame cut short");
    int n = h[1] | h[2] << 8; if (n > Max) throw new IOException("frame too long");
    payload = new byte[n]; if (Fill(s, payload) < n) throw new IOException("frame cut short");
    type = h[0]; return true;
  }
  static int Fill(Stream s, byte[] b) { int o = 0; while (o < b.Length) { int r = s.Read(b, o, b.Length - o); if (r <= 0) break; o += r; } return o; }
  // What the helper accepts: a known type, the right size, only the flags DeskGlide Link uses
  public static bool Valid(byte type, byte[] p) {
    if (type == 'L') return p.Length == 0;
    if (p.Length != (type == 'K' ? 12 : type == 'M' ? 16 : -1)) return false;
    int[] v = ToInts(p);
    if (type == 'K') return v[0] >= 0 && v[0] <= 0xFF && v[1] >= 0 && v[1] <= 0xFF && (v[2] & ~KeyFlags) == 0;
    return (v[3] & ~MouseFlags) == 0;
  }
  public static Mon2[] Monitors(byte[] p) {   // a 'D' frame -> monitors, or null if it doesn't hold 1..16 real rectangles
    int[] v = ToInts(p); if (p.Length % 20 != 0 || v.Length / 5 < 1 || v.Length / 5 > 16) return null;
    var o = new Mon2[v.Length / 5];
    for (int i = 0; i < o.Length; i++) { o[i] = new Mon2 { L = v[5 * i], T = v[5 * i + 1], R = v[5 * i + 2], B = v[5 * i + 3], Dpi = v[5 * i + 4] }; if (o[i].R <= o[i].L || o[i].B <= o[i].T || o[i].Dpi < 48 || o[i].Dpi > 960) return null; }
    return o;
  }
}
public struct Mon2 { public int L, T, R, B, Dpi; }

public static class HelperMain {
  static Stream outS; static readonly object outGate = new object();
  static bool noInject; static volatile int gen; static long errAt = -100000;
  static readonly BlockingCollection<KeyValuePair<byte, int[]>> q = new BlockingCollection<KeyValuePair<byte, int[]>>(4096);
  const long OwnTag = 0x44474C4B;   // "DGLK", as DeskGlide Link's own input

  public static int Main(string[] args) {
    noInject = Array.IndexOf(args, "-NoInject") >= 0;
    Stream inS = Console.OpenStandardInput(); outS = Console.OpenStandardOutput();
    var d = new Thread(Desktops); d.IsBackground = true; d.Start();
    Log("helper started" + (noInject ? ", no injection" : "") + " in session " + System.Diagnostics.Process.GetCurrentProcess().SessionId);
    try {
      byte t; byte[] p;
      while (HelperProto.Read(inS, out t, out p)) {
        if (HelperProto.Valid(t, p)) q.TryAdd(new KeyValuePair<byte, int[]>(t, HelperProto.ToInts(p)));
        else Log("ignored a bad frame from the service");
      }
    } catch (Exception e) { Log("helper: " + e.Message); }
    return 0;   // the service closed the pipe: it stopped, so the helper stops too
  }
  static void Send(byte[] f) { lock (outGate) { try { outS.Write(f, 0, f.Length); outS.Flush(); } catch { } } }
  static void Log(string s) { var b = Encoding.UTF8.GetBytes(s); if (b.Length > HelperProto.Max) Array.Resize(ref b, HelperProto.Max); Send(HelperProto.Frame((byte)'G', b)); }

  // Every 100 ms: which desktop has the input? A new one gets a fresh thread (SetThreadDesktop fails for a thread that has
  // used another desktop's windows), and the old thread ends.
  static volatile string cur;
  static void Desktops() {
    while (true) {
      IntPtr h = OpenInputDesktop(0, false, 0x10000000);   // GENERIC_ALL
      if (h != IntPtr.Zero) {
        string name = DeskName(h);
        if (name != null && name != cur) {
          cur = name; int my = ++gen; IntPtr desk = h; string nm = name;
          var t = new Thread(() => Inject(desk, my, nm)); t.IsBackground = true; t.Start();
        } else CloseDesktop(h);
      }
      Thread.Sleep(100);
    }
  }
  static void Inject(IntPtr desk, int my, string name) {
    try {
      if (!SetThreadDesktop(desk)) { Log("can't switch to the " + name + " desktop (error " + Marshal.GetLastWin32Error() + ")"); Thread.Sleep(1000); if (gen == my) cur = null; return; }   // tried again in a second
      try { SetThreadDpiAwarenessContext(new IntPtr(-4)); } catch { }   // PerMonitorV2: physical pixels, as the other PC sends them
      Log("input desktop: " + name);
      string sent = null; int monAt = Environment.TickCount - 1000;
      while (gen == my) {
        if (Environment.TickCount - monAt >= 1000) { monAt = Environment.TickCount; string m = Report(sent); if (m != null) sent = m; }
        KeyValuePair<byte, int[]> c;
        if (!q.TryTake(out c, 50)) continue;
        // ponytail: an event taken just as the desktop switches goes to the old one; one event at a UAC prompt or lock
        Do(c.Key, c.Value);
      }
    } finally { CloseDesktop(desk); }
  }
  static string Report(string last) {   // this desktop's monitors to the service, when they change
    var v = new List<int>();
    MonEnum cb = (IntPtr h, IntPtr dc, ref RC r, IntPtr p) => { uint x, y; int dpi = 96; try { if (GetDpiForMonitor(h, 0, out x, out y) == 0) dpi = (int)x; } catch { } v.AddRange(new[] { r.l, r.t, r.r, r.b, dpi }); return v.Count < 80; };
    EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, cb, IntPtr.Zero);
    string sig = string.Join(",", v); if (v.Count == 0 || sig == last) return null;
    Send(HelperProto.Ints((byte)'D', v.ToArray())); return sig;
  }
  static void Do(byte t, int[] v) {
    if (noInject) { Log("would inject " + (t == 'K' ? "key vk " + v[0].ToString("X2") + " sc " + v[1].ToString("X2") + " flags " + v[2] : t == 'M' ? "mouse " + v[0] + "," + v[1] + " data " + v[2] + " flags " + v[3].ToString("X") : "lock")); return; }
    if (t == 'L') { if (!LockWorkStation()) Fail(); return; }
    var i = new INPUT();
    if (t == 'K') { i.type = 1; i.u.k.vk = (ushort)v[0]; i.u.k.sc = (ushort)v[1]; i.u.k.flags = (uint)v[2]; i.u.k.extra = (IntPtr)OwnTag; }
    else {
      int x = v[0], y = v[1];
      if ((v[3] & 0x8000) != 0) { x = Norm(x, GetSystemMetrics(76), GetSystemMetrics(78)); y = Norm(y, GetSystemMetrics(77), GetSystemMetrics(79)); }   // this desktop's virtual screen
      i.type = 0; i.u.m.dx = x; i.u.m.dy = y; i.u.m.data = (uint)v[2]; i.u.m.flags = (uint)v[3]; i.u.m.extra = (IntPtr)OwnTag;
    }
    if (SendInput(1, new[] { i }, Marshal.SizeOf(typeof(INPUT))) != 1) Fail();
  }
  static void Fail() { if (Environment.TickCount - errAt > 5000) { errAt = Environment.TickCount; Log("Windows refused the input (error " + Marshal.GetLastWin32Error() + ")"); } }
  public static int Norm(int v, int origin, int size) { return size <= 1 ? 0 : (int)Math.Min(65535, ((long)(v - origin) * 65536 + 32768) / size); }   // as Geo.Norm
  static string DeskName(IntPtr h) {
    var b = new byte[512]; int n; if (!GetUserObjectInformation(h, 2, b, b.Length, out n)) return null;   // UOI_NAME
    return Encoding.Unicode.GetString(b, 0, Math.Max(0, n - 2));
  }

  [StructLayout(LayoutKind.Sequential)] struct RC { public int l, t, r, b; }
  [StructLayout(LayoutKind.Sequential)] struct MOUSEIN { public int dx, dy; public uint data, flags, time; public IntPtr extra; }
  [StructLayout(LayoutKind.Sequential)] struct KEYIN { public ushort vk, sc; public uint flags, time; public IntPtr extra; }
  [StructLayout(LayoutKind.Explicit)] struct UNION { [FieldOffset(0)] public MOUSEIN m; [FieldOffset(0)] public KEYIN k; }
  [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public UNION u; }
  delegate bool MonEnum(IntPtr h, IntPtr dc, ref RC r, IntPtr p);
  [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] i, int size);
  [DllImport("user32.dll", SetLastError = true)] static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
  [DllImport("user32.dll", SetLastError = true)] static extern bool SetThreadDesktop(IntPtr d);
  [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr d);
  [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool GetUserObjectInformation(IntPtr h, int index, byte[] info, int len, out int needed);
  [DllImport("user32.dll", SetLastError = true)] static extern bool LockWorkStation();
  [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
  [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MonEnum f, IntPtr p);
  [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr h, int type, out uint x, out uint y);
}
