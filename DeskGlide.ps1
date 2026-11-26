# DeskGlide: two PCs, one monitor, one keyboard and mouse (Synergy / Deskflow), one pair of headphones.
# The same files run on both PCs as a tray app with a window. Install.cmd adds it to Startup, Uninstall.cmd removes it.
#   -Test        self-check of the pure logic (no network, no monitor, no audio)
#   -Console     output to this console instead of the tray, for debugging
#   -ShowWindow  open the DeskGlide window right away
param(
  [switch]$Console, [switch]$Test, [switch]$Install, [switch]$Uninstall, [switch]$ShowWindow,
  # hidden, for debugging and for running two copies on one PC:
  [switch]$DryRun,                        # never send a DDC command, only print it
  [string]$PairCode,                      # pair at startup without the window
  [int]$Port = 6991, [int]$PeerPort = 0,  # control/discovery UDP port to listen on / to send to
  [int]$AudioPort = 6990,
  [string]$ConfigDir = "$env:APPDATA\DeskGlide",
  [string]$Name = $env:COMPUTERNAME,
  [switch]$NoBroadcast,                   # find the peer by address only
  [string]$Theme,                         # 'light' or 'dark' instead of the Windows setting
  [string]$Shot                           # save a screenshot of the window to this .png, then quit
)
$ErrorActionPreference = 'Stop'
$Version = '3.0'
if (-not $PeerPort) { $PeerPort = $Port }
Add-Type -Path "$PSScriptRoot\DeskGlide.cs" -ReferencedAssemblies System.Drawing
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, PresentationFramework, PresentationCore, WindowsBase, WindowsFormsIntegration
$cfgPath   = Join-Path $ConfigDir 'config.json'
$mutedPath = Join-Path $ConfigDir 'muted.txt'   # apps we muted, so a crash or kill doesn't leave them muted
$logPath   = Join-Path $ConfigDir 'deskglide.log'
$icoPath   = Join-Path $PSScriptRoot 'DeskGlide.ico'
$lnk       = Join-Path ([Environment]::GetFolderPath('Startup')) 'DeskGlide.lnk'
$argLine   = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
$opp       = @{ left = 'right'; right = 'left'; up = 'down'; down = 'up' }

