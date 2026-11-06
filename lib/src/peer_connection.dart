/// Peer connections.
library;

import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'channel.dart';
import 'native.dart' as n;
import 'runtime.dart';
import 'track.dart';
import 'types.dart';

/// Settings of a [PeerConnection].
class RtcConfiguration {
  const RtcConfiguration({
    this.iceServers = const [],
    this.bindAddress,
    this.portRangeBegin = 0,
    this.portRangeEnd = 0,
    this.mtu = 0,
    this.maxMessageSize = 0,
    this.relayOnly = false,
    this.enableIceTcp = false,
    this.disableAutoNegotiation = false,
    this.forceMediaTransport = false,
  });

  /// STUN and TURN servers as URLs: `stun:host:port`,
  /// `turn:user:password@host:port`, `turns:...`, with `?transport=tcp` for
  /// TURN over TCP. Empty (the default) means host candidates only.
  final List<String> iceServers;

  /// Gather on this local address only (all when null).
  final String? bindAddress;

  /// Local UDP ports to use (0: any).
  final int portRangeBegin, portRangeEnd;

  /// 0: automatic.
  final int mtu;

  /// The largest message this side accepts (0: libdatachannel's default).
  final int maxMessageSize;

  /// Use relay (TURN) candidates only.
  final bool relayOnly;
  final bool enableIceTcp;

  /// Without it, creating a data channel or adding a track, or setting a
  /// remote offer, sends a description by itself. With it, call
  /// [PeerConnection.setLocalDescription] yourself.
  final bool disableAutoNegotiation;

  /// Set up the media transport (SRTP) even before a track exists.
  final bool forceMediaTransport;
}

/// A WebRTC peer connection.
///
/// Signaling is up to you: send what [onLocalDescription] and
/// [onLocalCandidate] give to the other peer, and give it what it sends to
/// [setRemoteDescription] and [addRemoteCandidate]. With auto negotiation
/// (the default), creating a data channel or track makes the offer, and a
/// remote offer makes the answer.
class PeerConnection {
  PeerConnection([RtcConfiguration config = const RtcConfiguration()])
    : id = _create(config),
      _autoNegotiation = !config.disableAutoNegotiation {
    Runtime.register(id, _onEvent);
    Runtime.retain();
  }

  static int _create(RtcConfiguration c) {
    return using((arena) {
      final servers = arena<Pointer<Char>>(c.iceServers.length + 1);
      for (var i = 0; i < c.iceServers.length; i++) {
        servers[i] = cString(arena, c.iceServers[i]);
      }
      final flags =
          (c.relayOnly ? 1 : 0) |
          (c.enableIceTcp ? 2 : 0) |
          (c.disableAutoNegotiation ? 4 : 0) |
          (c.forceMediaTransport ? 8 : 0);
      return check(
        'rtcCreatePeerConnection',
        n.createPeerConnection(
          Runtime.port,
          servers,
          c.iceServers.length,
          cString(arena, c.bindAddress),
          c.portRangeBegin,
          c.portRangeEnd,
          c.mtu,
          c.maxMessageSize,
          flags,
        ),
      );
    });
  }

  /// libdatachannel's id.
  final int id;

  final bool _autoNegotiation;
  var _negotiationScheduled = false;
  final _unnegotiated = <Track>[];

  final _descriptions = StreamController<SessionDescription>.broadcast();
  final _candidates = StreamController<IceCandidate>.broadcast();
  final _states = StreamController<PeerConnectionState>.broadcast();
  final _iceStates = StreamController<IceConnectionState>.broadcast();
  final _gatheringStates = StreamController<IceGatheringState>.broadcast();
  final _signalingStates = StreamController<SignalingState>.broadcast();
  final _dataChannels = StreamController<DataChannel>();
  final _tracks = StreamController<Track>();
  final _owned = <Channel>[];
  var _deleted = false;

  PeerConnectionState _state = PeerConnectionState.newState;
  IceConnectionState _iceState = IceConnectionState.newState;
  IceGatheringState _gatheringState = IceGatheringState.newState;
  SignalingState _signalingState = SignalingState.stable;

  PeerConnectionState get state => _state;
  IceConnectionState get iceConnectionState => _iceState;
  IceGatheringState get iceGatheringState => _gatheringState;
  SignalingState get signalingState => _signalingState;

  /// Descriptions to send to the other peer.
  Stream<SessionDescription> get onLocalDescription => _descriptions.stream;

  /// Candidates to send to the other peer, as they are gathered.
  Stream<IceCandidate> get onLocalCandidate => _candidates.stream;

