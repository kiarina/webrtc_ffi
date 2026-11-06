import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:test/test.dart';
import 'package:webrtc_ffi/webrtc_ffi.dart';

import 'loopback.dart';

void main() {
  late Loopback l;
  late DataChannel x, y;
  late StreamQueue<DataChannel> incoming;

  setUp(() async {
    l = Loopback();
    x = l.a.createDataChannel('nerve');
    incoming = StreamQueue(l.b.onDataChannel);
    y = await incoming.next.timeout(const Duration(seconds: 10));
    await Future.wait([x.opened, y.opened]).timeout(const Duration(seconds: 10));
  });

  tearDown(() => l.dispose());

  test('connects and reports the channel', () async {
    await l.connected();
    expect(l.a.state, PeerConnectionState.connected);
    expect(y.label, 'nerve');
    expect(x.streamId, y.streamId);
    expect(l.a.selectedCandidatePair, isNotNull);
    expect(l.a.localDescription!.type, SdpType.offer);
    expect(l.b.localDescription!.type, SdpType.answer);
  });

  test('text in any script, in order', () async {
    final texts = ['hello', 'quote " and \\ and\nnewline', '日本語のテキスト', '絵文字 👋🏽 と 𠮷', 'x' * 100000];
    final got = y.messages.take(texts.length).toList();
    texts.forEach(x.sendText);
    final m = await got.timeout(const Duration(seconds: 10));
    expect([for (final e in m) (e as TextMessage).text], texts);
  });

  test('rejects U+0000 in text', () {
    expect(() => x.sendText('a\u0000b'), throwsArgumentError);
  });

  test('binary both ways, up to the max message size', () async {
    final r = Random(1);
    final sizes = [1, 1000, 65536, x.maxMessageSize];
    final data = [for (final s in sizes) Uint8List.fromList(List.generate(s, (_) => r.nextInt(256)))];
    final got = x.messages.take(data.length).toList();
    final echo = y.messages.listen((m) => y.sendBinary((m as BinaryMessage).data));
    data.forEach(x.sendBinary);
    final m = await got.timeout(const Duration(seconds: 20));
    await echo.cancel();
    expect([for (final e in m) (e as BinaryMessage).data], data);
  });

  test('bufferedAmount and its low event', () async {
    x.bufferedAmountLowThreshold = 0;
    final low = x.onBufferedAmountLow.first;
    final chunk = Uint8List(60000);
    for (var i = 0; i < 200; i++) {
      x.sendBinary(chunk);
    }
    expect(x.bufferedAmount, greaterThan(0));
    final received = y.messages.take(200).length;
    await low.timeout(const Duration(seconds: 20));
    expect(await received.timeout(const Duration(seconds: 20)), 200);
  });

  test('closing one end closes the other', () async {
    x.close();
    await y.closed.timeout(const Duration(seconds: 10));
    expect(y.isClosed, isTrue);
  });

  test('unordered unreliable channel opens', () async {
    final u = l.a.createDataChannel('fast', ordered: false, maxRetransmits: 0, protocol: 'p');
    final v = await incoming.next.timeout(const Duration(seconds: 10));
    await v.opened;
    expect(v.label, 'fast');
    expect(v.protocol, 'p');
    u.sendText('ping');
    expect(((await v.messages.first) as TextMessage).text, 'ping');
  });

  test('negotiated channel needs no announcement', () async {
    final p = l.a.createDataChannel('pre', negotiated: true, streamId: 10);
    final q = l.b.createDataChannel('pre', negotiated: true, streamId: 10);
    await Future.wait([p.opened, q.opened]).timeout(const Duration(seconds: 10));
    p.sendText('hi');
    expect(((await q.messages.first) as TextMessage).text, 'hi');
  });
}
