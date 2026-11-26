// DeskGlide native helpers. DeskGlide.ps1 compiles this with Add-Type (C# 5, nothing to install).
using System; using System.Text; using System.Net; using System.Net.Sockets; using System.Threading; using System.IO;
using System.Collections.Generic; using System.Runtime.InteropServices; using System.Security.Cryptography;
using System.Drawing; using System.Drawing.Drawing2D; using System.Drawing.Imaging;
using System.IO.Compression; using System.Collections.Concurrent; using System.Diagnostics; using System.Net.NetworkInformation;

// One background download (or GET when path is null) with progress. DeskGlide.ps1 polls it from its timer.
public class Job {
  public volatile string Status = "";   // "" while running, then "ok" or "error: ..."
  public long Done, Total;
  public string Text;                    // the body, for a GET
  public static Job Start(string url, string path, string sha256, string extractTo) {
    var j = new Job();   // PowerShell passes $null as "": treat both as "not given"
    var t = new Thread(() => j.Run(url, N(path), N(sha256), N(extractTo))); t.IsBackground = true; t.Start(); return j;
  }
  static string N(string s) { return string.IsNullOrEmpty(s) ? null : s;
  }
  void Run(string url, string path, string sha256, string extractTo) {
    try {
      ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
      var rq = WebRequest.Create(url); var http = rq as HttpWebRequest; if (http != null) http.UserAgent = "DeskGlide"; rq.Timeout = 30000;   // GitHub wants a User-Agent
      using (var rs = rq.GetResponse()) using (var s = rs.GetResponseStream()) {
        Total = rs.ContentLength;
        Stream o = path == null ? (Stream)new MemoryStream() : File.Create(path);
        using (var h = SHA256.Create()) {
          try {
            var b = new byte[65536]; int n;
            while ((n = s.Read(b, 0, b.Length)) > 0) { o.Write(b, 0, n); h.TransformBlock(b, 0, n, null, 0); Done += n; }
            h.TransformFinalBlock(b, 0, 0);
            if (path == null) Text = Encoding.UTF8.GetString(((MemoryStream)o).ToArray());
          } finally { o.Close(); }
          if (sha256 != null && Dg.Hex(h.Hash) != sha256.ToLowerInvariant()) {
            File.Delete(path); Status = "error: the download's SHA256 doesn't match the release, so it was deleted"; return;
          }
        }
      }
      if (extractTo != null) {   // into a temp folder first, so a half-extracted copy is never used
        string tmp = extractTo + ".part";
        if (Directory.Exists(tmp)) Directory.Delete(tmp, true);
        ZipFile.ExtractToDirectory(path, tmp);   // refuses entries that point outside tmp
        if (Directory.Exists(extractTo)) Directory.Delete(extractTo, true);
        Directory.Move(tmp, extractTo);
      }
      Status = "ok";
    } catch (Exception e) { Status = "error: " + e.Message; }
  }
}