function Now-Ms { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
function Load-Config {
  $c = @{ peer = ''; key = ''; peerAddress = ''; input = 0; inputOverride = 0; monitor = $true; audio = 'follow'; hp = ''; vol = 100
          paused = $false; syncAt = 0; synergyLog = ''; screenName = ''; onSwitch = ''; layout = $null }
  if (Test-Path $cfgPath) { (Get-Content $cfgPath -Raw | ConvertFrom-Json).psobject.Properties | % { $c[$_.Name] = $_.Value } }
  if ($c.Contains('headphones')) {   # DeskGlide 2 had a per-PC flag; now it's one shared value: the name of the PC with the headphones
    if ($c.headphones -and -not $c.hp) { $c.hp = $Name; $c.syncAt = Now-Ms }   # newest, so the other PC takes it instead of clearing it
    $c.Remove('headphones')
  }
  $c
}
function Save-Config { [void](New-Item -ItemType Directory -Force $ConfigDir); $C | ConvertTo-Json | Set-Content $cfgPath -Encoding UTF8 }

# Screen name in the last Synergy/Deskflow 'switch from "A" to "B"' line, or $null.
function Get-Target([string]$text) {
  $m = [regex]::Matches($text, 'switch from "[^"]+" to "([^"]+)"')
  if ($m.Count) { $m[$m.Count - 1].Groups[1].Value }
}
# Reads whole lines from byte $from to the end of the log. Returns text, new position.
function Read-Lines([string]$path, [long]$from) {
  $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite,Delete')
  try {
    if ($fs.Length -lt $from) { $from = 0 }   # log rotated
    $fs.Position = $from; $b = New-Object byte[] ($fs.Length - $from); $n = $fs.Read($b, 0, $b.Length)
  } finally { $fs.Close() }
  $end = if ($n) { [Array]::LastIndexOf($b, [byte]10, $n - 1) } else { -1 }
  if ($end -lt 0) { return '', $from }
  [Text.Encoding]::UTF8.GetString($b, 0, $end + 1), ($from + $end + 1)
}

# 'section: links' of a Synergy/Deskflow server config -> { from, dir, to } objects. Everything else is ignored.
function Parse-Links([string]$text) {
  $in = $false; $from = ''
  foreach ($line in $text -split "`r?`n") {
    $l = $line.Trim()
    if ($l -match '^section:\s*links$') { $in = $true; continue }
    if (-not $in) { continue }
    if ($l -eq 'end') { $in = $false; continue }
    if ($l -match '^([^\s=:]+):$') { $from = $matches[1]; continue }
    if ($from -and $l -match '^(left|right|up|down)(\([^)]*\))?\s*=\s*([^\s(]+)') { [pscustomobject]@{ from = $from; dir = $matches[1].ToLower(); to = $matches[3] } }
  }
}
# Where the other screen is next to $me: @{ other; dir }, dir = the edge of $me that leads to it. $null if no link.
function Layout-Of($links, [string]$me) {
  foreach ($l in $links) { if ($l.from -eq $me) { return @{ other = $l.to; dir = $l.dir } } }
  foreach ($l in $links) { if ($l.to -eq $me) { return @{ other = $l.from; dir = $opp[$l.dir] } } }
}
# DeskGlide's own layout, stored as { "<PC name>": "<side of the other PC it is on>" } and the same on both PCs.
# Returns it as seen from $me: @{ other; dir }, or $null if none is stored.
function Layout-Stored($layout, [string]$me, [string]$peer) {
  if (-not $layout -or -not $peer) { return }
  $d = $layout.$peer; if ($d -and $opp[$d]) { return @{ other = $peer; dir = $d } }
  $d = $layout.$me; if ($d -and $opp[$d]) { return @{ other = $peer; dir = $opp[$d] } }
}

function Input-Name([int]$v) {
  switch ($v) { 0 { 'not learned yet' } 15 { 'DisplayPort' } 16 { 'DisplayPort 2' } 17 { 'HDMI 1' } 18 { 'HDMI 2' } default { "input $v" } }
}
# An address typed by the user: IPv4 or a computer name, trimmed. '' clears it, $null = not an address.
function Parse-Address([string]$text) {
  $t = ($text -replace '\(.*\)', '').Trim()   # "100.101.5.7 (Tailscale)" as copied from the other PC
  if (-not $t) { return '' }
  if ($t -match '^[\d.]+$') { $ip = $null; if ($t -match '^\d{1,3}(\.\d{1,3}){3}$' -and [Net.IPAddress]::TryParse($t, [ref]$ip)) { return $t }; return $null }
  if ($t.Length -le 253 -and $t -match '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$') { return $t }
  $null
}
# Friendly name of a network adapter, or $null to leave it out (virtual adapters nobody pairs over)
function Adapter-Label([string]$name, [string]$desc, [string]$type) {
  $all = "$name $desc"
  if ($all -match 'Tailscale') { return 'Tailscale' }
  if ($all -match 'ZeroTier') { return 'ZeroTier' }
  if ($type -eq 'Loopback' -or $all -match 'VirtualBox|Hyper-V|VMware|WSL|vEthernet|Virtual|Loopback|Bluetooth|Npcap') { return $null }
  if ($type -eq 'Wireless80211') { return 'Wi-Fi' }
  if ($type -match 'Ethernet') { return 'Ethernet' }
  $name
}
function My-Addresses {
  foreach ($ni in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
    if ($ni.OperationalStatus -ne 'Up') { continue }
    $label = Adapter-Label $ni.Name $ni.Description "$($ni.NetworkInterfaceType)"
    if (-not $label) { continue }
    foreach ($u in $ni.GetIPProperties().UnicastAddresses) { if ($u.Address.AddressFamily -eq 'InterNetwork') { "$($u.Address) ($label)" } }
  }
}

# Newest settings win on both PCs. Returns $true if the message's settings were taken.
function Merge-Settings($cfg, $m) {
  $took = $false
  if ($m.ly -and -not $cfg.layout) { $cfg.layout = $m.ly; $took = $true }   # the first layout either PC sets
  if ([long]$m.st -le [long]$cfg.syncAt) { return $took }
  $cfg.monitor = [bool]$m.m; $cfg.audio = [string]$m.am; $cfg.paused = [bool]$m.p; $cfg.syncAt = [long]$m.st
  if ($null -ne $m.hp) { $cfg.hp = [string]$m.hp }   # a DeskGlide 2 peer doesn't send it: keep ours, never clear it
  if ($null -ne $m.v) { $cfg.vol = [int]$m.v }
  if ($m.ly) { $cfg.layout = $m.ly }
  $true
}
# h is for DeskGlide 2 peers (it had a per-PC headphones flag); ly is DeskGlide's layout; l is Synergy's, from the server
function State-Json($cfg) {
  @{ n = $Name; t = $S.t; s = $S.server; sa = ($S.active -eq 'me'); i = (My-Input); h = ($cfg.hp -eq $Name)
     m = $cfg.monitor; am = $cfg.audio; p = $cfg.paused; st = $cfg.syncAt; hp = $cfg.hp; v = $cfg.vol; ly = $cfg.layout
     l = @($(if ($S.server) { $S.links | % { "$($_.from) $($_.dir) $($_.to)" } })) } | ConvertTo-Json -Compress
}
# Why sound is or isn't playing, in plain words.
function Audio-Status($cfg, [bool]$paired, [bool]$online, [string]$active) {
  $peer = $cfg.peer
  if (-not $paired) { return 'Off: pair with your other PC first.' }
  if ($cfg.paused) { return 'Off while DeskGlide is paused.' }
  if ($cfg.audio -eq 'off') { return 'Off. Choose Follow mouse or Hear both to hear the other PC.' }
  $here = $cfg.hp -eq $Name; $there = $cfg.hp -and $cfg.hp -eq $peer
  if (-not $here -and -not $there) { return 'Off: choose which PC your headphones are plugged into.' }
  if (-not $online) { return "Off: waiting for $peer to connect." }
  if ($here) {
    if ($cfg.audio -eq 'both') { return "You hear this PC and $peer together." }
    if ($active -eq 'peer') { return "You hear $peer. This PC's apps are muted until the mouse comes back." }
    return "You hear this PC. $peer plays when the mouse moves to it."
  }
  if ($cfg.audio -eq 'both') { return "This PC's sound plays in the headphones on $peer." }
  "This PC's sound plays in the headphones on $peer while the mouse is here."
}

$S = @{ key = $null; server = $false; log = ''; pos = 0; screen = ''; active = $null; activeName = ''; want = $null; wantName = ''
        since = [DateTime]::MinValue; activeSince = Get-Date; inputOk = $false; readAt = [DateTime]::MinValue
        peerAddr = $null; peerSeen = [DateTime]::MinValue; peerInput = 0; peerLinks = @(); lastT = 0; t = [long]0
        lastSend = [DateTime]::MinValue; roleAt = Get-Date; n = 0; okCtl = 0; badCtl = 0; statAt = Get-Date
        lastErr = ''; lastErrAt = [DateTime]::MinValue; savedMuted = ''; told = @{}
        fixedIp = $null; fixedSeen = [DateTime]::MinValue; verify = $null; monMsg = ''; monErr = $false
        links = @(); confPath = ''; confTime = $null; layDir = ''; drag = $null
        code = ''; myAddrs = ''; pairStart = Get-Date; pairErr = ''; addrErr = ''; unpairAt = $null; volAt = $null
        wiz = 0; wizDone = $false; iconState = 3; dark = $null; shownAt = $null }
$tray = $null; $win = $null; $ui = @{}; $icons = @(); $logos = @()

function My-Input { if ($C.inputOverride) { [int]$C.inputOverride } else { [int]$C.input } }

if ($Test) {
  function Check($ok, $what) { if (-not $ok) { throw "self-check FAILED: $what" } }
  $a = '[t] - INFO - x - [core] switch from "pc-a" to "pc-b" at 2559,478 - {}'   # Synergy 3
  $b = '[2026-01-01T12:00:00] INFO: switch from "pc-b" to "PC-A" at 1,491'        # Deskflow
  Check ((Get-Target $a) -eq 'pc-b') 'Synergy line'
  Check ((Get-Target "$a`n$b") -eq 'pc-a') 'last line wins, names case-insensitive'
  Check ($null -eq (Get-Target '[core] entering screen')) 'noise matched'
  $f = [IO.Path]::GetTempFileName(); [IO.File]::WriteAllText($f, "$a`n$b`npartial")
  $text, $pos = Read-Lines $f 0
  Check ((Get-Target $text) -eq 'pc-a' -and $pos -eq $a.Length + $b.Length + 2) 'Read-Lines keeps the partial last line'
  Remove-Item $f

  $code = [Dg]::NewCode(); Check ($code -match '^[A-Z2-9]{4}-[A-Z2-9]{4}$') "code format $code"
  $k = [Dg]::DeriveKey('abcd-efgh'); $k2 = [Dg]::DeriveKey('ABCD EFGJ')
  Check ($k.Length -eq 32 -and [Convert]::ToBase64String($k) -eq [Convert]::ToBase64String([Dg]::DeriveKey('ABCDEFGH'))) 'key ignores case and dashes'
  Check ([Convert]::ToBase64String($k) -ne [Convert]::ToBase64String($k2)) 'different codes, different keys'
  $p = [Dg]::Seal($k, '{"n":"x","t":1}')
  Check ([Dg]::Open($k, $p) -eq '{"n":"x","t":1}') 'control message round trip'
  Check ($null -eq [Dg]::Open($k2, $p)) 'control message with wrong key accepted'
  Check ($null -eq [Dg]::Open($k, $p.Replace('"t":1', '"t":2'))) 'tampered control message accepted'
  Check ($null -eq [Dg]::Open($k, 'garbage')) 'garbage accepted'

  $r = 0; $ch = 0
  function Pkt($key, [int]$rate, [int]$chans, [int]$bytes) { [Dg]::MakePacket($key, $rate, $chans, 7, (New-Object byte[] ([Math]::Max($bytes, 1))), $bytes) }
  Check ([Dg]::ValidPacket($k, (Pkt $k 48000 2 1152), [ref]$r, [ref]$ch) -and $r -eq 48000 -and $ch -eq 2) 'valid stereo packet rejected'
  Check ([Dg]::ValidPacket($k, (Pkt $k 44100 1 2), [ref]$r, [ref]$ch)) 'valid mono packet rejected'
  $bad = Pkt $k 48000 2 1152; $bad[100] = 1
  Check (-not [Dg]::ValidPacket($k, $bad, [ref]$r, [ref]$ch)) 'tampered audio accepted'
  Check (-not [Dg]::ValidPacket($k2, (Pkt $k 48000 2 1152), [ref]$r, [ref]$ch)) 'audio with wrong key accepted'
  Check (-not [Dg]::ValidPacket($k, (Pkt $k 48000 2 3), [ref]$r, [ref]$ch)) 'odd length accepted'
  Check (-not [Dg]::ValidPacket($k, (Pkt $k 48000 6 12), [ref]$r, [ref]$ch)) '6 channels accepted'
  Check (-not [Dg]::ValidPacket($k, (Pkt $k 1 2 4), [ref]$r, [ref]$ch)) 'bad sample rate accepted'
  Check (-not [Dg]::ValidPacket($k, [byte[]](1, 2, 3), [ref]$r, [ref]$ch)) 'short packet accepted'
  Check ([Dg]::ToPcm16(2.0) -eq 32767 -and [Dg]::ToPcm16(-2.0) -eq -32768 -and [Dg]::ToPcm16(0) -eq 0) 'clipping'

  # volume: the receiver scales samples, the 8-byte header is untouched
  $pcm = New-Object byte[] 12; $pcm[0] = 9; $vals = 1000, -1000, 32767, -32768
  for ($i = 0; $i -lt 4; $i++) { [BitConverter]::GetBytes([int16]$vals[$i]).CopyTo($pcm, 4 + 2 * $i) }
  function Samples($buf) { (0..3 | % { [BitConverter]::ToInt16($buf, 4 + 2 * $_) }) -join ',' }
  $v = [byte[]]$pcm.Clone(); [Dg]::Scale($v, 4, 8, 0.5); Check ((Samples $v) -eq '500,-500,16383,-16384' -and $v[0] -eq 9) 'volume 50%'
  $v = [byte[]]$pcm.Clone(); [Dg]::Scale($v, 4, 8, 1);   Check ((Samples $v) -eq '1000,-1000,32767,-32768') 'volume 100% changed samples'
  $v = [byte[]]$pcm.Clone(); [Dg]::Scale($v, 4, 8, 0);   Check ((Samples $v) -eq '0,0,0,0') 'volume 0%'

  Check ((Input-Name 15) -eq 'DisplayPort' -and (Input-Name 17) -eq 'HDMI 1' -and (Input-Name 18) -eq 'HDMI 2' -and (Input-Name 3) -eq 'input 3') 'input names'

  # headphones owner: one shared value, newest wins, an echo or an older message never clears it
  function Msg($cfg, $n) { $C = $cfg; $Name = $n; State-Json $cfg | ConvertFrom-Json }
  $PA = @{ peer = 'PC-B'; hp = ''; monitor = $true; audio = 'follow'; paused = $false; vol = 100; syncAt = 5; input = 15; inputOverride = 0 }
  $PB = @{ peer = 'PC-A'; hp = ''; monitor = $true; audio = 'follow'; paused = $false; vol = 100; syncAt = 5; input = 17; inputOverride = 0 }
  $PA.hp = 'PC-A'; $PA.vol = 60; $PA.syncAt = 10   # picked "headphones on PC-A" on PC-A
  Check ((Merge-Settings $PB (Msg $PA 'PC-A')) -and $PB.hp -eq 'PC-A' -and $PB.vol -eq 60) 'owner and volume not synced'
  Check (-not (Merge-Settings $PA (Msg $PB 'PC-B')) -and $PA.hp -eq 'PC-A') 'echo from the other PC changed the owner'
  $PB.hp = 'PC-B'; $PB.syncAt = 20                 # then picked "PC-B" on PC-B
  Check ((Merge-Settings $PA (Msg $PB 'PC-B')) -and $PA.hp -eq 'PC-B') 'change on the other PC not synced'
  $old = Msg $PA 'PC-A'; $old.st = 30; $old.m = $false; $old.psobject.Properties.Remove('hp')   # a DeskGlide 2 message
  Check ((Merge-Settings $PB $old) -and $PB.hp -eq 'PC-B' -and -not $PB.monitor) 'DeskGlide 2 message cleared the owner'
  $stale = Msg $PB 'PC-B'; $stale.hp = ''; $stale.st = 1
  Check (-not (Merge-Settings $PA $stale) -and $PA.hp -eq 'PC-B') 'older message overwrote the owner'
  Check ((Msg $PA 'PC-B').h -eq $true -and (Msg $PA 'PC-A').h -eq $false) 'h flag for DeskGlide 2 peers'

  $Name = 'PC-A'; $q = @{ peer = 'PC-B'; hp = ''; audio = 'follow'; paused = $false }
  Check ((Audio-Status $q $false $false 'me') -match 'pair') 'reason: not paired'
  Check ((Audio-Status $q $true $true 'me') -match 'headphones are plugged') 'reason: no headphones PC'
  $q.hp = 'PC-A'; Check ((Audio-Status $q $true $false 'me') -match 'waiting for PC-B') 'reason: offline'
  Check ((Audio-Status $q $true $true 'peer') -match '^You hear PC-B') 'status: playing the other PC'
  $q.hp = 'PC-B'; Check ((Audio-Status $q $true $true 'me') -match 'headphones on PC-B') 'status: sending'
  $q.audio = 'off'; Check ((Audio-Status $q $true $true 'me') -match '^Off\.') 'reason: audio off'
  $q.paused = $true; Check ((Audio-Status $q $true $true 'me') -match 'paused') 'reason: paused'

  Check ((Parse-Address ' 192.168.1.20 ') -eq '192.168.1.20' -and (Parse-Address '100.101.5.7 (Tailscale)') -eq '100.101.5.7') 'address: IPv4'
  Check ((Parse-Address 'LAPTOP') -eq 'LAPTOP' -and (Parse-Address 'pc.tail1234.ts.net') -eq 'pc.tail1234.ts.net') 'address: names'
  Check ((Parse-Address '') -eq '' -and $null -eq (Parse-Address '999.1.1.1') -and $null -eq (Parse-Address '1.2.3') -and $null -eq (Parse-Address 'my pc') -and $null -eq (Parse-Address '-x')) 'address: rejects'
  Check ((Adapter-Label 'Ethernet' 'Intel(R) Ethernet I219-V' 'Ethernet') -eq 'Ethernet' -and (Adapter-Label 'Wi-Fi' 'Intel Wi-Fi 6 AX201' 'Wireless80211') -eq 'Wi-Fi') 'label: real adapters'
  Check ((Adapter-Label 'Tailscale' 'Tailscale Tunnel' 'Unknown') -eq 'Tailscale' -and (Adapter-Label 'ZeroTier One [abc]' 'ZeroTier Virtual Port' 'Ethernet') -eq 'ZeroTier') 'label: VPNs'
  Check ($null -eq (Adapter-Label 'Ethernet 2' 'VirtualBox Host-Only Ethernet Adapter' 'Ethernet') -and $null -eq (Adapter-Label 'vEthernet (WSL)' 'Hyper-V Virtual Ethernet Adapter' 'Ethernet') -and $null -eq (Adapter-Label 'Loopback Pseudo-Interface 1' '' 'Loopback')) 'label: virtual adapters hidden'

  $conf = "section: screens`n`tlaptop:`n`t`tswitchCorners = none`n`tdesk-pc:`n`t`tswitchCorners = none`nend`nsection: links`n`tlaptop:`n`t`tright = desk-pc`n`tdesk-pc:`n`t`tleft = laptop`nend`nsection: options`n`theartbeat = 5000`nend`n"
  $links = @(Parse-Links $conf)
  Check ($links.Count -eq 2 -and $links[1].from -eq 'desk-pc' -and $links[1].dir -eq 'left' -and $links[1].to -eq 'laptop') 'links: Synergy 3 sample'
  $lay = Layout-Of $links 'DESK-PC'; Check ($lay.other -eq 'laptop' -and $lay.dir -eq 'left') 'layout seen from the server'
  $lay = Layout-Of @($links[1]) 'LAPTOP'; Check ($lay.other -eq 'desk-pc' -and $lay.dir -eq 'right') 'layout from the reverse link'
  $links = @(Parse-Links "section: links`n  top:`n    down(0,100) = bottom(0,100)`n  bottom:`n    UP = top`n    sideways = x`n  garbage line`n= = =`nend`nsection: options`n  left = nope`nend")
  Check ($links.Count -eq 2 -and $links[0].dir -eq 'down' -and $links[0].to -eq 'bottom' -and $links[1].dir -eq 'up') 'links: up/down, ranges and garbage'
  Check ((@(Parse-Links 'random text')).Count -eq 0) 'links: no section'

  # DeskGlide's own layout: one value, read from either PC's side, synced newest-wins
  $ly = '{"LAPTOP":"left"}' | ConvertFrom-Json   # as loaded from config.json
  $lay = Layout-Stored $ly 'DESK-PC' 'LAPTOP'; Check ($lay.other -eq 'LAPTOP' -and $lay.dir -eq 'left') 'stored layout on DESK-PC'
  $lay = Layout-Stored $ly 'LAPTOP' 'DESK-PC'; Check ($lay.other -eq 'DESK-PC' -and $lay.dir -eq 'right') 'stored layout on the other PC'
  Check ($null -eq (Layout-Stored $null 'DESK-PC' 'X') -and $null -eq (Layout-Stored $ly 'DESK-PC' '') -and $null -eq (Layout-Stored ('{"X":"sideways"}' | ConvertFrom-Json) 'DESK-PC' 'X')) 'no or bad stored layout'
  $PA = @{ peer = 'PC-B'; hp = ''; monitor = $true; audio = 'follow'; paused = $false; vol = 100; syncAt = 5; input = 15; inputOverride = 0; layout = $null }
  $PB = $PA.Clone(); $PB.peer = 'PC-A'
  $PA.layout = @{ 'PC-B' = 'up' }; $PA.syncAt = 9
  Check ((Merge-Settings $PB (Msg $PA 'PC-A')) -and (Layout-Stored $PB.layout 'PC-B' 'PC-A').dir -eq 'down') 'layout not synced'
  $PB.layout = $null; $PB.syncAt = 99
  Check ((Merge-Settings $PB (Msg $PA 'PC-A')) -and $PB.layout) 'first layout not taken from an older message'

  $bmp = [Dg]::DrawIcon(16, 1); Check ($bmp.GetPixel(4, 7).R -lt 60 -and $bmp.GetPixel(11, 7).R -gt 100) 'icon: this PC half highlighted'
  $bmp = [Dg]::DrawIcon(16, 2); Check ($bmp.GetPixel(4, 7).R -gt 100 -and $bmp.GetPixel(11, 7).R -lt 60) 'icon: other PC half highlighted'

  $Name = 'PC-A'; $ConfigDir = Join-Path $env:TEMP "deskglide-test-$PID"; $cfgPath = Join-Path $ConfigDir 'config.json'
  [void](New-Item -ItemType Directory -Force $ConfigDir)
  Set-Content $cfgPath '{"peer":"PC-B","key":"a2V5","input":15,"headphones":true,"syncAt":5,"audio":"both"}'
  $C = Load-Config
  Check ($C.hp -eq 'PC-A' -and $C.syncAt -gt 5 -and -not $C.Contains('headphones') -and $C.key -eq 'a2V5' -and $C.peer -eq 'PC-B' -and $C.audio -eq 'both' -and $C.vol -eq 100) 'upgrade from DeskGlide 2 (headphones here)'
  Set-Content $cfgPath '{"peer":"PC-B","key":"a2V5","headphones":false,"syncAt":5}'
  $C = Load-Config; Check ($C.hp -eq '' -and $C.syncAt -eq 5 -and $C.key -eq 'a2V5') 'upgrade from DeskGlide 2 (headphones elsewhere)'
  $C = Load-Config; $C.peer = 'PC-B'; $C.input = 17; $C.audio = 'both'; $C.hp = 'PC-B'; $C.syncAt = 1764000000000; Save-Config
  $C = Load-Config
  Check ($C.peer -eq 'PC-B' -and $C.input -eq 17 -and $C.audio -eq 'both' -and $C.hp -eq 'PC-B' -and $C.syncAt -eq 1764000000000 -and $C.monitor -eq $true) 'config round trip'
  Remove-Item -Recurse $ConfigDir
  'self-check ok'; return
}

function Restore-Muted {   # unmute the apps a previous run muted (crash, kill, uninstall)
  if (-not (Test-Path $mutedPath)) { return }
  Get-Content $mutedPath | % { [void][Dg]::Muted.Add($_) }
  [Dg]::MuteOthers($false, $PID); Remove-Item $mutedPath
}
function Ensure-Icon { if (-not (Test-Path $icoPath)) { [Dg]::SaveIco($icoPath, 0, [int[]](16, 24, 32, 48, 256)) } }
function Set-Startup([bool]$on) {
  if (-not $on) { Remove-Item $lnk -ErrorAction SilentlyContinue; return }
  Ensure-Icon
  $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
  $sc.TargetPath = "$PSHOME\powershell.exe"; $sc.Arguments = $argLine; $sc.WorkingDirectory = $PSScriptRoot; $sc.IconLocation = $icoPath; $sc.Save()
}

if ($Install -or $Uninstall) {
  # stop running copies (also DeskGlide 1's deskglide.ps1 / deskglide-audio.ps1, which this replaces)
  Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    ? { $_.ProcessId -ne $PID -and $_.CommandLine -like '*deskglide*.ps1*' } |
    % { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Milliseconds 500
  Restore-Muted
  if ($Uninstall) { Set-Startup $false; "DeskGlide removed. Your settings are kept in $ConfigDir"; return }
  Set-Startup $true
  Start-Process "$PSHOME\powershell.exe" "$argLine -ShowWindow" -WindowStyle Hidden
  'DeskGlide is installed and running. Its window is open, and its icon is in the taskbar tray.'; return
}

# ---------------------------------------------------------------- the app
function Say([string]$text, [string]$kind) {   # kind: '' = log only, 'error' / 'info' = also a balloon (info only for pairing success)
  if ($kind -eq 'error') {
    if ($text -eq $S.lastErr -and ((Get-Date) - $S.lastErrAt).TotalMinutes -lt 5) { return }
    $S.lastErr = $text; $S.lastErrAt = Get-Date
  }
  $line = '{0:HH:mm:ss} {1}' -f (Get-Date), $text
  Add-Content -LiteralPath $logPath $line
  if ($Console) { Write-Host $line }
  elseif ($kind -and $tray) { $tray.ShowBalloonTip(5000, 'DeskGlide', $text, $(if ($kind -eq 'error') { 'Error' } else { 'Info' })) }
}
function Once([string]$id, [string]$text, [string]$kind) { if (-not $S.told[$id]) { $S.told[$id] = $true; Say $text $kind } }
function Peer-Online { [bool]($S.peerAddr -and ((Get-Date) - $S.peerSeen).TotalSeconds -lt 10) }
function Peer-Label { if ($C.peer) { $C.peer } else { 'the other PC' } }
function Pc-Label([string]$screen) { if ($screen -eq $S.screen) { $Name } elseif ($screen -eq $C.peer) { $C.peer } else { $screen.ToUpper() } }

function Send-State {
  if (-not $S.key) { return }
  $S.t = [Math]::Max([long]$S.t + 1, [long](Now-Ms))   # strictly increasing, the peer drops replays
  $b = [Text.Encoding]::UTF8.GetBytes([Dg]::Seal($S.key, (State-Json $C)))
  # broadcast finds the peer (and re-finds it when its address changes); unicast reaches it where broadcast doesn't
  $to = @($S.peerAddr, $S.fixedIp | ? { $_ })
  if (-not $NoBroadcast) { $to = @([Dg]::Broadcasts()) + $to }
  foreach ($ip in $to) {
    try { [void]$udp.Send($b, $b.Length, (New-Object Net.IPEndPoint($ip, $PeerPort))) } catch {}   # one dead adapter must not stop the rest; "not found" shows in the window
  }
  $S.lastSend = Get-Date
}

function Resolve-Peer {   # the saved/typed address -> IP for unicast
  $S.fixedIp = $null
  if (-not $C.peerAddress) { return }
  # ponytail: DNS lookup on the UI thread; only on start, on change, and once a minute while it fails
  try { $S.fixedIp = @([Net.Dns]::GetHostAddresses($C.peerAddress) | ? { $_.AddressFamily -eq 'InterNetwork' })[0] } catch {}
  if (-not $S.fixedIp) { Say "Can't find the address $($C.peerAddress)." }
}

function Receive-Control {
  while ($udp.Available -gt 0) {
    $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
    $json = [Dg]::Open($S.key, [Text.Encoding]::UTF8.GetString($udp.Receive([ref]$ep)))
    if (-not $json) { $S.badCtl++; continue }   # not paired with us, or tampered: drop
    $m = $json | ConvertFrom-Json
    if ($m.n -eq $Name) { continue }            # our own broadcast
    if (-not $C.peer) { $C.peer = $m.n; $S.code = ''; Save-Config; Say "Paired with $($m.n)." info }
    if ($m.n -ne $C.peer) { continue }
    # ponytail: replay guard is "timestamp must grow"; it resets after 30 s of silence so a peer whose clock jumped back recovers
    if (((Get-Date) - $S.peerSeen).TotalSeconds -gt 30) { $S.lastT = 0 }
    if ([long]$m.t -le $S.lastT) { continue }
    $S.lastT = [long]$m.t; $S.okCtl++
    if (-not $S.peerAddr -or -not $S.peerAddr.Equals($ep.Address)) { Say "Found $($m.n) at $($ep.Address)." }
    $S.peerAddr = $ep.Address; $S.peerSeen = Get-Date; $S.peerInput = [int]$m.i
    # remember the address for the next start; only replace it once it went quiet, so a peer on two adapters doesn't flip-flop
    if ($S.fixedIp -and $S.fixedIp.Equals($ep.Address)) { $S.fixedSeen = Get-Date }
    elseif (((Get-Date) - $S.fixedSeen).TotalSeconds -gt 10) { $C.peerAddress = "$($ep.Address)"; $S.fixedIp = $ep.Address; $S.fixedSeen = Get-Date; Save-Config }
    if ($m.s) { $S.peerLinks = @($m.l | % { $w = "$_" -split ' '; if ($w.Count -eq 3 -and $opp[$w[1]]) { [pscustomobject]@{ from = $w[0]; dir = $w[1]; to = $w[2] } } }) }
    if (Merge-Settings $C $m) { Save-Config; Update-Menu }
    if ($m.s -and -not $S.server) { if ($m.sa) { Set-Active 'peer' $m.n } else { Set-Active 'me' $Name } }
  }
}

function Set-Active($new, [string]$screen) {
  if ($new -eq $S.active) { return }
  $old = $S.active; $S.active = $new; $S.activeName = $screen; $S.activeSince = Get-Date; $S.inputOk = $false
  Say "Mouse is on $(if ($new -eq 'me') { 'this PC' } elseif ($C.peer) { $C.peer } else { $screen })."
  if ($S.server) { Send-State }   # tell the peer right away; it wakes its screen when the mouse arrives there
  if ($new -eq 'me' -and $old) { [Dg]::WakeDisplay() }   # so the monitor doesn't switch to a sleeping screen
  # The PC on screen sends the switch: many monitors ignore DDC from an input they aren't showing.
  if ($old -eq 'me' -and $new -eq 'peer' -and $C.monitor -and -not $C.paused) { Switch-Monitor }
  if ($C.onSwitch) {
    $pc = if ($new -eq 'me') { $Name } elseif ($C.peer) { $C.peer } else { $screen }
    try { Start-Process cmd.exe "/c `"$($C.onSwitch) `"$pc`"`"" -WindowStyle Hidden } catch { Say "Your switch script didn't start: $($_.Exception.Message)" error }
  }
}

function Switch-Monitor {
  $to = $S.peerInput
  if (-not $to) { $S.monMsg = "Can't switch yet: $(Peer-Label)'s input isn't known. Show it on the monitor once."; $S.monErr = $true; Say $S.monMsg; return }
  $S.monErr = $false
  if ($DryRun) { Say "dry run: would switch the monitor to input $to"; $S.monMsg = "Dry run: would switch the monitor to $(Input-Name $to)."; return }
  if ([Dg]::SetInput([uint32]$to)) {
    Say "Monitor -> input $to"; $S.monMsg = "Switched to $(Input-Name $to)."
    $S.verify = @{ at = (Get-Date).AddSeconds(2); to = $to; from = (My-Input); tries = 1; active = $S.active }
  } else { $S.monErr = $true; $S.monMsg = "The monitor did not accept the switch to $(Input-Name $to)."; Say $S.monMsg error }
}
function Check-Switch {   # 2 s after a switch: did the monitor really change? retry once, then tell the user
  $v = $S.verify
  if (-not $v -or (Get-Date) -lt $v.at) { return }
  $S.verify = $null
  if ($S.active -ne $v.active) { return }   # the mouse moved again meanwhile
  $cur = [Dg]::GetInput()
  if ($cur -ne $v.from -or -not $v.from) { return }   # switched (or the monitor won't answer from an input it doesn't show)
  if ($v.tries -lt 2) {
    Say "The monitor still shows input $cur, trying again."
    [void][Dg]::SetInput([uint32]$v.to); $v.at = (Get-Date).AddSeconds(2); $v.tries++; $S.verify = $v
  } else {
    $S.monErr = $true
    $S.monMsg = "Your monitor didn't accept the switch to $(Input-Name $v.to). Check that DDC/CI is on in the monitor's menu. Some monitors only accept it with the input set to manual, not auto."
    Say "Your monitor didn't accept the switch to $(Input-Name $v.to)." error
  }
}
function Test-Monitor {   # read-only: says what would happen
  $v = [Dg]::GetInput(); $peer = Peer-Label
  if ($v -lt 0) { $S.monErr = $true; $S.monMsg = "The monitor didn't answer. Turn on DDC/CI in the monitor's on-screen menu, then try again."; return }
  $S.monErr = $false
  $msg = "The monitor answers and shows $(Input-Name $v)$(if ($v -eq (My-Input)) { ' (this PC)' } elseif ($v -eq $S.peerInput) { " ($peer)" })."
  $msg += if ($S.peerInput) { " When the mouse moves to $peer, DeskGlide switches it to $(Input-Name $S.peerInput)." } else { " Show $peer on the monitor once so DeskGlide learns its input." }
  if (-not $C.monitor) { $msg += ' Monitor follows mouse is off, so it won''t switch by itself.' }
  $S.monMsg = $msg
}

function Detect-Role {   # the PC whose Synergy/Deskflow log has "switch from" lines is the server
  $log = if ($C.synergyLog) { $C.synergyLog } else { "$env:LOCALAPPDATA\synergy-dragon\logs\synergy-dragon-agent.log" }
  if (-not (Test-Path -LiteralPath $log)) { return }
  $text, $pos = Read-Lines $log 0
  if (-not $text.Contains('switch from "')) { return }
  $S.server = $true; $S.log = $log; $S.pos = $pos
  Say "This PC is the Synergy server (log: $log)."
  $t = Get-Target $text
  if (-not $t -or $t -eq $S.screen) { Set-Active 'me' $S.screen } else { Set-Active 'peer' $t }
}
function Read-Layout {   # Synergy 3's layout (read-only): the default until DeskGlide has its own; re-read when the file changes
  $f = Get-ChildItem "$env:APPDATA\synergy-dragon\agent\*\synergy-server.conf" -ErrorAction SilentlyContinue | sort LastWriteTime | select -Last 1 | % FullName
  if (-not $f) { $S.links = @(); $S.confPath = ''; return }
  $tm = (Get-Item -LiteralPath $f).LastWriteTimeUtc
  if ($f -eq $S.confPath -and $tm -eq $S.confTime) { return }
  $S.confPath = $f; $S.confTime = $tm; $S.links = @(Parse-Links ([IO.File]::ReadAllText($f)))
}
# Where the other PC is, as shown in the Layout card: DeskGlide's stored layout, else Synergy's. Also Synergy's, to compare.
function Current-Layout {
  $links = if ($S.server -or -not $S.peerLinks.Count) { $S.links } else { $S.peerLinks }
  $syn = Layout-Of $links $S.screen
  if ($syn) { $syn.other = Pc-Label $syn.other }
  $own = Layout-Stored $C.layout $Name $C.peer
  @{ own = $own; syn = $syn; show = $(if ($own) { $own } else { $syn }) }
}
function Set-Layout([string]$dir) {   # the other PC is on the $dir side of this one
  if (-not $C.peer -or -not $opp[$dir] -or $dir -eq $S.layDir) { return }
  $C.layout = @{ ($C.peer) = $dir }; Changed
  Say "Layout: $($C.peer) is $dir of this PC."
}

function Save-Muted {
  $ids = @([Dg]::Muted) -join "`n"
  if ($ids -eq $S.savedMuted) { return }
  $S.savedMuted = $ids
  if ($ids) { Set-Content $mutedPath $ids } else { Remove-Item $mutedPath -ErrorAction SilentlyContinue }
}

function Tick {
  $now = Get-Date
  Receive-Control
  if ($S.server -and (Test-Path -LiteralPath $S.log)) {
    $text, $S.pos = Read-Lines $S.log $S.pos
    $t = Get-Target $text
    if ($t) { $S.want = $(if ($t -eq $S.screen) { 'me' } else { 'peer' }); $S.wantName = $t; $S.since = $now }
    # wait 400 ms after the last switch so a bounce at the screen edge doesn't flicker the monitor
    if ($S.want -and $S.want -ne $S.active -and ($now - $S.since).TotalMilliseconds -ge 400) { Set-Active $S.want $S.wantName }
  }
  if ($showEvt.WaitOne(0)) { Show-Window }   # DeskGlide was started again: show this copy instead
  if ($S.n++ % 5) { return }   # the rest twice a second

  $online = Peer-Online
  if (($now - $S.lastSend).TotalSeconds -ge 2) { Send-State }
  if (($now - $S.roleAt).TotalSeconds -ge 60) {
    $S.roleAt = $now
    if (-not $S.server) { Detect-Role }
    if ($C.peerAddress -and -not $S.fixedIp) { Resolve-Peer }
  }
  if ($S.n % 30 -eq 1) { Read-Layout }   # every 3 s
  Check-Switch
  if ($S.volAt -and ($now - $S.volAt).TotalMilliseconds -ge 400) { $S.volAt = $null; Changed }   # slider: sync when it stops moving

  # learn this PC's monitor input while it is on screen (retry if the monitor still shows the other PC)
  if ($S.active -eq 'me' -and -not $S.inputOk -and ($now - $S.activeSince).TotalSeconds -ge 3 -and ($now - $S.readAt).TotalSeconds -ge 10) {
    $S.readAt = $now; $v = [Dg]::GetInput()
    if ($v -lt 0) { Once ddc 'The monitor does not answer DDC/CI. Turn on DDC/CI in the monitor''s menu.' error }
    elseif ($v -ne $S.peerInput) {
      $S.inputOk = $true; Say "This PC is on monitor input $v."
      if ($v -ne $C.input) { $C.input = $v; Save-Config; Send-State }
    }
  }
  if ($online -and (-not (My-Input) -or -not $S.peerInput)) {
    Once inputs 'Almost done: show each PC on the monitor once. Move the mouse to it and, if the screen does not follow, press the monitor''s input button.'
  }

  # audio: the PC with the headphones receives, the other one sends
  # ponytail: audio is authenticated (HMAC) but not encrypted; anyone on the LAN can listen. Add AES-CTR if that matters.
  $on = $online -and $C.audio -ne 'off' -and -not $C.paused
  [Dg]::Key = $S.key
  [Dg]::Target = if ($S.peerAddr) { New-Object Net.IPEndPoint($S.peerAddr, $AudioPort) } else { $null }
  [Dg]::SendOn = $on -and $C.hp -and $C.hp -eq $C.peer
  [Dg]::RecvOn = $on -and $C.hp -eq $Name
  [Dg]::RemoteOn = $C.audio -eq 'both' -or $S.active -eq 'peer'
  [Dg]::Volume = [Math]::Max(0, [Math]::Min(100, [int]$C.vol)) / 100
  if ([Dg]::RecvOn -and $C.audio -eq 'follow' -and $S.active -eq 'peer') { [Dg]::MuteOthers($true, $PID) }
  elseif ([Dg]::Muted.Count) { [Dg]::MuteOthers($false, $PID) }
  Save-Muted
  if ([Dg]::LastError) { Say "Audio: $([Dg]::LastError)" error }

  $S.iconState = if ($C.paused -or -not $C.peer) { 3 } elseif ($S.active -eq 'me') { 1 } elseif ($S.active -eq 'peer') { 2 } else { 0 }
  $act = switch ($S.active) { 'me' { 'this PC' } 'peer' { Peer-Label } default { '?' } }
  $pair = if (-not $S.key) { 'not paired' } elseif (-not $C.peer) { 'pairing...' } elseif ($online) { "paired, $($C.peer)" } else { "$($C.peer) not found" }
  $status = "DeskGlide$(if ($C.paused) { ' (paused)' }): $pair`nMouse on: $act"
  if ($tray) {
    $tray.Text = $status.Substring(0, [Math]::Min(63, $status.Length))
    if ($tray.Icon -ne $icons[$S.iconState]) { $tray.Icon = $icons[$S.iconState] }
  }
  Update-Ui
  if ($Shot -and $S.shownAt -and ($now - $S.shownAt).TotalSeconds -ge 4) { Save-Shot; [Windows.Forms.Application]::Exit() }
  if ($Console -and ($now - $S.statAt).TotalSeconds -ge 5) {
    $S.statAt = $now
    Write-Host ("{0:HH:mm:ss} [{1}] control ok {2} bad {3} | audio sent {4} ok {5} bad {6}" -f $now, ($status -replace "`n", ', '), $S.okCtl, $S.badCtl, [Dg]::Sent, [Dg]::Got, [Dg]::Bad)
  }
}

function Set-Key([string]$code) {
  if ([Dg]::NormCode($code).Length -ne 8) { throw "That code doesn't look right. It has 8 letters and digits, like ABCD-EFGH." }
  $S.key = [Dg]::DeriveKey($code); $C.key = [Convert]::ToBase64String($S.key)
  $C.peer = ''; $S.peerAddr = $null; $S.lastT = 0; $S.pairStart = Get-Date; $S.pairErr = ''
  Save-Config; Say 'Pairing: waiting for the other PC...'; Send-State
}
function Unpair {
  $S.key = $null; $C.key = ''; $C.peer = ''; $C.peerAddress = ''; $S.peerAddr = $null; $S.fixedIp = $null
  $S.code = ''; $S.pairErr = ''; $S.unpairAt = $null; $S.peerInput = 0; $S.peerLinks = @()
  Save-Config; Say 'Unpaired.'
}
function Use-Address([string]$text) {
  $a = Parse-Address $text
  if ($null -eq $a) { $S.addrErr = "That isn't an address. Type an IP address like 192.168.1.20, or the PC's name."; return }
  $S.addrErr = ''
  if ($a -ne $C.peerAddress) { $C.peerAddress = $a; $S.fixedSeen = Get-Date; Save-Config; Resolve-Peer; Send-State }
}
function Set-Log([string]$p) {   # the Synergy/Deskflow log path from the Settings card
  $p = $p.Trim().Trim('"')
  if ($p -eq $C.synergyLog) { return }
  $C.synergyLog = $p; Save-Config; $S.server = $false; Detect-Role
}
function Browse([string]$title, [string]$filter, [string]$dir) {
  $d = New-Object Microsoft.Win32.OpenFileDialog; $d.Title = $title; $d.Filter = $filter
  if (Test-Path $dir) { $d.InitialDirectory = $dir }
  if ($d.ShowDialog($win)) { $d.FileName }
}

function Changed { $C.syncAt = Now-Ms; Save-Config; Update-Menu; Send-State }   # a setting changed here: newest settings win on both PCs
function Set-Audio([string]$a) { if ($C.audio -ne $a) { $C.audio = $a; Changed } }
function Set-Hp([string]$pc) { if ($pc -and $C.hp -ne $pc) { $C.hp = $pc; Changed } }
function Update-Menu {
  if (-not $tray) { return }
  $miMon.Checked = $C.monitor; $miPause.Checked = $C.paused
  $miFollow.Checked = $C.audio -eq 'follow'; $miBoth.Checked = $C.audio -eq 'both'; $miOff.Checked = $C.audio -eq 'off'
  $miHpMe.Text = "$Name (this PC)"; $miHpMe.Checked = $C.hp -eq $Name
  $miHpPeer.Text = Peer-Label; $miHpPeer.Enabled = [bool]$C.peer; $miHpPeer.Checked = $C.hp -and $C.hp -eq $C.peer
}
function Item($items, [string]$text, [scriptblock]$do) {
  $i = New-Object Windows.Forms.ToolStripMenuItem $text
  $i.Tag = $do
  $i.Add_Click({ try { & $this.Tag; Update-Ui } catch { Say "$($_.Exception.Message)" error } })
  [void]$items.Add($i); $i
}

# ---------------------------------------------------------------- window
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DeskGlide" Width="1140" Height="790" MinWidth="920" MinHeight="560" WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI" FontSize="14" Background="{DynamicResource Bg}" Foreground="{DynamicResource Fg}" UseLayoutRounding="True">
<Window.Resources>
  <Style x:Key="CardBox" TargetType="Border">
    <Setter Property="Background" Value="{DynamicResource Card}"/><Setter Property="BorderBrush" Value="{DynamicResource Line}"/>
    <Setter Property="BorderThickness" Value="1"/><Setter Property="CornerRadius" Value="8"/>
    <Setter Property="Padding" Value="20,16,20,18"/><Setter Property="Margin" Value="0,0,0,14"/>
  </Style>
  <Style x:Key="InsetBox" TargetType="Border">
    <Setter Property="Background" Value="{DynamicResource Inset}"/><Setter Property="CornerRadius" Value="6"/><Setter Property="Padding" Value="2"/>
  </Style>
  <Style x:Key="H" TargetType="TextBlock"><Setter Property="FontSize" Value="16"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
  <Style x:Key="Big" TargetType="TextBlock"><Setter Property="FontSize" Value="26"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Margin" Value="0,0,0,10"/><Setter Property="TextWrapping" Value="Wrap"/></Style>
  <Style x:Key="Body" TargetType="TextBlock"><Setter Property="TextWrapping" Value="Wrap"/><Setter Property="LineHeight" Value="21"/></Style>
  <Style x:Key="Sub" TargetType="TextBlock"><Setter Property="Foreground" Value="{DynamicResource Fg2}"/><Setter Property="FontSize" Value="12.5"/><Setter Property="TextWrapping" Value="Wrap"/></Style>
  <Style x:Key="Label" TargetType="TextBlock"><Setter Property="Margin" Value="0,12,0,5"/></Style>
  <Style x:Key="Glyph" TargetType="TextBlock">
    <Setter Property="FontFamily" Value="Segoe Fluent Icons, Segoe MDL2 Assets"/><Setter Property="FontSize" Value="16"/>
    <Setter Property="Foreground" Value="{DynamicResource Accent}"/><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="Margin" Value="0,0,12,0"/>
  </Style>
  <Style TargetType="Button">
    <Setter Property="Background" Value="{DynamicResource Btn}"/><Setter Property="Foreground" Value="{DynamicResource Fg}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource Line2}"/><Setter Property="Padding" Value="16,6"/><Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
      <Grid>
        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="5"/>
        <Border x:Name="hover" Background="{DynamicResource Hover}" CornerRadius="5" Visibility="Hidden"/>
        <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Grid>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="hover" Property="Visibility" Value="Visible"/></Trigger>
        <Trigger Property="IsPressed" Value="True"><Setter Property="Opacity" Value="0.8"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
    <Setter Property="Background" Value="{DynamicResource Accent}"/><Setter Property="BorderBrush" Value="{DynamicResource Accent}"/><Setter Property="Foreground" Value="{DynamicResource AccentFg}"/>
  </Style>
  <Style x:Key="Link" TargetType="Button">
    <Setter Property="Foreground" Value="{DynamicResource Accent}"/><Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><ContentPresenter VerticalAlignment="Center"/></ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="Switch" TargetType="CheckBox">
    <Setter Property="Foreground" Value="{DynamicResource Fg}"/><Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox">
      <Grid Background="Transparent">
        <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <ContentPresenter VerticalAlignment="Center" Margin="0,0,16,0"/>
        <Border x:Name="track" Grid.Column="1" Width="40" Height="20" CornerRadius="10" BorderThickness="1" BorderBrush="{DynamicResource Fg2}" Background="Transparent" VerticalAlignment="Center">
          <Ellipse x:Name="knob" Width="12" Height="12" Fill="{DynamicResource Fg2}" HorizontalAlignment="Left" Margin="3,0,0,0"/>
        </Border>
      </Grid>
      <ControlTemplate.Triggers>
        <Trigger Property="IsChecked" Value="True">
          <Setter TargetName="track" Property="Background" Value="{DynamicResource Accent}"/><Setter TargetName="track" Property="BorderBrush" Value="{DynamicResource Accent}"/>
          <Setter TargetName="knob" Property="Fill" Value="{DynamicResource AccentFg}"/><Setter TargetName="knob" Property="HorizontalAlignment" Value="Right"/>
          <Setter TargetName="knob" Property="Margin" Value="0,0,3,0"/>
        </Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="Seg" TargetType="RadioButton">
    <Setter Property="Foreground" Value="{DynamicResource Fg}"/><Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RadioButton">
      <Border x:Name="b" Background="Transparent" CornerRadius="5" Padding="4,6">
        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource Hover}"/></Trigger>
        <Trigger Property="IsChecked" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource Accent}"/><Setter Property="Foreground" Value="{DynamicResource AccentFg}"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="TextBox">
    <Setter Property="Foreground" Value="{DynamicResource Fg}"/><Setter Property="Background" Value="{DynamicResource Field}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource Line2}"/><Setter Property="CaretBrush" Value="{DynamicResource Fg}"/>
    <Setter Property="SelectionBrush" Value="{DynamicResource Accent}"/><Setter Property="Padding" Value="6,5"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TextBox">
      <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="5">
        <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
      </Border>
      <ControlTemplate.Triggers><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{DynamicResource Accent}"/></Trigger></ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="SliderFill" TargetType="RepeatButton"><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RepeatButton">
    <Grid Background="Transparent"><Border Height="4" CornerRadius="2" Background="{DynamicResource Accent}"/></Grid>
  </ControlTemplate></Setter.Value></Setter></Style>
  <Style x:Key="SliderRest" TargetType="RepeatButton"><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RepeatButton">
    <Grid Background="Transparent"><Border Height="4" CornerRadius="2" Background="{DynamicResource Line2}"/></Grid>
  </ControlTemplate></Setter.Value></Setter></Style>
  <Style TargetType="Slider"><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Slider">
    <Track x:Name="PART_Track" Height="22">
      <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource SliderFill}" Command="Slider.DecreaseLarge"/></Track.DecreaseRepeatButton>
      <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource SliderRest}" Command="Slider.IncreaseLarge"/></Track.IncreaseRepeatButton>
      <Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb">
        <Grid Width="20" Height="20"><Ellipse Fill="{DynamicResource Card}" Stroke="{DynamicResource Line2}"/><Ellipse Width="10" Height="10" Fill="{DynamicResource Accent}"/></Grid>
      </ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
    </Track>
  </ControlTemplate></Setter.Value></Setter></Style>
  <Style x:Key="Screen" TargetType="Border">
    <Setter Property="Width" Value="140"/><Setter Property="Height" Value="70"/><Setter Property="Margin" Value="4"/><Setter Property="CornerRadius" Value="7"/>
    <Setter Property="BorderThickness" Value="1.5"/><Setter Property="BorderBrush" Value="{DynamicResource Line2}"/><Setter Property="Background" Value="{DynamicResource Inset}"/>
  </Style>
