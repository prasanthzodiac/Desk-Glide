# DeskGlide audio: hear another PC's sound in the headphones plugged into this PC.
#
# On the PC whose sound you want to hear (sender):
#   powershell -ExecutionPolicy Bypass -File deskglide-audio.ps1 -Send 192.168.1.20
# On the PC with the headphones (receiver):
#   powershell -ExecutionPolicy Bypass -File deskglide-audio.ps1 -Receive
#
# The sender records whatever its default speakers/headphones are playing (WASAPI loopback),
# converts it to 16-bit PCM and sends it over UDP. The receiver plays it on its default
# output device. Both PCs' sound mix in your headphones. Nothing to install.
param(
  [string]$Send,         # sender: address of the PC with the headphones
  [switch]$Receive,      # receiver: play incoming audio
  [int]   $Port = 6990,  # UDP port, same on both PCs
  [string]$From,         # receiver: only accept audio from this address
  [int]   $Seconds = 0,  # stop after this many seconds (0 = run until Ctrl+C)
  [switch]$Test          # self-check, no audio
)

Add-Type @"
using System; using System.Net; using System.Net.Sockets; using System.Threading;
using System.Collections.Generic; using System.Runtime.InteropServices;

public static class DgAudio {
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

  public static string LastError = "";
  static IAudioClient client; static IAudioCaptureClient capture;
  static int srcCh, srcRate, srcBits; static bool srcFloat;
  static UdpClient udp; static IPEndPoint target; static ushort seq;
  static byte[] outBuf = new byte[4096]; static int outLen;
  const int ChunkFrames = 288;   // 6 ms at 48 kHz; 1152 bytes stereo, fits one UDP packet

