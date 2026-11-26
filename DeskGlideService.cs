// DeskGlide's optional SYSTEM service: lets DeskGlide Link on the other PC control admin windows, UAC prompts, the lock and
// sign-in screen, and Ctrl+Alt+Del on this PC. The security model (README, "Security model"):
// - It runs only from a folder that only administrators can change (C:\Program Files\DeskGlide), as LocalSystem.
// - It owns the receiving side of DeskGlide Link here: the UDP port, the session crypto and the reliable stream (class Link).
// - Its own key comes from a pairing the user confirms on both PCs, is stored DPAPI-protected as SYSTEM in
//   C:\ProgramData\DeskGlide\service (SYSTEM and Administrators only) and never goes back to user mode.
// - Its control pipe gives status and panic to the interactive user; pairing, unpairing, enable/disable and settings only to
//   an elevated administrator. Everything else is refused and logged.
// - Input reaches the desktop through DeskGlideHelper.exe, started in the console session over two inherited anonymous pipes.
// Built by DeskGlide.ps1 (Build-Service) with Windows' own csc.exe: DeskGlide.cs + this file + DeskGlideHelper.cs.
using System; using System.Text; using System.Net; using System.Threading; using System.IO; using System.Collections.Generic;
using System.Runtime.InteropServices; using System.Security.Cryptography; using System.Security.AccessControl;
using System.Security.Principal; using System.IO.Pipes; using System.Threading.Tasks; using System.Diagnostics; using Microsoft.Win32;

public static class ServiceMain {
  public static int Main(string[] args) {
    if (args.Length == 0) { System.ServiceProcess.ServiceBase.Run(new Svc()); return 0; }
    try {
      switch (args[0]) {
        case "-Console": return RunConsole(args);
        case "-SelfTest": return SvcTest.Run();
        case "-Sas": return Sas(args.Length > 1 ? args[1] : "");
      }
    } catch (Exception e) { Console.Error.WriteLine("DeskGlideService: " + e.Message); return 1; }
    Console.Error.WriteLine("DeskGlideService runs as a Windows service. Also: -SelfTest; -Sas on|off (as administrator); -Console -Data <folder> -Pipe <name> [-Port n] [-PeerPort n] [-NoInject] [-Helper <exe>] [-SeedKey <base64>]");
    return 2;
  }
  public static string Exe { get { return Process.GetCurrentProcess().MainModule.FileName; } }
  // Test mode: the service's logic as the current user, with its own folder and pipe, until <Data>\stop appears. It has only
  // the user's rights, so it can't be used to gain any.
  static int RunConsole(string[] a) {
    var o = new SvcOptions { Service = false, Pipe = null, Helper = Path.Combine(Path.GetDirectoryName(Exe), "DeskGlideHelper.exe") };
    for (int i = 1; i < a.Length; i++) {
      string v = i + 1 < a.Length ? a[i + 1] : null;
      switch (a[i]) {
        case "-Data": o.Data = v; i++; break;
        case "-Pipe": o.Pipe = v; i++; break;
        case "-Port": o.Port = int.Parse(v); i++; break;
        case "-PeerPort": o.PeerPort = int.Parse(v); i++; break;
        case "-Helper": o.Helper = v; i++; break;
        case "-SeedKey": o.SeedKey = Convert.FromBase64String(v); i++; break;
        case "-NoInject": o.NoInject = true; break;
        default: throw new ArgumentException("unknown option " + a[i]);
      }
    }
    if (o.Data == null || o.Pipe == null || o.Pipe == SvcPipe.Name || Path.GetFullPath(o.Data).TrimEnd('\\').Equals(SvcStore.Dir, StringComparison.OrdinalIgnoreCase))
      throw new ArgumentException("console mode needs its own -Data folder and -Pipe name");
    var core = new SvcCore(o); core.Start();
    string stop = Path.Combine(o.Data, "stop");
    while (!File.Exists(stop)) Thread.Sleep(100);
    core.Stop(); File.Delete(stop); return 0;
  }
  // As administrator, from DeskGlide's setup: allow Ctrl+Alt+Del from services, or put back what was there before
  static int Sas(string v) {
    string why = SvcStore.Prepare(SvcStore.Dir, true); if (why != null) throw new InvalidOperationException(why);
    string backup = Path.Combine(SvcStore.Dir, "sas-previous.txt");
    if (v == "on") SasPolicy.Enable(Registry.LocalMachine, SasPolicy.KeyPath, backup);
    else if (v == "off") SasPolicy.Restore(Registry.LocalMachine, SasPolicy.KeyPath, backup);
    else throw new ArgumentException("-Sas on or -Sas off");
    Console.WriteLine("Ctrl+Alt+Del from DeskGlide: " + (SasPolicy.Allowed(Registry.LocalMachine, SasPolicy.KeyPath) ? "allowed" : "not allowed"));
    return 0;
  }
}

public class Svc : System.ServiceProcess.ServiceBase {
  SvcCore core;
  public Svc() { ServiceName = SvcPipe.Name; CanStop = true; CanShutdown = true; CanHandleSessionChangeEvent = true; }
  // null if both programs sit where only administrators can change them; else why not
  public static string Check(string exe, string helper) { return SvcPaths.Writable(exe, 2) ?? SvcPaths.Writable(helper, 2); }
  protected override void OnStart(string[] args) {
    string exe = ServiceMain.Exe, helper = Path.Combine(Path.GetDirectoryName(exe), "DeskGlideHelper.exe");
    string why = Check(exe, helper);
    if (why != null) throw new InvalidOperationException("DeskGlide's service runs only from a folder that only administrators can change: " + why);
    core = new SvcCore(new SvcOptions { Service = true, Data = SvcStore.Dir, Pipe = SvcPipe.Name, Helper = helper });
    core.Start();
  }
  protected override void OnStop() { if (core != null) core.Stop(); }
  protected override void OnShutdown() { OnStop(); }
  protected override void OnSessionChange(System.ServiceProcess.SessionChangeDescription d) { if (core != null) core.SessionChanged(); }
}

public class SvcOptions {
  public string Data, Pipe, Helper; public int Port = 6993, PeerPort = 6993; public bool Service, NoInject; public byte[] SeedKey;
}