</Window.Resources>
<Grid>
  <Grid x:Name="Main" Margin="28,20,28,12">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <Grid Margin="0,0,0,18">
      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/></Grid.ColumnDefinitions>
      <Image x:Name="Logo" Width="52" Height="52" Margin="0,0,16,0" VerticalAlignment="Center"/>
      <StackPanel Grid.Column="1" VerticalAlignment="Center">
        <StackPanel Orientation="Horizontal">
          <TextBlock x:Name="Title" FontSize="24" FontWeight="SemiBold" Text="DeskGlide"/>
          <Ellipse x:Name="Dot" Width="10" Height="10" Margin="12,4,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <TextBlock x:Name="Sub" Foreground="{DynamicResource Fg2}" Margin="0,2,0,0" TextWrapping="Wrap"/>
      </StackPanel>
    </Grid>
    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="14"/><ColumnDefinition/><ColumnDefinition Width="14"/><ColumnDefinition/></Grid.ColumnDefinitions>
        <StackPanel>
          <Border Style="{StaticResource CardBox}"><StackPanel>
            <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Glyph}" Text="&#xE8AB;"/><TextBlock Style="{StaticResource H}" Text="Layout"/></StackPanel>
            <Grid x:Name="LayoutGrid" HorizontalAlignment="Center" Margin="0,12,0,0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
              <Border x:Name="BoxMe" Grid.Row="1" Grid.Column="1" Style="{StaticResource Screen}"><StackPanel VerticalAlignment="Center" Margin="6,0">
                <TextBlock x:Name="BoxMeName" FontSize="12.5" FontWeight="SemiBold" HorizontalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                <TextBlock x:Name="BoxMeTag" FontSize="11" Foreground="{DynamicResource Fg2}" HorizontalAlignment="Center"/></StackPanel></Border>
              <Border x:Name="BoxPeer" Grid.Row="1" Grid.Column="0" Style="{StaticResource Screen}" Panel.ZIndex="1" ToolTip="Drag to the side of this PC where the other PC is"><StackPanel VerticalAlignment="Center" Margin="6,0">
                <TextBlock x:Name="BoxPeerName" FontSize="12.5" FontWeight="SemiBold" HorizontalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                <TextBlock x:Name="BoxPeerTag" FontSize="11" Foreground="{DynamicResource Fg2}" HorizontalAlignment="Center"/></StackPanel></Border>
            </Grid>
            <TextBlock x:Name="LayoutCap" Style="{StaticResource Body}" Margin="0,12,0,0"/>
            <StackPanel x:Name="LayEdit">
              <TextBlock x:Name="LayLabel" Style="{StaticResource Label}"/>
              <Border Style="{StaticResource InsetBox}"><UniformGrid Rows="1">
                <RadioButton x:Name="LayLeft" GroupName="lay" Style="{StaticResource Seg}" Content="Left"/>
                <RadioButton x:Name="LayRight" GroupName="lay" Style="{StaticResource Seg}" Content="Right"/>
                <RadioButton x:Name="LayUp" GroupName="lay" Style="{StaticResource Seg}" Content="Above"/>
                <RadioButton x:Name="LayDown" GroupName="lay" Style="{StaticResource Seg}" Content="Below"/>
              </UniformGrid></Border>
            </StackPanel>
            <TextBlock x:Name="LayoutMsg" Style="{StaticResource Sub}" Margin="0,8,0,0"/>
          </StackPanel></Border>
          <Border Style="{StaticResource CardBox}"><StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,12"><TextBlock Style="{StaticResource Glyph}" Text="&#xE7F4;"/><TextBlock Style="{StaticResource H}" Text="Monitor"/></StackPanel>
            <CheckBox x:Name="MonToggle" Style="{StaticResource Switch}"><StackPanel>
              <TextBlock Text="Monitor follows mouse"/>
              <TextBlock Style="{StaticResource Sub}" Text="Switch the monitor's input to the PC that has the mouse."/></StackPanel></CheckBox>
            <Border Style="{StaticResource InsetBox}" Padding="12,8" Margin="0,12,0,12"><Grid>
              <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
              <TextBlock x:Name="MeName" TextTrimming="CharacterEllipsis"/><TextBlock x:Name="MeInput" Grid.Column="1" FontWeight="SemiBold" Margin="12,0,0,0"/>
              <TextBlock x:Name="PeerName" Grid.Row="1" Margin="0,6,0,0" TextTrimming="CharacterEllipsis"/><TextBlock x:Name="PeerInput" Grid.Row="1" Grid.Column="1" FontWeight="SemiBold" Margin="12,6,0,0"/>
            </Grid></Border>
            <StackPanel Orientation="Horizontal">
              <Button x:Name="SwitchNow" Style="{StaticResource Primary}" Content="Switch monitor now"/>
              <Button x:Name="TestMon" Content="Test" Margin="8,0,0,0" ToolTip="Ask the monitor which input it shows. Nothing is switched."/>
            </StackPanel>
            <TextBlock x:Name="MonMsg" Style="{StaticResource Sub}" Margin="0,10,0,0"/>
          </StackPanel></Border>
        </StackPanel>

        <StackPanel Grid.Column="2">
          <Border Style="{StaticResource CardBox}"><StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,12"><TextBlock Style="{StaticResource Glyph}" Text="&#xE7F6;"/><TextBlock Style="{StaticResource H}" Text="Sound"/></StackPanel>
            <Border Style="{StaticResource InsetBox}"><UniformGrid Rows="1">
              <RadioButton x:Name="AFollow" GroupName="audio" Style="{StaticResource Seg}" Content="Follow mouse"/>
              <RadioButton x:Name="ABoth" GroupName="audio" Style="{StaticResource Seg}" Content="Hear both"/>
              <RadioButton x:Name="AOff" GroupName="audio" Style="{StaticResource Seg}" Content="Off"/>
            </UniformGrid></Border>
            <TextBlock Style="{StaticResource Label}" Text="Headphones are plugged into"/>
            <Border x:Name="HpHostMain"><Border x:Name="HpPanel" Style="{StaticResource InsetBox}"><UniformGrid Rows="1">
              <RadioButton x:Name="HpMe" GroupName="hp" Style="{StaticResource Seg}"/>
              <RadioButton x:Name="HpPeer" GroupName="hp" Style="{StaticResource Seg}"/>
            </UniformGrid></Border></Border>
            <Grid Margin="0,16,0,0"><TextBlock x:Name="VolLabel" TextTrimming="CharacterEllipsis" Margin="0,0,44,0"/><TextBlock x:Name="VolPct" HorizontalAlignment="Right" Foreground="{DynamicResource Fg2}"/></Grid>
            <Slider x:Name="Vol" Minimum="0" Maximum="100" SmallChange="1" LargeChange="10" IsMoveToPointEnabled="True" Margin="0,6,0,0"/>
            <Border Style="{StaticResource InsetBox}" Padding="12,9" Margin="0,14,0,0"><Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/></Grid.ColumnDefinitions>
              <Ellipse x:Name="AudioDot" Width="8" Height="8" Margin="0,6,10,0" VerticalAlignment="Top"/>
              <TextBlock x:Name="AudioWhy" Grid.Column="1" Style="{StaticResource Body}"/>
            </Grid></Border>
          </StackPanel></Border>
          <Border Style="{StaticResource CardBox}"><StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,12"><TextBlock Style="{StaticResource Glyph}" Text="&#xE71B;"/><TextBlock Style="{StaticResource H}" Text="Pairing"/></StackPanel>
            <StackPanel x:Name="PairedBox">
              <TextBlock x:Name="PairedText" FontWeight="SemiBold"/>
              <TextBlock Style="{StaticResource Sub}" Margin="0,4,0,0" Text="Every message and sound packet between the two PCs is signed with your pairing key, so other devices can't control DeskGlide."/>
              <Button x:Name="Unpair" Content="Unpair" HorizontalAlignment="Left" Margin="0,12,0,0"/>
            </StackPanel>
            <Border x:Name="PairHostMain"><StackPanel x:Name="PairPanel">
              <StackPanel x:Name="PairChoose">
                <TextBlock x:Name="PairIntro" Style="{StaticResource Sub}" Text="Show a code on one PC, then type it on the other. You only do this once."/>
                <Button x:Name="ShowCode" Style="{StaticResource Primary}" Content="Show a code on this PC" HorizontalAlignment="Left" Margin="0,12,0,0"/>
                <StackPanel x:Name="CodeBox" Margin="0,4,0,0">
                  <TextBlock x:Name="Code" FontSize="34" FontWeight="SemiBold" Foreground="{DynamicResource Accent}"/>
                  <TextBlock x:Name="MyAddrs" Style="{StaticResource Sub}" Margin="0,4,0,0"/>
                </StackPanel>
                <StackPanel x:Name="EntryBox">
                  <TextBlock Style="{StaticResource Label}" Text="Or type the code the other PC shows"/>
                  <DockPanel><Button x:Name="PairGo" DockPanel.Dock="Right" Content="Pair" Margin="8,0,0,0"/><TextBox x:Name="CodeIn" CharacterCasing="Upper" MaxLength="12" FontSize="15"/></DockPanel>
                </StackPanel>
                <StackPanel x:Name="AddrRow" Margin="0,12,0,0">
                  <TextBlock Text="Other PC's address"/>
                  <DockPanel Margin="0,6,0,0"><Button x:Name="AddrGo" DockPanel.Dock="Right" Content="Connect" Margin="8,0,0,0"/><TextBox x:Name="AddrIn"/></DockPanel>
                </StackPanel>
              </StackPanel>
              <ProgressBar x:Name="PairBusy" IsIndeterminate="True" Height="3" Margin="0,14,0,0" Foreground="{DynamicResource Accent}" Background="{DynamicResource Inset}" BorderThickness="0"/>
              <TextBlock x:Name="PairMsg" Style="{StaticResource Body}" Margin="0,8,0,0"/>
              <Button x:Name="PairCancel" Style="{StaticResource Link}" Content="Cancel" HorizontalAlignment="Left" Margin="0,8,0,0"/>
            </StackPanel></Border>
          </StackPanel></Border>
        </StackPanel>

        <StackPanel Grid.Column="4">
          <Border Style="{StaticResource CardBox}"><StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,12"><TextBlock Style="{StaticResource Glyph}" Text="&#xE713;"/><TextBlock Style="{StaticResource H}" Text="Settings"/></StackPanel>
            <CheckBox x:Name="StartupToggle" Style="{StaticResource Switch}" Content="Start with Windows"/>
            <CheckBox x:Name="PauseToggle" Style="{StaticResource Switch}" Margin="0,12,0,0"><StackPanel>
              <TextBlock Text="Pause DeskGlide"/><TextBlock Style="{StaticResource Sub}" Text="No switching and no sound until you turn this off."/></StackPanel></CheckBox>
            <TextBlock Style="{StaticResource Label}" Text="Synergy or Deskflow log"/>
            <DockPanel><Button x:Name="BrowseLog" DockPanel.Dock="Right" Content="Browse..." Margin="8,0,0,0"/><TextBox x:Name="LogPath"/></DockPanel>
            <TextBlock x:Name="RoleText" Style="{StaticResource Sub}" Margin="0,4,0,0"/>
            <TextBlock Style="{StaticResource Label}" Text="Other PC's address (optional)"/>
            <TextBox x:Name="AddrSet"/>
            <TextBlock x:Name="AddrHint" Style="{StaticResource Sub}" Margin="0,4,0,0"/>
            <TextBlock Style="{StaticResource Label}" Text="Run my script when the screen switches"/>
            <TextBox x:Name="Script"/>
            <TextBlock Style="{StaticResource Sub}" Margin="0,4,0,0" Text="Optional. Gets the name of the PC that now has the mouse, for example C:\Scripts\switched.cmd"/>
          </StackPanel></Border>
        </StackPanel>
      </Grid>
    </ScrollViewer>
    <DockPanel Grid.Row="2" Margin="2,6,2,0">
      <TextBlock DockPanel.Dock="Right" FontSize="12.5"><Hyperlink x:Name="OpenLog" Foreground="{DynamicResource Accent}">Open log</Hyperlink><Run Text="     "/><Hyperlink x:Name="Help" Foreground="{DynamicResource Accent}">Help and README</Hyperlink></TextBlock>
      <TextBlock x:Name="Ver" Foreground="{DynamicResource Fg2}" FontSize="12.5"/>
    </DockPanel>
  </Grid>

  <Grid x:Name="Wiz" Visibility="Collapsed">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <DockPanel Margin="36,24,36,0">
      <TextBlock x:Name="WizStep" DockPanel.Dock="Right" Foreground="{DynamicResource Fg2}" VerticalAlignment="Center"/>
      <StackPanel Orientation="Horizontal">
        <Image x:Name="WizLogo" Width="28" Height="28"/>
        <TextBlock Text="DeskGlide setup" FontSize="15" FontWeight="SemiBold" Margin="10,0,24,0" VerticalAlignment="Center"/>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Rectangle x:Name="D1" Width="28" Height="4" RadiusX="2" RadiusY="2" Margin="0,0,6,0"/><Rectangle x:Name="D2" Width="28" Height="4" RadiusX="2" RadiusY="2" Margin="0,0,6,0"/>
          <Rectangle x:Name="D3" Width="28" Height="4" RadiusX="2" RadiusY="2" Margin="0,0,6,0"/><Rectangle x:Name="D4" Width="28" Height="4" RadiusX="2" RadiusY="2" Margin="0,0,6,0"/>
          <Rectangle x:Name="D5" Width="28" Height="4" RadiusX="2" RadiusY="2"/>
        </StackPanel>
      </StackPanel>
    </DockPanel>
    <Border Grid.Row="1" Style="{StaticResource CardBox}" Margin="36,20,36,18" Padding="48,36">
      <ScrollViewer VerticalScrollBarVisibility="Auto"><Grid MaxWidth="620" HorizontalAlignment="Left">
        <StackPanel x:Name="W1">
          <Image x:Name="BigLogo" Width="88" Height="88" HorizontalAlignment="Left"/>
          <TextBlock Style="{StaticResource Big}" Text="Welcome to DeskGlide" Margin="0,18,0,10"/>
          <TextBlock Style="{StaticResource Body}" Text="Two PCs, one monitor, one keyboard and mouse. When Synergy moves your mouse to the other PC, DeskGlide makes everything else follow."/>
          <Grid Margin="0,22,0,0">
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/></Grid.ColumnDefinitions>
            <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
            <TextBlock Style="{StaticResource Glyph}" Text="&#xE7F4;" FontSize="20" Margin="0,0,16,14"/>
            <TextBlock Grid.Column="1" Style="{StaticResource Body}" Text="The monitor switches to the PC that has the mouse." Margin="0,0,0,14"/>
            <TextBlock Grid.Row="1" Style="{StaticResource Glyph}" Text="&#xE7F6;" FontSize="20" Margin="0,0,16,14"/>
            <TextBlock Grid.Row="1" Grid.Column="1" Style="{StaticResource Body}" Text="Your headphones play that PC's sound, or both PCs at once." Margin="0,0,0,14"/>
            <TextBlock Grid.Row="2" Style="{StaticResource Glyph}" Text="&#xE71B;" FontSize="20" Margin="0,0,16,0"/>
            <TextBlock Grid.Row="2" Grid.Column="1" Style="{StaticResource Body}" Text="The two PCs find each other on your network. You pair them once with a code."/>
          </Grid>
          <TextBlock Style="{StaticResource Sub}" Margin="0,22,0,0" Text="Setup takes about a minute. Install DeskGlide on both PCs and run this setup on both."/>
        </StackPanel>
        <StackPanel x:Name="W2" Visibility="Collapsed">
          <TextBlock Style="{StaticResource Big}" Text="Pair your two PCs"/>
          <TextBlock Style="{StaticResource Body}" Text="On one PC, show a code. On the other PC, type it in. DeskGlide must be running on both."/>
          <Border x:Name="PairHostWiz" Margin="0,18,0,0"/>
        </StackPanel>
        <StackPanel x:Name="W3" Visibility="Collapsed">
          <TextBlock Style="{StaticResource Big}" Text="Show each PC on the monitor once"/>
          <TextBlock Style="{StaticResource Body}" Text="Move your mouse to each PC once and wait a few seconds. If the screen doesn't follow, press the monitor's input button. DeskGlide asks the monitor which input each PC uses."/>
          <Border Style="{StaticResource InsetBox}" Padding="16,12" Margin="0,18,0,0"><Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
            <TextBlock x:Name="MeTick" Style="{StaticResource Glyph}"/><TextBlock x:Name="WMeName" Grid.Column="1"/><TextBlock x:Name="WMeInput" Grid.Column="2" FontWeight="SemiBold"/>
            <TextBlock x:Name="PeerTick" Grid.Row="1" Style="{StaticResource Glyph}" Margin="0,10,12,0"/><TextBlock x:Name="WPeerName" Grid.Row="1" Grid.Column="1" Margin="0,10,0,0"/><TextBlock x:Name="WPeerInput" Grid.Row="1" Grid.Column="2" FontWeight="SemiBold" Margin="0,10,0,0"/>
          </Grid></Border>
          <TextBlock x:Name="W3Msg" Style="{StaticResource Sub}" Margin="0,12,0,0"/>
        </StackPanel>
        <StackPanel x:Name="W4" Visibility="Collapsed">
          <TextBlock Style="{StaticResource Big}" Text="Where are your headphones plugged in?"/>
          <TextBlock Style="{StaticResource Body}" Text="The other PC sends its sound there over your network. Both PCs share this choice, and you can change it later."/>
          <Border x:Name="HpHostWiz" Margin="0,18,0,0"/>
          <TextBlock Style="{StaticResource Sub}" Margin="0,12,0,0" Text="No headphones? Click Next, and set Sound to Off later."/>
        </StackPanel>
        <StackPanel x:Name="W5" Visibility="Collapsed">
          <TextBlock Style="{StaticResource Glyph}" Text="&#xE73E;" FontSize="40" HorizontalAlignment="Left" Margin="0,0,0,14"/>
          <TextBlock Style="{StaticResource Big}" Text="You're all set"/>
          <TextBlock x:Name="Summary" Style="{StaticResource Body}"/>
          <TextBlock Style="{StaticResource Sub}" Margin="0,18,0,0" Text="DeskGlide keeps running in the taskbar tray. Double-click its icon to open this window again."/>
        </StackPanel>
      </Grid></ScrollViewer>
    </Border>
    <DockPanel Grid.Row="2" Margin="36,0,36,24">
      <Button x:Name="WizSkip" Style="{StaticResource Link}" Content="Skip setup"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="WizBack" Content="Back" MinWidth="100"/>
        <Button x:Name="WizNext" Style="{StaticResource Primary}" Content="Next" MinWidth="130" Margin="8,0,0,0"/>
      </StackPanel>
    </DockPanel>
  </Grid>
