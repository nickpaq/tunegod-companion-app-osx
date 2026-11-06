# TuneGod Link protocol (version 1)

How the Mac companion and the TuneGod iOS app exchange audio and MIDI over the USB cable. Both repositories implement this file; a change
here bumps `PROTOCOL_VERSION` and lands in both.

## Goals
- The iPhone appears in any Mac audio app (Ableton included) as an audio device: **outputs** play on the phone's speaker, **inputs** carry
  the phone's mic (and optionally TuneGod's own output).
- One cable, low latency (target under ~12 ms each way at 48 kHz), no drift, no resampling.
- MIDI both ways on the same connection, timed against the same clock as the audio.

## Parts
```
 Ableton ──Core Audio──▶ TuneGod Link driver (HAL plug-in, inside coreaudiod)
                               │  loopback TCP 47821 (audio + the phone's clock)
                               ▼
                         TuneGod Link helper (menu-bar app + its daemon)
                               │  virtual MIDI ports "TuneGod" (in/out)
                               │  TCP over the USB cable (the Mac's device multiplexer socket)
                               ▼
                         TuneGod iOS app, "Mac Link" mode (listens on loopback port 47820)
```
- **Driver** (`AudioServerPlugIn`): publishes the device "TuneGod iPhone". It never touches USB or MIDI; it exchanges audio and the
  clock with the helper over a loopback TCP connection (see "Driver").
- **Helper**: finds the phone on the cable, holds the one TCP connection, relays audio and the clock between the phone and the driver,
  owns the virtual MIDI ports, measures latency and shows status in the menu bar.
- **iOS app**: runs the audio session, plays what arrives, sends the mic, and is the **clock master**.

## Transport
- One TCP connection per phone. The phone listens on `127.0.0.1:47820` while Mac Link is on; the Mac reaches it through the cable tunnel.
  Listening on loopback only keeps the port off Wi-Fi networks.
- `TCP_NODELAY` on both ends. One message per write where possible.
- All integers little-endian. Audio samples `Float32`, interleaved.

### Message frame
| bytes | field |
|---|---|
| 1 | `type` |
| 1 | `flags` (0 for now) |
| 2 | reserved, 0 |
| 4 | `length`: payload bytes after this 8-byte header |

A receiver skips any `type` it does not know (forward compatibility). A `length` over 1 MiB closes the connection.

