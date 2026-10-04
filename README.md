# Talkie

**Offline phone-to-phone intercom bridge for two Bluetooth intercoms.**

You have two Bluetooth intercoms (helmet units, walkie-style headsets, …) that
cannot pair with each other directly. Talkie solves that with two
phones and a Wi-Fi hotspot — **no cell tower, no internet, no SIM data
required**:

```
┌───────────┐  HFP/SCO  ┌─────────────┐   Wi-Fi hotspot   ┌────────────┐  HFP/SCO  ┌───────────┐
│ Intercom A│◄─────────►│ Android     │◄─────────────────►│ iPhone     │◄─────────►│ Intercom B│
└───────────┘  Bluetooth│ (Host)      │  WebRTC audio     │ (Client)   │ Bluetooth │           │
                        └─────────────┘  over local LAN    └────────────┘           └───────────┘
```

One phone shares its **Wi-Fi hotspot** (this is the *Host*), the other phone
joins it (this is the *Client*). Live audio then flows between the two
intercoms with the latency of a local network — even in the middle of a
jungle.

---

## How it works

| Layer | Technology |
| --- | --- |
| Intercom ⇄ phone | Standard **Bluetooth headset profile (HFP)**. Pair each intercom to its phone in the system Bluetooth settings, then pick it as the audio route in the app. |
| Phone ⇄ phone | **WebRTC** audio over the hotspot LAN (Opus codec, echo cancellation, noise suppression, jitter buffer, packet-loss concealment — all built into the WebRTC engine). No STUN/TURN servers are used; the connection is fully local. |
| Session setup | A tiny TCP signaling protocol (port **45678**) plus UDP beacon discovery (port **45679**) so the client finds the host automatically — no IP typing needed (manual IP entry is available as a fallback). |
| Survivability | Android: **foreground service** (`microphone|connectedDevice` types) + partial wake lock + Wi-Fi lock + multicast lock, `START_STICKY`, survives task removal. iOS: **audio background mode** with an active audio session. |
| Phone calls | Native **audio-focus (Android)** and **AVAudioSession interruption (iOS)** observers: the intercom mutes itself the moment a call comes in and **auto-resumes** when the call ends. No manual action needed. |
| Reconnection | Heartbeat pings every 3 s. On link loss the client auto-reconnects with backoff and re-discovery; the host goes back to waiting. Survives screen-off, brief hotspot hiccups, and (with VoLTE) phone calls. |

---

## Project layout

```
lib/
  core/          protocol framing, TCP signaling, UDP beacon discovery, SDP tools, logging
  engine/        intercom engine state machine, WebRTC backend abstraction, settings
  platform/      native bridge (method/event channels to Kotlin & Swift)
  ui/            home/call screen, settings, logs, audio-route picker
android/app/src/main/kotlin/com/example/intercom_talkie/
  MainActivity.kt     method/event channels, audio routes, system settings
  IntercomService.kt  foreground service, wake/Wi-Fi/multicast locks, call detection
  NativeEvents.kt     event sink shared by service and activity
ios/Runner/
  AppDelegate.swift   method/event channels, AVAudioSession interruption
                      handling, audio routes, background keep-alive task
test/           protocol, SDP, signaling (real loopback TCP), engine end-to-end
                (two engines over loopback: handshake, mute, PTT, call
                interruption, auto-reconnect), widget smoke tests
.github/workflows/ci.yml   analyze + test + Android APK + iOS compile check
```

---

## Requirements

- Flutter **3.47.5** (the revision pinned in CI; any compatible recent stable
  works) with Dart ≥ 3.13.
- Android device: Android 7.0+ (API 24+).
- iPhone: iOS 15+.
- The two phones must be on the **same Wi-Fi hotspot** (one phone creates it).
- Bluetooth intercoms that act as **headsets (HFP)** — virtually all helmet
  intercoms and BT headsets do.

> ℹ️ **Intercoms with custom BLE audio protocols** (proprietary apps, no
> "headset/HFP" mode) are *not* handled by this version. The audio path is
> designed for HFP-class devices. BLE-GATT intercom support can be added
> later as a separate audio backend.

