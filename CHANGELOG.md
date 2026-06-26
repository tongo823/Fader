# Changelog

## 1.2
- Fixed: Fader could drop the volume of an app during a voice/video call (e.g. WhatsApp). It now leaves any app that's using the microphone completely untouched, so it can never affect call audio. Such apps reappear in the mixer the moment the call ends.

## 1.1
- Added a magnetic detent at 100% on each app's slider — it snaps to unity so it's easy to land on, with a tick mark and the percentage highlighting at exactly 100%.
- 100% is now perfectly transparent, and the boost above it has a little more headroom.
- Drag past the detent to deliberately push an app louder than normal.

## 1.0
- First public release.
- Per-app volume mixer in the menu bar — only apps that are actually playing audio show up.
- Each app gets a volume slider (0–150% with a clean boost), mute, and a live level meter.
- Browser and Electron audio (e.g. YouTube in Chrome) is grouped under one slider for the app.
- Master output slider.
- Per-app levels are remembered between launches.
- Adapts when you switch output devices (headphones, AirPlay, etc.).
- Launch at login.
- One-click updates from GitHub.
