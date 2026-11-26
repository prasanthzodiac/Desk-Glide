# DeskGlide: two PCs, one monitor, one keyboard and mouse (shared by Synergy for now), one pair of headphones.
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
  [string]$DataDir = "$env:LOCALAPPDATA\DeskGlide",   # the installed app
  [string]$Name = $env:COMPUTERNAME,
  [switch]$NoBroadcast,                   # find the peer by address only
  [string]$DropDir = "$env:USERPROFILE\Downloads\DeskGlide",   # where files from the other PC are saved
  [string]$Theme,                         # 'light' or 'dark' instead of the Windows setting
  [string]$Shot                           # save a screenshot of the window to this .png, then quit
)
$ErrorActionPreference = 'Stop'
$Version = '4.0'
$Proto = 4   # 'ver' in the state message; DeskGlide 3 sends none, so new features stay off with it
$UpdateRepo = ''   # 'owner/repo' on GitHub for auto-update; empty = no update checks
if (-not $PeerPort) { $PeerPort = $Port }
Add-Type -Path "$PSScriptRoot\DeskGlide.cs" -ReferencedAssemblies System.Drawing, System.Core, System.IO.Compression, System.IO.Compression.FileSystem, System.Windows.Forms
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, PresentationFramework, PresentationCore, WindowsBase, WindowsFormsIntegration, System.Security
$cfgPath   = Join-Path $ConfigDir 'config.json'
$mutedPath = Join-Path $ConfigDir 'muted.txt'   # apps we muted, so a crash or kill doesn't leave them muted
$logPath   = Join-Path $ConfigDir 'deskglide.log'
$icoPath   = Join-Path $PSScriptRoot 'DeskGlide.ico'
$lnk       = Join-Path ([Environment]::GetFolderPath('Startup')) 'DeskGlide.lnk'
$opp       = @{ left = 'right'; right = 'left'; up = 'down'; down = 'up' }

# DeskGlide runs from its own copy in $appDir, so the downloaded folder can be moved or deleted and updates have one place to go
$appDir   = Join-Path $DataDir 'app'
$appFiles = 'DeskGlide.ps1', 'DeskGlide.cs', 'DeskGlide.ico', 'README.md', 'LICENSE', 'Install.cmd', 'Uninstall.cmd'
function Arg-Line([string]$ps1) { "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ps1`"" }
function Copy-App([string]$from, [string]$to) {   # DeskGlide's own files only (no .git, docs or settings); returns the copies
  [void](New-Item -ItemType Directory -Force $to)
  foreach ($f in $appFiles) { $src = Join-Path $from $f; if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src (Join-Path $to $f) -Force; Join-Path $to $f } }
}

function Now-Ms { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
function To-Hash($o) {   # a JSON object { "MSI4CE8": 15 } -> @{ MSI4CE8 = 15 }
  $h = @{}; if ($o -is [hashtable]) { foreach ($k in $o.Keys) { $h[$k] = [int]$o[$k] } } elseif ($o) { $o.psobject.Properties | % { $h[$_.Name] = [int]$_.Value } }; $h
}
function Load-Config {
  $c = @{ peer = ''; key = ''; peerAddress = ''; input = 0; inputOverride = 0; monitor = $true; audio = 'follow'; hp = ''; vol = 100
          paused = $false; syncAt = 0; synergyLog = ''; screenName = ''; onSwitch = ''; layout = $null
          kmHost = ''; inputs = @{}; monOff = @(); detach = $false
          hotkeyPeer = 'Ctrl+Alt+Right'; hotkeyMe = 'Ctrl+Alt+Left'; files = $true; fileLimitMB = 2048; mic = 'off'; updateAt = 0 }
  if (Test-Path $cfgPath) { (Get-Content $cfgPath -Raw | ConvertFrom-Json).psobject.Properties | % { $c[$_.Name] = $_.Value } }
  $c.inputs = To-Hash $c.inputs; $c.monOff = @($c.monOff | ? { $_ })
  if ($c.Contains('headphones')) {   # DeskGlide 2 had a per-PC flag; now it's one shared value: the name of the PC with the headphones
    if ($c.headphones -and -not $c.hp) { $c.hp = $Name; $c.syncAt = Now-Ms }   # newest, so the other PC takes it instead of clearing it
    $c.Remove('headphones')
  }
  $c.key = Unprotect-Key $c.key   # DeskGlide 3 stored it in plain text: the next Save-Config protects it
  if (-not $c.key) { $c.peer = '' }   # no readable key (copied from another user or PC): pair again
  $c
}
function Save-Config {   # the pairing key goes to disk only encrypted for this Windows user (DPAPI)
  [void](New-Item -ItemType Directory -Force $ConfigDir)
  $o = $C.Clone(); $o.key = Protect-Key $C.key
  $o | ConvertTo-Json | Set-Content $cfgPath -Encoding UTF8
}
# The pairing key (base64) <-> 'dpapi:<base64 blob>' in config.json, readable only by this Windows user on this PC.
$dpapiExtra = [Text.Encoding]::UTF8.GetBytes('DeskGlide pairing key')
function Protect-Key([string]$b64) {
  if (-not $b64) { return '' }
  'dpapi:' + [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($b64), $dpapiExtra, 'CurrentUser'))
}
function Unprotect-Key([string]$s) {   # '' if it can't be read (another user or PC): DeskGlide then asks to pair again
  if ($s -notlike 'dpapi:*') { return $s }
  try { [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($s.Substring(6)), $dpapiExtra, 'CurrentUser')) } catch { '' }
}

# Screen name in the last Synergy 'switch from "A" to "B"' line, or $null.
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

# 'section: links' of a Synergy server config -> { from, dir, to } objects. Everything else is ignored.
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
  if ($m.kh -and -not $cfg.kmHost) { $cfg.kmHost = [string]$m.kh; $took = $true }   # same for the keyboard PC (the Synergy server's guess)
  if ([long]$m.st -le [long]$cfg.syncAt) { return $took }
  $cfg.monitor = [bool]$m.m; $cfg.audio = [string]$m.am; $cfg.paused = [bool]$m.p; $cfg.syncAt = [long]$m.st
  if ($null -ne $m.hp) { $cfg.hp = [string]$m.hp }   # a DeskGlide 2 peer doesn't send it: keep ours, never clear it
  if ($null -ne $m.v) { $cfg.vol = [int]$m.v }
  if ($m.ly) { $cfg.layout = $m.ly }
  if ($m.kh) { $cfg.kmHost = [string]$m.kh }          # DeskGlide 4 settings: a DeskGlide 3 peer doesn't send them, keep ours
  if ($null -ne $m.mo) { $cfg.monOff = @($m.mo | ? { $_ }) }
  if ($m.mc) { $cfg.mic = [string]$m.mc }
  $true
}
# h is for DeskGlide 2 peers (it had a per-PC headphones flag); ly is DeskGlide's layout; l is Synergy's, from the server
# DeskGlide 4 adds ver, sn (screen name), kh (the PC the keyboard and mouse are plugged into),
# mi (this PC's input on each monitor), mo (monitors that don't follow the mouse) and hk/ha (a hotkey press, for 10 s:
# its time and the PC it showed), fo (files copied here: { id; n = how many; b = bytes; names }), mc (microphone mode) and
# vc (VB-Cable is installed here)
function State-Json($cfg) {
  @{ n = $Name; t = $S.t; s = $S.server; sa = ($S.active -eq 'me'); i = (My-Input); h = ($cfg.hp -eq $Name)
     m = $cfg.monitor; am = $cfg.audio; p = $cfg.paused; st = $cfg.syncAt; hp = $cfg.hp; v = $cfg.vol; ly = $cfg.layout
     l = @($(if ($S.server) { $S.links | % { "$($_.from) $($_.dir) $($_.to)" } }))
     ver = $Proto; sn = $S.screen; kh = $cfg.kmHost; mi = $cfg.inputs; mo = @($cfg.monOff)
     hk = $(if ((Now-Ms) - [long]$S.hk -lt 10000) { $S.hk } else { 0 }); ha = $S.hkTo
     fo = $(if ($cfg.files) { $S.offer } else { $null }); mc = $cfg.mic; vc = ($S.cable -ge 0) } | ConvertTo-Json -Compress -Depth 4
}
# The notice for files on the clipboard: small, so it fits in the state message; the names are only for the window
function File-Offer([string]$id, [string[]]$paths, [long]$bytes) {
  @{ id = $id; n = $paths.Count; b = $bytes; names = @($paths | select -First 3 | % { Split-Path $_ -Leaf } | % { if ($_.Length -gt 60) { $_.Substring(0, 60) } else { $_ } }) }
}
function Size-Text([long]$b) { if ($b -ge 1GB) { '{0:0.0} GB' -f ($b / 1GB) } elseif ($b -ge 1MB) { '{0:0.0} MB' -f ($b / 1MB) } else { '{0:0} KB' -f [Math]::Ceiling($b / 1KB) } }
function Offer-Text($o) {   # "report.pdf", "3 items: a, b, c", with the size
  if (-not $o) { return '' }
  $what = if ([int]$o.n -eq 1) { @($o.names)[0] } else { "$($o.n) items: $(@($o.names) -join ', ')$(if ([int]$o.n -gt @($o.names).Count) { ', ...' })" }
  "$what ($(Size-Text ([long]$o.b)))"
}

# ---------- hotkeys ----------
# 'Ctrl+Alt+Right' -> @{ text = 'Ctrl+Alt+Right'; mods; vk } for RegisterHotKey, or $null.
# At least one modifier; keys: arrows, A-Z, 0-9, F1-F24.
function Parse-Hotkey([string]$text) {
  $parts = @(($text -replace '\s', '') -split '\+' | ? { $_ })
  if ($parts.Count -lt 2) { return }
  $mods = 0; $names = @()
  foreach ($p in $parts[0..($parts.Count - 2)]) {
    $m = switch -regex ($p) { '^(ctrl|control)$' { 2, 'Ctrl' } '^alt$' { 1, 'Alt' } '^shift$' { 4, 'Shift' } '^win$' { 8, 'Win' } }
    if (-not $m -or ($mods -band $m[0])) { return }
    $mods = $mods -bor $m[0]; $names += $m[1]
  }
  $k = $parts[-1]
  $key = switch -regex ($k) {
    '^(left|right|up|down)$' { $n = $k.Substring(0, 1).ToUpper() + $k.Substring(1).ToLower(); @{ vk = @{ Left = 0x25; Up = 0x26; Right = 0x27; Down = 0x28 }[$n]; n = $n } }
    '^[a-z0-9]$' { @{ vk = [int][char]$k.ToUpper(); n = $k.ToUpper() } }
    '^f([1-9]|1\d|2[0-4])$' { @{ vk = 0x6F + [int]$matches[1]; n = $k.ToUpper() } }
  }
  if (-not $key) { return }
  @{ text = (($names + $key.n) -join '+'); mods = $mods; vk = $key.vk }
}

# ---------- monitors ----------
# The other PC's input on monitor $id: what it learned for that monitor, else its one input (DeskGlide 3, or a monitor it doesn't see)
function Peer-Input-Of($peerInputs, [int]$peerInput, [string]$id) { if ($peerInputs -and $peerInputs[$id]) { [int]$peerInputs[$id] } else { $peerInput } }
# The monitors to switch to the other PC, each with the input to switch to; skips unchecked monitors and unknown inputs
function Switch-Plan($mons, $off, $peerInputs, [int]$peerInput) {
  foreach ($m in $mons) {
    if (@($off) -contains $m.id) { continue }
    $to = Peer-Input-Of $peerInputs $peerInput $m.id
    if ($to) { @{ id = $m.id; to = $to; path = $m.path; name = $m.name } }
  }
}

# ---------- GitHub releases (auto-update) ----------
# The release asset whose name matches $pattern, e.g. 'DeskGlide-*.zip'
function Pick-Asset($release, [string]$pattern) { @($release.assets | ? { $_.name -like $pattern })[0] }
# GitHub's asset digest 'sha256:<hex>' -> lowercase hex, or $null
function Parse-Digest([string]$d) { if ($d -match '^sha256:([0-9a-fA-F]{64})$') { $matches[1].ToLower() } }