</Grid>
</Window>
'@

$themes = @{
  light = @{ Bg = '#F3F3F3'; Card = '#FFFFFF'; Line = '#E5E5E5'; Line2 = '#C8C8C8'; Inset = '#F5F5F5'; Fg = '#1B1B1B'; Fg2 = '#5E5E5E'
             Btn = '#FDFDFD'; Hover = '#0D000000'; Field = '#FFFFFF'; Accent = '#005FB8'; AccentFg = '#FFFFFF'; AccentSoft = '#1F005FB8'
             Good = '#0F7B0F'; Warn = '#9D5D00'; Bad = '#C42B1C' }
  dark  = @{ Bg = '#202020'; Card = '#2B2B2B'; Line = '#383838'; Line2 = '#5A5A5A'; Inset = '#242424'; Fg = '#FFFFFF'; Fg2 = '#C5C5C5'
             Btn = '#373737'; Hover = '#17FFFFFF'; Field = '#1F1F1F'; Accent = '#60CDFF'; AccentFg = '#000000'; AccentSoft = '#3360CDFF'
             Good = '#6CCB5F'; Warn = '#FCE100'; Bad = '#FF99A4' }
}
function Apply-Theme {   # follows Windows' app theme, live
  $dark = if ($Theme) { $Theme -eq 'dark' } else { (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue).AppsUseLightTheme -eq 0 }
  if ($dark -eq $S.dark) { return }
  $S.dark = $dark; $t = $themes[$(if ($dark) { 'dark' } else { 'light' })]
  $bc = New-Object Windows.Media.BrushConverter
  foreach ($k in $t.Keys) { $win.Resources[$k] = $bc.ConvertFromString($t[$k]) }
  [Dg]::DarkTitle((New-Object Windows.Interop.WindowInteropHelper $win).Handle, $dark)
}
function Brush([string]$k) { $win.Resources[$k] }
function Show-If($el, $cond) { $el.Visibility = if ($cond) { 'Visible' } else { 'Collapsed' } }