// The service's work: DeskGlide Link (receiving), the control pipe, and the helper in the console session.
public class SvcCore {
  readonly SvcOptions o; volatile Link link; volatile byte[] key; Dictionary<string, string> cfg;
  volatile bool running, restart; Thread pipeT, superT; readonly ManualResetEvent stop = new ManualResetEvent(false); readonly AutoResetEvent nudge = new AutoResetEvent(false);
  volatile Mon[] mons = new Mon[0]; readonly object gate = new object(), helperGate = new object(), logGate = new object();
  IntPtr helperProc; uint helperSession = uint.MaxValue; Stream toHelper, fromHelper; int helperAt, quickExits, linkTry = -100000, pipeErrAt = -100000;
  public int Dropped, RefusedCmds;
  public SvcCore(SvcOptions opt) { o = opt; }

  public void Start() {
    string why = SvcStore.Prepare(o.Data, o.Service); if (why != null) throw new InvalidOperationException(why);
    running = true;
    Log("DeskGlide service starting" + (o.Service ? "" : " in console mode as " + Environment.UserName) + (o.NoInject ? ", no injection" : ""));
    if (o.SeedKey != null) SvcStore.SaveKey(o.Data, o.SeedKey);
    key = SvcStore.LoadKey(o.Data); cfg = SvcStore.LoadSettings(o.Data);
    Log(key == null ? "not paired: turn admin control on in DeskGlide" : "paired" + (Peer != null ? " with " + Peer : ""));
    pipeT = Run(PipeLoop); superT = Run(Supervise);
  }
  public void Stop() {
    running = false; stop.Set(); nudge.Set();
    if (superT != null) superT.Join(5000);
    StopLink("the service stopped");   // releases every key through the helper first
    if (pipeT != null) pipeT.Join(3000);
    KillHelper(); Log("stopped");
  }
  public void SessionChanged() { nudge.Set(); }
  bool Enabled { get { lock (gate) { string v; return !cfg.TryGetValue("enabled", out v) || v != "0"; } } }
  string Peer { get { lock (gate) { string v; return cfg.TryGetValue("peer", out v) ? v : null; } } }
  static Thread Run(ThreadStart f) { var t = new Thread(f); t.IsBackground = true; t.Start(); return t; }

  // ---------- DeskGlide Link ----------
  void StartLink() {
    var l = new Link { Name = Environment.MachineName, Sender = false, Key = key };
    l.Out = ToHelper; l.Sas = PressSas;
    IPAddress a; string p = Peer; if (p != null && IPAddress.TryParse(p, out a)) l.Peer = a;
    l.SetLocal(mons);
    l.Start(o.Port, o.PeerPort); link = l;
    l.SetLocal(mons);   // the helper's report may have come in between: it saw no link yet, and reports again only on a change
    Log("DeskGlide Link receiving on UDP port " + o.Port);
  }
  void StopLink(string why) {
    var l = link; link = null;
    if (l != null) { l.Stop(); Drain(l); Log("DeskGlide Link stopped: " + why); }
  }
  void Drain(Link l) { string m; while (l.Log.TryDequeue(out m)) Log("link: " + m); }
  void ToHelper(int kind, int a, int b, int c, int d) {
    byte[] f = kind == 1 ? HelperProto.Ints((byte)'K', a, b, c) : kind == 2 ? HelperProto.Ints((byte)'M', a, b, c, d) : HelperProto.Frame((byte)'L', new byte[0]);
    lock (helperGate) {
      if (toHelper == null) { Dropped++; return; }
      try { toHelper.Write(f, 0, f.Length); toHelper.Flush(); } catch { Dropped++; }
    }
  }
  void PressSas() {
    bool allowed = SasPolicy.Allowed(Registry.LocalMachine, SasPolicy.KeyPath);
    if (o.NoInject) { Log("would press Ctrl+Alt+Del (SendSAS); allowed by the Windows policy: " + (allowed ? "yes" : "no")); return; }
    if (!allowed) { Log("Ctrl+Alt+End from the other PC, but Ctrl+Alt+Del isn't allowed: turn admin control on again and allow it"); return; }
    try { SendSAS(false); Log("pressed Ctrl+Alt+Del"); } catch (Exception e) { Log("can't press Ctrl+Alt+Del: " + e.Message); }
  }

  // ---------- the supervisor: the helper, Link's log, restarts ----------
  void Supervise() {
    while (running) {
      nudge.WaitOne(250);
      if (!running) break;
      try {
        Helper();
        var l = link; if (l != null) Drain(l);
        if (restart) { restart = false; StopLink("new settings"); linkTry = -100000; }
        if (link == null && key != null && Enabled && Environment.TickCount - linkTry > 5000) {
          linkTry = Environment.TickCount;
          try { StartLink(); } catch (Exception e) { Log("can't start DeskGlide Link: " + e.Message + " (trying again in 5 s; DeskGlide on this PC lets go of the port once it sees the service)"); }
        }
      } catch (Exception e) { Log("error: " + e.Message); }
    }
  }
  // Exactly one helper, in the session at the console; a new one when that session changes or it exits
  void Helper() {
    uint want = o.Service ? WTSGetActiveConsoleSessionId() : (uint)Process.GetCurrentProcess().SessionId;
    if (want == 0xFFFFFFFF) return;   // no session at the console this moment (switching users)
    bool alive = helperProc != IntPtr.Zero && WaitForSingleObject(helperProc, 0) != 0;
    if (alive && helperSession == want) return;
    if (helperProc != IntPtr.Zero) {
      if (!alive) { Log("the helper exited"); quickExits = Environment.TickCount - helperAt < 3000 ? quickExits + 1 : 0; }
      else Log("console session " + helperSession + " -> " + want + ": moving the helper");
      KillHelper();
    }
    if (quickExits >= 5 && Environment.TickCount - helperAt < 30000) return;   // it keeps exiting: try every 30 s
    helperAt = Environment.TickCount;
    if (o.Service) { string why = SvcPaths.Writable(o.Helper, 2); if (why != null) { Log("not starting the helper: " + why); return; } }
    var toH = new AnonymousPipeServerStream(PipeDirection.Out, HandleInheritability.Inheritable, 0, SvcAcl.Anon(o.Service));
    var fromH = new AnonymousPipeServerStream(PipeDirection.In, HandleInheritability.Inheritable, 0, SvcAcl.Anon(o.Service));
    string err;
    IntPtr proc = SvcLaunch.Start(o.Helper, o.NoInject ? "-NoInject" : "", o.Service ? want : uint.MaxValue,
                                  toH.ClientSafePipeHandle.DangerousGetHandle(), fromH.ClientSafePipeHandle.DangerousGetHandle(), out err);
    toH.DisposeLocalCopyOfClientHandle(); fromH.DisposeLocalCopyOfClientHandle();
    if (proc == IntPtr.Zero) { Log("can't start the helper: " + err); toH.Dispose(); fromH.Dispose(); return; }
    lock (helperGate) toHelper = toH;
    fromHelper = fromH; helperProc = proc; helperSession = want;
    Run(() => ReadHelper(fromH));
  }
  void ReadHelper(Stream s) {
    try {
      byte t; byte[] p;
      while (HelperProto.Read(s, out t, out p)) {
        if (t == 'D') { var m = HelperProto.Monitors(p); if (m != null) { mons = Array.ConvertAll(m, x => new Mon(x.L, x.T, x.R, x.B, x.Dpi)); var l = link; if (l != null) l.SetLocal(mons); } }
        else if (t == 'G') Log("helper: " + Encoding.UTF8.GetString(p));
      }
    } catch (Exception e) { if (running) Log("helper pipe: " + e.Message); }
  }
  void KillHelper() {
    Stream s; lock (helperGate) { s = toHelper; toHelper = null; }
    if (s != null) try { s.Dispose(); } catch { }   // the end of its input: it injects what it has, then exits
    if (helperProc != IntPtr.Zero) {
      if (WaitForSingleObject(helperProc, 2000) != 0) TerminateProcess(helperProc, 1);
      CloseHandle(helperProc); helperProc = IntPtr.Zero; helperSession = uint.MaxValue;
    }
    if (fromHelper != null) { try { fromHelper.Dispose(); } catch { } fromHelper = null; }
  }

