// DeskGlide native helpers. DeskGlide.ps1 compiles this with Add-Type (C# 5, nothing to install).
using System; using System.Text; using System.Net; using System.Net.Sockets; using System.Threading;
using System.Collections.Generic; using System.Runtime.InteropServices; using System.Security.Cryptography;

public static class Dg {
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