function On([string]$name, [string[]]$events, [scriptblock]$do) {   # UI event -> $do, then refresh the window
  $el = $ui[$name]; $el.Tag = $do
  foreach ($ev in $events) { $el."add_$ev"({ try { & $this.Tag @args } catch { Say "$($_.Exception.Message)" error }; Update-Ui }) }
}

function New-Window {
  $script:win = [Windows.Markup.XamlReader]::Parse($xaml)
  foreach ($n in [regex]::Matches($xaml, 'x:Name="([A-Z]\w*)"') | % { $_.Groups[1].Value }) { $ui[$n] = $win.FindName($n) }
  [Windows.Forms.Integration.ElementHost]::EnableModelessKeyboardInterop($win)   # typing works under the WinForms message loop
  [void](New-Object Windows.Interop.WindowInteropHelper $win).EnsureHandle()
  Ensure-Icon
  $win.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$icoPath)
  $script:logos = 0..3 | % { [Windows.Media.Imaging.BitmapFrame]::Create((New-Object IO.MemoryStream (, [Dg]::IconPng(176, $_))), 'None', 'OnLoad') }
  $ui.WizLogo.Source = $logos[0]; $ui.BigLogo.Source = $logos[0]
  $ui.Ver.Text = "DeskGlide $Version  -  $Name$(if ($DryRun) { '  -  dry run' })"
  if ($Shot) { $win.Topmost = $true }

  On MonToggle Checked, Unchecked { if ($C.monitor -ne [bool]$ui.MonToggle.IsChecked) { $C.monitor = -not $C.monitor; Changed } }
  On PauseToggle Checked, Unchecked { if ($C.paused -ne [bool]$ui.PauseToggle.IsChecked) { $C.paused = -not $C.paused; Changed } }
  On StartupToggle Checked, Unchecked { $want = [bool]$ui.StartupToggle.IsChecked; if ((Test-Path $lnk) -ne $want) { Set-Startup $want } }
  On AFollow Checked { Set-Audio 'follow' }
  On ABoth Checked { Set-Audio 'both' }
  On AOff Checked { Set-Audio 'off' }
  On HpMe Checked { Set-Hp $Name }
  On HpPeer Checked { Set-Hp $C.peer }
  On Vol ValueChanged { $v = [int]$ui.Vol.Value; if ($v -ne $C.vol) { $C.vol = $v; $S.volAt = Get-Date } }
  On SwitchNow Click { Switch-Monitor }
  On TestMon Click { Test-Monitor }
  On ShowCode Click { $S.code = [Dg]::NewCode(); $S.myAddrs = (@(My-Addresses) -join '   '); Set-Key $S.code }
  On PairGo Click { Pair-Entered }
  On CodeIn KeyDown { if ($args[1].Key -eq 'Return') { Pair-Entered } }
  On AddrGo Click { Use-Address $ui.AddrIn.Text }
  On AddrIn KeyDown { if ($args[1].Key -eq 'Return') { Use-Address $ui.AddrIn.Text } }
  On AddrSet LostFocus { Use-Address $ui.AddrSet.Text }
  On Unpair Click { if ($S.unpairAt -and ((Get-Date) - $S.unpairAt).TotalSeconds -lt 5) { Unpair } else { $S.unpairAt = Get-Date } }
  On PairCancel Click { Unpair }
  On LogPath LostFocus { Set-Log $ui.LogPath.Text }
  On BrowseLog Click { $f = Browse 'Choose the Synergy or Deskflow log file' 'Log files|*.log;*.txt|All files|*.*' "$env:LOCALAPPDATA\synergy-dragon\logs"; if ($f) { Set-Log $f } }
  On Script LostFocus { $C.onSwitch = $ui.Script.Text.Trim(); Save-Config }
  On OpenLog Click { Start-Process notepad.exe "`"$logPath`"" }
  On LayLeft Checked { Set-Layout 'left' }
  On LayRight Checked { Set-Layout 'right' }
  On LayUp Checked { Set-Layout 'up' }
  On LayDown Checked { Set-Layout 'down' }
  On Help Click { $md = Join-Path $PSScriptRoot 'README.md'; if (Test-Path 'Registry::HKEY_CLASSES_ROOT\.md') { Start-Process $md } else { Start-Process notepad.exe "`"$md`"" } }
  On WizNext Click { if ($S.wiz -ge 5) { Show-Wizard 0 } else { Show-Wizard ($S.wiz + 1) } }
  On WizBack Click { Show-Wizard ($S.wiz - 1) }
  On WizSkip Click { Show-Wizard 0 }
  # drag the other PC's screen around this one, like Windows' display settings
  $ui.BoxPeer.RenderTransform = New-Object Windows.Media.TranslateTransform
  $ui.BoxPeer.Add_MouseLeftButtonDown({ if ($C.peer) { $S.drag = $args[1].GetPosition($ui.LayoutGrid); [void]$ui.BoxPeer.CaptureMouse() } })
  $ui.BoxPeer.Add_MouseMove({ if ($S.drag) { $p = $args[1].GetPosition($ui.LayoutGrid); $ui.BoxPeer.RenderTransform.X = $p.X - $S.drag.X; $ui.BoxPeer.RenderTransform.Y = $p.Y - $S.drag.Y } })
  $ui.BoxPeer.Add_MouseLeftButtonUp({ try { Drop-Peer } catch { Say "$($_.Exception.Message)" error }; Update-Ui })
  $win.Add_Closing({ if ($tray) { $args[1].Cancel = $true; $win.Hide() } else { [Windows.Forms.Application]::Exit() } })   # the tray's Quit ends DeskGlide
  Apply-Theme
}

