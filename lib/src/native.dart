/// The C functions of the bundled library: libdatachannel's C API (`rtc*`)
/// and the shim (`webrtc_ffi_*`, native/shim.c).
@DefaultAsset('package:webrtc_ffi/webrtc_ffi')
library;

import 'dart:ffi';

/// Event kinds of the shim; keep in step with native/shim.c.
abstract final class Ev {
  static const localDescription = 1;
  static const localCandidate = 2;
  static const state = 3;
  static const iceState = 4;
  static const gatheringState = 5;
  static const signalingState = 6;
  static const dataChannel = 7;
  static const track = 8;
  static const open = 10;
  static const closed = 11;
  static const error = 12;
  static const available = 13;
  static const bufferedLow = 14;
  static const pli = 15;
  static const remb = 16;
  static const log = 20;
}

const errSuccess = 0;
const errInvalid = -1;
const errFailure = -2;
const errNotAvail = -3;
const errTooSmall = -4;

// --- shim ---

@Native<IntPtr Function(Pointer<Void>)>(symbol: 'webrtc_ffi_init')
external int init(Pointer<Void> apiData);

@Native<Void Function(Int, Int64)>(symbol: 'webrtc_ffi_init_logger')
external void initLogger(int level, int port);

@Native<Int Function(Int64, Pointer<Pointer<Char>>, Int, Pointer<Char>, Int, Int, Int, Int, Int)>(
  symbol: 'webrtc_ffi_create_peer_connection',
)
external int createPeerConnection(
  int port,
  Pointer<Pointer<Char>> iceServers,
  int count,
  Pointer<Char> bindAddress,
  int portBegin,
  int portEnd,
  int mtu,
  int maxMessageSize,
  int flags,
);

@Native<Int Function(Int64, Int, Pointer<Char>, Pointer<Char>, Int, Int, Int, Int, Int)>(
  symbol: 'webrtc_ffi_create_data_channel',
)
external int createDataChannel(
  int port,
  int pc,
  Pointer<Char> label,
  Pointer<Char> protocol,
  int unordered,
  int maxRetransmits,
  int maxPacketLifeTime,
  int negotiated,
  int stream,
);

@Native<
  Int Function(
    Int64,
    Int,
    Int,
    Int,
    Int,
    Uint32,
    Pointer<Char>,
    Pointer<Char>,
    Pointer<Char>,
    Pointer<Char>,
    Pointer<Char>,
  )
>(symbol: 'webrtc_ffi_add_track')
external int addTrack(
  int port,
  int pc,
  int direction,
  int codec,
  int payloadType,
  int ssrc,
  Pointer<Char> mid,
  Pointer<Char> name,
  Pointer<Char> msid,
  Pointer<Char> trackId,
  Pointer<Char> profile,
);

@Native<Int Function(Int64, Int, Pointer<Char>)>(symbol: 'webrtc_ffi_add_track_sdp')
external int addTrackSdp(int port, int pc, Pointer<Char> mediaDescription);

@Native<Int Function(Int, Int, Uint32, Pointer<Char>, Int, Uint32, Int, Int, Int, Uint32, Uint32)>(
  symbol: 'webrtc_ffi_set_packetizer',
)
external int setPacketizer(
  int tr,
  int codec,
  int ssrc,
  Pointer<Char> cname,
  int payloadType,
  int clockRate,
  int maxFragmentSize,
  int nalSeparator,
  int obuPacketization,
  int sequenceNumber,
  int timestamp,
);

@Native<Int Function(Int)>(symbol: 'webrtc_ffi_chain_pli_handler')
external int chainPliHandler(int tr);

@Native<Int Function(Int)>(symbol: 'webrtc_ffi_chain_remb_handler')
external int chainRembHandler(int tr);

// --- peer connection ---

@Native<Int Function(Int)>(symbol: 'rtcClosePeerConnection')
external int closePeerConnection(int pc);

@Native<Int Function(Int)>(symbol: 'rtcDeletePeerConnection')
external int deletePeerConnection(int pc);

@Native<Int Function(Int, Pointer<Char>)>(symbol: 'rtcSetLocalDescription')
external int setLocalDescription(int pc, Pointer<Char> type);

@Native<Int Function(Int, Pointer<Char>, Pointer<Char>)>(symbol: 'rtcSetRemoteDescription')
external int setRemoteDescription(int pc, Pointer<Char> sdp, Pointer<Char> type);

@Native<Int Function(Int, Pointer<Char>, Pointer<Char>)>(symbol: 'rtcAddRemoteCandidate')
external int addRemoteCandidate(int pc, Pointer<Char> cand, Pointer<Char> mid);

typedef StringGetter = int Function(int id, Pointer<Char> buffer, int size);

@Native<Int Function(Int, Pointer<Char>, Int)>(symbol: 'rtcGetLocalDescription')
external int getLocalDescription(int pc, Pointer<Char> buffer, int size);

@Native<Int Function(Int, Pointer<Char>, Int)>(symbol: 'rtcGetRemoteDescription')
external int getRemoteDescription(int pc, Pointer<Char> buffer, int size);

@Native<Int Function(Int, Pointer<Char>, Int)>(symbol: 'rtcGetLocalDescriptionType')
external int getLocalDescriptionType(int pc, Pointer<Char> buffer, int size);

@Native<Int Function(Int, Pointer<Char>, Int)>(symbol: 'rtcGetRemoteDescriptionType')
external int getRemoteDescriptionType(int pc, Pointer<Char> buffer, int size);

@Native<Int Function(Int, Pointer<Char>, Int)>(symbol: 'rtcGetLocalAddress')
external int getLocalAddress(int pc, Pointer<Char> buffer, int size);

