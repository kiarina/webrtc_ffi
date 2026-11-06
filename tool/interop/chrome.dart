/// Interop with Chrome (libwebrtc, the WebRTC of flutter_webrtc and the
/// browsers), in one session:
///
/// - a data channel: text in any script and binary, echoed by the page;
/// - media from Chrome: its fake camera and microphone as H.264 and Opus,
///   put back together into frames here;
/// - media to Chrome: those frames sent back on tracks of our own, which
///   Chrome must decode.
///
///   dart run tool/interop/chrome.dart [--chrome <path>] [--host <ip>] [--seconds 8]
///
/// Dart offers; the page (served here, driven over a WebSocket) answers.
/// Prints a JSON report and exits with 1 when a check fails. With --host,
/// Chrome is not started: open the printed URL in a browser yourself (for
/// a probe in a container talking to a browser on the host).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:webrtc_ffi/webrtc_ffi.dart';

Future<void> main(List<String> args) async {
  String? opt(String name) {
    final i = args.indexOf('--$name');
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final seconds = int.parse(opt('seconds') ?? '8');
  final host = opt('host');
  final chromePath = opt('chrome') ?? Platform.environment['CHROME'] ?? _defaultChrome();

  final server = await HttpServer.bind(InternetAddress.anyIPv4, int.parse(opt('port') ?? '0'));
  final page = File.fromUri(Platform.script.resolve('page.html')).readAsStringSync();
  final socket = Completer<WebSocket>();
  server.listen((req) async {
    if (req.uri.path == '/ws') {
      final ws = await WebSocketTransformer.upgrade(req);
      if (!socket.isCompleted) socket.complete(ws);
    } else {
      req.response.headers.contentType = ContentType.html;
      req.response.write(page);
      await req.response.close();
    }
  });
  final url = 'http://${host ?? '127.0.0.1'}:${server.port}/';
  stderr.writeln('page: $url');

  Process? chrome;
  Directory? profile;
  if (host == null) {
    profile = await Directory.systemTemp.createTemp('webrtc_ffi_chrome');
    chrome = await Process.start(chromePath, [
      '--headless=new',
      '--no-first-run',
      '--user-data-dir=${profile.path}',
      '--use-fake-device-for-media-stream',
      '--use-fake-ui-for-media-stream',
      '--disable-features=WebRtcHideLocalIpsWithMdns',
      '--autoplay-policy=no-user-gesture-required',
      url,
    ]);
    chrome.stderr.drain<void>();
    chrome.stdout.drain<void>();
  }

  final report = <String, Object?>{};
  var ok = true;
  void checkThat(String name, bool pass, [Object? detail]) {
    report[name] = {'ok': pass, 'detail': ?detail};
    if (!pass) ok = false;
    stderr.writeln('${pass ? 'ok  ' : 'FAIL'} $name ${detail ?? ''}');
  }

  final ws = await socket.future.timeout(const Duration(seconds: 30));
  final fromPage = StreamController<Map<String, dynamic>>.broadcast();
  ws.listen((m) => fromPage.add(jsonDecode(m as String) as Map<String, dynamic>));
  void toPage(Map<String, Object?> m) => ws.add(jsonEncode(m));
  final chromeVersion = (await fromPage.stream.firstWhere((m) => m['k'] == 'hello'))['ua'];
  report['chrome'] = chromeVersion;

  final pc = PeerConnection();
  final verbose = args.contains('--verbose');
  if (verbose) {
    pc.onStateChange.listen((s) => stderr.writeln('state $s'));
    pc.onIceConnectionStateChange.listen((s) => stderr.writeln('ice $s'));
    pc.onLocalDescription.listen((d) => stderr.writeln('local ${d.type.name}\n${d.sdp}'));
    pc.onLocalCandidate.listen((c) => stderr.writeln('local $c'));
  }
  pc.onLocalDescription.listen((d) => toPage({'k': 'desc', ...d.toJson()}));
  pc.onLocalCandidate.listen((c) => toPage({'k': 'cand', ...c.toJson()}));
  fromPage.stream.listen((m) {
    switch (m['k']) {
      case 'desc':
        if (verbose) stderr.writeln('remote ${m['type']}\n${m['sdp']}');
        pc.setRemoteDescription(SessionDescription.fromJson(m));
      case 'cand':
        if (verbose) stderr.writeln('remote cand ${m['candidate']}');
        pc.addRemoteCandidate(IceCandidate.fromJson(m));
      case 'log':
        stderr.writeln('page: ${m['text']}');
    }
  });

  const h264 = 'profile-level-id=42e01f;packetization-mode=1;level-asymmetry-allowed=1';
  // Ours to Chrome.
  final videoOut = pc.addTrack(
    const TrackInit(
      codec: Codec.h264,
      payloadType: 96,
      ssrc: 1001,
      mid: 'v-out',
      msid: 'back',
      trackId: 'v-back',
      profile: h264,
    ),
  );
  final audioOut = pc.addTrack(
    const TrackInit(
      codec: Codec.opus,
      payloadType: 111,
      ssrc: 1002,
      mid: 'a-out',
      msid: 'back',
      trackId: 'a-back',
      profile: 'minptime=10;useinbandfec=1',
    ),
  );
  // Chrome's to us.
  final videoIn = pc.addTrack(
    const TrackInit(
      codec: Codec.h264,
      payloadType: 96,

      mid: 'v-in',
      direction: Direction.recvOnly,
      profile: h264,
    ),
  );
  final audioIn = pc.addTrack(
    const TrackInit(codec: Codec.opus, payloadType: 111, mid: 'a-in', direction: Direction.recvOnly),
  );
  videoOut.setPacketizer(Codec.h264, payloadType: 96, ssrc: 1001);
  audioOut.setPacketizer(Codec.opus, payloadType: 111, ssrc: 1002);
  videoIn.enableReceiverReports();
  audioIn.enableReceiverReports();
  videoOut.enableKeyframeRequests();
  final dc = pc.createDataChannel('nerve');

  final started = Stopwatch()..start();
  await pc.connected();
  await dc.opened;
  report['connected_ms'] = started.elapsedMilliseconds;
  report['candidate_pair'] = pc.selectedCandidatePair?.local.split(' ').skip(4).take(4).join(' ');

  // --- data channel ---
  final texts = ['ascii', '日本語', '絵文字 👋🏽 𠮷', 'x' * 60000];
  final binary = Uint8List.fromList(List.generate(200000, (i) => i * 7 & 0xff));
  final echoes = dc.messages.take(texts.length + 1).toList();
  texts.forEach(dc.sendText);
  dc.sendBinary(binary);
  final back = await echoes.timeout(const Duration(seconds: 10));
  checkThat(
    'datachannel_text',
    [for (final m in back.take(texts.length)) m is TextMessage ? m.text : null].join() == texts.join(),
  );
  final b = back.last;
  checkThat('datachannel_binary', b is BinaryMessage && _equal(b.data, binary));

  // --- media: receive, and send back what was received ---
  final h264In = H264Depacketizer(payloadTypes: {96});
  final opusIn = AudioDepacketizer(payloadTypes: {111});
  var videoFrames = 0, completeFrames = 0, idr = 0, audioFrames = 0, videoBytes = 0;
  int? firstVideoTs, firstAudioTs;
  var keyframeRequests = 0;
  videoOut.onKeyframeRequest.listen((_) => keyframeRequests++);
  var sentBackVideo = 0;
  var waitingForKeyframe = true;
  videoIn.rtp.listen((bytes) {
    final p = RtpPacket.parse(bytes);
    if (p == null) return;
    for (final f in h264In.add(p)) {
      videoFrames++;
      videoBytes += f.data.length;
      if (!f.complete) continue;
      completeFrames++;
      final types = _nalTypes(f.data);
      if (types.contains(5)) idr++;
      if (waitingForKeyframe && !types.contains(5)) continue;
      waitingForKeyframe = false;
      firstVideoTs ??= f.timestamp;
      final t = ((f.timestamp - firstVideoTs!) & 0xffffffff) / 90000;
      videoOut.sendFrame(f.data, at: Duration(microseconds: (t * 1e6).round()));
      sentBackVideo++;
    }
  });
  audioIn.rtp.listen((bytes) {
    final p = RtpPacket.parse(bytes);
    final f = p == null ? null : opusIn.add(p);
    if (f == null) return;
    audioFrames++;
    firstAudioTs ??= f.timestamp;
    final t = ((f.timestamp - firstAudioTs!) & 0xffffffff) / 48000;
    audioOut.sendFrame(f.data, at: Duration(microseconds: (t * 1e6).round()));
  });

  await Future<void>.delayed(Duration(seconds: seconds ~/ 2));
  final idrBefore = idr;
  videoIn.requestKeyframe();
  await Future<void>.delayed(Duration(seconds: seconds - seconds ~/ 2));

  toPage({'k': 'stats'});
  final stats = await fromPage.stream
      .firstWhere((m) => m['k'] == 'stats')
      .timeout(const Duration(seconds: 10));

  checkThat('video_from_chrome', completeFrames > seconds * 10, {
    'frames': videoFrames,
    'complete': completeFrames,
    'idr': idr,
    'kbit_s': (videoBytes * 8 / 1000 / seconds).round(),
  });
  checkThat('keyframe_request_to_chrome', idr > idrBefore, {'idr_before': idrBefore, 'idr_after': idr});
  checkThat('audio_from_chrome', audioFrames > seconds * 40, {'frames': audioFrames});
  checkThat('video_to_chrome_decoded', ((stats['video_frames_decoded'] as num?) ?? 0) > seconds * 5, {
    'sent': sentBackVideo,
    'decoded': stats['video_frames_decoded'],
    'size': '${stats['video_width']}x${stats['video_height']}',
  });
  checkThat('audio_to_chrome_decoded', ((stats['audio_samples'] as num?) ?? 0) > 48000 * (seconds - 2), {
    'samples': stats['audio_samples'],
    'concealed': stats['audio_concealed'],
  });
  report['keyframe_requests_from_chrome'] = keyframeRequests;
  report['ok'] = ok;

  stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
  pc.dispose();
  await ws.close();
  await server.close(force: true);
  chrome?.kill(ProcessSignal.sigkill);
  await chrome?.exitCode;
  try {
    await profile?.delete(recursive: true);
  } catch (_) {}
  exit(ok ? 0 : 1);
}

String _defaultChrome() {
  if (Platform.isMacOS) return '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
  if (Platform.isWindows) return r'C:\Program Files\Google\Chrome\Application\chrome.exe';
  return 'google-chrome';
}

bool _equal(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// NAL unit types in an Annex B access unit.
Set<int> _nalTypes(Uint8List d) {
  final types = <int>{};
  for (var i = 0; i + 4 < d.length; i++) {
    if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 0 && d[i + 3] == 1) types.add(d[i + 4] & 0x1f);
  }
  return types;
}
