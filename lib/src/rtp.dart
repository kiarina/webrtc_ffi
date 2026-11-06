/// Reading RTP packets and putting frames back together.
library;

import 'dart:typed_data';

/// One RTP packet (RFC 3550), read without copying the payload.
class RtpPacket {
  RtpPacket._(
    this.bytes, {
    required this.marker,
    required this.payloadType,
    required this.sequenceNumber,
    required this.timestamp,
    required this.ssrc,
    required this.csrcs,
    required this.payload,
    required this.extensionProfile,
    required this.extension,
  });

  /// Reads [bytes]; null when they are not an RTP packet.
  static RtpPacket? parse(Uint8List bytes) {
    if (bytes.length < 12 || bytes[0] >> 6 != 2) return null;
    final padding = bytes[0] & 0x20 != 0;
    final hasExtension = bytes[0] & 0x10 != 0;
    final csrcCount = bytes[0] & 0x0f;
    final d = ByteData.sublistView(bytes);
    var offset = 12 + 4 * csrcCount;
    if (bytes.length < offset) return null;
    final csrcs = [for (var i = 0; i < csrcCount; i++) d.getUint32(12 + 4 * i)];
    int? profile;
    Uint8List? extension;
    if (hasExtension) {
      if (bytes.length < offset + 4) return null;
      profile = d.getUint16(offset);
      final words = d.getUint16(offset + 2);
      if (bytes.length < offset + 4 + 4 * words) return null;
      extension = Uint8List.sublistView(bytes, offset + 4, offset + 4 + 4 * words);
      offset += 4 + 4 * words;
    }
    var end = bytes.length;
    if (padding) {
      end -= bytes[bytes.length - 1];
      if (end < offset) return null;
    }
    return RtpPacket._(
      bytes,
      marker: bytes[1] & 0x80 != 0,
      payloadType: bytes[1] & 0x7f,
      sequenceNumber: d.getUint16(2),
      timestamp: d.getUint32(4),
      ssrc: d.getUint32(8),
      csrcs: csrcs,
      payload: Uint8List.sublistView(bytes, offset, end),
      extensionProfile: profile,
      extension: extension,
    );
  }

  final Uint8List bytes;
  final bool marker;
  final int payloadType;
  final int sequenceNumber;
  final int timestamp;
  final int ssrc;
  final List<int> csrcs;
  final Uint8List payload;

  /// The header extension's profile (0xBEDE for one-byte extensions), if any.
  final int? extensionProfile;
  final Uint8List? extension;
}

/// A frame put back together from RTP packets.
class RtpFrame {
  const RtpFrame(this.data, {required this.timestamp, required this.payloadType, required this.complete});

  final Uint8List data;

  /// The RTP timestamp all its packets carried.
  final int timestamp;
  final int payloadType;

  /// False when a packet of the frame was missing (the data has a gap).
  final bool complete;
}

/// Audio codecs that put one frame in each packet (Opus, G.711, G.722):
/// the frame is the payload.
class AudioDepacketizer {
  AudioDepacketizer({this.payloadTypes});

  /// Only these payload types (all when null).
  final Set<int>? payloadTypes;

  RtpFrame? add(RtpPacket p) {
    if (payloadTypes != null && !payloadTypes!.contains(p.payloadType)) return null;
    return RtpFrame(
      Uint8List.fromList(p.payload),
      timestamp: p.timestamp,
      payloadType: p.payloadType,
      complete: true,
    );
  }
}

/// H.264 over RTP (RFC 6184: single NAL units, STAP-A, FU-A) back to access
/// units in Annex B form (each NAL unit after 00 00 00 01).
///
/// Packets are taken in the order given; a frame ends with the marker bit or
/// when the timestamp changes. A gap in sequence numbers marks the frame
/// incomplete.
class H264Depacketizer {
  H264Depacketizer({this.payloadTypes});

  /// Only these payload types (all when null).
  final Set<int>? payloadTypes;

  static const _startCode = [0, 0, 0, 1];
  final _out = BytesBuilder(copy: false);
  int? _timestamp;
  int? _payloadType;
  int? _lastSequence;
  var _complete = true;
  var _inFragment = false;

  /// Adds one packet; returns the frames it finished (usually zero or one).
  List<RtpFrame> add(RtpPacket p) {
    if (payloadTypes != null && !payloadTypes!.contains(p.payloadType)) return const [];
    final done = <RtpFrame>[];
    if (_timestamp != null && p.timestamp != _timestamp) {
      final f = _flush(complete: false);
      if (f != null) done.add(f);
    }
    if (_lastSequence != null && p.sequenceNumber != (_lastSequence! + 1) & 0xffff) {
      _complete = false;
    }
    _lastSequence = p.sequenceNumber;
    _timestamp = p.timestamp;
    _payloadType = p.payloadType;
    _read(p.payload);
    if (p.marker) {
      final f = _flush(complete: true);
      if (f != null) done.add(f);
    }
    return done;
  }

  void _read(Uint8List b) {
    if (b.isEmpty) return;
    final type = b[0] & 0x1f;
    if (type >= 1 && type <= 23) {
      _inFragment = false;
      _out
        ..add(_startCode)
        ..add(b);
    } else if (type == 24) {
      // STAP-A: 16-bit sizes, each followed by a NAL unit.
      _inFragment = false;
      var i = 1;
      while (i + 2 <= b.length) {
        final size = (b[i] << 8) | b[i + 1];
        i += 2;
        if (i + size > b.length) {
          _complete = false;
          return;
        }
        _out
          ..add(_startCode)
          ..add(Uint8List.sublistView(b, i, i + size));
        i += size;
      }
    } else if (type == 28) {
      // FU-A: indicator, header (S E R type), part.
      if (b.length < 2) return;
      final start = b[1] & 0x80 != 0;
      final end = b[1] & 0x40 != 0;
      if (start) {
        _out
          ..add(_startCode)
          ..addByte((b[0] & 0xe0) | (b[1] & 0x1f));
        _inFragment = true;
      } else if (!_inFragment) {
        _complete = false;
        return;
      }
      _out.add(Uint8List.sublistView(b, 2));
      if (end) _inFragment = false;
    } else {
      // STAP-B, MTAP, FU-B: not used by WebRTC.
      _complete = false;
    }
  }

  RtpFrame? _flush({required bool complete}) {
    final ts = _timestamp, pt = _payloadType;
    final ok = complete && _complete && !_inFragment;
    _timestamp = null;
    _complete = true;
    _inFragment = false;
    if (_out.isEmpty || ts == null || pt == null) {
      _out.clear();
      return null;
    }
    return RtpFrame(_out.takeBytes(), timestamp: ts, payloadType: pt, complete: ok);
  }
}
