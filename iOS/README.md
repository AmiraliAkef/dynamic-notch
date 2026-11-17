# Dynamic Notch for iPhone

A companion app that shows your Mac's agents as a **Live Activity** on the Lock Screen and in the Dynamic Island. The dot is orange while agents work (like the mic indicator), red when one is waiting for you, and grey when everything is idle or the Mac is out of range.

## How it talks to the Mac

Over **Bluetooth LE**, with no server, no push notifications and no paid developer account:

- Dynamic Notch on the Mac is a Bluetooth peripheral publishing one `AgentStatus` value (`Sources/NotchShared/AgentStatus.swift`, shared by both apps). It sends on every change and every 60s as a heartbeat.
- The iPhone app subscribes with the `bluetooth-central` background mode, so iOS wakes it for each update and it refreshes the Live Activity. If the Mac stops sending for 2.5 minutes, the activity greys out ("Mac out of range") without the app having to run.
- macOS doesn't let apps accept Bluetooth pairing, so each status is encrypted with AES-GCM instead. The key is made on the Mac and handed to the iPhone once through a QR code; anyone nearby can connect, but only the paired phone can read it.

## Install on your iPhone

1. On the Mac, turn on **iPhone indicator** in the Dynamic Notch menu (it's on by default) and allow Bluetooth if macOS asks.
2. `cd iOS && xcodegen` (only needed after editing `project.yml`; `brew install xcodegen`), then `open DynamicNotch.xcodeproj`.
3. Plug in your iPhone, select it as the run destination, and press **Run**. The first time, trust the developer profile on the phone: Settings › General › VPN & Device Management.
4. Open the app and allow Bluetooth. On the Mac, choose **Pair iPhone…** in the Dynamic Notch menu, point the iPhone's Camera at the QR code and tap the link. The Live Activity starts on its own.

## Caffeinated mode from the iPhone

The ☕ button on the Lock Screen banner and in the expanded Dynamic Island (and the toggle in the app) turns Caffeinated mode on the Mac on or off. The command is written to a second Bluetooth characteristic, sealed with the same pairing key and timestamped, so only your phone can send one and a recorded command can't be replayed. Caffeinated mode must be set up on the Mac once first (it needs your admin password).

## Permission requests from the iPhone

When Claude Code asks for permission (run a command, edit a file, fetch a page…), the Dynamic Island expands with a sound and shows what it wants to do, with **Deny** and **Allow**. The same card replaces the agent list on the Lock Screen. The app shows the full command and, when Claude Code offers one, **Always allow** (it adds the same rule as "Yes, and don't ask again" in the terminal).

The prompt in the terminal keeps working at the same time, so you can answer at whichever device is closer. Requests that need a typed answer (Claude's multiple-choice questions, plan approval) stay in the terminal. A request waits for the phone for up to about 10 minutes.

On the Mac this needs the updated Claude Code hooks: choose *Update Claude Code hooks to answer on iPhone* in the Dynamic Notch menu.

## Limits

- **Range**: Bluetooth reaches about 10 m.
- **Starting**: iOS only lets an app start a Live Activity while it's open, and ends it after about 8 hours. Opening the app brings it back.
- **Free signing**: apps signed with a free Apple ID expire after 7 days. Press Run in Xcode again to renew.

## Testing in the Simulator

The Simulator has no Bluetooth. Run with the `-demoStatus` launch argument (Debug builds only) to fill the app and Live Activity with fake agents.
