# synergy-monitor-switch

**One keyboard, one mouse, one monitor, two computers. No reaching for the monitor's input button.**

Move the mouse off the edge of one computer's screen and:

1. **Synergy** (or **Deskflow**, its free open-source version) moves the mouse and keyboard to the other computer.
2. **This script** sees the switch and tells the monitor to change its input to that computer.

It's one PowerShell script with nothing to install. It talks to the monitor over DDC/CI through `dxva2.dll`, which ships with Windows.

```
 PC A (server)  ──DisplayPort──┐
   keyboard + mouse            ├──  one monitor
 PC B (client)  ────HDMI───────┘
       ▲
       └── Synergy / Deskflow shares keyboard + mouse over the network
```

## Requirements

- Windows 10 or 11 on the computer that has the keyboard and mouse (the server)
- A monitor with DDC/CI turned on (most monitors have it on by default; look in the monitor's on-screen menu)
- Both computers connected to that monitor on different inputs
- Synergy 3 or Deskflow on both computers

## Setup

### 1. Share the keyboard and mouse

Install one of these on **both** computers:

| | Cost | Get it |
|---|---|---|
| Synergy | Paid | https://symless.com/synergy |
| Deskflow | Free, open source | https://github.com/deskflow/deskflow |

- On the computer with the keyboard and mouse, choose **server** (Synergy: "Use this computer's keyboard and mouse").
- On the other computer, choose **client** and connect to the server.
- In the server's screen layout, place the client on the side where you want the mouse to cross over (for example, to the right).

Now check that moving the mouse past that edge controls the other computer. If it doesn't, fix this before going further, because the script depends on it.

**Deskflow only:** turn on **Log to file** in Deskflow's settings and note the file path. You'll need it in step 3.

### 2. Find your monitor's input numbers

On the server, open PowerShell in this folder and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\synergy-monitor-switch.ps1 -Show
```

Example output:

```
Generic PnP Monitor : current input = 15   supported inputs = 17, 18, 15
```

- The **current input** is the server's input. Use it for `-MyInput`.
- The other computer is on one of the other numbers. Common values are `15` = DisplayPort 1, `16` = DisplayPort 2, `17` = HDMI 1, `18` = HDMI 2. Use it for `-OtherInput`.

### 3. Run it

```powershell
powershell -ExecutionPolicy Bypass -File .\synergy-monitor-switch.ps1 -MyInput 15 -OtherInput 17
```

With Deskflow, add `-Log "C:\path\to\deskflow.log"`.

Move the mouse to the other computer and back. Each switch prints a line:

```
09:02:11 input -> 17 ok
09:02:15 input -> 15 ok
```

### 4. Start it automatically at login

Run this in the same folder, with your own input numbers. It puts a shortcut in your Startup folder that runs the script with no window:

```powershell
$s = (New-Object -ComObject WScript.Shell).CreateShortcut("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\Synergy Monitor Switch.lnk"); $s.TargetPath = "powershell.exe"; $s.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$((Resolve-Path .\synergy-monitor-switch.ps1).Path)`" -MyInput 15 -OtherInput 17"; $s.Save()
```

To stop it starting automatically, delete `Synergy Monitor Switch` from the Startup folder (press Win+R and type `shell:startup`).

## Copy-paste between the computers

| What | Synergy 3 | Deskflow | How |
|---|---|---|---|
| Text | Yes | Yes | Copy on one computer, move the mouse over, paste |
| Images / screenshots | Yes | Yes | Same as text |
| Files and folders | No | No | Use one of the options below |

Both tools dropped file drag-and-drop, so for files use something Windows already has:

- **Nearby sharing** (built into Windows 10 and 11): turn it on under Settings > System > Nearby sharing on both computers. Then right-click a file, choose **Share**, and pick the other computer.
- **Shared folder:** right-click a folder, choose **Properties > Sharing > Share**, then open it from the other computer as `\\COMPUTER-NAME\FolderName`. Good for files you move every day.

## Options

| Option | Default | What it does |
|---|---|---|
| `-MyInput` | `15` | Monitor input of this computer (the server) |
| `-OtherInput` | `17` | Monitor input of the other computer |
| `-Me` | computer name | This computer's screen name in Synergy/Deskflow |
| `-Log` | Synergy 3 agent log | Path to the Synergy/Deskflow log file |
| `-SettleMs` | `400` | Wait after the last switch, so a quick bounce at the screen edge doesn't flicker the monitor |
| `-Show` | | List the monitor's current and supported inputs |
| `-DryRun` | | Print the switches without changing the monitor |
| `-Test` | | Run the built-in self-check |

## Troubleshooting

- **Nothing prints when the mouse crosses:** the log path is wrong, or the log isn't being written. Synergy 3's log is `%LOCALAPPDATA%\synergy-dragon\logs\synergy-dragon-agent.log`. For Deskflow, make sure Log to file is on.
- **It always switches to the other input:** your screen name in Synergy/Deskflow isn't the Windows computer name. Pass it with `-Me "name"`.
- **`no DDC/CI reply`:** turn on DDC/CI in the monitor's on-screen menu.
- **Switching back prints `FAILED`:** some monitors ignore commands from an input they aren't showing. This setup sends every command from the server, so it only works if your monitor accepts those.
- **Windows rearranges after a switch:** some monitors drop the DisplayPort link when they change input, so the server thinks the monitor was unplugged. Try another cable or port, or turn off the monitor's "DP auto-switch" or deep-sleep option.

## Tested on

- Windows 11 with Synergy 3 and an MSI monitor (DisplayPort + HDMI)

Deskflow support relies on Deskflow writing the same `switch from "A" to "B"` log line as Synergy. If it doesn't work for you, please open an issue.

## License

MIT