// A message-only window for global hotkeys and clipboard changes. DeskGlide.ps1 polls the flags from its timer.
public class MsgWin : System.Windows.Forms.NativeWindow {
  [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
  [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
  [DllImport("user32.dll")] static extern bool AddClipboardFormatListener(IntPtr h);
  public static volatile int Pressed;          // id of the last hotkey pressed, 0 = none; DeskGlide.ps1 clears it
  public static volatile bool ClipChanged;
  public MsgWin() { var p = new System.Windows.Forms.CreateParams(); p.Parent = new IntPtr(-3); CreateHandle(p); }   // HWND_MESSAGE
  // vk 0 = just unregister. false = another program has this key.
  public bool SetHotkey(int id, uint mods, uint vk) { UnregisterHotKey(Handle, id); return vk == 0 || RegisterHotKey(Handle, id, mods | 0x4000, vk); }   // MOD_NOREPEAT
  public bool ListenClipboard() { return AddClipboardFormatListener(Handle); }
  protected override void WndProc(ref System.Windows.Forms.Message m) {
    if (m.Msg == 0x312) Pressed = m.WParam.ToInt32();          // WM_HOTKEY
    else if (m.Msg == 0x31D) ClipChanged = true;               // WM_CLIPBOARDUPDATE
    base.WndProc(ref m);
  }
}

// File copy-paste. The PC where files were copied serves them over TCP; the other PC pulls them when the mouse
// arrives there. Every frame is encrypted and authenticated (Dg.Encrypt) with a key for this one connection.
public static class Files {
  // ---- sender ----
  public static volatile string OfferId = "";   // the files on this PC's clipboard, as offered to the other PC
  public static volatile string[] OfferPaths;
  public static volatile byte[] Key;            // the pairing key
  public static volatile string ServeError = "";
  // Total bytes of the files (folders walked), or -1 if over limit. ponytail: walks on the caller's thread, stops at the limit
  public static long Measure(string[] paths, long limit) {
    long n = 0;
    foreach (var p in paths) {
      if (File.Exists(p)) n += new FileInfo(p).Length;
      else if (Directory.Exists(p)) foreach (var f in new DirectoryInfo(p).EnumerateFiles("*", SearchOption.AllDirectories)) { n += f.Length; if (n > limit) return -1; }
      if (n > limit) return -1;
    }
    return n;
  }
  public static void Offer(string[] paths) { OfferPaths = paths; OfferId = paths == null ? "" : Dg.Hex(Dg.Random(8)); }
  public static void Serve(int port) {
    var t = new Thread(() => {
      var l = new TcpListener(IPAddress.Any, port); l.Start();
      while (true) { var c = l.AcceptTcpClient(); var w = new Thread(() => ServeOne(c)); w.IsBackground = true; w.Start(); }
    });
    t.IsBackground = true; t.Start();
  }
  static void ServeOne(TcpClient c) {
    try {
      using (c) {
        c.ReceiveTimeout = 15000; c.SendTimeout = 60000; var s = c.GetStream();
        byte[] nr = ReadN(s, 16), ns = Dg.Random(16); s.Write(ns, 0, 16);
        byte[] k = Dg.SessionKey(Key, "files", Cat(nr, ns)); long rx = 0, tx = 0;
        string id = Encoding.UTF8.GetString(ReadFrame(s, k, 'R', rx++));   // a PC without the pairing key fails here, before anything is sent
        if (id.StartsWith("clip:")) { Clip.Serve(s, k, id.Substring(5), ref tx); return; }   // text or a picture (DeskGlide Link)
        string[] paths = OfferPaths;
        if (paths == null || id != OfferId) { WriteFrame(s, k, 'S', tx++, Encoding.UTF8.GetBytes("gone"), 0, 4); return; }
        var list = new List<KeyValuePair<string, string>>(); var m = new StringBuilder();   // relative path -> full path
        foreach (var p in paths) {
          string top = Path.GetFileName(p.TrimEnd('\\'));
          if (File.Exists(p)) { list.Add(new KeyValuePair<string, string>(top, p)); m.Append("F\t" + new FileInfo(p).Length + "\t" + top + "\n"); continue; }
          var root = new DirectoryInfo(p); m.Append("D\t" + top + "\n");
          foreach (var d in root.EnumerateDirectories("*", SearchOption.AllDirectories)) m.Append("D\t" + top + "/" + Rel(root, d.FullName) + "\n");
          foreach (var f in root.EnumerateFiles("*", SearchOption.AllDirectories)) {
            string r = top + "/" + Rel(root, f.FullName); list.Add(new KeyValuePair<string, string>(r, f.FullName)); m.Append("F\t" + f.Length + "\t" + r + "\n");
          }
        }
        byte[] mb = Encoding.UTF8.GetBytes("ok\n" + m); WriteFrame(s, k, 'S', tx++, mb, 0, mb.Length);
        var buf = new byte[65536];
        foreach (var e in list) using (var f = new FileStream(e.Value, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
          int n; while ((n = f.Read(buf, 0, buf.Length)) > 0) WriteFrame(s, k, 'S', tx++, buf, 0, n);
        }
        WriteFrame(s, k, 'S', tx++, buf, 0, 0);   // end
      }
    } catch (Exception e) { ServeError = e.Message; }
  }
  static string Rel(DirectoryInfo root, string full) { return full.Substring(root.FullName.TrimEnd('\\').Length + 1).Replace('\\', '/'); }

  // ---- receiver ----
  public static volatile string Status = "";    // "" idle, "busy", "ok", or "error: ..."
  public static long Done, Total;
  public static string[] Result;                 // the saved files and folders, top level
  public static void Fetch(string host, int port, byte[] key, string id, string root, long limit) {
    Status = "busy"; Done = 0; Total = 0; Result = null;
    var t = new Thread(() => { try { FetchRun(host, port, key, id, root, limit); Status = "ok"; } catch (Exception e) { Status = "error: " + e.Message; } });
    t.IsBackground = true; t.Start();
  }
  static void FetchRun(string host, int port, byte[] key, string id, string root, long limit) {
    Directory.CreateDirectory(root);
    string stage = Path.Combine(root, ".incoming-" + Dg.Hex(Dg.Random(4))); var tops = new List<string>();
    try {
      using (var c = new TcpClient()) {
        c.Connect(host, port); c.ReceiveTimeout = 60000; c.SendTimeout = 15000; var s = c.GetStream();
        byte[] nr = Dg.Random(16); s.Write(nr, 0, 16); byte[] ns = ReadN(s, 16);
        byte[] k = Dg.SessionKey(key, "files", Cat(nr, ns)); long rx = 0, tx = 0;
        byte[] ib = Encoding.UTF8.GetBytes(id); WriteFrame(s, k, 'R', tx++, ib, 0, ib.Length);
        string man;   // the sender drops a request it cannot decrypt, so a closed connection here means another pairing key
        try { man = Encoding.UTF8.GetString(ReadFrame(s, k, 'S', rx++)); } catch (IOException) { throw new IOException("the other PC refused: it is not paired with this one"); }
        if (!man.StartsWith("ok\n")) throw new IOException("the other PC no longer offers these files (copied something else?)");
        var files = new List<KeyValuePair<string, long>>();
        foreach (var line in man.Substring(3).Split(new[] { '\n' }, StringSplitOptions.RemoveEmptyEntries)) {
          var a = line.Split('\t'); string rel = a[a.Length - 1];
          string full = SafePath(stage, rel); if (full == null) throw new IOException("unsafe file name: " + rel);
          string top = rel.Split('/')[0]; if (!tops.Contains(top)) tops.Add(top);
          if (a[0] == "D" && a.Length == 2) Directory.CreateDirectory(full);
          else if (a[0] == "F" && a.Length == 3) { long n = long.Parse(a[1]); if (n < 0) throw new IOException("bad size"); files.Add(new KeyValuePair<string, long>(full, n)); Total += n; }
          else throw new IOException("bad file list");
        }
        if (Total > limit) throw new IOException("the files are larger than the limit set in Settings");
        foreach (var f in files) {
          Directory.CreateDirectory(Path.GetDirectoryName(f.Key));
          using (var o = File.Create(f.Key)) {
            long left = f.Value;
            while (left > 0) {
              byte[] b = ReadFrame(s, k, 'S', rx++);
              if (b.Length == 0 || b.Length > left) throw new IOException("the transfer was cut short");
              o.Write(b, 0, b.Length); left -= b.Length; Done += b.Length;
            }
          }
        }
        if (ReadFrame(s, k, 'S', rx++).Length != 0) throw new IOException("bad end of transfer");
      }
      var done = new List<string>();
      foreach (var top in tops) { string src = Path.Combine(stage, top), dst = Unique(root, top); if (Directory.Exists(src)) Directory.Move(src, dst); else File.Move(src, dst); done.Add(dst); }
      Result = done.ToArray();
    } finally { try { if (Directory.Exists(stage)) Directory.Delete(stage, true); } catch {} }
  }
  // "dir/sub/a.txt" under root, or null if it could leave root or isn't a plain relative name
  public static string SafePath(string root, string rel) {
    if (string.IsNullOrEmpty(rel) || rel.Length > 400 || rel.IndexOf('\\') >= 0 || rel.IndexOf(':') >= 0) return null;
    foreach (var part in rel.Split('/')) if (part == "" || part == "." || part == ".." || part.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || part.EndsWith(".") || part.EndsWith(" ")) return null;
    string r = Path.GetFullPath(root).TrimEnd('\\') + "\\", full = Path.GetFullPath(Path.Combine(r, rel.Replace('/', '\\')));
    return full.StartsWith(r, StringComparison.OrdinalIgnoreCase) ? full : null;
  }
  // root\name, or root\name (2).ext if that exists
  public static string Unique(string root, string name) {
    string p = Path.Combine(root, name); if (!File.Exists(p) && !Directory.Exists(p)) return p;
    string b = Path.GetFileNameWithoutExtension(name), x = Path.GetExtension(name);
    if (Directory.Exists(p)) { b = name; x = ""; }
    for (int i = 2; ; i++) { p = Path.Combine(root, b + " (" + i + ")" + x); if (!File.Exists(p) && !Directory.Exists(p)) return p; }
  }

  // frame: [length:4][Dg.Encrypt(key, direction + sequence, data)]. The sequence in the MAC stops reordering and replay.
  internal static void WriteFrame(Stream s, byte[] k, char dir, long seq, byte[] b, int off, int n) {
    byte[] e = Dg.Encrypt(k, Ad(dir, seq), b, off, n);
    s.Write(BitConverter.GetBytes(e.Length), 0, 4); s.Write(e, 0, e.Length);
  }
  internal static byte[] ReadFrame(Stream s, byte[] k, char dir, long seq) {
    int n = BitConverter.ToInt32(ReadN(s, 4), 0);
    if (n < 0 || n > 70000) throw new IOException("bad frame");
    byte[] d = Dg.Decrypt(k, Ad(dir, seq), ReadN(s, n), 0, n);
    if (d == null) throw new IOException("the other PC isn't paired with this one, or the data was changed on the way");
    return d;
  }
  static byte[] Ad(char dir, long seq) { var a = new byte[9]; a[0] = (byte)dir; BitConverter.GetBytes(seq).CopyTo(a, 1); return a; }
  internal static byte[] ReadN(Stream s, int n) {
    var b = new byte[n]; int got = 0;
    while (got < n) { int r = s.Read(b, got, n - got); if (r <= 0) throw new IOException("the connection closed"); got += r; }
    return b;
  }
  internal static byte[] Cat(byte[] a, byte[] b) { var o = new byte[a.Length + b.Length]; a.CopyTo(o, 0); b.CopyTo(o, a.Length); return o; }
}

public static class Dg {
  public static string Hex(byte[] b) { var s = new StringBuilder(); foreach (byte x in b) s.Append(x.ToString("x2")); return s.ToString(); }


  // ---------- app icon: a monitor whose left half is this PC and right half the other PC ----------
  // state: 0 = app icon (two-tone), 1 = this PC has the mouse, 2 = the other PC has it, 3 = grey (paused / not paired)
  public static Bitmap DrawIcon(int size, int state) {
    var bmp = new Bitmap(size, size, PixelFormat.Format32bppArgb);
    float k = size / 16f;   // drawn on a 16-unit grid so 16 px stays crisp
    Color frame = state == 3 ? Color.FromArgb(110, 110, 110) : Color.FromArgb(38, 50, 66);
    Color on = Color.FromArgb(0, 120, 212), soft = Color.FromArgb(96, 180, 245), off = Color.FromArgb(150, 160, 172), grey = Color.FromArgb(185, 185, 185);
    Color left = state == 3 ? grey : state == 2 ? off : on;
    Color right = state == 3 ? grey : state == 1 ? off : state == 2 ? on : soft;
    using (var g = Graphics.FromImage(bmp)) {
      g.SmoothingMode = SmoothingMode.AntiAlias; g.PixelOffsetMode = PixelOffsetMode.Half;
      using (var b = new SolidBrush(frame)) {
        g.FillPath(b, Round(1 * k, 2 * k, 14 * k, 10 * k, 1.5f * k));    // bezel
        g.FillRectangle(b, 7 * k, 12 * k, 2 * k, 1 * k);                  // neck
        g.FillPath(b, Round(4 * k, 13 * k, 8 * k, 2 * k, 0.8f * k));      // foot
      }
      float gap = size >= 32 ? 0.25f * k : 0;
      using (var b = new SolidBrush(left)) g.FillRectangle(b, 2 * k, 3 * k, 6 * k - gap, 8 * k);
      using (var b = new SolidBrush(right)) g.FillRectangle(b, 8 * k + gap, 3 * k, 6 * k - gap, 8 * k);
    }
    return bmp;
  }
  static GraphicsPath Round(float x, float y, float w, float h, float r) {
    var p = new GraphicsPath(); float d = r * 2;
    p.AddArc(x, y, d, d, 180, 90); p.AddArc(x + w - d, y, d, d, 270, 90);
    p.AddArc(x + w - d, y + h - d, d, d, 0, 90); p.AddArc(x, y + h - d, d, d, 90, 90);
    p.CloseFigure(); return p;
  }
  public static byte[] IconPng(int size, int state) {
    using (var b = DrawIcon(size, state)) using (var ms = new MemoryStream()) { b.Save(ms, ImageFormat.Png); return ms.ToArray(); }
  }
  // .ico with PNG frames (Windows Vista and later read these)
  public static void SaveIco(string path, int state, int[] sizes) {
    var pngs = new List<byte[]>(); foreach (int z in sizes) pngs.Add(IconPng(z, state));
    using (var w = new BinaryWriter(File.Create(path))) {
      w.Write((short)0); w.Write((short)1); w.Write((short)sizes.Length);
      int off = 6 + 16 * sizes.Length;
      for (int i = 0; i < sizes.Length; i++) {
        byte z = (byte)(sizes[i] >= 256 ? 0 : sizes[i]);
        w.Write(z); w.Write(z); w.Write((short)0); w.Write((short)1); w.Write((short)32);
        w.Write(pngs[i].Length); w.Write(off); off += pngs[i].Length;
      }
      foreach (var p in pngs) w.Write(p);
    }
  }

  // ---------- window helpers ----------
  [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int n);
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int n);
  [StructLayout(LayoutKind.Sequential)] struct RECT { public int l, t, r, b; }
  [DllImport("shell32.dll", CharSet=CharSet.Unicode)] static extern int SetCurrentProcessExplicitAppUserModelID(string id);
  public static void DarkTitle(IntPtr h, bool dark) { int v = dark ? 1 : 0; DwmSetWindowAttribute(h, 20, ref v, 4); }   // DWMWA_USE_IMMERSIVE_DARK_MODE
  public static int[] FrameRect(IntPtr h) {   // the window's visible bounds in screen pixels (no invisible resize border)
    RECT r; DwmGetWindowAttribute(h, 9, out r, 16); return new[] { r.l, r.t, r.r - r.l, r.b - r.t };
  }
  public static void AppId(string id) { SetCurrentProcessExplicitAppUserModelID(id); }   // own taskbar button, not grouped with PowerShell

  // ---------- wake this PC's screen when the mouse arrives ----------
  [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint f);
  [DllImport("user32.dll")] static extern void mouse_event(uint f, int dx, int dy, uint d, IntPtr e);
  public static void WakeDisplay() {   // ES_DISPLAY_REQUIRED, then +1 px and -1 px (MOVE | MOVE_NOCOALESCE): Windows drops a zero-distance move
    SetThreadExecutionState(2); mouse_event(0x2001, 1, 0, 0, IntPtr.Zero); mouse_event(0x2001, -1, 0, 0, IntPtr.Zero);
  }

  // ---------- volume: the receiver scales the other PC's 16-bit samples, vol 0..1 ----------
  public static volatile float Volume = 1f;
  public static void Scale(byte[] b, int off, int len, float vol) {
    if (vol >= 1f) return;
    for (int i = off, end = off + len - 1; i < end; i += 2) {
      int s = (int)((short)(b[i] | b[i + 1] << 8) * vol);
      b[i] = (byte)s; b[i + 1] = (byte)(s >> 8);
    }
  }
  // ---------- monitor: DDC/CI VCP 0x60 (input select) via dxva2.dll ----------
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct PM { public IntPtr h; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string d; }
  delegate bool MEP(IntPtr hm, IntPtr dc, IntPtr r, IntPtr p);
  [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MEP cb, IntPtr p);
  [DllImport("dxva2.dll")] static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hm, out uint n);
  [DllImport("dxva2.dll")] static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hm, uint n, [Out] PM[] a);
  [DllImport("dxva2.dll")] static extern bool DestroyPhysicalMonitors(uint n, PM[] a);
  [DllImport("dxva2.dll")] static extern bool SetVCPFeature(IntPtr h, byte code, uint value);
  [DllImport("dxva2.dll")] static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte code, IntPtr t, out uint cur, out uint max);

  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  struct MONITORINFOEX { public int cb; public RECT mon, work; public uint flags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dev; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  struct DISPLAY_DEVICE { public int cb; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string name; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string text;
    public uint state; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string id; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string key; }
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr hm, ref MONITORINFOEX mi);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool EnumDisplayDevices(string dev, uint i, ref DISPLAY_DEVICE dd, uint flags);

  // Every physical monitor with its id and device path (\\?\DISPLAY#MSI4CE8#...#{guid}).
  // ponytail: physical monitor i of a display output is matched to its i-th active monitor device; true for everything but clone setups
  static void Each(Action<PM, string, string> f) {
    var seen = new Dictionary<string, int>();
    EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (hm, dc, r, p) => {
      uint n; if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hm, out n) || n == 0) return true;
      var a = new PM[n]; if (!GetPhysicalMonitorsFromHMONITOR(hm, n, a)) return true;
      var paths = new List<string>(); var mi = new MONITORINFOEX(); mi.cb = Marshal.SizeOf(mi);
      if (GetMonitorInfo(hm, ref mi)) {
        var dd = new DISPLAY_DEVICE(); dd.cb = Marshal.SizeOf(dd);
        for (uint i = 0; EnumDisplayDevices(mi.dev, i, ref dd, 1); i++) { if ((dd.state & 1) != 0) paths.Add(dd.id); dd.cb = Marshal.SizeOf(dd); }   // 1 = active, EDD_GET_DEVICE_INTERFACE_NAME
      }
      for (int i = 0; i < a.Length; i++) {
        string path = i < paths.Count ? paths[i] : "", k = MonitorKey(path); int c; seen.TryGetValue(k, out c); seen[k] = ++c;
        f(a[i], c > 1 ? k + "-" + c : k, path);
      }
      DestroyPhysicalMonitors(n, a); return true;
    }, IntPtr.Zero);
  }
  // The monitor's EDID maker + product code ("MSI4CE8"): the same on both PCs, whichever input shows it.
  // ponytail: two identical monitors are told apart by order ("MSI4CE8-2"), which can differ between the PCs
  public static string MonitorKey(string path) { var p = (path ?? "").Split('#'); return p.Length > 2 && p[1] != "" ? p[1].ToUpperInvariant() : "MONITOR"; }
  // "id \t device path \t name" per monitor; no DDC traffic
  public static string[] ListMonitors() {
    var names = FriendlyNames(); var o = new List<string>();
    Each((m, id, path) => { string nm; if (!names.TryGetValue(path.ToLowerInvariant(), out nm) || nm == "") nm = m.d; o.Add(id + "\t" + path + "\t" + nm); });
    return o.ToArray();
  }
  public static bool SetInputOn(string id, uint v) { bool ok = false; Each((m, i, p) => { if (i == id) ok |= SetVCPFeature(m.h, 0x60, v); }); return ok; }
  public static int GetInputOf(string id) {   // -1 = no DDC/CI reply (or no such monitor)
    int v = -1;
    Each((m, i, p) => { uint cur, max; if (i == id && v < 0 && GetVCPFeatureAndVCPFeatureReply(m.h, 0x60, IntPtr.Zero, out cur, out max)) v = (int)(cur & 0xFF); });
    return v;
  }

  // ---------- display configuration: take a switched-away monitor off this PC's desktop, and put it back ----------
  [StructLayout(LayoutKind.Sequential)] struct LUID { public uint lo; public int hi; }
  [StructLayout(LayoutKind.Sequential)] struct PathSource { public LUID adapter; public uint id, mode, status; }
  [StructLayout(LayoutKind.Sequential)] struct PathTarget { public LUID adapter; public uint id, mode, tech, rotation, scaling, rateN, rateD, scan; public int available; public uint status; }
  [StructLayout(LayoutKind.Sequential)] struct PathInfo { public PathSource src; public PathTarget tgt; public uint flags; }
  [StructLayout(LayoutKind.Sequential, Size=64)] struct ModeInfo { public uint type, id; public LUID adapter; }   // opaque: passed back unchanged
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  struct TargetName { public uint type, size; public LUID adapter; public uint id, flags, tech; public ushort maker, product; public uint conn;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=64)] public string name; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string path; }
  [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint np, out uint nm);
  [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint np, [Out] PathInfo[] p, ref uint nm, [Out] ModeInfo[] m, IntPtr topo);
  [DllImport("user32.dll")] static extern int SetDisplayConfig(uint np, [In] PathInfo[] p, uint nm, [In] ModeInfo[] m, uint flags);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int DisplayConfigGetDeviceInfo(ref TargetName t);
  const uint SdcApply = 0x80, SdcValidate = 0x40, SdcSupplied = 0x20, SdcAllowChanges = 0x400, SdcExtend = 0x4;

  static bool Query(out PathInfo[] p, out ModeInfo[] m) {   // active paths only
    uint np, nm; p = null; m = null;
    if (GetDisplayConfigBufferSizes(2, out np, out nm) != 0) return false;
    p = new PathInfo[np]; m = new ModeInfo[nm];
    if (QueryDisplayConfig(2, ref np, p, ref nm, m, IntPtr.Zero) != 0) return false;
    Array.Resize(ref p, (int)np); Array.Resize(ref m, (int)nm); return true;
  }
  static TargetName TargetOf(PathInfo x) {
    var t = new TargetName(); t.type = 2; t.size = (uint)Marshal.SizeOf(t); t.adapter = x.tgt.adapter; t.id = x.tgt.id;   // 2 = GET_TARGET_NAME
    DisplayConfigGetDeviceInfo(ref t); return t;
  }
  static Dictionary<string, string> FriendlyNames() {   // device path -> "MAG 275QF X30"
    var o = new Dictionary<string, string>(); PathInfo[] p; ModeInfo[] m;
    if (Query(out p, out m)) foreach (var x in p) { var t = TargetOf(x); if (t.path != null) o[t.path.ToLowerInvariant()] = t.name ?? ""; }
    return o;
  }
  static PathInfo[] savedPaths; static ModeInfo[] savedModes;
  public static bool Detached { get { return savedPaths != null; } }
  // Takes the monitor with this device path off the desktop. validate: only ask Windows whether it would accept it.
  // Returns "" when done (or acceptable), else why not.
  public static string Detach(string devicePath, bool validate) {
    PathInfo[] p; ModeInfo[] m; if (!Query(out p, out m)) return "can't read the display setup";
    int hit = -1;
    for (int i = 0; i < p.Length; i++) if (string.Equals(TargetOf(p[i]).path, devicePath, StringComparison.OrdinalIgnoreCase)) hit = i;
    if (hit < 0) return "it isn't on this PC's desktop";
    if (p.Length < 2) return "it's this PC's only screen";
    var q = (PathInfo[])p.Clone();
    q[hit].flags &= ~1u; q[hit].src.mode = 0xFFFFFFFF; q[hit].tgt.mode = 0xFFFFFFFF;   // inactive, no modes
    int r = SetDisplayConfig((uint)q.Length, q, (uint)m.Length, m, SdcSupplied | SdcAllowChanges | (validate ? SdcValidate : SdcApply));
    if (r != 0) return "Windows refused (error " + r + ")";
    if (!validate && savedPaths == null) { savedPaths = p; savedModes = m; }   // the setup before the first monitor was taken off
    return "";
  }
  public static string Reattach() {
    if (savedPaths == null) return "";
    int r = SetDisplayConfig((uint)savedPaths.Length, savedPaths, (uint)savedModes.Length, savedModes, SdcSupplied | SdcAllowChanges | SdcApply);
    if (r != 0) r = SetDisplayConfig(0, null, 0, null, SdcApply | SdcExtend);   // fall back to Windows' own extended layout
    savedPaths = null; savedModes = null;
    return r == 0 ? "" : "Windows refused (error " + r + ")";
  }

  // ---------- discovery: 255.255.255.255 leaves through one adapter only, so also send each subnet's broadcast ----------
  public static List<IPAddress> Broadcasts() {
    var o = new List<IPAddress> { IPAddress.Broadcast };
    foreach (var ni in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces()) {
      if (ni.OperationalStatus != System.Net.NetworkInformation.OperationalStatus.Up) continue;
      foreach (var u in ni.GetIPProperties().UnicastAddresses) {
        if (u.Address.AddressFamily != AddressFamily.InterNetwork || u.IPv4Mask == null || IPAddress.IsLoopback(u.Address)) continue;
        byte[] a = u.Address.GetAddressBytes(), m = u.IPv4Mask.GetAddressBytes();
        for (int i = 0; i < 4; i++) a[i] |= (byte)~m[i];
        o.Add(new IPAddress(a));
      }
    }
    return o;
  }

  // ---------- pairing and authentication ----------
  const string Alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";   // 32 symbols, no I/O/0/1

  public static string NewCode() {   // 8 symbols = 40 bits, shown as ABCD-EFGH
    var b = new byte[8]; using (var r = new RNGCryptoServiceProvider()) r.GetBytes(b);
    var s = new StringBuilder();
    for (int i = 0; i < 8; i++) { if (i == 4) s.Append('-'); s.Append(Alphabet[b[i] % 32]); }
    return s.ToString();
  }
  public static string NormCode(string code) {
    var s = new StringBuilder();
    foreach (char c in (code ?? "").ToUpperInvariant()) if (Alphabet.IndexOf(c) >= 0) s.Append(c);
    return s.ToString();
  }
  public static byte[] DeriveKey(string code) {
    using (var k = new Rfc2898DeriveBytes(NormCode(code), Encoding.UTF8.GetBytes("DeskGlide pairing v2"), 100000, HashAlgorithmName.SHA256))
      return k.GetBytes(32);
  }
  static byte[] Mac(byte[] key, byte[] data, int len) { using (var h = new HMACSHA256(key)) return h.ComputeHash(data, 0, len); }

  // ---------- encryption: AES-256-CBC, then HMAC-SHA256 over it (encrypt-then-MAC; .NET Framework has no AES-GCM) ----------
  static readonly RandomNumberGenerator Rng = RandomNumberGenerator.Create();
  public static byte[] Random(int n) { var b = new byte[n]; lock (Rng) Rng.GetBytes(b); return b; }
  // A key for one session (a sound stream, a file transfer): the pairing key with a purpose and fresh random nonces
  public static byte[] SessionKey(byte[] pairKey, string purpose, byte[] nonce) {
    byte[] p = Encoding.UTF8.GetBytes("DeskGlide " + purpose + " "), b = new byte[p.Length + nonce.Length];
    p.CopyTo(b, 0); nonce.CopyTo(b, p.Length); return Mac(pairKey, b, b.Length);
  }
  public const int CryptoOverhead = 16 + 16 + 16;   // IV, up to one block of padding, tag
  static byte[] SubKey(byte[] key, string label) { var b = Encoding.ASCII.GetBytes(label); return Mac(key, b, b.Length); }
  // [IV:16][AES-CBC ciphertext][tag:16], tag = HMAC-SHA256(mac key, ad + IV + ciphertext) cut to 16 bytes. ad: authenticated, not sent.
  public static byte[] Encrypt(byte[] key, byte[] ad, byte[] data, int off, int len) {
    byte[] iv = Random(16), ct;
    using (var a = Aes.Create()) { a.Key = SubKey(key, "enc"); a.IV = iv; a.Mode = CipherMode.CBC; a.Padding = PaddingMode.PKCS7; using (var e = a.CreateEncryptor()) ct = e.TransformFinalBlock(data, off, len); }
    var o = new byte[16 + ct.Length + 16];
    iv.CopyTo(o, 0); ct.CopyTo(o, 16);
    Buffer.BlockCopy(Tag(key, ad, o, 16 + ct.Length), 0, o, 16 + ct.Length, 16);
    return o;
  }
  // The data, or null if the key is wrong or anything was changed (checked before decrypting).
  public static byte[] Decrypt(byte[] key, byte[] ad, byte[] p, int off, int len) {
    if (key == null || p == null || len < 48 || (len - 32) % 16 != 0 || off < 0 || off + len > p.Length) return null;
    var body = new byte[len]; Buffer.BlockCopy(p, off, body, 0, len);
    if (!Same(Tag(key, ad, body, len - 16), body, len - 16, 16)) return null;
    var iv = new byte[16]; Buffer.BlockCopy(body, 0, iv, 0, 16);
    using (var a = Aes.Create()) { a.Key = SubKey(key, "enc"); a.IV = iv; a.Mode = CipherMode.CBC; a.Padding = PaddingMode.PKCS7; using (var d = a.CreateDecryptor()) return d.TransformFinalBlock(body, 16, len - 32); }
  }
  static byte[] Tag(byte[] key, byte[] ad, byte[] b, int n) {
    using (var h = new HMACSHA256(SubKey(key, "mac"))) { if (ad != null && ad.Length > 0) h.TransformBlock(ad, 0, ad.Length, null, 0); h.TransformFinalBlock(b, 0, n); return h.Hash; }
  }
  static bool Same(byte[] a, byte[] b, int bOff, int n) { int d = 0; for (int i = 0; i < n; i++) d |= a[i] ^ b[bOff + i]; return d == 0; }

  // Control message: base64(HMAC-SHA256(json)) + "|" + json.
  public static string Seal(byte[] key, string json) {
    byte[] b = Encoding.UTF8.GetBytes(json);
    return Convert.ToBase64String(Mac(key, b, b.Length)) + "|" + json;
  }
  // Returns the json, or null if the tag is wrong (other key, tampered, garbage).
  public static string Open(byte[] key, string pkt) {
    if (key == null || pkt == null || pkt.IndexOf('|') != 44) return null;
    byte[] tag; try { tag = Convert.FromBase64String(pkt.Substring(0, 44)); } catch (FormatException) { return null; }
    string json = pkt.Substring(45); byte[] b = Encoding.UTF8.GetBytes(json);
    return tag.Length == 32 && Same(Mac(key, b, b.Length), tag, 0, 32) ? json : null;
  }

  // Audio packet (sound and microphone): [session nonce:16][Encrypt(session key, nonce, [rate:4][channels:2][seq:2][16-bit PCM])].
  // The sender picks the nonce at random for each stream; the session key is the pairing key with that nonce. Each packet
  // also gets its own random IV (Encrypt). About 1.2 KB per 6 ms of 48 kHz stereo.
  static byte[] txNonce, txKey, txFor, rxNonce, rxKey, rxFor;
  public static void NewAudioSession() { txNonce = null; }
  public static byte[] MakePacket(byte[] key, int rate, int ch, ushort seq, byte[] pcm, int len) {
    if (txNonce == null || txFor != key) { txNonce = Random(16); txKey = SessionKey(key, "audio", txNonce); txFor = key; }
    var plain = new byte[8 + len];
    BitConverter.GetBytes(rate).CopyTo(plain, 0); BitConverter.GetBytes((ushort)ch).CopyTo(plain, 4); BitConverter.GetBytes(seq).CopyTo(plain, 6);
    Buffer.BlockCopy(pcm, 0, plain, 8, len);
    byte[] e = Encrypt(txKey, txNonce, plain, 0, plain.Length), p = new byte[16 + e.Length];
    txNonce.CopyTo(p, 0); e.CopyTo(p, 16); return p;
  }
  // The decrypted [rate][channels][seq][PCM], or null if it isn't from the paired PC, was changed, or makes no sense.
  public static byte[] OpenPacket(byte[] key, byte[] p, out int rate, out int ch) {
    rate = 0; ch = 0;
    if (key == null || p == null || p.Length < 16 + CryptoOverhead || p.Length > 16 + 8192 + CryptoOverhead) return null;
    if (rxNonce == null || rxFor != key || !Same(rxNonce, p, 0, 16)) {   // a new stream: derive its key once
      var n = new byte[16]; Buffer.BlockCopy(p, 0, n, 0, 16); rxKey = SessionKey(key, "audio", n); rxNonce = n; rxFor = key;
    }
    byte[] d = Decrypt(rxKey, rxNonce, p, 16, p.Length - 16);
    if (d == null || d.Length < 10) return null;
    rate = BitConverter.ToInt32(d, 0); ch = BitConverter.ToUInt16(d, 4);
    return rate >= 8000 && rate <= 192000 && ch >= 1 && ch <= 2 && (d.Length - 8) % (ch * 2) == 0 ? d : null;
  }

  // ---------- audio threads: DeskGlide.ps1 sets these flags, the threads do the rest ----------
  // Each PC sends one stream and receives one: the headphones PC receives the other PC's sound and sends its microphone,
  // the other PC sends its sound and plays that microphone into VB-Cable. So one port and one packet format serve both.
  public const int Sound = 1, Mic = 2;
  public static volatile int SendMode, RecvMode;   // 0 off, Sound (loopback of the default output) or Mic (default microphone)
  public static volatile int RecvDevice = -1;      // waveOut device to play into: -1 = default output, else CABLE Input
  public static volatile bool RemoteOn;
  public static volatile IPEndPoint Target;
  public static volatile byte[] Key;
  public static int Sent, Got, Bad;
  public static string LastError = "";

  public static void StartAudio(int port) {
    var t = new Thread(SendLoop); t.IsBackground = true; t.Start();
    var r = new Thread(() => RecvLoop(port)); r.IsBackground = true; r.Start();
  }
  static void SendLoop() {
    while (true) {
      try {
        if (SendMode != capMode) StopCapture();   // switched between sound and microphone
        if (SendMode != 0) { if (udp == null) udp = new UdpClient(); Sent += PumpSend(100); } else Thread.Sleep(100);
      } catch (Exception e) { LastError = e.Message; Thread.Sleep(1000); }
    }
  }
  static void RecvLoop(int port) {
    while (true) {
      try {
        if (RecvMode != 0) { if (rx == null) { rx = new UdpClient(port); rx.Client.ReceiveTimeout = 20; } Got += PumpReceive(100); }
        else { CloseOut(); if (rx != null) { rx.Close(); rx = null; } Thread.Sleep(100); }
      } catch (Exception e) { LastError = e.Message; Thread.Sleep(1000); }
    }
  }

  // waveOut device whose name starts with this ("CABLE Input" for VB-Audio Virtual Cable), or -1
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  struct WAVEOUTCAPS { public ushort mid, pid; public uint ver; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string name; public uint formats; public ushort ch, res; public uint support; }
  [DllImport("winmm.dll")] static extern int waveOutGetNumDevs();
  [DllImport("winmm.dll", CharSet=CharSet.Unicode)] static extern int waveOutGetDevCaps(IntPtr id, ref WAVEOUTCAPS c, int size);
  public static string[] OutputDevices() {
    var o = new List<string>();
    for (int i = 0, n = waveOutGetNumDevs(); i < n; i++) { var c = new WAVEOUTCAPS(); o.Add(waveOutGetDevCaps(new IntPtr(i), ref c, Marshal.SizeOf(c)) == 0 ? c.name : ""); }
    return o.ToArray();
  }
  public static int FindOutput(string prefix) {
    var d = OutputDevices();
    for (int i = 0; i < d.Length; i++) if (d[i].StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return i;
    return -1;
  }

  // ---------- WASAPI capture: loopback of the default output, or the default microphone (COM interop) ----------
  [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorCo {}
  [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDeviceEnumerator {
    int EnumAudioEndpoints(int flow, int mask, out IntPtr devices);
    int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice device);
  }
  [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDevice {
    int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o);
  }
  [ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IAudioClient {
    int Initialize(int shareMode, int flags, long bufferDuration, long periodicity, IntPtr format, IntPtr session);
    int GetBufferSize(out uint n);
    int GetStreamLatency(out long l);
    int GetCurrentPadding(out uint p);
    int IsFormatSupported(int m, IntPtr f, out IntPtr c);
    int GetMixFormat(out IntPtr format);
    int GetDevicePeriod(out long d, out long m);
    int Start(); int Stop(); int Reset();
    int SetEventHandle(IntPtr h);
    int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object o);
  }
  [ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IAudioCaptureClient {
    int GetBuffer(out IntPtr data, out uint frames, out uint flags, out ulong pos, out ulong qpc);
    int ReleaseBuffer(uint frames);
    int GetNextPacketSize(out uint frames);
  }
  static void Check(int hr) { if (hr < 0) Marshal.ThrowExceptionForHR(hr); }

  static IAudioClient client; static IAudioCaptureClient capture; static int capMode;
  static int srcCh, srcRate, srcBits; static bool srcFloat;
  static UdpClient udp; static ushort seq;
  static byte[] outBuf = new byte[4096]; static int outLen;
  const int ChunkFrames = 288;   // 6 ms at 48 kHz; 1152 bytes stereo, fits one UDP packet

  static void InitCapture() {
    var en = (IMMDeviceEnumerator)new MMDeviceEnumeratorCo();
    int mode = SendMode; bool mic = mode == Mic;
    IMMDevice dev; Check(en.GetDefaultAudioEndpoint(mic ? 1 : 0, 0, out dev));   // eCapture or eRender, eConsole
    Guid iid = typeof(IAudioClient).GUID; object o;
    Check(dev.Activate(ref iid, 23, IntPtr.Zero, out o)); client = (IAudioClient)o;
    IntPtr fmt; Check(client.GetMixFormat(out fmt));
    int tag = (ushort)Marshal.ReadInt16(fmt, 0);
    srcCh = Marshal.ReadInt16(fmt, 2); srcRate = Marshal.ReadInt32(fmt, 4); srcBits = Marshal.ReadInt16(fmt, 14);
    srcFloat = tag == 3 || (tag == 0xFFFE && Marshal.ReadInt32(fmt, 24) == 3);
    try { Check(client.Initialize(0, mic ? 0 : 0x00020000, 1000000, 0, fmt, IntPtr.Zero)); }   // shared, LOOPBACK for sound, 100 ms
    finally { Marshal.FreeCoTaskMem(fmt); }
    iid = typeof(IAudioCaptureClient).GUID;
    Check(client.GetService(ref iid, out o)); capture = (IAudioCaptureClient)o;
    Check(client.Start());
    outLen = 0; capMode = mode; NewAudioSession();   // a new stream gets a new session key
  }

  static void StopCapture() {
    if (client == null) return;
    try { client.Stop(); } catch {}
    if (capture != null) Marshal.ReleaseComObject(capture);
    Marshal.ReleaseComObject(client);
    capture = null; client = null; capMode = 0;
  }

  public static short ToPcm16(float v) {
    int s = (int)(v * 32767f);
    return (short)(s > 32767 ? 32767 : s < -32768 ? -32768 : s);
  }

  // Captures and sends for about ms milliseconds. Returns packets sent.
  static int PumpSend(int ms) {
    int sent = 0; DateTime end = DateTime.UtcNow.AddMilliseconds(ms);
    while (DateTime.UtcNow < end) {
      try {
        if (client == null) InitCapture();
        uint n; Check(capture.GetNextPacketSize(out n));
        if (n == 0) { Thread.Sleep(3); continue; }
        IntPtr data; uint frames, flags; ulong p1, p2;
        Check(capture.GetBuffer(out data, out frames, out flags, out p1, out p2));
        int bps = srcBits / 8, bpf = srcCh * bps;
        byte[] raw = new byte[frames * bpf];
        if ((flags & 2) == 0) Marshal.Copy(data, raw, 0, raw.Length);   // 2 = SILENT: keep zeros
        Check(capture.ReleaseBuffer(frames));
        int och = Math.Min(srcCh, 2);   // ponytail: surround sound is cut to front left/right
        for (int f = 0; f < frames; f++) {
          for (int c = 0; c < och; c++) {
            int off = f * bpf + c * bps; float v;
            if (srcFloat) v = BitConverter.ToSingle(raw, off);
            else if (srcBits == 16) v = BitConverter.ToInt16(raw, off) / 32768f;
            else if (srcBits == 24) v = (raw[off] | raw[off + 1] << 8 | (sbyte)raw[off + 2] << 16) / 8388608f;
            else v = BitConverter.ToInt32(raw, off) / 2147483648f;
            short s = ToPcm16(v);
            outBuf[outLen++] = (byte)s; outBuf[outLen++] = (byte)(s >> 8);
          }
          if (outLen >= ChunkFrames * och * 2) {
            byte[] pkt = MakePacket(Key, srcRate, och, seq++, outBuf, outLen); outLen = 0;
            IPEndPoint t = Target; if (t != null) { udp.Send(pkt, pkt.Length, t); sent++; }
          }
        }
        LastError = "";
      } catch (Exception e) {
        // device changed or unplugged: rebuild capture on the next pass
        LastError = e.Message; StopCapture(); Thread.Sleep(1000);
      }
    }
    return sent;
  }

  // ---------- winmm playback ----------
  [StructLayout(LayoutKind.Sequential)] struct WAVEFORMATEX { public ushort tag, ch; public uint rate, avg; public ushort align, bits, cb; }
  [StructLayout(LayoutKind.Sequential)] struct WAVEHDR { public IntPtr data; public uint len, rec; public IntPtr user; public uint flags, loops; public IntPtr next, reserved; }
  [DllImport("winmm.dll")] static extern int waveOutOpen(out IntPtr h, int dev, ref WAVEFORMATEX f, IntPtr cb, IntPtr inst, int flags);
  [DllImport("winmm.dll")] static extern int waveOutPrepareHeader(IntPtr h, IntPtr hdr, int size);
  [DllImport("winmm.dll")] static extern int waveOutUnprepareHeader(IntPtr h, IntPtr hdr, int size);
  [DllImport("winmm.dll")] static extern int waveOutWrite(IntPtr h, IntPtr hdr, int size);
  [DllImport("winmm.dll")] static extern int waveOutReset(IntPtr h);
  [DllImport("winmm.dll")] static extern int waveOutClose(IntPtr h);

  static readonly int HdrSize = Marshal.SizeOf(typeof(WAVEHDR));
  static readonly int LenOff = (int)Marshal.OffsetOf(typeof(WAVEHDR), "len");
  static readonly int FlagsOff = (int)Marshal.OffsetOf(typeof(WAVEHDR), "flags");
  const int Blocks = 6;      // 10 ms each: at most ~60 ms queued in the sound card
  const int MaxPending = 3;  // at most ~30 ms waiting; older audio is dropped so delay stays low
  const int Prebuffer = 2;   // after a gap, wait for 20 ms of audio before playing (fewer clicks)

  static UdpClient rx;
  static IntPtr wave = IntPtr.Zero; static int wRate, wCh, wDev = -2, blockBytes;
  static IntPtr[] hdrs, datas; static bool[] busy;
  static Queue<byte[]> pending = new Queue<byte[]>();
  static byte[] fill; static int fillLen;

  // Receives and plays for about ms milliseconds. Returns authenticated packets.
  static int PumpReceive(int ms) {
    int got = 0; DateTime end = DateTime.UtcNow.AddMilliseconds(ms);
    while (DateTime.UtcNow < end) {
      byte[] p; IPEndPoint ep = null;
      try { p = rx.Receive(ref ep); } catch (SocketException) { Feed(); continue; }
      int rate, ch; p = OpenPacket(Key, p, out rate, out ch);
      if (p == null) { Bad++; continue; }
      got++;
      if (RecvMode == Sound && !RemoteOn) continue;   // follow mode: the mouse is on this PC, drop the other PC's sound
      if (wave == IntPtr.Zero || rate != wRate || ch != wCh || RecvDevice != wDev) OpenOut(rate, ch);
      if (RecvMode == Sound) Scale(p, 8, p.Length - 8, Volume);   // the volume slider is for the other PC's sound, not its microphone
      for (int i = 8, n = p.Length; i < n; ) {
        int k = Math.Min(blockBytes - fillLen, n - i);
        Buffer.BlockCopy(p, i, fill, fillLen, k); fillLen += k; i += k;
        if (fillLen == blockBytes) { pending.Enqueue(fill); fill = new byte[blockBytes]; fillLen = 0; }
      }
      Feed();
    }
    return got;
  }

  static void Feed() {
    if (wave == IntPtr.Zero) return;
    int inFlight = 0;
    for (int i = 0; i < Blocks; i++) {
      if (busy[i] && (Marshal.ReadInt32(hdrs[i], FlagsOff) & 1) != 0) busy[i] = false;   // WHDR_DONE
      if (busy[i]) inFlight++;
    }
    while (pending.Count > MaxPending) pending.Dequeue();
    if (inFlight == 0 && pending.Count < Prebuffer) return;
    for (int i = 0; i < Blocks && pending.Count > 0; i++) {
      if (busy[i]) continue;
      byte[] b = pending.Dequeue();
      Marshal.Copy(b, 0, datas[i], blockBytes);
      Marshal.WriteInt32(hdrs[i], LenOff, blockBytes);
      Marshal.WriteInt32(hdrs[i], FlagsOff, Marshal.ReadInt32(hdrs[i], FlagsOff) & ~1);
      if (waveOutWrite(wave, hdrs[i], HdrSize) == 0) busy[i] = true;
    }
  }

  static void OpenOut(int rate, int ch) {
    CloseOut();
    var f = new WAVEFORMATEX { tag = 1, ch = (ushort)ch, rate = (uint)rate, bits = 16,
                               align = (ushort)(ch * 2), avg = (uint)(rate * ch * 2), cb = 0 };
    int dev = RecvDevice; int r = waveOutOpen(out wave, dev, ref f, IntPtr.Zero, IntPtr.Zero, 0);   // -1 = default output device
    if (r != 0) { wave = IntPtr.Zero; throw new InvalidOperationException("waveOutOpen failed: " + r); }
    wRate = rate; wCh = ch; wDev = dev; blockBytes = rate / 100 * ch * 2;
    fill = new byte[blockBytes]; fillLen = 0; pending.Clear();
    hdrs = new IntPtr[Blocks]; datas = new IntPtr[Blocks]; busy = new bool[Blocks];
    for (int i = 0; i < Blocks; i++) {
      datas[i] = Marshal.AllocHGlobal(blockBytes);
      hdrs[i] = Marshal.AllocHGlobal(HdrSize);
      Marshal.Copy(new byte[HdrSize], 0, hdrs[i], HdrSize);
      Marshal.WriteIntPtr(hdrs[i], 0, datas[i]);
      Marshal.WriteInt32(hdrs[i], LenOff, blockBytes);
      waveOutPrepareHeader(wave, hdrs[i], HdrSize);
    }
  }

  static void CloseOut() {
    if (wave == IntPtr.Zero) return;
    waveOutReset(wave);
    for (int i = 0; i < Blocks; i++) {
      waveOutUnprepareHeader(wave, hdrs[i], HdrSize);
      Marshal.FreeHGlobal(hdrs[i]); Marshal.FreeHGlobal(datas[i]);
    }
    waveOutClose(wave); wave = IntPtr.Zero;
  }

  // ---------- follow the mouse: per-app mute on this PC ----------
  public static HashSet<string> Muted = new HashSet<string>();   // session ids WE muted

  [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IAudioSessionManager2 {
    int GetAudioSessionControl(IntPtr g, int f, out IntPtr c);
    int GetSimpleAudioVolume(IntPtr g, int f, out IntPtr v);
    int GetSessionEnumerator(out IAudioSessionEnumerator e);
  }
  [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IAudioSessionEnumerator {
    int GetCount(out int n);
    int GetSession(int i, [MarshalAs(UnmanagedType.IUnknown)] out object s);
  }
  [ComImport, Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IAudioSessionControl2 {
    int GetState(out int s);
    int GetDisplayName(out IntPtr n);
    int SetDisplayName(IntPtr n, IntPtr g);
    int GetIconPath(out IntPtr p);
    int SetIconPath(IntPtr p, IntPtr g);
    int GetGroupingParam(out Guid g);
    int SetGroupingParam(IntPtr g, IntPtr c);
    int RegisterAudioSessionNotification(IntPtr n);
    int UnregisterAudioSessionNotification(IntPtr n);
    int GetSessionIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string id);
    int GetSessionInstanceIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string id);
    int GetProcessId(out uint pid);
  }
  [ComImport, Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface ISimpleAudioVolume {
    int SetMasterVolume(float v, IntPtr ctx);
    int GetMasterVolume(out float v);
    int SetMute(bool m, IntPtr ctx);
    int GetMute(out bool m);
  }

  // mute=true: mute every app on the default output except selfPid (new apps get caught on the next call).
  // mute=false: unmute only the apps we muted, so apps the user muted stay muted.
  public static void MuteOthers(bool mute, int selfPid) {
    var en = (IMMDeviceEnumerator)new MMDeviceEnumeratorCo();
    IMMDevice dev; Check(en.GetDefaultAudioEndpoint(0, 0, out dev));
    Guid iid = typeof(IAudioSessionManager2).GUID; object o;
    Check(dev.Activate(ref iid, 23, IntPtr.Zero, out o));
    var mgr = (IAudioSessionManager2)o;
    IAudioSessionEnumerator list; Check(mgr.GetSessionEnumerator(out list));
    int n; Check(list.GetCount(out n));
    for (int i = 0; i < n; i++) {
      object s; if (list.GetSession(i, out s) < 0 || s == null) continue;
      try {
        var ctl = (IAudioSessionControl2)s; var vol = (ISimpleAudioVolume)s;
        uint pid; ctl.GetProcessId(out pid);
        if (pid == (uint)selfPid) continue;
        string id; if (ctl.GetSessionIdentifier(out id) < 0 || id == null) continue;
        bool m; vol.GetMute(out m);
        if (mute && !m) { vol.SetMute(true, IntPtr.Zero); Muted.Add(id); }
        else if (!mute && m && Muted.Contains(id)) vol.SetMute(false, IntPtr.Zero);
      } finally { Marshal.ReleaseComObject(s); }
    }
    if (!mute) Muted.Clear();
    Marshal.ReleaseComObject(list); Marshal.ReleaseComObject(mgr); Marshal.ReleaseComObject(dev); Marshal.ReleaseComObject(en);
  }
}

// ======================= DeskGlide Link: DeskGlide's own keyboard and mouse sharing =======================
// The PC the keyboard and mouse are plugged into (the sender) reads the mouse with Raw Input. While the other PC has
// control, low-level hooks swallow local input (they only enqueue and return) and the sender moves its own model of the
// other PC's pointer over that PC's monitors, sending absolute positions: a lost packet never shifts the pointer. Keys,
// buttons and the wheel go on a reliable stream. One UDP datagram:
//   'D' 'L' [protocol] [kind: 0 hello, 1 session] [sender nonce:8]  Dg.Encrypt(key, those 12 bytes, body)
// hello (the same in every protocol version): key = SessionKey(pairing, "link hello"), body = [their nonce we know:8][time ms:8][name]
// session: key = SessionKey(pairing, "link", lower nonce + higher nonce), body = [type][ack:4] then
//   H heartbeat [seq:4][time us:4][echo:4][held us:4][flags: 1 = a game holds the pointer][pointer x:4 y:4][n][n x (l t r b:4, dpi:2)]
//   M mouse     [seq:4][mode: 0 absolute, 1 relative running sums][x:4][y:4]
//   R reliable  [seq:4] + E enter [x:4 y:4] | L leave | K key [scan][flags: 1 up, 2 extended][vk][modifiers]
//               | B button [b][down][relative][x:4 y:4] | W wheel [horizontal][delta:2] | X lock this PC too
//   A ack only

public struct Mon {   // a monitor in physical pixels; R and B exclusive
  public int L, T, R, B, Dpi;
  public Mon(int l, int t, int r, int b, int dpi) { L = l; T = t; R = r; B = b; Dpi = dpi > 0 ? dpi : 96; }
  public bool Has(int x, int y) { return x >= L && x < R && y >= T && y < B; }
}

// Screen geometry: where the pointer leaves one PC and enters the other. Edges are 'l', 'r', 'u', 'd'.
public static class Geo {
  public static int Find(Mon[] ms, int x, int y) { for (int i = 0; i < ms.Length; i++) if (ms[i].Has(x, y)) return i; return -1; }
  public static int F(double v) { return (int)Math.Floor(v); }
  public static char Opp(char d) { return d == 'l' ? 'r' : d == 'r' ? 'l' : d == 'u' ? 'd' : 'u'; }
  static bool Side(char d) { return d == 'l' || d == 'r'; }   // a left or right edge: positions along it are y
  static void Span(Mon[] ms, bool side, out int a, out int b) {   // the whole desktop along such an edge: [a, b)
    a = int.MaxValue; b = int.MinValue;
    foreach (var m in ms) { a = Math.Min(a, side ? m.T : m.L); b = Math.Max(b, side ? m.B : m.R); }
  }
  public static void Bounds(Mon[] ms, out int x, out int y, out int w, out int h) {
    int l = int.MaxValue, t = int.MaxValue, r = int.MinValue, b = int.MinValue;
    foreach (var m in ms) { l = Math.Min(l, m.L); t = Math.Min(t, m.T); r = Math.Max(r, m.R); b = Math.Max(b, m.B); }
    x = l; y = t; w = r - l; h = b - t;
  }
  // Where along this PC's 'dir' edge the pointer leaves (0..1 over the whole desktop), or -1: it isn't pushing out through
  // an outer edge (another monitor is there), or it is in a corner's dead zone.
  public static double Leave(Mon[] ms, int x, int y, double dx, double dy, char dir, int dead) {
    int i = Find(ms, x, y); if (i < 0) return -1;
    Mon m = ms[i];
    bool o = dir == 'r' ? dx > 0 && x >= m.R - 1 && Find(ms, m.R, y) < 0
           : dir == 'l' ? dx < 0 && x <= m.L && Find(ms, m.L - 1, y) < 0
           : dir == 'd' ? dy > 0 && y >= m.B - 1 && Find(ms, x, m.B) < 0
           : dir == 'u' && dy < 0 && y <= m.T && Find(ms, x, m.T - 1) < 0;
    if (!o) return -1;
    bool s = Side(dir); int at = s ? y : x, lo = s ? m.T : m.L, hi = s ? m.B : m.R;
    if (at < lo + dead || at >= hi - dead) return -1;
    int a, b; Span(ms, s, out a, out b);
    return (at - a + 0.5) / (b - a);
  }
  // Where the pointer enters through this PC's 'side' edge at f (0..1): on the outermost monitor there, at the same relative
  // position, so a pointer leaving halfway down one PC's screens enters halfway down the other's.
  public static void Entry(Mon[] ms, char side, double f, out int x, out int y) {
    bool s = Side(side); int a, b; Span(ms, s, out a, out b);
    int at = Math.Max(a, Math.Min(b - 1, a + F(f * (b - a)))), best = 0; long bMiss = long.MaxValue, bOut = long.MaxValue;
    for (int i = 0; i < ms.Length; i++) {
      Mon m = ms[i]; int lo = s ? m.T : m.L, hi = s ? m.B : m.R;
      long miss = at < lo ? lo - at : at >= hi ? at - hi + 1 : 0, outer = side == 'l' ? m.L : side == 'r' ? -m.R : side == 'u' ? m.T : -m.B;
      if (miss < bMiss || (miss == bMiss && outer < bOut)) { bMiss = miss; bOut = outer; best = i; }
    }
    Mon w = ms[best];
    if (s) { x = side == 'l' ? w.L : w.R - 1; y = Math.Max(w.T, Math.Min(w.B - 1, at)); }
    else { y = side == 'u' ? w.T : w.B - 1; x = Math.Max(w.L, Math.Min(w.R - 1, at)); }
  }
  // Moves the pointer (x, y) by (dx, dy) over the monitors ms; off every monitor it stays on its own, clamped.
  // Returns where along the 'back' edge it leaves (see Leave), or -1. back '\0' = never leaves.
  public static double Move(Mon[] ms, ref double x, ref double y, double dx, double dy, char back, int dead) {
    if (ms.Length == 0) return -1;
    double nx = x + dx, ny = y + dy;
    if (Find(ms, F(nx), F(ny)) >= 0) { x = nx; y = ny; return -1; }
    int i = Find(ms, F(x), F(y)); Mon m = ms[i < 0 ? 0 : i];
    x = Math.Max(m.L, Math.Min(m.R - 1, nx)); y = Math.Max(m.T, Math.Min(m.B - 1, ny));
    return back == '\0' ? -1 : Leave(ms, F(x), F(y), dx, dy, back, dead);
  }
  public static int DpiAt(Mon[] ms, double x, double y) { int i = Find(ms, F(x), F(y)); return i < 0 ? 96 : ms[i].Dpi; }
  // Mouse counts on the sender -> pixels on the receiver: the user's speed times the receiver's DPI over the sender's
  public static double Scale(int speedPct, int dpiFrom, int dpiTo) { return speedPct / 100.0 * (dpiTo > 0 ? dpiTo : 96) / (dpiFrom > 0 ? dpiFrom : 96); }
  // A pixel -> SendInput's 0..65535 across the virtual desktop (MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK). Windows takes
  // pixel = n * size / 65536; aiming at the pixel's centre lands on it whether Windows truncates or rounds (the old
  // round(v * 65535 / (size - 1)) landed one pixel short in places).
  public static int Norm(int v, int origin, int size) { return size <= 1 ? 0 : (int)Math.Min(65535, ((long)(v - origin) * 65536 + 32768) / size); }
  // A point -> the nearest point on a monitor, so every edge row (the taskbar's too) is reachable and nothing lands off-screen
  public static void Clamp(Mon[] ms, ref int x, ref int y) {
    if (ms.Length == 0 || Find(ms, x, y) >= 0) return;
    long best = long.MaxValue; int bx = x, by = y;
    foreach (var m in ms) {
      int cx = Math.Max(m.L, Math.Min(m.R - 1, x)), cy = Math.Max(m.T, Math.Min(m.B - 1, y));
      long d = (long)(cx - x) * (cx - x) + (long)(cy - y) * (cy - y);
      if (d < best) { best = d; bx = cx; by = cy; }
    }
    x = bx; y = by;
  }
}

// Relative movement (game mode): float deltas add up, whole pixels go out, the fraction stays for the next packet.
public class Coalescer {
  public double X, Y;
  public void Add(double dx, double dy) { X += dx; Y += dy; }
  public bool Take(out int dx, out int dy) { dx = (int)X; dy = (int)Y; X -= dx; Y -= dy; return dx != 0 || dy != 0; }
}

public static class KeyMap {
  // Every key packet carries all modifiers as bits: 0 LShift, 1 RShift, 2 LCtrl, 3 RCtrl, 4 LAlt, 5 RAlt, 6 LWin, 7 RWin
  public static readonly int[] Vk = { 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0x5B, 0x5C };
  public static readonly int[] Sc = { 0x2A, 0x36, 0x1D, 0x1D, 0x38, 0x38, 0x5B, 0x5C };
  public static readonly bool[] Ext = { false, false, false, true, false, true, true, true };
  public static int Apply(int mods, int vk, bool up) { int b = Array.IndexOf(Vk, vk); return b < 0 ? mods : up ? mods & ~(1 << b) : mods | (1 << b); }
  // What the receiver presses (bit | 0x100) or releases (bit) so its modifiers (have) match the sender's (want)
  public static List<int> Reconcile(int want, int have) {
    var o = new List<int>();
    for (int b = 0; b < 8; b++) { int w = (want >> b) & 1; if (w != ((have >> b) & 1)) o.Add(b | (w << 8)); }
    return o;
  }
  // AltGr arrives as a fake LCtrl (scan code 0x21D) plus RAlt; the receiver's own layout adds its own fake LCtrl
  public static bool FakeCtrl(int vk, int sc) { return vk == 0xA2 && (sc & 0x200) != 0; }
  // Modifier bits -> RegisterHotKey's (1 Alt, 2 Ctrl, 4 Shift, 8 Win)
  public static int HotMods(int mods) { return ((mods & 0x0C) != 0 ? 2 : 0) | ((mods & 0x30) != 0 ? 1 : 0) | ((mods & 3) != 0 ? 4 : 0) | ((mods & 0xC0) != 0 ? 8 : 0); }
}

// What the receiver injected and hasn't released: on leave or loss all of it goes up.
public class Held {
  readonly HashSet<int> keys = new HashSet<int>(); int buttons;   // key: scan | 0x100 extended, or 0x10000 | vk
  public void Key(int code, bool up) { if (up) keys.Remove(code); else keys.Add(code); }
  public void Button(int b, bool down) { if (down) buttons |= 1 << b; else buttons &= ~(1 << b); }
  public int Mods() { int m = 0; for (int b = 0; b < 8; b++) if (keys.Contains(KeyMap.Sc[b] | (KeyMap.Ext[b] ? 0x100 : 0))) m |= 1 << b; return m; }
  public List<int> TakeKeys() { var o = new List<int>(keys); keys.Clear(); return o; }
  public List<int> TakeButtons() { var o = new List<int>(); for (int b = 0; b < 5; b++) if ((buttons & 1 << b) != 0) o.Add(b); buttons = 0; return o; }
}

// Keys, buttons and the wheel: numbered, sent a second time 5 ms later unless acknowledged by then, resent every timeout
// until acknowledged (never given up while the link lives), delivered once and in order.
public class Reliable {
  public const int Dup = 5;
  public class Item { public uint Seq; public byte[] Data; public long SentAt; public int Sends = 1; }
  uint next = 1, rxNext = 1;
  readonly List<Item> outq = new List<Item>(); readonly Dictionary<uint, byte[]> early = new Dictionary<uint, byte[]>();
  public uint Ack { get { return rxNext - 1; } }   // everything up to here arrived
  public int Pending { get { return outq.Count; } }
  public Item Add(byte[] data, long now) { var it = new Item { Seq = next++, Data = data, SentAt = now }; outq.Add(it); return it; }
  public void Acked(uint ack) { outq.RemoveAll(i => (int)(ack - i.Seq) >= 0); }
  public List<Item> Due(long now, int rto) {
    var o = new List<Item>();
    foreach (var i in outq) if (now - i.SentAt >= (i.Sends == 1 ? Dup : rto)) { i.SentAt = now; i.Sends++; o.Add(i); }
    return o;
  }
  public List<byte[]> Got(uint seq, byte[] data) {   // what can be delivered now, in order
    var o = new List<byte[]>(); int ahead = (int)(seq - rxNext);
    if (ahead < 0 || ahead > 4096) return o;   // a duplicate, or nonsense
    early[seq] = data;
    byte[] d; while (early.TryGetValue(rxNext, out d)) { early.Remove(rxNext); o.Add(d); rxNext++; }
    return o;
  }
}

// The link's heartbeat, loss and reconnect timing (ms). Tick says what to send. Any packet from the other PC counts as alive;
// lost = 1.5 s plus the resend timeout without one. Fast: a PC has control, so a heartbeat every 100 ms (some Wi-Fi
// adapters doze between packets).
public class Conn {
  public const int Beat = 250, FastBeat = 100, LostAfter = 1500, MaxBackoff = 2000;
  public bool Up, Fast; public long LastRx; public int Slack; long nextHello, nextBeat; int backoff;
  public int Backoff { get { return backoff; } }
  public void Kick(long now) { backoff = 0; nextHello = now; }   // network change, wake-up, unlock: try now
  public bool Rx(long now) { LastRx = now; if (Up) return false; Up = true; backoff = 0; nextBeat = now; return true; }
  // 1 = send a hello, 2 = send a heartbeat, 4 = the link was just lost
  public int Tick(long now) {
    int r = 0;
    if (Up && now - LastRx > LostAfter + Slack) { Up = false; r |= 4; Kick(now); }
    if (Up) { if (now >= nextBeat) { nextBeat = now + (Fast ? FastBeat : Beat); r |= 2; } }
    else if (now >= nextHello) { r |= 1; backoff = backoff == 0 ? 100 : Math.Min(backoff * 2, MaxBackoff); nextHello = now + backoff; }
    return r;
  }
}

public class LossMeter {   // heartbeats that never arrived, per window of 40 (10 s)
  uint first; int got; bool any; public double Pct;
  public void Got(uint seq) {
    if (!any || (int)(seq - first) < 0) { first = seq; got = 0; any = true; }
    got++; int expected = (int)(seq - first) + 1;
    if (expected >= 40) { Pct = Math.Max(0, 100.0 * (expected - got) / expected); any = false; }
  }
}

// Round trip (ms): smoothed, its variation (shown as jitter) and the resend timeout SRTT + 4 * RTTVAR, 10..200 ms (RFC 6298)
public class RttEst {
  public double Srtt = -1, Var;
  public void Add(double r) {
    if (Srtt < 0) { Srtt = r; Var = r / 2; return; }
    Var = 0.75 * Var + 0.25 * Math.Abs(Srtt - r); Srtt = 0.875 * Srtt + 0.125 * r;
  }
  public int Rto { get { return Srtt < 0 ? 50 : (int)Math.Max(10, Math.Min(200, Srtt + 4 * Var)); } }
}

// Windows silently removes a low-level hook that is slow once. Raw Input still sees real input then, so: Raw Input reported
// some and the hook saw none of it within 200 ms = the hook is gone. Fed the counts of real (not injected) events; injects
// nothing, and with no input nothing happens. (Probes don't work: Windows drops zero-distance moves before the hooks.)
public class HookWatch {
  public const int Grace = 200;
  long raw, hook, hookAt, since = -1;
  public HookWatch(long rawCount, long hookCount, long now) { raw = rawCount; hook = hookCount; hookAt = now; }
  public bool Tick(long rawCount, long hookCount, long now) {   // true = reinstall the hook
    if (hookCount != hook) { hook = hookCount; raw = rawCount; hookAt = now; since = -1; return false; }
    if (rawCount != raw) { raw = rawCount; if (since < 0 && now - hookAt > Grace) since = now; }   // just after a hook call: the same event
    if (since < 0 || now - since < Grace) return false;
    since = -1; hookAt = now; return true;
  }
}

// The sender keeps its PC awake (ES_SYSTEM_REQUIRED) only while real input went to the other PC in the last 5 minutes;
// after that Windows' own sleep and screen-off timers apply. The receiver needs nothing: injected input resets its idle timer.
public static class Awake {
  public const int Ms = 300000;
  public static bool Want(bool active, long lastInput, long now) { return active && now - lastInput < Ms; }
}

public static class LinkProto {
  public const byte Version = 2;   // 2: DeskGlide 5.1 (mouse history, addresses in heartbeats)
  public static readonly byte[] Empty = new byte[0];
  public static byte[] Seal(byte[] key, byte kind, byte[] nonce, byte[] body, int len, byte ver) {
    var p = new byte[12]; p[0] = (byte)'D'; p[1] = (byte)'L'; p[2] = ver; p[3] = kind; Buffer.BlockCopy(nonce, 0, p, 4, 8);
    byte[] e = Dg.Encrypt(key, p, body, 0, len), o = new byte[12 + e.Length];
    p.CopyTo(o, 0); e.CopyTo(o, 12); return o;
  }
  // The body, or null if it isn't a DeskGlide Link packet under this key (the header, version included, is authenticated)
  public static byte[] Open(byte[] key, byte[] p, int n, out int ver, out int kind, out byte[] nonce) {
    ver = -1; kind = -1; nonce = null;
    if (key == null || p == null || n < 12 + Dg.CryptoOverhead || n > p.Length || p[0] != 'D' || p[1] != 'L') return null;
    ver = p[2]; kind = p[3]; nonce = new byte[8]; Buffer.BlockCopy(p, 4, nonce, 0, 8);
    var h = new byte[12]; Buffer.BlockCopy(p, 0, h, 0, 12);
    return Dg.Decrypt(key, h, p, 12, n - 12);
  }
  public static string VersionText(int theirs, string peer) {
    return theirs > Version ? "DeskGlide on " + peer + " is newer. Update DeskGlide on this PC to share the keyboard and mouse."
                            : "DeskGlide on " + peer + " is older. Update DeskGlide on " + peer + " to share the keyboard and mouse.";
  }
}

// The network adapter to reach the other PC through: one whose subnet holds it; a real one before a virtual one.
public static class Nic {
  public static bool Virtual(string desc) { return System.Text.RegularExpressions.Regex.IsMatch(desc ?? "", "Hyper-V|VirtualBox|VMware|vEthernet|WSL|Npcap|Loopback|Virtual|TAP-|Tailscale|ZeroTier|WireGuard", System.Text.RegularExpressions.RegexOptions.IgnoreCase); }
  static bool In(IPAddress a, IPAddress ip, IPAddress mask) {   // a is in ip's subnet
    byte[] p = a.GetAddressBytes(), b = ip.GetAddressBytes(), m = mask.GetAddressBytes(); bool same = p.Length == 4 && b.Length == 4 && m.Length == 4;
    for (int k = 0; same && k < 4; k++) same = (b[k] & m[k]) == (p[k] & m[k]);
    return same;
  }
  public static int Pick(IPAddress peer, int[] index, IPAddress[] ip, IPAddress[] mask, bool[] virt) {   // -1 = leave it to Windows' routing
    if (peer.GetAddressBytes().Length != 4 || IPAddress.IsLoopback(peer)) return -1;
    int best = -1; bool bestVirt = true;
    for (int i = 0; i < index.Length; i++) if (In(peer, ip[i], mask[i]) && (best < 0 || (bestVirt && !virt[i]))) { best = index[i]; bestVirt = virt[i]; }
    return best;
  }
  // A second path (Ethernet + Wi-Fi): another of the other PC's addresses, reached through a real adapter other than the first one's
  public static IPAddress Second(IPAddress[] theirs, IPAddress first, int firstIf, int[] index, IPAddress[] ip, IPAddress[] mask, bool[] virt, out int via) {
    via = -1;
    foreach (var a in theirs) {
      if (a.Equals(first) || IPAddress.IsLoopback(a)) continue;
      for (int i = 0; i < index.Length; i++) if (index[i] != firstIf && !virt[i] && In(a, ip[i], mask[i])) { via = index[i]; return a; }
    }
    return null;
  }
  // This PC's IPv4 adapters (index, address, mask, virtual?, wireless?)
  public static void List(out int[] index, out IPAddress[] ip, out IPAddress[] mask, out bool[] virt, out bool[] wifi) {
    var idx = new List<int>(); var ips = new List<IPAddress>(); var mk = new List<IPAddress>(); var vt = new List<bool>(); var wf = new List<bool>();
    foreach (var ni in NetworkInterface.GetAllNetworkInterfaces()) {
      if (ni.OperationalStatus != OperationalStatus.Up) continue;
      IPv4InterfaceProperties p4; try { p4 = ni.GetIPProperties().GetIPv4Properties(); } catch { continue; }
      if (p4 == null) continue;
      foreach (var u in ni.GetIPProperties().UnicastAddresses)
        if (u.Address.AddressFamily == AddressFamily.InterNetwork && u.IPv4Mask != null) {
          idx.Add(p4.Index); ips.Add(u.Address); mk.Add(u.IPv4Mask); vt.Add(Virtual(ni.Description + " " + ni.Name)); wf.Add(ni.NetworkInterfaceType == NetworkInterfaceType.Wireless80211);
        }
    }
    index = idx.ToArray(); ip = ips.ToArray(); mask = mk.ToArray(); virt = vt.ToArray(); wifi = wf.ToArray();
  }
  public static int ForPeer(IPAddress peer) { int[] i; IPAddress[] a, m; bool[] v, w; List(out i, out a, out m, out v, out w); return Pick(peer, i, a, m, v); }
}

// The engine: one per PC, on its own threads. DeskGlide.ps1 sets the fields below and reads Up/Active/Controlled.
public class Link {
  // ---- set by DeskGlide.ps1 (or the self-test) ----
  public volatile byte[] Key;                 // the pairing key
  public volatile IPAddress Peer;             // from discovery; then wherever the other PC's authenticated packets come from
  public volatile bool Sender;                // the keyboard and mouse are plugged into this PC
  public volatile char Dir = 'r';             // the side of this PC where the other PC is
  public volatile int Speed = 100, Dead = 8;  // pointer speed on the other PC (percent); corner dead zone (pixels)
  public volatile bool Game, LockSync;
  public volatile int PanicMods = 3, PanicVk = 0x13;   // RegisterHotKey style; Ctrl+Alt+Pause
  public string Name = "";
  public static volatile bool NoInject;       // -NoInject: no hooks, no Raw Input, no SendInput; what would be injected goes to Injected
  public volatile bool DualPath = true;       // send on a second adapter too when the other PC is reachable through two
  public volatile int DropPct, JitterMs;      // self-test: lose this share of sent packets; delay each by 0..JitterMs (in order)
  public volatile bool TestBlocked;           // self-test: "a game holds the pointer here"
  // DeskGlide's SYSTEM service (DeskGlideService.cs): input goes to its helper on the input desktop instead of SendInput here.
  // 1 key (vk, sc, flags), 2 mouse (x, y, data, flags; x and y in pixels when ABSOLUTE), 3 lock this PC
  public Action<int, int, int, int, int> Out;
  public Action Sas;                          // the service: Ctrl+Alt+End from the other PC presses Ctrl+Alt+Del here
  public int Refused;                         // hellos over the rate limit, dropped unchecked
  // ---- read by DeskGlide.ps1 ----
  public volatile bool Up, Active, Controlled, Uipi, Wireless;   // Active: this PC's keyboard and mouse drive the other PC; Controlled: the reverse
  public volatile string VersionMsg = "", InjectError = "";
  public double Loss;                         // percent
  public double Rtt { get { return est.Srtt; } }       // ms, smoothed; -1 = not measured yet
  public double Jitter { get { return est.Var; } }     // ms, the round trip's variation
  public int InjectFails, Stale, Jumps;       // Jumps: mouse positions lost that the history in the next packet couldn't fill
  public volatile int RawKb, RawMs, HookKb, HookMs;   // real (not injected) input seen by Raw Input and by the hooks
  public readonly ConcurrentQueue<string> Log = new ConcurrentQueue<string>(), Injected = new ConcurrentQueue<string>();
  public readonly ConcurrentQueue<long> Fed = new ConcurrentQueue<long>();
  public bool HasRemote { get { var r = remote; return r != null && r.Length > 0; } }
  public static long NowUs { get { return (long)(clock.Elapsed.TotalMilliseconds * 1000); } }
  public int Queued { get { return evq.Count; } }
  public IPAddress SecondPath { get { return Peer2; } }
  public string Pointer { get { return Geo.F(mx) + "," + Geo.F(my); } }   // self-test: where the sender has the pointer on the other PC

  const long OwnTag = 0x44474C4B;   // dwExtraInfo of DeskGlide's own input: "DGLK"
  const int Resume = 10000;         // a session dropped for less than this resumes as it was: same keys, same sequence numbers
  static readonly Stopwatch clock = Stopwatch.StartNew();
  static long Ms { get { return clock.ElapsedMilliseconds; } }
  static uint Us { get { return (uint)NowUs; } }
  readonly object gate = new object(), injGate = new object();
  struct Ev { public int Kind, A, B, C, D; }
  readonly ConcurrentQueue<Ev> evq = new ConcurrentQueue<Ev>();
  readonly AutoResetEvent wake = new AutoResetEvent(false);
  readonly ManualResetEvent winReady = new ManualResetEvent(false);
  readonly Random rnd = new Random();
  Socket sock; int peerPort; volatile bool running, kick, lockEvt, endPending, panic; Thread net, pump, msgs; Win win; IntPtr rawBuf;
  byte[] myNonce = Dg.Random(8), peerNonce, sessKey, helloKey, helloKeyFor; long lastHelloT; volatile string peerName = "the other PC";
  Conn conn = new Conn(); Reliable rel = new Reliable(); LossMeter loss = new LossMeter(); RttEst est = new RttEst();
  uint hbSeq, mSeq, rxMSeq, rxHb, peerT, peerTAt, flushedUs;
  volatile Mon[] local = new Mon[0], remote; bool fixedMons; long monsAt = -100000, uipiAt, deskAt, errAt = -100000, lockedAt = -100000;
  double mx, my, cx, cy; bool dirty, relMode, rawOn, timer1; Coalescer co = new Coalescer(); int sumX, sumY, mods, localDpi = 96;   // sender
  readonly bool[] phys = new bool[256]; volatile bool remoteGame; volatile int remoteX, remoteY;
  HookWatch hwKb, hwMs; long fwdAt, idleAt = -100000, hookNoteAt = -100000; int hookFixes;
  readonly int[] hx = new int[Hist], hy = new int[Hist]; int hn, mTail; byte[] lastM; long lastMAt;   // the sender's last positions
  const int Hist = 8;   // positions per mouse packet: the newest and the 7 before it (1 ms pacing: covers 7 lost in a row)
  readonly Held held = new Held(); int lastX = int.MinValue, lastY, rxSumX, rxSumY; bool rxRel, rxFresh; uint exec; IPAddress ifFor;   // receiver
  volatile IPAddress Peer2; Socket sock2; volatile IPAddress[] peerAddrs; IPAddress[] myAddrs = new IPAddress[0]; int firstIf = -1; long addrsAt = -100000;
  IntPtr qos; long lastDue, outageUntil; Thread delayer;
  const int MaxHellos = 20; long helloWin; int hellos;   // hellos checked per second (normally at most a few)
  class Delayed { public long Due; public byte[] P; public Socket S; public IPEndPoint To; }
  readonly ConcurrentQueue<Delayed> delayq = new ConcurrentQueue<Delayed>();

  // ---------- start / stop ----------
  public void Start(int port, int peerPort) {
    this.peerPort = peerPort; running = true;
    sock = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
    sock.ExclusiveAddressUse = true;   // no other program can bind this port on a more specific address and read the input
    sock.Bind(new IPEndPoint(IPAddress.Any, port));
    try { sock.IOControl(-1744830452, new byte[4], null); } catch {}   // SIO_UDP_CONNRESET off: ignore "port unreachable"
    sock.SendBufferSize = sock.ReceiveBufferSize = 1 << 20;   // a Wi-Fi stall doesn't overflow them
    try { var v = new QOS_VERSION { Major = 1 }; if (!QOSCreateHandle(ref v, out qos)) qos = IntPtr.Zero; } catch { qos = IntPtr.Zero; }
    NoTimerThrottling();
    msgs = Run(MsgLoop); winReady.WaitOne(3000);
    net = Run(NetLoop); pump = Run(PumpLoop);
    NetworkChange.NetworkAddressChanged += OnNetChange;
  }
  public void Stop() {   // gives control back and releases every key first
    NetworkChange.NetworkAddressChanged -= OnNetChange;
    running = false; wake.Set();
    if (pump != null) pump.Join(3000);
    try { sock.Close(); } catch {}
    try { if (sock2 != null) sock2.Close(); } catch {}
    if (net != null) net.Join(3000);
    if (msgs != null) msgs.Join(3000);
    if (qos != IntPtr.Zero) { QOSCloseHandle(qos); qos = IntPtr.Zero; }
  }
  public void Outage(int ms) { outageUntil = Ms + ms; }   // self-test: send nothing for this long
  public void Panic() { panic = true; wake.Set(); }   // the panic hotkey while this PC has control: release anything stuck
  public void FeedMouse(int dx, int dy, int buttons, int wheel) { Fed.Enqueue(NowUs); Enq(0, dx, dy, buttons, wheel); }   // self-test: Raw Input usButtonFlags / usButtonData
  public void FeedKey(int vk, int sc, int flags, int time) { Fed.Enqueue(NowUs); Enq(1, vk, sc, flags, time); }        // self-test: KBDLLHOOKSTRUCT fields
  public void SetLocal(Mon[] ms) { local = ms; fixedMons = true; }   // self-test: this PC's monitors
  public void SetCursor(int x, int y) { cx = x + 0.5; cy = y + 0.5; }   // self-test: this PC's pointer
  void Enq(int kind, int a, int b, int c, int d) { evq.Enqueue(new Ev { Kind = kind, A = a, B = b, C = c, D = d }); wake.Set(); }
  static Thread Run(ThreadStart f) { var t = new Thread(f); t.IsBackground = true; t.Start(); return t; }
  void Note(string s) { if (Log.Count < 500) Log.Enqueue(s); }
  void Would(string s) { if (Injected.Count < 100000) Injected.Enqueue(NowUs + "|" + s); }
  void OnNetChange(object s, EventArgs e) { kick = true; wake.Set(); }
  // PerMonitorV2 on this thread: monitor rects, the cursor and SendInput all in physical pixels (each Link thread calls it first)
  void Dpi() {
    bool ok; try { ok = SetThreadDpiAwarenessContext(new IntPtr(-4)) != IntPtr.Zero; } catch { ok = false; }
    if (!ok && !NoInject) Note("can't switch to per-monitor DPI: positions may be off on a scaled screen");
  }

  // ---------- the pump: input events, mouse coalescing, heartbeats, resends, reconnects ----------
  void PumpLoop() {
    Dpi(); DateTime wall = DateTime.UtcNow;
    while (running) {
      wake.WaitOne(dirty || rel.Pending > 0 || (lastM != null && mTail < 2) ? 1 : 20);
      try {
        if ((DateTime.UtcNow - wall).TotalSeconds > 3) Kick("this PC woke up");   // the loop runs every 20 ms, so a gap means sleep
        wall = DateTime.UtcNow;
        if (kick) { kick = false; ifFor = null; addrsAt = -100000; Kick("the network changed"); }
        if (endPending) { endPending = false; EndControl(peerName + " started a new session"); }
        if (panic) { panic = false; if (Active) Return(-1, true, "panic key"); else { if (Controlled) EndControl("panic key"); ReleaseLocal(); } }
        if (lockEvt) { lockEvt = false; if (Active) Return(-1, true, "this PC locked"); if (LockSync && Up && Ms - lockedAt > 3000) { Rel(new[] { (byte)'X' }); Note("this PC locked: locking " + peerName + " too"); } }
        Ev e; while (evq.TryDequeue(out e)) Process(e);
        if (dirty && Us - flushedUs >= 1000) Flush();   // at most one mouse packet per millisecond
        Periodic(Ms);
      } catch (Exception x) { Note("error: " + x.Message); }
    }
    try { if (Active) Return(-1, true, "DeskGlide stopped"); EndControl("DeskGlide stopped"); Exec(true); if (timer1) { timeEndPeriod(1); timer1 = false; } } catch {}
    if (win != null) PostMessage(win.Handle, 0x8003, IntPtr.Zero, IntPtr.Zero);
  }
  void Periodic(long now) {
    if (!fixedMons && now - monsAt >= (Controlled ? 250 : 2000)) { monsAt = now; local = ReadMons(); }   // fresh while injecting: a monitor coming back moves the desktop
    bool wantRaw = Sender && !NoInject;
    if (wantRaw != rawOn && win != null) { rawOn = wantRaw; PostMessage(win.Handle, 0x8002, (IntPtr)(wantRaw ? 1 : 0), IntPtr.Zero); }
    if (!Sender && Active) Return(-1, true, "this PC is no longer the keyboard PC");
    if (Controlled && !NoInject && Out == null && now - uipiAt >= 500) { uipiAt = now; Uipi = ElevatedFront(); }   // the service's helper runs as SYSTEM: no UIPI
    byte[] key = Key; IPAddress peer = Peer;
    if (key == null) return;
    // by content, not reference: PowerShell hands over a fresh copy of the same key on every poll
    if (!Same(key, helloKeyFor)) { lock (gate) { helloKey = Dg.SessionKey(key, "link hello", LinkProto.Empty); helloKeyFor = key; } NewSession("a new pairing"); }
    if (peer != null && !peer.Equals(ifFor)) { ifFor = peer; SetIf(peer); }
    if (now - addrsAt >= 5000) { addrsAt = now; Paths(); }
    int f; lock (gate) { conn.Slack = est.Rto; conn.Fast = Active || Controlled; f = conn.Tick(now); Up = conn.Up; }
    if ((f & 4) != 0) { Note("lost " + peerName + ": nothing for 1.5 s"); EndControl("connection lost"); }
    if (!Up && peerNonce != null && now - conn.LastRx > Resume) NewSession("no answer for 10 s");   // too long to resume: a fresh session
    if ((f & 1) != 0) SendHello();
    if ((f & 2) != 0) SendBeat();
    lock (gate) foreach (var it in rel.Due(now, est.Rto)) SendRel(it);
    if (lastM != null && mTail < 2 && now - lastMAt >= (mTail == 0 ? 10 : 40)) { mTail++; SendSession(lastM); }   // the mouse stopped: its last packet once or twice more
    if (Active) {
      bool wantRel = Game && remoteGame;
      if (wantRel != relMode) { Flush(); relMode = wantRel; co = new Coalescer(); hn = 0; if (!wantRel) { mx = remoteX + 0.5; my = remoteY + 0.5; } Note(wantRel ? "game mode: sending raw movement" : "game mode off"); }
      if (!NoInject && hwKb != null) {
        bool k = hwKb.Tick(RawKb, HookKb, now), m = hwMs.Tick(RawMs, HookMs, now);
        if (k || m) {
          Hooks(true); hookFixes++;
          if (now - hookNoteAt >= 60000) { hookNoteAt = now; Note("the input hook stopped answering; installed it again" + (hookFixes > 1 ? " (" + hookFixes + " times so far)" : "")); }
        }
      }
      if (!NoInject && now - deskAt >= 250) {   // Ctrl+Alt+Del, UAC or the lock screen here: the hooks miss key-ups, so release everything
        deskAt = now; IntPtr d = OpenInputDesktop(0, false, 1);
        if (d == IntPtr.Zero) Return(-1, true, "this PC switched to its secure desktop"); else CloseDesktop(d);
      }
    }
    Exec(false);
    bool fine = Active || Controlled;   // both sides: the sender's 1 ms pacing, the receiver's acks and resends
    if (fine != timer1) { if (fine) timeBeginPeriod(1); else timeEndPeriod(1); timer1 = fine; }   // 1 ms waits only while in use
  }
  // Windows 11 ignores timeBeginPeriod for processes with no visible window (DeskGlide lives in the tray),
  // so every 1 ms wait became a 15.6 ms tick (loopback p99 15 ms). Opt out of that throttling, and of EcoQoS.
  [StructLayout(LayoutKind.Sequential)] struct POWER_THROTTLING { public uint Version, ControlMask, StateMask; }
  [DllImport("kernel32.dll")] static extern bool SetProcessInformation(IntPtr process, int infoClass, ref POWER_THROTTLING info, int size);
  [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
  static void NoTimerThrottling() {
    try {   // ProcessPowerThrottling = 4; EXECUTION_SPEED 0x1 | IGNORE_TIMER_RESOLUTION 0x4 controlled, state 0 = never throttle
      var s = new POWER_THROTTLING { Version = 1, ControlMask = 0x1 | 0x4, StateMask = 0 };
      SetProcessInformation(GetCurrentProcess(), 4, ref s, Marshal.SizeOf(typeof(POWER_THROTTLING)));
    } catch {}   // older Windows: nothing to opt out of
  }
  void Kick(string why) { bool down; lock (gate) { conn.Kick(Ms); down = !conn.Up; } if (down && Key != null) Note("reconnecting: " + why); }
  void NewSession(string why) {   // a fresh nonce makes both PCs start a new session: no stale keys survive
    bool was = Up; EndControl("connection lost: " + why);
    lock (gate) { myNonce = Dg.Random(8); peerNonce = null; sessKey = null; rel = new Reliable(); conn = new Conn(); conn.Kick(Ms); Up = false; rxMSeq = 0; rxHb = 0; est = new RttEst(); loss = new LossMeter(); }
    if (was) Note("lost " + peerName + ": " + why);
  }
  void EndControl(string why) {   // leave or loss: control comes back here, everything held is released on this side
    if (Active) Return(-1, true, why);   // the 'L' waits in the stream if the link is down: a resumed session ends control there too
    if (Controlled) { ReleaseAll(); Controlled = false; Note(peerName + " no longer controls this PC (" + why + ")"); }
  }
  // The sender stays awake while input goes to the other PC (Awake). GetLastInputInfo and the low-level hooks: not measured
  // here (that needs a swallowing hook on a live desktop); Synergy-style servers are known to fall asleep while their input is
  // swallowed, so the sender holds ES_SYSTEM_REQUIRED itself either way. The receiver holds nothing: its injected input resets
  // its idle timer, so its sleep and screen-off timers follow the use.
  void Exec(bool off) {
    uint want = !off && Awake.Want(Active, fwdAt, Ms) ? 1u : 0u;
    if (NoInject) return;
    if (want != 0 && fwdAt - idleAt >= 10000) { idleAt = fwdAt; SetThreadExecutionState(1); }   // and Windows' sleep timer counts from the last forwarded input
    if (want == exec) return; exec = want;
    SetThreadExecutionState(0x80000000u | want);   // ES_CONTINUOUS (| ES_SYSTEM_REQUIRED)
  }

  // ---------- sender: input events ----------
  static readonly int[] RawDown = { 1, 4, 0x10, 0x40, 0x100 }, RawUp = { 2, 8, 0x20, 0x80, 0x200 }, BtnVk = { 1, 2, 4, 5, 6 };   // L R M X1 X2
  void Process(Ev e) {
    if (e.Kind == 1) { if (Active) KeyOut(e.A, e.B, e.C); return; }
    int dx = e.A, dy = e.B, bf = e.C;
    for (int b = 0; b < 5; b++) { if ((bf & RawDown[b]) != 0) phys[BtnVk[b]] = true; if ((bf & RawUp[b]) != 0) phys[BtnVk[b]] = false; }
    if (!Active) {
      if (NoInject) Geo.Move(local, ref cx, ref cy, dx, dy, '\0', 0);   // the self-test's pointer
      if ((dx != 0 || dy != 0) && Sender && Up && HasRemote && !Blocked()) {
        int x, y; Cursor(out x, out y); double f = Geo.Leave(local, x, y, dx, dy, Dir, Dead);
        if (f >= 0) Enter(f, x, y);
      }
      return;
    }
    fwdAt = Ms;
    if (dx != 0 || dy != 0) {
      double s = Geo.Scale(Speed, localDpi, Geo.DpiAt(remote, mx, my));
      if (relMode) co.Add(dx * s, dy * s);
      else { double f = Geo.Move(remote, ref mx, ref my, dx * s, dy * s, Geo.Opp(Dir), Dead); if (f >= 0) { dirty = true; Flush(); Return(f, true, "the pointer crossed the edge back"); return; } }
      dirty = true;
    }
    for (int b = 0; b < 5; b++) {
      if ((bf & (RawDown[b] | RawUp[b])) == 0) continue;
      Flush();   // the pointer gets there before the click
      var d = new byte[12]; d[0] = (byte)'B'; d[1] = (byte)b; d[2] = (byte)((bf & RawDown[b]) != 0 ? 1 : 0); d[3] = (byte)(relMode ? 1 : 0);
      Put(d, 4, (uint)Geo.F(mx)); Put(d, 8, (uint)Geo.F(my)); Rel(d);
    }
    if ((bf & 0x400) != 0) Wheel(false, e.D);   // raw deltas, small ones too (precision touchpads, free-spinning wheels)
    if ((bf & 0x800) != 0) Wheel(true, e.D);
  }
  void Wheel(bool h, int delta) { var d = new byte[4]; d[0] = (byte)'W'; d[1] = (byte)(h ? 1 : 0); BitConverter.GetBytes((short)delta).CopyTo(d, 2); Rel(d); }
  void KeyOut(int vk, int sc, int fl) {
    if (KeyMap.FakeCtrl(vk, sc)) return;
    bool up = (fl & 0x80) != 0; int before = mods; fwdAt = Ms;
    mods = KeyMap.Apply(mods, vk, up); phys[vk & 0xFF] = !up;
    if (!up && PanicMods != 0 && (vk == PanicVk || (PanicVk == 0x13 && vk == 3)) && (KeyMap.HotMods(before) & PanicMods) == PanicMods) {   // Ctrl+Pause arrives as Break
      Return(-1, true, "panic key"); return;
    }
    Rel(new[] { (byte)'K', (byte)sc, (byte)((up ? 1 : 0) | ((fl & 1) != 0 ? 2 : 0)), (byte)vk, (byte)before });
  }
  void Enter(double f, int x, int y) {
    int ex, ey; Geo.Entry(remote, Geo.Opp(Dir), f, out ex, out ey);
    mx = ex + 0.5; my = ey + 0.5; localDpi = Geo.DpiAt(local, x, y); relMode = Game && remoteGame; co = new Coalescer(); dirty = false; hn = 0;
    mods = 0; for (int b = 0; b < 8; b++) { int vk = KeyMap.Vk[b]; phys[vk] = Down(vk); if (phys[vk]) mods |= 1 << b; }   // held while crossing: the first key carries them
    long now = Ms; Active = true; fwdAt = now; hwKb = new HookWatch(RawKb, HookKb, now); hwMs = new HookWatch(RawMs, HookMs, now); Hooks(true);
    var d = new byte[9]; d[0] = (byte)'E'; Put(d, 1, (uint)ex); Put(d, 5, (uint)ey); Rel(d);
    Note("keyboard and mouse -> " + peerName);
  }
  void Return(double f, bool tell, string why) {   // f >= 0: the pointer came back across the edge there
    if (!Active) return;
    Active = false; dirty = false; Hooks(false);
    if (tell) Rel(new[] { (byte)'L' });
    if (f >= 0) { int x, y; Geo.Entry(local, Dir, f, out x, out y); if (NoInject) SetCursor(x, y); else SetCursorPos(x, y); }
    ReleaseLocal();
    Note("keyboard and mouse back on this PC (" + why + ")");
  }
  void ReleaseLocal() {   // keys and buttons Windows here still thinks are down, though they were let go while the other PC had them
    if (NoInject) return;
    for (int b = 0; b < 8; b++) { int vk = KeyMap.Vk[b]; if (!phys[vk] && Down(vk)) SendKey(KeyMap.Sc[b], KeyMap.Ext[b], 0, true); }
    for (int b = 0; b < 5; b++) if (!phys[BtnVk[b]] && Down(BtnVk[b])) SendMouse(0, 0, b == 3 ? 1u : b == 4 ? 2u : 0u, BtnUp[b]);
  }
  bool Down(int vk) { return NoInject ? phys[vk] : (GetAsyncKeyState(vk) & 0x8000) != 0; }
  void Flush() {
    if (!dirty || !Active) { dirty = false; return; }
    dirty = false; flushedUs = Us;
    int px, py;
    if (relMode) { int dx, dy; if (!co.Take(out dx, out dy)) return; sumX += dx; sumY += dy; px = sumX; py = sumY; }   // running sums: one is enough
    else { px = Geo.F(mx); py = Geo.F(my); }
    Array.Copy(hx, 0, hx, 1, Hist - 1); Array.Copy(hy, 0, hy, 1, Hist - 1); hx[0] = px; hy[0] = py; hn = relMode ? 1 : Math.Min(Hist, hn + 1);
    var d = new byte[11 + 8 * hn]; d[0] = (byte)'M'; d[9] = (byte)(relMode ? 1 : 0); d[10] = (byte)hn;
    for (int i = 0; i < hn; i++) { Put(d, 11 + 8 * i, (uint)hx[i]); Put(d, 15 + 8 * i, (uint)hy[i]); }
    Put(d, 5, ++mSeq); SendSession(d); lastM = d; lastMAt = Ms; mTail = 0;
  }
  void Cursor(out int x, out int y) {
    if (NoInject || Out != null) { x = Sender ? Geo.F(cx) : lastX; y = Sender ? Geo.F(cy) : lastY; return; }   // the service sits in session 0: its last injected position
    PT p; GetCursorPos(out p); x = p.x; y = p.y;
  }
  bool Blocked() {   // a game holds the pointer here: ClipCursor, or a full-screen Direct3D app
    if (NoInject || Out != null) return TestBlocked;   // ponytail: the service can't see the user's games; game mode needs the user-mode receiver
    Mon[] ms = local; if (ms.Length == 0) return false;
    int vx, vy, vw, vh; Geo.Bounds(ms, out vx, out vy, out vw, out vh); RC c;
    if (GetClipCursor(out c) && (c.l > vx || c.t > vy || c.r < vx + vw || c.b < vy + vh)) return true;
    int q; return SHQueryUserNotificationState(out q) == 0 && q == 3;   // QUNS_RUNNING_D3D_FULL_SCREEN
  }

  // ---------- sending ----------
  void Rel(byte[] d) { lock (gate) { if (sessKey == null) return; SendRel(rel.Add(d, Ms)); } }   // also while down: a resumed session gets it
  void SendRel(Reliable.Item it) { var b = new byte[9 + it.Data.Length]; b[0] = (byte)'R'; Put(b, 5, it.Seq); it.Data.CopyTo(b, 9); SendSession(b); }
  void SendSession(byte[] b) {   // fills in the ack
    byte[] k, me; lock (gate) { k = sessKey; me = myNonce; Put(b, 1, rel.Ack); }
    if (k != null) Send(LinkProto.Seal(k, 1, me, b, b.Length, LinkProto.Version));
  }
  void SendHello() {
    byte[] hk, me, known; lock (gate) { hk = helloKey; me = myNonce; known = peerNonce; }
    if (hk == null) return;
    byte[] nm = Encoding.UTF8.GetBytes(Name ?? ""), b = new byte[16 + Math.Min(nm.Length, 64)];
    if (known != null) known.CopyTo(b, 0);
    BitConverter.GetBytes(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()).CopyTo(b, 8);
    Buffer.BlockCopy(nm, 0, b, 16, b.Length - 16);
    Send(LinkProto.Seal(hk, 0, me, b, b.Length, LinkProto.Version));
  }
  void SendBeat() {
    Mon[] ms = local; IPAddress[] me = myAddrs; int n = Math.Min(ms.Length, 16), k = Math.Min(me.Length, 8), o2 = 31 + 18 * n; var b = new byte[o2 + 1 + 4 * k];
    b[0] = (byte)'H'; Put(b, 5, ++hbSeq); uint now = Us | 1, pt = peerT; Put(b, 9, now); Put(b, 13, pt); Put(b, 17, pt == 0 ? 0 : now - peerTAt);
    b[21] = (byte)(Blocked() ? 1 : 0);
    int x, y; Cursor(out x, out y); Put(b, 22, (uint)x); Put(b, 26, (uint)y); b[30] = (byte)n;
    for (int i = 0; i < n; i++) { int o = 31 + 18 * i; Put(b, o, (uint)ms[i].L); Put(b, o + 4, (uint)ms[i].T); Put(b, o + 8, (uint)ms[i].R); Put(b, o + 12, (uint)ms[i].B); BitConverter.GetBytes((ushort)ms[i].Dpi).CopyTo(b, o + 16); }
    b[o2] = (byte)k; for (int i = 0; i < k; i++) me[i].GetAddressBytes().CopyTo(b, o2 + 1 + 4 * i);   // this PC's addresses, for a second path
    SendSession(b);
  }
  void Send(byte[] p) {
    IPAddress a = Peer, a2 = Peer2; Socket s2 = sock2; if (a == null) return;
    if (Ms < outageUntil) return;
    if (DropPct > 0) lock (rnd) if (rnd.Next(100) < DropPct) return;
    if (JitterMs > 0) { Delay(p, sock, a); if (a2 != null && s2 != null) Delay(p, s2, a2); return; }
    SendOn(sock, p, a);
    if (a2 != null && s2 != null) SendOn(s2, p, a2);   // the second path: the other PC drops what it already has, by sequence
  }
  void SendOn(Socket s, byte[] p, IPAddress a) {
    try { s.SendTo(p, new IPEndPoint(a, peerPort)); } catch (Exception e) { if (running && Ms - errAt > 5000) { errAt = Ms; Note("can't send: " + e.Message); } }
  }
  void Delay(byte[] p, Socket s, IPAddress a) {   // self-test: a jittery network that keeps the order, like one Wi-Fi link
    lock (delayq) {
      lock (rnd) lastDue = Math.Max(lastDue, Ms + rnd.Next(JitterMs + 1));
      delayq.Enqueue(new Delayed { Due = lastDue, P = p, S = s, To = new IPEndPoint(a, peerPort) });
      if (delayer == null) delayer = Run(() => {
        while (running) { Delayed d; if (delayq.TryPeek(out d) && d.Due <= Ms && delayq.TryDequeue(out d)) SendOn(d.S, d.P, d.To.Address); else Thread.Sleep(1); }
      });
    }
  }
  void SetIf(IPAddress peer) {   // IP_UNICAST_IF: leave through the adapter whose subnet holds the other PC (not a VPN or Hyper-V one)
    int i = -1; try { i = Nic.ForPeer(peer); } catch {}
    try { sock.SetSocketOption(SocketOptionLevel.IP, (SocketOptionName)31, IPAddress.HostToNetworkOrder(Math.Max(i, 0))); } catch {}
    firstIf = i; Qos(sock, peer);
    if (i >= 0) Note("reaching " + peer + " through network adapter " + i);
  }
  void Qos(Socket s, IPAddress a) {   // qWAVE, no admin: the input stream goes out as control traffic (high priority on Wi-Fi too); failure is fine
    if (qos == IntPtr.Zero || IPAddress.IsLoopback(a)) return;
    var sa = new byte[16]; sa[0] = 2; sa[2] = (byte)(peerPort >> 8); sa[3] = (byte)peerPort; a.GetAddressBytes().CopyTo(sa, 4);   // sockaddr_in
    uint id = 0; try { QOSAddSocketToFlow(qos, s.Handle, sa, 5, 2, ref id); } catch {}   // QOSTrafficTypeControl, QOS_NON_ADAPTIVE_FLOW
  }
  void Paths() {   // every 5 s: this PC's addresses (sent in heartbeats), Wi-Fi or not, and a second path to the other PC
    int[] idx; IPAddress[] ip, mask; bool[] virt, wifi;
    try { Nic.List(out idx, out ip, out mask, out virt, out wifi); } catch { return; }
    var me = new List<IPAddress>(); for (int i = 0; i < ip.Length; i++) if (!virt[i] && !IPAddress.IsLoopback(ip[i])) me.Add(ip[i]);
    myAddrs = me.ToArray();
    bool w = false; for (int i = 0; i < idx.Length; i++) if (idx[i] == firstIf && wifi[i]) w = true;
    Wireless = w;
    IPAddress[] theirs = peerAddrs; int via = -1;
    IPAddress second = DualPath && theirs != null && firstIf >= 0 ? Nic.Second(theirs, Peer, firstIf, idx, ip, mask, virt, out via) : null;
    if (second == null) { if (Peer2 != null) { Peer2 = null; Note("second path to " + peerName + " gone"); } return; }
    if (second.Equals(Peer2)) return;
    try {
      if (sock2 == null) { sock2 = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp); sock2.Bind(new IPEndPoint(IPAddress.Any, 0)); sock2.SendBufferSize = 1 << 20; }
      sock2.SetSocketOption(SocketOptionLevel.IP, (SocketOptionName)31, IPAddress.HostToNetworkOrder(via));
      Qos(sock2, second); Peer2 = second; Note("second path to " + peerName + ": " + second + " through network adapter " + via);
    } catch (Exception e) { Note("no second path: " + e.Message); }
  }
  static void Put(byte[] b, int o, uint v) { b[o] = (byte)v; b[o + 1] = (byte)(v >> 8); b[o + 2] = (byte)(v >> 16); b[o + 3] = (byte)(v >> 24); }
  static uint U(byte[] b, int o) { return BitConverter.ToUInt32(b, o); }
  static int I(byte[] b, int o) { return BitConverter.ToInt32(b, o); }
  static bool Same(byte[] a, byte[] b) { if (a == null || b == null || a.Length != b.Length) return false; for (int i = 0; i < a.Length; i++) if (a[i] != b[i]) return false; return true; }
  static byte[] Order(byte[] a, byte[] b) { for (int i = 0; i < 8; i++) if (a[i] != b[i]) return a[i] < b[i] ? Files.Cat(a, b) : Files.Cat(b, a); return Files.Cat(a, b); }

  // ---------- receiving ----------
  void NetLoop() {
    Dpi(); var buf = new byte[2048]; EndPoint from = new IPEndPoint(IPAddress.Any, 0);
    while (running) {
      try {
        if (!sock.Poll(100000, SelectMode.SelectRead)) continue;
        int n = sock.ReceiveFrom(buf, ref from);
        OnPacket(buf, n, ((IPEndPoint)from).Address);
      } catch (ObjectDisposedException) { return; }
      catch (Exception x) { if (running) { Note("network: " + x.Message); Thread.Sleep(200); } }
    }
  }
  void OnPacket(byte[] p, int n, IPAddress src) {
    byte[] hk = helloKey; int ver, kind; byte[] nonce;
    if (hk == null || n < 12 || p[0] != 'D' || p[1] != 'L') return;
    if (p[3] == 0) {
      long now = Ms; if (now - helloWin >= 1000) { helloWin = now; hellos = 0; }
      if (++hellos > MaxHellos) { Refused++; return; }   // connection attempts: a flood is dropped before any crypto
      byte[] h = LinkProto.Open(hk, p, n, out ver, out kind, out nonce);
      if (h == null || h.Length < 16) return;   // not paired with this PC
      if (ver != LinkProto.Version) { VersionMsg = LinkProto.VersionText(ver, Encoding.UTF8.GetString(h, 16, h.Length - 16)); return; }
      Hello(h, nonce, src); return;
    }
    byte[] sk = sessKey, pn = peerNonce; if (sk == null || pn == null) return;
    for (int i = 0; i < 8; i++) if (p[4 + i] != pn[i]) return;   // not this session's nonce: dropped before any crypto
    byte[] b = LinkProto.Open(sk, p, n, out ver, out kind, out nonce);
    if (b == null || ver != LinkProto.Version || kind != 1 || !Same(nonce, pn)) return;
    if (!src.Equals(Peer) && !src.Equals(Peer2)) { Note(peerName + " is now at " + src); Peer = src; }
    Session(b);
  }
  void Hello(byte[] h, byte[] nonce, IPAddress src) {
    var known = new byte[8]; Buffer.BlockCopy(h, 0, known, 0, 8);
    long t = BitConverter.ToInt64(h, 8); string name = Encoding.UTF8.GetString(h, 16, h.Length - 16);
    bool reply, came = false;
    lock (gate) {
      if (!Same(nonce, peerNonce)) {   // the other PC (re)started its session
        if (conn.Up && t <= lastHelloT) return;   // an old hello played back
        if (conn.Up || Active || Controlled) { endPending = true; wake.Set(); }
        peerNonce = nonce; lastHelloT = t; sessKey = Dg.SessionKey(Key, "link", Order(myNonce, nonce)); rel = new Reliable(); rxMSeq = 0; rxHb = 0;
        conn = new Conn(); conn.LastRx = Ms; Up = false; est = new RttEst(); loss = new LossMeter();
      }
      if (name != "") peerName = name;
      VersionMsg = "";
      reply = !Same(known, myNonce);
      if (!reply) { came = conn.Rx(Ms); Up = true; }   // it knows this PC: the session is up
    }
    if (!src.Equals(Peer) && !src.Equals(Peer2)) Peer = src;
    if (reply) SendHello();
    if (came) { Note("connected to " + peerName); wake.Set(); }
  }
  void Session(byte[] b) {
    if (b.Length < 5) return;
    bool came; lock (gate) { came = conn.Rx(Ms); Up = true; rel.Acked(U(b, 1)); }
    if (came) { Note("connected to " + peerName); wake.Set(); }
    switch ((char)b[0]) {
      case 'H': Beat(b); break;
      case 'M': if (b.Length >= 19 && b[10] >= 1 && b[10] <= Hist && b.Length >= 11 + 8 * b[10]) Mouse(U(b, 5), b[9], b); break;
      case 'R':
        if (b.Length < 10) break;
        var d = new byte[b.Length - 9]; Buffer.BlockCopy(b, 9, d, 0, d.Length);
        List<byte[]> got; lock (gate) got = rel.Got(U(b, 5), d);
        foreach (var g in got) Deliver(g);
        SendSession(new[] { (byte)'A', (byte)0, (byte)0, (byte)0, (byte)0 });
        break;
    }
  }
  void Beat(byte[] b) {
    if (b.Length < 31) return;
    uint seq = U(b, 5); if (rxHb != 0 && (int)(seq - rxHb) <= 0) return;   // a copy from the second path, or late
    rxHb = seq; loss.Got(seq); Loss = loss.Pct;
    uint now = Us, t = U(b, 9), echo = U(b, 13), hold = U(b, 17);
    if (echo != 0) { double r = (uint)(now - echo - hold) / 1000.0; if (r < 5000) lock (gate) est.Add(r); }
    peerT = t; peerTAt = now;
    remoteGame = (b[21] & 1) != 0; remoteX = I(b, 22); remoteY = I(b, 26);
    int n = b[30], o2 = 31 + 18 * n; if (n < 1 || n > 16 || b.Length < o2) return;
    var ms = new Mon[n];
    for (int i = 0; i < n; i++) { int o = 31 + 18 * i; ms[i] = new Mon(I(b, o), I(b, o + 4), I(b, o + 8), I(b, o + 12), BitConverter.ToUInt16(b, o + 16)); if (ms[i].R <= ms[i].L || ms[i].B <= ms[i].T) return; }
    remote = ms;
    if (b.Length > o2 && b.Length >= o2 + 1 + 4 * b[o2]) {   // its addresses
      var a = new IPAddress[b[o2]]; for (int i = 0; i < a.Length; i++) { var q = new byte[4]; Buffer.BlockCopy(b, o2 + 1 + 4 * i, q, 0, 4); a[i] = new IPAddress(q); }
      peerAddrs = a;
    }
  }
  // The newest position wins by sequence; up to seven lost packets are filled in from the history the next one carries
  void Mouse(uint seq, int mode, byte[] p) {
    if (!Controlled) return;
    if (rxMSeq != 0 && (int)(seq - rxMSeq) <= 0) { Stale++; return; }   // older than what is already here, or a copy
    int n = p[10], gap = rxMSeq == 0 || rxFresh ? 0 : (int)(seq - rxMSeq) - 1;
    rxMSeq = seq; rxFresh = false;
    int a = I(p, 11), b = I(p, 15);
    if (mode == 0) {
      rxRel = false; if (gap > n - 1) Jumps++;
      for (int i = Math.Min(gap, n - 1); i >= 1; i--) InjMove(I(p, 11 + 8 * i), I(p, 15 + 8 * i));
      InjMove(a, b); return;
    }
    if (!rxRel) { rxRel = true; rxSumX = a; rxSumY = b; return; }   // running sums: a lost packet's movement still arrives
    int dx = a - rxSumX, dy = b - rxSumY; rxSumX = a; rxSumY = b;
    if (dx != 0 || dy != 0) InjRel(dx, dy);
  }
  void Deliver(byte[] d) {
    switch ((char)d[0]) {
      case 'E': if (d.Length < 9) return; Controlled = true; rxRel = false; rxFresh = true; lastX = int.MinValue; InjMove(I(d, 1), I(d, 5)); Note(peerName + " controls this PC"); break;
      case 'L': if (Controlled) { ReleaseAll(); Controlled = false; Note(peerName + " no longer controls this PC"); } break;
      case 'K': if (Controlled && d.Length >= 5) KeyIn(d[1], d[2], d[3], d[4]); break;
      case 'B': if (Controlled && d.Length >= 12) { if (d[3] == 0) InjMove(I(d, 4), I(d, 8)); InjButton(d[1], d[2] != 0, d[3] == 0); } break;
      case 'W': if (Controlled && d.Length >= 4) InjWheel(d[1] != 0, BitConverter.ToInt16(d, 2)); break;
      case 'X': if (LockSync) { lockedAt = Ms; Note("locked together with " + peerName); if (NoInject) Would("lock"); else if (Out != null) Out(3, 0, 0, 0, 0); else LockWorkStation(); } break;
    }
  }

  // ---------- receiver: injection (never fatal: a refusal is counted and shown) ----------
  void KeyIn(int sc, int fl, int vk, int want) {
    // Ctrl+Alt+Del always stays on the PC it's pressed on, so Ctrl+Alt+End (as in Remote Desktop) means it here; only the service can press it
    if (Sas != null && sc == 0x4F && (fl & 2) != 0 && (want & 0x0C) != 0 && (want & 0x30) != 0) { if ((fl & 1) == 0) Sas(); return; }
    lock (injGate) {
      foreach (int c in KeyMap.Reconcile(want, HaveMods())) { int b = c & 0xFF; SendKey(KeyMap.Sc[b], KeyMap.Ext[b], KeyMap.Vk[b], (c & 0x100) == 0); }
      SendKey(sc, (fl & 2) != 0, vk, (fl & 1) != 0);
    }
  }
  int HaveMods() {
    if (NoInject || Out != null) return held.Mods();   // ponytail: the service knows only what it injected, not keys held on this PC's own keyboard
    int m = 0; for (int b = 0; b < 8; b++) if ((GetAsyncKeyState(KeyMap.Vk[b]) & 0x8000) != 0) m |= 1 << b; return m;
  }
  void SendKey(int sc, bool ext, int vk, bool up) {
    bool byVk = sc == 0 || vk == 0x13 || vk == 3;   // ponytail: Pause/Break has no usable scan code; those go by virtual key
    if (!Active) held.Key(byVk ? 0x10000 | vk : sc | (ext ? 0x100 : 0), up);   // the sender's own releases aren't the receiver's
    if (NoInject) { Would("key " + (byVk ? "vk" + vk.ToString("X2") : sc.ToString("X2")) + (ext ? " ext" : "") + (up ? " up" : " down")); return; }
    int kf = (byVk ? 0 : 8) | (ext ? 1 : 0) | (up ? 2 : 0);   // KEYEVENTF_SCANCODE, EXTENDEDKEY, KEYUP
    if (Out != null) { Out(1, byVk ? vk : 0, byVk ? 0 : sc, kf, 0); return; }
    var i = new INPUT { type = 1 }; i.u.k.vk = (ushort)(byVk ? vk : 0); i.u.k.sc = (ushort)(byVk ? 0 : sc);
    i.u.k.flags = (uint)kf; i.u.k.extra = (IntPtr)OwnTag;
    Inject(i);
  }
  void InjMove(int x, int y) {
    Geo.Clamp(local, ref x, ref y);   // onto a real monitor: every edge row (the taskbar) is reachable, nothing lands between screens
    if (x == lastX && y == lastY) return;
    lastX = x; lastY = y;
    if (NoInject) { Would("move " + x + "," + y); return; }
    MouseAt(x, y, 0, 1);   // MOVE
  }
  // ABSOLUTE | VIRTUALDESK: no pointer acceleration. The service's helper normalizes on its own desktop; the service can't.
  void MouseAt(int x, int y, uint data, uint flags) {
    if (Out != null) Out(2, x, y, (int)data, (int)(flags | 0x8000 | 0x4000)); else SendMouse(NormX(x), NormY(y), data, flags | 0x8000 | 0x4000);
  }
  // Over the virtual desktop exactly as Windows normalizes it: read now, on this PerMonitorV2 thread (physical pixels)
  static int NormX(int x) { return Geo.Norm(x, GetSystemMetrics(76), GetSystemMetrics(78)); }   // SM_XVIRTUALSCREEN, SM_CXVIRTUALSCREEN
  static int NormY(int y) { return Geo.Norm(y, GetSystemMetrics(77), GetSystemMetrics(79)); }
  void InjRel(int dx, int dy) { if (NoInject) Would("rel " + dx + "," + dy); else SendMouse(dx, dy, 0, 1); }
  static readonly uint[] BtnDown = { 2, 8, 0x20, 0x80, 0x80 }, BtnUp = { 4, 0x10, 0x40, 0x100, 0x100 };
  void InjButton(int b, bool down, bool here) {   // here: at the pointer's last position, in the same input (the click lands where it is drawn)
    if (b > 4) return;
    lock (injGate) {
      held.Button(b, down);
      if (NoInject) { Would("button " + b + (down ? " down" : " up")); return; }
      uint data = b == 3 ? 1u : b == 4 ? 2u : 0u, fl = down ? BtnDown[b] : BtnUp[b];   // X buttons: XBUTTON1 / XBUTTON2
      if (here && lastX != int.MinValue) MouseAt(lastX, lastY, data, fl | 1); else SendMouse(0, 0, data, fl);
    }
  }
  void InjWheel(bool h, int delta) { if (NoInject) Would((h ? "hwheel " : "wheel ") + delta); else SendMouse(0, 0, (uint)delta, h ? 0x1000u : 0x800u); }
  void ReleaseAll() {
    lock (injGate) {
      foreach (int k in held.TakeKeys()) { if ((k & 0x10000) != 0) SendKey(0, false, k & 0xFF, true); else SendKey(k & 0xFF, (k & 0x100) != 0, 0, true); }
      foreach (int b in held.TakeButtons()) InjButton(b, false, false);
    }
  }
  void SendMouse(int dx, int dy, uint data, uint flags) {
    if (Out != null) { Out(2, dx, dy, (int)data, (int)flags); return; }
    var i = new INPUT { type = 0 }; i.u.m.dx = dx; i.u.m.dy = dy; i.u.m.data = data; i.u.m.flags = flags; i.u.m.extra = (IntPtr)OwnTag; Inject(i);
  }
  void Inject(INPUT i) {
    if (SendInput(1, new[] { i }, Marshal.SizeOf(typeof(INPUT))) == 1) { if (InjectError != "" && Ms - errAt > 5000) InjectError = ""; return; }
    int e = Marshal.GetLastWin32Error(); InjectFails++;
    InjectError = e == 5 ? "Windows refused input from " + peerName + ": the lock screen or an admin prompt is in front on this PC."
                         : "Windows refused input from " + peerName + " (error " + e + ").";
    if (Ms - errAt > 5000) { errAt = Ms; Note(InjectError); }
  }
  static bool ElevatedFront() {   // UIPI: Windows silently drops input to an admin window, so look for one in front
    uint pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid); if (pid == 0) return false;
    IntPtr p = OpenProcess(0x1000, false, pid); if (p == IntPtr.Zero) return false;   // PROCESS_QUERY_LIMITED_INFORMATION
    try {
      IntPtr t; if (!OpenProcessToken(p, 8, out t)) return true;   // TOKEN_QUERY refused: it runs above this PC's user
      try { int elev, n; return GetTokenInformation(t, 20, out elev, 4, out n) && elev != 0; } finally { CloseHandle(t); }   // TokenElevation
    } finally { CloseHandle(p); }
  }

  // ---------- the message thread: Raw Input, the hooks, lock and session notifications ----------
  class Win : System.Windows.Forms.NativeWindow {
    public Link L;
    protected override void WndProc(ref System.Windows.Forms.Message m) { try { L.OnMsg(m.Msg, m.WParam, m.LParam); } catch {} base.WndProc(ref m); }
  }
  void MsgLoop() {
    Dpi();
    try {
      var cp = new System.Windows.Forms.CreateParams(); cp.Parent = new IntPtr(-3);   // HWND_MESSAGE
      win = new Win { L = this }; win.CreateHandle(cp); rawBuf = Marshal.AllocHGlobal(256);
      WTSRegisterSessionNotification(win.Handle, 0);
    } catch (Exception e) { Note("no message window: " + e.Message); win = null; }
    winReady.Set();
    if (win == null) return;
    System.Windows.Forms.Application.Run();
    SetHooks(false); if (rawOn) SetRaw(false); WTSUnRegisterSessionNotification(win.Handle); win.DestroyHandle(); Marshal.FreeHGlobal(rawBuf);
  }
  void OnMsg(int msg, IntPtr w, IntPtr l) {
    if (msg == 0xFF) {   // WM_INPUT
      uint size = 256; int dx, dy, bf, bd;
      if (GetRawInputData(l, 0x10000003, rawBuf, ref size, (uint)HdrSize) == uint.MaxValue) return;
      if (ParseRaw(rawBuf, out dx, out dy, out bf, out bd)) { if ((dx | dy | bf) != 0) RawMs++; Enq(0, dx, dy, bf, bd); }
      else if (Marshal.ReadInt32(rawBuf, 0) == 1 && Marshal.ReadIntPtr(rawBuf, 8) != IntPtr.Zero) RawKb++;   // a real keyboard (only counted: keys come from the hook)
    }
    else if (msg == 0x2B1) { if (w.ToInt32() == 7) lockEvt = true; else kick = true; wake.Set(); }   // WM_WTSSESSION_CHANGE: 7 = locked
    else if (msg == 0x8001) SetHooks(w != IntPtr.Zero);
    else if (msg == 0x8002) SetRaw(w != IntPtr.Zero);
    else if (msg == 0x8003) System.Windows.Forms.Application.ExitThread();
  }
  void Hooks(bool on) { if (win != null) PostMessage(win.Handle, 0x8001, (IntPtr)(on ? 1 : 0), IntPtr.Zero); }
  void SetRaw(bool on) {
    uint fl = on ? 0x100u : 1u; IntPtr h = on ? win.Handle : IntPtr.Zero;   // RIDEV_INPUTSINK / RIDEV_REMOVE; the keyboard only for the hook watch
    var r = new[] { new RID { page = 1, usage = 2, flags = fl, hwnd = h }, new RID { page = 1, usage = 6, flags = fl, hwnd = h } };
    if (!RegisterRawInputDevices(r, 2, Marshal.SizeOf(typeof(RID))) && on) Note("can't read the mouse (Raw Input error " + Marshal.GetLastWin32Error() + ")");
  }
  static readonly int HdrSize = IntPtr.Size == 8 ? 24 : 16;   // RAWINPUTHEADER
  public static int RawHeader { get { return HdrSize; } }
  // A RAWINPUT -> movement, usButtonFlags and usButtonData; false if it isn't from a real mouse (injected input has no device)
  public static bool ParseRaw(IntPtr p, out int dx, out int dy, out int buttons, out int data) {
    dx = dy = buttons = data = 0;
    if (Marshal.ReadInt32(p, 0) != 0 || Marshal.ReadIntPtr(p, 8) == IntPtr.Zero) return false;   // RIM_TYPEMOUSE, hDevice
    int o = HdrSize, flags = Marshal.ReadInt16(p, o) & 0xFFFF;
    buttons = Marshal.ReadInt16(p, o + 4) & 0xFFFF; data = Marshal.ReadInt16(p, o + 6);
    if ((flags & 1) == 0) { dx = Marshal.ReadInt32(p, o + 12); dy = Marshal.ReadInt32(p, o + 16); }   // ponytail: absolute devices (pens, remote desktop) only click
    return true;
  }
  // Low-level hooks: installed only while the other PC has control. The callbacks only enqueue and return.
  delegate IntPtr HookProc(int c, IntPtr w, IntPtr l);
  static readonly HookProc kbProc = KbProc, msProc = MsProc;
  static volatile Link hookFor; static IntPtr kbHook, msHook;
  void SetHooks(bool on) {
    if (kbHook != IntPtr.Zero) UnhookWindowsHookEx(kbHook);
    if (msHook != IntPtr.Zero) UnhookWindowsHookEx(msHook);
    kbHook = msHook = IntPtr.Zero;
    if (!on || NoInject || !Active) return;
    hookFor = this; IntPtr mod = GetModuleHandle(null);
    kbHook = SetWindowsHookEx(13, kbProc, mod, 0); msHook = SetWindowsHookEx(14, msProc, mod, 0);
    if (kbHook == IntPtr.Zero || msHook == IntPtr.Zero) Note("couldn't install the input hook (error " + Marshal.GetLastWin32Error() + ")");
  }
  static IntPtr KbProc(int c, IntPtr w, IntPtr l) {   // KBDLLHOOKSTRUCT: vk 0, scan 4, flags 8, time 12, extra 16
    Link o = hookFor;
    if (c >= 0 && o != null) {
      long x = Marshal.ReadIntPtr(l, 16).ToInt64();
      if ((Marshal.ReadInt32(l, 8) & 0x10) == 0) o.HookKb++;   // not LLKHF_INJECTED: what Raw Input saw too (the hook watch)
      if (x != OwnTag && o.Active) { o.Enq(1, Marshal.ReadInt32(l, 0), Marshal.ReadInt32(l, 4), Marshal.ReadInt32(l, 8), Marshal.ReadInt32(l, 12)); return (IntPtr)1; }
    }
    return CallNextHookEx(IntPtr.Zero, c, w, l);
  }
  static IntPtr MsProc(int c, IntPtr w, IntPtr l) {   // MSLLHOOKSTRUCT: extra at 24 (x64); the movement itself comes from Raw Input
    Link o = hookFor;
    if (c >= 0 && o != null) {
      long x = Marshal.ReadIntPtr(l, IntPtr.Size == 8 ? 24 : 20).ToInt64();
      if ((Marshal.ReadInt32(l, 12) & 1) == 0) o.HookMs++;   // not LLMHF_INJECTED
      if (x != OwnTag && o.Active) return (IntPtr)1;
    }
    return CallNextHookEx(IntPtr.Zero, c, w, l);
  }
  public static int HookTest(Link l, bool keyboard, IntPtr data) {   // self-test: one hook callback on a made-up struct; 1 = swallowed
    hookFor = l; try { return (keyboard ? KbProc(0, IntPtr.Zero, data) : MsProc(0, IntPtr.Zero, data)).ToInt32(); } finally { hookFor = null; }
  }
  delegate bool MonEnum(IntPtr h, IntPtr dc, ref RC r, IntPtr p);
  static Mon[] ReadMons() {   // physical pixels (this thread is PerMonitorV2) and each monitor's DPI
    var o = new List<Mon>();
    MonEnum cb = (IntPtr h, IntPtr dc, ref RC r, IntPtr p) => { uint x, y; int dpi = 96; try { if (GetDpiForMonitor(h, 0, out x, out y) == 0) dpi = (int)x; } catch {} o.Add(new Mon(r.l, r.t, r.r, r.b, dpi)); return true; };
    EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, cb, IntPtr.Zero);
    return o.ToArray();
  }

  [StructLayout(LayoutKind.Sequential)] struct RC { public int l, t, r, b; }
  [StructLayout(LayoutKind.Sequential)] struct PT { public int x, y; }
  [StructLayout(LayoutKind.Sequential)] struct RID { public ushort page, usage; public uint flags; public IntPtr hwnd; }
  [StructLayout(LayoutKind.Sequential)] struct MOUSEIN { public int dx, dy; public uint data, flags, time; public IntPtr extra; }
  [StructLayout(LayoutKind.Sequential)] struct KEYIN { public ushort vk, sc; public uint flags, time; public IntPtr extra; }
  [StructLayout(LayoutKind.Explicit)] struct UNION { [FieldOffset(0)] public MOUSEIN m; [FieldOffset(0)] public KEYIN k; }
  [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public UNION u; }
  [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] i, int size);
  [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
  [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] static extern bool GetCursorPos(out PT p);
  [DllImport("user32.dll")] static extern bool GetClipCursor(out RC r);
  [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookEx(int id, HookProc f, IntPtr mod, uint thread);
  [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr h);
  [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int c, IntPtr w, IntPtr l);
  [DllImport("user32.dll", SetLastError = true)] static extern bool RegisterRawInputDevices(RID[] d, uint n, int size);
  [DllImport("user32.dll")] static extern uint GetRawInputData(IntPtr h, uint cmd, IntPtr data, ref uint size, uint header);
  [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] static extern bool LockWorkStation();
  [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MonEnum f, IntPtr p);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
  [StructLayout(LayoutKind.Sequential)] struct QOS_VERSION { public ushort Major, Minor; }
  [DllImport("qwave.dll")] static extern bool QOSCreateHandle(ref QOS_VERSION v, out IntPtr h);
  [DllImport("qwave.dll")] static extern bool QOSCloseHandle(IntPtr h);
  [DllImport("qwave.dll")] static extern bool QOSAddSocketToFlow(IntPtr h, IntPtr s, byte[] dest, int type, uint flags, ref uint id);
  [DllImport("user32.dll")] static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
  [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr d);
  [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string n);
  [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint f);
  [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [DllImport("advapi32.dll")] static extern bool OpenProcessToken(IntPtr p, uint access, out IntPtr t);
  [DllImport("advapi32.dll")] static extern bool GetTokenInformation(IntPtr t, int cls, out int info, int len, out int ret);
  [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr h, int type, out uint x, out uint y);
  [DllImport("shell32.dll")] static extern int SHQueryUserNotificationState(out int state);
  [DllImport("wtsapi32.dll")] static extern bool WTSRegisterSessionNotification(IntPtr h, int flags);
  [DllImport("wtsapi32.dll")] static extern bool WTSUnRegisterSessionNotification(IntPtr h);
  [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint ms);
  [DllImport("winmm.dll")] static extern uint timeEndPeriod(uint ms);
}

// Text and pictures for the other PC (with DeskGlide Link; Synergy did this before). The PC where they were copied serves
// them on the file port; the other PC pulls them when the mouse arrives: its own channel, off the input path, in chunks,
// capped, with timeouts.
public static class Clip {
  public const int Max = 32 << 20;
  public static volatile string OfferId = ""; static string kind; static byte[] data;
  public static bool Offer(string k, byte[] d) {
    if (d != null && d.Length > Max) d = null;
    kind = k; data = d; OfferId = d == null ? "" : Dg.Hex(Dg.Random(8)); return d != null;
  }
  internal static void Serve(Stream s, byte[] k, string id, ref long tx) {
    byte[] d = data; string kd = kind;
    if (d == null || id != OfferId) { var g = Encoding.UTF8.GetBytes("gone"); Files.WriteFrame(s, k, 'S', tx++, g, 0, g.Length); return; }
    var h = Encoding.UTF8.GetBytes("ok\n" + kd + "\n" + d.Length); Files.WriteFrame(s, k, 'S', tx++, h, 0, h.Length);
    for (int o = 0; o < d.Length; o += 65536) Files.WriteFrame(s, k, 'S', tx++, d, o, Math.Min(65536, d.Length - o));
    Files.WriteFrame(s, k, 'S', tx++, d, 0, 0);
  }
  public static volatile string Status = "";   // "" idle, "busy", "ok", or "error: ..."
  public static string ResultKind; public static byte[] Result;
  public static void Fetch(string host, int port, byte[] key, string id) {
    Status = "busy"; Result = null;
    var t = new Thread(() => { try { FetchRun(host, port, key, id); Status = "ok"; } catch (Exception e) { Status = "error: " + e.Message; } });
    t.IsBackground = true; t.Start();
  }
  static void FetchRun(string host, int port, byte[] key, string id) {
    using (var c = new TcpClient()) {
      if (!c.ConnectAsync(host, port).Wait(5000)) throw new IOException("the other PC didn't answer");
      c.ReceiveTimeout = 15000; c.SendTimeout = 15000; var s = c.GetStream();
      byte[] nr = Dg.Random(16); s.Write(nr, 0, 16); byte[] ns = Files.ReadN(s, 16);
      byte[] k = Dg.SessionKey(key, "files", Files.Cat(nr, ns)); long rx = 0;
      byte[] ib = Encoding.UTF8.GetBytes("clip:" + id); Files.WriteFrame(s, k, 'R', 0, ib, 0, ib.Length);
      string[] h = Encoding.UTF8.GetString(Files.ReadFrame(s, k, 'S', rx++)).Split('\n');
      if (h[0] != "ok" || h.Length != 3) throw new IOException("gone");
      int n = int.Parse(h[2]); if (n < 0 || n > Max) throw new IOException("too large");
      var o = new byte[n]; int got = 0;
      while (true) {
        byte[] b = Files.ReadFrame(s, k, 'S', rx++); if (b.Length == 0) break;
        if (got + b.Length > n) throw new IOException("bad length");
        Buffer.BlockCopy(b, 0, o, got, b.Length); got += b.Length;
      }
      if (got != n) throw new IOException("cut short");
      ResultKind = h[1]; Result = o;
    }
  }
}

// DeskGlide's optional SYSTEM service (DeskGlideService.cs), seen from the app: one line out, one line back over its control
// pipe. Status and panic work for anyone; everything else the service accepts only from an elevated administrator.
public static class SvcPipe {
  public const string Name = "DeskGlideService";
  public static string Exe { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), @"DeskGlide\DeskGlideService.exe"); } }
  // The reply, or null if nothing answered. service: the pipe's server must be DeskGlideService.exe from Program Files running
  // in session 0, not a program that took the pipe's name first; false only for the self-test's console-mode service.
  // Identification level: the service can check who asks, but can't act as the caller.
  public static string Call(string pipe, string line, int timeoutMs, bool service) {
    try {
      using (var c = new System.IO.Pipes.NamedPipeClientStream(".", pipe, System.IO.Pipes.PipeDirection.InOut, System.IO.Pipes.PipeOptions.None, System.Security.Principal.TokenImpersonationLevel.Identification)) {
        c.Connect(timeoutMs);
        if (service && !ServerIs(c.SafePipeHandle.DangerousGetHandle(), Exe)) { LastError = "the pipe's server isn't DeskGlide's service"; return null; }
        var b = Encoding.UTF8.GetBytes(line.Replace("\n", " ") + "\n"); c.Write(b, 0, b.Length); c.Flush();
        var t = System.Threading.Tasks.Task.Run(() => new StreamReader(c, Encoding.UTF8).ReadLine());
        return t.Wait(timeoutMs + 2000) ? t.Result : null;
      }
    } catch (Exception e) { LastError = e.Message; return null; }
  }
  public static volatile string LastError;
  public static bool ServerIs(IntPtr pipe, string exe) {
    uint pid, sess; if (!GetNamedPipeServerProcessId(pipe, out pid) || !ProcessIdToSessionId(pid, out sess) || sess != 0) return false;   // only services run in session 0
    IntPtr p = OpenProcess(0x1000, false, pid); if (p == IntPtr.Zero) return false;   // PROCESS_QUERY_LIMITED_INFORMATION
    try { var s = new StringBuilder(1024); int n = s.Capacity; return QueryFullProcessImageName(p, 0, s, ref n) && string.Equals(s.ToString(), exe, StringComparison.OrdinalIgnoreCase); }
    finally { CloseHandle(p); }
  }
  // The app polls the service's status on its own thread, so a missing or busy service never stalls the window
  public static volatile string Last; static Thread watch;
  public static void Watch() {
    if (watch != null) return;
    watch = new Thread(() => { while (true) { Last = File.Exists(Exe) ? Call(Name, "status", 500, true) : null; Thread.Sleep(2000); } });
    watch.IsBackground = true; watch.Start();
  }
  [DllImport("kernel32.dll")] static extern bool GetNamedPipeServerProcessId(IntPtr pipe, out uint pid);
  [DllImport("kernel32.dll")] static extern bool ProcessIdToSessionId(uint pid, out uint session);
  [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr p, int flags, StringBuilder name, ref int size);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
}

// Pairing the other PC's service: an ECDH P-256 exchange carried in control messages (signed with the pairing key), checked
// by the user comparing a six-digit number on both PCs. Programs running as the user can read the pairing key, so it alone
// must not be enough: a program in the middle would show a different number.
public class SvcPair : IDisposable {
  readonly ECDiffieHellmanCng ec = new ECDiffieHellmanCng(256);
  public byte[] Pub { get { return ec.PublicKey.ToByteArray(); } }
  // The service's key and the number to compare, from the offer's and the answer's public keys and the other side's; null if
  // theirs isn't a P-256 public key
  public byte[] Finish(byte[] offer, byte[] answer, byte[] theirs, out string check) {
    check = null;
    if (offer == null || answer == null || theirs == null || theirs.Length != 72) return null;
    try {
      ec.KeyDerivationFunction = ECDiffieHellmanKeyDerivationFunction.Hash; ec.HashAlgorithm = CngAlgorithm.Sha256;
      byte[] z; using (var k = ECDiffieHellmanCngPublicKey.FromByteArray(theirs, CngKeyBlobFormat.EccPublicBlob)) z = ec.DeriveKeyMaterial(k);
      byte[] both = Files.Cat(offer, answer);
      string n = (BitConverter.ToUInt32(Dg.SessionKey(z, "service check", both), 0) % 1000000).ToString("000000");
      check = n.Substring(0, 3) + " " + n.Substring(3);
      return Dg.SessionKey(z, "service link", both);
    } catch { return null; }
  }
  // Sent by the PC with the service once the user confirmed there: shows it holds the same key
  public static byte[] Proof(byte[] key, string id) { return Dg.SessionKey(key, "service paired", Encoding.UTF8.GetBytes(id ?? "")); }
  public void Dispose() { ec.Dispose(); }
}
