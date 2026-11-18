This repository holds two things: **TuneGod Link** (below) and **the instrument maker** (the second half of this file, 2026-11-18).
They share the menu-bar app and nothing else.

# TuneGod Link: handoff (2026-11-06)

Goal (the user): plug the iPhone running TuneGod into the Mac by USB and
- pick **"TuneGod iPhone"** in Ableton as an **audio output** (it plays on the phone's speaker) and an **audio input** (the phone's mic),
- with **low latency**, over the **cable**,
- and send TuneGod's **MIDI** (pads, sequencer, beat repeat) into Ableton.

The wire format is `docs/link-protocol.md`; read it before changing either side.

## What exists (this repo)
| Part | Where | State |
|---|---|---|
| Protocol codec, clock loop, MIDI byte⇄UMP, audio ring | `Sources/TuneGodLinkKit/` (`LinkProtocol`, `ClockMapper`, `MIDIUMP`, `AudioRing`) | Done, unit-tested. Builds for iOS too, so the phone can reuse it |
| Cable connection (the Mac's device service), sockets | `USBMux.swift`, `LinkSocket.swift` | Lists devices correctly; **never yet connected to a phone** (none was on the cable) |
| Mac session, clocked by the phone | `LinkMacSession.swift` | Tested against the simulator |
| Helper engine: watches the cable, bridges MIDI and the driver | `LinkHelper.swift`, `LinkDriverBridge.swift`, `LinkMIDIPorts.swift` | Tested against the simulator |
| Phone simulator | `LinkPhoneSimulator.swift`, `tglink phone-sim` | Used by the tests and by hand |
| Command-line tool | `Sources/tglink/` | `devices`, `connect`, `phone-sim`, `device-test` |
| Menu-bar app "TuneGod Companion" | `App/Sources/`, target in `project.yml` | Builds; never looked at (no screenshots); not installed in Applications, no launch at login |
| Driver: the "TuneGod iPhone" device | `Driver/TuneGodLinkDriver.c`, target `TuneGodLinkDriver` | **Installed on the user's Mac**; audio passes both ways against the simulator |

### How the pieces talk
```
Ableton ⇄ driver (in coreaudiod) ⇄ loopback TCP 47821 ⇄ helper ⇄ cable tunnel to the phone's port 47820 ⇄ TuneGod (Mac Link mode)
                                                        helper ⇄ virtual MIDI ports "TuneGod"
```
- The **phone is the only clock**. Each phone `AUDIO_UP` is a tick; the helper answers it with `AUDIO_DOWN` `lead` frames ahead and
  passes a `CLOCK` point to the driver, whose device time follows it (no resampling, no drift).
- Helper ⇄ driver uses the same framing plus `CLOCK` (0x50). The driver's sandbox allows the loopback socket through
  `AudioServerPlugIn_Network` in its Info.plist (checked in the SDK header).
- Driver numbers (frames at 48 kHz): output safety offset 256, input safety offset 128, reported latency 192 out / 128 in. These are
  first guesses, to be set from measurements on the phone.

## Verified (on the user's Mac, macOS 27.2, Xcode with Swift 6.4)
- `scripts/check.sh`: 14 tests pass. The loopback test is timing-sensitive: it failed once while the Mac was loaded (load average ~9
  from a simulator) and passed 3/3 alone.
- Simulator run, 12 s: round trip 0.1 ms, the measured phone rate within 0.1 Hz of the simulator's real one, 1 dropout (start-up).
- Driver installed, listed by the system as "TuneGod iPhone" (2 in, 2 out, 48 kHz, virtual). `tglink device-test` with the simulator
  and `tglink connect --direct`: the simulator's 330 Hz "mic" read on the device's input at the right level (0.141 RMS), no timeline gaps;
  the device's 440 Hz output arrived at the simulator at 0.141 RMS.
- Bugs found and fixed on the way: a lead change made a gap, the gap raised the lead (climbed every second); the rate estimate was too
  noisy (now measured over 10 s of smoothed points); the simulator burst packets after stalls (now it carries on like a phone); audio
  threads now use real-time scheduling.

## Not done / next
1. **TuneGod's "Mac Link" mode** (in `nickpaq/tunegod-native`): listen on `127.0.0.1:47820`; send `HELLO`, `CONFIG` (the granted rate
   and IO buffer), `START`, then one `AUDIO_UP` per IO cycle (mic, or no samples as a clock tick); play `AUDIO_DOWN` from a jitter
   buffer keyed by frame; answer `PING`; send `STATUS` once a second; background audio. Session: `.playAndRecord`, `.defaultToSpeaker`,
   48 kHz, smallest buffer. The protocol code in `TuneGodLinkKit` builds for iOS; whether to depend on this package or copy the
   protocol files is open (the iOS repo's rules forbid third-party imports; this is the user's own repo).