---

## Setup & run

### 1. Get the code and dependencies

```bash
git clone https://github.com/niranjanrimal25/intercom-talkie.git
cd intercom-talkie
git checkout arena/01a0f84a-intercom-talkie   # or merge the PR into main
flutter pub get
```

### 2. Android phone

```bash
# Run in debug (quick install while connected via USB):
flutter run -d <android-device-id>

# Or build a release APK and sideload it:
flutter build apk --release
# → build/app/outputs/flutter-apk/app-release.apk
adb install build/app/outputs/flutter-apk/app-release.apk
```

On first launch, **allow** the permissions when prompted:

- *Microphone*
- *Nearby devices* (Bluetooth) — needed to route audio to the intercom
- *Notifications* — needed for the persistent session notification

Also recommended (the app has a button for this in Settings):

- **Disable battery optimization** for Talkie so Android keeps the
  link alive with the screen off.
- On aggressive OEMs (Xiaomi, Oppo, Vivo, Huawei…), enable *Auto-start* /
  *Allow background activity* for the app.

### 3. iPhone

You need a Mac with Xcode 15+:

```bash
flutter run -d <iphone-device-id>          # debug run
# or
flutter build ios --release                # then open Xcode to install
```

In Xcode (first time only):

1. Open `ios/Runner.xcworkspace`.
2. Select the *Runner* target → *Signing & Capabilities* → pick your team.
3. Plug in the iPhone, trust the developer profile in
   Settings → General → VPN & Device Management.

On first launch, **allow**:

- *Microphone* permission
- *Local Network* permission (this is what lets the two phones talk)

> ⚠️ On iOS the app keeps running while backgrounded thanks to the audio
> background mode. If the user **force-quits** the app (swipe-up in the app
> switcher), iOS stops it — that is an OS-level limit for every app. Just
> reopen it; it reconnects automatically.

### 4. CI builds (optional, one-time setup)

The repo ships a ready-made GitHub Actions workflow at
[`ci/flutter-ci.yml`](ci/flutter-ci.yml). To enable it, copy it into place
once (the bot that pushes code cannot create workflow files):

```bash
mkdir -p .github/workflows
cp ci/flutter-ci.yml .github/workflows/ci.yml
git add .github/workflows/ci.yml
git commit -m "ci: enable CI"
git push
```

Every push then runs:

- `Analyze and test` — static analysis + the full unit/widget test suite.
- `Android release APK` — a signed-with-debug-key release APK artifact you can
  download from the Actions run and install directly.
- `iOS compile check` — compiles the full iOS app on a macOS runner.

---

## Using the intercom

1. **Pair each intercom to its own phone** in the system Bluetooth settings
   (Android: Settings → Connected devices; iPhone: Settings → Bluetooth).
   The intercom must show as *connected for calls*.
2. On **phone 1** (Android in the diagram above):
   1. Enable the Wi-Fi hotspot (Android: Settings → Hotspot & tethering;
      iPhone: Settings → Personal Hotspot).
   2. Open Talkie → **“Host on this phone”**.
3. On **phone 2**:
   1. Join that Wi-Fi hotspot.
   2. Open Talkie → **“Join the other phone”**.
   3. The app finds the host automatically (via UDP beacon / gateway scan).
      If it can't, type the host IP manually — on Android hotspots usually
      `192.168.43.1`, on iPhone hotspots `172.20.10.1`.
4. Both phones show **CONNECTED** — talk through your intercoms. 🎉
5. Optional: tap the **headphones icon** to choose which audio device
   (Bluetooth intercom / speaker / earpiece) the call uses.

### While talking

- **Mute** — mutes your mic.
- **Hold to talk** — appears in Settings → *Push-to-talk mode*. Use it if you
  hear echo when both intercoms are open (e.g. two riders side by side).
- **Phone call arrives** — the intercom pauses automatically and **resumes
  by itself** when the call ends. You can also take the call on the *other*
  phone; the link self-heals.
