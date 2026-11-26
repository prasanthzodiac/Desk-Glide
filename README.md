# DeskGlide

**One keyboard, one mouse, one monitor, one pair of headphones, two computers. No reaching for the monitor's input button.**

Move the mouse off the edge of one computer's screen and:

1. **Synergy** (or **Deskflow**, its free open-source version) moves the mouse and keyboard to the other computer.
2. **DeskGlide** sees the switch and tells the monitor to change its input to that computer.
3. If you like, your headphones play the sound of the computer that has the mouse, or both computers mixed.

DeskGlide is a small Windows app with nothing to install: a window plus a tray icon. The same files run on both computers. It talks to the monitor over DDC/CI through `dxva2.dll`, which ships with Windows, and the two computers find each other on your network by themselves.

```
 PC A (server)  ──DisplayPort──┐
   keyboard + mouse            ├──  one monitor
 PC B (client)  ────HDMI───────┘
       ▲
       └── Synergy / Deskflow shares keyboard + mouse over the network
           DeskGlide shares monitor switching and sound over the same network
```

## What it looks like

![DeskGlide window, light theme](docs/window-light.png)

The window follows Windows' light or dark app theme ([dark version](docs/window-dark.png)). It has:

- **A status header:** "Connected to LAPTOP" (or "Not paired" / "Looking for ..."), and which computer has the mouse right now.
- **Layout:** both screens side by side, like Windows' display settings. This computer is outlined and the one with the mouse is highlighted. Drag the other screen to the side where it sits, or pick Left / Right / Above / Below.
- **Monitor:** "Monitor follows mouse", each computer's input in plain words (DisplayPort, HDMI 1, ...), **Switch monitor now**, and **Test**, which asks the monitor what it shows without switching anything.
- **Sound:** Follow mouse / Hear both / Off, which computer the headphones are plugged into (one choice, shared by both computers), the other computer's volume, and a line that always says what you hear, or why you hear nothing.
- **Pairing:** show a code, or type one in. Progress and success show right in the window. **Unpair** is here too.
- **Settings:** Start with Windows, Pause, the Synergy/Deskflow log, the other computer's address (for computers on different networks), a script to run when the screen switches, and the log.

The tray icon is a small monitor whose left half is this computer and right half the other one. The half that has the mouse is lit, and the icon is grey while paused or not paired. Double-click it to open the window. Notifications only appear for problems and when pairing succeeds.

The first time it starts, DeskGlide opens a short setup guide in the same window:

![Setup guide, first page](docs/wizard.png)

## Requirements

