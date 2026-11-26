# DeskGlide

**One keyboard, one mouse, one monitor, one pair of headphones, two computers. No reaching for the monitor's input button.**

Move the mouse off the edge of one computer's screen and:

1. **Synergy** (or **Deskflow**, its free open-source version) moves the mouse and keyboard to the other computer.
2. **DeskGlide** sees the switch and tells the monitor to change its input to that computer.
3. If you like, your headphones play the sound of the computer that has the mouse, or both computers mixed.

DeskGlide is a small tray app with nothing to install. The same files run on both computers. It talks to the monitor over DDC/CI through `dxva2.dll`, which ships with Windows, and the two computers find each other on your network by themselves.

```
 PC A (server)  ──DisplayPort──┐
   keyboard + mouse            ├──  one monitor
 PC B (client)  ────HDMI───────┘
       ▲
       └── Synergy / Deskflow shares keyboard + mouse over the network
           DeskGlide shares monitor switching and sound over the same network
```

## Requirements

- Windows 10 or 11 on both computers, on the same network
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

Now check that moving the mouse past that edge controls the other computer. If it doesn't, fix this before going further, because DeskGlide depends on it.

**Deskflow only:** turn on **Log to file** in Deskflow's settings and note the file path. You'll need it in step 4.

### 2. Install DeskGlide on both computers

On **each** computer:

1. Download this repository (**Code > Download ZIP**) and extract it somewhere it can stay, for example `Documents\DeskGlide`.
2. Double-click **Install.cmd**. If Windows asks whether to run it, choose **Run**.
3. If Windows Firewall asks about PowerShell, allow it on **Private networks**. The two computers can't find each other without this.

A monitor icon appears in the taskbar tray (it may be under the **^** arrow). DeskGlide now starts by itself every time you log in.

### 3. Pair the two computers

1. On either computer, right-click the tray icon and choose **Pair with other PC...**, then click **No**. It shows a code like `K7MX-Q2PD`.
2. On the other computer, choose **Pair with other PC...**, click **Yes** and type that code.

Within a few seconds both computers show **Paired with ...**. You only do this once.

### 4. Show each computer on the monitor once

DeskGlide learns which monitor input each computer uses by asking the monitor while that computer is on screen. Move the mouse to the other computer; if the screen doesn't follow, press the monitor's input button to show it. Wait a few seconds, then do the same for the first computer. From then on, the monitor follows the mouse.

**Deskflow only:** right-click the tray icon, choose **Open settings folder**, open `config.json` and set `"synergyLog"` to your Deskflow log path, for example `"synergyLog": "C:\\Users\\me\\deskflow.log"` (double backslashes). Then quit and start DeskGlide again (run **Install.cmd** again).

### 5. Sound (optional)

On the computer your headphones are plugged into, right-click the tray icon and check **Headphones are plugged into this PC**. The other computer then sends its sound there. Choose what you hear under **Audio**:

| Audio | What you hear |
|---|---|
| **Follow mouse** (default) | Only the computer that has the mouse. While the mouse is on the other computer, this computer's apps are muted; when it comes back they are unmuted. Apps you muted yourself stay muted. |
| **Hear both** | Both computers mixed together. Nothing is muted. |
| **Off** | Nothing is sent. |

Changes in the tray menu apply to both computers.

## Tray menu

| Item | What it does |
|---|---|
| Monitor follows mouse | Switch the monitor's input when the mouse moves to the other computer |
| Audio | Follow mouse / Hear both / Off |
| Headphones are plugged into this PC | This computer plays the other one's sound |
| Pause | Stop switching and sound until you uncheck it |
| Pair with other PC... | Connect the two computers (once) |
| Open settings folder | `%APPDATA%\DeskGlide`: `config.json` and `deskglide.log` |
| Quit | Stop DeskGlide until the next login |

Hover over the icon to see which computer it's paired with and which one has the mouse. Problems show up as notifications.

## Settings

Most settings are in the tray menu. `config.json` also has these, for unusual setups. Quit DeskGlide before editing it:

