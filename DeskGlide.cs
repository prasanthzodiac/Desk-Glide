// DeskGlide native helpers. DeskGlide.ps1 compiles this with Add-Type (C# 5, nothing to install).
using System; using System.Text; using System.Net; using System.Net.Sockets; using System.Threading; using System.IO;
using System.Collections.Generic; using System.Runtime.InteropServices; using System.Security.Cryptography;
using System.Drawing; using System.Drawing.Drawing2D; using System.Drawing.Imaging;
using System.Security.Cryptography.X509Certificates; using System.IO.Compression;

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
      var rq = (HttpWebRequest)WebRequest.Create(url); rq.UserAgent = "DeskGlide"; rq.Timeout = 30000;
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
  static void WriteFrame(Stream s, byte[] k, char dir, long seq, byte[] b, int off, int n) {
    byte[] e = Dg.Encrypt(k, Ad(dir, seq), b, off, n);
    s.Write(BitConverter.GetBytes(e.Length), 0, 4); s.Write(e, 0, e.Length);
  }
  static byte[] ReadFrame(Stream s, byte[] k, char dir, long seq) {
    int n = BitConverter.ToInt32(ReadN(s, 4), 0);
    if (n < 0 || n > 70000) throw new IOException("bad frame");
    byte[] d = Dg.Decrypt(k, Ad(dir, seq), ReadN(s, n), 0, n);
    if (d == null) throw new IOException("the other PC isn't paired with this one, or the data was changed on the way");
    return d;
  }
  static byte[] Ad(char dir, long seq) { var a = new byte[9]; a[0] = (byte)dir; BitConverter.GetBytes(seq).CopyTo(a, 1); return a; }
  static byte[] ReadN(Stream s, int n) {
    var b = new byte[n]; int got = 0;
    while (got < n) { int r = s.Read(b, got, n - got); if (r <= 0) throw new IOException("the connection closed"); got += r; }
    return b;
  }
  static byte[] Cat(byte[] a, byte[] b) { var o = new byte[a.Length + b.Length]; a.CopyTo(o, 0); b.CopyTo(o, a.Length); return o; }
}

public static class Dg {
  public static string Hex(byte[] b) { var s = new StringBuilder(); foreach (byte x in b) s.Append(x.ToString("x2")); return s.ToString(); }

  // ---------- Deskflow TLS: its GUI makes the certificate, the headless core doesn't, so DeskGlide does ----------
  // Writes an RSA key and a self-signed certificate as PEM (what the Deskflow GUI writes), returns its fingerprint.
  public static string MakeCert(string pemPath) {
    using (var rsa = new RSACryptoServiceProvider(2048)) {
      var req = new CertificateRequest("CN=Deskflow", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
      byte[] der = req.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(10)).RawData;
      var p = rsa.ExportParameters(true);
      byte[] key = Tlv(0x30, Cat(DerInt(new byte[] { 0 }), DerInt(p.Modulus), DerInt(p.Exponent), DerInt(p.D), DerInt(p.P),
                                 DerInt(p.Q), DerInt(p.DP), DerInt(p.DQ), DerInt(p.InverseQ)));   // PKCS#1 RSAPrivateKey
      File.WriteAllText(pemPath, Pem("RSA PRIVATE KEY", key) + Pem("CERTIFICATE", der));
      return Hex(SHA256.Create().ComputeHash(der));
    }
  }
  // SHA256 of the certificate in a PEM file, lowercase hex, the way Deskflow's trusted-servers file stores it.
  public static string PemFingerprint(string pemPath) {
    string t = File.ReadAllText(pemPath); const string a = "-----BEGIN CERTIFICATE-----", z = "-----END CERTIFICATE-----";
    int i = t.IndexOf(a), j = t.IndexOf(z); if (i < 0 || j < i) return null;
    return Hex(SHA256.Create().ComputeHash(Convert.FromBase64String(t.Substring(i + a.Length, j - i - a.Length))));
  }
  static string Pem(string label, byte[] der) {
    return "-----BEGIN " + label + "-----\n" + Convert.ToBase64String(der, Base64FormattingOptions.InsertLineBreaks).Replace("\r", "") + "\n-----END " + label + "-----\n";
  }
  static byte[] DerInt(byte[] v) {   // unsigned big-endian -> DER INTEGER
    int i = 0; while (i < v.Length - 1 && v[i] == 0) i++;
    int pad = (v[i] & 0x80) != 0 ? 1 : 0; var b = new byte[v.Length - i + pad];
    Buffer.BlockCopy(v, i, b, pad, v.Length - i); return Tlv(2, b);
  }
  static byte[] Tlv(byte tag, byte[] body) {
    var m = new MemoryStream(); m.WriteByte(tag); int n = body.Length;
    if (n < 128) m.WriteByte((byte)n); else if (n < 256) { m.WriteByte(0x81); m.WriteByte((byte)n); } else { m.WriteByte(0x82); m.WriteByte((byte)(n >> 8)); m.WriteByte((byte)n); }
    m.Write(body, 0, n); return m.ToArray();
  }
  static byte[] Cat(params byte[][] parts) { var m = new MemoryStream(); foreach (var p in parts) m.Write(p, 0, p.Length); return m.ToArray(); }

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
  public static void WakeDisplay() { SetThreadExecutionState(2); mouse_event(1, 0, 0, 0, IntPtr.Zero); }   // ES_DISPLAY_REQUIRED, zero-distance MOUSEEVENTF_MOVE

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
  public const int AudioTagLen = 8;

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

  // Audio packet: [rate:4][channels:2][seq:2][16-bit PCM][first 8 bytes of HMAC-SHA256].
  public static byte[] MakePacket(byte[] key, int rate, int ch, ushort seq, byte[] pcm, int len) {
    byte[] p = new byte[8 + len + AudioTagLen];
    BitConverter.GetBytes(rate).CopyTo(p, 0); BitConverter.GetBytes((ushort)ch).CopyTo(p, 4); BitConverter.GetBytes(seq).CopyTo(p, 6);
    Buffer.BlockCopy(pcm, 0, p, 8, len);
    Buffer.BlockCopy(Mac(key, p, 8 + len), 0, p, 8 + len, AudioTagLen);
    return p;
  }
  public static bool ValidPacket(byte[] key, byte[] p, out int rate, out int ch) {
    rate = 0; ch = 0;
    if (key == null || p == null || p.Length < 10 + AudioTagLen || p.Length > 8 + 8192 + AudioTagLen) return false;
    int n = p.Length - AudioTagLen;
    if (!Same(Mac(key, p, n), p, n, AudioTagLen)) return false;
    rate = BitConverter.ToInt32(p, 0); ch = BitConverter.ToUInt16(p, 4);
    return rate >= 8000 && rate <= 192000 && ch >= 1 && ch <= 2 && (n - 8) % (ch * 2) == 0;
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
    outLen = 0; capMode = mode;
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
      int rate, ch; if (!ValidPacket(Key, p, out rate, out ch)) { Bad++; continue; }
      got++;
      if (RecvMode == Sound && !RemoteOn) continue;   // follow mode: the mouse is on this PC, drop the other PC's sound
      if (wave == IntPtr.Zero || rate != wRate || ch != wCh || RecvDevice != wDev) OpenOut(rate, ch);
      if (RecvMode == Sound) Scale(p, 8, p.Length - AudioTagLen - 8, Volume);   // the volume slider is for the other PC's sound, not its microphone
      for (int i = 8, n = p.Length - AudioTagLen; i < n; ) {
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
