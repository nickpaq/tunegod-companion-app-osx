# TuneGod companion for macOS

Connect the iPhone running TuneGod with a USB cable and it shows up in your Mac audio apps as **TuneGod iPhone**:

- **Outputs** play on the iPhone's speaker (monitor Ableton on the phone).
- **Inputs** carry the iPhone's mic, and optionally TuneGod's own output.
- A **TuneGod** MIDI port sends TuneGod's pads, sequencer and beat repeats to the Mac, and takes MIDI back.

How it works: `docs/link-protocol.md`.

It also makes **TuneGod instruments**: **Make instrument…** in its menu loads an Audio Unit instrument on the Mac, samples sixteen pads
of it at several velocities and writes a `.tgi` file to AirDrop to the phone, where it is added as a TGI pads track.

## Status
| Part | State |
|---|---|
| Link protocol, clock, MIDI conversion (`TuneGodLinkKit`) | Done, tested |
| Cable connection, Mac session, virtual "TuneGod" MIDI ports | Done; tested against the phone simulator, not yet against a phone |
| Menu-bar app (`TuneGod Companion`) | Builds; shows link state, latency, dropouts, MIDI, a test tone switch |
| Audio device for Ableton (the driver, `Driver/`) | Installed on the Mac; audio flows both ways against the phone simulator. Install with `scripts/install-driver.sh` (asks for the Mac password) |
| TuneGod's "Mac Link" mode on the iPhone | Not started (in `tunegod-native`) |
| Make instrument (`TuneGodSamplerKit`, `App/Sources/Maker`, `tgsample`) | Samples the system's own instrument into a `.tgi`, tested; not yet tried with another maker's drum plugin, and not yet listened to |

## Working on it (on the Mac)
- `scripts/check.sh`: builds the package and runs the tests (`--no-test` to only build).
- `swift run tglink devices`: the iPhones and iPads on the cable.
- `swift run tglink phone-sim --midi` in one terminal and `swift run tglink connect --direct 127.0.0.1:47820 --tone` in another:
  the whole link on one Mac, with its numbers once a second. `swift run tglink connect --tone` uses the cable instead.
- `swift run tglink device-test`: plays a tone into "TuneGod iPhone" and measures its input (driver installed, a helper running).
- The app: `xcodegen generate`, then build the `TuneGodCompanion` scheme. Launched with `--simulator` it connects to the phone
  simulator instead of the cable.
- `swift run tgsample list`: the Audio Unit instruments on this Mac. `swift run tgsample make "<part of a name>" out.tgi`: samples the
  usual drum notes of one (`--channel 10` for the system's own). Both need TuneGodCore beside this repository (see `CLAUDE.md`).
