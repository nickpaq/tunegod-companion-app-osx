# TuneGod companion (macOS) notes for Claude sessions

This repository is the Mac side of TuneGod Link: a Core Audio driver that makes the iPhone running TuneGod a Mac audio device ("TuneGod
iPhone": outputs play on the phone's speaker, inputs carry its mic), plus a menu-bar helper that carries audio and MIDI over the USB cable.
The iOS app is `nickpaq/tunegod-native`.

- **Start with `docs/HANDOFF.md`** (state and next steps). **The protocol is `docs/link-protocol.md`.** Both repositories implement it; a change bumps its version and lands on both sides.
- Native Swift (and C/C++ only where the Core Audio plug-in interface needs it). No web code, no third-party names or branding anywhere,
  no comments citing outside sources.
- **Git:** commits end with the Co-Authored-By and Claude-Session lines; no model names in commits, PRs or code.
- Building and signing happen on the user's Mac (Desktop Commander, device `Mac.lan`, `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`,
  team `3AK4NZ9W4P`). Say plainly what was and wasn't built or run.

## The instrument maker (since 2026-11-18)

The repository's second part: **Make instrument…** in the menu samples an Audio Unit instrument into a TuneGod instrument (`.tgi`) for
the phone. Pads (a drum kit on 16 pads) or keys (a range of notes, each key mapped to the nearest sampled note), the same steps for both. Its code is `Sources/TuneGodSamplerKit` (hosting, capture, trimming, the file), `Sources/tgsample` (the same from the command
line) and `App/Sources/Maker` (the window). It does not touch the Link code, and Link does not touch it.

- The `.tgi` format and the rules for choosing a layer are TuneGodCore's, in `nickpaq/tunegod-native` (`docs/tgi-file-format.md`); this
  package uses that code from `../tunegod-native/ios/TuneGodCore` (`TUNEGOD_CORE=<path>` names another checkout). Change the format there,
  for both sides.
- What is built, what was run and what was not: the second half of `docs/HANDOFF.md`. The numbers (threshold, lengths, trimming):
  `docs/superpowers/plans/2026-11-18-instrument-maker-pads.md`.
- A plugin's presets are browsed in the plugin's own window; the maker reads only the chosen one's name from the plugin's state
  and never opens a plugin's own files. One button (Make instrument) samples and writes `<kit name>.tgi` on the Desktop.
- Plugins are named in the interface only as the Mac lists them; no plugin maker's name is written into code, copy or tests (the tests
  use the system's own instrument).
