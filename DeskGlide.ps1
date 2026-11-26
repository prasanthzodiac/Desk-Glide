# DeskGlide: two PCs, one monitor, one keyboard and mouse (Synergy / Deskflow), one pair of headphones.
# The same files run on both PCs as a tray app. Install.cmd adds it to Startup, Uninstall.cmd removes it.
#   -Test      self-check of the pure logic (no network, no monitor, no audio)
#   -Console   run with output to this console instead of the tray, for debugging
param(
  [switch]$Console, [switch]$Test, [switch]$Install, [switch]$Uninstall,
  # hidden, for debugging and for running two copies on one PC:
  [switch]$DryRun,                        # never send a DDC command, only print it
  [string]$PairCode,                      # pair at startup without the dialog
  [int]$Port = 6991, [int]$PeerPort = 0,  # control/discovery UDP port to listen on / to send to
  [int]$AudioPort = 6990,
  [string]$ConfigDir = "$env:APPDATA\DeskGlide",
  [string]$Name = $env:COMPUTERNAME
)
$ErrorActionPreference = 'Stop'
if (-not $PeerPort) { $PeerPort = $Port }
Add-Type -Path "$PSScriptRoot\DeskGlide.cs"
$cfgPath   = Join-Path $ConfigDir 'config.json'
$mutedPath = Join-Path $ConfigDir 'muted.txt'   # apps we muted, so a crash or kill doesn't leave them muted
$logPath   = Join-Path $ConfigDir 'deskglide.log'

function Load-Config {
  $c = @{ peer = ''; key = ''; input = 0; inputOverride = 0; monitor = $true; audio = 'follow'
          headphones = $false; paused = $false; syncAt = 0; synergyLog = ''; screenName = '' }
  if (Test-Path $cfgPath) { (Get-Content $cfgPath -Raw | ConvertFrom-Json).psobject.Properties | % { $c[$_.Name] = $_.Value } }
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

  $r = 0; $c = 0
  function Pkt($key, [int]$rate, [int]$ch, [int]$bytes) { [Dg]::MakePacket($key, $rate, $ch, 7, (New-Object byte[] ([Math]::Max($bytes, 1))), $bytes) }
  Check ([Dg]::ValidPacket($k, (Pkt $k 48000 2 1152), [ref]$r, [ref]$c) -and $r -eq 48000 -and $c -eq 2) 'valid stereo packet rejected'
  Check ([Dg]::ValidPacket($k, (Pkt $k 44100 1 2), [ref]$r, [ref]$c)) 'valid mono packet rejected'
  $bad = Pkt $k 48000 2 1152; $bad[100] = 1
  Check (-not [Dg]::ValidPacket($k, $bad, [ref]$r, [ref]$c)) 'tampered audio accepted'
  Check (-not [Dg]::ValidPacket($k2, (Pkt $k 48000 2 1152), [ref]$r, [ref]$c)) 'audio with wrong key accepted'
  Check (-not [Dg]::ValidPacket($k, (Pkt $k 48000 2 3), [ref]$r, [ref]$c)) 'odd length accepted'
  Check (-not [Dg]::ValidPacket($k, (Pkt $k 48000 6 12), [ref]$r, [ref]$c)) '6 channels accepted'
  Check (-not [Dg]::ValidPacket($k, (Pkt $k 1 2 4), [ref]$r, [ref]$c)) 'bad sample rate accepted'
  Check (-not [Dg]::ValidPacket($k, [byte[]](1, 2, 3), [ref]$r, [ref]$c)) 'short packet accepted'
  Check ([Dg]::ToPcm16(2.0) -eq 32767 -and [Dg]::ToPcm16(-2.0) -eq -32768 -and [Dg]::ToPcm16(0) -eq 0) 'clipping'

  $ConfigDir = Join-Path $env:TEMP "deskglide-test-$PID"; $cfgPath = Join-Path $ConfigDir 'config.json'
  $C = Load-Config; $C.peer = 'PC-B'; $C.input = 17; $C.audio = 'both'; $C.syncAt = 1764000000000; Save-Config
  $C = Load-Config
  Check ($C.peer -eq 'PC-B' -and $C.input -eq 17 -and $C.audio -eq 'both' -and $C.syncAt -eq 1764000000000 -and $C.monitor -eq $true) 'config round trip'
  Remove-Item -Recurse $ConfigDir
  'self-check ok'; return
}

