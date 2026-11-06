# TuneGod companion (macOS) notes for Claude sessions

This repository is the Mac side of TuneGod Link: a Core Audio driver that makes the iPhone running TuneGod a Mac audio device ("TuneGod
iPhone": outputs play on the phone's speaker, inputs carry its mic), plus a menu-bar helper that carries audio and MIDI over the USB cable.
The iOS app is `nickpaq/tunegod-native`.

- **The protocol is `docs/link-protocol.md`.** Both repositories implement it; a change bumps its version and lands on both sides.
- Native Swift (and C/C++ only where the Core Audio plug-in interface needs it). No web code, no third-party names or branding anywhere,
  no comments citing outside sources.
- **Git:** commits end with the Co-Authored-By and Claude-Session lines; no model names in commits, PRs or code.
- Building and signing happen on the user's Mac (Desktop Commander, device `Mac.lan`, `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`,
  team `3AK4NZ9W4P`). Say plainly what was and wasn't built or run.
