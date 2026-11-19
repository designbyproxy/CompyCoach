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

- **Trigger**: a randomized 45–75 minute countdown of *active* time. It freezes while you're on a call (camera, mic, or screen sharing), away (no input for 3 minutes — the idle stretch is refunded), asleep, or already looking at a nudge, then resumes where it left off. After any pause there are always at least 2 minutes before the next nudge. The menu shows the time left and why it's paused.
- **Exercises**: Squats, Push-ups, Stand & Stretch, Sit-ups, 20-20-20 Eye Relax, Walk. Walk is capped once per day. Exercises rotate in order.
- **Walk weather**: set your home ZIP from the menu ("Set Home ZIP for Walk Weather…"). Walks are skipped when it feels colder than 45°F, it's precipitating, or there's a 40%+ chance of rain in the next hour, per [Open-Meteo](https://open-meteo.com) (free, no API key). A skipped walk comes back later that day once conditions improve. The ZIP is stored only in this Mac's user defaults; with no ZIP set, or if the weather can't be fetched, walks are always offered.
- **Adaptive targets**: after each completed exercise, the app looks at your hit rate over the past 7 days. ≥80% hit → target increases ~10%. ≤50% hit → target decreases ~10%. Sit-ups start at 12. Floors: Squats 5, Push-ups 4, Sit-ups 5, Stand/Stretch 20 sec.
- **Data**: stored in `~/Library/Application Support/CompyCoach/`. `log.json` is append-only NDJSON. `targets.json` holds current targets.
