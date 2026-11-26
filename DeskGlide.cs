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

  static void Each(Action<PM> f) {
    EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (hm, dc, r, p) => {
      uint n; if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hm, out n) || n == 0) return true;
      var a = new PM[n]; if (!GetPhysicalMonitorsFromHMONITOR(hm, n, a)) return true;
      foreach (var m in a) f(m);
      DestroyPhysicalMonitors(n, a); return true;
    }, IntPtr.Zero);
  }
  // ponytail: talks to every DDC monitor; fine for one shared monitor, filter by name if you have more
  public static bool SetInput(uint v) { bool ok = false; Each(m => ok |= SetVCPFeature(m.h, 0x60, v)); return ok; }
  public static int GetInput() {   // -1 = no DDC/CI reply
    int v = -1;
    Each(m => { uint cur, max; if (v < 0 && GetVCPFeatureAndVCPFeatureReply(m.h, 0x60, IntPtr.Zero, out cur, out max)) v = (int)(cur & 0xFF); });
    return v;
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

  // ---------- audio thread: DeskGlide.ps1 sets these flags, the thread does the rest ----------
  public static volatile bool SendOn, RecvOn, RemoteOn;
  public static volatile IPEndPoint Target;
  public static volatile byte[] Key;
  public static int Sent, Got, Bad;
  public static string LastError = "";

  public static void StartAudio(int port) {
    var t = new Thread(() => AudioLoop(port)); t.IsBackground = true; t.Start();
  }
  static void AudioLoop(int port) {
    while (true) {
      try {
        if (SendOn) { if (udp == null) udp = new UdpClient(); Sent += PumpSend(100); }
        else StopCapture();
        if (RecvOn) { if (rx == null) { rx = new UdpClient(port); rx.Client.ReceiveTimeout = 20; } Got += PumpReceive(100); }
        else { CloseOut(); if (rx != null) { rx.Close(); rx = null; } }
        if (!SendOn && !RecvOn) Thread.Sleep(100);
      } catch (Exception e) { LastError = e.Message; Thread.Sleep(1000); }
    }
  }

  // ---------- WASAPI loopback capture (COM interop) ----------
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

  static IAudioClient client; static IAudioCaptureClient capture;
  static int srcCh, srcRate, srcBits; static bool srcFloat;
  static UdpClient udp; static ushort seq;
  static byte[] outBuf = new byte[4096]; static int outLen;
  const int ChunkFrames = 288;   // 6 ms at 48 kHz; 1152 bytes stereo, fits one UDP packet

  static void InitCapture() {
    var en = (IMMDeviceEnumerator)new MMDeviceEnumeratorCo();
    IMMDevice dev; Check(en.GetDefaultAudioEndpoint(0, 0, out dev));   // eRender, eConsole
    Guid iid = typeof(IAudioClient).GUID; object o;
    Check(dev.Activate(ref iid, 23, IntPtr.Zero, out o)); client = (IAudioClient)o;
    IntPtr fmt; Check(client.GetMixFormat(out fmt));
    int tag = (ushort)Marshal.ReadInt16(fmt, 0);
    srcCh = Marshal.ReadInt16(fmt, 2); srcRate = Marshal.ReadInt32(fmt, 4); srcBits = Marshal.ReadInt16(fmt, 14);
    srcFloat = tag == 3 || (tag == 0xFFFE && Marshal.ReadInt32(fmt, 24) == 3);
    try { Check(client.Initialize(0, 0x00020000, 1000000, 0, fmt, IntPtr.Zero)); }   // shared, LOOPBACK, 100 ms
    finally { Marshal.FreeCoTaskMem(fmt); }
    iid = typeof(IAudioCaptureClient).GUID;
    Check(client.GetService(ref iid, out o)); capture = (IAudioCaptureClient)o;
    Check(client.Start());
    outLen = 0;
  }

  static void StopCapture() {
    if (client == null) return;
    try { client.Stop(); } catch {}
    if (capture != null) Marshal.ReleaseComObject(capture);
    Marshal.ReleaseComObject(client);
    capture = null; client = null;
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
  static IntPtr wave = IntPtr.Zero; static int wRate, wCh, blockBytes;
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
      if (!RemoteOn) continue;   // follow mode: the mouse is on this PC, drop the other PC's sound
      if (wave == IntPtr.Zero || rate != wRate || ch != wCh) OpenOut(rate, ch);
      Scale(p, 8, p.Length - AudioTagLen - 8, Volume);
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
    int r = waveOutOpen(out wave, -1, ref f, IntPtr.Zero, IntPtr.Zero, 0);   // default output device
    if (r != 0) { wave = IntPtr.Zero; throw new InvalidOperationException("waveOutOpen failed: " + r); }
    wRate = rate; wCh = ch; blockBytes = rate / 100 * ch * 2;
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
