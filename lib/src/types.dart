/// Values shared by the public API.
library;

/// A libdatachannel call that returned an error code.
class RtcException implements Exception {
  RtcException(this.operation, this.code);

  final String operation;
  final int code;

  String get codeName => switch (code) {
    -1 => 'invalid argument',
    -2 => 'failure',
    -3 => 'not available',
    -4 => 'buffer too small',
    _ => '$code',
  };

  @override
  String toString() => 'RtcException: $operation failed ($codeName)';
}

enum PeerConnectionState { newState, connecting, connected, disconnected, failed, closed }

enum IceConnectionState { newState, checking, connected, completed, failed, disconnected, closed }

enum IceGatheringState { newState, gathering, complete }

enum SignalingState { stable, haveLocalOffer, haveRemoteOffer, haveLocalPranswer, haveRemotePranswer }

enum SdpType {
  offer,
  answer,
  pranswer,
  rollback;

  static SdpType parse(String s) => values.firstWhere((t) => t.name == s);
}

/// An SDP offer or answer.
class SessionDescription {
  const SessionDescription(this.type, this.sdp);

  final SdpType type;
  final String sdp;

  /// The W3C shape, `{type, sdp}`.
  Map<String, String> toJson() => {'type': type.name, 'sdp': sdp};

  factory SessionDescription.fromJson(Map<String, dynamic> json) =>
      SessionDescription(SdpType.parse(json['type'] as String), json['sdp'] as String);

  @override
  String toString() => 'SessionDescription(${type.name})';
}

/// An ICE candidate, as `candidate:...` (without `a=`) and its media id.
class IceCandidate {
  const IceCandidate(this.candidate, {this.sdpMid, this.sdpMLineIndex});

  final String candidate;
  final String? sdpMid;

  /// Only carried for the other side: libdatachannel matches by [sdpMid].
  final int? sdpMLineIndex;

  /// The W3C shape, `{candidate, sdpMid, sdpMLineIndex}`.
  Map<String, Object?> toJson() => {'candidate': candidate, 'sdpMid': sdpMid, 'sdpMLineIndex': sdpMLineIndex};

  factory IceCandidate.fromJson(Map<String, dynamic> json) => IceCandidate(
    json['candidate'] as String,
    sdpMid: json['sdpMid'] as String?,
    sdpMLineIndex: (json['sdpMLineIndex'] as num?)?.toInt(),
  );

  @override
  String toString() => 'IceCandidate($candidate)';
}

enum RtcLogLevel { none, fatal, error, warning, info, debug, verbose }

class RtcLogRecord {
  const RtcLogRecord(this.level, this.message);

  final RtcLogLevel level;
  final String message;

  @override
  String toString() => '[${level.name}] $message';
}

/// Codecs libdatachannel knows; the values are its `rtcCodec`.
enum Codec {
  h264(0, MediaKind.video, 90000),
  vp8(1, MediaKind.video, 90000),
  vp9(2, MediaKind.video, 90000),
  h265(3, MediaKind.video, 90000),
  av1(4, MediaKind.video, 90000),
  opus(128, MediaKind.audio, 48000),
  pcmu(129, MediaKind.audio, 8000),
  pcma(130, MediaKind.audio, 8000),
  aac(131, MediaKind.audio, 48000),
  g722(132, MediaKind.audio, 8000);

  const Codec(this.value, this.kind, this.clockRate);

  final int value;
  final MediaKind kind;

  /// The usual RTP clock rate.
  final int clockRate;

  /// libdatachannel packetizes this codec (VP8 and VP9 it does not).
  bool get canPacketize => this != vp8 && this != vp9;
}

enum MediaKind { audio, video }

/// The values are libdatachannel's `rtcDirection`.
enum Direction { unknown, sendOnly, recvOnly, sendRecv, inactive }

/// How H.264 / H.265 frames given to [Track.sendFrame] separate their NAL
/// units. The values are libdatachannel's `rtcNalUnitSeparator`.
enum NalSeparator { length, longStartSequence, shortStartSequence, startSequence }

/// How AV1 frames given to [Track.sendFrame] are made of OBUs.
enum ObuPacketization { obu, temporalUnit }
