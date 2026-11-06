/// Routes the shim's events to the objects they belong to, and small helpers
/// around the C API.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'native.dart' as n;
import 'types.dart';

typedef EventHandler = void Function(int kind, int a, String? text1, String? text2);

/// Routes the native events of this isolate. Peer connections, data
/// channels and tracks share one id space in libdatachannel.
abstract final class Runtime {
  static final _handlers = <int, EventHandler>{};

  /// Events for an id nobody registered yet. A channel or track the remote
  /// peer opens can report `open` or `available` before the event that
  /// announces it reaches Dart.
  static final _pending = <int, List<List<Object?>>>{};

  static RawReceivePort? _port;
  static final _logs = StreamController<RtcLogRecord>.broadcast();
  static var _live = 0;

  /// This isolate's port for native events.
  static int get port => _ensure().sendPort.nativePort;

  static RawReceivePort _ensure() {
    final existing = _port;
    if (existing != null) return existing;
    final r = n.init(NativeApi.initializeApiDLData);
    if (r != 0) throw StateError('webrtc_ffi: Dart_InitializeApiDL failed ($r)');
    final p = RawReceivePort(_on, 'webrtc_ffi');
    // Only live peer connections keep the program running ([retain]).
    p.keepIsolateAlive = false;
    return _port = p;
  }

  /// A peer connection exists: wait for its events instead of letting the
  /// program end. Balanced by [release] when it is disposed.
  static void retain() {
    if (_live++ == 0) _ensure().keepIsolateAlive = true;
  }

  static void release() {
    if (--_live == 0) _ensure().keepIsolateAlive = false;
  }

  static void register(int id, EventHandler handler) {
    _ensure();
    _handlers[id] = handler;
    final waiting = _pending.remove(id);
    if (waiting != null) {
      for (final m in waiting) {
        _dispatch(handler, m);
      }
    }
  }

  static void unregister(int id) {
    _handlers.remove(id);
    _pending.remove(id);
  }

  static void _on(dynamic message) {
    final m = message as List<Object?>;
    final kind = m[0] as int, id = m[1] as int;
    if (kind == n.Ev.log) {
      final level = (m[2] as int).clamp(0, RtcLogLevel.values.length - 1);
      _logs.add(RtcLogRecord(RtcLogLevel.values[level], (m[3] as String?) ?? ''));
      return;
    }
    final h = _handlers[id];
    if (h != null) {
      _dispatch(h, m);
    } else {
      (_pending[id] ??= []).add(m);
    }
  }

  static void _dispatch(EventHandler h, List<Object?> m) =>
      h(m[0] as int, m[2] as int, m[3] as String?, m[4] as String?);

  static Stream<RtcLogRecord> startLogging(RtcLogLevel level) {
    n.initLogger(level.index, port);
    return _logs.stream;
  }
}

/// Throws [RtcException] for a negative libdatachannel result.
int check(String operation, int result) {
  if (result < 0) throw RtcException(operation, result);
  return result;
}

/// Reads a string from a getter that reports the size it needs; null when
/// the value is not available.
String? readString(int id, n.StringGetter getter) {
  final size = getter(id, nullptr, 0);
  if (size == n.errNotAvail) return null;
  check('string size', size);
  return using((arena) {
    final buf = arena<Char>(size);
    check('string read', getter(id, buf, size));
    return buf.cast<Utf8>().toDartString();
  });
}

/// A native copy of [s] (null stays null), freed with [arena].
Pointer<Char> cString(Arena arena, String? s) =>
    s == null ? nullptr : s.toNativeUtf8(allocator: arena).cast();

/// One growing native buffer for sends and receives. Every call into the C
/// API is synchronous, so one per isolate is enough.
abstract final class Scratch {
  static Pointer<Uint8> _buf = malloc<Uint8>(64 * 1024);
  static int _size = 64 * 1024;
  static final Pointer<Int> sizeOut = malloc<Int>();

  static Pointer<Uint8> get(int size) {
    if (size > _size) {
      malloc.free(_buf);
      var s = _size;
      while (s < size) {
        s *= 2;
      }
      _buf = malloc<Uint8>(s);
      _size = s;
    }
    return _buf;
  }

  static int get size => _size;

  /// Copies [data] into the buffer and returns it.
  static Pointer<Char> copy(List<int> data) {
    final p = get(data.length);
    p.asTypedList(data.length).setAll(0, data);
    return p.cast();
  }
}

/// Pulls every waiting message of a channel or track. [onText] gets string
/// messages, [onBinary] binary ones (a fresh copy each).
void drainMessages(int id, void Function(String) onText, void Function(Uint8List) onBinary) {
  while (true) {
    Scratch.sizeOut.value = Scratch.size;
    var r = n.receiveMessage(id, Scratch.get(0).cast(), Scratch.sizeOut);
    if (r == n.errTooSmall) {
      final need = Scratch.sizeOut.value.abs();
      Scratch.get(need);
      Scratch.sizeOut.value = Scratch.size;
      r = n.receiveMessage(id, Scratch.get(0).cast(), Scratch.sizeOut);
    }
    if (r == n.errNotAvail || r < 0) return;
    final size = Scratch.sizeOut.value;
    final buf = Scratch.get(0);
    if (size < 0) {
      // A string, its size counting the terminating 0.
      onText(utf8.decode(buf.asTypedList(-size - 1), allowMalformed: true));
    } else {
      onBinary(Uint8List.fromList(buf.asTypedList(size)));
    }
  }
}
