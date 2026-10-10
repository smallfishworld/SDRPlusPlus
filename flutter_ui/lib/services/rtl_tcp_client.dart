import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'android_usb_service.dart';
import 'sdr_dsp_worker.dart';

enum RtlTcpConnectionState {
  disconnected,
  connecting,
  connected,
  error,
}

enum ReceiverSourceKind {
  rtlTcp,
  file,
  network,
  sdrppServer,
  spyServer,
  rtlSdrUsb,
  rfspace,
  hermes,
  spectranHttp,
  soapy,
}

class RtlTcpClient {
  RtlTcpClient() {
    _nativeStateSubscription = _dsp.sourceStateStream.listen((state) {
      if (!_nativeSourceActive) {
        return;
      }
      if (state.connected) {
        _setState(RtlTcpConnectionState.connected);
        return;
      }
      _lastError = state.error;
      _nativeSourceActive = false;
      _setState(
        state.error.isEmpty
            ? RtlTcpConnectionState.disconnected
            : RtlTcpConnectionState.error,
      );
    });
  }

  final SdrDspWorker _dsp = SdrDspWorker();
  Socket? _socket;
  StreamSubscription<Uint8List>? _subscription;
  StreamSubscription<({bool connected, String error})>?
      _nativeStateSubscription;
  final _stateController = StreamController<RtlTcpConnectionState>.broadcast();
  BytesBuilder _iqBuffer = BytesBuilder(copy: false);
  static const int _iqBatchBytes = 64 * 1024;

  RtlTcpConnectionState _state = RtlTcpConnectionState.disconnected;
  String _lastError = '';
  int _headerBytesRemaining = 12;
  int _frequencyHz = 127250000;
  int _sampleRateHz = 2400000;
  String _mode = 'AM';
  double _bandwidthHz = 10000;
  bool _nativeSourceActive = false;
  ReceiverSourceKind _sourceKind = ReceiverSourceKind.rtlTcp;
  String _filePath = '';
  String _soapyDriver = '';
  String _soapyHardware = '';
  bool _soapyUsbOpen = false;

  RtlTcpConnectionState get state => _state;
  String get lastError => _lastError;
  int get frequencyHz => _frequencyHz;
  int get sampleRateHz => _sampleRateHz;
  String get mode => _mode;
  double get bandwidthHz => _bandwidthHz;
  bool get usingNativeSource => _nativeSourceActive;
  ReceiverSourceKind get sourceKind => _sourceKind;
  String get filePath => _filePath;
  String get soapyDriver => _soapyDriver;
  String get soapyHardware => _soapyHardware;

  Stream<Float32List> get spectrumStream => _dsp.spectrumStream;
  Stream<Uint8List> get audioStream => _dsp.audioStream;
  Stream<String> get backendStream => _dsp.backendStream;
  Stream<({String programService, String radioText})> get rdsStream =>
      _dsp.rdsStream;
  Stream<({int toneIndex, double toneHz})> get ctcssStream =>
      _dsp.ctcssStream;
  Stream<RtlTcpConnectionState> get stateStream => _stateController.stream;

