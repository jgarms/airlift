# Airlift

Pipe audio from any macOS app (e.g. Spotify) to one or more AirPlay 2 speakers
— HomePods included — in sync. macOS can only AirPlay *all* system audio to
*one* speaker; Airlift streams a single app to several, using the OS's own
AirPlay 2 engine.

## How it works

- **Capture** — a Core Audio *process tap* (`AudioHardwareCreateProcessTap`,
  macOS 14.2+) grabs one app's audio and mutes it locally while streaming.
- **Render** — the tapped PCM feeds an `AVSampleBufferAudioRenderer` via a
  ring buffer.
- **Route** — the renderer is attached to a private `AVOutputContext`. Speaker
  selection uses the *system* AirPlay picker (`AVRoutePickerView` +
  `setOutputContextID:` SPI): the picker UI runs inside Apple's entitled
  `AirPlayUIAgent`, which is allowed to attach HomePods to our context. The OS
  (`airplayd`) then owns the AirPlay 2 group, so multi-room stays in sync and
  protocol changes remain Apple's problem.

Why the picker instead of programmatic selection: enumerating AirPlay devices
(`AVOutputDeviceDiscoverySession`) is gated by the Apple-restricted
`com.apple.avfoundation.allows-access-to-device-list` entitlement — unentitled
apps get an empty device list while the daemon happily discovers on their
behalf. The picker sidesteps the gate with native UI.

> ⚠️ This uses private API (`AVOutputContext`, route-picker SPI) resolved at
> runtime. It's for personal use; expect breakage on OS updates.

## Build & run

```sh
Scripts/make-app.sh     # swift build + wraps build/Airlift.app (ad-hoc signed)
open build/Airlift.app
```

Menu bar (AirPlay icon, with a dot while streaming): **Choose Speakers…** opens the native AirPlay picker
(AirPlay 2 speakers multi-select), **Stream From** picks the source app,
**Start Streaming** taps it. Approve the Local Network and audio-capture
permission prompts on first use.

The same binary is also a CLI:

```sh
airlift devices                          # list Core Audio output devices
airlift record Spotify 5 out.wav         # tap an app to a file
airlift play Spotify 30 "Studio Display" # tap → local output device(s)
airlift context-play Spotify 10          # tap → renderer/context path
airlift ctl start [app] | stop           # remote-control the menu bar app
```

Logs: `~/Library/Logs/airlift.log`.

## Behavior notes

- A reconcile loop re-taps automatically when the source app quits/relaunches
  and restarts a failed renderer; dropped routes get a best-effort re-attach.
- Speaker picks don't survive an app restart (the OS rehydrates a saved
  context with the wrong type, which would break the picker) — re-pick after
  relaunching Airlift.
- Expect ~2 s of AirPlay latency; source-app volume applies upstream of the
  stream, per-speaker volume via the picker/Home app.

## Layout

- `Sources/airlift/` — CLI + menu bar app (tap, ring buffer, renderer,
  reconcile loop).
- `Sources/AirliftRouting/` — ObjC shim over the private routing classes,
  resolved via `NSClassFromString`/`objc_msgSend`; compiled `-fno-objc-arc`
  (hand-rolled `init` msgSends are incompatible with ARC bookkeeping).
- `Scripts/make-app.sh` — app-bundle wrapper (bundle identity is what makes
  TCC's Local Network permission work).
- `Resources/Airlift.icns` — app icon. To regenerate after editing the artwork,
  run `swift Scripts/make-icon.swift` followed by
  `iconutil -c icns build/Airlift.iconset -o Resources/Airlift.icns`.