- Windows 10 or 11 on both computers, on the same network (or see [PCs on different networks](#pcs-on-different-networks))
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

**Deskflow only:** turn on **Log to file** in Deskflow's settings and note the file path. After setup, put it under **Settings > Synergy or Deskflow log** in DeskGlide's window.

### 2. Install DeskGlide on both computers

On **each** computer:

1. Download this repository (**Code > Download ZIP**) and extract it somewhere it can stay, for example `Documents\DeskGlide`.
2. Double-click **Install.cmd**. If Windows asks whether to run it, choose **Run**.
3. If Windows Firewall asks about PowerShell, allow it on **Private networks**. The two computers can't find each other without this.

DeskGlide opens its setup guide and adds a monitor icon to the taskbar tray (it may be under the **^** arrow). From now on it starts by itself every time you log in.

### 3. Follow the setup guide on both computers

1. **Welcome:** what DeskGlide does.
2. **Pair:** on one computer click **Show a code on this PC**. It shows a code like `K7MX-Q2PD`. Type that code on the other computer and click **Pair**. Within a few seconds both say **Paired with ...**. You only do this once.
3. **Monitor:** move the mouse to each computer once and wait a few seconds. If the screen doesn't follow, press the monitor's input button. A tick appears next to each computer as DeskGlide learns its input.
4. **Headphones:** pick the computer your headphones are plugged into. The other computer then sends its sound there. Both computers share this choice.
5. **Done.**

You can skip the guide and do the same things in the main window at any time.

### Sound modes

| Sound | What you hear |
|---|---|
| **Follow mouse** (default) | Only the computer that has the mouse. While the mouse is on the other computer, this computer's apps are muted; when it comes back they are unmuted. Apps you muted yourself stay muted. |
| **Hear both** | Both computers mixed together. Nothing is muted. |
| **Off** | Nothing is sent. |

Changes in the window or the tray menu apply to both computers; the newest change wins.

## PCs on different networks

DeskGlide finds the other computer with a network broadcast. Where broadcast doesn't reach, give it the other computer's address. The pairing code is still the only security step.

- **A direct Ethernet cable between the two computers:** nothing to do. Windows gives both ends an automatic `169.254.x.x` address and broadcast works over it.
- **Tailscale or ZeroTier:** pair as usual. The computer showing the code also lists its addresses, for example `100.101.5.7 (Tailscale)`. If the other computer can't find it within about 10 seconds, it shows an **Other PC's address** box: type that address and click **Connect**. You can also set it any time under **Settings > Other PC's address**.
- **Phone hotspot, or Wi-Fi that blocks devices from seeing each other:** use the same address box with the address shown on the other computer.

Once connected, DeskGlide remembers the address and uses it again at the next start.

## Tray menu

| Item | What it does |
|---|---|
| Open DeskGlide | Opens the window (or double-click the icon) |
| Monitor follows mouse | Switch the monitor's input when the mouse moves to the other computer |
| Sound | Follow mouse / Hear both / Off |
| Headphones are plugged into | This computer or the other one |
| Pause | Stop switching and sound until you uncheck it |
| Quit | Stop DeskGlide until the next login (closing the window only hides it) |

Hover over the icon to see which computer it's paired with and which one has the mouse.

## Settings

Most settings are in the window. `%APPDATA%\DeskGlide\config.json` also has these, for unusual setups. Quit DeskGlide before editing it:

| Setting | Default | What it does |
|---|---|---|
| `inputOverride` | `0` | This computer's monitor input, if automatic detection gets it wrong. Common values: `15` = DisplayPort 1, `16` = DisplayPort 2, `17` = HDMI 1, `18` = HDMI 2 |
| `screenName` | computer name | This computer's screen name in Synergy/Deskflow, if it isn't the Windows computer name |

## Upgrading from DeskGlide 2

Your pairing is kept. On **each** computer, replace the files with the new ones and double-click **Install.cmd** again. It stops the old copy, starts the new one and opens the window. The old "Headphones are plugged into this PC" checkbox becomes the shared headphones choice; check the Sound card once to make sure it names the right computer.

**Upgrading from DeskGlide 1** (`deskglide.ps1` / `deskglide-audio.ps1`): Install.cmd stops the old scripts, but delete their old shortcuts from your Startup folder yourself (press Win+R and type `shell:startup`).

## Uninstall

Double-click **Uninstall.cmd** on each computer. It stops DeskGlide, unmutes any app it muted and removes it from Startup. Your settings stay in `%APPDATA%\DeskGlide`. Delete that folder too if you won't reinstall.

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
- The computer that is on screen sends the switch command, because many monitors ignore commands from an input they aren't showing. About 2 seconds later DeskGlide asks the monitor whether it really switched, tries once more if not, and tells you if the monitor refused.
- When the mouse arrives on a computer, DeskGlide wakes its screen, so the monitor doesn't switch to a sleeping computer.
- DeskGlide waits 400 ms after the mouse crosses, so a quick bounce at the screen edge doesn't flicker the monitor.
- The Layout card is DeskGlide's own layout, shared by both computers. Synergy still decides where the mouse really crosses for now. If Synergy's layout is different, the card says so. DeskGlide reads Synergy's layout only as the starting point and never changes Synergy's files.
- Sound delay is about 50–100 ms on a wired or home Wi-Fi network: fine for music and video, noticeable in games. For zero delay, a small hardware audio mixer is the better tool.
- Sound is sent uncompressed (about 1.5 Mbit/s). Every message and sound packet is signed with the key from pairing, so other devices can't control DeskGlide or inject sound. Sound is **not encrypted**, so use it on your own network only.
- Network ports: UDP `6991` (finding each other and control) and `6990` (sound).
- DeskGlide records the sending computer's default playback device. If that device changes or is unplugged, it reconnects to the new default by itself.
- Surround sound is sent as stereo (front left and right only).

## Troubleshooting

Click **Open log** at the bottom of the window to see what DeskGlide saw and did.

- **The header says "Looking for ...":** the computers can't reach each other. Allow PowerShell through Windows Firewall on Private networks on both, check that both are on the same network (not a guest Wi-Fi), or set the other computer's address in Settings.
- **The monitor doesn't switch:** click **Test** in the Monitor card. It says whether the monitor answers and which inputs DeskGlide knows. If an input says "not learned yet", show that computer on the monitor once. If the input is wrong, set `inputOverride`.
- **"Your monitor didn't accept the switch":** turn on DDC/CI in the monitor's menu. Some monitors only accept input changes with the input set to manual rather than auto.
- **Nothing happens when the mouse crosses:** the log path is wrong, or the log isn't being written. Synergy 3's log is `%LOCALAPPDATA%\synergy-dragon\logs\synergy-dragon-agent.log`. For Deskflow, make sure Log to file is on and set the path in Settings.
- **It always switches to the other input:** your screen name in Synergy/Deskflow isn't the Windows computer name. Set `screenName`.
- **No sound:** the line at the bottom of the Sound card says why (not paired, sound off, no headphones computer chosen, paused, or the other computer not connected).
- **Windows rearranges after a switch:** some monitors drop the DisplayPort link when they change input, so the computer thinks the monitor was unplugged. Try another cable or port, or turn off the monitor's "DP auto-switch" or deep-sleep option.
- **Debugging:** `powershell -ExecutionPolicy Bypass -File .\DeskGlide.ps1 -Console` runs with output to the console (quit the tray copy first); add `-ShowWindow` to open the window too. `-Test` runs the built-in self-check.

## Tested on

- Windows 11 with Synergy 3 and an MSI monitor (DisplayPort + HDMI)
- Sound between two Windows PCs on the same Wi-Fi network

Deskflow support relies on Deskflow writing the same `switch from "A" to "B"` log line as Synergy. If it doesn't work for you, please open an issue.

## License

MIT