# A release tag ('v4.1') if it is newer than $current, else $null
function Newer-Version([string]$tag, [string]$current) {
  $t = $tag -replace '^[vV]', ''; $v = $null; $c = $null
  if ([version]::TryParse($t, [ref]$v) -and [version]::TryParse($current, [ref]$c) -and $v -gt $c) { $t }
}
# The updater DeskGlide leaves behind when it exits for an update: waits for it, swaps the files (rolls back if a copy
# fails), unblocks them and starts DeskGlide again. -Files is comma-separated (powershell -File can't pass arrays).
$updaterText = @'
param([int]$Wait, [string]$From, [string]$To, [string]$Files, [switch]$NoStart)
try { Wait-Process -Id $Wait -Timeout 30 -ErrorAction Stop } catch {}
$bak = Join-Path $To '.previous'; [void](New-Item -ItemType Directory -Force $bak)
$names = $Files -split ','
try {
  foreach ($f in $names) {
    $src = Get-ChildItem -LiteralPath $From -Recurse -File -Filter $f | select -First 1
    if (-not $src) { continue }
    if (Test-Path -LiteralPath (Join-Path $To $f)) { Copy-Item -LiteralPath (Join-Path $To $f) (Join-Path $bak $f) -Force }
    Copy-Item -LiteralPath $src.FullName (Join-Path $To $f) -Force; Unblock-File -LiteralPath (Join-Path $To $f)
  }
} catch {
  foreach ($f in $names) { if (Test-Path -LiteralPath (Join-Path $bak $f)) { Copy-Item -LiteralPath (Join-Path $bak $f) (Join-Path $To $f) -Force } }
}
if (-not $NoStart) { Start-Process "$PSHOME\powershell.exe" "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$(Join-Path $To 'DeskGlide.ps1')`" -ShowWindow" -WindowStyle Hidden }
'@

# ---------- edges, for DeskGlide Link (keyboard and mouse sharing, next version) ----------
# The edges between the keyboard PC ($server) and the other one, from DeskGlide's layout, in Synergy's 'links' format:
# the other PC is on the $dir side of the keyboard PC. Parse-Links reads it back.
function Edge-Links([string]$server, [string]$client, [string]$dir) {
  "section: links`n`t${server}:`n`t`t$dir = $client`n`t${client}:`n`t`t$($opp[$dir]) = $server`nend`n"
}
# Why sound is or isn't playing, in plain words.
function Audio-Status($cfg, [bool]$paired, [bool]$online, [string]$active, [int]$peerVer = 4) {
  $peer = $cfg.peer
  if (-not $paired) { return 'Off: pair with your other PC first.' }
  if ($cfg.paused) { return 'Off while DeskGlide is paused.' }
  if ($cfg.audio -eq 'off') { return 'Off. Choose Follow mouse or Hear both to hear the other PC.' }
  $here = $cfg.hp -eq $Name; $there = $cfg.hp -and $cfg.hp -eq $peer
  if (-not $here -and -not $there) { return 'Off: choose which PC your headphones are plugged into.' }
  if (-not $online) { return "Off: waiting for $peer to connect." }
  if ($peerVer -lt 4) { return "Off: update DeskGlide on $peer. Sound is encrypted now, and DeskGlide 3 can't decrypt it." }
  if ($here) {
    if ($cfg.audio -eq 'both') { return "You hear this PC and $peer together." }
    if ($active -eq 'peer') { return "You hear $peer. This PC's apps are muted until the mouse comes back." }
    return "You hear this PC. $peer plays when the mouse moves to it."
  }
  if ($cfg.audio -eq 'both') { return "This PC's sound plays in the headphones on $peer." }
  "This PC's sound plays in the headphones on $peer while the mouse is here."
}

# What this PC's audio threads do: send and recv are 0, Sound (1) or Mic (2); dev is the waveOut device to play into (-1 = default).
# The headphones PC receives the other PC's sound and sends its microphone; the other PC sends sound and plays the mic into VB-Cable.
function Audio-Modes($cfg, [bool]$online, [string]$active, [int]$peerVer, [bool]$peerCable, [int]$cable) {
  $here = $cfg.hp -eq $Name; $there = $cfg.hp -and $cfg.hp -eq $cfg.peer
  $sound = $online -and $cfg.audio -ne 'off' -and -not $cfg.paused -and $peerVer -ge 4   # sound is encrypted since DeskGlide 4
  $mic = $online -and $cfg.mic -ne 'off' -and -not $cfg.paused -and $peerVer -ge 4
  $o = @{ send = 0; recv = 0; dev = -1 }
  if ($here) {
    if ($sound) { $o.recv = 1 }
    if ($mic -and $peerCable -and ($cfg.mic -eq 'always' -or $active -eq 'peer')) { $o.send = 2 }   # follow: only while the other PC has the mouse
  } elseif ($there) {
    if ($sound) { $o.send = 1 }
    if ($mic -and $cable -ge 0) { $o.recv = 2; $o.dev = $cable }
  }
  $o
}
# Why the microphone is or isn't shared, in plain words.
function Mic-Status($cfg, [bool]$paired, [bool]$online, [string]$active, [int]$peerVer, [bool]$peerCable, [int]$cable) {
  $peer = $cfg.peer
  if (-not $paired) { return 'Off: pair with your other PC first.' }
  if ($cfg.mic -eq 'off') { return 'Off. Choose Follow mouse or Always to use your headset microphone on both PCs.' }
  if ($cfg.paused) { return 'Off while DeskGlide is paused.' }
  $here = $cfg.hp -eq $Name; $there = $cfg.hp -and $cfg.hp -eq $peer
  if (-not $here -and -not $there) { return 'Off: choose which PC your headphones are plugged into (Sound card). The microphone comes from that PC.' }
  if ($there -and $cable -lt 0) { return "Off: install VB-Audio Virtual Cable on this PC to use the microphone of $peer here." }
  if (-not $online) { return "Off: waiting for $peer to connect." }
  if ($peerVer -lt 4) { return "Off: update DeskGlide on $peer to share the microphone." }
  if ($here -and -not $peerCable) { return "Off: install VB-Audio Virtual Cable on $peer. DeskGlide plays your microphone into it there." }
  if ($here) { if ($cfg.mic -eq 'always' -or $active -eq 'peer') { return "Your microphone goes to $peer. Apps there use CABLE Output as their microphone." } else { return "Your microphone stays here. It goes to $peer while the mouse is there." } }
  "The microphone of $peer plays into CABLE Input here. In your apps, choose CABLE Output as the microphone$(if ($cfg.mic -eq 'follow') { '. It is live while the mouse is here' })."
}

$S = @{ key = $null; server = $false; log = ''; pos = 0; screen = ''; active = $null; activeName = ''; want = $null; wantName = ''
        since = [DateTime]::MinValue; activeSince = Get-Date; inputOk = $false; readAt = [DateTime]::MinValue
        peerAddr = $null; peerSeen = [DateTime]::MinValue; peerInput = 0; peerLinks = @(); lastT = 0; t = [long]0
        lastSend = [DateTime]::MinValue; roleAt = Get-Date; n = 0; okCtl = 0; badCtl = 0; statAt = Get-Date
        lastErr = ''; lastErrAt = [DateTime]::MinValue; savedMuted = ''; told = @{}
        fixedIp = $null; fixedSeen = [DateTime]::MinValue; verify = $null; monMsg = ''; monErr = $false
        links = @(); confPath = ''; confTime = $null; layDir = ''; drag = $null
        code = ''; myAddrs = ''; pairStart = Get-Date; pairErr = ''; addrErr = ''; unpairAt = $null; volAt = $null
        wiz = 0; wizDone = $false; iconState = 3; dark = $null; shownAt = $null
        peerVer = 0; peerScreen = ''; upd = $null; newer = $null; updMsg = ''; startedAt = Get-Date
        cable = -1; cableAt = [DateTime]::MinValue; peerCable = $false
        offer = $null; peerOffer = $null; fetchedId = ''; pasted = ''; fileMsg = ''; fileErr = $false; fileSaved = @()
        hk = [long]0; hkTo = ''; hkSeen = [long]0; lastSa = $null; hkSig = ''; hkErr = ''; msgWin = $null
        mons = @(); monSig = ''; monRows = @{}; monAt = [DateTime]::MinValue; peerInputs = @{} }
$tray = $null; $win = $null; $ui = @{}; $icons = @(); $logos = @()

function My-Input { if ($C.inputOverride) { [int]$C.inputOverride } else { [int]$C.input } }

if ($Test) {
  function Check($ok, $what) { if (-not $ok) { throw "self-check FAILED: $what" } }
  $a = '[t] - INFO - x - [core] switch from "pc-a" to "pc-b" at 2559,478 - {}'   # Synergy 3
  $b = '[2026-01-01T12:00:00] INFO: switch from "pc-b" to "PC-A" at 1,491'        # ISO time stamps (other Synergy-compatible tools)
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

  # audio packets: encrypted (session key from a per-stream nonce, random IV each), anything else refused
  $r = 0; $ch = 0
  function Pkt($key, [int]$rate, [int]$chans, [int]$bytes) { $pcm = New-Object byte[] ([Math]::Max($bytes, 1)); for ($i = 0; $i -lt $pcm.Length; $i++) { $pcm[$i] = 0x41 }; [Dg]::MakePacket($key, $rate, $chans, 7, $pcm, $bytes) }
  $good = Pkt $k 48000 2 1152; $d = [Dg]::OpenPacket($k, $good, [ref]$r, [ref]$ch)
  Check ($d -and $r -eq 48000 -and $ch -eq 2 -and $d.Length -eq 8 + 1152 -and $d[8] -eq 0x41 -and [BitConverter]::ToUInt16($d, 6) -eq 7) 'stereo packet round trip'
  Check (-not ([Text.Encoding]::ASCII.GetString($good)).Contains('AAAAAAAA') -and $good.Length -le 16 + 8 + 1152 + [Dg]::CryptoOverhead) 'audio is encrypted, small overhead'
  Check ([Dg]::OpenPacket($k, (Pkt $k 44100 1 2), [ref]$r, [ref]$ch) -and $r -eq 44100 -and $ch -eq 1) 'mono packet round trip'
  $g2 = Pkt $k 48000 2 1152; [Dg]::NewAudioSession(); $g3 = Pkt $k 48000 2 1152
  Check ([Dg]::Hex($good[0..15]) -eq [Dg]::Hex($g2[0..15]) -and [Dg]::Hex($good[16..31]) -ne [Dg]::Hex($g2[16..31]) -and [Dg]::Hex($g3[0..15]) -ne [Dg]::Hex($good[0..15])) 'same stream nonce, new IV per packet, new nonce per stream'
  Check ([Dg]::OpenPacket($k, $g3, [ref]$r, [ref]$ch) -and [Dg]::OpenPacket($k, $good, [ref]$r, [ref]$ch)) 'receiver follows a new stream'
  foreach ($i in 3, 20, 100, ($good.Length - 1)) { $bad = [byte[]]$good.Clone(); $bad[$i] = $bad[$i] -bxor 1; Check ($null -eq [Dg]::OpenPacket($k, $bad, [ref]$r, [ref]$ch)) "tampered audio byte $i accepted" }
  Check ($null -eq [Dg]::OpenPacket($k2, (Pkt $k 48000 2 1152), [ref]$r, [ref]$ch)) 'audio with wrong key accepted'
  Check ($null -eq [Dg]::OpenPacket($k, (Pkt $k 48000 2 3), [ref]$r, [ref]$ch)) 'odd length accepted'
  Check ($null -eq [Dg]::OpenPacket($k, (Pkt $k 48000 6 12), [ref]$r, [ref]$ch)) '6 channels accepted'
  Check ($null -eq [Dg]::OpenPacket($k, (Pkt $k 1 2 4), [ref]$r, [ref]$ch)) 'bad sample rate accepted'
  Check ($null -eq [Dg]::OpenPacket($k, [byte[]](1, 2, 3), [ref]$r, [ref]$ch)) 'short packet accepted'
  $old = New-Object byte[] (8 + 1152 + 8); [BitConverter]::GetBytes(48000).CopyTo($old, 0); $old[4] = 2
  Check ($null -eq [Dg]::OpenPacket($k, $old, [ref]$r, [ref]$ch)) 'DeskGlide 3 plain packet accepted'
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
  Check ((Audio-Status $q $true $true 'me' 3) -match 'update DeskGlide on PC-B') 'reason: DeskGlide 3 peer'
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

  # release asset and digest (auto-update)
  $rel = '{"tag_name":"v4.1","assets":[{"name":"SHA256SUMS.txt","digest":"sha256:86D9A02F9F2F747023DE7F9808065BF4D7F922FFDE67C7308061A5865D367AC2"},{"name":"DeskGlide-4.1.zip","digest":"sha256:8d19004cc3625623489d96580c1b58fd13ee78185689907fd4478595f93fab9a"}]}' | ConvertFrom-Json
  Check ((Pick-Asset $rel 'DeskGlide-*.zip').name -eq 'DeskGlide-4.1.zip' -and $null -eq (Pick-Asset $rel 'Other-*.zip')) 'asset by name'
  Check ((Parse-Digest (Pick-Asset $rel 'SHA256SUMS.txt').digest) -eq '86d9a02f9f2f747023de7f9808065bf4d7f922ffde67c7308061a5865d367ac2') 'digest: lowercased'
  Check ($null -eq (Parse-Digest '') -and $null -eq (Parse-Digest 'sha512:abcd') -and $null -eq (Parse-Digest 'sha256:xyz') -and $null -eq (Parse-Digest "sha256:$('a' * 63)")) 'digest: rejects'
  Check ((Newer-Version 'v4.1' '4.0') -eq '4.1' -and (Newer-Version '4.0.1' '4.0') -eq '4.0.1' -and $null -eq (Newer-Version 'v4.0' '4.0') -and $null -eq (Newer-Version 'v3.9' '4.0') -and $null -eq (Newer-Version 'nightly' '4.0')) 'newer version'

  # update: download, SHA256 check and extract (file:// so it runs offline), then the updater swaps the files
  $ut = Join-Path $env:TEMP "dg-update-$PID"; [void](New-Item -ItemType Directory -Force "$ut\pkg\DeskGlide-4.1", "$ut\app")
  Set-Content "$ut\pkg\DeskGlide-4.1\DeskGlide.ps1" 'new ps1'; Set-Content "$ut\pkg\DeskGlide-4.1\DeskGlide.cs" 'new cs'
  Set-Content "$ut\app\DeskGlide.ps1" 'old ps1'; Set-Content "$ut\app\DeskGlide.cs" 'old cs'; Set-Content "$ut\app\README.md" 'old readme'
  [IO.Compression.ZipFile]::CreateFromDirectory("$ut\pkg", "$ut\rel.zip"); $sha = (Get-FileHash "$ut\rel.zip" -Algorithm SHA256).Hash.ToLower()
  function Fetch($sha256) { $j = [Job]::Start(([Uri]"$ut\rel.zip").AbsoluteUri, "$ut\dl.zip", $sha256, "$ut\staged"); $t0 = Get-Date; while (-not $j.Status -and ((Get-Date) - $t0).TotalSeconds -lt 10) { Start-Sleep -Milliseconds 50 }; $j.Status }
  Check ((Fetch ('0' * 64)) -match 'SHA256 doesn.t match' -and -not (Test-Path "$ut\dl.zip") -and -not (Test-Path "$ut\staged")) 'download with the wrong SHA256 kept'
  Check ((Fetch $sha) -eq 'ok' -and (Test-Path "$ut\staged\DeskGlide-4.1\DeskGlide.ps1") -and -not (Test-Path "$ut\staged.part")) 'download, check, extract'
  [IO.File]::WriteAllText("$ut\update.ps1", $updaterText)
  & "$ut\update.ps1" -Wait 2147483646 -From "$ut\staged" -To "$ut\app" -Files ($appFiles -join ',') -NoStart
  Check ((Get-Content "$ut\app\DeskGlide.ps1") -eq 'new ps1' -and (Get-Content "$ut\app\DeskGlide.cs") -eq 'new cs' -and (Get-Content "$ut\app\README.md") -eq 'old readme' -and (Get-Content "$ut\app\.previous\DeskGlide.ps1") -eq 'old ps1') 'updater: new files in, old kept in .previous'
  Remove-Item -Recurse -Force $ut

  # edges from DeskGlide's layout (for DeskGlide Link), and the keyboard PC choice, synced
  $edges = Edge-Links 'DESK-PC' 'LAPTOP' 'left'
  Check ($edges -match "DESK-PC:\n\t\tleft = LAPTOP\n" -and $edges -match "LAPTOP:\n\t\tright = DESK-PC\n") 'edges: both ways'
  $back = @(Parse-Links $edges); Check ($back.Count -eq 2 -and (Layout-Of $back 'DESK-PC').dir -eq 'left' -and (Layout-Of $back 'LAPTOP').dir -eq 'right') 'edges: read back as the same layout'
  $PA = @{ peer = 'PC-B'; hp = ''; monitor = $true; audio = 'follow'; paused = $false; vol = 100; syncAt = 5; input = 15; inputOverride = 0; layout = $null; kmHost = '' }
  $PB = $PA.Clone(); $PB.peer = 'PC-A'; $PA.kmHost = 'PC-A'
  Check ((Merge-Settings $PB (Msg $PA 'PC-A')) -and $PB.kmHost -eq 'PC-A' -and $PB.syncAt -eq 5) 'keyboard PC: first one set is taken'
  $PB.kmHost = 'PC-B'; $PB.syncAt = 50
  Check ((Merge-Settings $PA (Msg $PB 'PC-B')) -and $PA.kmHost -eq 'PC-B') 'keyboard PC synced'
  $v3 = Msg $PA 'PC-A'; 'ver', 'kh', 'sn', 'mi', 'mo' | % { $v3.psobject.Properties.Remove($_) }; $v3.st = 99
  Check ((Merge-Settings $PB $v3) -and $PB.kmHost -eq 'PC-B') 'DeskGlide 3 message cleared the keyboard PC'
  Check ((Msg $PA 'PC-A').ver -eq 4) 'state message has ver 4'

  # hotkeys: RegisterHotKey values
  $k = Parse-Hotkey 'Ctrl+Alt+Right'; Check ($k.mods -eq 3 -and $k.vk -eq 0x27 -and $k.text -eq 'Ctrl+Alt+Right') 'hotkey: default'
  $k = Parse-Hotkey ' control + shift + left '; Check ($k.mods -eq 6 -and $k.vk -eq 0x25 -and $k.text -eq 'Ctrl+Shift+Left') 'hotkey: spaces and case'
  $k = Parse-Hotkey 'Win+Alt+k'; Check ($k.mods -eq 9 -and $k.vk -eq 0x4B -and $k.text -eq 'Win+Alt+K') 'hotkey: letter'
  $k = Parse-Hotkey 'Ctrl+F12'; Check ($k.vk -eq 0x7B -and $k.text -eq 'Ctrl+F12') 'hotkey: F12'
  Check ((Parse-Hotkey 'Alt+F24').vk -eq 0x87 -and (Parse-Hotkey 'Ctrl+7').vk -eq 0x37) 'hotkey: F24 and digits'
  Check ($null -eq (Parse-Hotkey 'Right') -and $null -eq (Parse-Hotkey 'Ctrl+Ctrl+Right') -and $null -eq (Parse-Hotkey 'Ctrl+Alt+PgUp') -and $null -eq (Parse-Hotkey 'Hyper+Right') -and $null -eq (Parse-Hotkey 'Ctrl+F25') -and $null -eq (Parse-Hotkey '')) 'hotkey: rejects'
  $PA.hkTo = ''; $S.hk = Now-Ms; $S.hkTo = 'PC-B'; $hm = Msg $PA 'PC-A'
  Check ($hm.hk -eq $S.hk -and $hm.ha -eq 'PC-B') 'hotkey press in the state message'
  $S.hk = (Now-Ms) - 20000; Check ((Msg $PA 'PC-A').hk -eq 0) 'old hotkey press not resent'
  $S.hk = 0; $S.hkTo = ''

  # microphone: who sends and plays what, and why not
  $Name = 'PC-A'; $q = @{ peer = 'PC-B'; hp = 'PC-A'; audio = 'follow'; mic = 'follow'; paused = $false }
  $m = Audio-Modes $q $true 'me' 4 $true -1; Check ($m.recv -eq 1 -and $m.send -eq 0) 'headphones PC, mouse here: sound in, mic stays'
  $m = Audio-Modes $q $true 'peer' 4 $true -1; Check ($m.recv -eq 1 -and $m.send -eq 2) 'headphones PC, mouse there: mic goes'
  $m = Audio-Modes $q $true 'peer' 4 $false -1; Check ($m.send -eq 0) 'mic sent although the other PC has no VB-Cable'
  $m = Audio-Modes $q $true 'peer' 3 $true -1; Check ($m.send -eq 0 -and $m.recv -eq 0) 'sound or mic with DeskGlide 3 (it can''t decrypt)'
  $q.mic = 'always'; $m = Audio-Modes $q $true 'me' 4 $true -1; Check ($m.send -eq 2) 'mic always'
  $q.hp = 'PC-B'; $m = Audio-Modes $q $true 'me' 4 $false 3; Check ($m.send -eq 1 -and $m.recv -eq 2 -and $m.dev -eq 3) 'other PC: sound out, mic into CABLE Input'
  $m = Audio-Modes $q $true 'me' 4 $false -1; Check ($m.send -eq 1 -and $m.recv -eq 0) 'mic played without VB-Cable'
  $q.audio = 'off'; $q.mic = 'off'; $m = Audio-Modes $q $true 'me' 4 $true 3; Check ($m.send -eq 0 -and $m.recv -eq 0) 'all off'
  $q.mic = 'follow'; $q.paused = $true; Check ((Audio-Modes $q $true 'me' 4 $true 3).recv -eq 0 -and (Mic-Status $q $true $true 'me' 4 $true 3) -match 'paused') 'paused'
  $q.paused = $false
  Check ((Mic-Status $q $true $true 'me' 4 $false -1) -match 'install VB-Audio Virtual Cable on this PC') 'mic: VB-Cable missing here'
  $q.hp = 'PC-A'; Check ((Mic-Status $q $true $true 'me' 4 $false -1) -match 'install VB-Audio Virtual Cable on PC-B') 'mic: VB-Cable missing there'
  Check ((Mic-Status $q $true $true 'me' 4 $true -1) -match 'stays here') -and ((Mic-Status $q $true $true 'peer' 4 $true -1) -match 'goes to PC-B') 'mic: follow'
  Check ((Mic-Status $q $true $true 'me' 3 $true -1) -match 'update DeskGlide') 'mic: DeskGlide 3 peer'
  $PA.mic = 'off'; $PB.mic = 'always'; $PB.syncAt = 400; Check ((Merge-Settings $PA (Msg $PB 'PC-B')) -and $PA.mic -eq 'always') 'mic mode synced'
  $S.cable = 2; Check ((Msg $PA 'PC-A').vc -eq $true) 'VB-Cable flag sent'; $S.cable = -1

  # encryption: AES-CBC + HMAC round trip, and anything changed or the wrong key is refused
  $pk = [Dg]::DeriveKey('abcd-efgh'); $sk = [Dg]::SessionKey($k2, 'audio', [byte[]](1..16)); $ad = [byte[]](7, 7)
  Check ($sk.Length -eq 32 -and [Dg]::Hex($sk) -ne [Dg]::Hex([Dg]::SessionKey($k2, 'audio', [byte[]](2..17))) -and [Dg]::Hex($sk) -ne [Dg]::Hex([Dg]::SessionKey($k2, 'files', [byte[]](1..16)))) 'session keys differ per nonce and purpose'
  $plain = [Text.Encoding]::UTF8.GetBytes('hello, other PC'); $e1 = [Dg]::Encrypt($sk, $ad, $plain, 0, $plain.Length); $e2 = [Dg]::Encrypt($sk, $ad, $plain, 0, $plain.Length)
  Check ([Text.Encoding]::UTF8.GetString([Dg]::Decrypt($sk, $ad, $e1, 0, $e1.Length)) -eq 'hello, other PC' -and $e1.Length -eq 16 + 16 + 16) 'encrypt/decrypt round trip'
  Check ([Dg]::Hex($e1) -ne [Dg]::Hex($e2) -and -not ([Text.Encoding]::ASCII.GetString($e1)).Contains('hello')) 'random IV, no plain text'
  foreach ($i in 0, 20, ($e1.Length - 1)) { $t = [byte[]]$e1.Clone(); $t[$i] = $t[$i] -bxor 1; Check ($null -eq [Dg]::Decrypt($sk, $ad, $t, 0, $t.Length)) "tampered byte $i accepted" }
  Check ($null -eq [Dg]::Decrypt($sk, [byte[]](7, 8), $e1, 0, $e1.Length) -and $null -eq [Dg]::Decrypt($pk, $ad, $e1, 0, $e1.Length) -and $null -eq [Dg]::Decrypt($sk, $ad, $e1, 0, 40)) 'other sequence, wrong key or cut short accepted'
  $big = New-Object byte[] 70000; (New-Object Random 1).NextBytes($big); $eb = [Dg]::Encrypt($sk, $null, $big, 5, 65536)
  Check ([Dg]::Hex([Dg]::Decrypt($sk, $null, $eb, 0, $eb.Length)) -eq [Dg]::Hex($big[5..65540])) 'large block with offset'

  # files: offer message, safe names, and a real encrypted transfer over loopback TCP
  $o = File-Offer 'ab12' @('C:\x\report.pdf', 'C:\x\Photos', 'C:\x\b.txt', 'C:\x\c.txt') 3145728
  Check ($o.id -eq 'ab12' -and $o.n -eq 4 -and $o.b -eq 3145728 -and @($o.names).Count -eq 3 -and $o.names[1] -eq 'Photos') 'file offer: count, size, 3 names'
  $S.offer = $o; $PA.files = $true; $fm = Msg $PA 'PC-A'
  Check ($fm.fo.id -eq 'ab12' -and (Offer-Text $fm.fo) -eq '4 items: report.pdf, Photos, b.txt, ... (3.0 MB)') 'file offer in the state message'
  $PA.files = $false; Check ($null -eq (Msg $PA 'PC-A').fo) 'no file offer while file copy is off'
  $S.offer = $null; Check ((Offer-Text (File-Offer 'x' @('C:\a.txt') 100)) -eq 'a.txt (1 KB)') 'offer text, one file'
  $root = Join-Path $env:TEMP "dg-files-$PID"
  Check ([Files]::SafePath($root, 'dir/sub/a.txt') -eq "$root\dir\sub\a.txt") 'safe path'
  foreach ($bad in '../x', 'a/../../x', '/x', 'C:/x', 'a\b', 'a//b', 'con:', 'a/./b', '', 'x.', 'a/b ') { Check ($null -eq [Files]::SafePath($root, $bad)) "unsafe path accepted: '$bad'" }
  $src = Join-Path $root 'src'; $dst = Join-Path $root 'dst'
  [void](New-Item -ItemType Directory -Force "$src\Photos\2026\empty", $dst); [IO.File]::WriteAllBytes("$src\report.pdf", $big)
  Set-Content "$src\Photos\2026\a.txt" 'one'; Set-Content "$src\Photos\b.txt" 'two'; Set-Content "$dst\report.pdf" 'already here'
  Check ([Files]::Unique($dst, 'report.pdf') -eq "$dst\report (2).pdf" -and [Files]::Unique($dst, 'new.txt') -eq "$dst\new.txt") 'unique names'
  Check ([Files]::Measure([string[]]@("$src\report.pdf", "$src\Photos"), 1GB) -eq 70000 + 5 + 5 -and [Files]::Measure([string[]]@("$src\Photos"), 5) -eq -1) 'measure, limit'
  $fport = 47000 + $PID % 1000; [Files]::Key = $pk; [Files]::Serve($fport); [Files]::Offer([string[]]@("$src\report.pdf", "$src\Photos"))
  function Pull($key, $id, $limit) { [Files]::Fetch('127.0.0.1', $fport, $key, $id, $dst, $limit); $t0 = Get-Date; while ([Files]::Status -eq 'busy' -and ((Get-Date) - $t0).TotalSeconds -lt 15) { Start-Sleep -Milliseconds 50 }; [Files]::Status }
  Check ((Pull $k2 ([Files]::OfferId) 1GB) -match 'not paired') 'transfer with the wrong key not refused'
  Check ((Pull $pk 'other-id' 1GB) -match 'no longer offers') 'transfer of an old offer not refused'
  Check ((Pull $pk ([Files]::OfferId) 100) -match 'larger than the limit') 'receiver limit not applied'
  $st = Pull $pk ([Files]::OfferId) 1GB; $got = @([Files]::Result)
  Check ($st -eq 'ok' -and $got.Count -eq 2 -and $got[0] -eq "$dst\report (2).pdf" -and $got[1] -eq "$dst\Photos") "transfer: $st $($got -join ',')"
  Check ([Dg]::Hex([IO.File]::ReadAllBytes("$dst\report (2).pdf")) -eq [Dg]::Hex($big) -and (Get-Content "$dst\Photos\2026\a.txt") -eq 'one' -and (Test-Path "$dst\Photos\2026\empty") -and -not (Get-ChildItem $dst -Filter '.incoming*')) 'transfer: contents, empty folder, no leftovers'
  [Files]::Offer($null); Remove-Item -Recurse -Force $root

  # monitors: each PC's input per monitor, unchecked monitors stay put, DeskGlide 3 peers have one input for all
  $mons = @(@{ id = 'MSI4CE8'; path = 'p1'; name = 'MAG 275QF' }, @{ id = 'DEL4321'; path = 'p2'; name = 'DELL U2720Q' }, @{ id = 'DEL4321-2'; path = 'p3'; name = 'DELL U2720Q' })
  $pi = To-Hash ('{"MSI4CE8":17,"DEL4321":16}' | ConvertFrom-Json)
  Check ((Peer-Input-Of $pi 15 'MSI4CE8') -eq 17 -and (Peer-Input-Of $pi 15 'DEL4321-2') -eq 15 -and (Peer-Input-Of @{} 0 'X') -eq 0) 'peer input per monitor, else its one input'
  $plan = @(Switch-Plan $mons @('DEL4321') $pi 0)
  Check ($plan.Count -eq 1 -and $plan[0].id -eq 'MSI4CE8' -and $plan[0].to -eq 17 -and $plan[0].path -eq 'p1') 'plan: unchecked monitor and unknown input skipped'
  $plan = @(Switch-Plan $mons @() @{} 17)
  Check ($plan.Count -eq 3 -and -not ($plan | ? { $_.to -ne 17 })) 'plan: DeskGlide 3 peer switches every monitor to its input'
  Check (@(Switch-Plan $mons @() @{} 0).Count -eq 0) 'plan: nothing known, nothing switched'
  Check ((To-Hash $null).Count -eq 0 -and (To-Hash @{ a = '5' }).a -eq 5) 'to-hash'
  $PA.monOff = @(); $PB.monOff = @('DEL4321'); $PB.syncAt = 600
  Check ((Merge-Settings $PA (Msg $PB 'PC-B')) -and @($PA.monOff) -contains 'DEL4321') 'unchecked monitors synced'
  $v3.st = 700; Check ((Merge-Settings $PA $v3) -and @($PA.monOff) -contains 'DEL4321') 'DeskGlide 3 message cleared the unchecked monitors'

  # install: only DeskGlide's own files go into the app folder, and the shortcut runs that copy
  $to = Join-Path $env:TEMP "dg-app-$PID"; $copied = @(Copy-App $PSScriptRoot $to)
  $names = @(Get-ChildItem $to | % Name | sort)
  Check ($copied.Count -ge 6 -and ($names -join ',') -eq (($appFiles | ? { Test-Path (Join-Path $PSScriptRoot $_) } | sort) -join ',') -and (Test-Path "$to\DeskGlide.ps1") -and -not (Test-Path "$to\docs") -and -not (Test-Path "$to\.git")) "install copies the app files only: $($names -join ',')"
  Check ((Arg-Line "$to\DeskGlide.ps1") -eq "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$to\DeskGlide.ps1`"") 'startup arguments'
  Check ($appDir -eq (Join-Path $DataDir 'app')) 'app folder'
  Remove-Item -Recurse $to

  $bmp = [Dg]::DrawIcon(16, 1); Check ($bmp.GetPixel(4, 7).R -lt 60 -and $bmp.GetPixel(11, 7).R -gt 100) 'icon: this PC half highlighted'
  $bmp = [Dg]::DrawIcon(16, 2); Check ($bmp.GetPixel(4, 7).R -gt 100 -and $bmp.GetPixel(11, 7).R -lt 60) 'icon: other PC half highlighted'

  $Name = 'PC-A'; $ConfigDir = Join-Path $env:TEMP "deskglide-test-$PID"; $cfgPath = Join-Path $ConfigDir 'config.json'
  [void](New-Item -ItemType Directory -Force $ConfigDir)
  Set-Content $cfgPath '{"peer":"PC-B","key":"a2V5","input":15,"headphones":true,"syncAt":5,"audio":"both"}'
  $C = Load-Config
  Check ($C.hp -eq 'PC-A' -and $C.syncAt -gt 5 -and -not $C.Contains('headphones') -and $C.key -eq 'a2V5' -and $C.peer -eq 'PC-B' -and $C.audio -eq 'both' -and $C.vol -eq 100) 'upgrade from DeskGlide 2 (headphones here)'
  Set-Content $cfgPath '{"peer":"PC-B","key":"a2V5","headphones":false,"syncAt":5}'
  $C = Load-Config; Check ($C.hp -eq '' -and $C.syncAt -eq 5 -and $C.key -eq 'a2V5') 'upgrade from DeskGlide 2 (headphones elsewhere)'
  $C = Load-Config; $C.peer = 'PC-B'; $C.input = 17; $C.audio = 'both'; $C.hp = 'PC-B'; $C.syncAt = 1764000000000; $C.inputs = @{ MSI4CE8 = 17 }; $C.monOff = @('X'); Save-Config
  $C = Load-Config
  Check ($C.peer -eq 'PC-B' -and $C.input -eq 17 -and $C.audio -eq 'both' -and $C.hp -eq 'PC-B' -and $C.syncAt -eq 1764000000000 -and $C.monitor -eq $true -and $C.inputs.MSI4CE8 -eq 17 -and $C.inputs -is [hashtable] -and @($C.monOff).Count -eq 1) 'config round trip'
  # pairing key at rest: DPAPI-protected for this Windows user; DeskGlide 3's plain key is migrated on the next save
  $raw = Get-Content $cfgPath -Raw
  Check ($raw -match '"key":\s*"dpapi:' -and $raw -notmatch 'a2V5' -and $C.key -eq 'a2V5') 'key protected on disk, plain in memory'
  Set-Content $cfgPath '{"peer":"PC-B","key":"a2V5"}'; $C = Load-Config; Check ($C.key -eq 'a2V5') 'DeskGlide 3 plain key read'
  Save-Config; Check ((Get-Content $cfgPath -Raw) -notmatch 'a2V5' -and (Load-Config).key -eq 'a2V5') 'plain key migrated'
  Set-Content $cfgPath '{"peer":"PC-B","key":"dpapi:AAAA"}'; $u = Load-Config; Check ($u.key -eq '' -and $u.peer -eq '') 'unreadable key means unpaired, no crash'
  $C = Load-Config; $C.key = ''; Save-Config; Check ((Get-Content $cfgPath -Raw) -match '"key":\s*""') 'no key stays empty'
  Remove-Item -Recurse $ConfigDir
  'self-check ok'; return
}

function Restore-Muted {   # unmute the apps a previous run muted (crash, kill, uninstall)
  if (-not (Test-Path $mutedPath)) { return }
  Get-Content $mutedPath | % { [void][Dg]::Muted.Add($_) }
  [Dg]::MuteOthers($false, $PID); Remove-Item $mutedPath
}
function Ensure-Icon { if (-not (Test-Path $icoPath)) { [Dg]::SaveIco($icoPath, 0, [int[]](16, 24, 32, 48, 256)) } }
function Set-Startup([bool]$on, [string]$ps1 = $PSCommandPath) {
  if (-not $on) { Remove-Item $lnk -ErrorAction SilentlyContinue; return }
  Ensure-Icon
  $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
  $sc.TargetPath = "$PSHOME\powershell.exe"; $sc.Arguments = Arg-Line $ps1; $sc.WorkingDirectory = Split-Path $ps1; $sc.IconLocation = Join-Path (Split-Path $ps1) 'DeskGlide.ico'; $sc.Save()
}

if ($Install -or $Uninstall) {
  # stop running copies (also DeskGlide 1's deskglide.ps1 / deskglide-audio.ps1, which this replaces)
  Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    ? { $_.ProcessId -ne $PID -and $_.CommandLine -like '*deskglide*.ps1*' } |
    % { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Milliseconds 500
  Restore-Muted
  if ($Uninstall) {
    Set-Startup $false
    Remove-Item -LiteralPath $appDir -Recurse -Force -ErrorAction SilentlyContinue
    "DeskGlide removed. Your settings are kept in $ConfigDir"; return
  }
  $files = @(if ($PSScriptRoot -ne $appDir) { Copy-App $PSScriptRoot $appDir } else { $appFiles | % { Join-Path $appDir $_ } | ? { Test-Path $_ } })
  $files | Unblock-File   # downloaded from the internet: without this Windows asks before every start
  $app = Join-Path $appDir 'DeskGlide.ps1'
  Set-Startup $true $app
  Start-Process "$PSHOME\powershell.exe" "$(Arg-Line $app) -ShowWindow" -WindowStyle Hidden
  "DeskGlide is installed in $appDir and running. Its window is open, and its icon is in the taskbar tray."; return
}

# ---------------------------------------------------------------- the app
function Say([string]$text, [string]$kind) {   # kind: '' = log only, 'error' / 'info' = also a balloon (info: pairing succeeded, files ready)
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
    $S.peerVer = [int]$m.ver; $S.peerScreen = if ($m.sn) { [string]$m.sn } else { [string]$m.n }
    $S.peerInputs = To-Hash $m.mi; $S.peerOffer = $m.fo; $S.peerCable = [bool]$m.vc
    # remember the address for the next start; only replace it once it went quiet, so a peer on two adapters doesn't flip-flop
    if ($S.fixedIp -and $S.fixedIp.Equals($ep.Address)) { $S.fixedSeen = Get-Date }
    elseif (((Get-Date) - $S.fixedSeen).TotalSeconds -gt 10) { $C.peerAddress = "$($ep.Address)"; $S.fixedIp = $ep.Address; $S.fixedSeen = Get-Date; Save-Config }
    if ($m.s) { $S.peerLinks = @($m.l | % { $w = "$_" -split ' '; if ($w.Count -eq 3 -and $opp[$w[1]]) { [pscustomobject]@{ from = $w[0]; dir = $w[1]; to = $w[2] } } }) }
    if (Merge-Settings $C $m) { Save-Config; Update-Menu }
    # follow the server when where the mouse is changes there (not every message, so a hotkey here isn't undone by a stale one)
    if ($m.s -and -not $S.server -and [bool]$m.sa -ne $S.lastSa) { $S.lastSa = [bool]$m.sa; if ($m.sa) { Set-Active 'peer' $m.n } else { Set-Active 'me' $Name } }
    if ([long]$m.hk -gt $S.hkSeen) {   # a hotkey on the other PC
      $S.hkSeen = [long]$m.hk; $S.want = $null
      if ($m.ha -eq $Name) { Set-Active 'me' $S.screen } elseif ($m.ha) { Set-Active 'peer' $S.peerScreen }
    }
  }
}

function Set-Active($new, [string]$screen) {
  if ($new -eq $S.active) { return }
  $old = $S.active; $S.active = $new; $S.activeName = $screen; $S.activeSince = Get-Date; $S.inputOk = $false
  Say "Mouse is on $(if ($new -eq 'me') { 'this PC' } elseif ($C.peer) { $C.peer } else { $screen })."
  if ($S.server) { Send-State }   # tell the peer right away; it wakes its screen when the mouse arrives there
  if ($new -eq 'me' -and $old) { [Dg]::WakeDisplay() }   # so the monitor doesn't switch to a sleeping screen
  if ($new -eq 'me') { Reattach-Monitors; Fetch-Files }
  # The PC on screen sends the switch: many monitors ignore DDC from an input they aren't showing.
  if ($old -eq 'me' -and $new -eq 'peer' -and $C.monitor -and -not $C.paused) { Switch-Monitor }
  if ($C.onSwitch) {
    $pc = if ($new -eq 'me') { $Name } elseif ($C.peer) { $C.peer } else { $screen }
    try { Start-Process cmd.exe "/c `"$($C.onSwitch) `"$pc`"`"" -WindowStyle Hidden } catch { Say "Your switch script didn't start: $($_.Exception.Message)" error }
  }
}

function Show-Pc([string]$who) {   # hotkey: the monitor and sound go to $who ('me' or 'peer'); the mouse stays put
  if (-not $C.peer -or $C.paused) { return }
  $S.want = $null   # a pending edge crossing must not undo this
  $S.hk = Now-Ms; $S.hkTo = if ($who -eq 'me') { $Name } else { $C.peer }
  Say "Hotkey: show $($S.hkTo)."
  Set-Active $who $(if ($who -eq 'me') { $S.screen } else { $S.peerScreen })
  Send-State   # the other PC follows; if it is the one on screen, it switches the monitor to this PC
}
function Apply-Hotkeys {   # (re)registers both hotkeys; says which ones another program already has
  if (-not $S.msgWin) { return }
  $bad = @()
  foreach ($h in @(@(1, $C.hotkeyPeer), @(2, $C.hotkeyMe))) {
    $k = Parse-Hotkey $h[1]
    if (-not $k) { [void]$S.msgWin.SetHotkey($h[0], 0, 0) }
    elseif (-not $S.msgWin.SetHotkey($h[0], [uint32]$k.mods, [uint32]$k.vk)) { $bad += $k.text }
  }
  $S.hkErr = if ($bad.Count) { "$($bad -join ' and ') $(if ($bad.Count -gt 1) { 'are' } else { 'is' }) in use by another program. Choose another key." } else { '' }
  if ($bad.Count) { Say $S.hkErr }
}
function Set-HotkeyText([string]$which, [string]$text) {   # from the Settings card
  $k = Parse-Hotkey $text
  if (-not $k) { $S.hkErr = "`"$text`" isn't a hotkey DeskGlide understands. Use Ctrl, Alt, Shift or Win with an arrow, a letter, a digit or F1-F24, like Ctrl+Alt+Right."; return }
  if ($C[$which] -eq $k.text) { $S.hkErr = ''; return }
  $C[$which] = $k.text; Save-Config; Apply-Hotkeys
}
# ---------- auto-update: once a day ask GitHub for the latest release; the user clicks to install it ----------
function Poll-Update {
  if (-not $UpdateRepo) { return }
  $u = $S.upd
  if (-not $u) {   # a minute after start, then daily
    if (((Get-Date) - $S.startedAt).TotalSeconds -lt 60 -or (Now-Ms) - [long]$C.updateAt -lt 86400000) { return }
    $C.updateAt = Now-Ms; Save-Config
    $S.upd = @{ stage = 'check'; job = [Job]::Start("https://api.github.com/repos/$UpdateRepo/releases/latest", $null, $null, $null) }; return
  }
  $j = $u.job; if (-not $j -or -not $j.Status) { return }
  if ($u.stage -eq 'check') {
    $S.upd = $null
    if ($j.Status -ne 'ok') { Say "Update check failed: $($j.Status -replace '^error: ')"; return }
    $rel = $j.Text | ConvertFrom-Json; $ver = Newer-Version $rel.tag_name $Version; $a = Pick-Asset $rel 'DeskGlide-*.zip'
    if ($ver -and $a -and (Parse-Digest $a.digest)) { $S.newer = @{ ver = $ver; url = $a.browser_download_url; sha = (Parse-Digest $a.digest); page = $rel.html_url }; Say "DeskGlide $ver is available." }
    return
  }
  if ($j.Status -ne 'ok') { $S.upd = $null; $S.updMsg = "The update didn't download: $($j.Status -replace '^error: ')"; Say $S.updMsg error; return }
  # downloaded, SHA256 checked and extracted: hand over to the updater and quit
  $updater = Join-Path $DataDir 'update\update.ps1'; [IO.File]::WriteAllText($updater, $updaterText)
  Start-Process "$PSHOME\powershell.exe" "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$updater`" -Wait $PID -From `"$($u.dir)`" -To `"$PSScriptRoot`" -Files $($appFiles -join ',')" -WindowStyle Hidden
  Say "Installing DeskGlide $($S.newer.ver); it restarts in a moment."
  [Windows.Forms.Application]::Exit()
}
function Start-Update {   # the footer link
  $n = $S.newer; if (-not $n -or $S.upd) { return }
  if ($PSScriptRoot -ne $appDir) { Start-Process $n.page; return }   # not the installed copy: show the release page, Install.cmd does the rest
  $dir = Join-Path $DataDir "update\$($n.ver -replace '[^\w.-]', '')"; [void](New-Item -ItemType Directory -Force (Split-Path $dir))
  $S.updMsg = ''; $S.upd = @{ stage = 'get'; dir = $dir; job = [Job]::Start($n.url, "$dir.zip", $n.sha, $dir) }
}

# ---------- files: copy on one PC, paste on the other ----------
function Check-Clipboard {   # the clipboard changed: offer copied files to the other PC
  [MsgWin]::ClipChanged = $false
  if (-not $C.files) { return }
  $list = @(); try { if ([Windows.Forms.Clipboard]::ContainsFileDropList()) { $list = @([Windows.Forms.Clipboard]::GetFileDropList()) } } catch { return }   # busy: next change
  if (($list -join '|') -eq $S.pasted -and $list.Count) { return }   # the files DeskGlide just put there
  if (-not $list.Count) { if ($S.offer) { $S.offer = $null; [Files]::Offer($null); Send-State }; return }
  $limit = [long]$C.fileLimitMB * 1MB
  $bytes = try { [Files]::Measure([string[]]$list, $limit) } catch { -2 }
  if ($bytes -lt 0) {
    $S.offer = $null; [Files]::Offer($null); Send-State
    $S.fileErr = $true; $S.fileMsg = if ($bytes -eq -1) { "The files you copied are over the $(Size-Text $limit) limit (Settings), so they stay here." } else { "DeskGlide can't read the files you copied." }
    Say $S.fileMsg; return
  }
  [Files]::Offer([string[]]$list); $S.offer = File-Offer ([Files]::OfferId) $list $bytes
  $S.fileErr = $false; $S.fileMsg = "Copied here: $(Offer-Text $S.offer). Move the mouse to $(Peer-Label) and paste."
  Say "Offering $(Offer-Text $S.offer)"; Send-State
}
function Fetch-Files {   # the mouse arrived here: pull the other PC's copied files
  $o = $S.peerOffer
  if (-not $C.files -or -not $o -or -not $o.id -or $o.id -eq $S.fetchedId -or [Files]::Status -eq 'busy' -or -not $S.peerAddr) { return }
  $S.fetchedId = [string]$o.id; $S.fileErr = $false; $S.fileMsg = "Getting $(Offer-Text $o) from $(Peer-Label)..."
  Say "Fetching $(Offer-Text $o)"
  [Files]::Fetch("$($S.peerAddr)", $PeerPort + 1, $S.key, [string]$o.id, $DropDir, [long]$C.fileLimitMB * 1MB)
}
function Poll-Fetch {
  $st = [Files]::Status
  if ($st -eq '' -or $st -eq 'busy') { return }
  [Files]::Status = ''
  if ($st -ne 'ok') { $S.fileErr = $true; $S.fileMsg = "Couldn't get the files: $($st -replace '^error: ')"; Say $S.fileMsg error; return }
  $S.fileSaved = @([Files]::Result)
  $sc = New-Object Collections.Specialized.StringCollection; foreach ($p in $S.fileSaved) { [void]$sc.Add($p) }
  $S.pasted = $S.fileSaved -join '|'
  try { [Windows.Forms.Clipboard]::SetFileDropList($sc) } catch { Say "The files are in $DropDir, but the clipboard was busy." }
  $S.fileErr = $false; $S.fileMsg = "Ready to paste: $(($S.fileSaved | % { Split-Path $_ -Leaf }) -join ', '). Saved in $DropDir."
  Say "Files ready to paste (Ctrl+V): $(($S.fileSaved | % { Split-Path $_ -Leaf }) -join ', ')" info
}
function Refresh-Monitors {   # not while one is off the desktop: Windows doesn't list it then
  if ([Dg]::Detached) { return }
  $S.mons = @([Dg]::ListMonitors() | % { $a = $_ -split "`t"; @{ id = $a[0]; path = $a[1]; name = $(if ($a[2]) { $a[2] } else { 'Monitor' }) } })
}
function Switch-Monitor {
  $plan = @(Switch-Plan $S.mons $C.monOff $S.peerInputs $S.peerInput)
  if (-not $plan.Count) { $S.monMsg = "Can't switch yet: $(Peer-Label)'s input isn't known, or no monitor is set to switch. Show $(Peer-Label) on the monitor once."; $S.monErr = $true; Say $S.monMsg; return }
  $S.monErr = $false
  if ($DryRun) {
    foreach ($p in $plan) {
      Say "dry run: would switch $($p.name) to input $($p.to)"
      if ($C.detach) { $r = [Dg]::Detach($p.path, $true); Say "dry run: taking $($p.name) off this PC's desktop $(if ($r) { "would not work: $r" } else { 'would work' })" }
    }
    $S.monMsg = "Dry run: would switch $(($plan | % { "$($_.name) to $(Input-Name $_.to)" }) -join ', ')."; return
  }
  $done = @($plan | ? { [Dg]::SetInputOn($_.id, [uint32]$_.to) })
  $bad = @($plan | ? { $done -notcontains $_ })
  if ($done.Count) {
    Say "Monitor -> $(($done | % { "$($_.id) input $($_.to)" }) -join ', ')"; $S.monMsg = "Switched $(($done | % { "$($_.name) to $(Input-Name $_.to)" }) -join ', ')."
    foreach ($p in $done) { $p.from = [int]$C.inputs[$p.id] }
    $S.verify = @{ at = (Get-Date).AddSeconds(2); items = $done; tries = 1; active = $S.active }
  }
  if ($bad.Count) { $S.monErr = $true; $S.monMsg = "$(($bad | % name) -join ', ') did not accept the switch to $(Peer-Label)."; Say $S.monMsg error }
}
function Check-Switch {   # 2 s after a switch: did the monitors really change? retry once, then tell the user
  $v = $S.verify
  if (-not $v -or (Get-Date) -lt $v.at) { return }
  $S.verify = $null
  if ($S.active -ne $v.active) { return }   # the mouse moved again meanwhile
  # still on this PC's input; no answer counts as switched (many monitors don't answer an input they don't show)
  $stuck = @($v.items | ? { $_.from -and [Dg]::GetInputOf($_.id) -eq $_.from })
  if ($C.detach) { foreach ($p in @($v.items | ? { $stuck -notcontains $_ })) { $r = [Dg]::Detach($p.path, $false); Say "$(if ($r) { "Couldn't take $($p.name) off this PC's desktop: $r" } else { "Took $($p.name) off this PC's desktop." })" } }
  if (-not $stuck.Count) { return }
  if ($v.tries -lt 2) {
    Say "$(($stuck | % name) -join ', ') still shows this PC, trying again."
    foreach ($p in $stuck) { [void][Dg]::SetInputOn($p.id, [uint32]$p.to) }
    $v.items = $stuck; $v.at = (Get-Date).AddSeconds(2); $v.tries++; $S.verify = $v
  } else {
    $S.monErr = $true; $names = ($stuck | % name) -join ', '
    $S.monMsg = "$names didn't accept the switch to $(Peer-Label). Check that DDC/CI is on in the monitor's menu. Some monitors only accept it with the input set to manual, not auto."
    Say "$names didn't accept the switch to $(Peer-Label)." error
  }
}
function Reattach-Monitors {
  if (-not [Dg]::Detached) { return }
  $r = [Dg]::Reattach(); Say $(if ($r) { "Couldn't put the monitors back on this PC's desktop: $r. Press Win+P and choose Extend." } else { 'Put the monitors back on this PC''s desktop.' }) $(if ($r) { 'error' })
}
function Test-Monitor {   # read-only: says what would happen
  $peer = Peer-Label; Refresh-Monitors
  if (-not $S.mons.Count) { $S.monErr = $true; $S.monMsg = "Windows lists no monitor that DeskGlide can talk to."; return }
  $lines = foreach ($m in $S.mons) {
    $v = [Dg]::GetInputOf($m.id); $to = Peer-Input-Of $S.peerInputs $S.peerInput $m.id
    if ($v -lt 0) { "$($m.name) didn't answer: turn on DDC/CI in its on-screen menu."; continue }
    $line = "$($m.name) answers and shows $(Input-Name $v)$(if ($v -eq $C.inputs[$m.id]) { ' (this PC)' } elseif ($v -eq $to) { " ($peer)" })."
    if (@($C.monOff) -contains $m.id) { $line += ' It stays put when the mouse moves.' }
    elseif ($to) { $line += " When the mouse moves to $peer, it switches to $(Input-Name $to)." } else { $line += " Show $peer on it once so DeskGlide learns its input." }
    $line
  }
  $S.monErr = [bool]($lines -match "didn't answer")
  $S.monMsg = ($lines -join "`n") + $(if (-not $C.monitor) { "`nMonitor follows mouse is off, so nothing switches by itself." })
}

function Detect-Role {   # the PC whose Synergy log has "switch from" lines is the server
  $log = if ($C.synergyLog) { $C.synergyLog } else { "$env:LOCALAPPDATA\synergy-dragon\logs\synergy-dragon-agent.log" }
  if (-not (Test-Path -LiteralPath $log)) { return }
  $text, $pos = Read-Lines $log 0
  if (-not $text.Contains('switch from "')) { return }
  $S.server = $true; $S.log = $log; $S.pos = $pos
  Say "This PC is the Synergy server (log: $log)."
  if (-not $C.kmHost) { $C.kmHost = $Name; Save-Config }   # the default for "keyboard and mouse are plugged into"
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
  $hk = [MsgWin]::Pressed
  if ($hk) { [MsgWin]::Pressed = 0; Show-Pc $(if ($hk -eq 1) { 'peer' } else { 'me' }) }
  if ([MsgWin]::ClipChanged) { Check-Clipboard }
  if ($S.n++ % 5) { return }   # the rest twice a second

  $online = Peer-Online
  if (($now - $S.lastSend).TotalSeconds -ge 2) { Send-State }
  if (($now - $S.roleAt).TotalSeconds -ge 60) {
    $S.roleAt = $now
    if (-not $S.server) { Detect-Role }
    if ($C.peerAddress -and -not $S.fixedIp) { Resolve-Peer }
  }
  if ($S.n % 30 -eq 1) { Read-Layout }   # every 3 s
  Poll-Fetch; [Files]::Key = $S.key
  Poll-Update
  Check-Switch
  if ($S.volAt -and ($now - $S.volAt).TotalMilliseconds -ge 400) { $S.volAt = $null; Changed }   # slider: sync when it stops moving

  # learn this PC's monitor input while it is on screen (retry if the monitor still shows the other PC)
  if (($now - $S.monAt).TotalSeconds -ge 30) { $S.monAt = $now; Refresh-Monitors }
  if ($S.active -eq 'me' -and -not $S.inputOk -and ($now - $S.activeSince).TotalSeconds -ge 3 -and ($now - $S.readAt).TotalSeconds -ge 10) {
    $S.readAt = $now; $answered = $false; $changed = $false
    foreach ($m in $S.mons) {   # one input per monitor; a monitor still showing the other PC is asked again later
      $v = [Dg]::GetInputOf($m.id); if ($v -lt 0) { continue }
      $answered = $true
      if ($v -eq (Peer-Input-Of $S.peerInputs $S.peerInput $m.id)) { continue }
      $S.inputOk = $true
      if ($C.inputs[$m.id] -ne $v) { $C.inputs[$m.id] = $v; $changed = $true; Say "This PC is on input $v of $($m.name)." }
    }
    if (-not $answered) { Once ddc 'The monitor does not answer DDC/CI. Turn on DDC/CI in the monitor''s menu.' error }
    $first = if ($S.mons.Count) { [int]$C.inputs[$S.mons[0].id] }   # 'i' for DeskGlide 3 peers and the setup guide
    if ($first -and $first -ne $C.input) { $C.input = $first; $changed = $true }
    if ($changed) { Save-Config; Send-State }
  }
  if ($online -and (-not (My-Input) -or -not $S.peerInput)) {
    Once inputs 'Almost done: show each PC on the monitor once. Move the mouse to it and, if the screen does not follow, press the monitor''s input button.'
  }

  # audio: the PC with the headphones receives the other PC's sound and sends its microphone; the other PC the opposite
  if (($now - $S.cableAt).TotalSeconds -ge 30) { $S.cableAt = $now; $S.cable = [Dg]::FindOutput('CABLE Input') }
  $a = Audio-Modes $C $online $S.active $S.peerVer $S.peerCable $S.cable
  [Dg]::Key = $S.key
  [Dg]::Target = if ($S.peerAddr) { New-Object Net.IPEndPoint($S.peerAddr, $AudioPort) } else { $null }
  [Dg]::SendMode = $a.send; [Dg]::RecvMode = $a.recv; [Dg]::RecvDevice = $a.dev
  [Dg]::RemoteOn = $C.audio -eq 'both' -or $S.active -eq 'peer'
  [Dg]::Volume = [Math]::Max(0, [Math]::Min(100, [int]$C.vol)) / 100
  if ($a.recv -eq [Dg]::Sound -and $C.audio -eq 'follow' -and $S.active -eq 'peer') { [Dg]::MuteOthers($true, $PID) }
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
function Set-Log([string]$p) {   # the Synergy log path from the Settings card
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
            <StackPanel x:Name="MonList" Margin="0,12,0,12"/>
            <StackPanel Orientation="Horizontal">
              <Button x:Name="SwitchNow" Style="{StaticResource Primary}" Content="Switch monitor now"/>
              <Button x:Name="TestMon" Content="Test" Margin="8,0,0,0" ToolTip="Ask the monitor which input it shows. Nothing is switched."/>
            </StackPanel>
            <TextBlock x:Name="MonMsg" Style="{StaticResource Sub}" Margin="0,10,0,0"/>
          </StackPanel></Border>
        </StackPanel>

        <StackPanel Grid.Column="2">
          <Border Style="{StaticResource CardBox}"><StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,12"><TextBlock Style="{StaticResource Glyph}" Text="&#xE765;"/><TextBlock Style="{StaticResource H}" Text="Keyboard &amp; mouse"/></StackPanel>
            <TextBlock Style="{StaticResource Label}" Margin="0,0,0,5" Text="Keyboard and mouse are plugged into"/>
            <Border Style="{StaticResource InsetBox}"><UniformGrid Rows="1">
              <RadioButton x:Name="KmMe" GroupName="km" Style="{StaticResource Seg}"/>
              <RadioButton x:Name="KmPeer" GroupName="km" Style="{StaticResource Seg}"/>
            </UniformGrid></Border>
            <TextBlock Style="{StaticResource Sub}" Margin="0,10,0,0" Text="Sharing them is coming in DeskGlide Link. Until then Synergy shares them, and DeskGlide follows Synergy's log."/>
          </StackPanel></Border>
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
            <StackPanel Orientation="Horizontal" Margin="0,0,0,12"><TextBlock Style="{StaticResource Glyph}" Text="&#xE720;"/><TextBlock Style="{StaticResource H}" Text="Microphone"/></StackPanel>
            <Border Style="{StaticResource InsetBox}"><UniformGrid Rows="1">
              <RadioButton x:Name="MFollow" GroupName="mic" Style="{StaticResource Seg}" Content="Follow mouse"/>
              <RadioButton x:Name="MAlways" GroupName="mic" Style="{StaticResource Seg}" Content="Always"/>
              <RadioButton x:Name="MOff" GroupName="mic" Style="{StaticResource Seg}" Content="Off"/>
            </UniformGrid></Border>
            <TextBlock Style="{StaticResource Sub}" Margin="0,8,0,0" Text="The microphone of the headphones PC, usable in apps on the other PC."/>
            <Border Style="{StaticResource InsetBox}" Padding="12,9" Margin="0,12,0,0"><Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/></Grid.ColumnDefinitions>
              <Ellipse x:Name="MicDot" Width="8" Height="8" Margin="0,6,10,0" VerticalAlignment="Top"/>
              <TextBlock x:Name="MicWhy" Grid.Column="1" Style="{StaticResource Body}"/>
            </Grid></Border>
            <StackPanel x:Name="CableRow" Margin="0,12,0,0">
              <TextBlock Style="{StaticResource Sub}" Text="VB-Audio Virtual Cable is a free virtual microphone. Its license doesn't allow DeskGlide to include or download it, so install it yourself once (it needs a restart):"/>
              <TextBlock Style="{StaticResource Sub}" Margin="0,4,0,0"><Hyperlink x:Name="CableLink" Foreground="{DynamicResource Accent}">vb-audio.com/Cable</Hyperlink></TextBlock>
            </StackPanel>
          </StackPanel></Border>
        </StackPanel>

        <StackPanel Grid.Column="4">
          <Border Style="{StaticResource CardBox}"><StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,12"><TextBlock Style="{StaticResource Glyph}" Text="&#xE71B;"/><TextBlock Style="{StaticResource H}" Text="Pairing"/></StackPanel>
            <StackPanel x:Name="PairedBox">
              <TextBlock x:Name="PairedText" FontWeight="SemiBold"/>
              <TextBlock Style="{StaticResource Sub}" Margin="0,4,0,0" Text="Every message is signed with your pairing key, so other devices can't control DeskGlide. Sound, microphone and files are also encrypted."/>
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
          <Border Style="{StaticResource CardBox}"><StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,12"><TextBlock Style="{StaticResource Glyph}" Text="&#xE8C8;"/><TextBlock Style="{StaticResource H}" Text="Copy files"/></StackPanel>
            <CheckBox x:Name="FilesToggle" Style="{StaticResource Switch}"><StackPanel>
              <TextBlock Text="Copy and paste files between the PCs"/>
              <TextBlock Style="{StaticResource Sub}" Text="Copy files or folders, move the mouse to the other PC, press Ctrl+V. Sent encrypted."/></StackPanel></CheckBox>
            <TextBlock x:Name="FileMsg" Style="{StaticResource Body}" Margin="0,12,0,0"/>
            <ProgressBar x:Name="FileBar" Height="3" Margin="0,8,0,0" Maximum="1" Foreground="{DynamicResource Accent}" Background="{DynamicResource Inset}" BorderThickness="0"/>
            <TextBlock Style="{StaticResource Sub}" Margin="0,8,0,0"><Hyperlink x:Name="OpenDrop" Foreground="{DynamicResource Accent}">Open received files</Hyperlink></TextBlock>
          </StackPanel></Border>
          <Border Style="{StaticResource CardBox}"><StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,12"><TextBlock Style="{StaticResource Glyph}" Text="&#xE713;"/><TextBlock Style="{StaticResource H}" Text="Settings"/></StackPanel>
            <CheckBox x:Name="StartupToggle" Style="{StaticResource Switch}" Content="Start with Windows"/>
            <CheckBox x:Name="PauseToggle" Style="{StaticResource Switch}" Margin="0,12,0,0"><StackPanel>
              <TextBlock Text="Pause DeskGlide"/><TextBlock Style="{StaticResource Sub}" Text="No switching and no sound until you turn this off."/></StackPanel></CheckBox>
            <CheckBox x:Name="DetachToggle" Style="{StaticResource Switch}" Margin="0,12,0,0"><StackPanel>
              <TextBlock Text="Take switched monitors off this PC's desktop" TextWrapping="Wrap"/>
              <TextBlock Style="{StaticResource Sub}" Text="So windows and the pointer can't get lost on a monitor that shows the other PC. Off by default: Windows rearranges windows each time, and it needs another screen to stay on."/></StackPanel></CheckBox>
            <TextBlock Style="{StaticResource Label}" Text="Synergy log"/>
            <DockPanel><Button x:Name="BrowseLog" DockPanel.Dock="Right" Content="Browse..." Margin="8,0,0,0"/><TextBox x:Name="LogPath"/></DockPanel>
            <TextBlock x:Name="RoleText" Style="{StaticResource Sub}" Margin="0,4,0,0"/>
            <TextBlock Style="{StaticResource Label}" Text="Other PC's address (optional)"/>
            <TextBox x:Name="AddrSet"/>
            <TextBlock x:Name="AddrHint" Style="{StaticResource Sub}" Margin="0,4,0,0"/>
            <TextBlock Style="{StaticResource Label}" Text="Run my script when the screen switches"/>
            <TextBox x:Name="Script"/>
            <TextBlock Style="{StaticResource Sub}" Margin="0,4,0,0" Text="Optional. Gets the name of the PC that now has the mouse, for example C:\Scripts\switched.cmd"/>
            <TextBlock Style="{StaticResource Label}" Text="Hotkeys: monitor and sound, mouse stays"/>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="8"/><ColumnDefinition/></Grid.ColumnDefinitions>
              <StackPanel><TextBlock Style="{StaticResource Sub}" Text="Show the other PC"/><TextBox x:Name="HkPeer" Margin="0,4,0,0"/></StackPanel>
              <StackPanel Grid.Column="2"><TextBlock Style="{StaticResource Sub}" Text="Show this PC"/><TextBox x:Name="HkMe" Margin="0,4,0,0"/></StackPanel>
            </Grid>
            <TextBlock x:Name="HkMsg" Style="{StaticResource Sub}" Margin="0,4,0,0"/>
            <TextBlock Style="{StaticResource Label}" Text="Largest file copy, in MB"/>
            <TextBox x:Name="FileLimit"/>
          </StackPanel></Border>
        </StackPanel>
      </Grid>
    </ScrollViewer>
    <DockPanel Grid.Row="2" Margin="2,6,2,0">
      <TextBlock DockPanel.Dock="Right" FontSize="12.5"><Hyperlink x:Name="OpenLog" Foreground="{DynamicResource Accent}">Open log</Hyperlink><Run Text="     "/><Hyperlink x:Name="Help" Foreground="{DynamicResource Accent}">Help and README</Hyperlink></TextBlock>
      <TextBlock FontSize="12.5"><Run x:Name="Ver" Foreground="{DynamicResource Fg2}"/><Run Text="     "/><Hyperlink x:Name="UpdateLink" Foreground="{DynamicResource Accent}"><Run x:Name="UpdateText"/></Hyperlink></TextBlock>
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
          <TextBlock Style="{StaticResource Body}" Text="Two PCs, one monitor, one keyboard and mouse. Move the mouse off the edge of one PC's screen and everything else follows it to the other PC."/>
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
  if ($Shot) { $win.WindowStartupLocation = 'Manual'; $win.Left = -20000; $win.Top = 0; if ($S.key) { $win.Height = 1180 }; $win.ShowActivated = $false; $win.ShowInTaskbar = $false }   # drawn off screen, never takes focus

  On MonToggle Checked, Unchecked { if ($C.monitor -ne [bool]$ui.MonToggle.IsChecked) { $C.monitor = -not $C.monitor; Changed } }
  On PauseToggle Checked, Unchecked { if ($C.paused -ne [bool]$ui.PauseToggle.IsChecked) { $C.paused = -not $C.paused; Changed } }
  On DetachToggle Checked, Unchecked { if ($C.detach -ne [bool]$ui.DetachToggle.IsChecked) { $C.detach = -not $C.detach; Save-Config; if (-not $C.detach) { Reattach-Monitors } } }
  On StartupToggle Checked, Unchecked { $want = [bool]$ui.StartupToggle.IsChecked; if ((Test-Path $lnk) -ne $want) { Set-Startup $want } }
  On AFollow Checked { Set-Audio 'follow' }
  On ABoth Checked { Set-Audio 'both' }
  On AOff Checked { Set-Audio 'off' }
  On MFollow Checked { if ($C.mic -ne 'follow') { $C.mic = 'follow'; Changed } }
  On MAlways Checked { if ($C.mic -ne 'always') { $C.mic = 'always'; Changed } }
  On MOff Checked { if ($C.mic -ne 'off') { $C.mic = 'off'; Changed } }
  On CableLink Click { Start-Process 'https://vb-audio.com/Cable/' }
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
  On BrowseLog Click { $f = Browse 'Choose the Synergy log file' 'Log files|*.log;*.txt|All files|*.*' "$env:LOCALAPPDATA\synergy-dragon\logs"; if ($f) { Set-Log $f } }
  On Script LostFocus { $C.onSwitch = $ui.Script.Text.Trim(); Save-Config }
  On FilesToggle Checked, Unchecked { if ($C.files -ne [bool]$ui.FilesToggle.IsChecked) { $C.files = -not $C.files; Save-Config; if (-not $C.files) { $S.offer = $null; [Files]::Offer($null) }; Send-State } }
  On OpenDrop Click { [void](New-Item -ItemType Directory -Force $DropDir); Start-Process explorer.exe "`"$DropDir`"" }
  On FileLimit LostFocus { $n = 0; if ([int]::TryParse($ui.FileLimit.Text.Trim(), [ref]$n) -and $n -ge 1 -and $n -le 1048576) { $C.fileLimitMB = $n; Save-Config } }
  On HkPeer LostFocus { Set-HotkeyText 'hotkeyPeer' $ui.HkPeer.Text }
  On HkMe LostFocus { Set-HotkeyText 'hotkeyMe' $ui.HkMe.Text }
  On HkPeer KeyDown { if ($args[1].Key -eq 'Return') { Set-HotkeyText 'hotkeyPeer' $ui.HkPeer.Text } }
  On HkMe KeyDown { if ($args[1].Key -eq 'Return') { Set-HotkeyText 'hotkeyMe' $ui.HkMe.Text } }
  On OpenLog Click { Start-Process notepad.exe "`"$logPath`"" }
  On UpdateLink Click { Start-Update }
  On LayLeft Checked { Set-Layout 'left' }
  On LayRight Checked { Set-Layout 'right' }
  On LayUp Checked { Set-Layout 'up' }
  On LayDown Checked { Set-Layout 'down' }
  On Help Click { $md = Join-Path $PSScriptRoot 'README.md'; if (Test-Path 'Registry::HKEY_CLASSES_ROOT\.md') { Start-Process $md } else { Start-Process notepad.exe "`"$md`"" } }
  On KmMe Checked { if ($C.kmHost -ne $Name) { $C.kmHost = $Name; Changed } }
  On KmPeer Checked { if ($C.peer -and $C.kmHost -ne $C.peer) { $C.kmHost = $C.peer; Changed } }
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

function Build-MonRows {   # one row per monitor in the Monitor card, rebuilt when the monitors change
  $sig = ($S.mons | % { "$($_.id)=$($_.name)" }) -join ','
  if ($sig -eq $S.monSig) { return }
  $S.monSig = $sig; $ui.MonList.Children.Clear(); $S.monRows = @{}
  function El($type, $style) { $e = New-Object "Windows.Controls.$type"; if ($style) { $e.SetResourceReference([Windows.FrameworkElement]::StyleProperty, $style) }; $e }
  foreach ($m in $S.mons) {
    $box = El Border 'InsetBox'; $box.Padding = '12,10'; $box.Margin = '0,0,0,8'
    $sp = El StackPanel; $box.Child = $sp
    $cb = El CheckBox 'Switch'; $cb.Tag = $m.id; $cb.ToolTip = 'Switch this monitor with the mouse'
    $head = El StackPanel; $t = El TextBlock; $t.Text = $m.name; $t.FontWeight = 'SemiBold'; $t.TextTrimming = 'CharacterEllipsis'
    $sub = El TextBlock 'Sub'; $sub.Text = 'Switch with the mouse'; [void]$head.Children.Add($t); [void]$head.Children.Add($sub); $cb.Content = $head
    $cb.Add_Click({ try { $id = $this.Tag; $C.monOff = @(@($C.monOff | ? { $_ -ne $id }) + $(if (-not $this.IsChecked) { $id })) | ? { $_ }; Changed } catch { Say "$($_.Exception.Message)" error }; Update-Ui })
    [void]$sp.Children.Add($cb)
    $g = El Grid; $g.Margin = '0,8,0,0'
    foreach ($w in '*', 'Auto') { $col = El ColumnDefinition; $col.Width = $w; [void]$g.ColumnDefinitions.Add($col) }
    $row = @{ cb = $cb }
    for ($i = 0; $i -lt 2; $i++) {
      [void]$g.RowDefinitions.Add((El RowDefinition))
      $a = El TextBlock; $a.TextTrimming = 'CharacterEllipsis'; $b = El TextBlock; $b.FontWeight = 'SemiBold'; $b.Margin = '12,0,0,0'
      if ($i) { $a.Margin = '0,4,0,0'; $b.Margin = '12,4,0,0' }
      [Windows.Controls.Grid]::SetRow($a, $i); [Windows.Controls.Grid]::SetRow($b, $i); [Windows.Controls.Grid]::SetColumn($b, 1)
      [void]$g.Children.Add($a); [void]$g.Children.Add($b)
      if ($i) { $row.peer = $a; $row.peerIn = $b } else { $row.me = $a; $row.meIn = $b }
    }
    [void]$sp.Children.Add($g); [void]$ui.MonList.Children.Add($box); $S.monRows[$m.id] = $row
  }
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
  Build-MonRows
  foreach ($m in $S.mons) {
    $r = $S.monRows[$m.id]; $r.cb.IsChecked = @($C.monOff) -notcontains $m.id
    $r.me.Text = "$Name (this PC)"; $r.meIn.Text = Input-Name ([int]$(if ($C.inputOverride) { $C.inputOverride } else { $C.inputs[$m.id] }))
    $r.peer.Text = $peer; $r.peerIn.Text = if ($paired) { Input-Name (Peer-Input-Of $S.peerInputs $S.peerInput $m.id) } else { 'not paired' }
  }
  $ui.SwitchNow.IsEnabled = @(Switch-Plan $S.mons $C.monOff $S.peerInputs $S.peerInput).Count -gt 0
  $ui.SwitchNow.ToolTip = "Show $peer on the monitor now"
  $ui.MonMsg.Text = $S.monMsg; $ui.MonMsg.Foreground = Brush $(if ($S.monErr) { 'Bad' } else { 'Fg2' }); Show-If $ui.MonMsg $S.monMsg

  # keyboard & mouse
  $ui.KmMe.Content = $Name; $ui.KmPeer.Content = $peer; $ui.KmPeer.IsEnabled = $paired
  $ui.KmMe.IsChecked = $C.kmHost -eq $Name; $ui.KmPeer.IsChecked = $paired -and $C.kmHost -eq $C.peer

  # sound
  $ui.AFollow.IsChecked = $C.audio -eq 'follow'; $ui.ABoth.IsChecked = $C.audio -eq 'both'; $ui.AOff.IsChecked = $C.audio -eq 'off'
  $ui.HpMe.Content = $Name; $ui.HpPeer.Content = $peer; $ui.HpPeer.IsEnabled = $paired
  $ui.HpMe.IsChecked = $C.hp -eq $Name; $ui.HpPeer.IsChecked = $paired -and $C.hp -eq $C.peer
  $sender = if ($C.hp -eq $Name) { $peer } elseif ($paired -and $C.hp -eq $C.peer) { "this PC" } else { 'the other PC' }
  $ui.VolLabel.Text = "Volume of $sender"
  if (-not $S.volAt -and $ui.Vol.Value -ne $C.vol) { $ui.Vol.Value = $C.vol }
  $ui.VolPct.Text = "$($C.vol)%"
  $ui.AudioWhy.Text = Audio-Status $C $paired $online $S.active $S.peerVer
  $ui.AudioDot.Fill = Brush $(if ([Dg]::SendMode -eq [Dg]::Sound -or [Dg]::RecvMode -eq [Dg]::Sound) { 'Good' } else { 'Fg2' })

  # update (footer)
  $ui.UpdateText.Text = if ($S.updMsg) { $S.updMsg } elseif ($S.upd -and $S.upd.stage -eq 'get') { "Downloading DeskGlide $($S.newer.ver)... $(if ($S.upd.job.Total -gt 0) { [int](100 * $S.upd.job.Done / $S.upd.job.Total) })%" } elseif ($S.newer) { "Update available: DeskGlide $($S.newer.ver)" } else { '' }
  $ui.UpdateLink.IsEnabled = [bool]$S.newer -and -not $S.upd

  # files
  $ui.FilesToggle.IsChecked = $C.files
  $busy = [Files]::Status -eq 'busy'
  $ui.FileMsg.Text = if (-not $C.files) { 'Off.' } elseif ($S.fileMsg) { $S.fileMsg } elseif ($S.peerOffer -and $S.peerOffer.id -ne $S.fetchedId) { "Copied on ${peer}: $(Offer-Text $S.peerOffer). They come over when the mouse moves here." } else { 'Nothing copied yet.' }
  $ui.FileMsg.Foreground = Brush $(if ($S.fileErr) { 'Bad' } else { 'Fg' })
  Show-If $ui.FileBar $busy; if ($busy -and [Files]::Total -gt 0) { $ui.FileBar.Value = [Files]::Done / [Files]::Total }

  # microphone
  $ui.MFollow.IsChecked = $C.mic -eq 'follow'; $ui.MAlways.IsChecked = $C.mic -eq 'always'; $ui.MOff.IsChecked = $C.mic -eq 'off'
  $ui.MicWhy.Text = Mic-Status $C $paired $online $S.active $S.peerVer $S.peerCable $S.cable
  $ui.MicDot.Fill = Brush $(if ([Dg]::SendMode -eq [Dg]::Mic -or [Dg]::RecvMode -eq [Dg]::Mic) { 'Good' } else { 'Fg2' })
  Show-If $ui.CableRow ($C.mic -ne 'off' -and $paired -and (($C.hp -eq $C.peer -and $S.cable -lt 0) -or ($C.hp -eq $Name -and -not $S.peerCable)))

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
  $ui.StartupToggle.IsChecked = Test-Path $lnk; $ui.PauseToggle.IsChecked = $C.paused; $ui.DetachToggle.IsChecked = $C.detach
  $ui.HkMsg.Text = if ($S.hkErr) { $S.hkErr } else { 'The mouse stays where it is.' }
  $ui.HkMsg.Foreground = Brush $(if ($S.hkErr) { 'Bad' } else { 'Fg2' })
  foreach ($p in @(@('LogPath', 'synergyLog'), @('AddrSet', 'peerAddress'), @('Script', 'onSwitch'), @('HkPeer', 'hotkeyPeer'), @('HkMe', 'hotkeyMe'), @('FileLimit', 'fileLimitMB'))) {
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

function Save-Shot {   # -Shot: the window's content rendered off screen, under a title bar drawn like Windows 11's
  $root = $win.Content; $root.Background = $win.Background
  $w = [int]$root.ActualWidth; $h = [int]$root.ActualHeight
  $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap $w, $h, 96, 96, ([Windows.Media.PixelFormats]::Pbgra32); $rtb.Render($root)
  $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb)); $ms = New-Object IO.MemoryStream; $enc.Save($ms)
  $body = [Drawing.Image]::FromStream($ms); $bar = 32
  $bmp = New-Object Drawing.Bitmap $w, ($h + $bar); $g = [Drawing.Graphics]::FromImage($bmp)
  $g.TextRenderingHint = 'ClearTypeGridFit'; $g.SmoothingMode = 'AntiAlias'
  $bg = [Drawing.ColorTranslator]::FromHtml($(if ($S.dark) { '#202020' } else { '#F3F3F3' })); $fg = [Drawing.ColorTranslator]::FromHtml($(if ($S.dark) { '#FFFFFF' } else { '#1B1B1B' }))
  $g.Clear($bg); $g.DrawImage($body, 0, $bar, $w, $h)
  $g.DrawImage(([Dg]::DrawIcon(16, 0)), 10, 8)
  $fb = New-Object Drawing.SolidBrush $fg
  $g.DrawString('DeskGlide', (New-Object Drawing.Font('Segoe UI', 9)), $fb, 34, 8)
  $glyphs = New-Object Drawing.Font('Segoe Fluent Icons', 7.5)
  $i = 0; foreach ($c in [char]0xE8BB, [char]0xE922, [char]0xE921) { $g.DrawString([string]$c, $glyphs, $fb, $w - 30 - 46 * $i, 11); $i++ }   # close, maximize, minimize
  $g.Dispose(); $bmp.Save($Shot, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); $body.Dispose()
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
  $S.msgWin = New-Object MsgWin; Apply-Hotkeys
  [void]$S.msgWin.ListenClipboard(); [Files]::Key = $S.key; [Files]::Serve($Port + 1)   # files: TCP on the control port + 1
  $S.screen = if ($C.screenName) { $C.screenName } else { $Name }
  if ($C.key) { $S.key = [Convert]::FromBase64String($C.key) }
  if ($PairCode) { Set-Key $PairCode }
  Resolve-Peer
  Say "DeskGlide on $Name, control port $Port -> $PeerPort, audio port $AudioPort$(if ($DryRun) { ', dry run' })$(if ($NoBroadcast) { ', no broadcast' })."
  Refresh-Monitors; $S.monAt = Get-Date
  Say "Monitors: $(($S.mons | % { "$($_.name) ($($_.id))" }) -join ', ')"
  Detect-Role
  if (-not $S.server) { Say 'This PC is a Synergy client (no "switch from" lines in its log).' }
  Read-Layout
  if (-not $S.key) { Say 'Not paired yet: open the DeskGlide window to pair.' }

  if ($Console -and -not $ShowWindow) {
    while ($true) { try { [Windows.Forms.Application]::DoEvents(); Tick } catch { Say "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))" error }; Start-Sleep -Milliseconds 100 }   # DoEvents: hotkey and clipboard messages
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
  [Dg]::SendMode = 0; [Dg]::RecvMode = 0
  if ([Dg]::Detached) { [void][Dg]::Reattach() }   # never leave a monitor off the desktop
  if ([Dg]::Muted.Count) { [Dg]::MuteOthers($false, $PID) }
  Save-Muted
  if ($tray) { $tray.Visible = $false; $tray.Dispose() }
}
