# CompyCoach

A macOS menu bar app that nudges you to move every 45–75 minutes. Squats, push-ups, standing stretches, 20-20-20 eye breaks, and short walks. Targets adapt automatically based on your hit rate over the past 7 days.

## Install

1. Copy `CompyCoach.app` from `build/export/` to your `/Applications` folder.
2. **Right-click → Open** on the first launch to bypass Gatekeeper (the app is ad-hoc signed, not notarized).
3. Click the figure icon in the menu bar to open the menu.
4. Enable **Launch at Login** from the menu if you want it to start automatically on login.

> **Note:** Launch at Login only registers successfully when the app is running from `/Applications` or `~/Applications`. It will silently fail if launched from Downloads or DerivedData.

## Build from source

Requires Xcode 15+ and macOS 13+.

```bash
xcodebuild -scheme CompyCoach -configuration Release \
    -archivePath ./build/CompyCoach.xcarchive archive

xcodebuild -exportArchive \
    -archivePath ./build/CompyCoach.xcarchive \
    -exportPath ./build/export \
    -exportOptionsPlist ExportOptions.plist
```

The app bundle lands at `./build/export/CompyCoach.app`.

## How it works

- **Trigger**: a randomized 45–75 minute timer fires when you haven't been idle for more than 5 minutes. It uses the system uptime clock, so sleep time doesn't count — after waking your Mac, the full interval resets.
- **Exercises**: Squats, Push-ups, Stand & Stretch, Sit-ups, 20-20-20 Eye Relax, Walk. Walk is capped once per day. Exercises rotate in order.
- **Adaptive targets**: after each completed exercise, the app looks at your hit rate over the past 7 days. ≥80% hit → target increases ~10%. ≤50% hit → target decreases ~10%. Sit-ups start at 12. Floors: Squats 5, Push-ups 4, Sit-ups 5, Stand/Stretch 20 sec.
- **Data**: stored in `~/Library/Application Support/CompyCoach/`. `log.json` is append-only NDJSON. `targets.json` holds current targets.