2. **MIDI out from TuneGod**: stamp every note (sequencer steps and each beat-repeat hit) with the phone frame it sounds at and send it
   as `MIDI` on the link; the helper puts it out of the "TuneGod" port at the matching Mac time. Also per-track MIDI channel and "mute
   internal sound" in the sound settings menu.
3. **First test with the phone on the cable**: `tglink devices` (the phone must appear), then `tglink connect --tone` (tone on the
   phone's speaker). Open item: that the cable tunnel reaches a socket on the phone's loopback address.
4. **Latency**: the user said to leave measuring for later. Then set the driver's safety offsets and latencies from real numbers.
5. **Companion app**: install into Applications, launch at login (ask the user), show the driver and phone state. Later a signed
   (Developer ID) installer that also installs the driver.
6. Feedback when the speaker plays into the mic: an option to mute the mic while the speaker plays (see the protocol's phone notes).

## Working on it
- On the Mac (Desktop Commander, device `Mac.lan`): repo at `~/Developer/tunegod-companion-app-osx`; pull, then `./scripts/check.sh`.
- Driver install: `./scripts/install-driver.sh` builds it and shows macOS's administrator dialog (the user types the password on the
  Mac; Desktop Commander refuses `sudo`). It restarts the Mac's audio service, which stops all audio for about a second.
  `--uninstall` removes it.
- Whole chain on one Mac: `tglink phone-sim` | `tglink connect --direct 127.0.0.1:47820` | `tglink device-test`. Only one helper can
  run at a time (the app or `tglink connect`), because the driver port is single.

---

# The instrument maker: handoff (2026-11-18)

The repository's second part. **Make instrument…** in the companion's menu opens a window that loads an Audio Unit instrument,
samples sixteen pads of it at several velocities and writes a TuneGod instrument (`.tgi`) for the phone. It is part 2 of TuneGod
instruments; the whole feature's handoff, the design and the file format are in `nickpaq/tunegod-native`
(`docs/TGI-HANDOFF.md`, `docs/superpowers/specs/2026-11-18-tgi-instruments-design.md`, `docs/tgi-file-format.md`). The plan this was
built from, with its numbers (threshold, lengths, trimming), is `docs/superpowers/plans/2026-11-18-instrument-maker-pads.md`.

## What exists
| Part | Where | State |
|---|---|---|
| Trimming, layer velocities | `Sources/TuneGodSamplerKit/SampleMath.swift` | Unit-tested |
| Capturing one hit, a whole kit | `SampleCapture.swift`, `KitSampler.swift`, `KitSetup.swift` | Unit-tested against a made-up plugin |
| Hits to a `.tgi` (24-bit Apple Lossless in CAF) | `AudioCoding.swift`, `InstrumentBuilder.swift` | Unit-tested; the file is read back by TuneGodCore's `readTGI` |
| Hosting the plugin | `PluginHost.swift` | Tested against the system's General MIDI instrument only |
| The plugin on the speakers, the result's playback, MIDI in | `LiveOutput.swift`, `InstrumentPlayer.swift`, `MIDIInput.swift` | The player's levels and cuts are tested by rendering it by hand; **nothing has been listened to** |
| The kit's name | `PresetName.swift` (`PluginHost.presetName`) | Unit-tested; read correctly from the user's drum plugin's first kit |
| A plugin's pad setup, kept between runs | `PadSetupStore.swift` | Unit-tested; the user's drum plugin's setup is saved on the Mac |
| Command-line tool | `Sources/tgsample/` | `list`, `setup "<plugin>" <map.txt>`, `make "<plugin>" <out.tgi>` |
| The window | `App/Sources/Maker/` | Builds and opens with the user's drum plugin; its title bar showed the first kit's name (one screenshot, 2026-11-18). **No button was clicked by a person**, and the name following a kit chosen by hand has not been seen |

## Browse, hear, one button (2026-11-18, the user's request)
The user asked to browse the plugin's presets, hear a kit and make its `.tgi` with one button, "exactly how it worked for the test"
instrument, the file carrying the preset's name.
- **The list of kits is the plugin's own window.** The drum plugin gives a host no presets (`factoryPresets` is empty, no user
  presets) and its preset files are encrypted, so the companion cannot show a list of its own. Kits are browsed and heard there;
  the pads in our window play whichever is chosen.