function Restore-Muted {   # unmute the apps a previous run muted (crash, kill, uninstall)
  if (-not (Test-Path $mutedPath)) { return }
  Get-Content $mutedPath | % { [void][Dg]::Muted.Add($_) }
  [Dg]::MuteOthers($false, $PID); Remove-Item $mutedPath
}

if ($Install -or $Uninstall) {
  # stop running copies (also DeskGlide 1's deskglide.ps1 / deskglide-audio.ps1, which this replaces)
  Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    ? { $_.ProcessId -ne $PID -and $_.CommandLine -like '*deskglide*.ps1*' } |
    % { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Milliseconds 500
  Restore-Muted
  $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'DeskGlide.lnk'
  $argLine = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
  if ($Uninstall) { Remove-Item $lnk -ErrorAction SilentlyContinue; "DeskGlide removed. Your settings are kept in $ConfigDir"; return }
  $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
  $s.TargetPath = "$PSHOME\powershell.exe"; $s.Arguments = $argLine; $s.WorkingDirectory = $PSScriptRoot; $s.Save()
  Start-Process "$PSHOME\powershell.exe" $argLine -WindowStyle Hidden
  'DeskGlide is installed and running. Look for its icon in the taskbar tray.'; return
}

# ---------------------------------------------------------------- the app
$S = @{ key = $null; server = $false; log = ''; pos = 0; screen = ''; active = $null; want = $null; since = [DateTime]::MinValue
        activeSince = Get-Date; inputOk = $false; readAt = [DateTime]::MinValue; peerAddr = $null; peerSeen = [DateTime]::MinValue
        peerInput = 0; peerH = $false; lastT = 0; t = [long]0; lastSend = [DateTime]::MinValue; roleAt = Get-Date; n = 0
        okCtl = 0; badCtl = 0; statAt = Get-Date; lastErr = ''; lastErrAt = [DateTime]::MinValue; savedMuted = ''; told = @{} }
$tray = $null

function Say([string]$text, [string]$kind) {   # kind: '' = log only, 'info' / 'error' = also a balloon
  if ($kind -eq 'error') {
    if ($text -eq $S.lastErr -and ((Get-Date) - $S.lastErrAt).TotalMinutes -lt 5) { return }
    $S.lastErr = $text; $S.lastErrAt = Get-Date
  }
  $line = '{0:HH:mm:ss} {1}' -f (Get-Date), $text
  Add-Content -LiteralPath $logPath $line
  if ($Console) { Write-Host $line }
  elseif ($kind) { $tray.ShowBalloonTip(5000, 'DeskGlide', $text, $(if ($kind -eq 'error') { 'Error' } else { 'Info' })) }
}
function Once([string]$id, [string]$text, [string]$kind) { if (-not $S.told[$id]) { $S.told[$id] = $true; Say $text $kind } }
function My-Input { if ($C.inputOverride) { [int]$C.inputOverride } else { [int]$C.input } }
function Now-Ms { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

function Send-State {
  if (-not $S.key) { return }
  $S.t = [Math]::Max([long]$S.t + 1, [long](Now-Ms))   # strictly increasing, the peer drops replays
  $json = @{ n = $Name; t = $S.t; s = $S.server; sa = ($S.active -eq 'me'); i = (My-Input); h = $C.headphones
             m = $C.monitor; am = $C.audio; p = $C.paused; st = $C.syncAt } | ConvertTo-Json -Compress
  $b = [Text.Encoding]::UTF8.GetBytes([Dg]::Seal($S.key, $json))
  # broadcast finds the peer (and re-finds it when its address changes); unicast reaches it if broadcast doesn't
  foreach ($ip in @([Dg]::Broadcasts()) + @($S.peerAddr | ? { $_ })) {
    try { [void]$udp.Send($b, $b.Length, (New-Object Net.IPEndPoint($ip, $PeerPort))) } catch {}   # one dead adapter must not stop the rest; "not found" shows in the tooltip
  }
  $S.lastSend = Get-Date
}

function Receive-Control {
  while ($udp.Available -gt 0) {
    $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
    $json = [Dg]::Open($S.key, [Text.Encoding]::UTF8.GetString($udp.Receive([ref]$ep)))
    if (-not $json) { $S.badCtl++; continue }   # not paired with us, or tampered: drop
    $m = $json | ConvertFrom-Json
    if ($m.n -eq $Name) { continue }            # our own broadcast
    if (-not $C.peer) { $C.peer = $m.n; Save-Config; Say "Paired with $($m.n)." info }
    if ($m.n -ne $C.peer) { continue }
    # ponytail: replay guard is "timestamp must grow"; it resets after 30 s of silence so a peer whose clock jumped back recovers
    if (((Get-Date) - $S.peerSeen).TotalSeconds -gt 30) { $S.lastT = 0 }
    if ([long]$m.t -le $S.lastT) { continue }
    $S.lastT = [long]$m.t; $S.okCtl++
    if (-not $S.peerAddr -or -not $S.peerAddr.Equals($ep.Address)) { Say "Found $($m.n) at $($ep.Address)." }
    $S.peerAddr = $ep.Address; $S.peerSeen = Get-Date; $S.peerInput = [int]$m.i; $S.peerH = [bool]$m.h
    if ([long]$m.st -gt [long]$C.syncAt) {   # settings changed on the other PC more recently: take them
      $C.monitor = [bool]$m.m; $C.audio = $m.am; $C.paused = [bool]$m.p; $C.syncAt = [long]$m.st
      if ($m.h) { $C.headphones = $false }
      Save-Config; Update-Menu
    }
    if ($m.s -and -not $S.server) { Set-Active $(if ($m.sa) { 'peer' } else { 'me' }) }
  }
}

function Set-Active($new) {
  if ($new -eq $S.active) { return }
  $old = $S.active; $S.active = $new; $S.activeSince = Get-Date; $S.inputOk = $false
  Say "Mouse is on $(if ($new -eq 'me') { 'this PC' } else { $C.peer })."
  # The PC on screen sends the switch: many monitors ignore DDC from an input they aren't showing.
  if ($old -eq 'me' -and $new -eq 'peer' -and $C.monitor -and -not $C.paused) {
    if (-not $S.peerInput) { Say "Can't switch the monitor yet: the other PC's input is unknown." }
    elseif ($DryRun) { Say "dry run: would switch the monitor to input $($S.peerInput)" }
    else {
      $ok = [Dg]::SetInput([uint32]$S.peerInput)   # ponytail: no retry; the next switch tries again
      if ($ok) { Say "Monitor -> input $($S.peerInput)" } else { Say "The monitor did not accept the switch to input $($S.peerInput)." error }
    }
  }
  if ($S.server) { Send-State }   # tell the peer right away
}

function Detect-Role {   # the PC whose Synergy/Deskflow log has "switch from" lines is the server
  $log = if ($C.synergyLog) { $C.synergyLog } else { "$env:LOCALAPPDATA\synergy-dragon\logs\synergy-dragon-agent.log" }
  if (-not (Test-Path -LiteralPath $log)) { return }
  $text, $pos = Read-Lines $log 0
  if (-not $text.Contains('switch from "')) { return }
  $S.server = $true; $S.log = $log; $S.pos = $pos
  Say "This PC is the Synergy server (log: $log)."
  $t = Get-Target $text
  Set-Active $(if (-not $t -or $t -eq $S.screen) { 'me' } else { 'peer' })
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
    if ($t) { $S.want = $(if ($t -eq $S.screen) { 'me' } else { 'peer' }); $S.since = $now }
    # wait 400 ms after the last switch so a bounce at the screen edge doesn't flicker the monitor
    if ($S.want -and $S.want -ne $S.active -and ($now - $S.since).TotalMilliseconds -ge 400) { Set-Active $S.want }
  }
  if ($S.n++ % 5) { return }   # the rest twice a second

  $online = $S.peerAddr -and ($now - $S.peerSeen).TotalSeconds -lt 10
  if (($now - $S.lastSend).TotalSeconds -ge 2) { Send-State }
  if (-not $S.server -and ($now - $S.roleAt).TotalSeconds -ge 60) { $S.roleAt = $now; Detect-Role }

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
    Once inputs 'Almost done: show each PC on the monitor once. Move the mouse to it and, if the screen does not follow, press the monitor''s input button.' info
  }

  # audio: the PC with the headphones receives, the other one sends
  # ponytail: audio is authenticated (HMAC) but not encrypted; anyone on the LAN can listen. Add AES-CTR if that matters.
  $on = $online -and $C.audio -ne 'off' -and -not $C.paused
  [Dg]::Key = $S.key
  [Dg]::Target = if ($S.peerAddr) { New-Object Net.IPEndPoint($S.peerAddr, $AudioPort) } else { $null }
  [Dg]::SendOn = $on -and -not $C.headphones -and $S.peerH
  [Dg]::RecvOn = $on -and $C.headphones
  [Dg]::RemoteOn = $C.audio -eq 'both' -or $S.active -eq 'peer'
  if ([Dg]::RecvOn -and $C.audio -eq 'follow' -and $S.active -eq 'peer') { [Dg]::MuteOthers($true, $PID) }
  elseif ([Dg]::Muted.Count) { [Dg]::MuteOthers($false, $PID) }
  Save-Muted
  if ([Dg]::LastError) { Say "Audio: $([Dg]::LastError)" error }

  $act = switch ($S.active) { 'me' { 'this PC' } 'peer' { $C.peer } default { '?' } }
  $pair = if (-not $S.key) { 'not paired' } elseif (-not $C.peer) { 'pairing...' } elseif ($online) { "paired, $($C.peer)" } else { "$($C.peer) not found" }
  $status = "DeskGlide$(if ($C.paused) { ' (paused)' }): $pair`nMouse on: $act"
  if ($tray) { $tray.Text = $status.Substring(0, [Math]::Min(63, $status.Length)) }
  if ($Console -and ($now - $S.statAt).TotalSeconds -ge 5) {
    $S.statAt = $now
    Write-Host ("{0:HH:mm:ss} [{1}] control ok {2} bad {3} | audio sent {4} ok {5} bad {6}" -f $now, ($status -replace "`n", ', '), $S.okCtl, $S.badCtl, [Dg]::Sent, [Dg]::Got, [Dg]::Bad)
  }
}