function Drop-Peer {   # the side of this PC's box where the other box was let go
  if (-not $S.drag) { return }
  $S.drag = $null; $ui.BoxPeer.ReleaseMouseCapture()
  $p = $ui.BoxPeer.TranslatePoint([Windows.Point]::new($ui.BoxPeer.ActualWidth / 2, $ui.BoxPeer.ActualHeight / 2), $ui.LayoutGrid)
  $me = $ui.BoxMe.TranslatePoint([Windows.Point]::new($ui.BoxMe.ActualWidth / 2, $ui.BoxMe.ActualHeight / 2), $ui.LayoutGrid)
  $ui.BoxPeer.RenderTransform.X = 0; $ui.BoxPeer.RenderTransform.Y = 0
  $dx = $p.X - $me.X; $dy = $p.Y - $me.Y
  if ([Math]::Abs($dx) -ge [Math]::Abs($dy)) { Set-Layout $(if ($dx -lt 0) { 'left' } else { 'right' }) }
  else { Set-Layout $(if ($dy -lt 0) { 'up' } else { 'down' }) }
}

function Pair-Entered {
  if ([Dg]::NormCode($ui.CodeIn.Text).Length -ne 8) { $S.pairErr = "That code doesn't look right. It has 8 letters and digits, like K7MX-Q2PD."; return }
  $S.code = ''; Set-Key $ui.CodeIn.Text
}

