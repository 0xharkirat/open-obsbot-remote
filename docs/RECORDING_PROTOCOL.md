# Recording and audio protocol

The contract between the bridge and the remote for the REC tab.

Written before either side is built, so the two can be implemented in parallel and meet in the middle.

## Why recording is host-side

The Tiny 2 Lite has no storage. Every recording method in the SDK is annotated `@category tail air`: `cameraSetVideoRecordR`, `cameraSetTakePhotosR`, `cameraSetRecordResolutionR`, `cameraSetRecordSplitSizeR`. That is a different model.

So the bridge records. On the Linux host that is also the better place: the disk and the hardware encoder are both there.

Audio turned out differently from the first draft of this document, and the correction is worth recording.

`cameraSetAudioCtrlStateU` is **not** a microphone control. Its `AudioCtrlCmdType` enum is a list of voice commands: `AudioCtrlHiTiny`, `AudioCtrlSleepTiny`, `AudioCtrlTrack`, `AudioCtrlZoomIn`. It configures what the camera does when spoken to. `cameraSetAudioAutoGainU` is the only method in the SDK that touches audio capture, and it adjusts gain rather than muting.

**There is no way to mute this camera's microphone through the SDK.** So the control cannot mean "turn the camera's audio on or off". It means what is actually achievable: what the recorder writes.

## Three modes, not a boolean

A boolean "with audio or not" could not express audio-only, and audio-only is the mode whose cost differs most: roughly 57 MB an hour at 128 kbps AAC against 3.7 GB an hour for video. That difference is the whole reason to offer it, so the preference is a mode rather than a flag.

| Mode | Writes | File |
| --- | --- | --- |
| `both` (default) | Video and audio | `.mp4` |
| `video` | Video only | `.mp4` |
| `audio` | Audio only | `.m4a` |

Three decisions inside that table are worth stating.

**Audio-only is not a `.mp4`.** An MP4 with no video track is legal and confusing: it opens in a video player as a black rectangle with sound. The extension is the only thing that tells a player, and a person scrolling a directory, that there is no picture in it. The mp4 muxer still writes the file; only the name changes.

**A missing microphone means different things in different modes.** In `both` it downgrades to a silent recording, because losing the whole take is worse than losing the sound. In `audio` it is a hard `audio_unavailable` failure, because nothing is left to capture and starting would write an empty file that looks like a successful take until someone plays it. The asymmetry is deliberate.

**Each mode pays only for what it uses.** `video` runs no ALSA input. `audio` opens no pipe, runs no frame pump, and starts no video encoder at all.

The capture itself has two properties worth knowing, both discovered by trying:

- The microphone is **stereo-only at 32 kHz**. Constraining the input with `-ac 1` makes ALSA refuse outright, because before `-i` that is a request to open the hardware in mono. The recorder opens a `plughw:` device, whose plug layer converts rate, format and channel count, and downmixes to mono as an output option instead.
- Card indices are not stable across boots, so the device is resolved by name from `/proc/asound/cards`.

## Client to bridge

Every request carries an `id`, echoed in the `ack`. Same shape as the existing actions.

```jsonc
// Start recording. device_id defaults to the on-air camera, and an absent
// `mode` means "use the current preference", so the record button does not
// have to restate what the mode selector already set.
{"id": 1, "action": "record.start", "device_id": "RMOWLHHC233LOQ", "mode": "both"}

// Stop. Returns the finished file's path and size in the ack.
{"id": 2, "action": "record.stop"}

// Poll. State is also pushed unsolicited, so this is only for a fresh client.
{"id": 3, "action": "record.status"}

// What future recordings capture. Bridge-global, because the recorder is.
// See the note above on why this is not a camera setting.
{"id": 4, "action": "record.set_mode", "mode": "both"}   // both | video | audio
```

### Errors

`record.start` fails with an `ack` carrying `ok:false` and an `err` code:

