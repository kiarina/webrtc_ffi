/// What data channels and tracks share, and data channels.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'native.dart' as n;
import 'runtime.dart';

/// What a [DataChannel] and a [Track] have in common: they open and close,
/// send messages and buffer them.
abstract class Channel {
  Channel.attach(this.id) {
    Runtime.register(id, onEvent);
  }

  /// libdatachannel's id.
  final int id;

  final _opened = Completer<void>();
  final _closed = Completer<void>();
  final _errors = StreamController<String>.broadcast();
  final _bufferedLow = StreamController<void>.broadcast();
  var _deleted = false;

  /// Completes when the channel opens (at once if it is open already).
  Future<void> get opened {
    if (!_opened.isCompleted && !_deleted && n.isOpen(id)) _opened.complete();
    return _opened.future;
  }

  /// Completes when the channel closes, for whatever reason.
  Future<void> get closed => _closed.future;

  bool get isOpen => !_deleted && n.isOpen(id);
  bool get isClosed => _deleted || n.isClosed(id);

  Stream<String> get onError => _errors.stream;

  /// Bytes queued to send.
  int get bufferedAmount => _deleted ? 0 : check('rtcGetBufferedAmount', n.getBufferedAmount(id));

  /// [onBufferedAmountLow] fires when [bufferedAmount] falls to this.
  set bufferedAmountLowThreshold(int amount) =>
      check('rtcSetBufferedAmountLowThreshold', n.setBufferedAmountLowThreshold(id, amount));

  Stream<void> get onBufferedAmountLow => _bufferedLow.stream;

  /// The largest message this channel can send.
  int get maxMessageSize => check('rtcMaxMessageSize', n.maxMessageSize(id));

  /// Sends one binary message.
  void sendBinary(List<int> data) {
    check('rtcSendMessage', n.sendMessage(id, Scratch.copy(data), data.length));
  }

  /// Closes the channel. [closed] completes when it is closed.
  void close() {
    if (_deleted) return;
    n.close(id);
  }

  /// Frees the native object. Closes it first if needed.
  void dispose() {
    if (_deleted) return;
    _deleted = true;
    n.delete(id);
    Runtime.unregister(id);
    _finish();
  }

  void onText(String text);
  void onBinary(Uint8List data);

  void onEvent(int kind, int a, String? text, [String? _]) {
    switch (kind) {
      case n.Ev.open:
        if (!_opened.isCompleted) _opened.complete();
      case n.Ev.closed:
        _finish();
      case n.Ev.error:
        _errors.add(text ?? '');
      case n.Ev.available:
        if (!_deleted) drainMessages(id, onText, onBinary);
      case n.Ev.bufferedLow:
        _bufferedLow.add(null);
    }
  }

  void _finish() {
    if (!_closed.isCompleted) _closed.complete();
    finish();
  }

  /// Closes the streams of a subclass.
  void finish() {
    _errors.close();
    _bufferedLow.close();
  }
}

/// One message on a [DataChannel].
sealed class DataChannelMessage {
  const DataChannelMessage();
}

class TextMessage extends DataChannelMessage {
  const TextMessage(this.text);
  final String text;
}

class BinaryMessage extends DataChannelMessage {
  const BinaryMessage(this.data);
  final Uint8List data;
}

/// An SCTP data channel.
class DataChannel extends Channel {
  DataChannel.attach(super.id) : super.attach();

  final _messages = StreamController<DataChannelMessage>();

  /// Received messages, in order. Single subscription: messages that arrive
  /// before the first listener wait for it.
  Stream<DataChannelMessage> get messages => _messages.stream;

  String get label => readString(id, n.getDataChannelLabel) ?? '';
  String get protocol => readString(id, n.getDataChannelProtocol) ?? '';

  /// The SCTP stream id.
  int get streamId => check('rtcGetDataChannelStream', n.getDataChannelStream(id));

  /// Sends one string message. The C API takes strings null-terminated, so
  /// [text] cannot contain U+0000 (send it as binary instead).
  void sendText(String text) {
    if (text.contains('\u0000')) {
      throw ArgumentError.value(text, 'text', 'contains U+0000');
    }
    final bytes = utf8.encode(text);
    final p = Scratch.get(bytes.length + 1);
    p.asTypedList(bytes.length).setAll(0, bytes);
    p[bytes.length] = 0;
    // A negative size: a null-terminated string message.
    check('rtcSendMessage', n.sendMessage(id, p.cast(), -1));
  }

  @override
  void onText(String text) => _messages.add(TextMessage(text));

  @override
  void onBinary(Uint8List data) => _messages.add(BinaryMessage(data));

  @override
  void finish() {
    _messages.close();
    super.finish();
  }
}