function Show-Window {
  if (-not $win) { New-Window }
  if (-not $S.key -and -not $S.wizDone -and -not $S.wiz) { Show-Wizard 1 }
  $win.Show()
  if ($win.WindowState -eq 'Minimized') { $win.WindowState = 'Normal' }
  [void]$win.Activate(); $S.shownAt = Get-Date; Update-Ui
}

function Show-Wizard([int]$step) {
  $S.wiz = $step; $in = $step -gt 0
  foreach ($p in @(@($ui.PairPanel, $ui.PairHostWiz, $ui.PairHostMain), @($ui.HpPanel, $ui.HpHostWiz, $ui.HpHostMain))) {   # the wizard borrows these from the main view
    $to = if ($in) { $p[1] } else { $p[2] }
    if ($p[0].Parent -ne $to) { $p[0].Parent.Child = $null; $to.Child = $p[0] }
  }
  Show-If $ui.Wiz $in; Show-If $ui.Main (-not $in)
  if (-not $in) { $S.wizDone = $true; return }
  for ($i = 1; $i -le 5; $i++) { Show-If $ui["W$i"] ($i -eq $step); $ui["D$i"].SetResourceReference([Windows.Shapes.Shape]::FillProperty, $(if ($i -le $step) { 'Accent' } else { 'Line2' })) }
  $ui.WizBack.Visibility = if ($step -gt 1) { 'Visible' } else { 'Hidden' }
  $ui.WizSkip.Visibility = if ($step -lt 5) { 'Visible' } else { 'Hidden' }
  $ui.WizNext.Content = switch ($step) { 1 { 'Get started' } 5 { 'Finish' } default { 'Next' } }
  $ui.WizStep.Text = "Step $step of 5"
}