## Messages
| type | name | direction | payload |
|---|---|---|---|
| 0x01 | `HELLO` | both | magic `TGLK` (4), `protocolVersion` u16, `role` u8 (0 phone, 1 mac), reserved u8, `appVersion` (u8 length + UTF-8) |
| 0x02 | `CONFIG` | phone → mac | `sampleRate` u32, `framesPerPacket` u16, `downChannels` u8, `upChannels` u8, `upLayout` u8, `ioBufferFrames` u16, `outputLatencyFrames` u32, `inputLatencyFrames` u32 |
| 0x03 | `START` | phone → mac | `sampleTime` u64: the phone timeline's frame the stream begins at |
| 0x04 | `STOP` | either | none |
| 0x10 | `AUDIO_UP` | phone → mac | `sampleTime` u64, `frames` u16, reserved u16, samples (`frames × upChannels × 4` bytes) |
| 0x11 | `AUDIO_DOWN` | mac → phone | `sampleTime` u64 (phone timeline frame the first sample plays at), `frames` u16, reserved u16, samples (`frames × downChannels × 4`) |
| 0x20 | `MIDI` | both | `sampleTime` u64 (phone timeline; 0 = as soon as possible), `count` u16, then MIDI 1.0 bytes (complete messages only; SysEx in one message) |
| 0x30 | `PING` | either | `id` u32, `senderTime` u64 (sender's own clock, nanoseconds) |
| 0x31 | `PONG` | either | the `PING` payload echoed |
| 0x40 | `STATUS` | either | `underruns` u32, `overruns` u32, `bufferedFrames` u32 (receiver side), `latePackets` u32 |

### Session order
1. Mac connects, both send `HELLO`. Different `protocolVersion` → each side shows "Update TuneGod / the companion" and closes.
2. Phone sends `CONFIG` once its audio session is running (the real sample rate and IO buffer the system granted, not the preferred ones).
   A new `CONFIG` (route change, sample-rate change, mic turned on or off) is followed by `STOP` and a new `START`.
3. Phone sends `START`, then one `AUDIO_UP` per audio IO cycle, always: with `upChannels = 0` it still goes out as a clock tick.
4. Mac sends `AUDIO_DOWN` ahead of time (see Clock). `PING` about once a second from each side; `STATUS` about once a second.

### Channel layouts (`upLayout`)
| value | up channels |
|---|---|
| 0 | none (clock ticks only) |
| 1 | 1: mic |
| 2 | 2: mic, mic (same signal; a mono mic on a stereo input pair) |
| 3 | 4: mic, mic, TuneGod output L, TuneGod output R |

`downChannels` is 2 (stereo to the speaker; the phone sums to mono where the speaker is mono).

## Clock (no drift, no resampling)
- The phone's audio hardware is the only clock. `sampleTime` counts its frames from `START`.
- The helper turns `AUDIO_UP` arrival times into a smooth mapping *phone sampleTime ↔ Mac host time* with a delay-locked loop (bandwidth
  around 1 Hz, reset on `START`). The driver's zero timestamps (`GetZeroTimeStamp`) come from that mapping, so the device runs at exactly
  the phone's rate and Ableton follows it. The driver lists only the phone's `sampleRate`; a different rate needs a new `CONFIG`.
- Down: the helper sends each block for `sampleTime = phoneNow + downLead`, where `downLead` starts at 2 packets and adapts to the phone's
  `STATUS` (raise by one packet on underruns, lower slowly while `bufferedFrames` stays high). The phone keeps a jitter buffer keyed by
  `sampleTime`, plays silence and counts an underrun for a missing block, and drops blocks already late.
- Up: the driver's input ring is read `upLead` frames behind the newest frame (starts at 2 packets, same adaptation).
- The driver reports its latency and safety offset from `CONFIG` plus the current leads, so Ableton's recording compensation lines up.

## MIDI
- Phone → Mac: TuneGod stamps each note with the phone `sampleTime` it sounds at (sequencer steps and beat repeats are stamped ahead from
  the audio thread). The helper converts it to Mac host time through the clock mapping and sends it out of the virtual source "TuneGod" with
  that timestamp.
- Mac → phone: whatever is sent to the virtual destination "TuneGod" goes to the phone stamped the same way and plays through TuneGod's
  existing MIDI input handling.
- MIDI clock (24 per quarter) and start/stop ride these messages like any other MIDI.

## Driver (helper ↔ driver, Mac only)
The driver connects to the helper at `127.0.0.1:47821` (allowed by `AudioServerPlugIn_Network` in its Info.plist) and speaks the same
framing. Helper → driver: the phone's `CONFIG`, `START`/`STOP`, every mic `AUDIO_UP`, and after each phone packet
`CLOCK` (0x50: `sampleTime` u64, `hostTicks` u64, `rate` f64 bits): phone frame `sampleTime` falls at Mac host time `hostTicks`.
Driver → helper: `AUDIO_DOWN` blocks of what Mac apps played, stamped with phone frames.
- The device's sample time maps to host time through the latest `CLOCK`, so the device runs at the phone's rate. Device frame + `offset`
  = phone frame; `offset` is set when the clock locks so the device's timeline stays continuous, and the device free-runs at its last
  rate (silent) when the phone goes.
- Output: what an app writes for device frame S goes to phone frame S + offset; the helper sends it to the phone `lead` frames ahead.
  The output safety offset (256 frames) keeps apps writing far enough ahead of the helper's lead.
- Input: device frame S reads the mic at phone frame S + offset; the input safety offset (128) covers one phone packet and the hop.
- The IO callbacks touch only a seqlock'd clock and two rings with atomic positions; the driver's own threads do the socket work.

## Latency budget (48 kHz, 64-frame packets)
| stage | ms |
|---|---|
| Ableton's buffer (64–128 frames) | 1.3–2.7 |
| Helper and driver rings (`upLead`/`downLead`, 2 packets) | 2.7 |
| Cable and TCP | under 1 |
| Phone jitter buffer | inside `downLead` |
| Phone audio IO buffer (what iOS grants, often 128–256 frames on the speaker) | 2.7–5.3 |
| **Total each way** | **about 7–12** |

Measured `PING` round trips and the leads show in the helper's menu so the real numbers are visible.

## Phone side notes
- Audio session: `.playAndRecord`, `.defaultToSpeaker`, preferred 48 kHz and 64 frames (it reports what it gets in `CONFIG`). Background audio
  keeps Mac Link running when the app is left or the screen locks.
- Mic: the raw mic by default (no voice processing: echo cancellation would add latency). The speaker playing into the mic can feed back
  into an armed, monitored track; the app offers "mic off while the speaker plays" and headphones avoid it.
- Mac Link and TuneGod's own engine share the session: what plays on the speaker is the Mac's audio plus TuneGod's own sound
  (each with its own level).

## Open items to verify early
1. The cable tunnel reaches a socket listening on the phone's loopback address (expected; check on the device first).
2. ~~The plug-in can reach the helper~~: it connects over loopback TCP, allowed by `AudioServerPlugIn_Network`.
3. The smallest IO buffer iOS grants with the speaker and mic both running.
