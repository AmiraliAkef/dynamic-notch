# Dynamic Notch for iPhone

A companion app that shows your Mac's agents as a **Live Activity** on the Lock Screen and in the Dynamic Island. The dot is orange while agents work (like the mic indicator), red when one is waiting for you, and grey when everything is idle or the Mac is out of range. iPhone Live Activities also show in the Mac menu bar through iPhone Mirroring.

## How it talks to the Mac

Over **Bluetooth LE**, with no server, no push notifications and no paid developer account:

- Dynamic Notch on the Mac is a Bluetooth peripheral publishing one `AgentStatus` value (`Sources/NotchShared/AgentStatus.swift`, shared by both apps). It sends on every change and every 60s as a heartbeat.
- The iPhone app subscribes with the `bluetooth-central` background mode, so iOS wakes it for each update and it refreshes the Live Activity. If the Mac stops sending for 2.5 minutes, the activity greys out ("Mac out of range") without the app having to run.
- The value requires encryption, so iOS shows a one-time pairing prompt and nobody else nearby can read it.

## Install on your iPhone

1. On the Mac, turn on **iPhone indicator** in the Dynamic Notch menu (it's on by default) and allow Bluetooth if macOS asks.
2. `cd iOS && xcodegen` (only needed after editing `project.yml`; `brew install xcodegen`), then `open DynamicNotch.xcodeproj`.
3. Plug in your iPhone, select it as the run destination, and press **Run**. The first time, trust the developer profile on the phone: Settings › General › VPN & Device Management.
4. Open the app, allow Bluetooth, and accept the pairing prompt. The Live Activity starts on its own.

## Limits

- **Range**: Bluetooth reaches about 10 m.
- **Starting**: iOS only lets an app start a Live Activity while it's open, and ends it after about 8 hours. Opening the app brings it back.
- **Free signing**: apps signed with a free Apple ID expire after 7 days. Press Run in Xcode again to renew.

## Testing in the Simulator

The Simulator has no Bluetooth. Run with the `-demoStatus` launch argument (Debug builds only) to fill the app and Live Activity with fake agents.
