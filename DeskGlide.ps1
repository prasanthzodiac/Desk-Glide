# DeskGlide: two PCs, one monitor, one keyboard and mouse (shared by DeskGlide Link), one pair of headphones.
# The same files run on both PCs as a tray app with a window. Install.cmd adds it to Startup, Uninstall.cmd removes it.
#   -Test        self-check of the pure logic (no network, no monitor, no audio)
#   -Console     output to this console instead of the tray, for debugging
#   -ShowWindow  open the DeskGlide window right away
#   -ServiceSetup / -ServiceRemove  (elevated, started by the app) install or remove the admin control service on this PC
param(
  [switch]$Console, [switch]$Test, [switch]$Install, [switch]$Uninstall, [switch]$ShowWindow,
  [switch]$ServiceSetup, [switch]$ServiceRemove,   # admin control (DeskGlideService.cs): run elevated by the app
  [string]$SetupKey, [string]$SetupPeer, [string]$SetupPeerName,   # -ServiceSetup: the pairing key, the other PC's address and name
  # hidden, for debugging and for running two copies on one PC:
  [switch]$DryRun,                        # never send a DDC command, only print it
  [switch]$NoInject,                      # DeskGlide Link: no hooks, no Raw Input, no SendInput; log what it would inject
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
$Version = '5.2.3'
$Proto = 5   # 'ver' in the state message; DeskGlide 3 sends none, so new features stay off with it; 5 = DeskGlide Link
$UpdateRepo = ''   # 'owner/repo' on GitHub for auto-update; empty = no update checks
if (-not $PeerPort) { $PeerPort = $Port }
Add-Type -Path "$PSScriptRoot\DeskGlide.cs" -ReferencedAssemblies System.Drawing, System.Core, System.IO.Compression, System.IO.Compression.FileSystem, System.Windows.Forms
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, PresentationFramework, PresentationCore, WindowsBase, WindowsFormsIntegration, System.Security
if ($NoInject) { [Link]::NoInject = $true }
$cfgPath   = Join-Path $ConfigDir 'config.json'
$mutedPath = Join-Path $ConfigDir 'muted.txt'   # apps we muted, so a crash or kill doesn't leave them muted
$logPath   = Join-Path $ConfigDir 'deskglide.log'
$icoPath   = Join-Path $PSScriptRoot 'DeskGlide.ico'
$lnk       = Join-Path ([Environment]::GetFolderPath('Startup')) 'DeskGlide.lnk'
$opp       = @{ left = 'right'; right = 'left'; up = 'down'; down = 'up' }

# DeskGlide runs from its own copy in $appDir, so the downloaded folder can be moved or deleted and updates have one place to go
$appDir   = Join-Path $DataDir 'app'
$appFiles = 'DeskGlide.ps1', 'DeskGlide.cs', 'DeskGlideService.cs', 'DeskGlideHelper.cs', 'DeskGlide.ico', 'README.md', 'LICENSE', 'Install.cmd', 'Uninstall.cmd'
function Arg-Line([string]$ps1) { "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ps1`"" }
$svcName = 'DeskGlideService'; $svcDir = Join-Path $env:ProgramFiles 'DeskGlide'; $svcData = Join-Path $env:ProgramData 'DeskGlide\service'
function Build-Service([string]$src, [string]$out) {
  $csc = "$env:windir\Microsoft.NET\Framework64\v4.0.30319\csc.exe"; if (-not (Test-Path $csc)) { $csc = "$env:windir\Microsoft.NET\Framework\v4.0.30319\csc.exe" }
  [void](New-Item -ItemType Directory -Force $out)
  $refs = 'System', 'System.Core', 'System.Drawing', 'System.Windows.Forms', 'System.IO.Compression', 'System.IO.Compression.FileSystem', 'System.Security', 'System.ServiceProcess' | % { "/r:$_.dll" }
  $o = & $csc /nologo /optimize /target:exe /main:ServiceMain "/out:$out\DeskGlideService.exe" @refs "$src\DeskGlide.cs" "$src\DeskGlideService.cs" "$src\DeskGlideHelper.cs" 2>&1
  if ($LASTEXITCODE) { throw "can't build the service: $(($o | ? { $_ -match 'error' }) -join ' ')" }
  $o = & $csc /nologo /optimize /target:winexe /main:HelperMain "/out:$out\DeskGlideHelper.exe" /r:System.Core.dll "$src\DeskGlideHelper.cs" 2>&1
  if ($LASTEXITCODE) { throw "can't build the helper: $(($o | ? { $_ -match 'error' }) -join ' ')" }
}
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
          hotkeyPeer = 'Ctrl+Alt+Right'; hotkeyMe = 'Ctrl+Alt+Left'; files = $true; fileLimitMB = 2048; mic = 'off'; updateAt = 0
          link = -not (Test-Path $cfgPath); linkSpeed = 100; game = $false; lockSync = $false; panicKey = 'Ctrl+Alt+Pause'; dualPath = $true
          adminKey = ''; peerAdmin = $false }   # Link: on for new installs; dualPath: Ethernet + Wi-Fi both
  if (Test-Path $cfgPath) { (Get-Content $cfgPath -Raw | ConvertFrom-Json).psobject.Properties | % { $c[$_.Name] = $_.Value } }
  $c.inputs = To-Hash $c.inputs; $c.monOff = @($c.monOff | ? { $_ })
  if ($c.Contains('headphones')) {   # DeskGlide 2 had a per-PC flag; now it's one shared value: the name of the PC with the headphones
    if ($c.headphones -and -not $c.hp) { $c.hp = $Name; $c.syncAt = Now-Ms }   # newest, so the other PC takes it instead of clearing it
    $c.Remove('headphones')
  }
  $c.key = Unprotect-Key $c.key   # DeskGlide 3 stored it in plain text: the next Save-Config protects it
  $c.adminKey = Unprotect-Key $c.adminKey   # the other PC's admin control service, when this PC controls it
  if (-not $c.key) { $c.peer = '' }   # no readable key (copied from another user or PC): pair again
  $c
}
function Save-Config {   # the pairing key goes to disk only encrypted for this Windows user (DPAPI)
  [void](New-Item -ItemType Directory -Force $ConfigDir)
  $o = $C.Clone(); $o.key = Protect-Key $C.key; $o.adminKey = Protect-Key $C.adminKey
  $o | ConvertTo-Json | Set-Content "$cfgPath.tmp" -Encoding UTF8; Move-Item -Force "$cfgPath.tmp" $cfgPath   # atomic: a crash never leaves half a file
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
  if ($null -ne $m.lk) { $cfg.link = [bool]$m.lk }   # DeskGlide 5: keyboard and mouse sharing, and locking both PCs together
  if ($null -ne $m.ls) { $cfg.lockSync = [bool]$m.ls }
  $true
}
# h is for DeskGlide 2 peers (it had a per-PC headphones flag); ly is DeskGlide's layout; l is Synergy's, from the server
# DeskGlide 4 adds ver, sn (screen name), kh (the PC the keyboard and mouse are plugged into),
# mi (this PC's input on each monitor), mo (monitors that don't follow the mouse) and hk/ha (a hotkey press, for 10 s:
# its time and the PC it showed), fo (files copied here: { id; n = how many; b = bytes; names }), mc (microphone mode) and
# vc (VB-Cable is installed here). DeskGlide 5 adds lk (DeskGlide Link on), ls (lock both PCs together) and co (text or a
# picture copied here: { id; k = 'text' or 'png'; b = bytes }). DeskGlide 5.2 adds as (admin control: this PC's service
# receives the keyboard and mouse) and, in their own messages, adm (pairing that service: offer, answer, done).
function State-Json($cfg) {
  @{ n = $Name; t = $S.t; s = $S.server; sa = ($S.active -eq 'me'); i = (My-Input); h = ($cfg.hp -eq $Name)
     m = $cfg.monitor; am = $cfg.audio; p = $cfg.paused; st = $cfg.syncAt; hp = $cfg.hp; v = $cfg.vol; ly = $cfg.layout
     l = @($(if ($S.server) { $S.links | % { "$($_.from) $($_.dir) $($_.to)" } }))
     ver = $Proto; sn = $S.screen; kh = $cfg.kmHost; mi = $cfg.inputs; mo = @($cfg.monOff)
     hk = $(if ((Now-Ms) - [long]$S.hk -lt 10000) { $S.hk } else { 0 }); ha = $S.hkTo
     fo = $(if ($cfg.files) { $S.offer } else { $null }); mc = $cfg.mic; vc = ($S.cable -ge 0)
     lk = [bool]$cfg.link; ls = [bool]$cfg.lockSync; co = $S.clipOffer; as = (Svc-On $S.svc) } | ConvertTo-Json -Compress -Depth 4
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
# At least one modifier; keys: arrows, A-Z, 0-9, F1-F24, Pause, ScrollLock.
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
    '^(pause|break)$' { @{ vk = 0x13; n = 'Pause' } }
    '^scrolllock$' { @{ vk = 0x91; n = 'ScrollLock' } }
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

# DeskGlide Link's state in plain words. $l: the engine (or $null), $synergy: Synergy runs on this PC.
function Link-Status($cfg, [bool]$paired, [bool]$online, [int]$peerVer, $l, [bool]$synergy, $svc = $null) {
  $peer = if ($cfg.peer) { $cfg.peer } else { 'the other PC' }
  if (-not $cfg.link) { return 'Off. Synergy shares the keyboard and mouse, and DeskGlide follows its log.' }
  if (-not $paired) { return 'Pair with your other PC first.' }
  if (-not $cfg.kmHost) { return 'Choose the PC your keyboard and mouse are plugged into.' }
  if ($synergy) { return 'Synergy is running on this PC. Quit it (and its service), so only DeskGlide moves the mouse.' }
  if (Svc-On $svc) {   # admin control: the service receives here, not this app
    if ($cfg.kmHost -eq $Name) { return "Admin control is on, so DeskGlide's service holds this PC's keyboard and mouse port. Turn admin control off to share this PC's keyboard and mouse." }
    if ($svc.up -ne '1') { return "Admin control: on (service). Waiting for $peer..." }
    if ($svc.controlled -eq '1') { return "The keyboard and mouse of $peer are on this PC, admin windows, UAC prompts and the lock screen included." }
    return "Connected. The keyboard and mouse of $peer come here when its pointer crosses the edge, admin windows and the lock screen included."
  }
  if ($online -and $peerVer -lt 5) { return "Update DeskGlide on $peer to share the keyboard and mouse." }
  if (-not $l) { return 'Starting...' }
  if ($l.VersionMsg) { return $l.VersionMsg }
  if (-not $l.Up) { return "Waiting for $peer..." }
  if ($l.Controlled -and $l.Uipi) { return "An admin window is in front on this PC. Windows doesn't let $peer type into it: use this PC's own keyboard there, or click another window." }
  if ($l.InjectError) { return $l.InjectError }
  $panic = if ($cfg.panicKey) { ", or press $($cfg.panicKey)" } else { '' }
  if ($cfg.kmHost -eq $Name) {
    if ($l.Active) { return "Your keyboard and mouse are on $peer. Move back across the edge$panic." }
    return "Connected. Move the mouse off the screen edge toward $peer to use it."
  }
  if ($l.Controlled) { return "The keyboard and mouse of $peer are on this PC." }
  "Connected. The keyboard and mouse of $peer come here when its pointer crosses the edge."
}
# Admin control (DeskGlideService.cs) in plain words. $svc: the service's status here; $busy/$want: its elevated setup is
# open; on the keyboard PC it describes the other PC's service instead.
function Svc-State([string]$line) {   # 'ok enabled=1 paired=1 ...' -> @{ enabled = '1'; ... }, or $null
  if ($line -notlike 'ok *') { return $null }
  $h = @{}; foreach ($kv in $line.Substring(3) -split ' ') { $k, $v = $kv -split '=', 2; if ($k) { $h[$k] = $v } }; $h
}
function Svc-On($svc) { [bool]($svc -and $svc.enabled -eq '1' -and $svc.paired -eq '1') }
function Link-Used { [bool]$S.link -or (Svc-On $S.svc) }   # keyboard and mouse sharing: this app's Link, or (admin control) the service's
function Admin-Status($cfg, $svc, [bool]$installed, [bool]$busy, [bool]$want, [bool]$hasKey) {
  $peer = if ($cfg.peer) { $cfg.peer } else { 'the other PC' }
  if ($busy) { if ($want) { return "Finish in the admin window that Windows opened: check that $peer shows the same number." } else { return 'Finish in the admin window that Windows opened.' } }
  if ($cfg.kmHost -eq $Name -and -not (Svc-On $svc)) {
    if ($cfg.peerAdmin -and $hasKey) { return "On at $peer`: its admin windows, UAC prompts and lock screen work from here. Ctrl+Alt+End there = Ctrl+Alt+Del." }
    if ($cfg.peerAdmin) { return "On at $peer, but not paired with this PC. Turn it off and on again in DeskGlide on $peer." }
    return "Turn this on in DeskGlide on $peer, the PC being controlled."
  }
  if (Svc-On $svc) { return "On (service). Ctrl+Alt+Del: $(if ($svc.sas -eq '1') { "press Ctrl+Alt+End on $peer" } else { 'not allowed' })." }
  if ($svc) { return "DeskGlide's service runs here but isn't paired. Turn this off and on again." }
  if ($installed) { return "DeskGlide's service is installed but doesn't answer. Turn this off and on again." }
  "Off. Turning it on installs a small Windows service; Windows asks for permission once."
}
# The connection in one word: round trip and its jitter (ms), packet loss (%)
function Link-Quality([double]$rtt, [double]$jitter, [double]$loss) {
  if ($rtt -ge 80 -or $jitter -ge 30 -or $loss -ge 5) { 'Poor' } elseif ($rtt -ge 20 -or $jitter -ge 10 -or $loss -ge 1) { 'Fair' } else { 'Good' }
}
# Wi-Fi power saving from 'powercfg /q' (no admin): the current AC and DC values, in that order; 0 = Maximum Performance
function PowerSave-On([string]$text, [bool]$onAC) {
  $v = @([regex]::Matches($text, '0x([0-9a-fA-F]{8})') | % { [Convert]::ToInt32($_.Groups[1].Value, 16) })
  $v.Count -ge 2 -and $v[$(if ($onAC) { 0 } else { 1 })] -gt 0
}
function Wifi-PowerSave {
  $q = (powercfg /q SCHEME_CURRENT 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 2>$null) -join "`n"
  PowerSave-On $q ([Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus -ne 'Offline')
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
        mons = @(); monSig = ''; monRows = @{}; monAt = [DateTime]::MinValue; peerInputs = @{}
        link = $null; linkAt = [DateTime]::MinValue; linkWant = $null; synergy = $false; synAt = [DateTime]::MinValue; speedAt = $null; psave = $false; psaveAt = [DateTime]::MinValue
        clipOffer = $null; peerClip = $null; clipGot = ''; clipSig = ''; clipSetAt = [DateTime]::MinValue
        svc = $null; adminKey = $null; adminPend = $null; adminWant = $false; adminUntil = $null }
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
  Check ((Msg $PA 'PC-A').ver -eq 5) 'state message has ver 5'
  # DeskGlide Link settings: on/off and lock sync are shared; a DeskGlide 4 message (no lk) keeps ours
  $PA.link = $true; $PA.lockSync = $true; $PB.link = $false; $PA.syncAt = 800
  Check ((Merge-Settings $PB (Msg $PA 'PC-A')) -and $PB.link -and $PB.lockSync) 'Link on and lock sync synced'
  $v4 = Msg $PA 'PC-A'; 'lk', 'ls' | % { $v4.psobject.Properties.Remove($_) }; $v4.st = 900; $PB.link = $true
  Check ((Merge-Settings $PB $v4) -and $PB.link) 'DeskGlide 4 message turned Link off'
  $PA.syncAt = 5; $PB.syncAt = 99   # as the tests below expect
  $S.clipOffer = @{ id = 'c1'; k = 'text'; b = 5 }; Check ((Msg $PA 'PC-A').co.k -eq 'text') 'clipboard offer in the state message'; $S.clipOffer = $null
  # Link status, in plain words
  $L5 = @{ peer = 'PC-B'; link = $true; kmHost = 'PC-A'; panicKey = 'Ctrl+Alt+Pause' }; $Name = 'PC-A'
  $eng = [pscustomobject]@{ Up = $true; Active = $false; Controlled = $false; Uipi = $false; VersionMsg = ''; InjectError = '' }
  Check ((Link-Status $L5 $true $true 5 $eng $false) -match '^Connected. Move the mouse') 'link status: ready here'
  $eng.Active = $true; Check ((Link-Status $L5 $true $true 5 $eng $false) -match 'are on PC-B.*Ctrl\+Alt\+Pause') 'link status: on the other PC'
  $Name = 'PC-B'; $eng.Active = $false; $eng.Controlled = $true; $eng.Uipi = $true; Check ((Link-Status $L5 $true $true 5 $eng $false) -match 'admin window') 'link status: admin window in front'; $Name = 'PC-A'
  Check ((Link-Status $L5 $true $true 4 $eng $false) -match 'Update DeskGlide on PC-B' -and (Link-Status $L5 $true $true 5 $eng $true) -match 'Synergy is running') 'link status: old peer, Synergy running'
  $eng.Up = $false; Check ((Link-Status $L5 $true $true 5 $eng $false) -match 'Waiting for PC-B') 'link status: waiting'
  $eng.VersionMsg = 'DeskGlide on PC-B is older.'; Check ((Link-Status $L5 $true $true 5 $eng $false) -eq 'DeskGlide on PC-B is older.') 'link status: version mismatch'
  $L5.kmHost = ''; Check ((Link-Status $L5 $true $true 5 $eng $false) -match 'Choose the PC') 'link status: no keyboard PC'
  $L5.link = $false; Check ((Link-Status $L5 $true $true 5 $null $false) -match '^Off') 'link status: off'
  # admin control: the service's status line, the card's texts on both PCs
  $sv = Svc-State 'ok enabled=1 paired=1 link=1 up=1 controlled=1 helper=1 sas=1 peer=PC-A refused=0 dropped=0'
  Check ($sv.controlled -eq '1' -and (Svc-On $sv) -and -not (Svc-On (Svc-State 'ok enabled=1 paired=0')) -and -not (Svc-On (Svc-State 'ok enabled=0 paired=1')) -and -not (Svc-State 'refused') -and -not (Svc-State '')) 'service status parsed'
  $L5.link = $true; $L5.kmHost = 'PC-A'; $L5.peer = 'PC-A'; $Name = 'PC-B'
  Check ((Link-Status $L5 $true $true 5 $null $false $sv) -match 'admin windows, UAC prompts and the lock screen included') 'link status: controlled through the service'
  $sv.controlled = '0'; $sv.up = '0'; Check ((Link-Status $L5 $true $true 5 $null $false $sv) -match '^Admin control: on \(service\). Waiting for PC-A') 'link status: service waiting'
  Check ((Admin-Status $L5 $sv $true $false $false $false) -match '^On \(service\). Ctrl\+Alt\+Del: press Ctrl\+Alt\+End on PC-A') 'admin status: on, Ctrl+Alt+Del allowed'
  Check ((Admin-Status $L5 $null $false $false $false $false) -match '^Off. Turning it on installs') 'admin status: off'
  Check ((Admin-Status $L5 $null $true $false $false $false) -match "installed but doesn't answer") 'admin status: installed, not running'
  Check ((Admin-Status $L5 $null $false $true $true $false) -match 'check that PC-A shows the same number') 'admin status: setup open'
  $Name = 'PC-A'; $L5.peer = 'PC-B'
  Check ((Link-Status $L5 $true $true 5 $eng $false $sv) -match "service holds this PC's keyboard and mouse port") 'link status: service here, but this is the keyboard PC'
  Check ((Admin-Status $L5 $null $false $false $false $false) -match '^Turn this on in DeskGlide on PC-B') 'admin status: keyboard PC'
  $L5.peerAdmin = $true; Check (((Admin-Status $L5 $null $false $false $false $true) -match '^On at PC-B') -and ((Admin-Status $L5 $null $false $false $false $false) -match 'not paired with this PC')) 'admin status: the other PC has it'
  $L5.peerAdmin = $false
  $S.svc = Svc-State 'ok enabled=1 paired=1 up=1'; Check ((-not $S.link) -and (Link-Used)) 'clipboard: text and pictures still shared while the admin service has the Link (5.2.2 stopped)'; $S.svc = $null

  # hotkeys: RegisterHotKey values
  $k = Parse-Hotkey 'Ctrl+Alt+Right'; Check ($k.mods -eq 3 -and $k.vk -eq 0x27 -and $k.text -eq 'Ctrl+Alt+Right') 'hotkey: default'
  $k = Parse-Hotkey ' control + shift + left '; Check ($k.mods -eq 6 -and $k.vk -eq 0x25 -and $k.text -eq 'Ctrl+Shift+Left') 'hotkey: spaces and case'
  $k = Parse-Hotkey 'Win+Alt+k'; Check ($k.mods -eq 9 -and $k.vk -eq 0x4B -and $k.text -eq 'Win+Alt+K') 'hotkey: letter'
  $k = Parse-Hotkey 'Ctrl+F12'; Check ($k.vk -eq 0x7B -and $k.text -eq 'Ctrl+F12') 'hotkey: F12'
  Check ((Parse-Hotkey 'Alt+F24').vk -eq 0x87 -and (Parse-Hotkey 'Ctrl+7').vk -eq 0x37) 'hotkey: F24 and digits'
  $k = Parse-Hotkey 'Ctrl+Alt+Pause'; Check ($k.vk -eq 0x13 -and $k.mods -eq 3 -and $k.text -eq 'Ctrl+Alt+Pause' -and (Parse-Hotkey 'ctrl+break').vk -eq 0x13 -and (Parse-Hotkey 'Shift+ScrollLock').vk -eq 0x91) 'hotkey: the panic key'
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
  # clipboard (text and pictures, DeskGlide Link): its own request on the file port, chunked, capped, gone when replaced
  $txt = [Text.Encoding]::UTF8.GetBytes('Grüße ' + ('x' * 100000)); Check ([Clip]::Offer('text', $txt)) 'clip offer'
  function PullClip($key, $id) { [Clip]::Fetch('127.0.0.1', $fport, $key, $id); $t0 = Get-Date; while ([Clip]::Status -eq 'busy' -and ((Get-Date) - $t0).TotalSeconds -lt 10) { Start-Sleep -Milliseconds 20 }; [Clip]::Status }
  Check ((PullClip $pk ([Clip]::OfferId)) -eq 'ok' -and [Clip]::ResultKind -eq 'text' -and [Dg]::Hex([Clip]::Result) -eq [Dg]::Hex($txt)) 'clip transfer'
  Check ((PullClip $pk 'old') -eq 'error: gone' -and (PullClip $k2 ([Clip]::OfferId)) -match '^error') 'clip: old offer or wrong key refused'
  Check (-not [Clip]::Offer('png', (New-Object byte[] ([Clip]::Max + 1))) -and [Clip]::OfferId -eq '') 'clip: over the cap not offered'
  [Files]::Offer($null); Remove-Item -Recurse -Force $root

  # ---------- DeskGlide Link ----------
  # packets: the header (version included) is authenticated; tampering, another key or a cut packet is refused
  $lk = [Dg]::SessionKey($pk, 'link', [byte[]](1..16)); $nonce = [byte[]](1..8); $body = [byte[]](72, 1, 2, 3); $ver = 0; $kind = 0; $nn = $null
  $p = [LinkProto]::Seal($lk, 1, $nonce, $body, 4, [LinkProto]::Version)
  $o = [LinkProto]::Open($lk, $p, $p.Length, [ref]$ver, [ref]$kind, [ref]$nn)
  Check ($o -and [Dg]::Hex($o) -eq '48010203' -and $ver -eq [LinkProto]::Version -and $kind -eq 1 -and [Dg]::Hex($nn) -eq [Dg]::Hex($nonce) -and $p.Length -le 12 + 4 + [Dg]::CryptoOverhead) 'link packet round trip'
  foreach ($i in 2, 3, 5, 20, ($p.Length - 1)) { $t = [byte[]]$p.Clone(); $t[$i] = $t[$i] -bxor 1; Check ($null -eq [LinkProto]::Open($lk, $t, $t.Length, [ref]$ver, [ref]$kind, [ref]$nn)) "tampered link byte $i accepted" }
  Check ($null -eq [LinkProto]::Open($pk, $p, $p.Length, [ref]$ver, [ref]$kind, [ref]$nn) -and $null -eq [LinkProto]::Open($lk, $p, 40, [ref]$ver, [ref]$kind, [ref]$nn)) 'link packet: other key or cut short accepted'
  $nv = [LinkProto]::Version + 1; $p2 = [LinkProto]::Seal($lk, 0, $nonce, $body, 4, $nv); Check ([LinkProto]::Open($lk, $p2, $p2.Length, [ref]$ver, [ref]$kind, [ref]$nn) -and $ver -eq $nv) 'version byte authenticated and readable'
  Check (([LinkProto]::VersionText($nv, 'PC-B')) -match 'Update DeskGlide on this PC' -and ([LinkProto]::VersionText(0, 'PC-B')) -match 'Update DeskGlide on PC-B') 'version mismatch: says which PC to update'
  # game mode: float deltas, whole pixels out, the remainder kept
  $co = New-Object Coalescer; $dx = 0; $dy = 0; 1..3 | % { $co.Add(0.4, -0.4) }
  Check ($co.Take([ref]$dx, [ref]$dy) -and $dx -eq 1 -and $dy -eq -1 -and [Math]::Abs($co.X - 0.2) -lt 1e-9 -and [Math]::Abs($co.Y + 0.2) -lt 1e-9) 'coalesce: whole pixels out, remainder kept'
  Check (-not $co.Take([ref]$dx, [ref]$dy)) 'coalesce: nothing yet'
  $co.Add(0.85, 0); Check ($co.Take([ref]$dx, [ref]$dy) -and $dx -eq 1 -and $dy -eq 0) 'coalesce: remainder carried into the next packet'
  # modifiers: the full bitmap, the receiver's corrections, AltGr's fake LCtrl
  Check ([KeyMap]::Apply(0, 0xA5, $false) -eq 0x20 -and [KeyMap]::Apply(0x20, 0xA5, $true) -eq 0 -and [KeyMap]::Apply(5, 0x41, $false) -eq 5) 'modifier bitmap'
  Check ((@([KeyMap]::Reconcile(0x05, 0x02)) -join ',') -eq '256,1,258' -and @([KeyMap]::Reconcile(0x11, 0x11)).Count -eq 0) 'modifiers reconciled: press LShift, release RShift, press LCtrl'
  Check ([KeyMap]::FakeCtrl(0xA2, 0x21D) -and -not [KeyMap]::FakeCtrl(0xA2, 0x1D) -and -not [KeyMap]::FakeCtrl(0xA5, 0x38)) 'AltGr: only the fake LCtrl dropped'
  Check ([KeyMap]::HotMods(0x24) -eq 3 -and [KeyMap]::HotMods(0x41) -eq 12) 'modifier bits to hotkey modifiers'
  # release-all: everything injected and not released comes back
  $hd = New-Object Held; $hd.Key(0x2A, $false); $hd.Key(0x11D, $false); $hd.Key(0x1E, $false); $hd.Key(0x1E, $true); $hd.Key(0x10013, $false); $hd.Button(0, $true); $hd.Button(3, $true); $hd.Button(0, $false); $hd.Button(4, $true)
  Check ($hd.Mods() -eq 0x09) 'held modifiers: LShift and RCtrl'
  Check ((@($hd.TakeKeys() | sort) -join ',') -eq '42,285,65555' -and (@($hd.TakeButtons()) -join ',') -eq '3,4' -and @($hd.TakeKeys()).Count -eq 0 -and $hd.Mods() -eq 0) 'release-all, then nothing held'
  # edges: per-monitor layout in physical pixels, DPI, dead zones
  $one = [Mon[]]@([Mon]::new(0, 0, 1920, 1080, 96))
  $two = [Mon[]]@([Mon]::new(0, 0, 2560, 1440, 144), [Mon]::new(2560, 180, 4480, 1260, 96))   # 1440p at 150% and a lower 1080p on its right
  Check ([Math]::Abs([Geo]::Leave($one, 1919, 540, 3, 0, 'r', 8) - 540.5 / 1080) -lt 1e-9) 'leaves the right edge halfway down'
  Check ([Geo]::Leave($one, 1919, 540, -3, 0, 'r', 8) -lt 0 -and [Geo]::Leave($one, 1918, 540, 3, 0, 'r', 8) -lt 0 -and [Geo]::Leave($one, 1919, 540, 3, 0, 'l', 8) -lt 0) 'no crossing: moving back, not at the edge, other edge'
  Check ([Geo]::Leave($one, 1919, 4, 3, 0, 'r', 8) -lt 0 -and [Geo]::Leave($one, 1919, 1075, 3, 0, 'r', 8) -lt 0 -and [Geo]::Leave($one, 1919, 8, 3, 0, 'r', 8) -gt 0) 'corner dead zones'
  Check ([Geo]::Leave($two, 2559, 700, 5, 0, 'r', 8) -lt 0 -and [Math]::Abs([Geo]::Leave($two, 4479, 700, 5, 0, 'r', 8) - 700.5 / 1440) -lt 1e-9) 'between monitors is not an edge; the outer one is'
  Check ([Geo]::Leave($two, 2559, 100, 5, 0, 'r', 8) -gt 0 -and [Geo]::Leave($two, 3000, 180, 0, -2, 'u', 8) -gt 0 -and [Geo]::Leave($two, 1000, 0, 0, -2, 'u', 8) -gt 0) 'outer edges of uneven monitors'
  $x = 0; $y = 0
  [Geo]::Entry($two, 'l', 540.5 / 1080, [ref]$x, [ref]$y); Check ($x -eq 0 -and $y -eq 720) 'entry: halfway down there too'
  [Geo]::Entry($two, 'r', 0.05, [ref]$x, [ref]$y); Check ($x -eq 2559 -and $y -eq 72) 'entry: the outermost monitor at that height'
  [Geo]::Entry($two, 'r', 0.5, [ref]$x, [ref]$y); Check ($x -eq 4479 -and $y -eq 720) 'entry: right edge of the right monitor'
  [Geo]::Entry($one, 'l', 1.0, [ref]$x, [ref]$y); Check ($x -eq 0 -and $y -eq 1079) 'entry: clamped to the screen'
  [Geo]::Entry($two, 'u', 0.75, [ref]$x, [ref]$y); Check ($x -eq 3360 -and $y -eq 180) 'entry: top edge of the lower monitor'
  Check ([Geo]::Scale(100, 96, 144) -eq 1.5 -and [Math]::Abs([Geo]::Scale(200, 144, 96) - 4 / 3) -lt 1e-9 -and [Geo]::Scale(50, 0, 0) -eq 0.5) 'DPI ratio and speed'
  $mx = [double]2500; $my = [double]700.5
  Check ([Geo]::Move($two, [ref]$mx, [ref]$my, 100, 0, 'l', 8) -lt 0 -and $mx -eq 2600) 'pointer model crosses between monitors'
  Check ([Geo]::Move($two, [ref]$mx, [ref]$my, 0, -1000, 'l', 8) -lt 0 -and $my -eq 180) 'pointer model clamped to its monitor'
  $mx = 10.5; $my = 700.5; $f = [Geo]::Move($two, [ref]$mx, [ref]$my, -20, 0, 'l', 8)
  Check ([Math]::Abs($f - 700.5 / 1440) -lt 1e-9 -and $mx -eq 0) 'pointer model leaves through the edge back to this PC'
  $mx = 10.5; $my = 3.5; Check ([Geo]::Move($two, [ref]$mx, [ref]$my, -20, 0, 'l', 8) -lt 0 -and $mx -eq 0) 'no way back through a corner'
  # absolute coordinates: every pixel round-trips whether Windows truncates (n * size / 65536) or rounds (n * (size - 1) / 65535);
  # 100%, 125% and 150% layouts in physical pixels, one with a monitor left of the main one
  $lays = @{ '100%' = @([Mon]::new(0, 0, 1920, 1080, 96)); '125%' = @([Mon]::new(0, 0, 2560, 1600, 120), [Mon]::new(2560, 0, 4480, 1080, 96))
             '150%' = @([Mon]::new(-1920, 0, 0, 1080, 96), [Mon]::new(0, 0, 3840, 2160, 144)) }
  foreach ($k in $lays.Keys) {
    $ms = [Mon[]]$lays[$k]; $vx = 0; $vy = 0; $vw = 0; $vh = 0; [Geo]::Bounds($ms, [ref]$vx, [ref]$vy, [ref]$vw, [ref]$vh); $bad = @()
    foreach ($m in $ms) {
      $pts = @(@($m.L, $m.T), @(($m.L + 1), ($m.T + 1)), @([int](($m.L + $m.R) / 2), [int](($m.T + $m.B) / 2)), @(($m.R - 2), ($m.B - 2)), @(($m.R - 1), ($m.B - 1)))
      foreach ($pt in $pts) { foreach ($a in 0, 1) {
        $v = $pt[$a]; $o = @($vx, $vy)[$a]; $sz = @($vw, $vh)[$a]
        $n = [Geo]::Norm($v, $o, $sz); $t = $o + [Math]::Floor($n * $sz / 65536); $r = $o + [Math]::Round($n * ($sz - 1) / 65535)
        if ($t -ne $v -or $r -ne $v -or $n -lt 0 -or $n -gt 65535) { $bad += "$v -> $n -> $t/$r" } } }
    }
    $nx = [Geo]::Norm($vx + $vw - 1, $vx, $vw); $ny = [Geo]::Norm($vy + $vh - 1, $vy, $vh)
    Check ($bad.Count -eq 0 -and $nx -ge 65500 -and $ny -ge 65500) "absolute coordinates, $k layout: bottom-right pixel -> $nx,$ny and back $($bad -join '; ')"
  }
  $cx = 5000; $cy = 1200; [Geo]::Clamp($two, [ref]$cx, [ref]$cy); $cx2 = 100; $cy2 = 1500; [Geo]::Clamp($two, [ref]$cx2, [ref]$cy2)
  Check ($cx -eq 4479 -and $cy -eq 1200 -and $cx2 -eq 100 -and $cy2 -eq 1439) 'clamped onto the nearest monitor: the edge rows stay reachable'
  # reliable stream: out of order held back, delivered once and in order, resent until acknowledged
  $tx = New-Object Reliable; $rx = New-Object Reliable
  $i1 = $tx.Add([byte[]](1), 0); $i2 = $tx.Add([byte[]](2), 0); $i3 = $tx.Add([byte[]](3), 0)
  Check (@($rx.Got(2, $i2.Data)).Count -eq 0 -and @($rx.Got(3, $i3.Data)).Count -eq 0 -and $rx.Ack -eq 0) 'reliable: out of order held back'
  $d = @($rx.Got(1, $i1.Data)); Check ($d.Count -eq 3 -and $d[0][0] -eq 1 -and $d[1][0] -eq 2 -and $d[2][0] -eq 3 -and $rx.Ack -eq 3) 'reliable: delivered in order'
  Check (@($rx.Got(2, $i2.Data)).Count -eq 0 -and @($rx.Got(9000, $i2.Data)).Count -eq 0) 'reliable: duplicate or nonsense dropped'
  Check (@($tx.Due(4, 30)).Count -eq 0 -and @($tx.Due(5, 30)).Count -eq 3 -and @($tx.Due(34, 30)).Count -eq 0 -and @($tx.Due(35, 30)).Count -eq 3) 'reliable: a second copy after 5 ms, then resent every timeout'
  $tx.Acked(2); $due = @($tx.Due(70, 30)); Check ($tx.Pending -eq 1 -and $due.Count -eq 1 -and $due[0].Seq -eq 3) 'reliable: an ack removes up to it, the rest is resent'
  $tx.Acked(3); Check ($tx.Pending -eq 0) 'reliable: all acknowledged'
  # heartbeat, loss and reconnect backoff (ms)
  $cn = New-Object Conn; $cn.Kick(0)
  Check ((@(0..5000 | ? { $cn.Tick($_) -band 1 }) -join ',') -eq '0,100,300,700,1500,3100') 'reconnect backoff doubles'
  Check ((@(5001..9000 | ? { $cn.Tick($_) -band 1 }) -join ',') -eq '5100,7100') 'reconnect backoff capped at 2 s, forever'
  $cn.Kick(9001); Check ($cn.Tick(9001) -band 1) 'network change or wake-up: hello right away'
  Check ($cn.Rx(9100) -and $cn.Up -and ($cn.Tick(9100) -band 2) -and -not ($cn.Tick(9200) -band 2) -and ($cn.Tick(9350) -band 2)) 'up: heartbeat every 250 ms'
  $cn.Fast = $true; Check (-not ($cn.Tick(9400) -band 2) -and ($cn.Tick(9600) -band 2) -and -not ($cn.Tick(9699) -band 2) -and ($cn.Tick(9700) -band 2)) 'while a PC has control: a keep-alive every 100 ms'
  $cn.Fast = $false; [void]$cn.Rx(9100); $cn.Slack = 120
  Check (-not ($cn.Tick(10720) -band 4) -and $cn.Up) 'not lost at 1.5 s plus the resend timeout'
  $f = $cn.Tick(10721); Check (($f -band 4) -and ($f -band 1) -and -not $cn.Up) 'lost after 1.5 s (plus the resend timeout) without any packet, hello at once'
  # round trip, jitter and the resend timeout
  $re = New-Object RttEst; Check ($re.Rto -eq 50) 'resend timeout before any round trip: 50 ms'
  $re.Add(2); Check ($re.Rto -eq 10) 'fast LAN: resend timeout 10 ms at least'
  1..20 | % { $re.Add($(if ($_ % 2) { 20 } else { 120 })) }; Check ($re.Rto -eq 200 -and $re.Var -gt 30) 'jittery hotspot: resend timeout capped at 200 ms'
  $re = New-Object RttEst; 1..40 | % { $re.Add(30) }; Check ([Math]::Abs($re.Srtt - 30) -lt 0.01 -and $re.Var -lt 1 -and $re.Rto -eq 30) 'steady 30 ms: the timeout follows it'
  # connection quality in the window, Wi-Fi power saving from powercfg
  Check ((Link-Quality 2 0.5 0) -eq 'Good' -and (Link-Quality 35 8 0) -eq 'Fair' -and (Link-Quality 12 3 2) -eq 'Fair' -and (Link-Quality 40 35 0) -eq 'Poor' -and (Link-Quality 5 1 10) -eq 'Poor') 'connection quality: Good, Fair, Poor'
  $pq = "Possible Setting Index: 000`nCurrent AC Power Setting Index: 0x00000000`nCurrent DC Power Setting Index: 0x00000002"
  Check (-not (PowerSave-On $pq $true) -and (PowerSave-On $pq $false) -and -not (PowerSave-On '' $true)) 'Wi-Fi power saving: per power source, nothing when unknown'
  # keeping awake: only while input went to the other PC in the last 5 minutes
  Check ([Awake]::Want($true, 1000, 1000 + 299999) -and -not [Awake]::Want($true, 1000, 1000 + 300000) -and -not [Awake]::Want($false, 1000, 1001)) 'sender stays awake 5 minutes after the last forwarded input, then sleeps'
  $lm = New-Object LossMeter; foreach ($s in 1..40) { if ($s -notin 5, 15, 25, 35) { $lm.Got($s) } }; Check ([Math]::Abs($lm.Pct - 10) -lt 1e-9) 'packet loss 10%'
  # the network adapter whose subnet holds the other PC; a real one before a virtual one
  $ips = [Net.IPAddress[]]@('192.168.1.5', '192.168.56.1', '10.0.0.5', '192.168.1.20', '100.64.0.3'); $masks = [Net.IPAddress[]]@('255.255.255.0', '255.255.255.0', '255.0.0.0', '255.255.255.0', '255.192.0.0')
  $idx = [int[]](6, 7, 8, 9, 10); $virt = [bool[]]($true, $true, $false, $false, $true)
  function Nic($ip) { [Nic]::Pick([Net.IPAddress]::Parse($ip), $idx, $ips, $masks, $virt) }
  Check ((Nic '192.168.1.30') -eq 9 -and (Nic '192.168.56.101') -eq 7 -and (Nic '100.100.1.1') -eq 10 -and (Nic '8.8.8.8') -eq -1 -and (Nic '127.0.0.1') -eq -1) 'adapter: real before virtual, VPN only when nothing else'
  $via = 0; $sp = [Nic]::Second([Net.IPAddress[]]@('192.168.1.30', '192.168.56.101', '10.0.0.7'), [Net.IPAddress]::Parse('192.168.1.30'), 9, $idx, $ips, $masks, $virt, [ref]$via)
  $none = [Nic]::Second([Net.IPAddress[]]@('192.168.1.30', '192.168.56.101'), [Net.IPAddress]::Parse('192.168.1.30'), 9, $idx, $ips, $masks, $virt, [ref]$via)
  Check ("$sp" -eq '10.0.0.7' -and $null -eq $none) 'second path: another address through another real adapter, never a virtual one'
  Check ([Nic]::Virtual('Hyper-V Virtual Ethernet Adapter') -and [Nic]::Virtual('VirtualBox Host-Only Ethernet Adapter') -and -not [Nic]::Virtual('Intel(R) Ethernet Connection I219-V')) 'virtual adapters'
  # hook watch: Raw Input saw real input and the hook none of it within 200 ms = reinstall; nothing injected, idle = nothing
  $hw = New-Object HookWatch 0, 0, 0
  Check (@(0..5000 | ? { $hw.Tick(0, 0, $_) }).Count -eq 0) 'hook watch: idle, nothing happens'
  Check (-not $hw.Tick(1, 1, 5010) -and -not $hw.Tick(5, 4, 5100) -and -not $hw.Tick(9, 8, 5400)) 'hook watch: the hook sees the input, fine'
  Check (-not $hw.Tick(9, 9, 6000) -and -not $hw.Tick(10, 9, 6250) -and -not $hw.Tick(10, 10, 6280)) 'hook watch: the hook a moment after Raw Input, fine'
  Check (-not $hw.Tick(10, 11, 7000) -and -not $hw.Tick(11, 11, 7010) -and -not $hw.Tick(12, 11, 7150)) 'hook watch: Raw Input just after a hook call is the same event'
  Check (-not $hw.Tick(13, 11, 7500) -and -not $hw.Tick(14, 11, 7699) -and $hw.Tick(15, 11, 7700)) 'hook watch: input the hook missed for 200 ms, reinstall'
  Check (-not $hw.Tick(16, 11, 7800) -and -not $hw.Tick(16, 12, 7850) -and -not $hw.Tick(20, 16, 9000)) 'hook watch: once, then the new hook answers'
  # capture: made-up Raw Input and hook structs through the real parsers and callbacks
  $h = [Link]::RawHeader; $raw = New-Object byte[] ($h + 24)
  [BitConverter]::GetBytes([long]1).CopyTo($raw, 8); [BitConverter]::GetBytes([uint16]0x400).CopyTo($raw, $h + 4); [BitConverter]::GetBytes([int16]-60).CopyTo($raw, $h + 6)
  [BitConverter]::GetBytes(3).CopyTo($raw, $h + 12); [BitConverter]::GetBytes(-2).CopyTo($raw, $h + 16)
  $mem = [Runtime.InteropServices.Marshal]::AllocHGlobal(64); $b1 = 0; $b2 = 0; $b3 = 0; $b4 = 0
  [Runtime.InteropServices.Marshal]::Copy($raw, 0, $mem, $raw.Length)
  Check ([Link]::ParseRaw($mem, [ref]$b1, [ref]$b2, [ref]$b3, [ref]$b4) -and $b1 -eq 3 -and $b2 -eq -2 -and $b3 -eq 0x400 -and $b4 -eq -60) 'raw input: movement, wheel flag and a sub-120 delta'
  [Runtime.InteropServices.Marshal]::WriteInt64($mem, 8, 0); Check (-not [Link]::ParseRaw($mem, [ref]$b1, [ref]$b2, [ref]$b3, [ref]$b4)) 'raw input: injected input (no device) ignored'
  $hl = New-Object Link; [Runtime.InteropServices.Marshal]::Copy((New-Object byte[] 64), 0, $mem, 64); [Runtime.InteropServices.Marshal]::WriteInt32($mem, 0, 0x41)
  Check ([Link]::HookTest($hl, $true, $mem) -eq 0 -and $hl.Queued -eq 0 -and $hl.HookKb -eq 1) 'hook: passes everything while this PC has control; real keys counted'
  $hl.Active = $true; Check ([Link]::HookTest($hl, $true, $mem) -eq 1 -and $hl.Queued -eq 1 -and [Link]::HookTest($hl, $false, $mem) -eq 1) 'hook: swallows and enqueues while the other PC has control'
  [Runtime.InteropServices.Marshal]::WriteInt64($mem, 16, 0x44474C4B); Check ([Link]::HookTest($hl, $true, $mem) -eq 0) "hook: DeskGlide's own input passes"
  Check ($hl.HookKb -eq 3 -and $hl.HookMs -eq 1) 'hook watch: real keys and mouse counted'
  [Runtime.InteropServices.Marshal]::WriteInt64($mem, 16, 0); [Runtime.InteropServices.Marshal]::WriteInt32($mem, 8, 0x10); [Runtime.InteropServices.Marshal]::WriteInt32($mem, 12, 1)
  Check ([Link]::HookTest($hl, $true, $mem) -eq 1 -and [Link]::HookTest($hl, $false, $mem) -eq 1 -and $hl.HookKb -eq 3 -and $hl.HookMs -eq 1) "hook: other programs' injected input swallowed, not counted as real"
  [Runtime.InteropServices.Marshal]::FreeHGlobal($mem)

  # two engines over loopback UDP: the sender fed made-up input, the receiver records what it would inject
  [Link]::NoInject = $true; $lp = 47300 + $PID % 400
  function New-Link($mons, $nm) { $e = New-Object Link; $e.SetLocal($mons); $e.Name = $nm; $e.Key = $pk; $e.Peer = [Net.IPAddress]::Loopback; $e }
  $A = New-Link $one 'PC-A'; $B = New-Link $two 'PC-B'; $A.Sender = $true; $A.Dir = 'r'; $A.SetCursor(1900, 540)
  $A.Start($lp, $lp + 1); $B.Start($lp + 1, $lp)
  function Until([scriptblock]$cond, [int]$wait = 3000) { $t0 = Get-Date; while (-not (& $cond) -and ((Get-Date) - $t0).TotalMilliseconds -lt $wait) { Start-Sleep -Milliseconds 5 }; [bool](& $cond) }
  function Took { $o = @(); $s = $null; while ($B.Injected.TryDequeue([ref]$s)) { $o += ($s -split '\|')[1] }; $o }
  Check (Until { $A.Up -and $B.Up -and $A.HasRemote -and $B.HasRemote }) 'link: connected over loopback'
  $m = $null; while ($A.Log.TryDequeue([ref]$m)) {}; 1..5 | % { $A.Key = [byte[]]$pk.Clone(); Start-Sleep -Milliseconds 30 }   # the app re-sets the key every poll (5.2 flapped)
  $flap = $false; while ($A.Log.TryDequeue([ref]$m)) { if ($m -match 'new pairing') { $flap = $true } }
  Check ($A.Up -and -not $flap) 'link: the same key handed over again keeps the session'
  $A.FeedMouse(10, 0, 0, 0); Check (-not (Until { $A.Active } 300)) 'link: 10 px short of the edge stays here'
  $A.FeedMouse(20, 0, 0, 0); Check ((Until { $A.Active -and $B.Controlled }) -and (Took) -contains 'move 0,720') 'link: crossing the right edge; enters halfway down'
  $A.FeedMouse(10, 4, 0, 0); Check ((Until { $B.Injected.Count }) -and (Took) -contains 'move 15,726') 'link: moves scaled by the DPI ratio (96 -> 144)'
  $A.FeedKey(0xA0, 0x2A, 0, 1); $A.FeedKey(0x41, 0x1E, 0, 2); $A.FeedKey(0x41, 0x1E, 0x80, 3); $A.FeedKey(0xA2, 0x21D, 0, 4); $A.FeedKey(0xA5, 0x38, 1, 4)
  $A.FeedMouse(0, 0, 0x1, 0); $A.FeedMouse(0, 0, 0x2, 0); $A.FeedMouse(0, 0, 0x40, 0); $A.FeedMouse(0, 0, 0x400, 60); $A.FeedMouse(0, 0, 0x800, -30)
  Check (Until { $B.Injected.Count -ge 9 }) 'link: keys, buttons and wheel arrive'
  $got = (Took) -join ';'
  Check ($got -eq 'key 2A down;key 1E down;key 1E up;key 38 ext down;button 0 down;button 0 up;button 3 down;wheel 60;hwheel -30') "link: in order, AltGr's fake LCtrl dropped, X1, small wheel steps: $got"
  $A.FeedMouse(-40, 0, 0, 0); Check ((Until { -not $A.Active -and -not $B.Controlled }) -and $A.Up) 'link: back across the left edge of the other PC'
  $rel = (Took) -join ';'; Check ($rel -match 'key 2A up' -and $rel -match 'key 38 ext up' -and $rel -match 'button 3 up') "link: everything held released on leave: $rel"
  # panic key: Ctrl+Alt+Pause (Pause arrives as Break with Ctrl)
  $A.FeedMouse(30, 0, 0, 0); Check (Until { $A.Active -and $B.Controlled }) 'link: across again'
  [void](Took); $A.FeedKey(0xA2, 0x1D, 0, 1); $A.FeedKey(0xA4, 0x38, 0, 2); $A.FeedKey(3, 0x46, 1, 3)
  Check ((Until { -not $A.Active -and -not $B.Controlled }) -and ((Took) -join ';') -match 'key 1D down;key 38 down.*key (1D|38) up;key (1D|38) up$') 'link: panic key takes control back, releases Ctrl and Alt there'
  # game mode: the other PC's game holds the pointer, so raw running sums go instead
  $A.Game = $true; $B.TestBlocked = $true; Start-Sleep -Milliseconds 400   # a heartbeat carries it over
  $A.FeedMouse(30, 0, 0, 0); Check (Until { $A.Active }) 'link: across, game on the other PC'
  [void](Took); 1..4 | % { $A.FeedMouse(1, 1, 0, 0); Start-Sleep -Milliseconds 3 }
  Check ((Until { $B.Injected.Count -ge 2 }) -and @(Took | ? { $_ -like 'rel *' }).Count -ge 2) 'game mode: relative movement'
  $A.Panic(); Check (Until { -not $A.Active }) 'panic from the hotkey'; $A.Game = $false; $B.TestBlocked = $false
  $A.TestBlocked = $true; $A.SetCursor(1900, 540); $A.FeedMouse(30, 0, 0, 0)
  Check (-not (Until { $A.Active } 300)) 'link: no crossing while a game holds the pointer here'; $A.TestBlocked = $false
  # latency over loopback: made-up input to what the receiver would inject
  $A.SetCursor(1900, 540); $A.FeedMouse(30, 0, 0, 0); [void](Until { $A.Active -and $B.Controlled }); [void](Until { $false } 100); [void](Took)
  $fed = $null; while ($A.Fed.TryDequeue([ref]$fed)) {}
  function Lat([scriptblock]$feed, [int]$n) {
    $ms = foreach ($i in 1..$n) { $c = $B.Injected.Count; & $feed $i; [void](Until { $B.Injected.Count -gt $c } 1000); $s = $null; [void]$B.Injected.TryDequeue([ref]$s); $t = 0L; [void]$A.Fed.TryDequeue([ref]$t); ([long]($s -split '\|')[0] - $t) / 1000.0 }
    $ms = @($ms | sort); '{0:0.00}/{1:0.00}/{2:0.00} ms' -f $ms[[int]($n / 2)], $ms[[int]($n * 0.99) - 1], $ms[-1]
  }
  $script:latMove = Lat { param($i) $A.FeedMouse($(if ($i % 2) { 3 } else { -3 }), 0, 0, 0) } 300
  $A.FeedKey(0x41, 0x1E, 0, 0); $A.FeedKey(0x41, 0x1E, 0x80, 0); [void](Until { $B.Injected.Count -ge 4 }); [void](Took); while ($A.Fed.TryDequeue([ref]$fed)) {}   # Ctrl and Alt still held from the panic test: reconciled first
  $script:latKey = Lat { param($i) $A.FeedKey(0x41, 0x1E, $(if ($i % 2) { 0 } else { 0x80 }), $i) } 300
  # packet loss: 30% each way, still every key once and in order
  $A.DropPct = 30; $B.DropPct = 30; [void](Took)
  foreach ($i in 0..99) { $A.FeedKey(0x41 + $i % 10, 0x10 + $i % 10, 0, $i); $A.FeedKey(0x41 + $i % 10, 0x10 + $i % 10, 0x80, $i) }
  Check (Until { $B.Injected.Count -ge 200 } 8000) "loss: all 200 key events arrive ($($B.Injected.Count))"
  $seq = @(Took); $want = foreach ($i in 0..99) { 'key {0:X2} down' -f (0x10 + $i % 10); 'key {0:X2} up' -f (0x10 + $i % 10) }
  Check (($seq -join ';') -eq ($want -join ';')) 'loss: once each, in order'
  $A.DropPct = 0; $B.DropPct = 0
  # a phone hotspot: 10% loss and 0..50 ms jitter each way, then a 300 ms outage. No cursor jumps, every key once and in
  # order, control kept through the outage.
  $script:rtt = $A.Rtt; $script:got = @(); function Pull { $script:got += @(Took) }
  $script:want = @(); $script:kn = 0
  function Keys($n) { foreach ($i in 1..$n) { $script:kn++; $c = $script:kn % 10; $A.FeedKey(0x41 + $c, 0x10 + $c, 0, $kn); $A.FeedKey(0x41 + $c, 0x10 + $c, 0x80, $kn); $script:want += ('key {0:X2} down' -f (0x10 + $c)), ('key {0:X2} up' -f (0x10 + $c)) } }
  function GotKeys { @($script:got | ? { $_ -like 'key *' }) }
  $A.DropPct = 10; $B.DropPct = 10; $A.JitterMs = 50; $B.JitterMs = 50; [void](Until { $false } 500); [void](Took); $j0 = $B.Jumps; $st0 = $B.Stale
  foreach ($i in 1..300) { $A.FeedMouse($(if ($i -le 150) { 4 } else { -4 }), $(if ($i -le 150) { 1 } else { -1 }), 0, 0); if ($i % 15 -eq 0) { Keys 1 }; Start-Sleep -Milliseconds 2; if ($i % 50 -eq 0) { Pull } }
  [void](Until { Pull; (GotKeys).Count -ge $want.Count } 3000); [void](Until { $false } 300); Pull
  $last = @($got | ? { $_ -like 'move *' })[-1]
  Check ($B.Jumps -eq $j0 -and $last -eq "move $($A.Pointer)") "hotspot: no cursor jumps ($($B.Jumps - $j0)), pointer ends where the sender has it ($last / $($A.Pointer))"
  $A.Outage(300); $B.Outage(300); $t0 = Get-Date; Keys 10
  $ok = Until { Pull; (GotKeys).Count -ge $want.Count } 4000; $script:recMs = ((Get-Date) - $t0).TotalMilliseconds - 300
  Check ($ok -and ((GotKeys) -join ';') -eq ($want -join ';')) "hotspot: all $($want.Count) key events once and in order, through the outage"
  Check ($A.Active -and $B.Controlled -and $A.Up -and $B.Up -and $B.Jumps -eq $j0) 'hotspot: a 300 ms outage keeps control and the session'
  $script:jumps = $B.Jumps - $j0; $script:hot = 'rtt {0:0} ms, jitter {1:0} ms, loss {2:0}%, {3} stale mouse packets dropped' -f $A.Rtt, $A.Jitter, $A.Loss, ($B.Stale - $st0)
  $A.DropPct = 0; $B.DropPct = 0; $A.JitterMs = 0; $B.JitterMs = 0; [void](Until { $false } 200); [void](Took)
  # losing the link: control comes back, keys released, then it reconnects by itself
  $A.FeedKey(0x42, 0x30, 0, 1); [void](Until { $B.Injected.Count }); [void](Took)
  $t0 = Get-Date; $A.DropPct = 100; $B.DropPct = 100
  Check ((Until { -not $A.Up -and -not $A.Active -and -not $B.Controlled } 2500) -and (Took) -contains 'key 30 up') 'link lost after 1.5 s: control back here, held key released there'
  $script:lossMs = ((Get-Date) - $t0).TotalMilliseconds
  $A.DropPct = 0; $B.DropPct = 0; $t0 = Get-Date
  Check (Until { $A.Up -and $B.Up } 3000) 'link: reconnects by itself (backoff at most 2 s)'
  $script:backMs = ((Get-Date) - $t0).TotalMilliseconds
  # the other PC restarts: a new engine on the same port, found again
  $B.Stop(); $B = New-Link $two 'PC-B'; $B.Start($lp + 1, $lp)
  Check (Until { $A.Up -and $B.Up } 4000) 'link: the other PC restarted and was found again'
  # an older or newer DeskGlide says so, instead of "wrong key"
  $hk = [Dg]::SessionKey($pk, 'link hello', [byte[]]@()); $hb = New-Object byte[] 20; [Text.Encoding]::UTF8.GetBytes('PC-C').CopyTo($hb, 16)
  $vp = [LinkProto]::Seal($hk, 0, [byte[]](9..16), $hb, $hb.Length, [LinkProto]::Version + 1); $u = New-Object Net.Sockets.UdpClient; [void]$u.Send($vp, $vp.Length, '127.0.0.1', $lp); $u.Close()
  Check ((Until { $A.VersionMsg }) -and $A.VersionMsg -match 'PC-C is newer. Update DeskGlide on this PC') "version mismatch shown: $($A.VersionMsg)"
  $A.Stop(); $B.Stop(); [Link]::NoInject = $false

  # admin control: build the service and helper (Windows' csc.exe), run the service's own security self-test, then the
  # service in console mode (this user, temp folder, its own pipe, no injection: the helper logs what it would inject)
  # receiving from an engine here over loopback
  $sb = Join-Path $env:TEMP "dg-svc-$PID"; Build-Service $PSScriptRoot $sb
  $st = & "$sb\DeskGlideService.exe" -SelfTest; Check ($LASTEXITCODE -eq 0 -and ($st -join "`n") -match 'service self-test ok \((\d+) checks\)') "service self-test: $($st | select -Last 1)"
  $script:svcChecks = $matches[1]; $st | ? { $_ -match '^(  \w|authorization|this process|paths|pairing)' } | % { "  $_" }
  $sd = Join-Path $sb 'data'; $sl = Join-Path $sd 'service.log'; [void](New-Item -ItemType Directory -Force $sd); $pipe = "DeskGlideTest-$PID"
  function Logged([string]$pat) { (Test-Path $sl) -and ((Get-Content $sl -Raw) -match $pat) }
  $sp = Start-Process "$sb\DeskGlideService.exe" "-Console -Data `"$sd`" -Pipe $pipe -Port $($lp + 1) -PeerPort $lp -NoInject -SeedKey $([Convert]::ToBase64String($pk))" -PassThru -WindowStyle Hidden
  try {
    [Link]::NoInject = $true; $A = New-Link $one 'PC-A'; $A.Sender = $true; $A.Dir = 'r'; $A.SetCursor(1900, 540); $A.Start($lp, $lp + 1)
    Check ((Until { $A.Up -and $A.HasRemote } 15000) -and (Until { Logged 'helper: input desktop: ' } 5000))   # the helper can take 8+ s to start on a busy PC 'service: connected; its helper follows the input desktop and reports the monitors'
    $A.FeedMouse(30, 0, 0, 0); Check ((Until { $A.Active }) -and (Until { Logged 'would inject mouse -?\d+,-?\d+ data 0 flags C001' })) 'service: across the edge, an absolute move through the helper'
    $A.FeedKey(0x41, 0x1E, 0, 1); $A.FeedKey(0x41, 0x1E, 0x80, 2)
    Check (Until { (Logged 'would inject key vk 00 sc 1E flags 8') -and (Logged 'would inject key vk 00 sc 1E flags 10') }) 'service: a key down and up by scan code'
    $A.FeedKey(0xA2, 0x1D, 0, 3); $A.FeedKey(0xA4, 0x38, 0, 4); $A.FeedKey(0x23, 0x4F, 1, 5); $A.FeedKey(0x23, 0x4F, 0x81, 6)
    Check ((Until { Logged 'would press Ctrl\+Alt\+Del \(SendSAS\)' }) -and -not (Logged 'sc 4F')) 'service: Ctrl+Alt+End presses Ctrl+Alt+Del (SendSAS), End itself not injected'
    $s1 = [SvcPipe]::Call($pipe, 'status', 2000, $false)
    Check ($s1 -match '^ok enabled=1 paired=1 link=1 up=1 controlled=1 helper=1') "service pipe: status for a normal user: $s1"
    $deny = foreach ($v in "pair $([Convert]::ToBase64String((New-Object byte[] 32))) - -", 'unpair', 'disable', 'enable', 'peer 1.2.3.4', 'bogus') { [SvcPipe]::Call($pipe, $v, 2000, $false) }
    Check (@($deny | ? { $_ -ne 'refused' }).Count -eq 0 -and (Logged "refused 'pair' from .*only an elevated administrator")) 'service pipe: pairing and settings refused for a non-elevated user, and logged'
    Check ($null -eq [SvcPipe]::Call($pipe, 'status', 2000, $true)) 'service pipe: the app talks only to the installed service in session 0'
    # as a normal user (5.2 couldn't, so the app never saw its service): Windows' service control manager passes, a LOCAL SERVICE pipe doesn't
    function Server-Ok($n) { $c = New-Object IO.Pipes.NamedPipeClientStream('.', $n, [IO.Pipes.PipeDirection]::InOut); try { $c.Connect(1000); [SvcPipe]::ServerIs($c.SafePipeHandle.DangerousGetHandle()) } catch { $false } finally { $c.Dispose() } }
    Check ((Server-Ok 'ntsvcs') -and -not (Server-Ok 'eventlog')) 'service pipe: a SYSTEM service is recognised by its pipe owner, other services are not'
    Check ([SvcPipe]::Call($pipe, 'panic', 2000, $false) -eq 'ok' -and (Until { [SvcPipe]::Call($pipe, 'status', 2000, $false) -match 'controlled=0' }) -and (Until { (Logged 'sc 1D flags 10') -and (Logged 'sc 38 flags 10') })) 'service pipe: panic ends control, releases the held Ctrl and Alt'
    $bad = [LinkProto]::Seal([Dg]::DeriveKey('zzzz-zzzz'), 0, [byte[]](1..8), (New-Object byte[] 20), 20, [LinkProto]::Version)
    $u = New-Object Net.Sockets.UdpClient; 1..200 | % { [void]$u.Send($bad, $bad.Length, '127.0.0.1', $lp + 1) }; $u.Close(); Start-Sleep -Milliseconds 300
    $s2 = [SvcPipe]::Call($pipe, 'status', 2000, $false)
    Check ($s2 -match 'refused=(\d+)' -and [int]$matches[1] -ge 150 -and $s2 -match 'up=1') "service: a flood of 200 hellos under another key dropped unchecked past the rate limit, session up ($s2)"
    $A.Stop(); [Link]::NoInject = $false
  } finally {
    Set-Content (Join-Path $sd 'stop') ''; [void]$sp.WaitForExit(8000)
    Check ($sp.HasExited) 'service: stops cleanly'
    Start-Sleep -Milliseconds 300
    Check (-not (Get-Process DeskGlideHelper -ErrorAction SilentlyContinue | ? { $_.Path -like "$sb*" })) 'service: its helper exits with it'
    Remove-Item -Recurse -Force $sb
  }
  "link loopback: moves p50/p99/max $latMove, keys $latKey, heartbeat RTT $('{0:0.00}' -f $rtt) ms, loss noticed after $([int]$lossMs) ms, back after $([int]$backMs) ms"
  "service: $svcChecks security checks, loopback with this sender ok"
  "link hotspot (10% loss, 0..50 ms jitter, 300 ms outage): cursor jumps $jumps, keys in order, recovered $([int]$recMs) ms after the outage; $hot"

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
  Check ((Load-Config).link -and (Load-Config).panicKey -eq 'Ctrl+Alt+Pause') 'new install: keyboard and mouse sharing on'
  Set-Content $cfgPath '{"peer":"PC-B","key":"a2V5","input":15,"headphones":true,"syncAt":5,"audio":"both"}'
  $C = Load-Config
  Check (-not $C.link) 'upgrade: keyboard and mouse sharing stays off until turned on (Synergy keeps working)'
  Check ($C.hp -eq 'PC-A' -and $C.syncAt -gt 5 -and -not $C.Contains('headphones') -and $C.key -eq 'a2V5' -and $C.peer -eq 'PC-B' -and $C.audio -eq 'both' -and $C.vol -eq 100) 'upgrade from DeskGlide 2 (headphones here)'
  Set-Content $cfgPath '{"peer":"PC-B","key":"a2V5","headphones":false,"syncAt":5}'
  $C = Load-Config; Check ($C.hp -eq '' -and $C.syncAt -eq 5 -and $C.key -eq 'a2V5') 'upgrade from DeskGlide 2 (headphones elsewhere)'
  $C = Load-Config; $C.peer = 'PC-B'; $C.input = 17; $C.audio = 'both'; $C.hp = 'PC-B'; $C.syncAt = 1764000000000; $C.inputs = @{ MSI4CE8 = 17 }; $C.monOff = @('X'); Save-Config
  $C = Load-Config
  Check ($C.peer -eq 'PC-B' -and $C.input -eq 17 -and $C.audio -eq 'both' -and $C.hp -eq 'PC-B' -and $C.syncAt -eq 1764000000000 -and $C.monitor -eq $true -and $C.inputs.MSI4CE8 -eq 17 -and $C.inputs -is [hashtable] -and @($C.monOff).Count -eq 1) 'config round trip'
  # pairing key at rest: DPAPI-protected for this Windows user; DeskGlide 3's plain key is migrated on the next save
  $raw = Get-Content $cfgPath -Raw
  Check ($raw -match '"key":\s*"dpapi:' -and $raw -notmatch 'a2V5' -and $C.key -eq 'a2V5') 'key protected on disk, plain in memory'
  $C.adminKey = 'c3Zj'; $C.peerAdmin = $true; Save-Config; $raw = Get-Content $cfgPath -Raw; $C = Load-Config
  Check ($raw -match '"adminKey":\s*"dpapi:' -and $raw -notmatch 'c3Zj' -and $C.adminKey -eq 'c3Zj' -and $C.peerAdmin) "the other PC's admin service key protected on disk too"
  Check (-not (Test-Path "$cfgPath.tmp")) 'config written atomically (no temp file left)'
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

# ---------------------------------------------------------------- admin control (optional, elevated)
# DeskGlideService.cs and DeskGlideHelper.cs, compiled with the C# compiler that comes with Windows (no downloads). The
# setup copies them into C:\Program Files\DeskGlide (only administrators can change it) and builds them there; the service
# never runs anything from a folder a user can change. Like any installer, it trusts DeskGlide's files as they are when you
# approve Windows' prompt.
function Install-AdminService {
  Write-Host 'Installing the DeskGlide service...'
  $old = Get-Service $svcName -ErrorAction SilentlyContinue
  if ($old -and $old.Status -ne 'Stopped') { Stop-Service $svcName -Force; $old.WaitForStatus('Stopped', '00:00:20') }
  [void](New-Item -ItemType Directory -Force $svcDir)
  # Program Files already lets only administrators change it; this makes sure: SYSTEM and Administrators full, Users read
  [void](& icacls.exe $svcDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /Q)
  foreach ($f in 'DeskGlide.cs', 'DeskGlideService.cs', 'DeskGlideHelper.cs') { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $f) (Join-Path $svcDir $f) -Force }
  Build-Service $svcDir $svcDir
  [void](& icacls.exe $svcDir /setowner '*S-1-5-32-544' /T /Q)
  $exe = Join-Path $svcDir 'DeskGlideService.exe'
  if (-not $old) { [void](New-Service -Name $svcName -BinaryPathName "`"$exe`"" -DisplayName 'DeskGlide admin control' -StartupType Automatic -Description "Lets DeskGlide on your other PC control this PC's admin windows, UAC prompts and lock screen. Turn it off in DeskGlide.") }
  [void](& sc.exe failure $svcName reset= 86400 actions= restart/5000/restart/5000/restart/60000)
  Start-Service $svcName
  $t0 = Get-Date; while (-not ([SvcPipe]::Call($svcName, 'status', 1000, $true)) -and ((Get-Date) - $t0).TotalSeconds -lt 15) { Start-Sleep -Milliseconds 300 }
  if (-not [SvcPipe]::Call($svcName, 'status', 1000, $true)) { throw "The service doesn't answer. Its log: $svcData\service.log" }
  Write-Host 'The service is running.'
}
# The service's own key: an ECDH exchange with the other PC under the pairing key, confirmed by the user comparing a number
# on both screens (SvcPair). The key then goes to the service over its pipe, which takes it only from an elevated administrator.
function Pair-AdminService {
  $key = [Convert]::FromBase64String($SetupKey); $ip = [Net.IPAddress]::Parse($SetupPeer)
  if ($SetupPeerName -notmatch '^[A-Za-z0-9._-]{1,63}$') { throw "bad PC name $SetupPeerName" }
  $p = New-Object SvcPair; $mine = $p.Pub; $id = [Dg]::Hex([Dg]::Random(8)); $k = $null; $chk = $null
  $u = New-Object Net.Sockets.UdpClient(0); $u.Client.ReceiveTimeout = 500
  try {
    $offer = [Text.Encoding]::UTF8.GetBytes([Dg]::Seal($key, (@{ n = $Name; adm = 'offer'; id = $id; pub = [Convert]::ToBase64String($mine) } | ConvertTo-Json -Compress)))
    Write-Host "Pairing with $SetupPeerName ($SetupPeer). DeskGlide 5.2 or newer must be running there..."
    $t0 = Get-Date
    while (-not $k -and ((Get-Date) - $t0).TotalSeconds -lt 120) {
      [void]$u.Send($offer, $offer.Length, (New-Object Net.IPEndPoint($ip, $PeerPort)))
      $until = (Get-Date).AddSeconds(2)
      while (-not $k -and (Get-Date) -lt $until) {
        $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
        try { $raw = $u.Receive([ref]$ep) } catch { continue }
        $json = [Dg]::Open($key, [Text.Encoding]::UTF8.GetString($raw)); if (-not $json) { continue }
        $m = $json | ConvertFrom-Json; if ($m.adm -ne 'answer' -or $m.id -ne $id) { continue }
        try { $theirs = [Convert]::FromBase64String([string]$m.pub) } catch { continue }
        $k = $p.Finish($mine, $theirs, $theirs, [ref]$chk)
      }
    }
    if (-not $k) { throw "$SetupPeerName didn't answer. Check that DeskGlide 5.2 or newer runs there, then turn admin control on again." }
    Write-Host ''; Write-Host "      $chk" -ForegroundColor Cyan; Write-Host ''
    $yes = Read-Host "DeskGlide on $SetupPeerName shows a number now. Is it $chk? Type y and press Enter if it is"
    if ($yes -notmatch '^\s*y') { throw "Not paired: the numbers must match. If they didn't, a program on this PC or your network may be in between." }
    $r = [SvcPipe]::Call($svcName, "pair $([Convert]::ToBase64String($k)) $SetupPeer $SetupPeerName", 5000, $true)
    if ($r -ne 'ok') { throw "The service didn't take the pairing: $(if ($r) { $r } else { [SvcPipe]::LastError })" }
    $done = [Text.Encoding]::UTF8.GetBytes([Dg]::Seal($key, (@{ n = $Name; adm = 'done'; id = $id; proof = [Convert]::ToBase64String([SvcPair]::Proof($k, $id)) } | ConvertTo-Json -Compress)))
    1..3 | % { [void]$u.Send($done, $done.Length, (New-Object Net.IPEndPoint($ip, $PeerPort))); Start-Sleep -Milliseconds 300 }
  } finally { $u.Close(); $p.Dispose() }
  Write-Host "Paired. $SetupPeerName can now use this PC's admin windows, UAC prompts and lock screen."
  Write-Host ''
  Write-Host "Ctrl+Alt+Del can't travel between PCs: Windows always handles it on the PC where it is pressed. DeskGlide can press it"
  Write-Host "here when you press Ctrl+Alt+End on $SetupPeerName. That needs the Windows policy 'Disable or enable software Secure"
  Write-Host "Attention Sequence' set to allow services (SoftwareSASGeneration = 1 under HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\"
  Write-Host 'Policies\System). Other services on this PC could then press Ctrl+Alt+Del too (they already run as SYSTEM). Turning admin'
  Write-Host 'control off puts the old value back.'
  $sas = Read-Host 'Allow Ctrl+Alt+Del? Type y and press Enter to allow it, or just press Enter for no'
  & (Join-Path $svcDir 'DeskGlideService.exe') -Sas $(if ($sas -match '^\s*y') { 'on' } else { 'off' })
}
function Remove-AdminService {
  $exe = Join-Path $svcDir 'DeskGlideService.exe'
  if (Test-Path -LiteralPath $exe) { & $exe -Sas off }   # the Ctrl+Alt+Del policy as it was before DeskGlide
  $sv = Get-Service $svcName -ErrorAction SilentlyContinue
  if ($sv) {
    if ($sv.Status -ne 'Stopped') { Stop-Service $svcName -Force; $sv.WaitForStatus('Stopped', '00:00:20') }
    [void](& sc.exe delete $svcName)
  }
  Get-Process DeskGlideHelper -ErrorAction SilentlyContinue | ? { $_.Path -eq (Join-Path $svcDir 'DeskGlideHelper.exe') } | Stop-Process -Force
  Start-Sleep -Milliseconds 500
  foreach ($d in $svcDir, $svcData) { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force } }
  $parent = Split-Path $svcData; if ((Test-Path -LiteralPath $parent) -and -not (Get-ChildItem -LiteralPath $parent -Force)) { Remove-Item -LiteralPath $parent -Force }
  Write-Host 'Admin control removed: the service, its program folder and its key are gone.'
}
if ($ServiceSetup -or $ServiceRemove) {
  $Host.UI.RawUI.WindowTitle = 'DeskGlide admin control'
  try {
    if (-not (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
      throw 'Admin control is set up from the DeskGlide window, which asks Windows for permission first.'
    }
    if ($ServiceRemove) { Remove-AdminService } else { Install-AdminService; Pair-AdminService; Write-Host ''; Write-Host 'Admin control is on.' -ForegroundColor Green }
  } catch { Write-Host "Admin control: $($_.Exception.Message)" -ForegroundColor Red }
  [void](Read-Host 'Press Enter to close'); return
}

if ($Install -or $Uninstall) {
  # stop running copies (also DeskGlide 1's deskglide.ps1 / deskglide-audio.ps1, which this replaces)
  Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    ? { $_.ProcessId -ne $PID -and $_.CommandLine -like '*deskglide*.ps1*' } |
    % { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Milliseconds 500
  Restore-Muted
  if ($Uninstall) {
    if (Test-Path -LiteralPath (Join-Path $svcDir 'DeskGlideService.exe')) {   # admin control is installed: removing it needs Windows' permission
      'Removing admin control (Windows asks for permission)...'
      try { Start-Process "$PSHOME\powershell.exe" "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -ServiceRemove" -Verb RunAs -Wait } catch { "Admin control stays installed: $($_.Exception.Message)" }
    }
    Set-Startup $false
    Remove-Item -LiteralPath $appDir -Recurse -Force -ErrorAction SilentlyContinue
    "DeskGlide removed. Your settings are kept in $ConfigDir"; return
  }
  $files = @(if ($PSScriptRoot -ne $appDir) { Copy-App $PSScriptRoot $appDir } else { $appFiles | % { Join-Path $appDir $_ } | ? { Test-Path $_ } })
  # downloaded from the internet: without this Windows asks before every start
  $files | ? { $_ -is [string] -and (Test-Path -LiteralPath $_) } | % { Unblock-File -LiteralPath $_ }
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
    if ($m.adm) { Admin-Pairing $m $ep; continue }   # pairing the other PC's admin control service: its own messages
    # ponytail: replay guard is "timestamp must grow"; it resets after 30 s of silence so a peer whose clock jumped back recovers
    if (((Get-Date) - $S.peerSeen).TotalSeconds -gt 30) { $S.lastT = 0 }
    if ([long]$m.t -le $S.lastT) { continue }
    $S.lastT = [long]$m.t; $S.okCtl++
    if (-not $S.peerAddr -or -not $S.peerAddr.Equals($ep.Address)) { Say "Found $($m.n) at $($ep.Address)." }
    $S.peerAddr = $ep.Address; $S.peerSeen = Get-Date; $S.peerInput = [int]$m.i
    if ($null -ne $m.as -and [bool]$m.as -ne [bool]$C.peerAdmin) { $C.peerAdmin = [bool]$m.as; Save-Config }   # kept: the sign-in screen sends nothing
    $S.peerVer = [int]$m.ver; $S.peerScreen = if ($m.sn) { [string]$m.sn } else { [string]$m.n }
    $S.peerInputs = To-Hash $m.mi; $S.peerOffer = $m.fo; $S.peerCable = [bool]$m.vc; $S.peerClip = $m.co
    # remember the address for the next start; only replace it once it went quiet, so a peer on two adapters doesn't flip-flop
    if ($S.fixedIp -and $S.fixedIp.Equals($ep.Address)) { $S.fixedSeen = Get-Date }
    elseif (((Get-Date) - $S.fixedSeen).TotalSeconds -gt 10) { $C.peerAddress = "$($ep.Address)"; $S.fixedIp = $ep.Address; $S.fixedSeen = Get-Date; Save-Config }
    if ($m.s) { $S.peerLinks = @($m.l | % { $w = "$_" -split ' '; if ($w.Count -eq 3 -and $opp[$w[1]]) { [pscustomobject]@{ from = $w[0]; dir = $w[1]; to = $w[2] } } }) }
    if (Merge-Settings $C $m) { Save-Config; Update-Menu }
    # follow the server when where the mouse is changes there (not every message, so a hotkey here isn't undone by a stale one)
    if ($m.s -and -not $S.server -and -not $C.link -and [bool]$m.sa -ne $S.lastSa) { $S.lastSa = [bool]$m.sa; if ($m.sa) { Set-Active 'peer' $m.n } else { Set-Active 'me' $Name } }
    if ([long]$m.hk -gt $S.hkSeen) {   # a hotkey on the other PC
      $S.hkSeen = [long]$m.hk; $S.want = $null
      if ($m.ha -eq $Name) { Set-Active 'me' $S.screen } elseif ($m.ha) { Set-Active 'peer' $S.peerScreen }
    }
  }
}

# The other PC's elevated setup pairs its admin control service with this PC (SvcPair): answer its ECDH offer and show the
# number to compare there; once the user confirmed it there (and the service took the key), keep the service's key.
function Admin-Pairing($m, $ep) {
  if ($m.adm -eq 'offer') {
    if (-not $S.adminPend -or $S.adminPend.id -ne [string]$m.id) {   # it resends its offer: the same answer each time
      try { $theirs = [Convert]::FromBase64String([string]$m.pub) } catch { return }
      $p = New-Object SvcPair; $mine = $p.Pub; $chk = $null
      try { $k = $p.Finish($theirs, $mine, $theirs, [ref]$chk) } finally { $p.Dispose() }
      if (-not $k) { return }
      $S.adminPend = @{ id = [string]$m.id; key = $k; check = $chk; mine = $mine; at = Get-Date }
      Say "Admin control on $($m.n): check that it shows $chk, then confirm there." info
      if (-not $Console) { Show-Window }
    }
    $a = $S.adminPend
    $b = [Text.Encoding]::UTF8.GetBytes([Dg]::Seal($S.key, (@{ n = $Name; adm = 'answer'; id = $a.id; pub = [Convert]::ToBase64String($a.mine) } | ConvertTo-Json -Compress)))
    try { [void]$udp.Send($b, $b.Length, $ep) } catch {}
  } elseif ($m.adm -eq 'done' -and $S.adminPend -and [string]$m.id -eq $S.adminPend.id) {
    $proof = try { [Convert]::FromBase64String([string]$m.proof) } catch { $null }
    if ($proof -and [Dg]::Hex($proof) -eq [Dg]::Hex([SvcPair]::Proof($S.adminPend.key, $S.adminPend.id))) {
      $S.adminKey = $S.adminPend.key; $C.adminKey = [Convert]::ToBase64String($S.adminKey); $C.peerAdmin = $true; Save-Config
      Say "Admin control on $($m.n) is paired with this PC." info
    }
    $S.adminPend = $null
  }
}

function Set-Active($new, [string]$screen) {
  if ($new -eq $S.active) { return }
  $old = $S.active; $S.active = $new; $S.activeName = $screen; $S.activeSince = Get-Date; $S.inputOk = $false
  Say "Mouse is on $(if ($new -eq 'me') { 'this PC' } elseif ($C.peer) { $C.peer } else { $screen })."
  if ($S.server) { Send-State }   # tell the peer right away; it wakes its screen when the mouse arrives there
  if ($new -eq 'me' -and $old) { [Dg]::WakeDisplay() }   # so the monitor doesn't switch to a sleeping screen
  if ($new -eq 'me') { Reattach-Monitors; Fetch-Files; Fetch-Clip }
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
  foreach ($h in @(@(1, $C.hotkeyPeer), @(2, $C.hotkeyMe), @(3, $C.panicKey))) {
    $k = Parse-Hotkey $h[1]
    if (-not $k) { [void]$S.msgWin.SetHotkey($h[0], 0, 0); continue }
    $vk = if ($k.vk -eq 0x13 -and ($k.mods -band 2)) { 3 } else { $k.vk }   # Ctrl+Pause arrives as Break
    if (-not $S.msgWin.SetHotkey($h[0], [uint32]$k.mods, [uint32]$vk)) { $bad += $k.text }
  }
  $S.hkErr = if ($bad.Count) { "$($bad -join ' and ') $(if ($bad.Count -gt 1) { 'are' } else { 'is' }) in use by another program. Choose another key." } else { '' }
  if ($bad.Count) { Say $S.hkErr }
}
function Set-HotkeyText([string]$which, [string]$text) {   # from the Settings card
  $k = Parse-Hotkey $text
  if (-not $k) { $S.hkErr = "`"$text`" isn't a hotkey DeskGlide understands. Use Ctrl, Alt, Shift or Win with an arrow, a letter, a digit, F1-F24 or Pause, like Ctrl+Alt+Right."; return }
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
function Check-Clipboard {   # the clipboard changed: offer copied files (and with Link, text and pictures) to the other PC
  [MsgWin]::ClipChanged = $false
  $list = @(); $text = $null; $img = $null
  try {
    if ([Windows.Forms.Clipboard]::ContainsFileDropList()) { $list = @([Windows.Forms.Clipboard]::GetFileDropList()) }
    elseif ((Link-Used) -and ((Get-Date) - $S.clipSetAt).TotalSeconds -gt 1) {   # not the change DeskGlide just made
      if ([Windows.Forms.Clipboard]::ContainsText()) { $text = [Windows.Forms.Clipboard]::GetText() } elseif ([Windows.Forms.Clipboard]::ContainsImage()) { $img = [Windows.Forms.Clipboard]::GetImage() }
    } elseif (Link-Used) { return }
  } catch { return }   # busy: next change
  Offer-Clip $text $img
  if (-not $C.files) { return }
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
function Offer-Clip($text, $img) {   # text or a picture for the other PC, pulled when the mouse gets there
  $kind = ''; $bytes = $null
  if ($text) { $kind = 'text'; $bytes = [Text.Encoding]::UTF8.GetBytes($text) }
  elseif ($img) { $ms = New-Object IO.MemoryStream; $img.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $img.Dispose(); $kind = 'png'; $bytes = $ms.ToArray() }
  $sig = if ($bytes) { [Dg]::Hex(([Security.Cryptography.SHA256]::Create()).ComputeHash($bytes)) } else { '' }
  if ($sig -eq $S.clipSig) { return }
  $S.clipSig = $sig
  if ($bytes -and [Clip]::Offer($kind, $bytes)) { $S.clipOffer = @{ id = [Clip]::OfferId; k = $kind; b = $bytes.Length } }
  elseif (-not $S.clipOffer) { return } else { [void][Clip]::Offer('', $null); $S.clipOffer = $null }   # nothing, or over 32 MB: stays here
  Send-State
}
function Fetch-Clip {   # the mouse arrived here (Link): pull the text or picture copied on the other PC
  $o = $S.peerClip
  if (-not (Link-Used) -or -not $o -or -not $o.id -or $o.id -eq $S.clipGot -or [Clip]::Status -eq 'busy' -or -not $S.peerAddr) { return }
  $S.clipGot = [string]$o.id; [Clip]::Fetch("$($S.peerAddr)", $PeerPort + 1, $S.key, [string]$o.id)
}
function Poll-Clip {
  $st = [Clip]::Status
  if ($st -eq '' -or $st -eq 'busy') { return }
  [Clip]::Status = ''
  if ($st -ne 'ok') { if ($st -ne 'error: gone') { Say "Couldn't get the clipboard from $(Peer-Label): $($st -replace '^error: ')" }; return }
  $b = [Clip]::Result; $S.clipSetAt = Get-Date
  try {
    if ([Clip]::ResultKind -eq 'png') { [Windows.Forms.Clipboard]::SetImage([Drawing.Image]::FromStream((New-Object IO.MemoryStream (, $b)))) }
    else { [Windows.Forms.Clipboard]::SetText([Text.Encoding]::UTF8.GetString($b)) }
    Say "Clipboard from $(Peer-Label): $(if ([Clip]::ResultKind -eq 'png') { 'a picture' } else { 'text' }), $(Size-Text $b.Length)."
  } catch { Say "The clipboard was busy; copy it again on $(Peer-Label)." }
}

# ---------- DeskGlide Link: start and stop the engine, hand it the settings, follow where it says the mouse is ----------
function Poll-Link {
  $on = $C.link -and $S.key -and $C.peer
  if (-not $on) { if ($S.link) { $S.link.Stop(); $S.link = $null; $S.linkWant = $null; Say 'Keyboard and mouse sharing stopped.' }; return }
  $svc = $S.svc
  if (Svc-On $svc) {   # admin control: DeskGlide's service receives here (and holds the port), not this app
    if ($S.link) { $S.link.Stop(); $S.link = $null; Say "Admin control is on: DeskGlide's service receives the keyboard and mouse on this PC." }
    if ($C.kmHost -ne $Name -and $svc.up -eq '1') {
      $want = if ($svc.controlled -eq '1') { 'me' } else { 'peer' }
      if ($want -ne $S.linkWant) { $S.linkWant = $want; $S.want = $want; $S.wantName = $(if ($want -eq 'me') { $S.screen } else { $S.peerScreen }); $S.since = Get-Date }
    }
    return
  }
  if (-not $S.link) {
    if (((Get-Date) - $S.linkAt).TotalSeconds -lt 10) { return }   # the port was busy: try again in a while
    $S.linkAt = Get-Date
    $l = New-Object Link; $l.Name = $Name
    try { $l.Start($Port + 2, $PeerPort + 2) } catch { Say "Keyboard and mouse sharing can't use UDP port $($Port + 2): $($_.Exception.Message)" error; return }
    $S.link = $l; Say "Keyboard and mouse sharing on UDP port $($Port + 2)$(if ($NoInject) { ', no injection' })."
  }
  $l = $S.link
  # the other PC's admin service has its own key. Plain assignments: `$x = if (...) { $bytes }` unrolls the array into a new one
  $k = $S.key; if ($C.peerAdmin -and $S.adminKey -and $C.kmHost -eq $Name) { $k = $S.adminKey }; $l.Key = $k
  if ($S.peerAddr) { $l.Peer = $S.peerAddr } elseif ($S.fixedIp -and -not $l.Peer) { $l.Peer = $S.fixedIp }
  $l.Sender = $C.kmHost -eq $Name
  $lay = (Current-Layout).show; $l.Dir = [char]$(if ($lay) { $lay.dir[0] } else { 'r' })
  $l.Speed = [Math]::Max(25, [Math]::Min(400, [int]$C.linkSpeed)); $l.Game = [bool]$C.game; $l.LockSync = [bool]$C.lockSync; $l.DualPath = $C.dualPath -ne $false
  if ($l.Up -and $l.Wireless -and ((Get-Date) - $S.psaveAt).TotalSeconds -ge 300) { $S.psaveAt = Get-Date; $S.psave = Wifi-PowerSave }
  $pk = Parse-Hotkey $C.panicKey; $l.PanicMods = $(if ($pk) { $pk.mods } else { 0 }); $l.PanicVk = $(if ($pk) { $pk.vk } else { 0 })
  $msg = $null; while ($l.Log.TryDequeue([ref]$msg)) { Say "Link: $msg" }
  if ($NoInject) { while ($l.Injected.TryDequeue([ref]$msg)) { Say "Link would inject: $($msg -replace '^\d+\|')" } }
  # where the mouse is: the keyboard PC always knows; the other PC only while connected (a lost link doesn't move it)
  $want = if ($l.Sender) { if ($l.Active) { 'peer' } else { 'me' } } elseif ($l.Up) { if ($l.Controlled) { 'me' } else { 'peer' } }
  if ($want -and $want -ne $S.linkWant) { $S.linkWant = $want; $S.want = $want; $S.wantName = $(if ($want -eq 'me') { $S.screen } else { $S.peerScreen }); $S.since = Get-Date }
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
  $S.svc = Svc-State ([SvcPipe]::Last)
  if ($C.link) { Poll-Link }   # DeskGlide Link says where the mouse is; without it, Synergy's log does
  else {
    if ($S.link) { Poll-Link }
    if ($S.server -and (Test-Path -LiteralPath $S.log)) {
      $text, $S.pos = Read-Lines $S.log $S.pos
      $t = Get-Target $text
      if ($t) { $S.want = $(if ($t -eq $S.screen) { 'me' } else { 'peer' }); $S.wantName = $t; $S.since = $now }
    }
  }
  # wait a moment after the last switch so a bounce at the screen edge doesn't flicker the monitor
  if ($S.want -and $S.want -ne $S.active -and ($now - $S.since).TotalMilliseconds -ge $(if ($S.link) { 250 } else { 400 })) { Set-Active $S.want $S.wantName }
  if ($showEvt.WaitOne(0)) { Show-Window }   # DeskGlide was started again: show this copy instead
  $hk = [MsgWin]::Pressed
  if ($hk -eq 3) { [MsgWin]::Pressed = 0; if ($S.link) { $S.link.Panic() } elseif (Svc-On $S.svc) { [void][SvcPipe]::Call($svcName, 'panic', 500, $true) } }   # the panic key while this PC has the keyboard and mouse
  elseif ($hk) { [MsgWin]::Pressed = 0; Show-Pc $(if ($hk -eq 1) { 'peer' } else { 'me' }) }
  if ([MsgWin]::ClipChanged) { Check-Clipboard }
  if ($S.n++ % 5) { return }   # the rest twice a second

  $online = Peer-Online
  if (($now - $S.lastSend).TotalSeconds -ge 2) { Send-State }
  if (($now - $S.roleAt).TotalSeconds -ge 60) {
    $S.roleAt = $now
    if (-not $S.server -and -not $C.link) { Detect-Role }
    if ($C.peerAddress -and -not $S.fixedIp) { Resolve-Peer }
  }
  if ($S.n % 30 -eq 1) { Read-Layout }   # every 3 s
  Poll-Fetch; Poll-Clip; [Files]::Key = $S.key
  if ($C.link -and -not $Shot -and ($now - $S.synAt).TotalSeconds -ge 10) { $S.synAt = $now; $S.synergy = [bool](Get-Process -ErrorAction SilentlyContinue | ? { $_.ProcessName -match '^(synergy|deskflow|barrier|input-leap)' }) }
  if ($S.speedAt -and ($now - $S.speedAt).TotalMilliseconds -ge 400) { $S.speedAt = $null; Save-Config }   # speed slider: save when it stops
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
    Write-Host ("{0:HH:mm:ss} [{1}] control ok {2} bad {3} | audio sent {4} ok {5} bad {6}{7}" -f $now, ($status -replace "`n", ', '), $S.okCtl, $S.badCtl, [Dg]::Sent, [Dg]::Got, [Dg]::Bad, $(if ($S.link) { ' | link {0}, rtt {1:0.00} ms, loss {2:0}%' -f $(if ($S.link.Up) { 'up' } else { 'down' }), $S.link.Rtt, $S.link.Loss }))
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
  $C.adminKey = ''; $C.peerAdmin = $false; $S.adminKey = $null
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
            <CheckBox x:Name="LinkToggle" Style="{StaticResource Switch}"><StackPanel>
              <TextBlock Text="Share them with the other PC"/>
              <TextBlock Style="{StaticResource Sub}" Text="Move the mouse off the screen edge and keep typing there. Encrypted, DeskGlide's own (no Synergy)."/></StackPanel></CheckBox>
            <TextBlock Style="{StaticResource Label}" Text="Keyboard and mouse are plugged into"/>
            <Border x:Name="KmHostMain"><Border x:Name="KmPanel" Style="{StaticResource InsetBox}"><UniformGrid Rows="1">
              <RadioButton x:Name="KmMe" GroupName="km" Style="{StaticResource Seg}"/>
              <RadioButton x:Name="KmPeer" GroupName="km" Style="{StaticResource Seg}"/>
            </UniformGrid></Border></Border>
            <Border Style="{StaticResource InsetBox}" Padding="12,9" Margin="0,14,0,0"><Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/></Grid.ColumnDefinitions>
              <Ellipse x:Name="LinkDot" Width="8" Height="8" Margin="0,6,10,0" VerticalAlignment="Top"/>
              <StackPanel Grid.Column="1"><TextBlock x:Name="LinkWhy" Style="{StaticResource Body}"/><TextBlock x:Name="LinkStats" Style="{StaticResource Sub}" Margin="0,4,0,0"/><TextBlock x:Name="LinkTip" Style="{StaticResource Sub}" Margin="0,4,0,0"/></StackPanel>
            </Grid></Border>
            <StackPanel x:Name="LinkMore">
              <Grid Margin="0,16,0,0"><TextBlock Text="Pointer speed on the other PC" TextTrimming="CharacterEllipsis" Margin="0,0,44,0"/><TextBlock x:Name="SpeedPct" HorizontalAlignment="Right" Foreground="{DynamicResource Fg2}"/></Grid>
              <Slider x:Name="Speed" Minimum="25" Maximum="400" SmallChange="5" LargeChange="25" IsMoveToPointEnabled="True" Margin="0,6,0,0"/>
              <CheckBox x:Name="GameToggle" Style="{StaticResource Switch}" Margin="0,14,0,0"><StackPanel>
                <TextBlock Text="Game mode"/>
                <TextBlock Style="{StaticResource Sub}" Text="When a game on the other PC holds the pointer, send raw movement. Come back with the panic key."/></StackPanel></CheckBox>
              <CheckBox x:Name="LockToggle" Style="{StaticResource Switch}" Margin="0,12,0,0"><StackPanel>
                <TextBlock Text="Lock both PCs together"/>
                <TextBlock Style="{StaticResource Sub}" Text="Win+L on one PC locks the other one too."/></StackPanel></CheckBox>
              <CheckBox x:Name="SvcToggle" Style="{StaticResource Switch}" Margin="0,12,0,0"><StackPanel>
                <TextBlock Text="Control admin windows, UAC prompts and the lock screen on this PC" TextWrapping="Wrap"/>
                <TextBlock x:Name="SvcWhy" Style="{StaticResource Sub}"/></StackPanel></CheckBox>
              <TextBlock Style="{StaticResource Label}" Text="Panic key: keyboard and mouse back here"/>
              <TextBox x:Name="PanicKey"/>
              <TextBlock Style="{StaticResource Sub}" Margin="0,4,0,0" Text="Works without the network. Also releases any stuck key."/>
            </StackPanel>
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
          <Rectangle x:Name="D5" Width="28" Height="4" RadiusX="2" RadiusY="2" Margin="0,0,6,0"/><Rectangle x:Name="D6" Width="28" Height="4" RadiusX="2" RadiusY="2"/>
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
            <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
            <TextBlock Style="{StaticResource Glyph}" Text="&#xE7F4;" FontSize="20" Margin="0,0,16,14"/>
            <TextBlock Grid.Column="1" Style="{StaticResource Body}" Text="The monitor switches to the PC that has the mouse." Margin="0,0,0,14"/>
            <TextBlock Grid.Row="1" Style="{StaticResource Glyph}" Text="&#xE7F6;" FontSize="20" Margin="0,0,16,14"/>
            <TextBlock Grid.Row="1" Grid.Column="1" Style="{StaticResource Body}" Text="Your headphones play that PC's sound, or both PCs at once." Margin="0,0,0,14"/>
            <TextBlock Grid.Row="2" Style="{StaticResource Glyph}" Text="&#xE765;" FontSize="20" Margin="0,0,16,14"/>
            <TextBlock Grid.Row="2" Grid.Column="1" Style="{StaticResource Body}" Text="One keyboard and mouse for both PCs, shared by DeskGlide itself." Margin="0,0,0,14"/>
            <TextBlock Grid.Row="3" Style="{StaticResource Glyph}" Text="&#xE71B;" FontSize="20" Margin="0,0,16,0"/>
            <TextBlock Grid.Row="3" Grid.Column="1" Style="{StaticResource Body}" Text="The two PCs find each other on your network. You pair them once with a code."/>
          </Grid>
          <TextBlock Style="{StaticResource Sub}" Margin="0,22,0,0" Text="Setup takes about a minute. Install DeskGlide on both PCs and run this setup on both."/>
        </StackPanel>
        <StackPanel x:Name="W2" Visibility="Collapsed">
          <TextBlock Style="{StaticResource Big}" Text="Pair your two PCs"/>
          <TextBlock Style="{StaticResource Body}" Text="On one PC, show a code. On the other PC, type it in. DeskGlide must be running on both."/>
          <Border x:Name="PairHostWiz" Margin="0,18,0,0"/>
        </StackPanel>
        <StackPanel x:Name="W3" Visibility="Collapsed">
          <TextBlock Style="{StaticResource Big}" Text="Which PC are your keyboard and mouse plugged into?"/>
          <TextBlock Style="{StaticResource Body}" Text="DeskGlide shares them with the other PC: move the mouse off the edge of the screen and keep typing there. Both PCs share this choice."/>
          <Border x:Name="KmHostWiz" Margin="0,18,0,0"/>
          <TextBlock Style="{StaticResource Sub}" Margin="0,12,0,0" Text="Using Synergy today? Quit it on both PCs once the Keyboard &amp; mouse card says Connected."/>
          <Border x:Name="WizAdmin" Style="{StaticResource InsetBox}" Padding="16,12" Margin="0,18,0,0"><StackPanel>
            <TextBlock FontWeight="SemiBold" Text="Optional, on this PC: admin windows and the lock screen"/>
            <TextBlock Style="{StaticResource Sub}" Margin="0,4,0,0" Text="Windows keeps normal apps out of admin windows, UAC prompts, the lock screen and Ctrl+Alt+Del. A small DeskGlide service lets the other PC's keyboard and mouse work there too. Windows asks for permission once, then you compare a number on both PCs."/>
            <Button x:Name="WizAdminGo" Content="Set up admin control..." HorizontalAlignment="Left" Margin="0,10,0,0"/>
          </StackPanel></Border>
        </StackPanel>
        <StackPanel x:Name="W4" Visibility="Collapsed">
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
        <StackPanel x:Name="W5" Visibility="Collapsed">
          <TextBlock Style="{StaticResource Big}" Text="Where are your headphones plugged in?"/>
          <TextBlock Style="{StaticResource Body}" Text="The other PC sends its sound there over your network. Both PCs share this choice, and you can change it later."/>
          <Border x:Name="HpHostWiz" Margin="0,18,0,0"/>
          <TextBlock Style="{StaticResource Sub}" Margin="0,12,0,0" Text="No headphones? Click Next, and set Sound to Off later."/>
        </StackPanel>
        <StackPanel x:Name="W6" Visibility="Collapsed">
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
  if ($Shot) { $win.WindowStartupLocation = 'Manual'; $win.Left = -20000; $win.Top = 0; if ($S.key) { $win.Height = 1500 }; $win.ShowActivated = $false; $win.ShowInTaskbar = $false }   # drawn off screen, never takes focus

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
  On LinkToggle Checked, Unchecked { if ([bool]$C.link -ne [bool]$ui.LinkToggle.IsChecked) { $C.link = -not $C.link; Changed } }
  On SvcToggle Checked, Unchecked { $w = [bool]$ui.SvcToggle.IsChecked; if (-not $S.adminUntil -and $w -ne (Svc-On $S.svc)) { Admin-Setup $w } }
  On WizAdminGo Click { Admin-Setup $true }
  On GameToggle Checked, Unchecked { if ([bool]$C.game -ne [bool]$ui.GameToggle.IsChecked) { $C.game = -not $C.game; Save-Config } }
  On LockToggle Checked, Unchecked { if ([bool]$C.lockSync -ne [bool]$ui.LockToggle.IsChecked) { $C.lockSync = -not $C.lockSync; Changed } }
  On Speed ValueChanged { $v = [int]$ui.Speed.Value; if ($v -ne $C.linkSpeed) { $C.linkSpeed = $v; $S.speedAt = Get-Date } }
  On PanicKey LostFocus { Set-HotkeyText 'panicKey' $ui.PanicKey.Text }
  On PanicKey KeyDown { if ($args[1].Key -eq 'Return') { Set-HotkeyText 'panicKey' $ui.PanicKey.Text } }
  On WizNext Click { if ($S.wiz -ge 6) { Show-Wizard 0 } else { Show-Wizard ($S.wiz + 1) } }
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

function Admin-Setup([bool]$on) {   # the admin control switch: one Windows prompt, the rest in that admin window
  $peer = Peer-Label
  if ($on) {
    $addr = @($S.peerAddr, $S.fixedIp | ? { $_ })[0]
    if (-not $S.key -or -not $C.peer -or -not $addr) { [void][Windows.MessageBox]::Show("Pair with $peer first, and keep DeskGlide running on both PCs.", 'DeskGlide'); return }
    $text = "Windows keeps normal apps, DeskGlide included, out of admin windows, UAC prompts, the lock and sign-in screen and Ctrl+Alt+Del. To let $peer control those on this PC, DeskGlide installs a small Windows service in C:\Program Files\DeskGlide that receives the keyboard and mouse here.`n`nThe service has its own key, which programs running on this PC can't read, so they can't use it to click Yes on an admin prompt.`n`nWindows asks for permission next. In the admin window that opens, check that $peer shows the same number, then type y."
    if ([Windows.MessageBox]::Show($text, 'DeskGlide: admin control', 'OKCancel', 'Information') -ne 'OK') { return }
    $a = "-ServiceSetup -SetupKey $([Convert]::ToBase64String($S.key)) -SetupPeer $addr -SetupPeerName $($C.peer) -Name $Name -PeerPort $PeerPort"
  } else {
    if ([Windows.MessageBox]::Show("Turn admin control off? $peer then can't use this PC's admin windows, UAC prompts and lock screen. The service and its key are removed; Windows asks for permission.", 'DeskGlide: admin control', 'OKCancel', 'Question') -ne 'OK') { return }
    $a = '-ServiceRemove'
  }
  try { Start-Process "$PSHOME\powershell.exe" "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $a" -Verb RunAs; $S.adminWant = $on; $S.adminUntil = (Get-Date).AddMinutes(3) }
  catch { Say "Admin control: Windows' permission wasn't given." }
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
  foreach ($p in @(@($ui.PairPanel, $ui.PairHostWiz, $ui.PairHostMain), @($ui.HpPanel, $ui.HpHostWiz, $ui.HpHostMain), @($ui.KmPanel, $ui.KmHostWiz, $ui.KmHostMain))) {   # the wizard borrows these from the main view
    $to = if ($in) { $p[1] } else { $p[2] }
    if ($p[0].Parent -ne $to) { $p[0].Parent.Child = $null; $to.Child = $p[0] }
  }
  Show-If $ui.Wiz $in; Show-If $ui.Main (-not $in)
  if (-not $in) { $S.wizDone = $true; return }
  for ($i = 1; $i -le 6; $i++) { Show-If $ui["W$i"] ($i -eq $step); $ui["D$i"].SetResourceReference([Windows.Shapes.Shape]::FillProperty, $(if ($i -le $step) { 'Accent' } else { 'Line2' })) }
  $ui.WizBack.Visibility = if ($step -gt 1) { 'Visible' } else { 'Hidden' }
  $ui.WizSkip.Visibility = if ($step -lt 6) { 'Visible' } else { 'Hidden' }
  $ui.WizNext.Content = switch ($step) { 1 { 'Get started' } 6 { 'Finish' } default { 'Next' } }
  $ui.WizStep.Text = "Step $step of 6"
}

function Update-Ui {
  if (-not $win -or -not $win.IsVisible) { return }
  Apply-Theme
  $online = Peer-Online; $peer = Peer-Label; $paired = [bool]$C.peer; $pairing = $S.key -and -not $paired
  $tick = [string][char]0xE73E; $wait = [string][char]0xE712

  # header
  $ui.Logo.Source = $logos[$S.iconState]
  $ui.Title.Text = if (-not $S.key) { 'Not paired' } elseif ($pairing) { 'Pairing...' } elseif ($online) { "Connected to $peer" } else { "Looking for $peer..." }
  $mouse = switch ($S.active) { 'me' { "The mouse is on this PC ($Name)." } 'peer' { "The mouse is on $(if ($paired) { $peer } else { $S.activeName })." } default { if ($C.link) { 'Waiting for keyboard and mouse sharing to connect.' } else { 'Waiting for Synergy to report where the mouse is.' } } }
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
  $differs = -not $C.link -and $L.own -and $L.syn -and $L.syn.dir -ne $L.own.dir
  $ui.LayoutMsg.Text = if ($differs) { "Synergy's layout differs. Turn on keyboard and mouse sharing to use this one." } else { '' }
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
  $ui.LinkToggle.IsChecked = [bool]$C.link; $l = $S.link; $up = $l -and $l.Up
  $ui.LinkWhy.Text = Link-Status $C $paired $online $S.peerVer $l $S.synergy $S.svc
  $svcOn = Svc-On $S.svc
  $ui.LinkDot.Fill = Brush $(if (($up -and -not $S.synergy -and -not $l.InjectError) -or ($svcOn -and $S.svc.up -eq '1' -and $C.kmHost -ne $Name)) { 'Good' } elseif ($C.link) { 'Warn' } else { 'Fg2' })
  Show-If $ui.LinkStats $up; $tips = @()
  if ($up) {
    $ui.LinkStats.Inlines.Clear()
    if ($l.Rtt -ge 0) {
      $q = Link-Quality $l.Rtt $l.Jitter $l.Loss; $badge = New-Object Windows.Documents.Run $q; $badge.FontWeight = 'SemiBold'
      $badge.Foreground = Brush $(@{ Good = 'Good'; Fair = 'Warn'; Poor = 'Bad' }[$q]); $ui.LinkStats.Inlines.Add($badge)
      $ui.LinkStats.Inlines.Add((New-Object Windows.Documents.Run ('   Latency (round trip) {0:0.0} ms   Jitter {1:0.0} ms   Packet loss {2:0.#}%' -f $l.Rtt, $l.Jitter, $l.Loss)))
      if ($q -eq 'Poor') { $tips += 'Use a direct Ethernet cable or your home router instead of a phone hotspot for the best experience.' }
    } else { $ui.LinkStats.Inlines.Add((New-Object Windows.Documents.Run 'Measuring the connection...')) }
    if ($l.Wireless -and $S.psave) { $tips += 'Your Wi-Fi saves power between packets; for smoother control set Power mode to Best performance or use a cable.' }
  }
  if ($S.adminPend -and ((Get-Date) - $S.adminPend.at).TotalMinutes -lt 3) { $tips += "Admin control on $peer`: check that it shows $($S.adminPend.check), then confirm there." }
  $ui.LinkTip.Text = $tips -join "`n"; Show-If $ui.LinkTip $tips.Count
  Show-If $ui.LinkMore $C.link
  if (-not $S.speedAt -and $ui.Speed.Value -ne $C.linkSpeed) { $ui.Speed.Value = $C.linkSpeed }; $ui.SpeedPct.Text = "$($C.linkSpeed)%"
  $ui.GameToggle.IsChecked = [bool]$C.game; $ui.LockToggle.IsChecked = [bool]$C.lockSync
  $busy = [bool]($S.adminUntil -and (Get-Date) -lt $S.adminUntil -and $S.adminWant -ne $svcOn); if (-not $busy) { $S.adminUntil = $null }
  $ui.SvcToggle.IsChecked = if ($busy) { $S.adminWant } else { $svcOn }; $ui.SvcToggle.IsEnabled = $svcOn -or $C.kmHost -ne $Name
  $ui.SvcWhy.Text = Admin-Status $C $S.svc (Test-Path -LiteralPath (Join-Path $svcDir 'DeskGlideService.exe')) $busy $S.adminWant ([bool]$S.adminKey)
  Show-If $ui.WizAdmin ($C.kmHost -and $C.kmHost -ne $Name -and -not $svcOn)

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
  foreach ($p in @(@('LogPath', 'synergyLog'), @('AddrSet', 'peerAddress'), @('Script', 'onSwitch'), @('HkPeer', 'hotkeyPeer'), @('HkMe', 'hotkeyMe'), @('FileLimit', 'fileLimitMB'), @('PanicKey', 'panicKey'))) {
    if (-not $ui[$p[0]].IsKeyboardFocused) { $ui[$p[0]].Text = $C[$p[1]] }
  }
  $ui.RoleText.Text = if ($C.link) { 'Not used: DeskGlide shares the keyboard and mouse itself.' } elseif ($S.server) { "This PC is the Synergy server. Log: $($S.log)" } elseif ($C.synergyLog -and -not (Test-Path -LiteralPath $C.synergyLog)) { "This file doesn't exist." } else { "This PC is a Synergy client.$(if (-not $C.synergyLog) { " Empty means Synergy 3's log." })" }
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
    $kmText = if ($C.kmHost) { "Keyboard and mouse: plugged into $(if ($C.kmHost -eq $Name) { 'this PC' } else { $C.kmHost }), shared $(if ($C.link) { 'by DeskGlide' } else { 'by Synergy' })." } else { 'Keyboard and mouse: not set. Choose in the Keyboard & mouse card.' }
    $ui.Summary.Text = "$(if ($paired) { "Paired with $peer." } else { 'Not paired yet. Pair in the Pairing card.' })`n$kmText`nMonitor: this PC on $(Input-Name $mi), $peer on $(Input-Name $pi).`n$hpText"
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
  $S.msgWin = New-Object MsgWin; if (-not $Shot) { Apply-Hotkeys }
  [void]$S.msgWin.ListenClipboard(); [Files]::Key = $S.key; [Files]::Serve($Port + 1)   # files: TCP on the control port + 1
  $S.screen = if ($C.screenName) { $C.screenName } else { $Name }
  if ($C.key) { $S.key = [Convert]::FromBase64String($C.key) }
  if ($C.adminKey) { $S.adminKey = [Convert]::FromBase64String($C.adminKey) }
  [SvcPipe]::Watch()   # admin control: this PC's service, if installed
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
  if ($S.link) { $S.link.Stop() }   # gives the keyboard and mouse back and releases every key
  [Dg]::SendMode = 0; [Dg]::RecvMode = 0
  if ([Dg]::Detached) { [void][Dg]::Reattach() }   # never leave a monitor off the desktop
  if ([Dg]::Muted.Count) { [Dg]::MuteOthers($false, $PID) }
  Save-Muted
  if ($tray) { $tray.Visible = $false; $tray.Dispose() }
}