@Native<Int Function(Int, Pointer<Char>, Int)>(symbol: 'rtcGetRemoteAddress')
external int getRemoteAddress(int pc, Pointer<Char> buffer, int size);

@Native<Int Function(Int, Pointer<Char>, Int, Pointer<Char>, Int)>(symbol: 'rtcGetSelectedCandidatePair')
external int getSelectedCandidatePair(
  int pc,
  Pointer<Char> local,
  int localSize,
  Pointer<Char> remote,
  int remoteSize,
);

@Native<Int Function(Int)>(symbol: 'rtcGetMaxDataChannelStream')
external int getMaxDataChannelStream(int pc);

@Native<Int Function(Int)>(symbol: 'rtcGetRemoteMaxMessageSize')
external int getRemoteMaxMessageSize(int pc);

// --- data channel and track (common) ---

@Native<Int Function(Int, Pointer<Char>, Int)>(symbol: 'rtcSendMessage')
external int sendMessage(int id, Pointer<Char> data, int size);

@Native<Int Function(Int, Pointer<Char>, Pointer<Int>)>(symbol: 'rtcReceiveMessage')
external int receiveMessage(int id, Pointer<Char> buffer, Pointer<Int> size);

@Native<Int Function(Int)>(symbol: 'rtcClose')
external int close(int id);

@Native<Int Function(Int)>(symbol: 'rtcDelete')
external int delete(int id);

@Native<Bool Function(Int)>(symbol: 'rtcIsOpen')
external bool isOpen(int id);

@Native<Bool Function(Int)>(symbol: 'rtcIsClosed')
external bool isClosed(int id);

@Native<Int Function(Int)>(symbol: 'rtcMaxMessageSize')
external int maxMessageSize(int id);

@Native<Int Function(Int)>(symbol: 'rtcGetBufferedAmount')
external int getBufferedAmount(int id);

@Native<Int Function(Int, Int)>(symbol: 'rtcSetBufferedAmountLowThreshold')
external int setBufferedAmountLowThreshold(int id, int amount);

// --- data channel ---

@Native<Int Function(Int)>(symbol: 'rtcGetDataChannelStream')
external int getDataChannelStream(int dc);

@Native<Int Function(Int, Pointer<Char>, Int)>(symbol: 'rtcGetDataChannelLabel')
external int getDataChannelLabel(int dc, Pointer<Char> buffer, int size);

@Native<Int Function(Int, Pointer<Char>, Int)>(symbol: 'rtcGetDataChannelProtocol')
external int getDataChannelProtocol(int dc, Pointer<Char> buffer, int size);

// --- track ---

@Native<Int Function(Int, Pointer<Char>, Int)>(symbol: 'rtcGetTrackDescription')
external int getTrackDescription(int tr, Pointer<Char> buffer, int size);

@Native<Int Function(Int, Pointer<Char>, Int)>(symbol: 'rtcGetTrackMid')
external int getTrackMid(int tr, Pointer<Char> buffer, int size);

@Native<Int Function(Int, Pointer<Int>)>(symbol: 'rtcGetTrackDirection')
external int getTrackDirection(int tr, Pointer<Int> direction);

@Native<Int Function(Int)>(symbol: 'rtcRequestKeyframe')
external int requestKeyframe(int tr);

@Native<Int Function(Int, UnsignedInt)>(symbol: 'rtcRequestBitrate')
external int requestBitrate(int tr, int bitrate);

@Native<Int Function(Int)>(symbol: 'rtcChainRtcpReceivingSession')
external int chainRtcpReceivingSession(int tr);

@Native<Int Function(Int)>(symbol: 'rtcChainRtcpSrReporter')
external int chainRtcpSrReporter(int tr);

@Native<Int Function(Int, UnsignedInt)>(symbol: 'rtcChainRtcpNackResponder')
external int chainRtcpNackResponder(int tr, int maxStoredPackets);

@Native<Int Function(Int, Double, Pointer<Uint32>)>(symbol: 'rtcTransformSecondsToTimestamp')
external int transformSecondsToTimestamp(int id, double seconds, Pointer<Uint32> timestamp);

@Native<Int Function(Int, Uint32, Pointer<Double>)>(symbol: 'rtcTransformTimestampToSeconds')
external int transformTimestampToSeconds(int id, int timestamp, Pointer<Double> seconds);

@Native<Int Function(Int, Pointer<Uint32>)>(symbol: 'rtcGetCurrentTrackTimestamp')
external int getCurrentTrackTimestamp(int id, Pointer<Uint32> timestamp);

@Native<Int Function(Int, Uint32)>(symbol: 'rtcSetTrackRtpTimestamp')
external int setTrackRtpTimestamp(int id, int timestamp);

@Native<Int Function(Int, Pointer<Uint32>, Int)>(symbol: 'rtcGetSsrcsForTrack')
external int getSsrcsForTrack(int tr, Pointer<Uint32> buffer, int count);

@Native<Int Function(Int, Pointer<Char>, Pointer<Int>, Int)>(symbol: 'rtcGetTrackPayloadTypesForCodec')
external int getTrackPayloadTypesForCodec(int tr, Pointer<Char> codec, Pointer<Int> buffer, int size);

// --- global ---

@Native<Void Function()>(symbol: 'rtcPreload')
external void preload();

@Native<Void Function()>(symbol: 'rtcCleanup')
external void cleanup();

@Native<Int Function(UnsignedInt)>(symbol: 'rtcSetThreadPoolSize')
external int setThreadPoolSize(int count);
