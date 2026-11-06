import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:test/test.dart';
import 'package:webrtc_ffi/webrtc_ffi.dart';

import 'loopback.dart';

/// A fake H.264 access unit: SPS, PPS and a big IDR slice (Annex B), so the
/// slice needs FU-A and the parameter sets fit in a STAP-A or single packets.
Uint8List accessUnit(Random r, int sliceSize) {
  final b = BytesBuilder();
  void nal(List<int> header, int size) {
    b.add([0, 0, 0, 1, ...header]);
    // Never 00 00 0x inside a NAL unit (that is what emulation prevention
    // guarantees in real streams).
    b.add(List.generate(size, (_) => 1 + r.nextInt(255)));
  }

  nal([0x67, 0x42, 0xe0, 0x1f], 8); // SPS
  nal([0x68], 4); // PPS
  nal([0x65], sliceSize); // IDR slice
  return b.toBytes();
}

void main() {
  late Loopback l;
  late StreamQueue<Track> incoming;

  setUp(() {
    l = Loopback();
    incoming = StreamQueue(l.b.onTrack);
  });

  tearDown(() => l.dispose());

  test('H.264 frames arrive whole through FU-A, with their timestamps', () async {
    final video = l.a.addTrack(
      const TrackInit(
        codec: Codec.h264,
        payloadType: 96,
        ssrc: 42,
        mid: 'video',
        msid: 'stream',
        trackId: 'video',
        profile: 'profile-level-id=42e01f;packetization-mode=1;level-asymmetry-allowed=1',
      ),
    );
    video.setPacketizer(Codec.h264, payloadType: 96, ssrc: 42, maxFragmentSize: 1200);
    final remote = await incoming.next.timeout(const Duration(seconds: 10));
    expect(remote.mid, 'video');
    expect(remote.direction, Direction.recvOnly);
    remote.enableReceiverReports();
    await Future.wait([video.opened, remote.opened]).timeout(const Duration(seconds: 10));

    final r = Random(2);
    final frames = [for (var i = 0; i < 10; i++) accessUnit(r, 5000 + 1000 * i)];
    final dep = H264Depacketizer(payloadTypes: {96});
    final got = <RtpFrame>[];
    final done = Completer<void>();
    remote.rtp.listen((bytes) {
      final p = RtpPacket.parse(bytes)!;
      expect(p.ssrc, 42);
      got.addAll(dep.add(p));
      if (got.length == frames.length && !done.isCompleted) done.complete();
    });
    for (var i = 0; i < frames.length; i++) {
      video.sendFrame(frames[i], at: Duration(milliseconds: 33 * i));
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await done.future.timeout(const Duration(seconds: 10));
    expect([for (final f in got) f.data], frames);
    expect(got.every((f) => f.complete), isTrue);
    final ticks = [for (final f in got) (f.timestamp - got.first.timestamp) & 0xffffffff];
    expect(ticks, [for (var i = 0; i < frames.length; i++) 33 * i * 90]);
  });

  test('Opus frames arrive one per packet, and audio and video share the connection', () async {
    final audio = l.a.addTrack(
      const TrackInit(codec: Codec.opus, payloadType: 111, ssrc: 7, mid: 'audio', msid: 'stream'),
    );
    audio.setPacketizer(Codec.opus, payloadType: 111, ssrc: 7);
    final video = l.a.addTrack(
      const TrackInit(codec: Codec.h264, payloadType: 96, ssrc: 8, mid: 'video', msid: 'stream'),
    );
    video.setPacketizer(Codec.h264, payloadType: 96, ssrc: 8);
    final dc = l.a.createDataChannel('nerve');

    final remoteTracks = {
      for (final t in await incoming.take(2).timeout(const Duration(seconds: 10))) t.mid: t,
    };
    expect(remoteTracks.keys, unorderedEquals(['audio', 'video']));
    final remote = remoteTracks['audio']!;
    expect(remote.payloadTypesFor('opus'), contains(111));
    await Future.wait([audio.opened, remote.opened, dc.opened]).timeout(const Duration(seconds: 10));

    final r = Random(3);
    final frames = [
      for (var i = 0; i < 50; i++) Uint8List.fromList(List.generate(40 + i, (_) => r.nextInt(256))),
    ];
    final dep = AudioDepacketizer(payloadTypes: {111});
    final got = remote.rtp.map((b) => dep.add(RtpPacket.parse(b)!)!).take(frames.length).toList();
    for (var i = 0; i < frames.length; i++) {
      audio.sendFrame(frames[i], at: Duration(milliseconds: 20 * i));
    }
    final f = await got.timeout(const Duration(seconds: 10));
    expect([for (final e in f) e.data], frames);
    expect(f[1].timestamp - f[0].timestamp, 960); // 20 ms at 48 kHz
  });

  test('keyframe requests reach the sender', () async {
    final video = l.a.addTrack(const TrackInit(codec: Codec.h264, payloadType: 96, ssrc: 9, mid: 'video'));
    video.setPacketizer(Codec.h264, payloadType: 96, ssrc: 9);
    video.enableKeyframeRequests();
    final remote = await incoming.next.timeout(const Duration(seconds: 10));
    remote.enableReceiverReports();
    await Future.wait([video.opened, remote.opened]).timeout(const Duration(seconds: 10));
    // The receiver learns the SSRC from a packet before it can ask.
    final first = remote.rtp.first;
    video.sendFrame(accessUnit(Random(4), 100), at: Duration.zero);
    await first.timeout(const Duration(seconds: 10));
    final asked = video.onKeyframeRequest.first;
    remote.requestKeyframe();
    await asked.timeout(const Duration(seconds: 10));
  });
}