function Set-Key([string]$code) {
  if ([Dg]::NormCode($code).Length -ne 8) { throw "That code doesn't look right. It has 8 letters and digits, like ABCD-EFGH." }
  $S.key = [Dg]::DeriveKey($code); $C.key = [Convert]::ToBase64String($S.key)
  $C.peer = ''; $S.peerAddr = $null; $S.lastT = 0
  Save-Config; Say 'Pairing: waiting for the other PC...' info; Send-State
}

function Pair {
  $r = [Windows.Forms.MessageBox]::Show("Does the other PC already show a DeskGlide pairing code?`n`nYes: type that code here.`nNo: show a new code here, to type on the other PC.", 'DeskGlide pairing', 'YesNoCancel', 'Question')
  if ($r -eq 'Yes') {
    $code = [Microsoft.VisualBasic.Interaction]::InputBox('Pairing code shown on the other PC:', 'DeskGlide pairing', '')
    if ($code.Trim()) { Set-Key $code }
  } elseif ($r -eq 'No') {
    $code = [Dg]::NewCode(); Set-Key $code
    [void][Windows.Forms.MessageBox]::Show("On the other PC, right-click the DeskGlide tray icon, choose Pair with other PC..., click Yes and type:`n`n        $code`n`nThe two PCs find each other within a few seconds.", 'DeskGlide pairing')
  }
}

