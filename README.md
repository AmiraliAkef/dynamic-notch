# Dynamic Notch

A Dynamic Island for the MacBook notch. It lives around the camera notch and shows live activities:

- **Now Playing**: album art and equalizer bars driven by the audio that's actually playing (a Core Audio tap plus an FFT). Hover to get controls and a seek bar. Works with Music, Spotify, browsers and anything else that reports to macOS Now Playing.
- **Claude Code**: shows when Claude is working, needs your permission or input, or has finished, for each session. Click to jump to the terminal it's running in.
- **Terminal**: each open zsh session is listed with how long it's been open, what it's running, and a button to quit it. Commands that run longer than 10s also show in the notch while they run, then show a ✓ or ✗ banner when they finish.
- **Timers**: built-in timers and a stopwatch, plus timers running in **Clock.app**.
- **Two at once**: like the iPhone, a second activity gets its own bubble to the right of the notch while the main one stays on the left wing. Click either side to open it.
- **System**: charger plugged in or unplugged, low battery, Bluetooth devices (AirPods…) connecting.

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
| zsh hook using `zsh/net/socket`, so it adds no extra process per command | `hooks/notch.zsh` |

The Now Playing and Clock integrations use undocumented system internals, so a future macOS update may break them. Each one fails on its own without affecting the rest of the app.

## License

MIT, see [LICENSE](LICENSE).
