# Dynamic Notch

A Dynamic Island for the MacBook notch. It lives around the camera notch and shows live activities:

- **Now Playing**: album art and equalizer bars driven by the audio that's actually playing (a Core Audio tap plus an FFT). Hover to get controls and a seek bar. Works with Music, Spotify, browsers and anything else that reports to macOS Now Playing.
- **Claude Code**: shows when Claude is working, needs your permission or input, or has finished, for each session. Click to jump to the terminal it's running in.
- **Terminal**: each open zsh session is listed with how long it's been open, what it's running, and a button to quit it (which also closes its Terminal or iTerm2 tab). Commands that run longer than 10s also show in the notch while they run, then show a ✓ or ✗ banner when they finish.
- **Timers**: built-in timers and a stopwatch, plus timers running in **Clock.app**.
- **Two at once**: like the iPhone, a second activity gets its own bubble to the right of the notch while the main one stays on the left wing. Click either side to open it.
- **System**: charger plugged in or unplugged, low battery, Bluetooth devices (AirPods…) connecting.
- **Caffeinated mode**: the ☕ button in the expanded notch (or the menu) keeps the Mac awake **with the lid closed**, so agents keep working in your bag. It turns itself off when the battery drops below 20% (configurable), when the Mac gets hot, after a set time, or when your agents finish, and it's always undone when the app quits. The menu bar icon becomes a cup while it's on.
- **iPhone notifications**: get "needs your permission" and "finished" pushes for Claude Code on your iPhone through the free [ntfy](https://ntfy.sh) app, optionally only while you're away from the Mac (lid closed, screen locked). They also show on the Mac through iPhone Mirroring.

## Build & install

```sh
./build.sh            # builds build/DynamicNotch.app
./build.sh --install  # copies it to /Applications and launches it
```

Requires Xcode 16+ (Swift 6) on macOS 14+. Run `scripts/make-signing-cert.sh` once first: it creates a local signing certificate so macOS remembers permissions across rebuilds (ad-hoc builds lose them every time). Then, from the menu bar icon:

- **Install Claude Code hooks** adds a hook to each event in `~/.claude/settings.json` (a backup is saved next to it).
- **Install shell integration (zsh)** adds one `source` line to `~/.zshrc`.
- **Install `notch` command** symlinks the CLI into `/usr/local/bin` or `~/.local/bin`.
- **Live equalizer** needs the System Audio Recording permission (macOS asks the first time). The audio is analyzed in memory and never recorded. Turn it off in the menu with *Sync equalizer to audio*.
- **Caffeinated mode** needs a one-time *Set up Caffeinated mode…*: macOS asks for your admin password once to install `/etc/sudoers.d/dynamicnotch`, which allows only `pmset -a disablesleep 0|1` without a password (it's checked with `visudo` first). Remove it from the menu at any time. If you ever need to undo it by hand: `sudo pmset -a disablesleep 0`.
- **iPhone notifications**: *iPhone notifications › Set up…* creates a random private topic. Subscribe to it in the ntfy iOS app. Anyone who knows the topic can read the messages, so keep it private, or point it at your own server with `defaults write com.amirali.dynamicnotch phone.server https://ntfy.example.com`.
- **Clock app timers** need Full Disk Access (System Settings › Privacy & Security › Full Disk Access › Dynamic Notch). Without it, macOS blocks reading Clock's data.

## CLI

```sh
notch timer 25m Focus      # also 90s, 1h30m, 5:00
notch timer pause|resume|cancel
notch stopwatch start|stop|reset
notch notify "Deploy finished" "api-server" --icon checkmark.circle.fill
```

## How it works

| Piece | Where |
|---|---|
| Transparent panel above the menu bar, sized from `NSScreen.auxiliaryTopLeftArea`/`safeAreaInsets` | `Window/` |
| Activity priorities, banners, idle → compact → banner → expanded | `Core/NotchModel.swift` |
| Unix socket (`~/Library/Application Support/DynamicNotch/notch.sock`, JSON lines) | `Core/SocketServer.swift` |
| Now Playing. MediaRemote only answers Apple-signed processes since macOS 15.4, so `Helper/MediaRemoteHelper.m` is loaded into `/usr/bin/perl` | `Activities/NowPlaying.swift` |
| Live equalizer. Taps the Now Playing app's audio processes (falls back to all system audio), FFTs it into 6 log-spaced bands with adaptive gain, and delays the result by the output latency so the bars match what you hear | `Activities/AudioVisualizer.swift` |
| Clock.app timers, read from mobiletimerd's Core Data store (`ZMTCDTIMER`; state 2 = paused, 3 = running; end date archived as `MTTimerDate`) | `Activities/ClockAppTimers.swift` |
| Caffeinated mode: `pmset disablesleep` via a narrow sudoers rule, plus battery/thermal/time/agent safety checks and crash recovery on next launch | `Activities/Caffeinate.swift` |
| iPhone notifications: JSON POST to an ntfy topic on Claude "waiting"/"finished" and Caffeinated auto-off | `Activities/PhoneNotifier.swift` |
| App icon: `Resources/AppIcon.icon` (Icon Composer format, with default, dark and tinted appearances) for macOS 26+, plus a classic `.icns` from `DynamicNotchIcons/AppIcon.appiconset` for older systems. Edit the SVG masters in `DynamicNotchIcons/`, then run `scripts/make-app-icon.sh` | `build.sh` |
| zsh hook using `zsh/net/socket`, so it adds no extra process per command | `hooks/notch.zsh` |

The Now Playing and Clock integrations use undocumented system internals, so a future macOS update may break them. Each one fails on its own without affecting the rest of the app.

## License

MIT, see [LICENSE](LICENSE).