- **The kit's name** comes from the state the plugin hands a host for saving (`fullState`): `presetName(inState:)` looks for an
  entry whose name ends in `CurrentPresetName` (then `PresetName`, `ProgramName`, `PatchName`), as zero-ended text or
  `key="value"`. The window asks about once a second (`MakerModel.watchKit`), names the instrument after it until the user types
  another name, and goes back to following when the kit changes. A plugin that does not name its kit leaves the plugin's name.
- **One button:** Make instrument samples the kit and writes `<name>.tgi` on the Desktop (`freeInstrumentFile`: a taken name gets
  " 2", nothing is replaced). The result row has Show in Finder, Save as… and AirDrop.
- **The button is also in the plugin's window** (`PluginWindowBar`, a title bar accessory): the drum plugin's window is large and
  covers the maker's, so the kit's name, Make instrument, the progress and AirDrop sit in its title bar. The maker's window is
  only needed to change the pads, the layers or the name.
- **Remembered:** the plugin last used (it loads when the window opens) and each plugin's pad setup, in
  `~/Library/Application Support/TuneGod Companion/Pad setups/<plugin id>.json`, written whenever a pad, the layers, the
  alternates or the channel change. The setup the test instrument was made with (`~/Developer/tgi-test/ad2-map.txt`: crashes,
  rides, four toms, three hats, kick, snare, rimshot, sidestick; the closed and pedal hats cut the open one; 4 layers, 1 alternate)
  is saved there for the user's drum plugin, so nothing has to be set. **Changed the same day at the user's request:** pads 7 and
  8 (toms 3 and 4) are now the plugin's first two Flexi slots, labelled Perc (note 47) and Flexi (note 96); the notes were found
  by soloing each slot and probing which notes still sound (the third slot was empty in the first kit, its note is not known).
  The file with the toms is kept as `ad2-map-toms.txt`. No instrument has been made with the new setup yet.
- **The test instrument was made by another tool** (`tgsample` on `claude/hopeful-johnson-xtf655`, commit `1177fbd`: an audio
  engine rendering offline, the key let go after 0.25 s, 12 s at most). This branch does not merge that tool; it samples the same
  setup with this kit's code. Compared hit by hit on the Mac: the same 64 hits, lengths within the plugin's own variation plus this
  kit's 10 ms tail (185.5 s against 185.7 s in all), the same levels, 25.6 MB both. The longest hit was raised from 10 s to 12 s to
  match (the rides at full velocity run past 9 s).

## How it works
- `PluginHost` loads the Audio Unit **in this process** and pulls its render block by hand, 512 frames at a time. No audio engine
  owns the plugin, so one unit serves the sampler (as fast as it renders, with the plugin told it is offline, or paced to real time)
  and the speakers (`LiveOutput`), never both at once (`sampling`). Only the plugin's **first output** is recorded.
- A hit (`captureHit`): wait for silence, note-on at the layer's velocity, hold the key until the sound has stayed under −80 dB for
  0.3 s (or 10 s, where it is faded and reported), note-off, trim to 0.5 ms before the first sound and 10 ms after the last. Nothing
  is normalised. A note with no sound within 1 s is no hit.
