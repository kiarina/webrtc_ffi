/// WebRTC for Dart without Flutter, on libdatachannel.
///
/// Peer connections ([PeerConnection]), data channels ([DataChannel]) and
/// media tracks ([Track]: RTP, with packetizers for sending and
/// depacketizers for receiving). Encoding, decoding, capture and playback
/// are not part of it.
library;

import 'src/native.dart' as n;
import 'src/runtime.dart';
import 'src/types.dart';

export 'src/channel.dart' show BinaryMessage, Channel, DataChannel, DataChannelMessage, TextMessage;
export 'src/peer_connection.dart' show PeerConnection, RtcConfiguration;
export 'src/rtp.dart' show AudioDepacketizer, H264Depacketizer, RtpFrame, RtpPacket;
export 'src/track.dart' show Track, TrackInit;
export 'src/types.dart';

/// Process-wide settings of the native library.
abstract final class WebRtc {
  /// Native log messages at [level] and above. Only the first call sets the
  /// level (a libdatachannel limitation).
  static Stream<RtcLogRecord> logs(RtcLogLevel level) => Runtime.startLogging(level);

  /// Starts the native threads now instead of with the first connection.
  static void preload() => n.preload();

  /// Waits for the native threads to stop. Call it, if at all, after every
  /// connection is disposed.
  static void cleanup() => n.cleanup();

  /// Native worker threads; applies to threads started afterwards.
  static set threadPoolSize(int count) => check('rtcSetThreadPoolSize', n.setThreadPoolSize(count));
}
