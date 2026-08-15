# Recording and audio protocol

The contract between the bridge and the remote for the REC tab.

Written before either side is built, so the two can be implemented in parallel and meet in the middle.

## Why recording is host-side

The Tiny 2 Lite has no storage. Every recording method in the SDK is annotated `@category tail air`: `cameraSetVideoRecordR`, `cameraSetTakePhotosR`, `cameraSetRecordResolutionR`, `cameraSetRecordSplitSizeR`. That is a different model.

So the bridge records. On the Linux host that is also the better place: the disk and the hardware encoder are both there.

Audio is different. `cameraSetAudioCtrlStateU` and `cameraSetAudioAutoGainU` are both tagged `tiny2 series`, so the camera's own audio controls do work. But the video path carries no audio at all, so a recording with sound means capturing the camera's USB audio interface separately and muxing it. The toggle in the UI controls both: the SDK setting on the camera, and whether the recorder muxes an audio track.

## Client to bridge

Every request carries an `id`, echoed in the `ack`. Same shape as the existing actions.

```jsonc
// Start recording. device_id defaults to the on-air camera.
{"id": 1, "action": "record.start", "device_id": "RMOWLHHC233LOQ", "audio": true}

// Stop. Returns the finished file's path and size in the ack.
{"id": 2, "action": "record.stop"}

// Poll. State is also pushed unsolicited, so this is only for a fresh client.
{"id": 3, "action": "record.status"}

// Camera audio on or off. Applies the SDK setting and sets whether future
// recordings mux an audio track.
{"id": 4, "action": "audio.set", "device_id": "RMOWLHHC233LOQ", "enabled": true}
```

### Errors

`record.start` fails with an `ack` carrying `ok:false` and an `err` code:

| `err` | Meaning |
| --- | --- |
| `already_recording` | One recording at a time |
| `no_device` | `device_id` unknown, or nothing on air |
| `no_space` | Less than `min_free_bytes` on the target volume |
| `encoder_failed` | ffmpeg would not start; `msg` carries its stderr tail |
| `audio_unavailable` | `audio:true` but the camera exposes no capture device |

`audio_unavailable` is a **warning, not a failure**: the recording starts without sound and `recording.audio` comes back `false`. Losing the take because the mic was missing would be the wrong trade.

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
    "path": "/srv/data/recordings/2026-08-15/1423-RMOWLHHC233LOQ.mp4",
    "audio": true,                    // whether a track is actually being written
    "disk_free_bytes": 973000000000,
    "error": ""                       // non-empty means it died mid-take
  },

  // Per device, inside each entry of `devices`.
  "audio": {
    "available": true,   // the camera exposes a capture device
    "enabled": true,     // SDK state
    "auto_gain": true
  }
}
```

`elapsed_s` is authoritative rather than derived on the client. A phone that reconnects mid-take must show the true elapsed time, not start counting from zero.

`error` is how a recording that dies is surfaced. The UI should show it and stay showing it until the next `record.start`, because a take that silently stopped is the worst outcome here.

## Files

```
/srv/data/recordings/<YYYY-MM-DD>/<HHMM>-<SN>.mp4
```

Date directories because a day's takes belong together, and the serial in the filename because two cameras recording on two days is the case that makes an undated flat directory useless.

Fragmented MP4, so a recording killed by a power cut is still playable up to the last flushed fragment. A plain MP4 whose `moov` atom never got written is a lost take, and this machine cannot boot unattended after a power cut.

## Constraints

- **One recording at a time.** Two would double the encode load and the disk write rate for no clear gain. Revisit when there are two cameras.
- **Never touch the MJPEG path.** It is what OBS consumes in production at a Sikh temple, on macOS. The recorder reads the same JPEGs the bridge already holds, exactly as the H.264 transcoder does, and opens no V4L2 device of its own.
- **Refuse below a floor of free space**, default 5 GB. Filling the disk that holds the photo library is a worse failure than a refused recording.
- **Linux only for now.** The macOS build should compile without the recorder, the same way it compiles without `--h264`.