  // ---------- the control pipe ----------
  void PipeLoop() {
    NamedPipeServerStream next = null;
    while (running) {
      var s = next ?? NewPipe(); next = null;
      if (s == null) { stop.WaitOne(1000); continue; }
      try {
        var ar = s.BeginWaitForConnection(null, null);
        if (WaitHandle.WaitAny(new[] { ar.AsyncWaitHandle, stop }) == 1) break;
        s.EndWaitForConnection(ar);
        next = NewPipe();   // the next instance first: the name is never free for another program between clients
        Serve(s);
      } catch (Exception e) { if (running) Log("control pipe: " + e.Message); }
      finally { s.Dispose(); }
    }
    if (next != null) next.Dispose();
  }
  NamedPipeServerStream NewPipe() {
    try { return new NamedPipeServerStream(o.Pipe, PipeDirection.InOut, 2, PipeTransmissionMode.Byte, PipeOptions.Asynchronous, 1024, 1024, SvcAcl.Pipe(o.Service)); }
    catch (Exception e) {
      if (Environment.TickCount - pipeErrAt > 60000) { pipeErrAt = Environment.TickCount; Log("can't open the control pipe (does another program hold its name?): " + e.Message); }
      return null;
    }
  }
  void Serve(NamedPipeServerStream s) {
    string line = ReadLine(s, 2000); if (line == null) return;
    string[] w = line.Trim().Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
    string verb = w.Length > 0 ? w[0].ToLowerInvariant() : "";
    string who = "an unknown caller"; bool admin = false;
    try { s.RunAsClient(() => { using (var id = WindowsIdentity.GetCurrent(true)) { if (id != null) { who = id.Name; admin = SvcAuth.ElevatedAdmin(id); } } }); }
    catch (Exception e) { who += " (" + e.Message + ")"; }
    if (!SvcAuth.Allowed(verb, admin)) {
      RefusedCmds++; Log("refused '" + Clip(verb) + "' from " + who + (Array.IndexOf(SvcAuth.AdminVerbs, verb) >= 0 ? ": only an elevated administrator may do that" : ": unknown command"));
      Reply(s, "refused"); return;
    }
    string r = "ok";
    try {
      switch (verb) {
        case "status": r = Status(); break;
        case "panic": { var l = link; if (l != null) l.Panic(); Log("panic from " + who + ": control ends here, every key released"); break; }
        case "pair": r = Pair(w, who); break;
        case "unpair": SvcStore.DeleteKey(o.Data); key = null; restart = true; Log("unpaired by " + who); break;
        case "enable": case "disable": Set("enabled", verb == "enable" ? "1" : "0"); restart = true; Log(verb + "d by " + who); break;
        case "peer": { IPAddress a; if (w.Length != 2 || !IPAddress.TryParse(w[1], out a)) { r = "error: peer <IPv4 address>"; break; } Set("peer", a.ToString()); var l = link; if (l != null) l.Peer = a; Log("peer " + a + " set by " + who); break; }
      }
    } catch (Exception e) { r = "error: " + e.Message; Log(verb + " failed: " + e.Message); }
    nudge.Set(); Reply(s, r);
  }
  string Pair(string[] w, string who) {   // pair <base64 key> <peer address or -> <peer name or ->
    if (w.Length != 4) return "error: pair <key> <address> <name>";
    byte[] k; try { k = Convert.FromBase64String(w[1]); } catch { k = null; }
    if (k == null || k.Length != 32) return "error: the key must be 32 bytes";
    IPAddress a = null; if (w[2] != "-" && !IPAddress.TryParse(w[2], out a)) return "error: bad address";
    if (w[3] != "-" && !System.Text.RegularExpressions.Regex.IsMatch(w[3], "^[A-Za-z0-9._-]{1,63}$")) return "error: bad name";
    SvcStore.SaveKey(o.Data, k); key = k;
    lock (gate) { if (a != null) cfg["peer"] = a.ToString(); if (w[3] != "-") cfg["name"] = w[3]; cfg["enabled"] = "1"; SvcStore.SaveSettings(o.Data, cfg); }
    restart = true; Log("paired by " + who + (w[3] != "-" ? " with " + w[3] : ""));
    return "ok";
  }
  void Set(string k, string v) { lock (gate) { cfg[k] = v; SvcStore.SaveSettings(o.Data, cfg); } }
  string Status() {
    var l = link; string name; lock (gate) { if (!cfg.TryGetValue("name", out name)) name = "-"; }
    return "ok enabled=" + (Enabled ? 1 : 0) + " paired=" + (key != null ? 1 : 0) + " link=" + (l != null ? 1 : 0)
         + " up=" + (l != null && l.Up ? 1 : 0) + " controlled=" + (l != null && l.Controlled ? 1 : 0)
         + " helper=" + (helperProc != IntPtr.Zero ? 1 : 0) + " sas=" + (SasPolicy.Allowed(Registry.LocalMachine, SasPolicy.KeyPath) ? 1 : 0)
         + " peer=" + name + " refused=" + (RefusedCmds + (l != null ? l.Refused : 0)) + " dropped=" + Dropped;
  }
  static string ReadLine(Stream s, int ms) {   // one line of at most 1 KB, or null after ms
    var t = Task.Run(() => { var b = new List<byte>(); int c; while (b.Count < 1024 && (c = s.ReadByte()) >= 0 && c != '\n') b.Add((byte)c); return Encoding.UTF8.GetString(b.ToArray()); });
    try { return t.Wait(ms) ? t.Result : null; } catch { return null; }
  }
  static void Reply(Stream s, string r) { try { var b = Encoding.UTF8.GetBytes(r + "\n"); s.Write(b, 0, b.Length); s.Flush(); } catch { } }
  static string Clip(string s) { return s.Length > 40 ? s.Substring(0, 40) + "..." : s; }