- **End** — ends the session (also available as an action on the Android
  notification).
- The call screen shows live **latency / jitter / loss** and voice levels —
  handy when testing link quality in the field.

---

## Shared music

Either person can start a song that plays **on both phones at once**, in
sync, through both intercoms:

1. While connected, tap **Music** in the call panel and pick an audio file
   (MP3, AAC/M4A, FLAC, WAV, OGG — anything your phone can decode).
2. The file is transferred over the intercom link itself (a few seconds for
   a typical song, with the intercom staying live the whole time).
3. Playback starts on both phones simultaneously; the sender keeps the
   master clock and nudges the receiver back into sync if the phones drift.
4. Either rider can pause, resume or stop the shared track from the
   now-playing bar.

Notes:

- This works with **audio files you own** (picked from the system file
  picker). Songs streaming from Spotify/Apple Music cannot be captured —
  iOS forbids capturing other apps' audio entirely, and DRM'd streams are
  protected on Android too.
- Music plays through the active intercom audio route (Bluetooth headset).
  If it comes out of the phone speaker on your device, pick the headset in
  the route sheet (headphones icon).
- The shared track stops automatically when the session ends.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| “No host found” on the client | Make sure both phones are on the *same* hotspot. Discovery uses UDP beacons **plus** an active probe/response exchange, so it also works behind broadcast-filtering access points. On iPhone, grant *Local Network* permission the first time it is asked for (Settings → Privacy & Security → Local Network → Talkie) — the join will then succeed on the next automatic retry. Manual IP entry works too. |
| Passcode rejected | Both phones must use the same passcode in Settings (empty = open). |
| Audio comes from the phone speaker instead of the intercom | Pair the intercom in system Bluetooth settings, then pick it under the headphones icon. On Android tap *Prefer headset/intercom*. |
| Echo / howling | Enable *Push-to-talk mode* in Settings, or lower volume on the intercom. WebRTC echo cancellation handles most cases when the intercom mic is positioned away from the speaker. |
| Link drops when screen turns off (Android) | Disable battery optimization (Settings screen has a button), allow background activity / auto-start on OEM ROMs. |
| Link drops when a phone call comes in | Without VoLTE, a GSM call can briefly tear down the hotspot — the app reconnects automatically once the call ends and the hotspot returns. |
| Can't hear anything but the timer runs | Check both intercoms are powered on and connected; check volume (press volume keys *during* the session — it adjusts the call stream). |
| iOS app stops when backgrounded | Background audio keeps a *live* session running with the screen off. Swiping the app away always kills it — an iOS platform rule no app can bypass; with *Rejoin after restart* enabled, opening Talkie again silently re-establishes the link. |
| Android: audio stops when swiping the app away | Should not happen — the app runs on a cached Flutter engine inside the foreground service. If it does, check that the Talkie notification is present and that the ROM's battery manager isn't force-stopping the app (disable battery optimization from the Settings screen). |

---

## Technical notes & limitations

- **Latency**: WebRTC over a local WLAN typically achieves 40–120 ms
  one-way — good enough for fluid conversation.
- **Echo cancellation** is performed by the WebRTC engine (AEC3) on both
  phones. Helmet intercoms with poor mic/speaker isolation may still need
  push-to-talk.
- **Security**: the link is DTLS-SRTP encrypted (standard WebRTC). An
  optional 4-digit-style passcode prevents other people on the hotspot from
  connecting.
- **Both phones on any shared Wi-Fi** also works (e.g. a travel router) —
  the hotspot is just the most convenient offline setup.
- **One-to-one only**: the host serves exactly one client at a time
  (newcomers get `busy`).
- iOS **force-quit** terminates the app (OS behavior); everything else
  (screen lock, backgrounding, phone calls) is handled automatically.

## Verifying changes locally

```bash
flutter analyze      # static analysis (must be clean)
flutter test         # protocol, SDP, signaling, engine E2E, widget tests
```
