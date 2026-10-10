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
behalf. Selecting is gated too: `-[AVOutputContext setOutputDevices:]` from an
unentitled process fails with `-12023`, even with live device objects taken
from an already-routed context, and MediaRemote's discovery sessions also come
back empty. The picker sidesteps both gates with native UI, which is also why
its list can't be filtered to HomePods or pre-selected.

> ⚠️ This uses private API (`AVOutputContext`, route-picker SPI) resolved at
> runtime. It's for personal use; expect breakage on OS updates.

## Build & run

```sh
Scripts/make-app.sh     # swift build + wraps build/Airlift.app (ad-hoc signed)
open build/Airlift.app
```

Airlift streams automatically: it starts streaming whenever the source app
plays and stops when it goes quiet. If no speakers are selected when playback
starts, it pops up the native AirPlay picker (AirPlay 2 speakers
multi-select). Quit Airlift to play locally again.

Menu bar (AirPlay icon, full-strength while streaming, dimmed while idle):
**Choose Speakers…** reopens the picker, **Pause Airlift** suspends streaming
until resumed, **Stream From** picks the source app, **Launch at Login**
registers the app as a login item. Approve the Local Network and audio-capture
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

- The tap (which mutes the source app locally) stays up while the source app
  runs and speakers are selected. The renderer only exists while the app is
  audible: the first audible buffer starts it, 30 s of silence stops it and
  releases the speakers.
- With no speakers selected the tap only listens: the source app plays
  locally as usual, and the picker opens when it starts playing (once per
  stretch of playback).
- A reconcile loop (2 s tick, plus app launch/quit, Core Audio process-list
  and route-change events) re-taps when the source app quits/relaunches and
  restarts a failed renderer.
- Speaker picks don't survive an app restart (the route lives on a context
  that dies with the process, and can't be re-selected programmatically) —
  Airlift asks again the next time the source app plays.
- Expect ~2 s of AirPlay latency; source-app volume applies upstream of the
  stream, per-speaker volume via the picker/Home app.
- While streaming Spotify, the menu bar app reads its current track locally
  every 2 s and publishes title, artist, album, and artwork to Now Playing.
  Approve the macOS Automation prompt to let Airlift read Spotify; no Spotify
  account login or Web API setup is needed. Artwork downloads from the URL
  Spotify supplies. Track progress and remote playback commands are not yet
  implemented. If metadata is unavailable (or another app is selected), it
  falls back to **Spotify via Airlift** (or that app's name), with the Mac's
  name underneath. Metadata clears when streaming ends, including the usual
  30 s silence timeout. Metadata delivery to HomePod and Apple Watch has
  been verified during streaming.
  The menu also shows **Title — Artist** on a separate line while Spotify
  metadata is available; long titles are shortened with the full text in a
  tooltip.

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