| `err` | Meaning |
| --- | --- |
| `already_recording` | One recording at a time |
| `no_device` | `device_id` unknown, or nothing on air |
| `no_space` | Less than `min_free_bytes` on the target volume |
| `encoder_failed` | ffmpeg would not start; `msg` carries its stderr tail |
| `unknown_action` | A `record.*` action the bridge does not implement |
| `not_recording` | `record.stop` with nothing running |
| `not_supported` | This build has no recorder, which is how macOS answers |
| `audio_unavailable` | Mode `audio` with no microphone. Only ever raised in that mode |

A missing microphone is an error in exactly one mode. In `both` it is not: the recording starts without sound, `recording.audio` comes back `false`, and `recording.audio_available` explains why, because losing the take is worse than losing the sound. In `audio` it is `audio_unavailable`, because nothing is left to record and an empty file that looks like a successful take is the worse outcome.

## Bridge to client

Two additions to the existing state event. Both are pushed on change, so the UI never polls.

```jsonc
{
  "active_device_id": "RMOWLHHC233LOQ",
  "devices": [ /* unchanged */ ],

  // Bridge-global: one recording at a time, like `active`.
  "recording": {
    "active": true,
    "device_id": "RMOWLHHC233LOQ",
    "started_at_ms": 1786800000000,   // wall clock, for a UI that reconnects
    "elapsed_s": 125,                 // authoritative; do not count locally
    "bytes": 41234567,
    "path": "/srv/data/recordings/2026-08-15/142317-RMOWLHHC233LOQ.mp4",
    "audio": true,                    // whether THIS take is writing audio
    "video": true,                    // whether THIS take is writing video
    "mode": "both",                   // what the NEXT take will capture
    "audio_available": true,          // whether a microphone exists at all
    "disk_free_bytes": 973000000000,
    "error": ""                       // non-empty means it died mid-take
  },

}
```

`mode` is the preference and is what the mode selector shows. `video` and `audio` are what the running take is actually doing, and they can disagree with the preference: `mode: "both"` with no microphone yields `video: true, audio: false`. An operator who believes they are capturing sound has to be able to see that they are not, which is why these are three fields and not one.

There is deliberately no per-device `audio` block. The recorder is bridge-global, so a per-camera flag would be reporting a setting that does not exist per camera. `audio_available` sits in the recording block for the same reason.

`auto_gain` is left unwired. `cameraSetAudioAutoGainU` works on this model and could be exposed later as an ordinary device-scoped action, but it is a gain adjustment rather than the mute control the UI was originally going to need, so it does not belong in this contract.

`elapsed_s` is authoritative rather than derived on the client. A phone that reconnects mid-take must show the true elapsed time, not start counting from zero.

`error` is how a recording that dies is surfaced. The UI should show it and stay showing it until the next `record.start`, because a take that silently stopped is the worst outcome here.

## Files

```
/srv/data/recordings/<YYYY-MM-DD>/<HHMMSS>-<SN>.mp4
```

Date directories because a day's takes belong together, and the serial in the filename because two cameras recording on two days is the case that makes an undated flat directory useless.

Seconds rather than minutes in the timestamp: two takes inside one minute is completely ordinary, and at minute resolution the second silently overwrites the first.

Fragmented MP4, so a recording killed by a power cut is still playable up to the last flushed fragment. A plain MP4 whose `moov` atom never got written is a lost take, and this machine cannot boot unattended after a power cut.

## Constraints

- **One recording at a time.** Two would double the encode load and the disk write rate for no clear gain. Revisit when there are two cameras.
- **Never touch the MJPEG path.** It is what OBS consumes in production at a Sikh temple, on macOS. The recorder reads the same JPEGs the bridge already holds, exactly as the H.264 transcoder does, and opens no V4L2 device of its own.
- **Refuse below a floor of free space**, default 5 GB. Filling the disk that holds the photo library is a worse failure than a refused recording.
- **Linux only for now.** The macOS build should compile without the recorder, the same way it compiles without `--h264`.
