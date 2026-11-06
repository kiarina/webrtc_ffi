import 'dart:async';

import 'package:webrtc_ffi/webrtc_ffi.dart';

/// Two peer connections in this process with signaling wired directly.
class Loopback {
  Loopback({RtcConfiguration config = const RtcConfiguration()})
    : a = PeerConnection(config),
      b = PeerConnection(config) {
    _wire(a, b);
    _wire(b, a);
  }

  final PeerConnection a, b;
  final _subs = <StreamSubscription<void>>[];

  void _wire(PeerConnection from, PeerConnection to) {
    _subs.add(from.onLocalDescription.listen(to.setRemoteDescription));
    _subs.add(from.onLocalCandidate.listen(to.addRemoteCandidate));
  }

  Future<void> connected() => Future.wait([a.connected(), b.connected()]);

  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    a.dispose();
    b.dispose();
  }
}