  Stream<PeerConnectionState> get onStateChange => _states.stream;
  Stream<IceConnectionState> get onIceConnectionStateChange => _iceStates.stream;
  Stream<IceGatheringState> get onIceGatheringStateChange => _gatheringStates.stream;
  Stream<SignalingState> get onSignalingStateChange => _signalingStates.stream;

  /// Data channels the other peer opened. Single subscription: channels
  /// that arrive before the first listener wait for it.
  Stream<DataChannel> get onDataChannel => _dataChannels.stream;

  /// Tracks a remote description added. Single subscription.
  Stream<Track> get onTrack => _tracks.stream;

  /// Completes when [state] is connected; throws [StateError] if it fails or
  /// closes first, or after [timeout].
  Future<void> connected({Duration timeout = const Duration(seconds: 30)}) {
    if (_state == PeerConnectionState.connected) return Future.value();
    return onStateChange
        .firstWhere(
          (s) =>
              s == PeerConnectionState.connected ||
              s == PeerConnectionState.failed ||
              s == PeerConnectionState.closed,
        )
        .timeout(timeout)
        .then((s) {
          if (s != PeerConnectionState.connected) throw StateError('peer connection $s');
        });
  }

  /// Starts negotiation: makes an offer (or the answer, after a remote offer)
  /// and reports it on [onLocalDescription]. Only needed with
  /// [RtcConfiguration.disableAutoNegotiation], or to renegotiate.
  void setLocalDescription([SdpType? type]) => using((arena) {
    check('rtcSetLocalDescription', n.setLocalDescription(id, cString(arena, type?.name)));
  });

  void setRemoteDescription(SessionDescription description) => using((arena) {
    check(
      'rtcSetRemoteDescription',
      n.setRemoteDescription(id, cString(arena, description.sdp), cString(arena, description.type.name)),
    );
  });

  /// Adds a candidate from the other peer (after its description). An empty
  /// candidate (end of candidates) is ignored.
  void addRemoteCandidate(IceCandidate candidate) {
    var c = candidate.candidate;
    if (c.isEmpty) return;
    if (c.startsWith('a=')) c = c.substring(2);
    using((arena) {
      check(
        'rtcAddRemoteCandidate',
        n.addRemoteCandidate(id, cString(arena, c), cString(arena, candidate.sdpMid)),
      );
    });
  }

  SessionDescription? get localDescription => _description(n.getLocalDescription, n.getLocalDescriptionType);
  SessionDescription? get remoteDescription =>
      _description(n.getRemoteDescription, n.getRemoteDescriptionType);

  SessionDescription? _description(n.StringGetter sdp, n.StringGetter type) {
    final s = readString(id, sdp), t = readString(id, type);
    if (s == null || t == null) return null;
    return SessionDescription(SdpType.parse(t), s);
  }

  /// The local and remote addresses ICE chose, `ip:port`.
  String? get localAddress => readString(id, n.getLocalAddress);
  String? get remoteAddress => readString(id, n.getRemoteAddress);

  /// The candidate pair ICE chose.
  ({String local, String remote})? get selectedCandidatePair => using((arena) {
    const size = 256;
    final l = arena<Char>(size), r = arena<Char>(size);
    if (n.getSelectedCandidatePair(id, l, size, r, size) < 0) return null;
    String strip(String c) => c.startsWith('a=') ? c.substring(2) : c;
    return (local: strip(l.cast<Utf8>().toDartString()), remote: strip(r.cast<Utf8>().toDartString()));
  });

  /// The largest message the other peer accepts.
  int get remoteMaxMessageSize => check('rtcGetRemoteMaxMessageSize', n.getRemoteMaxMessageSize(id));

  /// Opens a data channel. By default it is ordered and reliable. Setting
  /// [maxRetransmits] or [maxPacketLifeTime] makes it unreliable. With
  /// [negotiated], both peers create it with the same [streamId] and nothing
  /// is announced.
  DataChannel createDataChannel(
    String label, {
    bool ordered = true,
    int? maxRetransmits,
    Duration? maxPacketLifeTime,
    String protocol = '',
    bool negotiated = false,
    int? streamId,
  }) {
    final dc = using(
      (arena) => check(
        'rtcCreateDataChannel',
        n.createDataChannel(
          Runtime.port,
          id,
          cString(arena, label),
          cString(arena, protocol),
          ordered ? 0 : 1,
          maxRetransmits ?? -1,
          maxPacketLifeTime?.inMilliseconds ?? -1,
          negotiated ? 1 : 0,
          streamId ?? -1,
        ),
      ),
    );
    final ch = DataChannel.attach(dc);
    _owned.add(ch);
    return ch;
  }