  public void Log(string s) {
    string line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + " " + s;
    lock (logGate) {
      if (!o.Service) Console.WriteLine(line);
      try {
        string p = Path.Combine(o.Data, "service.log");
        if (File.Exists(p) && new FileInfo(p).Length > (1 << 20)) { File.Delete(p + ".old"); File.Move(p, p + ".old"); }
        File.AppendAllText(p, line + Environment.NewLine);
      } catch { }
    }
  }
  [DllImport("kernel32.dll")] static extern uint WTSGetActiveConsoleSessionId();
  [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
  [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr h, uint code);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [DllImport("sas.dll")] static extern void SendSAS(bool asUser);
}

// Who may do what over the control pipe
public static class SvcAuth {
  public static readonly string[] AdminVerbs = { "pair", "unpair", "enable", "disable", "peer" };
  public static bool Allowed(string verb, bool elevatedAdmin) { return verb == "status" || verb == "panic" || (elevatedAdmin && Array.IndexOf(AdminVerbs, verb) >= 0); }
  // An administrator whose administrator rights are on (approved in a UAC prompt), not a user's or a filtered token
  public static bool ElevatedAdmin(WindowsIdentity id) {
    if (id == null || id.IsAnonymous || id.IsGuest) return false;
    int elev, n; if (!GetTokenInformation(id.Token, 20, out elev, 4, out n) || elev == 0) return false;   // TokenElevation
    return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator);   // CheckTokenMembership: enabled, not deny-only
  }
  [DllImport("advapi32.dll")] static extern bool GetTokenInformation(IntPtr t, int cls, out int info, int len, out int ret);
}