  Future<void> connect({
    required String host,
    required int port,
    int sampleRateHz = 2400000,
    int frequencyHz = 127250000,
    String mode = 'AM',
    double bandwidthHz = 10000,
  }) async {
    await disconnect();
    await _dsp.start();
    _sourceKind = ReceiverSourceKind.rtlTcp;
    _filePath = '';

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

    final nativeResult = await _dsp.connectRtlTcpSource(
      host: host,
      port: port,
      sampleRateHz: _sampleRateHz,
      frequencyHz: _frequencyHz,
    );
    if (nativeResult.ok) {
      _nativeSourceActive = true;
      _setState(RtlTcpConnectionState.connected);
      return;
    }

    // Keep the old Dart transport as a compatibility fallback for platforms
    // where the native source runtime is not packaged yet.
    _nativeSourceActive = false;
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

  Future<void> openFile({
    required String path,
    bool float32Mode = false,
    int centerFrequencyHz = 0,
    String mode = 'AM',
    double bandwidthHz = 10000,
  }) async {
    await disconnect();
    await _dsp.start();

    _setState(RtlTcpConnectionState.connecting);
    _lastError = '';
    _sourceKind = ReceiverSourceKind.file;
    _filePath = path;
    _mode = mode;
    _bandwidthHz = bandwidthHz;

    _dsp.setMode(_mode);
    _dsp.setBandwidth(_bandwidthHz);

    final result = await _dsp.openFileSource(
      path: path,
      float32Mode: float32Mode,
      centerFrequencyHz: centerFrequencyHz,
    );

    if (!result.ok) {
      _lastError = result.error;
      _nativeSourceActive = false;
      _setState(RtlTcpConnectionState.error);
      throw StateError(
        result.error.isEmpty
            ? 'Could not open IQ file'
            : result.error,
      );
    }

    _nativeSourceActive = true;
    _sampleRateHz = result.sampleRateHz;
    _frequencyHz = result.centerFrequencyHz;
    _dsp.setSampleRate(_sampleRateHz);
    _dsp.setMode(_mode);
    _dsp.setBandwidth(_bandwidthHz);
    _setState(RtlTcpConnectionState.connected);
  }

  Future<void> connectNetwork({
    required String host,
    required int port,
    required int sampleRateHz,
    required int protocol,
    required int sampleType,
    int centerFrequencyHz = 0,
    String mode = 'AM',
    double bandwidthHz = 10000,
  }) async {
    await disconnect();
    await _dsp.start();

    _setState(RtlTcpConnectionState.connecting);
    _lastError = '';
    _sourceKind = ReceiverSourceKind.network;
    _filePath = '';
    _mode = mode;
    _bandwidthHz = bandwidthHz;

    _dsp.setMode(_mode);
    _dsp.setBandwidth(_bandwidthHz);

    final result = await _dsp.connectNetworkSource(
      host: host,
      port: port,
      sampleRateHz: sampleRateHz,
      protocol: protocol,
      sampleType: sampleType,
      centerFrequencyHz: centerFrequencyHz,
    );

    if (!result.ok) {
      _lastError = result.error;
      _nativeSourceActive = false;
      _setState(RtlTcpConnectionState.error);
      throw StateError(
        result.error.isEmpty
            ? 'Could not connect Network Source'
            : result.error,
      );
    }

    _nativeSourceActive = true;
    _sampleRateHz = result.sampleRateHz;
    _frequencyHz = result.centerFrequencyHz;
    _dsp.setSampleRate(_sampleRateHz);
    _dsp.setMode(_mode);
    _dsp.setBandwidth(_bandwidthHz);
    _setState(RtlTcpConnectionState.connected);
  }

  Future<void> connectRfspace({
    required String host,
    required int port,
    required int sampleRateHz,
    required int frequencyHz,
    required int gainDb,
    String mode = 'AM',
    double bandwidthHz = 10000,
  }) async {
    await _connectNativeRemoteSource(
      kind: ReceiverSourceKind.rfspace,
      mode: mode,
      bandwidthHz: bandwidthHz,
      connect: () => _dsp.connectRfspaceSource(
        host: host,
        port: port,
        sampleRateHz: sampleRateHz,
        frequencyHz: frequencyHz,
        gainDb: gainDb,
      ),
    );
  }

  Future<void> connectHermes({
    required String host,
    required int port,
    required int sampleRateHz,
    required int frequencyHz,
    required int gainDb,
    String mode = 'AM',
    double bandwidthHz = 10000,
  }) async {
    await _connectNativeRemoteSource(
      kind: ReceiverSourceKind.hermes,
      mode: mode,
      bandwidthHz: bandwidthHz,
      connect: () => _dsp.connectHermesSource(
        host: host,
        port: port,
        sampleRateHz: sampleRateHz,
        frequencyHz: frequencyHz,
        gainDb: gainDb,
      ),
    );
  }

  Future<void> connectSpectranHttp({
    required String host,
    required int port,
    required int frequencyHz,
    String mode = 'AM',
    double bandwidthHz = 10000,
  }) async {
    await _connectNativeRemoteSource(
      kind: ReceiverSourceKind.spectranHttp,
      mode: mode,
      bandwidthHz: bandwidthHz,
      connect: () => _dsp.connectSpectranHttpSource(
        host: host,
        port: port,
        frequencyHz: frequencyHz,
      ),
    );
  }

  Future<void> _connectNativeRemoteSource({
    required ReceiverSourceKind kind,
    required String mode,
    required double bandwidthHz,
    required Future<({
      bool ok,
      String error,
      int sampleRateHz,
      int centerFrequencyHz,
    })> Function() connect,
  }) async {
    await disconnect();
    await _dsp.start();

    _setState(RtlTcpConnectionState.connecting);
    _lastError = '';
    _sourceKind = kind;
    _filePath = '';
    _mode = mode;
    _bandwidthHz = bandwidthHz;
    _dsp.setMode(_mode);
    _dsp.setBandwidth(_bandwidthHz);

    final result = await connect();
    if (!result.ok) {
      _lastError = result.error;
      _nativeSourceActive = false;
      _setState(RtlTcpConnectionState.error);
      throw StateError(
        result.error.isEmpty
            ? 'Could not connect native SDR source'
            : result.error,
      );
    }

    _nativeSourceActive = true;
    _sampleRateHz = result.sampleRateHz;
    _frequencyHz = result.centerFrequencyHz;
    _dsp.setSampleRate(_sampleRateHz);
    _dsp.setMode(_mode);
    _dsp.setBandwidth(_bandwidthHz);
    _setState(RtlTcpConnectionState.connected);
  }

  Future<List<String>> enumerateSoapy({
    String filter = '',
  }) async {
    await _dsp.start();
    return _dsp.enumerateSoapy(filter: filter);
  }

  Future<void> connectSoapy({
    required String deviceArgs,
    required int sampleRateHz,
    required int frequencyHz,
    required double rfBandwidthHz,
    required double gainDb,
    required bool agc,
    int channel = 0,
    String mode = 'AM',
    double bandwidthHz = 10000,
    bool preserveUsbHandle = false,
  }) async {
    if (!preserveUsbHandle) {
      await disconnect();
    } else {
      if (_nativeSourceActive) {
        _dsp.disconnectSource();
        _nativeSourceActive = false;
      }
      final subscription = _subscription;
      _subscription = null;
      await subscription?.cancel();
      _socket?.destroy();
      _socket = null;
      _iqBuffer = BytesBuilder(copy: false);
      _dsp.reset();
      _setState(RtlTcpConnectionState.disconnected);
    }
    await _dsp.start();

    _setState(RtlTcpConnectionState.connecting);
    _lastError = '';
    _sourceKind = ReceiverSourceKind.soapy;
    _filePath = '';
    _soapyDriver = '';
    _soapyHardware = '';
    _mode = mode;
    _bandwidthHz = bandwidthHz;

    _dsp.setMode(_mode);
    _dsp.setBandwidth(_bandwidthHz);

    final result = await _dsp.connectSoapySource(
      deviceArgs: deviceArgs,
      sampleRateHz: sampleRateHz,
      frequencyHz: frequencyHz,
      rfBandwidthHz: rfBandwidthHz,
      gainDb: gainDb,
      agc: agc,
      channel: channel,
    );

    if (!result.ok) {
      _lastError = result.error;
      _nativeSourceActive = false;
      _setState(RtlTcpConnectionState.error);
      throw StateError(
        result.error.isEmpty
            ? 'Could not open SoapySDR device'
            : result.error,
      );
    }

    _nativeSourceActive = true;
    _sampleRateHz = result.sampleRateHz;
    _frequencyHz = result.centerFrequencyHz;
    _soapyDriver = result.driver;
    _soapyHardware = result.hardware;
    _dsp.setSampleRate(_sampleRateHz);
    _dsp.setMode(_mode);
    _dsp.setBandwidth(_bandwidthHz);
    _setState(RtlTcpConnectionState.connected);
  }

  Future<void> connectSoapyUsb({
    required String deviceName,
    required String driver,
    required int sampleRateHz,
    required int frequencyHz,
    required double rfBandwidthHz,
    required double gainDb,
    required bool agc,
    int channel = 0,
    String mode = 'AM',
    double bandwidthHz = 10000,
  }) async {
    await disconnect();

    final opened = await AndroidUsbService.openSdrUsb(deviceName);
    if (opened == null) {
      _lastError = 'USB permission denied or SDR device could not be opened';
      _setState(RtlTcpConnectionState.error);
      throw StateError(_lastError);
    }

    final actualDriver =
        opened.driver == 'unknown' ? driver : opened.driver;
    final args = 'driver=$actualDriver,fd=${opened.fd}';

    try {
      _soapyUsbOpen = true;
      await connectSoapy(
        deviceArgs: args,
        sampleRateHz: sampleRateHz,
        frequencyHz: frequencyHz,
        rfBandwidthHz: rfBandwidthHz,
        gainDb: gainDb,
        agc: agc,
        channel: channel,
        mode: mode,
        bandwidthHz: bandwidthHz,
        preserveUsbHandle: true,
      );
    } catch (_) {
      _soapyUsbOpen = false;
      await AndroidUsbService.closeSdrUsb();
      rethrow;
    }
  }

  Future<void> connectRtlSdrUsb({
    required String deviceName,
    int sampleRateHz = 2400000,
    int frequencyHz = 127250000,
    String mode = 'AM',
    double bandwidthHz = 10000,
  }) async {
    await disconnect();
    await _dsp.start();

    _setState(RtlTcpConnectionState.connecting);
    _lastError = '';
    _sourceKind = ReceiverSourceKind.rtlSdrUsb;
    _filePath = '';
    _mode = mode;
    _bandwidthHz = bandwidthHz;

    final opened = await AndroidUsbService.openRtlSdr(deviceName);
    if (opened == null) {
      _lastError =
          'USB permission denied or RTL-SDR could not be opened';
      _setState(RtlTcpConnectionState.error);
      throw StateError(_lastError);
    }

    _dsp.setMode(_mode);
    _dsp.setBandwidth(_bandwidthHz);

    final result = await _dsp.connectRtlSdrUsbSource(
      systemFd: opened.fd,
      sampleRateHz: sampleRateHz,
      frequencyHz: frequencyHz,
    );

    if (!result.ok) {
      await AndroidUsbService.closeRtlSdr();
      _lastError = result.error;
      _nativeSourceActive = false;
      _setState(RtlTcpConnectionState.error);
      throw StateError(
        result.error.isEmpty
            ? 'Could not open RTL-SDR USB'
            : result.error,
      );
    }

    _nativeSourceActive = true;
    _sampleRateHz = result.sampleRateHz;
    _frequencyHz = result.centerFrequencyHz;
    _dsp.setSampleRate(_sampleRateHz);
    _dsp.setMode(_mode);
    _dsp.setBandwidth(_bandwidthHz);
    _setState(RtlTcpConnectionState.connected);
  }

  Future<void> connectSdrppServer({
    required String host,
    required int port,
    int frequencyHz = 127250000,
    String mode = 'AM',
    double bandwidthHz = 10000,
  }) async {
    await disconnect();
    await _dsp.start();

    _setState(RtlTcpConnectionState.connecting);
    _lastError = '';
    _sourceKind = ReceiverSourceKind.sdrppServer;
    _filePath = '';
    _mode = mode;
    _bandwidthHz = bandwidthHz;

    _dsp.setMode(_mode);
    _dsp.setBandwidth(_bandwidthHz);

    final result = await _dsp.connectSdrppServerSource(
      host: host,
      port: port,
      frequencyHz: frequencyHz,
    );

    if (!result.ok) {
      _lastError = result.error;
      _nativeSourceActive = false;
      _setState(RtlTcpConnectionState.error);
      throw StateError(
        result.error.isEmpty
            ? 'Could not connect SDR++ Server'
            : result.error,
      );
    }

    _nativeSourceActive = true;
    _sampleRateHz = result.sampleRateHz;
    _frequencyHz = result.centerFrequencyHz;
    _dsp.setSampleRate(_sampleRateHz);
    _dsp.setMode(_mode);
    _dsp.setBandwidth(_bandwidthHz);
    _setState(RtlTcpConnectionState.connected);
  }

  Future<void> connectSpyServer({
    required String host,
    required int port,
    required int sampleRateHz,
    int frequencyHz = 127250000,
    String mode = 'AM',
    double bandwidthHz = 10000,
  }) async {
    await disconnect();
    await _dsp.start();

    _setState(RtlTcpConnectionState.connecting);
    _lastError = '';
    _sourceKind = ReceiverSourceKind.spyServer;
    _filePath = '';
    _mode = mode;
    _bandwidthHz = bandwidthHz;

    _dsp.setMode(_mode);
    _dsp.setBandwidth(_bandwidthHz);

    final result = await _dsp.connectSpyServerSource(
      host: host,
      port: port,
      sampleRateHz: sampleRateHz,
      frequencyHz: frequencyHz,
    );

    if (!result.ok) {
      _lastError = result.error;
      _nativeSourceActive = false;
      _setState(RtlTcpConnectionState.error);
      throw StateError(
        result.error.isEmpty
            ? 'Could not connect SpyServer'
            : result.error,
      );
    }

    _nativeSourceActive = true;
    _sampleRateHz = result.sampleRateHz;
    _frequencyHz = result.centerFrequencyHz;
    _dsp.setSampleRate(_sampleRateHz);
    _dsp.setMode(_mode);
    _dsp.setBandwidth(_bandwidthHz);
    _setState(RtlTcpConnectionState.connected);
  }

  Future<void> disconnect() async {
    if (_nativeSourceActive) {
      _dsp.disconnectSource();
      _nativeSourceActive = false;
    }

    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    _socket?.destroy();
    _socket = null;
    _iqBuffer = BytesBuilder(copy: false);
    _dsp.reset();
    if (_sourceKind != ReceiverSourceKind.soapy) {
      _soapyDriver = '';
      _soapyHardware = '';
    }
    if (_sourceKind == ReceiverSourceKind.rtlSdrUsb) {
      await AndroidUsbService.closeRtlSdr();
    }
    if (_soapyUsbOpen) {
      _soapyUsbOpen = false;
      await AndroidUsbService.closeSdrUsb();
    }
    _setState(RtlTcpConnectionState.disconnected);
  }

  void setFrequency(int frequencyHz) {
    _frequencyHz = frequencyHz;
    if (_nativeSourceActive) {
      _dsp.sourceSetFrequency(frequencyHz);
    } else if (_state == RtlTcpConnectionState.connected) {
      _sendCommand(1, frequencyHz);
      _iqBuffer = BytesBuilder(copy: false);
      _dsp.reset();
    }
  }

  void setSampleRate(int sampleRateHz) {
    if (_sourceKind == ReceiverSourceKind.file ||
        _sourceKind == ReceiverSourceKind.sdrppServer) {
      return;
    }
    _sampleRateHz = sampleRateHz;
    _dsp.setSampleRate(sampleRateHz);
    if (_nativeSourceActive) {
      _dsp.sourceSetSampleRate(sampleRateHz);
    } else if (_state == RtlTcpConnectionState.connected) {
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

  void setFrequencyOffset(double offsetHz) {
    _dsp.setFrequencyOffset(offsetHz);
  }

  void setTunerAgc(bool enabled) {
    if (_nativeSourceActive) {
      _dsp.sourceSetTunerAgc(enabled);
    } else if (_state == RtlTcpConnectionState.connected) {
      _sendCommand(3, enabled ? 0 : 1);
    }
  }

  void setGainDb(double gainDb) {
    if (_nativeSourceActive) {
      _dsp.sourceSetTunerAgc(false);
      _dsp.sourceSetGainDb(gainDb);
    } else if (_state == RtlTcpConnectionState.connected) {
      _sendCommand(3, 1);
      _sendCommand(4, (gainDb * 10).round());
    }
  }

  void setGainIndex(int index) {
    if (_nativeSourceActive) {
      _dsp.sourceSetGainIndex(index);
    } else if (_state == RtlTcpConnectionState.connected) {
      _sendCommand(13, index);
    }
  }

  void setPpm(int ppm) {
    if (_nativeSourceActive) {
      _dsp.sourceSetPpm(ppm);
    } else if (_state == RtlTcpConnectionState.connected) {
      _sendCommand(5, ppm);
    }
  }

  void setRtlAgc(bool enabled) {
    if (_nativeSourceActive) {
      _dsp.sourceSetRtlAgc(enabled);
    } else if (_state == RtlTcpConnectionState.connected) {
      _sendCommand(8, enabled ? 1 : 0);
    }
  }

  void setDirectSampling(int mode) {
    if (_nativeSourceActive) {
      _dsp.sourceSetDirectSampling(mode.clamp(0, 2).toInt());
    } else if (_state == RtlTcpConnectionState.connected) {
      _sendCommand(9, mode.clamp(0, 2).toInt());
    }
  }

  void setOffsetTuning(bool enabled) {
    if (_nativeSourceActive) {
      _dsp.sourceSetOffsetTuning(enabled);
    } else if (_state == RtlTcpConnectionState.connected) {
      _sendCommand(10, enabled ? 1 : 0);
    }
  }

  void setBiasTee(bool enabled) {
    if (_nativeSourceActive) {
      _dsp.sourceSetBiasTee(enabled);
    } else if (_state == RtlTcpConnectionState.connected) {
      _sendCommand(14, enabled ? 1 : 0);
    }
  }

  void setRfBandwidth(double bandwidthHz) {
    if (_nativeSourceActive) {
      _dsp.sourceSetRfBandwidth(bandwidthHz);
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

  void setCtcss(int mode, int toneIndex) {
    _dsp.setCtcss(mode, toneIndex);
  }

  void setFmIfNr(bool enabled, int preset) {
    _dsp.setFmIfNr(enabled, preset);
  }

  void setAmAgc(bool carrier, double attackMs, double decayMs) {
    _dsp.setAmAgc(carrier, attackMs, decayMs);
  }

  void setSsbAgc(double attackMs, double decayMs) {
    _dsp.setSsbAgc(attackMs, decayMs);
  }

  void setCwOptions(int toneHz, double attackMs, double decayMs) {
    _dsp.setCwOptions(toneHz, attackMs, decayMs);
  }

  void setNfmOptions(bool lowPass) {
    _dsp.setNfmOptions(lowPass);
  }

  void setNfmVoiceFilter(bool enabled) {
    _dsp.setNfmVoiceFilter(enabled);
  }

  void setWfmOptions(bool stereo, bool lowPass, bool rdsEnabled) {
    _dsp.setWfmOptions(stereo, lowPass, rdsEnabled);
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
    await _nativeStateSubscription?.cancel();
    _nativeStateSubscription = null;
    await _dsp.dispose();
    await _stateController.close();
  }
}
