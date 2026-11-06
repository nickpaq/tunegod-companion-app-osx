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