public static class SvcAcl {
  public static readonly SecurityIdentifier System = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
  public static readonly SecurityIdentifier Admins = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
  public static readonly SecurityIdentifier Interactive = new SecurityIdentifier(WellKnownSidType.InteractiveSid, null);
  public static readonly SecurityIdentifier Network = new SecurityIdentifier(WellKnownSidType.NetworkSid, null);
  public static readonly SecurityIdentifier TrustedInstaller = new SecurityIdentifier("S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464");
  // The service's data folder: SYSTEM and Administrators only, nothing inherited from ProgramData (where users may write)
  public static DirectorySecurity AdminDir() {
    var d = new DirectorySecurity(); d.SetAccessRuleProtection(true, false);
    foreach (var s in new[] { System, Admins }) d.AddAccessRule(new FileSystemAccessRule(s, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
    return d;
  }
  // The control pipe: SYSTEM and Administrators full, the interactive user read/write (no new instances, so it can't stand
  // in for the service), nobody over the network. Console mode adds its own user so it can open the next instance.
  public const PipeAccessRights UserRights = PipeAccessRights.ReadWrite | PipeAccessRights.Synchronize;
  public static PipeSecurity Pipe(bool service) {
    var p = new PipeSecurity(); p.SetAccessRuleProtection(true, false);
    p.AddAccessRule(new PipeAccessRule(Network, PipeAccessRights.FullControl, AccessControlType.Deny));
    p.AddAccessRule(new PipeAccessRule(System, PipeAccessRights.FullControl, AccessControlType.Allow));
    p.AddAccessRule(new PipeAccessRule(Admins, PipeAccessRights.FullControl, AccessControlType.Allow));
    p.AddAccessRule(new PipeAccessRule(Interactive, UserRights, AccessControlType.Allow));
    if (!service) p.AddAccessRule(new PipeAccessRule(WindowsIdentity.GetCurrent().User, PipeAccessRights.CreateNewInstance, AccessControlType.Allow));
    return p;
  }
  public static PipeSecurity Anon(bool service) {   // the helper's pipes: its inherited handles need no access check, so SYSTEM only
    if (!service) return null;
    var p = new PipeSecurity(); p.SetAccessRuleProtection(true, false);
    p.AddAccessRule(new PipeAccessRule(System, PipeAccessRights.FullControl, AccessControlType.Allow));
    return p;
  }
}

// Can programs running as a user change this file or folder, or swap what holds it?
public static class SvcPaths {
  // write or add, append or add a folder, extended attributes, delete inside, attributes, delete, permissions, owner, GENERIC_ALL/WRITE
  const int Change = 0x2 | 0x4 | 0x10 | 0x40 | 0x100 | 0x10000 | 0x40000 | 0x80000 | 0x10000000 | 0x40000000;
  const int Swap = 0x40 | 0x10000 | 0x40000 | 0x80000 | 0x10000000;   // a folder further up: what lets someone replace what's inside
  public static bool Trusted(SecurityIdentifier s) { return s != null && (s == SvcAcl.System || s == SvcAcl.Admins || s == SvcAcl.TrustedInstaller); }
  // null if only SYSTEM, Administrators and TrustedInstaller can; else why not. strict: how many levels from path up must be
  // unchangeable (2 for a program: it and its folder, where a planted DLL would load); above that, only swapping counts.
  public static string Writable(string path, int strict) {
    string p;
    try { p = Path.GetFullPath(path).TrimEnd('\\'); if (p.EndsWith(":")) p += "\\"; } catch { return "bad path " + path; }
    for (int level = 0; p != null; level++, p = Path.GetDirectoryName(p)) {
      FileAttributes a; try { a = File.GetAttributes(p); } catch { return p + " doesn't exist"; }
      if (level < strict && (a & FileAttributes.ReparsePoint) != 0) return p + " is a link";
      FileSystemSecurity sec;
      try {
        if ((a & FileAttributes.Directory) != 0) sec = Directory.GetAccessControl(p, AccessControlSections.Access | AccessControlSections.Owner);
        else sec = File.GetAccessControl(p, AccessControlSections.Access | AccessControlSections.Owner);
      } catch (Exception e) { return "can't read the permissions of " + p + ": " + e.Message; }
      var owner = sec.GetOwner(typeof(SecurityIdentifier)) as SecurityIdentifier;
      if (!Trusted(owner)) return p + " belongs to " + Who(owner);
      int bad = level < strict ? Change : Swap;
      foreach (FileSystemAccessRule r in sec.GetAccessRules(true, true, typeof(SecurityIdentifier))) {
        if (r.AccessControlType != AccessControlType.Allow || (r.PropagationFlags & PropagationFlags.InheritOnly) != 0) continue;
        var s = r.IdentityReference as SecurityIdentifier;
        if (!Trusted(s) && ((int)r.FileSystemRights & bad) != 0) return Who(s) + " can change " + p;
      }
    }
    return null;
  }
  static string Who(SecurityIdentifier s) { if (s == null) return "nobody"; try { return s.Translate(typeof(NTAccount)).Value; } catch { return s.Value; } }
}

// The service's own files: its key (DPAPI as SYSTEM: only the service can read it), settings and log
public static class SvcStore {
  public static string Dir { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), @"DeskGlide\service"); } }
  public static string AppDir { get { return Path.GetDirectoryName(SvcPipe.Exe); } }
  static readonly byte[] Entropy = Encoding.UTF8.GetBytes("DeskGlide service key");
  // strict (the service): dir and its parent end up SYSTEM and Administrators only; whatever was there instead (ProgramData
  // lets users create folders, so a program could have made them first) is removed, never followed through a link.
  // null when done, else why not.
  public static string Prepare(string dir, bool strict) {
    if (!strict) { Directory.CreateDirectory(dir); return null; }
    foreach (string d in new[] { Path.GetDirectoryName(dir), dir })
      for (int i = 0; ; i++) {
        string why = SvcPaths.Writable(d, 1); if (why == null) break;
        if (i == 3) return "can't make " + d + " safe: " + why;
        if (Directory.Exists(d) || File.Exists(d)) Remove(d);
        try { Directory.CreateDirectory(d, SvcAcl.AdminDir()); } catch { }
      }
    return null;
  }
  static void Remove(string p) {
    try {
      var a = File.GetAttributes(p);
      if ((a & FileAttributes.Directory) == 0) File.Delete(p);
      else if ((a & FileAttributes.ReparsePoint) != 0) Directory.Delete(p);   // the link itself, not where it points
      else Directory.Delete(p, true);   // doesn't recurse through links inside
    } catch { }
  }
  public static string KeyFile(string dir) { return Path.Combine(dir, "pairing.key"); }
  public static void SaveKey(string dir, byte[] key) { Atomic(KeyFile(dir), ProtectedData.Protect(key, Entropy, DataProtectionScope.CurrentUser)); }
  public static byte[] LoadKey(string dir) {
    try { var k = ProtectedData.Unprotect(File.ReadAllBytes(KeyFile(dir)), Entropy, DataProtectionScope.CurrentUser); return k.Length == 32 ? k : null; } catch { return null; }
  }
  public static void DeleteKey(string dir) { File.Delete(KeyFile(dir)); }
  public static Dictionary<string, string> LoadSettings(string dir) {
    var d = new Dictionary<string, string>();
    try { foreach (var l in File.ReadAllLines(Path.Combine(dir, "service.txt"))) { int i = l.IndexOf('='); if (i > 0) d[l.Substring(0, i)] = l.Substring(i + 1); } } catch { }
    return d;
  }
  public static void SaveSettings(string dir, Dictionary<string, string> d) {
    var s = new StringBuilder(); foreach (var kv in d) s.Append(kv.Key + "=" + kv.Value + "\r\n");
    Atomic(Path.Combine(dir, "service.txt"), Encoding.UTF8.GetBytes(s.ToString()));
  }
  static void Atomic(string path, byte[] b) {
    File.WriteAllBytes(path + ".tmp", b);
    if (File.Exists(path)) File.Replace(path + ".tmp", path, null); else File.Move(path + ".tmp", path);
  }
}

// Ctrl+Alt+Del from a service: Windows allows SendSAS only with the policy "Disable or enable software Secure Attention
// Sequence" (SoftwareSASGeneration) set to services (1) or services and Ease of Access apps (3). DeskGlide remembers what
// was there before and puts it back when admin control is turned off.
public static class SasPolicy {
  public const string KeyPath = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System", Value = "SoftwareSASGeneration";
  public static int On(int? before) { return before == 2 || before == 3 ? 3 : 1; }   // keep Ease of Access apps if they had it
  public static bool Allowed(RegistryKey hive, string sub) {
    try { using (var k = hive.OpenSubKey(sub)) { object v = k == null ? null : k.GetValue(Value); return v is int && ((int)v == 1 || (int)v == 3); } } catch { return false; }
  }
  public static void Enable(RegistryKey hive, string sub, string backup) {
    using (var k = hive.CreateSubKey(sub)) {
      object v = k.GetValue(Value); int? before = v is int ? (int?)(int)v : null;
      if (!File.Exists(backup)) File.WriteAllText(backup, before.HasValue ? before.Value.ToString() : "none");   // the value from before DeskGlide, once
      k.SetValue(Value, On(before), RegistryValueKind.DWord);
    }
  }
  public static void Restore(RegistryKey hive, string sub, string backup) {
    if (!File.Exists(backup)) return;   // DeskGlide never changed it
    string was = File.ReadAllText(backup).Trim(); int n;
    using (var k = hive.CreateSubKey(sub)) {
      if (int.TryParse(was, out n)) k.SetValue(Value, n, RegistryValueKind.DWord); else k.DeleteValue(Value, false);
    }
    File.Delete(backup);
  }
}