  /// Adds a track for one codec.
  Track addTrack(TrackInit init) {
    if (init.ssrc == null) return addTrackFromSdp(init.toMediaSection());
    final tr = using(
      (arena) => check(
        'rtcAddTrack',
        n.addTrack(
          Runtime.port,
          id,
          init.direction.index,
          init.codec.value,
          init.payloadType,
          init.ssrc!,
          cString(arena, init.mid),
          cString(arena, init.name),
          cString(arena, init.msid),
          cString(arena, init.trackId),
          cString(arena, init.profile),
        ),
      ),
    );
    final t = Track.attach(tr);
    _owned.add(t);
    _negotiate(t);
    return t;
  }

  /// libdatachannel negotiates by itself for data channels, not for tracks.
  /// Tracks added in one go share one description, and a description that
  /// already carries them (a data channel created right after, say) is not
  /// sent again.
  void _negotiate(Track t) {
    if (!_autoNegotiation) return;
    _unnegotiated.add(t);
    if (_negotiationScheduled) return;
    _negotiationScheduled = true;
    scheduleMicrotask(() {
      _negotiationScheduled = false;
      if (_deleted) return;
      final sdp = readString(id, n.getLocalDescription) ?? '';
      final missing = _unnegotiated.where(
        (t) => !sdp.contains('a=mid:${t.mid}\r\n') && !sdp.contains('a=mid:${t.mid}\n'),
      );
      final needed = missing.isNotEmpty;
      _unnegotiated.clear();
      if (needed) setLocalDescription();
    });
  }

  /// Adds a track from a whole media description (an `m=` section with its
  /// attributes), for codecs or settings [addTrack] does not cover.
  Track addTrackFromSdp(String mediaDescription) {
    final tr = using(
      (arena) => check('rtcAddTrack', n.addTrackSdp(Runtime.port, id, cString(arena, mediaDescription))),
    );
    final t = Track.attach(tr);
    _owned.add(t);
    _negotiate(t);
    return t;
  }

  /// Closes the connection (and its channels and tracks).
  void close() {
    if (_deleted) return;
    n.closePeerConnection(id);
  }

  /// Closes and frees the connection, its channels and its tracks.
  void dispose() {
    if (_deleted) return;
    for (final c in _owned) {
      c.dispose();
    }
    _deleted = true;
    n.deletePeerConnection(id);
    Runtime.unregister(id);
    Runtime.release();
    _finish();
  }

  void _onEvent(int kind, int a, String? text1, String? text2) {
    switch (kind) {
      case n.Ev.localDescription:
        _descriptions.add(SessionDescription(SdpType.parse(text1!), text2!));
      case n.Ev.localCandidate:
        var c = text2!;
        if (c.startsWith('a=')) c = c.substring(2);
        final mid = text1!;
        _candidates.add(IceCandidate(c, sdpMid: mid, sdpMLineIndex: _mLineIndex(mid)));
      case n.Ev.state:
        _state = PeerConnectionState.values[a];
        _states.add(_state);
        if (_state == PeerConnectionState.closed) _finish();
      case n.Ev.iceState:
        _iceState = IceConnectionState.values[a];
        _iceStates.add(_iceState);
      case n.Ev.gatheringState:
        _gatheringState = IceGatheringState.values[a];
        _gatheringStates.add(_gatheringState);
      case n.Ev.signalingState:
        _signalingState = SignalingState.values[a];
        _signalingStates.add(_signalingState);
      case n.Ev.dataChannel:
        final ch = DataChannel.attach(a);
        _owned.add(ch);
        if (!_dataChannels.isClosed) _dataChannels.add(ch);
      case n.Ev.track:
        final t = Track.attach(a);
        _owned.add(t);
        if (!_tracks.isClosed) _tracks.add(t);
    }
  }

  /// The index of [mid]'s m-line in the local description, for peers that
  /// match candidates by index (libwebrtc accepts either).
  int? _mLineIndex(String mid) {
    final sdp = readString(id, n.getLocalDescription);
    if (sdp == null) return null;
    var index = -1;
    for (final line in sdp.split(RegExp(r'\r?\n'))) {
      if (line.startsWith('m=')) index++;
      if (line == 'a=mid:$mid') return index;
    }
    return null;
  }

  void _finish() {
    if (_descriptions.isClosed) return;
    for (final c in [
      _descriptions,
      _candidates,
      _states,
      _iceStates,
      _gatheringStates,
      _signalingStates,
      _dataChannels,
      _tracks,
    ]) {
      c.close();
    }
  }
}