function Update-Ui {
  if (-not $win -or -not $win.IsVisible) { return }
  Apply-Theme
  $online = Peer-Online; $peer = Peer-Label; $paired = [bool]$C.peer; $pairing = $S.key -and -not $paired
  $tick = [string][char]0xE73E; $wait = [string][char]0xE712

  # header
  $ui.Logo.Source = $logos[$S.iconState]
  $ui.Title.Text = if (-not $S.key) { 'Not paired' } elseif ($pairing) { 'Pairing...' } elseif ($online) { "Connected to $peer" } else { "Looking for $peer..." }
  $mouse = switch ($S.active) { 'me' { "The mouse is on this PC ($Name)." } 'peer' { "The mouse is on $(if ($paired) { $peer } else { $S.activeName })." } default { 'Waiting for Synergy to report where the mouse is.' } }
  $ui.Sub.Text = if ($C.paused) { "Paused: the monitor and sound stay as they are. $mouse" } elseif (-not $S.key) { 'Pair with your other PC to get started.' } elseif ($pairing) { 'Waiting for the other PC...' } elseif (-not $online) { "Make sure $peer is on, running DeskGlide, and on the same network (or set its address in Settings)." } else { $mouse }
  $ui.Dot.Fill = Brush $(if ($C.paused -or -not $S.key) { 'Fg2' } elseif ($online) { 'Good' } else { 'Warn' })

  # layout
  $L = Current-Layout; $lay = $L.show
  $S.layDir = if ($lay) { $lay.dir } else { '' }
  $ui.BoxMeName.Text = $Name; $ui.BoxMeTag.Text = 'This PC' + $(if ($S.active -eq 'me') { '  -  mouse' })
  $ui.BoxMe.BorderBrush = Brush 'Accent'; $ui.BoxMe.Background = Brush $(if ($S.active -eq 'me') { 'AccentSoft' } else { 'Inset' })
  Show-If $ui.BoxPeer $paired; Show-If $ui.LayEdit $paired
  if (-not $S.drag) {
    $pos = @{ left = 1, 0; right = 1, 2; up = 0, 1; down = 2, 1 }[$(if ($lay) { $lay.dir } else { 'right' })]
    [Windows.Controls.Grid]::SetRow($ui.BoxPeer, $pos[0]); [Windows.Controls.Grid]::SetColumn($ui.BoxPeer, $pos[1])
  }
  $ui.BoxPeerName.Text = $peer; $ui.BoxPeerTag.Text = $(if ($S.active -eq 'peer') { 'mouse' } elseif (-not $lay) { 'drag me' } else { '' })
  $ui.BoxPeer.Background = Brush $(if ($S.active -eq 'peer') { 'AccentSoft' } else { 'Inset' })
  $ui.BoxPeer.Cursor = [Windows.Input.Cursors]::SizeAll
  $ui.LayLabel.Text = "Where is ${peer}?"
  foreach ($d in 'Left', 'Right', 'Up', 'Down') { $ui["Lay$d"].IsChecked = $S.layDir -eq $d }
  $edge = @{ left = 'LEFT'; right = 'RIGHT'; up = 'TOP'; down = 'BOTTOM' }
  $ui.LayoutCap.Text = if (-not $paired) { 'Pair with your other PC to place its screen.' }
    elseif ($lay) { "Move the mouse off the $($edge[$lay.dir]) edge of $Name to reach $peer." }
    else { "Drag $peer's screen to the side of this PC where it sits, or pick a side below." }
  $differs = $L.own -and $L.syn -and $L.syn.dir -ne $L.own.dir
  $ui.LayoutMsg.Text = if ($differs) { "Synergy's layout differs; DeskGlide will apply its own layout when keyboard/mouse sharing moves into DeskGlide." } else { '' }
  Show-If $ui.LayoutMsg $differs

  # monitor
  $ui.MonToggle.IsChecked = $C.monitor
  $ui.MeName.Text = "$Name (this PC)"; $ui.MeInput.Text = Input-Name (My-Input)
  $ui.PeerName.Text = $peer; $ui.PeerInput.Text = if ($paired) { Input-Name $S.peerInput } else { 'not paired' }
  $ui.SwitchNow.IsEnabled = [bool]$S.peerInput
  $ui.SwitchNow.ToolTip = "Show $peer on the monitor now"
  $ui.MonMsg.Text = $S.monMsg; $ui.MonMsg.Foreground = Brush $(if ($S.monErr) { 'Bad' } else { 'Fg2' }); Show-If $ui.MonMsg $S.monMsg

  # sound
  $ui.AFollow.IsChecked = $C.audio -eq 'follow'; $ui.ABoth.IsChecked = $C.audio -eq 'both'; $ui.AOff.IsChecked = $C.audio -eq 'off'
  $ui.HpMe.Content = $Name; $ui.HpPeer.Content = $peer; $ui.HpPeer.IsEnabled = $paired
  $ui.HpMe.IsChecked = $C.hp -eq $Name; $ui.HpPeer.IsChecked = $paired -and $C.hp -eq $C.peer
  $sender = if ($C.hp -eq $Name) { $peer } elseif ($paired -and $C.hp -eq $C.peer) { "this PC" } else { 'the other PC' }
  $ui.VolLabel.Text = "Volume of $sender"
  if (-not $S.volAt -and $ui.Vol.Value -ne $C.vol) { $ui.Vol.Value = $C.vol }
  $ui.VolPct.Text = "$($C.vol)%"
  $ui.AudioWhy.Text = Audio-Status $C $paired $online $S.active
  $ui.AudioDot.Fill = Brush $(if ([Dg]::SendOn -or [Dg]::RecvOn) { 'Good' } else { 'Fg2' })

  # pairing
  $waited = ((Get-Date) - $S.pairStart).TotalSeconds
  Show-If $ui.PairedBox $paired; $ui.PairedText.Text = "Paired with $peer"
  $ui.Unpair.Content = if ($S.unpairAt -and ((Get-Date) - $S.unpairAt).TotalSeconds -lt 5) { 'Click again to unpair' } else { 'Unpair' }
  Show-If $ui.PairPanel ($S.wiz -or -not $paired)
  Show-If $ui.PairChoose (-not $paired); Show-If $ui.PairIntro (-not $S.key); Show-If $ui.ShowCode (-not $S.key)
  Show-If $ui.CodeBox ($pairing -and $S.code); $ui.Code.Text = $S.code
  $ui.MyAddrs.Text = if ($S.myAddrs) { "If the other PC can't find this one, type one of these addresses there:`n$($S.myAddrs)" } else { '' }
  Show-If $ui.EntryBox (-not $S.code)
  Show-If $ui.AddrRow ($pairing -and -not $S.code -and ($waited -gt 10 -or $C.peerAddress))
  Show-If $ui.PairBusy $pairing; Show-If $ui.PairCancel $pairing
  $ui.PairMsg.Text = if ($S.pairErr) { $S.pairErr } elseif ($paired) { "$([char]0x2713)  Paired with $peer." } elseif (-not $S.key) { '' }
    elseif ($S.code) { "Type this code on the other PC. Waiting for it...$(if ($waited -gt 30) { ' Still waiting: check the code, and that Windows Firewall allows PowerShell on private networks.' })" }
    elseif ($waited -gt 10) { "Can't find the other PC on this network. If the PCs are on different networks (Tailscale, ZeroTier, a cable), type the other PC's address below." }
    else { 'Looking for the other PC...' }
  $ui.PairMsg.Foreground = Brush $(if ($S.pairErr) { 'Bad' } elseif ($paired) { 'Good' } else { 'Fg' })
  if ($S.addrErr) { $ui.PairMsg.Text = $S.addrErr; $ui.PairMsg.Foreground = Brush 'Bad' }

  # settings (text boxes are refreshed only while the user isn't typing in them)
  $ui.StartupToggle.IsChecked = Test-Path $lnk; $ui.PauseToggle.IsChecked = $C.paused
  foreach ($p in @(@('LogPath', 'synergyLog'), @('AddrSet', 'peerAddress'), @('Script', 'onSwitch'))) {
    if (-not $ui[$p[0]].IsKeyboardFocused) { $ui[$p[0]].Text = $C[$p[1]] }
  }
  $ui.RoleText.Text = if ($S.server) { "This PC is the Synergy server. Log: $($S.log)" } elseif ($C.synergyLog -and -not (Test-Path -LiteralPath $C.synergyLog)) { "This file doesn't exist." } else { "This PC is a Synergy client.$(if (-not $C.synergyLog) { " Empty means Synergy 3's log." })" }
  $ui.AddrHint.Text = if ($S.addrErr) { $S.addrErr } elseif ($C.peerAddress -and -not $S.fixedIp) { "Can't find $($C.peerAddress) yet." } else { 'Only for PCs on different networks. Filled in once connected.' }
  $ui.AddrHint.Foreground = Brush $(if ($S.addrErr) { 'Bad' } else { 'Fg2' })

  # wizard
  if ($S.wiz) {
    $ui.WizNext.IsEnabled = $S.wiz -ne 2 -or $paired
    $mi = My-Input; $pi = $S.peerInput
    $ui.WMeName.Text = "$Name (this PC)"; $ui.WMeInput.Text = if ($mi) { Input-Name $mi } else { 'waiting...' }
    $ui.WPeerName.Text = $peer; $ui.WPeerInput.Text = if ($pi) { Input-Name $pi } else { 'waiting...' }
    $ui.MeTick.Text = if ($mi) { $tick } else { $wait }; $ui.MeTick.Foreground = Brush $(if ($mi) { 'Good' } else { 'Fg2' })
    $ui.PeerTick.Text = if ($pi) { $tick } else { $wait }; $ui.PeerTick.Foreground = Brush $(if ($pi) { 'Good' } else { 'Fg2' })
    $ui.W3Msg.Text = if ($mi -and $pi) { 'Both inputs learned. The monitor now follows your mouse.' } elseif (-not $mi) { 'Move the mouse to this PC and wait a few seconds.' } else { "Now move the mouse to $peer. If the screen doesn't follow, press the monitor's input button." }
    $hpText = if ($C.hp) { "Headphones: on $(if ($C.hp -eq $Name) { 'this PC' } else { $C.hp })." } else { 'Headphones: not set. Choose them in the Sound card any time.' }
    $ui.Summary.Text = "$(if ($paired) { "Paired with $peer." } else { 'Not paired yet. Pair in the Pairing card.' })`nMonitor: this PC on $(Input-Name $mi), $peer on $(Input-Name $pi).`n$hpText"
  }
}

function Save-Shot {   # -Shot: the window as it is on screen
  $r = [Dg]::FrameRect((New-Object Windows.Interop.WindowInteropHelper $win).Handle)
  $bmp = New-Object Drawing.Bitmap $r[2], $r[3]
  $g = [Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($r[0], $r[1], 0, 0, $bmp.Size); $g.Dispose()
  $bmp.Save($Shot, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
  Say "Saved a screenshot to $Shot"
}

try {
  [void](New-Item -ItemType Directory -Force $ConfigDir)
  $C = Load-Config
  $mutex = New-Object Threading.Mutex($false, "Local\DeskGlide-$Port")   # one copy per user
  $showEvt = New-Object Threading.EventWaitHandle($false, 'AutoReset', "Local\DeskGlide-show-$Port")
  try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
  if (-not $owned) { [void]$showEvt.Set(); if ($Console) { 'DeskGlide is already running; showing its window.' }; return }
  Set-Content $logPath "DeskGlide $Version started $(Get-Date)$(if ($DryRun) { ' [dry run]' })"
  Save-Config   # writes the upgraded format
  [Dg]::AppId('DeskGlide')

  if (-not $Console) {
    $sz = [Windows.Forms.SystemInformation]::SmallIconSize.Width
    $icons = 0..3 | % { [Drawing.Icon]::FromHandle(([Dg]::DrawIcon($sz, $_)).GetHicon()) }   # ponytail: 4 HICONs, made once, never freed
    $tray = New-Object Windows.Forms.NotifyIcon
    $tray.Icon = $icons[3]; $tray.Text = 'DeskGlide'
    $menu = New-Object Windows.Forms.ContextMenuStrip
    $miOpen = Item $menu.Items 'Open DeskGlide' { Show-Window }; $miOpen.Font = New-Object Drawing.Font($miOpen.Font, [Drawing.FontStyle]::Bold)
    [void]$menu.Items.Add('-')
    $miMon = Item $menu.Items 'Monitor follows mouse' { $C.monitor = -not $C.monitor; Changed }
    $miAudio = Item $menu.Items 'Sound' {}
    $miFollow = Item $miAudio.DropDownItems 'Follow mouse' { Set-Audio 'follow' }
    $miBoth = Item $miAudio.DropDownItems 'Hear both' { Set-Audio 'both' }
    $miOff = Item $miAudio.DropDownItems 'Off' { Set-Audio 'off' }
    $miHp = Item $menu.Items 'Headphones are plugged into' {}
    $miHpMe = Item $miHp.DropDownItems $Name { Set-Hp $Name }
    $miHpPeer = Item $miHp.DropDownItems 'the other PC' { Set-Hp $C.peer }
    $miPause = Item $menu.Items 'Pause' { $C.paused = -not $C.paused; Changed }
    [void]$menu.Items.Add('-')
    [void](Item $menu.Items 'Quit' { [Windows.Forms.Application]::Exit() })
    $tray.ContextMenuStrip = $menu
    $tray.Add_MouseDoubleClick({ Show-Window })
    $tray.Add_BalloonTipClicked({ Show-Window })
    $tray.Visible = $true
    Update-Menu
  }

  Restore-Muted
  $udp = New-Object Net.Sockets.UdpClient
  $udp.Client.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Any, $Port)))
  $udp.EnableBroadcast = $true
  [void]$udp.Client.IOControl(-1744830452, [byte[]](0, 0, 0, 0), $null)   # SIO_UDP_CONNRESET off: ignore ICMP "port unreachable"
  [Dg]::StartAudio($AudioPort)
  $S.screen = if ($C.screenName) { $C.screenName } else { $Name }
  if ($C.key) { $S.key = [Convert]::FromBase64String($C.key) }
  if ($PairCode) { Set-Key $PairCode }
  Resolve-Peer
  Say "DeskGlide on $Name, control port $Port -> $PeerPort, audio port $AudioPort$(if ($DryRun) { ', dry run' })$(if ($NoBroadcast) { ', no broadcast' })."
  Detect-Role
  if (-not $S.server) { Say 'This PC is a Synergy client (no "switch from" lines in its log).' }
  Read-Layout
  if (-not $S.key) { Say 'Not paired yet: open the DeskGlide window to pair.' }

  if ($Console -and -not $ShowWindow) {
    while ($true) { try { Tick } catch { Say "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))" error }; Start-Sleep -Milliseconds 100 }
  } else {
    $timer = New-Object Windows.Forms.Timer; $timer.Interval = 100
    $timer.Add_Tick({ try { Tick } catch { Say "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))" error } })
    $timer.Start()
    if ($ShowWindow -or -not $S.key) { Show-Window }   # first run: the setup wizard
    [Windows.Forms.Application]::Run()
  }
} catch {
  $msg = "DeskGlide stopped: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
  try { Add-Content -LiteralPath $logPath $msg } catch {}
  if ($Console) { throw } else { [void][Windows.Forms.MessageBox]::Show($msg, 'DeskGlide', 'OK', 'Error') }
} finally {
  [Dg]::SendOn = $false; [Dg]::RecvOn = $false
  if ([Dg]::Muted.Count) { [Dg]::MuteOthers($false, $PID) }
  Save-Muted
  if ($tray) { $tray.Visible = $false; $tray.Dispose() }
}
