/// Media tracks.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'channel.dart';
import 'native.dart' as n;
import 'runtime.dart';
import 'types.dart';

/// One media section (`m=`) of the session: RTP in and out.
///
/// libdatachannel moves RTP; it does not capture, encode, decode or play.
/// To send, give it encoded frames ([sendFrame], after [setPacketizer]) or
/// whole RTP packets ([sendRtp]). Received media arrives as RTP packets
/// ([rtp]); [H264Depacketizer] and [AudioDepacketizer] turn them back into
/// frames.
class Track extends Channel {
  Track.attach(super.id) : super.attach();

  final _rtp = StreamController<Uint8List>();
  final _keyframeRequests = StreamController<void>.broadcast();
  final _bitrates = StreamController<int>.broadcast();
  int? _startTimestamp;
  static final _random = Random.secure();

  /// Received RTP packets, in arrival order (no reordering or jitter
  /// buffer). RTCP is not included. Single subscription.
  Stream<Uint8List> get rtp => _rtp.stream;

  /// The remote peer asked for a keyframe (RTCP PLI). Needs
  /// [enableKeyframeRequests].
  Stream<void> get onKeyframeRequest => _keyframeRequests.stream;

  /// Bitrates the remote peer estimates (RTCP REMB), in bit/s. Needs
  /// [enableBitrateEstimates].
  Stream<int> get onBitrateEstimate => _bitrates.stream;

  /// The media id (`a=mid`).
  String get mid => readString(id, n.getTrackMid) ?? '';

  /// The media description of this track (its `m=` section).
  String get description => readString(id, n.getTrackDescription) ?? '';

  Direction get direction => using((arena) {
    final p = arena<Int>();
    check('rtcGetTrackDirection', n.getTrackDirection(id, p));
    return Direction.values[p.value];
  });

  /// The SSRCs announced for this track.
  List<int> get ssrcs => using((arena) {
    final p = arena<Uint32>(16);
    final count = check('rtcGetSsrcsForTrack', n.getSsrcsForTrack(id, p, 16));
    return [for (var i = 0; i < count; i++) p[i]];
  });

  /// The payload types the description gives [codec] (its rtpmap name, such
  /// as `H264` or `opus`).
  List<int> payloadTypesFor(String codec) => using((arena) {
    final p = arena<Int>(32);
    final c = cString(arena, codec);
    final count = check('rtcGetTrackPayloadTypesForCodec', n.getTrackPayloadTypesForCodec(id, c, p, 32));
    return [for (var i = 0; i < count; i++) p[i]];
  });

  /// Splits frames given to [sendFrame] into RTP packets for [codec].
  ///
  /// [payloadType] and [ssrc] must match the description ([Track]'s
  /// [TrackInit]). [clockRate] defaults to the codec's usual one.
  /// [maxFragmentSize] (H.264, H.265, AV1) defaults to libdatachannel's
  /// choice. With [senderReports], RTCP sender reports are sent (receivers
  /// use them to sync audio and video); with [nackResponder], lost packets
  /// the receiver asks for are sent again from the last [nackBuffer] packets.
  void setPacketizer(
    Codec codec, {
    required int payloadType,
    required int ssrc,
    String cname = 'webrtc_ffi',
    int? clockRate,
    int maxFragmentSize = 0,
    NalSeparator nalSeparator = NalSeparator.startSequence,
    ObuPacketization obuPacketization = ObuPacketization.temporalUnit,
    bool senderReports = true,
    bool nackResponder = true,
    int nackBuffer = 512,
  }) {
    if (!codec.canPacketize) {
      throw ArgumentError.value(codec, 'codec', 'libdatachannel has no packetizer for it');
    }
    using((arena) {
      check(
        'set packetizer',
        n.setPacketizer(
          id,
          codec.value,
          ssrc,
          cString(arena, cname),
          payloadType,
          clockRate ?? codec.clockRate,
          maxFragmentSize,
          nalSeparator.index,
          obuPacketization.index,
          _random.nextInt(1 << 16),
          _random.nextInt(1 << 32),
        ),
      );
    });
    if (senderReports) check('rtcChainRtcpSrReporter', n.chainRtcpSrReporter(id));
    if (nackResponder) check('rtcChainRtcpNackResponder', n.chainRtcpNackResponder(id, nackBuffer));
    _startTimestamp = currentTimestamp;
  }

  /// Answers RTCP for received media (receiver reports, and lets
  /// [requestKeyframe] and [requestBitrate] work). Call it on tracks that
  /// receive.
  void enableReceiverReports() => check('rtcChainRtcpReceivingSession', n.chainRtcpReceivingSession(id));

  /// Reports the remote peer's keyframe requests on [onKeyframeRequest].
  void enableKeyframeRequests() => check('chain PLI handler', n.chainPliHandler(id));

  /// Reports the remote peer's bitrate estimates on [onBitrateEstimate].
  void enableBitrateEstimates() => check('chain REMB handler', n.chainRembHandler(id));

