# DeskGlide: switches a shared monitor's input whenever Synergy / Deskflow moves the cursor between computers.
#
# Run it on the SERVER (the computer whose keyboard and mouse are shared). It watches the
# Synergy or Deskflow log for lines like
#   switch from "pc-a" to "pc-b" at 2559,478
# and sends the DDC/CI command VCP 0x60 (Input Select) to the monitor.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File deskglide.ps1 -Show                # list monitor inputs
#   powershell -ExecutionPolicy Bypass -File deskglide.ps1 -MyInput 15 -OtherInput 17
#   powershell -ExecutionPolicy Bypass -File deskglide.ps1 -Log C:\path\deskflow.log
#   powershell -ExecutionPolicy Bypass -File deskglide.ps1 -DryRun              # print only
#   powershell -ExecutionPolicy Bypass -File deskglide.ps1 -Test                # parser self-check
param(
  [string]$Me         = $env:COMPUTERNAME,  # this computer's screen name in Synergy/Deskflow (case-insensitive)
  [int]   $MyInput    = 15,   # input this computer uses. Common: 15=DisplayPort 1, 16=DP 2, 17=HDMI 1, 18=HDMI 2
  [int]   $OtherInput = 17,   # input the other computer uses
  [int]   $SettleMs   = 400,  # wait this long after the last switch so edge bounces don't flicker the monitor
  [string]$Log        = "$env:LOCALAPPDATA\synergy-dragon\logs\synergy-dragon-agent.log",  # Synergy 3 default
  [switch]$Show,
  [switch]$DryRun,
  [switch]$Test
)

# Returns the input for the last switch in $text, or $null if there is none.
function Get-Target([string]$text) {
  $m = [regex]::Matches($text, 'switch from "[^"]+" to "([^"]+)"')
  if ($m.Count -eq 0) { return $null }
  if ($m[$m.Count - 1].Groups[1].Value -eq $Me) { $MyInput } else { $OtherInput }
}

if ($Test) {
  $Me = 'pc-a'
  $a = '[t] - INFO - x - [core] switch from "pc-a" to "pc-b" at 2559,478 - {}'   # Synergy 3
  $b = '[2026-01-01T12:00:00] INFO: switch from "pc-b" to "PC-A" at 1,491'        # Deskflow
  if ((Get-Target $a) -ne $OtherInput)    { throw 'to other failed' }
  if ((Get-Target $b) -ne $MyInput)       { throw 'to me failed (name must be case-insensitive)' }
  if ((Get-Target "$a`n$b") -ne $MyInput) { throw 'last line must win' }
  if ($null -ne (Get-Target '[core] entering screen')) { throw 'noise matched' }
  'self-check ok'; return
}

Add-Type @"
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public class Ddc {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct PM { public IntPtr h; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string d; }
  delegate bool MEP(IntPtr hm, IntPtr dc, IntPtr r, IntPtr p);
  [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MEP cb, IntPtr p);
  [DllImport("dxva2.dll")] static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hm, out uint n);
  [DllImport("dxva2.dll")] static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hm, uint n, [Out] PM[] a);
  [DllImport("dxva2.dll")] static extern bool DestroyPhysicalMonitors(uint n, PM[] a);
  [DllImport("dxva2.dll")] static extern bool SetVCPFeature(IntPtr h, byte code, uint value);
  [DllImport("dxva2.dll")] static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte code, IntPtr t, out uint cur, out uint max);
  [DllImport("dxva2.dll")] static extern bool GetCapabilitiesStringLength(IntPtr h, out uint n);
  [DllImport("dxva2.dll")] static extern bool CapabilitiesRequestAndCapabilitiesReply(IntPtr h, StringBuilder s, uint n);

  static void Each(Action<PM> f) {
    EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (hm, dc, r, p) => {
      uint n; if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hm, out n) || n == 0) return true;
      var a = new PM[n]; if (!GetPhysicalMonitorsFromHMONITOR(hm, n, a)) return true;
      foreach (var m in a) f(m);
      DestroyPhysicalMonitors(n, a); return true;
    }, IntPtr.Zero);
  }
  // ponytail: sends to every DDC monitor; fine for one shared monitor, filter by name if you have more
  public static bool SetInput(uint v) { bool ok = false; Each(m => ok |= SetVCPFeature(m.h, 0x60, v)); return ok; }
  public static List<string> Describe() {
    var o = new List<string>();
    Each(m => {
      uint cur, max, len; string caps = "";
      bool ok = GetVCPFeatureAndVCPFeatureReply(m.h, 0x60, IntPtr.Zero, out cur, out max);
      if (GetCapabilitiesStringLength(m.h, out len)) { var sb = new StringBuilder((int)len); if (CapabilitiesRequestAndCapabilitiesReply(m.h, sb, len)) caps = sb.ToString(); }
      o.Add(m.d + "|" + (ok ? cur.ToString() : "") + "|" + caps);
    });
    return o;
  }
}
"@

if ($Show) {
  foreach ($line in [Ddc]::Describe()) {
    $name, $cur, $caps = $line -split '\|', 3
    if (-not $cur) { "$name : no DDC/CI reply (turn on DDC/CI in the monitor's menu)"; continue }
    $list = if ($caps -match '\b60\(\s*([0-9A-Fa-f ]+)\)') { ($Matches[1].Trim() -split '\s+' | % { [Convert]::ToInt32($_, 16) }) -join ', ' } else { 'unknown' }
    "$name : current input = $cur   supported inputs = $list"
  }
  "Use the current input as -MyInput, and one of the others as -OtherInput."
  return
}

if (-not (Test-Path $Log)) { throw "Log not found: $Log  (pass -Log <path to your Synergy/Deskflow log>)" }
"Watching $Log  (me=$Me input $MyInput, other input $OtherInput)$(if($DryRun){'  [dry run]'})"

$pos = (Get-Item $Log).Length   # start at the end, ignore old history
$want = $null; $since = Get-Date; $applied = $null
while ($true) {
  $len = (Get-Item $Log).Length
  if ($len -lt $pos) { $pos = 0 }   # log rotated/truncated
  if ($len -gt $pos) {
    $fs = [IO.File]::Open($Log, 'Open', 'Read', 'ReadWrite,Delete')
    try {
      $fs.Position = $pos
      $buf = New-Object byte[] ($len - $pos)
      $read = $fs.Read($buf, 0, $buf.Length)
    } finally { $fs.Close() }
    $end = [Array]::LastIndexOf($buf, [byte]10, $read - 1)   # only consume whole lines
    if ($end -ge 0) {
      $pos += $end + 1
      $t = Get-Target ([Text.Encoding]::UTF8.GetString($buf, 0, $end + 1))
      if ($null -ne $t) { $want = $t; $since = Get-Date }
    }
  }
  if ($null -ne $want -and $want -ne $applied -and ((Get-Date) - $since).TotalMilliseconds -ge $SettleMs) {
    $ok = if ($DryRun) { $true } else { [Ddc]::SetInput([uint32]$want) }
    "{0:HH:mm:ss} input -> {1} {2}" -f (Get-Date), $want, $(if ($ok) { 'ok' } else { 'FAILED' })
    $applied = $want   # ponytail: no retry on failure; the next screen switch tries again
  }
  Start-Sleep -Milliseconds 100
}
