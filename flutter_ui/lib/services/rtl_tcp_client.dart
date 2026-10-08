import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'sdr_dsp_worker.dart';

enum RtlTcpConnectionState {
  disconnected,
  connecting,
  connected,
  error,
}

class RtlTcpClient {
  final SdrDspWorker _dsp = SdrDspWorker();
  Socket? _socket;
  StreamSubscription<Uint8List>? _subscription;
  final _stateController = StreamController<RtlTcpConnectionState>.broadcast();
  BytesBuilder _iqBuffer = BytesBuilder(copy: false);
  static const int _iqBatchBytes = 64 * 1024;

  RtlTcpConnectionState _state = RtlTcpConnectionState.disconnected;
  String _lastError = '';
  int _headerBytesRemaining = 12;
  int _frequencyHz = 127250000;
  int _sampleRateHz = 1024000;
  String _mode = 'AM';
  double _bandwidthHz = 10000;

  RtlTcpConnectionState get state => _state;
  String get lastError => _lastError;
  int get frequencyHz => _frequencyHz;
  int get sampleRateHz => _sampleRateHz;
  String get mode => _mode;
  double get bandwidthHz => _bandwidthHz;

  Stream<Float32List> get spectrumStream => _dsp.spectrumStream;
  Stream<Uint8List> get audioStream => _dsp.audioStream;
  Stream<String> get backendStream => _dsp.backendStream;
  Stream<RtlTcpConnectionState> get stateStream => _stateController.stream;

  Future<void> connect({
    required String host,
    required int port,
    int sampleRateHz = 1024000,
    int frequencyHz = 127250000,
    String mode = 'AM',
    double bandwidthHz = 10000,
  }) async {
    await disconnect();
    await _dsp.start();

    _setState(RtlTcpConnectionState.connecting);
    _lastError = '';
    _headerBytesRemaining = 12;
    _iqBuffer = BytesBuilder(copy: false);
    _frequencyHz = frequencyHz;
    _sampleRateHz = sampleRateHz;
    _mode = mode;
    _bandwidthHz = bandwidthHz;

    _dsp.configure(
      sampleRateHz: _sampleRateHz,
      mode: _mode,
      bandwidthHz: _bandwidthHz,
    );

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
      _sendCommand(3, 0);
      _sendCommand(8, 0);
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
    _iqBuffer = BytesBuilder(copy: false);
    _dsp.reset();
    _setState(RtlTcpConnectionState.disconnected);
  }

  void setFrequency(int frequencyHz) {
    _frequencyHz = frequencyHz;
    if (_state == RtlTcpConnectionState.connected) {
      _sendCommand(1, frequencyHz);
    }
    // Drop IQ already accumulated for the old channel and reset the complete
    // DSP state after issuing the tuner command. The UI also debounces an
    // audio-stream restart after interactive retuning.
    _iqBuffer = BytesBuilder(copy: false);
    _dsp.reset();
  }

  void setSampleRate(int sampleRateHz) {
    _sampleRateHz = sampleRateHz;
    _dsp.setSampleRate(sampleRateHz);
    if (_state == RtlTcpConnectionState.connected) {
      _sendCommand(2, sampleRateHz);
    }
  }

  void setMode(String mode) {
    _mode = mode;
    _dsp.setMode(mode);
  }

  void setBandwidth(double bandwidthHz) {
    _bandwidthHz = bandwidthHz;
    _dsp.setBandwidth(bandwidthHz);
  }

  void setTunerAgc(bool enabled) {
    if (_state == RtlTcpConnectionState.connected) {
      _sendCommand(3, enabled ? 0 : 1);
    }
  }

  void setGainDb(double gainDb) {
    if (_state == RtlTcpConnectionState.connected) {
      _sendCommand(3, 1);
      _sendCommand(4, (gainDb * 10).round());
    }
  }

  void setGainIndex(int index) {
    if (_state == RtlTcpConnectionState.connected) {
      _sendCommand(13, index);
    }
  }

  void setPpm(int ppm) {
    if (_state == RtlTcpConnectionState.connected) {
      _sendCommand(5, ppm);
    }
  }

  void setRtlAgc(bool enabled) {
    if (_state == RtlTcpConnectionState.connected) {
      _sendCommand(8, enabled ? 1 : 0);
    }
  }

  void setDirectSampling(int mode) {
    if (_state == RtlTcpConnectionState.connected) {
      _sendCommand(9, mode.clamp(0, 2).toInt());
    }
  }

  void setOffsetTuning(bool enabled) {
    if (_state == RtlTcpConnectionState.connected) {
      _sendCommand(10, enabled ? 1 : 0);
    }
  }

  void setBiasTee(bool enabled) {
    if (_state == RtlTcpConnectionState.connected) {
      _sendCommand(14, enabled ? 1 : 0);
    }
  }

  void setSquelch(bool enabled, double thresholdDb) {
    _dsp.setSquelch(enabled, thresholdDb);
  }

  void setNoiseBlanker(bool enabled, double level) {
    _dsp.setNoiseBlanker(enabled, level);
  }

  void setHighPass(bool enabled) {
    _dsp.setHighPass(enabled);
  }

  void setDeemphasis(int modeUs) {
    _dsp.setDeemphasis(modeUs);
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
      ..setUint32(1, parameter & 0xFFFFFFFF, Endian.big);
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

    if (data.isEmpty) {
      return;
    }

    // TCP packet boundaries do not match IQ sample boundaries. Buffer into
    // larger even-sized blocks so I/Q pairs never lose alignment and the DSP
    // isolate is not flooded with tiny messages.
    _iqBuffer.add(data);
    if (_iqBuffer.length < _iqBatchBytes) {
      return;
    }

    final batch = _iqBuffer.takeBytes();
    _iqBuffer = BytesBuilder(copy: false);
    final evenLength = batch.length & ~1;
    if (evenLength > 0) {
      _dsp.addIq(Uint8List.sublistView(batch, 0, evenLength));
    }
    if (evenLength != batch.length) {
      _iqBuffer.addByte(batch.last);
    }
  }

  Future<void> dispose() async {
    await disconnect();
    await _dsp.dispose();
    await _stateController.close();
  }
}