  /// Sends one encoded frame through the packetizer. [at] is the frame's
  /// time from the start of the stream; without it the RTP timestamp stays
  /// where the last frame left it.
  void sendFrame(List<int> frame, {Duration? at}) {
    if (at != null) {
      final start = _startTimestamp ?? (throw StateError('setPacketizer first'));
      final ts = (start + secondsToTimestamp(at.inMicroseconds / 1e6)) & 0xffffffff;
      check('rtcSetTrackRtpTimestamp', n.setTrackRtpTimestamp(id, ts));
    }
    sendBinary(frame);
  }

  /// Sends one whole RTP packet (on a track without a packetizer).
  void sendRtp(List<int> packet) => sendBinary(packet);

  /// Asks the remote sender for a keyframe (PLI). Needs
  /// [enableReceiverReports].
  void requestKeyframe() => check('rtcRequestKeyframe', n.requestKeyframe(id));

  /// Asks the remote sender to keep under [bitsPerSecond] (REMB). Needs
  /// [enableReceiverReports].
  void requestBitrate(int bitsPerSecond) => check('rtcRequestBitrate', n.requestBitrate(id, bitsPerSecond));

  /// The RTP timestamp the next frame gets.
  int get currentTimestamp => using((arena) {
    final p = arena<Uint32>();
    check('rtcGetCurrentTrackTimestamp', n.getCurrentTrackTimestamp(id, p));
    return p.value;
  });

  /// [seconds] in RTP clock ticks of this track.
  int secondsToTimestamp(double seconds) => using((arena) {
    final p = arena<Uint32>();
    check('rtcTransformSecondsToTimestamp', n.transformSecondsToTimestamp(id, seconds, p));
    return p.value;
  });

  /// RTP clock ticks of this track in seconds.
  double timestampToSeconds(int timestamp) => using((arena) {
    final p = arena<Double>();
    check('rtcTransformTimestampToSeconds', n.transformTimestampToSeconds(id, timestamp, p));
    return p.value;
  });

  @override
  void onText(String text) {}

  @override
  void onBinary(Uint8List data) {
    // RTCP (payload types 200-207 sit where RTP has marker + PT 72-79)
    // that no handler consumed is not media.
    if (data.length >= 2) {
      final pt = data[1] & 0x7f;
      if (pt >= 72 && pt <= 79) return;
    }
    _rtp.add(data);
  }

  @override
  void onEvent(int kind, int a, String? text, [String? _]) {
    switch (kind) {
      case n.Ev.pli:
        _keyframeRequests.add(null);
      case n.Ev.remb:
        _bitrates.add(a);
      default:
        super.onEvent(kind, a, text);
    }
  }

  @override
  void finish() {
    _rtp.close();
    _keyframeRequests.close();
    _bitrates.close();
    super.finish();
  }
}

/// A track to add with [PeerConnection.addTrack].
class TrackInit {
  const TrackInit({
    required this.codec,
    required this.payloadType,
    required this.mid,
    this.ssrc,
    this.direction = Direction.sendOnly,
    this.name,
    this.msid,
    this.trackId,
    this.profile,
  });

  final Codec codec;
  final int payloadType;

  /// The SSRC this side sends with. Null (for a track that only receives)
  /// announces none.
  final int? ssrc;

  /// The media id; unique in the session (such as `video` or `0`).
  final String mid;
  final Direction direction;

  /// The CNAME-like name of the source (optional).
  final String? name;

  /// The media stream id; tracks with the same one play in sync.
  final String? msid;
  final String? trackId;

  /// The codec's format parameters (`a=fmtp`), such as
  /// `profile-level-id=42e01f;packetization-mode=1;level-asymmetry-allowed=1`.
  final String? profile;

  /// The media section libdatachannel would write, without an SSRC.
  String toMediaSection() {
    final video = codec.kind == MediaKind.video;
    final rtpmap = switch (codec) {
      Codec.h264 => 'H264/90000',
      Codec.vp8 => 'VP8/90000',
      Codec.vp9 => 'VP9/90000',
      Codec.h265 => 'H265/90000',
      Codec.av1 => 'AV1/90000',
      Codec.opus => 'opus/48000/2',
      Codec.pcmu => 'PCMU/8000/1',
      Codec.pcma => 'PCMA/8000/1',
      Codec.aac => 'MP4A-LATM/48000/2',
      Codec.g722 => 'G722/8000/1',
    };
    final fmtp = profile ?? (codec == Codec.aac ? 'cpresent=1' : null);
    final dir = switch (direction) {
      Direction.sendOnly => 'sendonly',
      Direction.recvOnly => 'recvonly',
      Direction.inactive => 'inactive',
      _ => 'sendrecv',
    };
    return [
      'm=${video ? 'video' : 'audio'} 9 UDP/TLS/RTP/SAVPF $payloadType',
      'c=IN IP4 0.0.0.0',
      'a=mid:$mid',
      'a=$dir',
      'a=rtcp-mux',
      'a=rtpmap:$payloadType $rtpmap',
      if (fmtp != null) 'a=fmtp:$payloadType $fmtp',
      if (video) ...[
        'a=rtcp-fb:$payloadType nack',
        'a=rtcp-fb:$payloadType nack pli',
        'a=rtcp-fb:$payloadType goog-remb',
      ],
      if (msid != null) 'a=msid:$msid ${trackId ?? ''}'.trimRight(),
      '',
    ].join('\r\n');
  }
}
