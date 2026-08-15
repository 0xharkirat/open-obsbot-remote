/// What a recording captures.
///
/// A boolean "with audio or not" could not express audio-only, and audio-only
/// is the mode whose cost differs most: roughly 57 MB an hour at 128 kbps AAC
/// against 3.7 GB an hour for video. That difference is the reason to offer
/// it, so the preference is a mode rather than a flag.
enum RecordMode {
  /// Video and audio. The default, and a `.mp4`.
  both('both', 'Video + Audio'),

  /// Video with no audio track. Still a `.mp4`.
  video('video', 'Video only'),

  /// Audio with no video track, written as `.m4a`. An MP4 with no picture is
  /// legal and confusing: it opens in a video player as a black rectangle
  /// with sound, so the extension carries the difference.
  audio('audio', 'Audio only');

  const RecordMode(this.wire, this.label);

  /// The value on the wire.
  final String wire;

  /// What the operator reads. Plain words rather than codec names, because
  /// this is read in a hurry by someone who is not thinking about containers.
  final String label;

  /// Unknown strings fall back to [both] rather than throwing. A bridge that
  /// grows a fourth mode should not crash a remote that predates it, and a
  /// remote that cannot parse a mode is still able to record.
  static RecordMode fromWire(String? s) {
    switch (s) {
      case 'video':
        return RecordMode.video;
      case 'audio':
        return RecordMode.audio;
      default:
        return RecordMode.both;
    }
  }

  /// Whether a take in this mode writes a video track.
  bool get hasVideo => this != RecordMode.audio;

  /// Whether a take in this mode tries to write an audio track. Trying and
  /// succeeding differ: in [both] a missing microphone downgrades to silence,
  /// while in [audio] it is a hard failure.
  bool get wantsAudio => this != RecordMode.video;
}
