// Two peer connections in one process: the signaling a real program would
// send over the network (descriptions and candidates) is handed over
// directly. One opens a data channel, the other answers a message.
import 'package:webrtc_ffi/webrtc_ffi.dart';

Future<void> main() async {
  final alice = PeerConnection();
  final bob = PeerConnection();
  for (final (from, to) in [(alice, bob), (bob, alice)]) {
    from.onLocalDescription.listen(to.setRemoteDescription);
    from.onLocalCandidate.listen(to.addRemoteCandidate);
  }

  bob.onDataChannel.listen((channel) {
    channel.messages.listen((m) {
      if (m is TextMessage) channel.sendText('bob got: ${m.text}');
    });
  });

  final channel = alice.createDataChannel('chat');
  await channel.opened;
  channel.sendText('hello 👋');
  final reply = await channel.messages.first;
  print((reply as TextMessage).text);
  print('connected through ${alice.selectedCandidatePair?.local}');

  alice.dispose();
  bob.dispose();
}