| Setting | Default | What it does |
|---|---|---|
| `inputOverride` | `0` | This computer's monitor input, if automatic detection gets it wrong. Common values: `15` = DisplayPort 1, `16` = DisplayPort 2, `17` = HDMI 1, `18` = HDMI 2 |
| `synergyLog` | Synergy 3 agent log | Path to the Synergy/Deskflow log file |
| `screenName` | computer name | This computer's screen name in Synergy/Deskflow, if it isn't the Windows computer name |

## Uninstall

Double-click **Uninstall.cmd** on each computer. It stops DeskGlide, unmutes any app it muted and removes it from Startup. Your settings stay in `%APPDATA%\DeskGlide`. Delete that folder too if you won't reinstall.

**Upgrading from DeskGlide 1** (`deskglide.ps1` / `deskglide-audio.ps1`): Install.cmd stops the old scripts, but delete their old shortcuts from your Startup folder yourself (press Win+R and type `shell:startup`).

## Copy-paste between the computers

| What | Synergy 3 | Deskflow | How |
|---|---|---|---|
| Text | Yes | Yes | Copy on one computer, move the mouse over, paste |
| Images / screenshots | Yes | Yes | Same as text |
| Files and folders | No | No | Use one of the options below |

Both tools dropped file drag-and-drop, so for files use something Windows already has:

- **Nearby sharing** (built into Windows 10 and 11): turn it on under Settings > System > Nearby sharing on both computers. Then right-click a file, choose **Share**, and pick the other computer.
- **Shared folder:** right-click a folder, choose **Properties > Sharing > Share**, then open it from the other computer as `\\COMPUTER-NAME\FolderName`. Good for files you move every day.

## Good to know

- Which computer is the server is detected automatically: it's the one whose Synergy/Deskflow log has `switch from` lines.
- The computer that is on screen sends the switch command, because many monitors ignore commands from an input they aren't showing.
- DeskGlide waits 400 ms after the mouse crosses, so a quick bounce at the screen edge doesn't flicker the monitor.
- Sound delay is about 50–100 ms on a wired or home Wi-Fi network: fine for music and video, noticeable in games. For zero delay, a small hardware audio mixer is the better tool.
- Sound is sent uncompressed (about 1.5 Mbit/s). Every message and sound packet is signed with the key from pairing, so other devices can't control DeskGlide or inject sound. Sound is **not encrypted**, so use it on your own network only.
- Network ports: UDP `6991` (finding each other and control) and `6990` (sound).
- DeskGlide records the sending computer's default playback device. If that device changes or is unplugged, it reconnects to the new default by itself.
- Surround sound is sent as stereo (front left and right only).

## Troubleshooting

Right-click the tray icon > **Open settings folder** > `deskglide.log` shows what DeskGlide saw and did.

- **Tooltip says "... not found":** the computers can't reach each other. Allow PowerShell through Windows Firewall on Private networks on both, and check that both are on the same network (not a guest Wi-Fi).
- **The monitor doesn't switch:** do step 4 again. Check that the log shows `This PC is on monitor input ...` on both computers. If the input is wrong, set `inputOverride`.
- **Nothing happens when the mouse crosses:** the log path is wrong, or the log isn't being written. Synergy 3's log is `%LOCALAPPDATA%\synergy-dragon\logs\synergy-dragon-agent.log`. For Deskflow, make sure Log to file is on and set `synergyLog`.
- **It always switches to the other input:** your screen name in Synergy/Deskflow isn't the Windows computer name. Set `screenName`.
- **"The monitor does not answer DDC/CI":** turn on DDC/CI in the monitor's on-screen menu.
- **Windows rearranges after a switch:** some monitors drop the DisplayPort link when they change input, so the computer thinks the monitor was unplugged. Try another cable or port, or turn off the monitor's "DP auto-switch" or deep-sleep option.
- **Debugging:** `powershell -ExecutionPolicy Bypass -File .\DeskGlide.ps1 -Console` runs with output to the console (quit the tray copy first). `-Test` runs the built-in self-check.

## Tested on

- Windows 11 with Synergy 3 and an MSI monitor (DisplayPort + HDMI)
- Sound between two Windows PCs on the same Wi-Fi network (DeskGlide 1; DeskGlide 2 uses the same sound code)

Deskflow support relies on Deskflow writing the same `switch from "A" to "B"` log line as Synergy. If it doesn't work for you, please open an issue.

## License

MIT
