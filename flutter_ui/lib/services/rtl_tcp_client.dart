import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

enum RtlTcpConnectionState {
  disconnected,
  connecting,
  connected,
  error,
}

class RtlTcpClient {
  Socket? _socket;
  StreamSubscription<Uint8List>? _subscription;
  final _spectrumController = StreamController<Float32List>.broadcast();
  final _stateController = StreamController<RtlTcpConnectionState>.broadcast();

  RtlTcpConnectionState _state = RtlTcpConnectionState.disconnected;
  String _lastError = '';
  int _headerBytesRemaining = 12;
  int _frequencyHz = 127250000;
  int _sampleRateHz = 1024000;
  DateTime _lastFftAt = DateTime.fromMillisecondsSinceEpoch(0);
  Uint8List _carry = Uint8List(0);

  RtlTcpConnectionState get state => _state;
  String get lastError => _lastError;
  int get frequencyHz => _frequencyHz;
  int get sampleRateHz => _sampleRateHz;
  Stream<Float32List> get spectrumStream => _spectrumController.stream;
  Stream<RtlTcpConnectionState> get stateStream => _stateController.stream;

  Future<void> connect({
    required String host,
    required int port,
    int sampleRateHz = 1024000,
    int frequencyHz = 127250000,
  }) async {
    await disconnect();
    _setState(RtlTcpConnectionState.connecting);
    _lastError = '';
    _headerBytesRemaining = 12;
    _carry = Uint8List(0);
    _frequencyHz = frequencyHz;
    _sampleRateHz = sampleRateHz;

    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 5),
      );
      socket.setOption(SocketOption.tcpNoDelay, true);
      _socket = socket;

      _subscription = socket.listen(
        _handleData,
        onError: (Object error) {
          _lastError = error.toString();
          _setState(RtlTcpConnectionState.error);
        },
        onDone: () {
          if (_state != RtlTcpConnectionState.disconnected) {
            _setState(RtlTcpConnectionState.disconnected);
          }
        },
        cancelOnError: false,
      );

      _setState(RtlTcpConnectionState.connected);
      _sendCommand(2, _sampleRateHz);
      _sendCommand(1, _frequencyHz);
      _sendCommand(3, 0); // tuner AGC
      _sendCommand(8, 0); // RTL AGC off
    } catch (error) {
      _lastError = error.toString();
      _setState(RtlTcpConnectionState.error);
      rethrow;
    }
  }

  Future<void> disconnect() async {
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    _socket?.destroy();
    _socket = null;
    _carry = Uint8List(0);
    _setState(RtlTcpConnectionState.disconnected);
  }

  void setFrequency(int frequencyHz) {
    _frequencyHz = frequencyHz;
    if (_state == RtlTcpConnectionState.connected) {
      _sendCommand(1, frequencyHz);
    }
  }

  void setSampleRate(int sampleRateHz) {
    _sampleRateHz = sampleRateHz;
    if (_state == RtlTcpConnectionState.connected) {
      _sendCommand(2, sampleRateHz);
    }
  }

  void setTunerAgc(bool enabled) {
    if (_state == RtlTcpConnectionState.connected) {
      _sendCommand(3, enabled ? 0 : 1);
    }
  }

  void setGainIndex(int index) {
    if (_state == RtlTcpConnectionState.connected) {
      _sendCommand(13, index);
    }
  }

  void _setState(RtlTcpConnectionState value) {
    _state = value;
    if (!_stateController.isClosed) {
      _stateController.add(value);
    }
  }

  void _sendCommand(int command, int parameter) {
    final socket = _socket;
    if (socket == null) {
      return;
    }

    final bytes = ByteData(5)
      ..setUint8(0, command)
      ..setUint32(1, parameter, Endian.big);
    socket.add(bytes.buffer.asUint8List());
  }

  void _handleData(Uint8List input) {
    var data = input;

    if (_headerBytesRemaining > 0) {
      if (data.length <= _headerBytesRemaining) {
        _headerBytesRemaining -= data.length;
        return;
      }
      data = Uint8List.sublistView(data, _headerBytesRemaining);
      _headerBytesRemaining = 0;
    }

    final now = DateTime.now();
    if (now.difference(_lastFftAt).inMilliseconds < 45) {
      return;
    }

    const neededBytes = 2048; // 1024 complex unsigned 8-bit IQ samples.
    Uint8List frame;
    if (_carry.isNotEmpty) {
      final merged = Uint8List(_carry.length + data.length)
        ..setRange(0, _carry.length, _carry)
        ..setRange(_carry.length, _carry.length + data.length, data);
      data = merged;
      _carry = Uint8List(0);
    }

    if (data.length < neededBytes) {
      _carry = Uint8List.fromList(data);
      return;
    }

    frame = Uint8List.sublistView(data, 0, neededBytes);
    _lastFftAt = now;

    final spectrum = _fft1024(frame);
    if (!_spectrumController.isClosed) {
      _spectrumController.add(spectrum);
    }
  }

  Float32List _fft1024(Uint8List iqBytes) {
    const n = 1024;
    final re = Float64List(n);
    final im = Float64List(n);

    for (var i = 0; i < n; i++) {
      final window = 0.5 - 0.5 * math.cos((2 * math.pi * i) / (n - 1));
      re[i] = ((iqBytes[i * 2] - 127.5) / 127.5) * window;
      im[i] = ((iqBytes[i * 2 + 1] - 127.5) / 127.5) * window;
    }

    var j = 0;
    for (var i = 1; i < n; i++) {
      var bit = n >> 1;
      while ((j & bit) != 0) {
        j ^= bit;
        bit >>= 1;
      }
      j ^= bit;
      if (i < j) {
        final tr = re[i];
        re[i] = re[j];
        re[j] = tr;
        final ti = im[i];
        im[i] = im[j];
        im[j] = ti;
      }
    }

    for (var length = 2; length <= n; length <<= 1) {
      final angle = -2 * math.pi / length;
      final wLenRe = math.cos(angle);
      final wLenIm = math.sin(angle);

      for (var i = 0; i < n; i += length) {
        var wRe = 1.0;
        var wIm = 0.0;
        final half = length >> 1;

        for (var k = 0; k < half; k++) {
          final even = i + k;
          final odd = even + half;
          final oddRe = re[odd] * wRe - im[odd] * wIm;
          final oddIm = re[odd] * wIm + im[odd] * wRe;
          final evenRe = re[even];
          final evenIm = im[even];

          re[even] = evenRe + oddRe;
          im[even] = evenIm + oddIm;
          re[odd] = evenRe - oddRe;
          im[odd] = evenIm - oddIm;

          final nextWRe = wRe * wLenRe - wIm * wLenIm;
          wIm = wRe * wLenIm + wIm * wLenRe;
          wRe = nextWRe;
        }
      }
    }

    const outputBins = 256;
    const merge = n ~/ outputBins;
    final output = Float32List(outputBins);
    final normDb = 20 * math.log(n) / math.ln10;

    for (var out = 0; out < outputBins; out++) {
      var maxPowerDb = -160.0;
      for (var m = 0; m < merge; m++) {
        final shiftedIndex = (out * merge + m + n ~/ 2) % n;
        final magnitude = math.sqrt(
          re[shiftedIndex] * re[shiftedIndex] +
              im[shiftedIndex] * im[shiftedIndex],
        );
        final db = 20 * math.log(magnitude + 1e-12) / math.ln10 - normDb;
        if (db > maxPowerDb) {
          maxPowerDb = db;
        }
      }
      output[out] = maxPowerDb;
    }

    return output;
  }

  Future<void> dispose() async {
    await disconnect();
    await _subscription?.cancel();
    await _spectrumController.close();
    await _stateController.close();
  }
}