function Changed { $C.syncAt = Now-Ms; Save-Config; Update-Menu; Send-State }   # menu change: newest settings win on both PCs
function Update-Menu {
  if (-not $tray) { return }
  $miMon.Checked = $C.monitor; $miHp.Checked = $C.headphones; $miPause.Checked = $C.paused
  $miFollow.Checked = $C.audio -eq 'follow'; $miBoth.Checked = $C.audio -eq 'both'; $miOff.Checked = $C.audio -eq 'off'
}
function Item($items, [string]$text, [scriptblock]$do) {
  $i = New-Object Windows.Forms.ToolStripMenuItem $text
  $i.Tag = $do
  $i.Add_Click({ try { & $this.Tag } catch { Say "$($_.Exception.Message)" error } })
  [void]$items.Add($i); $i
}

if (-not $Console) { Add-Type -AssemblyName System.Windows.Forms, System.Drawing, Microsoft.VisualBasic }
try {
  [void](New-Item -ItemType Directory -Force $ConfigDir)
  $C = Load-Config
  $mutex = New-Object Threading.Mutex($false, "Local\DeskGlide-$Port")   # one copy per user
  try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
  if (-not $owned) { if ($Console) { 'DeskGlide is already running.' }; return }
  Set-Content $logPath "DeskGlide started $(Get-Date)$(if ($DryRun) { ' [dry run]' })"

  if (-not $Console) {
    $tray = New-Object Windows.Forms.NotifyIcon
    $tray.Icon = [Drawing.Icon]::ExtractAssociatedIcon("$env:SystemRoot\System32\DisplaySwitch.exe")
    $tray.Text = 'DeskGlide'
    $menu = New-Object Windows.Forms.ContextMenuStrip
    $miMon = Item $menu.Items 'Monitor follows mouse' { $C.monitor = -not $C.monitor; Changed }
    $miAudio = Item $menu.Items 'Audio' {}
    $miFollow = Item $miAudio.DropDownItems 'Follow mouse' { $C.audio = 'follow'; Changed }
    $miBoth = Item $miAudio.DropDownItems 'Hear both' { $C.audio = 'both'; Changed }
    $miOff = Item $miAudio.DropDownItems 'Off' { $C.audio = 'off'; Changed }
    $miHp = Item $menu.Items 'Headphones are plugged into this PC' { $C.headphones = -not $C.headphones; Changed }
    $miPause = Item $menu.Items 'Pause' { $C.paused = -not $C.paused; Changed }
    [void]$menu.Items.Add('-')
    [void](Item $menu.Items 'Pair with other PC...' { Pair })
    [void](Item $menu.Items 'Open settings folder' { Start-Process explorer.exe $ConfigDir })
    [void](Item $menu.Items 'Quit' { [Windows.Forms.Application]::Exit() })
    $tray.ContextMenuStrip = $menu; $tray.Visible = $true
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
  Say "DeskGlide on $Name, control port $Port -> $PeerPort, audio port $AudioPort$(if ($DryRun) { ', dry run' })."
  Detect-Role
  if (-not $S.server) { Say 'This PC is a Synergy client (no "switch from" lines in its log).' }
  if (-not $S.key) { Say 'DeskGlide is running. Right-click its tray icon and choose Pair with other PC... to connect the two PCs.' info }

  if ($Console) {
    while ($true) { try { Tick } catch { Say "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))" error }; Start-Sleep -Milliseconds 100 }
  } else {
    $timer = New-Object Windows.Forms.Timer; $timer.Interval = 100
    $timer.Add_Tick({ try { Tick } catch { Say "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))" error } })
    $timer.Start()
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
