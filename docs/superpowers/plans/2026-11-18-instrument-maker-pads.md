# The instrument maker (TGI pads) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** TuneGod Companion gains **Make instrument…**: it loads an Audio Unit instrument, samples sixteen pads of it at several
velocities and writes a `.tgi` that TuneGod plays on the phone.

**Architecture:** A new package target, `TuneGodSamplerKit`, holds everything that is not a view: the plugin host (an `AUAudioUnit`
pulled by hand, never by an engine), the capture loop and trimming (pure, over a `NoteRendering` protocol so tests use a fake
plugin), the kit sampler, and the builder that turns captured hits into a `TGIInstrument` through `TuneGodCore`'s own `writeTGI`.
The window's views and model live in `App/Sources/Maker`. A command-line tool, `tgsample`, runs the same code without the window.

**Tech Stack:** Swift 6.4 in Swift 5 mode, SwiftUI and AppKit, AudioToolbox (`AUAudioUnit`), AVFoundation (Apple Lossless, playback),
CoreMIDI, CoreAudioKit (the plugin's own view), Swift Testing. `TuneGodCore` from `nickpaq/tunegod-native`.

**Spec:** `../tunegod-native/docs/superpowers/specs/2026-11-18-tgi-instruments-design.md` ("The Mac companion"), the format
`../tunegod-native/docs/tgi-file-format.md`, the handoff `../tunegod-native/docs/TGI-HANDOFF.md` ("Next: part 2").

## Global Constraints

- Mac only. Audio Units only: no VST3, no hosting inside a DAW, no recording a DAW's output.
- The TuneGod Link code (`Sources/TuneGodLinkKit`, `Driver/`, `Sources/tglink`) is not touched.
- `TuneGodCore` is used from `../tunegod-native/ios/TuneGodCore`; the environment variable `TUNEGOD_CORE` names another checkout.
- Pads only (kind `pads`, exactly 16, row by row from the top left). Keys are part 3.
- Velocity layers: default 4, up to 8; spaced evenly; each played at the **top** of its range (`velocity == top`, the last 127).
- Alternates per layer: default 1, up to 4. The closed hat (and the pedal hat) cut the open hat by default.
- Audio: exactly as the plugin produced it, nothing normalised; 48 kHz, 24-bit Apple Lossless in CAF; a hit whose two channels are
  identical is stored mono. Entry names `pNN-lL-aA.caf`.
- No project of its own: an instrument that needs changing is sampled again.
- This repository's rules: native Swift, no third-party names or branding in code or copy, commits end with the Co-Authored-By and
  Claude-Session lines.

## The builder's numbers (the spec leaves them open)

| What | Value |
| --- | --- |
| Render block | 512 frames |
| Sound threshold (first sound, and silence) | 1e-4 of full scale (−80 dB) |
| A hit has ended when | every sample has stayed under the threshold for 0.3 s |
| Longest hit | 12 s (10 s until 2026-11-18: long cymbals at full velocity ran past it), then a 20 ms fade (the hit is reported as cut short) |
| Kept before the first sound | 24 frames (0.5 ms) |
| Kept after the last sound | 10 ms |
| The key is held | until the hit has ended (a drum plugin that stops at note-off still plays its whole hit) |
| Before each hit | render until silent for 0.1 s, at most 5 s |
| Plugins load | in this process (a version 3 Audio Unit loads however it asks to) |
| MIDI channel | 1, with a picker (multi-channel plugins keep drums on 10) |

## Review Focus

1. **A pad whose note makes no sound in the plugin**: the pad is left empty and named in a warning; the file is never damaged.
2. **A sound that never ends** (a looped sample, a noise floor above the threshold): it is cut at the longest hit with a fade and
   named in a warning; sampling never hangs.
3. **The plugin plays louder than full scale**: the hit is stored (clipped by the 24-bit file) and counted in a warning that says
   to turn the plugin down and sample again.
4. **Cancel while sampling**: the held note is released, nothing is written, the window returns to the setup.
5. **The last hit's tail under the next hit** (long cymbals, reverbs): each hit waits for silence first.

---

### Task 1: The package target and the sampling arithmetic

**Files:** Modify `Package.swift`. Create `Sources/TuneGodSamplerKit/SampleMath.swift`, `Tests/TuneGodSamplerKitTests/SampleMathTests.swift`.

**Produces:**
- `Package.swift`: dependency `TuneGodCore` at `TUNEGOD_CORE` or `../tunegod-native/ios/TuneGodCore`; targets `TuneGodSamplerKit`
  (re-exports `TuneGodCore`), `TuneGodSamplerKitTests`, executable `tgsample`.
- `struct CaptureSettings` (`sampleRate`, `blockFrames`, `threshold`, `silenceSeconds`, `maxSeconds`, `leadInFrames`, `tailSeconds`,
  `fadeSeconds`, `settleSeconds`, `settleMaxSeconds`; the defaults above).
- `struct CapturedHit { left: [Float]; right: [Float]?; peak: Float; cutShort: Bool }` with `frames` and `channels`.
- `func layerVelocities(_ count: Int) -> [Int]`: 4 → `[32, 64, 95, 127]`, 1 → `[127]`, clamped to 1…8.
- `func trimmedHit(left: [Float], right: [Float], cutShort: Bool, settings: CaptureSettings) -> CapturedHit?`: nil when nothing
  reaches the threshold.

- [ ] Tests: `layerVelocities` for 1, 2, 4, 8 and out of range; a hit with 1000 silent frames in front starts 24 frames before its
  first sound; trailing silence is cut to 10 ms; identical channels come back mono, different ones stereo; all-silent is nil; a
  cut-short hit ends at zero after its fade; `peak` is the largest magnitude of either channel.
- [ ] Implement, run `scripts/check.sh`, commit.

### Task 2: Capturing one hit, and a whole kit

**Files:** Create `NoteRendering.swift`, `SampleCapture.swift`, `KitSetup.swift`, `KitSampler.swift` in the kit;
`Tests/TuneGodSamplerKitTests/FakePlugin.swift`, `CaptureTests.swift`, `KitSamplerTests.swift`.

**Produces:**
- `protocol NoteRendering: AnyObject { var sampleRate: Double { get }; func noteOn(_ note: Int, velocity: Int, channel: Int);
  func noteOff(_ note: Int, channel: Int); func render(frames: Int, left: inout [Float], right: inout [Float]) throws }` (appends).
- `struct SamplingCancelled: Error`.
- `func captureHit(_ plugin: NoteRendering, note: Int, velocity: Int, channel: Int, settings: CaptureSettings, realTime: Bool,
  cancelled: () -> Bool) throws -> CapturedHit?`: settles, plays, holds, releases, trims. Always sends the note-off.
- `struct PadSetup { note: Int; label: String; type: String?; cuts: [Int] }`;
  `struct KitSetup { pads: [PadSetup?]; layers: Int; alternates: Int; channel: Int }` with `sampleCount`,
  `static func standardDrums() -> KitSetup` (bottom row kick 36, snare 38, closed hat 42, open hat 46, as TuneGod's own kit).
- `struct SampledKit { hits: [[[CapturedHit]]?]; warnings: [String] }` (pad → layer → alternates; a layer with no sound is empty).
- `func sampleKit(_ plugin: NoteRendering, setup: KitSetup, settings: CaptureSettings, realTime: Bool,
  progress: (Int, Int, String) -> Void, cancelled: () -> Bool) throws -> SampledKit`.

- [ ] Tests with `FakePlugin` (a decaying tone whose level follows velocity, a start delay, optional endless notes and silent
  notes): the captured hit's peak rises with velocity; the delay is trimmed; an endless note is cut at `maxSeconds` and flagged;
  cancel throws `SamplingCancelled` and leaves no note held; a second hit does not begin with the first one's tail; a kit records
  pads × layers × alternates in order and reports progress to the total; a silent pad is nil with a warning naming its label.
- [ ] Implement, check, commit.

### Task 3: From captured hits to a `.tgi`

**Files:** Create `AudioCoding.swift`, `InstrumentBuilder.swift`; tests `InstrumentBuilderTests.swift`.

**Produces:**
- `func encodeAppleLossless(_ hit: CapturedHit, sampleRate: Double) throws -> Data` and
  `func decodeAudio(_ data: Data) throws -> (left: [Float], right: [Float]?, sampleRate: Double)`.
- `func buildInstrument(_ kit: SampledKit, setup: KitSetup, name: String, madeWith: String?, id: String, created: String,
  sampleRate: Double) throws -> (instrument: TGIInstrument, audio: [String: Data], warnings: [String])`: drops empty layers and
  gives the hardest remaining one `top` 127, keeps only cuts that point at pads that exist, throws when no pad made a sound.
- `func instrumentFileName(_ name: String) -> String` (a name safe for a file, `.tgi` added; empty becomes "Instrument").

- [ ] Tests: an encoded hit decodes to the same samples within one 24-bit step, mono stays mono; a built kit passes `validateTGI`,
  survives `writeTGI` → `readTGI`, has 16 pads, `velocity == top` per layer and entry names `p12-l0-a0.caf`; a pad whose softest
  layer was silent keeps its other layers; a hit over full scale is counted in a warning; a cut pointing at an empty pad is dropped.
- [ ] Implement, check, commit.

### Task 4: Hosting the plugin

**Files:** Create `PluginHost.swift`; `Sources/tgsample/main.swift`; tests `PluginHostTests.swift`.

**Produces:**
- `struct PluginInfo: Identifiable, Hashable { name; maker; description: AudioComponentDescription }`,
  `func installedInstruments() -> [PluginInfo]` (music devices, sorted by maker then name).
- `final class PluginHost: NoteRendering`: `static func load(_ info: PluginInfo, sampleRate: Double) async throws -> PluginHost`,
  `let unit: AUAudioUnit`, `var offline: Bool` (tells the plugin it is rendered faster than real time),
  `func liveRender(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) -> Bool` (for the speaker;
  false while a sample is being taken), `func allNotesOff()`. One lock keeps the speaker and the sampler from pulling at once.
- `tgsample list` and `tgsample make "<plugin>" <out.tgi> [--channel n] [--layers n] [--alternates n] [--realtime] [--name s]`.

- [ ] Test (runs on a Mac): the system's own General MIDI instrument loads, a note on channel 10 makes sound, velocity 127 is
  louder than 32, and it is silent again after the note.
- [ ] Implement; `swift run tgsample make` against that instrument writes a file `readTGI` accepts. Commit.

### Task 5: Hearing it: the plugin live, the result, and MIDI in

**Files:** Create `LiveOutput.swift`, `InstrumentPlayer.swift`, `MIDIInput.swift`; tests `InstrumentPlayerTests.swift`.

**Produces:**
- `final class LiveOutput`: an output engine with one source that pulls `PluginHost.liveRender`; `start()`, `stop()`.
- `final class InstrumentPlayer`: `init(instrument: TGIInstrument, audio: [String: Data])`, `func play(pad: Int, velocity: Int)`,
  `func stopAll()`. The layer, the alternate and the gain come from `tgiLayerIndex`, `tgiNextHit`, `tgiLayerGain`; a pad's `cuts`
  stop those pads. `static func choice(pad: TGIPad, velocity: Int, last: inout [Int: Int]) -> (layer: Int, hit: Int, gain: Double)`
  is the tested part.
- `final class MIDIInput`: `init(onNote: @escaping (_ note: Int, _ velocity: Int, _ on: Bool) -> Void)`; every source, hot-plugged.

- [ ] Tests: `choice` picks the layer by `top`, rotates alternates per layer, and gives gain 1 at the layer's own velocity.
- [ ] Implement, check, commit.

### Task 6: The window

**Files:** Create `App/Sources/Maker/MakerModel.swift`, `MakerWindow.swift`, `PadGridView.swift`, `PluginWindow.swift`.
Modify `App/Sources/TuneGodCompanionApp.swift` (the menu's **Make instrument…**, a `Window` scene), `project.yml` (the kit product,
the `.tgi` type).

One window, top to bottom: the plugin (picker, channel, Show plugin window) → the 4 × 4 grid (a pad shows its label, its Type's
colour and its note; a click plays it; the keys 1234 / QWER / ASDF / ZXCV play the rows) beside the selected pad's settings (note,
Learn from a MIDI keyboard, label, Type, Cuts, Clear) → Velocity layers, Alternates, Real time, with the count of samples and the
estimates → **Sample** (progress, Cancel) → the result: Listen to the plugin or the instrument, a velocity slider, warnings, the
name, **Save…** and **AirDrop**.

- [ ] Build the app (`xcodegen generate`, the `TuneGodCompanion` scheme), launch it, open the window, take a screenshot. Commit.

### Task 7: Records

- [ ] `CLAUDE.md`, `README.md`, `docs/HANDOFF.md` here say the repository holds both Link and the instrument maker, what was run and
  what was not. `../tunegod-native/docs/TGI-HANDOFF.md`: part 1 tested by the user, part 2's state.