// Starting the helper with only its two pipe handles inherited (PROC_THREAD_ATTRIBUTE_HANDLE_LIST: none of the service's
// sockets or files leak into it). session: run as SYSTEM in that session, on winsta0\default (the helper then follows the
// input desktop); uint.MaxValue: as this process (console mode).
public static class SvcLaunch {
  public static IntPtr Start(string exe, string args, uint session, IntPtr stdin, IntPtr stdout, out string err) {
    err = null; IntPtr tok = IntPtr.Zero, dup = IntPtr.Zero, list = IntPtr.Zero, handles = IntPtr.Zero; bool listOk = false;
    try {
      if (session != uint.MaxValue) {
        if (!OpenProcessToken(GetCurrentProcess(), 0x1 | 0x2 | 0x8 | 0x80 | 0x100, out tok)) return Fail(out err, "OpenProcessToken");   // ASSIGN_PRIMARY, DUPLICATE, QUERY, ADJUST_DEFAULT, ADJUST_SESSIONID
        if (!DuplicateTokenEx(tok, 0x2000000, IntPtr.Zero, 2, 1, out dup)) return Fail(out err, "DuplicateTokenEx");   // MAXIMUM_ALLOWED, SecurityImpersonation, TokenPrimary
        if (!SetTokenInformation(dup, 12, ref session, 4)) return Fail(out err, "SetTokenInformation(TokenSessionId)");
      }
      IntPtr size = IntPtr.Zero; InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
      list = Marshal.AllocHGlobal(size);
      if (!InitializeProcThreadAttributeList(list, 1, 0, ref size)) return Fail(out err, "InitializeProcThreadAttributeList");
      listOk = true;
      handles = Marshal.AllocHGlobal(2 * IntPtr.Size); Marshal.WriteIntPtr(handles, 0, stdin); Marshal.WriteIntPtr(handles, IntPtr.Size, stdout);
      if (!UpdateProcThreadAttribute(list, 0, (IntPtr)0x20002, handles, (IntPtr)(2 * IntPtr.Size), IntPtr.Zero, IntPtr.Zero)) return Fail(out err, "UpdateProcThreadAttribute");
      var si = new STARTUPINFOEX(); si.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX)); si.lpAttributeList = list;
      si.StartupInfo.dwFlags = 0x100; si.StartupInfo.hStdInput = stdin; si.StartupInfo.hStdOutput = stdout;   // STARTF_USESTDHANDLES
      si.StartupInfo.lpDesktop = @"winsta0\default";
      var cmd = new StringBuilder("\"" + exe + "\"" + (string.IsNullOrEmpty(args) ? "" : " " + args));
      const uint flags = 0x80000 | 0x08000000;   // EXTENDED_STARTUPINFO_PRESENT, CREATE_NO_WINDOW
      PROCESS_INFORMATION pi; string dir = Path.GetDirectoryName(exe);
      bool ok = dup != IntPtr.Zero ? CreateProcessAsUser(dup, exe, cmd, IntPtr.Zero, IntPtr.Zero, true, flags, IntPtr.Zero, dir, ref si, out pi)
                                   : CreateProcess(exe, cmd, IntPtr.Zero, IntPtr.Zero, true, flags, IntPtr.Zero, dir, ref si, out pi);
      if (!ok) return Fail(out err, "CreateProcess");
      CloseHandle(pi.hThread); return pi.hProcess;
    } finally {
      if (listOk) DeleteProcThreadAttributeList(list);
      if (list != IntPtr.Zero) Marshal.FreeHGlobal(list);
      if (handles != IntPtr.Zero) Marshal.FreeHGlobal(handles);
      if (dup != IntPtr.Zero) CloseHandle(dup);
      if (tok != IntPtr.Zero) CloseHandle(tok);
    }
  }
  static IntPtr Fail(out string err, string what) { err = what + " failed (error " + Marshal.GetLastWin32Error() + ")"; return IntPtr.Zero; }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct STARTUPINFO {
    public int cb; public string lpReserved, lpDesktop, lpTitle; public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
    public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
  }
  [StructLayout(LayoutKind.Sequential)] struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }
  [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
  [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr p, uint access, out IntPtr t);
  [DllImport("advapi32.dll", SetLastError = true)] static extern bool DuplicateTokenEx(IntPtr t, uint access, IntPtr sa, int level, int type, out IntPtr dup);
  [DllImport("advapi32.dll", SetLastError = true)] static extern bool SetTokenInformation(IntPtr t, int cls, ref uint info, int len);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attr, IntPtr value, IntPtr size, IntPtr prev, IntPtr retSize);
  [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
  [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool CreateProcessAsUser(IntPtr token, string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string dir, ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool CreateProcess(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string dir, ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);
}

// DeskGlideService.exe -SelfTest: the security parts, as the current user, touching only temp folders and HKCU\Software\DeskGlideTest-*
public static class SvcTest {
  static int n;
  static void Check(bool ok, string what) { if (!ok) throw new Exception("service self-test FAILED: " + what); n++; }
  public static int Run() {
    // 1. the control pipe's authorization matrix: elevated administrator / a user or a non-elevated administrator / another user
    string[] verbs = { "status", "panic", "pair", "unpair", "enable", "disable", "peer", "shutdown", "" };
    var rows = new StringBuilder();
    foreach (var v in verbs) {
      bool admin = SvcAuth.Allowed(v, true), user = SvcAuth.Allowed(v, false);
      bool want = v == "status" || v == "panic" || Array.IndexOf(SvcAuth.AdminVerbs, v) >= 0;
      Check(admin == want, "elevated admin: " + v);
      Check(user == (v == "status" || v == "panic"), "user: " + v);
      rows.Append(string.Format("  {0,-9} elevated admin {1,-7} user/other user {2}\n", v == "" ? "(empty)" : v, admin ? "allowed" : "refused", user ? "allowed" : "refused"));
    }
    Console.Write("authorization matrix:\n" + rows);
    using (var me = WindowsIdentity.GetCurrent()) {
      Console.WriteLine("this process (" + me.Name + "): elevated administrator = " + SvcAuth.ElevatedAdmin(me));
      Check(!SvcAuth.ElevatedAdmin(WindowsIdentity.GetAnonymous()), "anonymous is no administrator");
    }
    // 2. ACLs
    string dirSddl = SvcAcl.AdminDir().GetSecurityDescriptorSddlForm(AccessControlSections.Access);
    Check(dirSddl == "D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)" || dirSddl == "D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)", "data folder ACL " + dirSddl);
    var pipe = SvcAcl.Pipe(true); string pipeSddl = pipe.GetSecurityDescriptorSddlForm(AccessControlSections.Access);
    Check(pipeSddl.StartsWith("D:P(D;;0x1f019f;;;NU)") && pipeSddl.Contains("(A;;0x1f019f;;;SY)") && pipeSddl.Contains("(A;;0x1f019f;;;BA)") && pipeSddl.Contains(";;;IU)"), "pipe ACL " + pipeSddl);   // 0x1f019f: a pipe's full control
    foreach (PipeAccessRule r in pipe.GetAccessRules(true, false, typeof(SecurityIdentifier))) {
      var s = (SecurityIdentifier)r.IdentityReference;
      Check(s == SvcAcl.Network ? r.AccessControlType == AccessControlType.Deny : SvcPaths.Trusted(s) || s == SvcAcl.Interactive, "pipe ACL holds only SYSTEM, Administrators, INTERACTIVE, NETWORK denied: " + s);
      if (s == SvcAcl.Interactive) Check((r.PipeAccessRights & PipeAccessRights.CreateNewInstance) == 0 && (r.PipeAccessRights & PipeAccessRights.ChangePermissions) == 0 && (r.PipeAccessRights & PipeAccessRights.ReadData) != 0, "interactive user: read/write only");
    }
    Check(SvcAcl.Anon(true).GetSecurityDescriptorSddlForm(AccessControlSections.Access) == "D:P(A;;0x1f019f;;;SY)", "helper pipes: SYSTEM only " + SvcAcl.Anon(true).GetSecurityDescriptorSddlForm(AccessControlSections.Access));
    Console.WriteLine("ACLs: data folder " + dirSddl + "; control pipe " + pipeSddl);
    // 3. paths: refuse to run from a folder a user can change
    string sys = Environment.GetFolderPath(Environment.SpecialFolder.System), pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
    string tmp = Path.Combine(Path.GetTempPath(), "dg-svctest-" + Process.GetCurrentProcess().Id); Directory.CreateDirectory(tmp);
    string fake = Path.Combine(tmp, "DeskGlideService.exe"); File.WriteAllText(fake, "x");
    try {
      Check(SvcPaths.Writable(Path.Combine(sys, "cmd.exe"), 2) == null, "System32\\cmd.exe is admin-only: " + SvcPaths.Writable(Path.Combine(sys, "cmd.exe"), 2));
      Check(SvcPaths.Writable(pf, 1) == null, "Program Files is admin-only: " + SvcPaths.Writable(pf, 1));
      string why = Svc.Check(fake, Path.Combine(tmp, "DeskGlideHelper.exe"));
      Check(why != null, "a service exe in a user's temp folder is refused");
      Console.WriteLine("paths: " + fake + " refused (" + why + ")");
      Check(SvcPaths.Writable(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), 1) != null, "ProgramData itself lets users add folders");
      Check(SvcPaths.Writable(Path.Combine(pf, "no-such-DeskGlide-file.exe"), 2) != null, "a missing file is refused");
      Check(SvcPaths.Writable(ServiceMain.Exe, 2) != null || ServiceMain.Exe.StartsWith(pf, StringComparison.OrdinalIgnoreCase), "this test's own exe (in a user folder) is refused");
      string locked = Path.Combine(tmp, "admin-only"); Directory.CreateDirectory(locked, SvcAcl.AdminDir());
      Check((SvcPaths.Writable(locked, 1) ?? "").Contains("belongs to"), "a folder with the right ACL but a user as owner is still refused: " + SvcPaths.Writable(locked, 1));
      var back = new DirectorySecurity(); back.AddAccessRule(new FileSystemAccessRule(WindowsIdentity.GetCurrent().User, FileSystemRights.FullControl, AccessControlType.Allow)); Directory.SetAccessControl(locked, back);
      // 4. the key: where it lives, DPAPI-protected (as SYSTEM in the service; this user here), nothing readable without it
      Check(SvcStore.Dir.Equals(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), @"DeskGlide\service"), StringComparison.OrdinalIgnoreCase), "key folder " + SvcStore.Dir);
      Check(SvcStore.AppDir.Equals(Path.Combine(pf, "DeskGlide"), StringComparison.OrdinalIgnoreCase) && SvcPipe.Exe.EndsWith(@"\DeskGlide\DeskGlideService.exe"), "program folder " + SvcStore.AppDir);
      Check(SvcStore.KeyFile(SvcStore.Dir) == Path.Combine(SvcStore.Dir, "pairing.key"), "key file");
      Console.WriteLine("key: " + SvcStore.KeyFile(SvcStore.Dir) + " (DPAPI as SYSTEM); programs: " + SvcStore.AppDir);
      var key = Dg.Random(32); SvcStore.SaveKey(tmp, key);
      byte[] disk = File.ReadAllBytes(SvcStore.KeyFile(tmp));
      Check(Dg.Hex(SvcStore.LoadKey(tmp)) == Dg.Hex(key) && !Dg.Hex(disk).Contains(Dg.Hex(key)), "key round trip, not plain on disk");
      File.WriteAllBytes(SvcStore.KeyFile(tmp), ProtectedData.Protect(new byte[32], null, DataProtectionScope.CurrentUser)); Check(SvcStore.LoadKey(tmp) == null, "a blob without the service's entropy is refused");
      File.WriteAllBytes(SvcStore.KeyFile(tmp), key); Check(SvcStore.LoadKey(tmp) == null, "a plain key file is refused");
      SvcStore.DeleteKey(tmp); Check(SvcStore.LoadKey(tmp) == null, "no key, not paired");
      var cfg = new Dictionary<string, string> { { "peer", "192.168.1.20" }, { "enabled", "0" } }; SvcStore.SaveSettings(tmp, cfg);
      Check(SvcStore.LoadSettings(tmp)["peer"] == "192.168.1.20" && SvcStore.LoadSettings(tmp)["enabled"] == "0", "settings round trip");
      // 5. the Ctrl+Alt+Del policy: set, kept once, restored
      string sub = @"Software\DeskGlideTest-" + Process.GetCurrentProcess().Id, bk = Path.Combine(tmp, "sas-previous.txt");
      try {
        var hk = Registry.CurrentUser;
        Check(!SasPolicy.Allowed(hk, sub), "SAS: off at first");
        SasPolicy.Enable(hk, sub, bk); Check(SasPolicy.Allowed(hk, sub) && (int)hk.OpenSubKey(sub).GetValue(SasPolicy.Value) == 1 && File.ReadAllText(bk) == "none", "SAS: absent -> 1, 'none' kept");
        SasPolicy.Enable(hk, sub, bk); Check(File.ReadAllText(bk) == "none", "SAS: turning it on twice keeps the original");
        SasPolicy.Restore(hk, sub, bk); Check(hk.OpenSubKey(sub).GetValue(SasPolicy.Value) == null && !File.Exists(bk), "SAS: restored to absent");
        using (var k = hk.CreateSubKey(sub)) k.SetValue(SasPolicy.Value, 2, RegistryValueKind.DWord);
        SasPolicy.Enable(hk, sub, bk); Check((int)hk.OpenSubKey(sub).GetValue(SasPolicy.Value) == 3, "SAS: Ease of Access (2) kept: 3");
        SasPolicy.Restore(hk, sub, bk); Check((int)hk.OpenSubKey(sub).GetValue(SasPolicy.Value) == 2, "SAS: restored to 2");
        SasPolicy.Restore(hk, sub, bk); Check((int)hk.OpenSubKey(sub).GetValue(SasPolicy.Value) == 2, "SAS: restore without a backup changes nothing");
        Check(SasPolicy.On(null) == 1 && SasPolicy.On(0) == 1 && SasPolicy.On(1) == 1 && SasPolicy.On(3) == 3, "SAS: values");
      } finally { Registry.CurrentUser.DeleteSubKeyTree(sub, false); }
      Console.WriteLine("SAS policy: set, kept once, restored (tested on HKCU\\" + sub + ")");
    } finally { try { Directory.Delete(tmp, true); } catch { } }
    // 6. the helper's frames
    var ms = new MemoryStream(); byte t; byte[] p;
    foreach (var f in new[] { HelperProto.Ints((byte)'K', 0x41, 0x1E, 0x8), HelperProto.Ints((byte)'M', 100, -20, 0, 0xC001), HelperProto.Frame((byte)'L', new byte[0]) }) ms.Write(f, 0, f.Length);
    ms.Position = 0;
    Check(HelperProto.Read(ms, out t, out p) && t == 'K' && HelperProto.Valid(t, p) && HelperProto.ToInts(p)[1] == 0x1E, "frame: key");
    Check(HelperProto.Read(ms, out t, out p) && t == 'M' && HelperProto.Valid(t, p) && HelperProto.ToInts(p)[1] == -20, "frame: mouse, negative coordinates");
    Check(HelperProto.Read(ms, out t, out p) && t == 'L' && HelperProto.Valid(t, p), "frame: lock");
    Check(!HelperProto.Read(ms, out t, out p), "frame: end of stream");
    Check(!HelperProto.Valid((byte)'K', HelperProto.ToBytes(0x41, 0x1E, 0x4)), "frame: KEYEVENTF_UNICODE refused");
    Check(!HelperProto.Valid((byte)'K', HelperProto.ToBytes(0x141, 0x1E, 0)), "frame: vk out of range refused");
    Check(!HelperProto.Valid((byte)'M', HelperProto.ToBytes(0, 0, 0, 0x2000)), "frame: unknown mouse flag (MOVE_NOCOALESCE) refused");
    Check(!HelperProto.Valid((byte)'K', new byte[8]) && !HelperProto.Valid((byte)'X', new byte[0]) && !HelperProto.Valid((byte)'L', new byte[1]), "frame: wrong size or type refused");
    bool threw = false; try { HelperProto.Read(new MemoryStream(new byte[] { (byte)'K', 0xFF, 0xFF }), out t, out p); } catch (IOException) { threw = true; }
    Check(threw, "frame: longer than 1 KB refused");
    threw = false; try { HelperProto.Read(new MemoryStream(new byte[] { (byte)'K', 12, 0, 1, 2 }), out t, out p); } catch (IOException) { threw = true; }
    Check(threw, "frame: cut short refused");
    threw = false; try { HelperProto.Frame((byte)'G', new byte[2000]); } catch (ArgumentException) { threw = true; } Check(threw, "frame: too long to send");
    var mon = HelperProto.Monitors(HelperProto.ToBytes(0, 0, 1920, 1080, 96, 1920, 0, 4480, 1440, 144));
    Check(mon != null && mon.Length == 2 && mon[1].R == 4480 && mon[1].Dpi == 144, "frame: monitors");
    Check(HelperProto.Monitors(HelperProto.ToBytes(0, 0, 0, 1080, 96)) == null && HelperProto.Monitors(new byte[7]) == null, "frame: bad monitors refused");
    Check(HelperMain.Norm(1919, 0, 1920) == Geo.Norm(1919, 0, 1920) && HelperMain.Norm(0, -1920, 3840) == Geo.Norm(0, -1920, 3840), "helper: absolute coordinates as Link's");
    Console.WriteLine("helper frames: key, mouse, lock, limits, monitors");
    // 7. pairing: both sides get the same key and number; a program in the middle gets other keys
    using (SvcPair b = new SvcPair(), a = new SvcPair(), m = new SvcPair()) {
      string cb, ca, cm1, cm2;
      byte[] kb = b.Finish(b.Pub, a.Pub, a.Pub, out cb), ka = a.Finish(b.Pub, a.Pub, b.Pub, out ca);
      Check(kb != null && Dg.Hex(kb) == Dg.Hex(ka) && cb == ca && System.Text.RegularExpressions.Regex.IsMatch(cb, @"^\d{3} \d{3}$"), "pairing: same key and number " + cb);
      byte[] k1 = b.Finish(b.Pub, m.Pub, m.Pub, out cm1), k2 = a.Finish(m.Pub, a.Pub, m.Pub, out cm2);
      Check(Dg.Hex(k1) != Dg.Hex(k2) && Dg.Hex(k1) != Dg.Hex(kb), "pairing: a program in the middle ends up with other keys");
      Check(b.Finish(b.Pub, a.Pub, new byte[72], out cm1) == null && b.Finish(b.Pub, a.Pub, new byte[5], out cm1) == null, "pairing: a bad public key refused");
      Check(Dg.Hex(SvcPair.Proof(kb, "x")) == Dg.Hex(SvcPair.Proof(ka, "x")) && Dg.Hex(SvcPair.Proof(kb, "x")) != Dg.Hex(SvcPair.Proof(k1, "x")), "pairing: proof");
      Console.WriteLine("pairing: both PCs show " + cb + "; with a program in the middle each side gets another key");
    }
    Console.WriteLine("service self-test ok (" + n + " checks)");
    return 0;
  }
}