- A kit (`sampleKit`): every pad × every layer (evenly spaced velocities, each the top of its range: 4 layers are 32, 64, 95, 127)
  × every alternate. `buildInstrument` turns it into TuneGodCore's `TGIInstrument`; `writeTGI` is TuneGodCore's.
- `TuneGodCore` comes from `../tunegod-native/ios/TuneGodCore`; `TUNEGOD_CORE=<path>` names another checkout (`Package.swift`).
- The app has the hardened runtime's `disable-library-validation` entitlement (`project.yml`): without it macOS refuses to load
  other makers' plugins into the app.

## Verified (on the user's Mac, macOS 27.2)
- `swift test`: all 67 tests pass (53 `TuneGodSamplerKitTests`, among them four that run the system's own instrument for real, and Link's 14).
- `swift run tgsample make "DLSMusicDevice" out.tgi --channel 10`: 16 pads, 64 hits, 20 MB, in 2.4 s; with `--realtime` 16 hits in 54 s.
  Every pad's four layers rise in level; `readTGI` accepts the file.
- The app builds (`xcodegen generate`, scheme `TuneGodCompanion`, Debug). Launched with
  `--make-instrument --plugin DLSMusicDevice --channel 10 --sample` it opened the window and the plugin's own window, sampled, and
  showed the result with Save and AirDrop (screenshots taken, not kept).

## Not verified / next
1. **A drum plugin from another maker: sampled, to be accepted by the user.** The user's drum plugin is installed now. `tgsample
   make` loads it in this process, renders it faster than real time (64 hits in 4.7 s) and matches the test instrument (above).
   Still unknown: a kit switched in the plugin's window and made straight away (the plugin may still be loading its sounds; the
   tool waits 2 s after loading, the window does not wait), and plugins with several outputs.
2. **By ear and by hand:** clicking and key-playing the pads, a MIDI keyboard (playing, Learn), Cancel, Save…, AirDrop, the
   result's playback against the plugin.
3. **The file on the phone:** the test instrument made by `tgipack` works there (the user, 2026-11-18); one made here (Apple Lossless
   in CAF rather than WAV) has not been tried.
4. **Size.** Hits are long because the tail is kept down to −80 dB: the system instrument's kit came to 20 MB for 64 hits, about
   60 MB decoded. The window warns above 150 MB decoded (`PHONE_MEMORY_WARNING_BYTES`), a guess until the phone's cost is measured.
5. TGI keys (part 3): range, notes per octave, hold length; `captureHit` already holds and releases, `TGIZone` is in TuneGodCore.
6. Later, if wanted: remembering a plugin's pad setup between runs (the design keeps no project in version 1), a plugin's other
   outputs, loading plugins out of process.

## Working on it
- Tests: `TUNEGOD_CORE=<TuneGodCore with the TGI code> swift test --filter TuneGodSamplerKitTests`. The default path works once
  `~/Developer/tunegod-native` is on a commit that has `Sources/TuneGodCore/TGI`.
- The app: `TUNEGOD_CORE=… xcodegen generate`, then build `TuneGodCompanion`. `--make-instrument` opens the window at launch;
  debug builds also take `--plugin <part of a name>`, `--channel <n>` and `--sample` (press Make instrument once the plugin has
  loaded). **Put `--make-instrument` last:** a launch whose last argument is a bare word (`--plugin Name`) opens no window, because
  the system takes the word for a file to open. The plugin last used loads by itself, so `--make-instrument` alone is enough.
- **TuneGodCore must have `TGI_PAD_VOICES`** (the phone repository's branch `claude/serene-lamport-o2lucs`, 3.209.1): a pad of an
  instrument sounds at most twice at once on the phone, and the preview here (`InstrumentPlayer.play`) follows that number. On the
  Mac `TUNEGOD_CORE` is `~/Developer/tg-tgi-kits/ios/TuneGodCore`, a worktree of that branch.
- On the Mac the worktree is `~/Developer/tgc-kits`; `~/Developer/tgi-test/kits-test.sh`, `kits-make.sh` and `kits-app.sh` pull the
  branch and run the tests, a sampling of the drum plugin, and the app's build. An app that has a plugin loaded does not end on a
  plain `kill`; quit it from its menu (or `kill -9`).
