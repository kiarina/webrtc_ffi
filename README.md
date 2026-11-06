# webrtc_ffi

WebRTC for Dart **without Flutter**: peer connections, data channels and media tracks, through
[libdatachannel](https://github.com/paullouisageneau/libdatachannel) and `dart:ffi`.

It is for programs that cannot use flutter_webrtc: a CLI, a server, a process in a container. It talks to browsers,
flutter_webrtc apps (libwebrtc) and other WebRTC stacks.

- **Data channels:** ordered or not, reliable or not, negotiated or announced. Text and binary messages, back-pressure
  (`bufferedAmount`, `onBufferedAmountLow`).
- **Media tracks:** RTP in and out. Packetizers split encoded frames for H.264, H.265, AV1, Opus, PCMU, PCMA, AAC and
  G.722. RTCP sender reports, NACK retransmission, keyframe requests (PLI) and bitrate estimates (REMB). On the receiving
  side, depacketizers put H.264 and audio frames back together.
- **Not included:** capture, encoding, decoding and playback. Bring encoded frames (from FFmpeg, a hardware encoder or a
  file), or forward the ones you receive.
- **No setup:** the build hook compiles libdatachannel, libsrtp, usrsctp, libjuice and Mbed TLS from source into one
  shared library. Nothing has to be installed at run time (no OpenSSL, no VC++ runtime).

## Status

0.1.0-dev. Checked on:

| Platform | Tests | Interop with Chrome 156 (data, H.264 and Opus both ways) |
|---|---|---|
| macOS 27 (arm64) | ✓ | ✓ |
| Linux (Debian trixie, arm64, in Docker) | ✓ | ✓ (Chrome on the macOS host) |
| Windows 11 (x64, Visual Studio 2022) | ✓ | ✓ |

Android and iOS are not built yet.

## Requirements

| | |
|---|---|
| Dart | 3.10 or later |
| Build tools | CMake 3.21 or later and a C/C++ compiler: Xcode or its command line tools on macOS, GCC or Clang on Linux, Visual Studio 2022 with "Desktop development with C++" on Windows (its CMake is found automatically) |

The first build takes a minute or two. Later builds are cached. The library is about 3 MB.

## Usage

### Signaling and a data channel

Signaling is yours to carry (a WebSocket, HTTP, anything). Send what `onLocalDescription` and `onLocalCandidate` give to
the other peer, and pass what it sends to `setRemoteDescription` and `addRemoteCandidate`. Both types have W3C-shaped
`toJson` and `fromJson`, so they can go to a browser as they are.

```dart
import 'package:webrtc_ffi/webrtc_ffi.dart';

final pc = PeerConnection(const RtcConfiguration(iceServers: ['stun:stun.l.google.com:19302']));
pc.onLocalDescription.listen((d) => signaling.send({'type': 'desc', ...d.toJson()}));
pc.onLocalCandidate.listen((c) => signaling.send({'type': 'cand', ...c.toJson()}));
signaling.onMessage((m) => switch (m['type']) {
  'desc' => pc.setRemoteDescription(SessionDescription.fromJson(m)),
  'cand' => pc.addRemoteCandidate(IceCandidate.fromJson(m)),
  _ => null,
});

final channel = pc.createDataChannel('chat'); // makes the offer
await channel.opened;
channel.sendText('hello 👋');
channel.messages.listen((m) => switch (m) {
  TextMessage(:final text) => print(text),
  BinaryMessage(:final data) => print('${data.length} bytes'),
});
```

The other peer gets the channel from `pc.onDataChannel`. A connection that is open keeps the program running.
`dispose()` frees it, along with its channels and tracks.

[example/webrtc_ffi_example.dart](example/webrtc_ffi_example.dart) is a complete program: two connections in one process.

### Sending media

```dart
final video = pc.addTrack(const TrackInit(
  codec: Codec.h264,
  payloadType: 96,
  ssrc: 1001,
  mid: 'video',
  msid: 'camera',
  profile: 'profile-level-id=42e01f;packetization-mode=1;level-asymmetry-allowed=1',
));
video.setPacketizer(Codec.h264, payloadType: 96, ssrc: 1001);
video.enableKeyframeRequests();
video.onKeyframeRequest.listen((_) => encoder.forceKeyframe());

await video.opened;
encoder.frames.listen((f) => video.sendFrame(f.annexB, at: f.time));
```

Adding tracks negotiates by itself, as creating a data channel does. To negotiate yourself, set
`RtcConfiguration.disableAutoNegotiation` and call `setLocalDescription()`.

### Receiving media

Add a track that only receives (no `ssrc`), or take the tracks a remote offer brings from `pc.onTrack`. Received media
comes as RTP packets:

```dart
final cam = pc.addTrack(const TrackInit(
  codec: Codec.h264, payloadType: 96, mid: 'remote-video', direction: Direction.recvOnly));
cam.enableReceiverReports(); // RTCP receiver reports; lets requestKeyframe work
final depacketizer = H264Depacketizer(payloadTypes: {96});
cam.rtp.listen((bytes) {
  for (final frame in depacketizer.add(RtpPacket.parse(bytes)!)) {
    if (frame.complete) decoder.decode(frame.data, frame.timestamp); // Annex B
  }
});
cam.requestKeyframe();
```

`AudioDepacketizer` does the same for Opus and G.711 (one frame per packet). Packets come in arrival order: there is no
jitter buffer or reordering.

### Notes

- Each isolate gets the events of the connections it created. Several isolates can use the library at the same time.
- `WebRtc.logs(RtcLogLevel.debug)` streams libdatachannel's own log.
- A text message cannot contain U+0000, because the C API takes strings null-terminated. Send binary instead.
- With Docker Desktop, a container reaches the host through the VM's network. The peer on the host must offer a candidate
  on that network: Chrome only does so with a media permission (or `--use-fake-ui-for-media-stream`).

## Testing

```bash
dart test                                   # loopback: data channels and media in one process
dart run tool/interop/chrome.dart           # against a headless Chrome (data, and media both ways)
docker build -f tool/docker/Dockerfile -t webrtc_ffi-test . && docker run --rm webrtc_ffi-test
```

The Chrome check opens the page it serves in a headless Chrome with a fake camera and microphone, so it needs no
devices. It receives Chrome's H.264 and Opus, sends the same frames back, and passes only if Chrome decodes them.
With `--host <ip>` it does not start Chrome: open the printed URL in a browser yourself.

## How it works

- `native/shim.c` is a small C layer over libdatachannel's C API. It posts every event to the Dart port of the isolate
  that owns the connection (`Dart_PostCObject`), so no Dart code runs on libdatachannel's threads. Messages are not
  copied into events: Dart pulls them with `rtcReceiveMessage` when told that some are waiting. The calls that take C
  structs are wrapped there too.
- Everything is linked into one library, `webrtc_ffi`. Only the C API is exported, so the bundled Mbed TLS and libsrtp
  cannot clash with other copies in the same process.
- `tool/vendor.sh` refreshes `third_party/` from pinned tags. `third_party/VERSIONS.txt` lists what is there.

## License

MIT; see [LICENSE](LICENSE). The bundled native sources keep their own licenses: see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