  public static void StartSend(string host, int port) {
    IPAddress ip;
    if (!IPAddress.TryParse(host, out ip))
      ip = Array.Find(Dns.GetHostAddresses(host), a => a.AddressFamily == AddressFamily.InterNetwork);
    if (ip == null) throw new ArgumentException("Cannot resolve " + host);
    target = new IPEndPoint(ip, port); udp = new UdpClient();
  }

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
    try { if (client != null) client.Stop(); } catch {}
    if (capture != null) Marshal.ReleaseComObject(capture);
    if (client != null) Marshal.ReleaseComObject(client);
    capture = null; client = null;
  }

  public static short ToPcm16(float v) {
    int s = (int)(v * 32767f);
    return (short)(s > 32767 ? 32767 : s < -32768 ? -32768 : s);
  }

  // Captures and sends for about ms milliseconds. Returns packets sent.
  public static int PumpSend(int ms) {
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
          if (outLen >= ChunkFrames * och * 2) { SendChunk(och); sent++; }
        }
        LastError = "";
      } catch (Exception e) {
        // device changed or unplugged: rebuild capture on the next pass
        LastError = e.Message; StopCapture(); Thread.Sleep(1000);
      }
    }
    return sent;
  }

  static void SendChunk(int och) {
    byte[] pkt = new byte[8 + outLen];
    BitConverter.GetBytes(srcRate).CopyTo(pkt, 0);
    BitConverter.GetBytes((ushort)och).CopyTo(pkt, 4);
    BitConverter.GetBytes(seq++).CopyTo(pkt, 6);
    Buffer.BlockCopy(outBuf, 0, pkt, 8, outLen);
    udp.Send(pkt, pkt.Length, target);
    outLen = 0;
  }

  public static void StopSend() { StopCapture(); if (udp != null) udp.Close(); udp = null; }

  // ---------- packet check (receiver trust boundary) ----------
  public static bool ValidPacket(byte[] p, out int rate, out int ch) {
    rate = 0; ch = 0;
    if (p == null || p.Length < 10 || p.Length > 8 + 8192) return false;
    rate = BitConverter.ToInt32(p, 0); ch = BitConverter.ToUInt16(p, 4);
    return rate >= 8000 && rate <= 192000 && ch >= 1 && ch <= 2 && (p.Length - 8) % (ch * 2) == 0;
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

  static UdpClient rx; static IPAddress allowFrom;
  static IntPtr wave = IntPtr.Zero; static int wRate, wCh, blockBytes;
  static IntPtr[] hdrs, datas; static bool[] busy;
  static Queue<byte[]> pending = new Queue<byte[]>();
  static byte[] fill; static int fillLen;
  public static string LastSender = "";
  public static bool Playing { get { return wave != IntPtr.Zero; } }

  public static void StartReceive(int port, string from) {
    rx = new UdpClient(port); rx.Client.ReceiveTimeout = 20;
    allowFrom = string.IsNullOrEmpty(from) ? null : IPAddress.Parse(from);
  }

  // Receives and plays for about ms milliseconds. Returns packets accepted.
  public static int PumpReceive(int ms) {
    int got = 0; DateTime end = DateTime.UtcNow.AddMilliseconds(ms);
    while (DateTime.UtcNow < end) {
      byte[] p; IPEndPoint ep = null;
      try { p = rx.Receive(ref ep); } catch (SocketException) { Feed(); continue; }
      if (allowFrom != null && !ep.Address.Equals(allowFrom)) continue;
      int rate, ch; if (!ValidPacket(p, out rate, out ch)) continue;
      LastSender = ep.Address.ToString(); got++;
      if (wave == IntPtr.Zero || rate != wRate || ch != wCh) OpenOut(rate, ch);
      for (int i = 8; i < p.Length; ) {
        int n = Math.Min(blockBytes - fillLen, p.Length - i);
        Buffer.BlockCopy(p, i, fill, fillLen, n); fillLen += n; i += n;
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

  public static void StopReceive() { CloseOut(); if (rx != null) rx.Close(); rx = null; }
}
"@

if ($Test) {
  $r = 0; $c = 0
  function Pkt([int]$rate, [int]$ch, [int]$bytes) {
    [byte[]](([BitConverter]::GetBytes($rate)) + ([BitConverter]::GetBytes([uint16]$ch)) + @(0, 0) + (,0 * $bytes))
  }
  if (-not [DgAudio]::ValidPacket((Pkt 48000 2 1152), [ref]$r, [ref]$c) -or $r -ne 48000 -or $c -ne 2) { throw 'valid stereo packet rejected' }
  if (-not [DgAudio]::ValidPacket((Pkt 44100 1 2), [ref]$r, [ref]$c)) { throw 'valid mono packet rejected' }
  if ([DgAudio]::ValidPacket((Pkt 48000 2 3), [ref]$r, [ref]$c))  { throw 'odd length accepted' }
  if ([DgAudio]::ValidPacket((Pkt 48000 6 12), [ref]$r, [ref]$c)) { throw '6 channels accepted' }
  if ([DgAudio]::ValidPacket((Pkt 1 2 4), [ref]$r, [ref]$c))      { throw 'bad sample rate accepted' }
  if ([DgAudio]::ValidPacket([byte[]](1, 2, 3), [ref]$r, [ref]$c)) { throw 'short packet accepted' }
  if ([DgAudio]::ToPcm16(2.0) -ne 32767 -or [DgAudio]::ToPcm16(-2.0) -ne -32768 -or [DgAudio]::ToPcm16(0) -ne 0) { throw 'clipping wrong' }
  'self-check ok'; return
}

if (-not $Send -and -not $Receive) { throw 'Use -Send <address of the PC with headphones> or -Receive' }
$until = if ($Seconds -gt 0) { (Get-Date).AddSeconds($Seconds) } else { [DateTime]::MaxValue }
$err = ''

if ($Send) {
  [DgAudio]::StartSend($Send, $Port)
  "Sending this PC's sound to ${Send}:$Port  (Ctrl+C to stop)"
  # ponytail: audio is not encrypted; use on your own network only
  try {
    $total = 0
    while ((Get-Date) -lt $until) {
      $total += [DgAudio]::PumpSend(250)
      if ([DgAudio]::LastError -ne $err) { $err = [DgAudio]::LastError; if ($err) { "capture error, retrying: $err" } }
    }
    "sent $total packets"
  } finally { [DgAudio]::StopSend() }
} else {
  [DgAudio]::StartReceive($Port, $From)
  "Listening on UDP $Port, playing on the default output device  (Ctrl+C to stop)"
  try {
    $who = ''; $total = 0
    while ((Get-Date) -lt $until) {
      $total += [DgAudio]::PumpReceive(250)
      if ([DgAudio]::LastSender -ne $who) { $who = [DgAudio]::LastSender; "receiving from $who" }
    }
    "received $total packets"
  } finally { [DgAudio]::StopReceive() }
}
