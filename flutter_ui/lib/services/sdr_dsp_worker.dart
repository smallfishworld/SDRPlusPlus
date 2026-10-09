import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'native_dsp_bridge.dart';
import 'native_source_bridge.dart';

class SdrDspWorker {
  Isolate? _isolate;
  ReceivePort? _receivePort;
  StreamSubscription<dynamic>? _receiveSubscription;
  SendPort? _commandPort;

  final StreamController<Float32List> _spectrumController =
      StreamController<Float32List>.broadcast();
  final StreamController<Uint8List> _audioController =
      StreamController<Uint8List>.broadcast();
  final StreamController<String> _backendController =
      StreamController<String>.broadcast();
  final StreamController<({String programService, String radioText})>
      _rdsController =
      StreamController<({String programService, String radioText})>.broadcast();
  final StreamController<({int toneIndex, double toneHz})>
      _ctcssController =
      StreamController<({int toneIndex, double toneHz})>.broadcast();
  final StreamController<({bool connected, String error})>
      _sourceStateController =
      StreamController<({bool connected, String error})>.broadcast();

  Stream<Float32List> get spectrumStream => _spectrumController.stream;
  Stream<Uint8List> get audioStream => _audioController.stream;
  Stream<String> get backendStream => _backendController.stream;
  Stream<({String programService, String radioText})> get rdsStream =>
      _rdsController.stream;
  Stream<({int toneIndex, double toneHz})> get ctcssStream =>
      _ctcssController.stream;
  Stream<({bool connected, String error})> get sourceStateStream =>
      _sourceStateController.stream;

  Future<void> start() async {
    if (_commandPort != null) {
      return;
    }

    final ready = Completer<SendPort>();
    final receivePort = ReceivePort();
    _receivePort = receivePort;

    _receiveSubscription = receivePort.listen((message) {
      if (message is SendPort) {
        if (!ready.isCompleted) {
          ready.complete(message);
        }
        return;
      }

      if (message is! Map<Object?, Object?>) {
        return;
      }

      final type = message['type'];
      if (type == 'backend') {
        final name = message['name'];
        if (name is String && !_backendController.isClosed) {
          _backendController.add(name);
        }
        return;
      }

      if (type == 'sourceState') {
        final connected = message['connected'];
        final error = message['error'];
        if (connected is bool &&
            error is String &&
            !_sourceStateController.isClosed) {
          _sourceStateController.add(
            (connected: connected, error: error),
          );
        }
        return;
      }

      if (type == 'rds') {
        final ps = message['programService'];
        final rt = message['radioText'];
        if (ps is String && rt is String && !_rdsController.isClosed) {
          _rdsController.add((programService: ps, radioText: rt));
        }
        return;
      }

      if (type == 'ctcss') {
        final toneIndex = message['toneIndex'];
        final toneHz = message['toneHz'];
        if (toneIndex is int &&
            toneHz is num &&
            !_ctcssController.isClosed) {
          _ctcssController.add((
            toneIndex: toneIndex,
            toneHz: toneHz.toDouble(),
          ));
        }
        return;
      }

      final payload = message['data'];
      if (payload is! TransferableTypedData) {
        return;
      }

      final bytes = payload.materialize().asUint8List();
      if (type == 'spectrum') {
        final aligned = Uint8List.fromList(bytes);
        final frame = Float32List.view(
          aligned.buffer,
          aligned.offsetInBytes,
          aligned.lengthInBytes ~/ Float32List.bytesPerElement,
        );
        if (!_spectrumController.isClosed) {
          _spectrumController.add(Float32List.fromList(frame));
        }
      } else if (type == 'audio') {
        if (!_audioController.isClosed) {
          _audioController.add(Uint8List.fromList(bytes));
        }
      }
    });

    _isolate = await Isolate.spawn(_sdrDspWorkerMain, receivePort.sendPort);
    _commandPort = await ready.future.timeout(const Duration(seconds: 3));
  }

  void configure({
    required int sampleRateHz,
    required String mode,
    required double bandwidthHz,
  }) {
    _commandPort?.send(<String, Object>{
      'type': 'config',
      'sampleRateHz': sampleRateHz,
      'mode': mode,
      'bandwidthHz': bandwidthHz,
    });
  }

  void setMode(String mode) {
    _commandPort?.send(<String, Object>{
      'type': 'mode',
      'mode': mode,
    });
  }

  void setBandwidth(double bandwidthHz) {
    _commandPort?.send(<String, Object>{
      'type': 'bandwidth',
      'bandwidthHz': bandwidthHz,
    });
  }

  void setSampleRate(int sampleRateHz) {
    _commandPort?.send(<String, Object>{
      'type': 'sampleRate',
      'sampleRateHz': sampleRateHz,
    });
  }

  void setSquelch(bool enabled, double thresholdDb) {
    _commandPort?.send(<String, Object>{
      'type': 'squelch',
      'enabled': enabled,
      'thresholdDb': thresholdDb,
    });
  }

  void setNoiseBlanker(bool enabled, double level) {
    _commandPort?.send(<String, Object>{
      'type': 'noiseBlanker',
      'enabled': enabled,
      'level': level,
    });
  }

  void setHighPass(bool enabled) {
    _commandPort?.send(<String, Object>{
      'type': 'highPass',
      'enabled': enabled,
    });
  }

  void setDeemphasis(int modeUs) {
    _commandPort?.send(<String, Object>{
      'type': 'deemphasis',
      'modeUs': modeUs,
    });
  }

  void setCtcss(int mode, int toneIndex) {
    _commandPort?.send(<String, Object>{
      'type': 'ctcss',
      'mode': mode,
      'toneIndex': toneIndex,
    });
  }

  void setFmIfNr(bool enabled, int preset) {
    _commandPort?.send(<String, Object>{
      'type': 'fmIfNr',
      'enabled': enabled,
      'preset': preset,
    });
  }

  void setAmAgc(bool carrier, double attackMs, double decayMs) {
    _commandPort?.send(<String, Object>{
      'type': 'amAgc',
      'carrier': carrier,
      'attackMs': attackMs,
      'decayMs': decayMs,
    });
  }

  void setSsbAgc(double attackMs, double decayMs) {
    _commandPort?.send(<String, Object>{
      'type': 'ssbAgc',
      'attackMs': attackMs,
      'decayMs': decayMs,
    });
  }

  void setCwOptions(int toneHz, double attackMs, double decayMs) {
    _commandPort?.send(<String, Object>{
      'type': 'cwOptions',
      'toneHz': toneHz,
      'attackMs': attackMs,
      'decayMs': decayMs,
    });
  }

  void setNfmOptions(bool lowPass) {
    _commandPort?.send(<String, Object>{
      'type': 'nfmOptions',
      'lowPass': lowPass,
    });
  }

  void setNfmVoiceFilter(bool enabled) {
    _commandPort?.send(<String, Object>{
      'type': 'nfmVoiceFilter',
      'enabled': enabled,
    });
  }

  void setWfmOptions(bool stereo, bool lowPass, bool rdsEnabled) {
    _commandPort?.send(<String, Object>{
      'type': 'wfmOptions',
      'stereo': stereo,
      'lowPass': lowPass,
      'rdsEnabled': rdsEnabled,
    });
  }

  Future<({bool ok, String error})> connectRtlTcpSource({
    required String host,
    required int port,
    required int sampleRateHz,
    required int frequencyHz,
  }) async {
    await start();
    final commandPort = _commandPort;
    if (commandPort == null) {
      return (ok: false, error: 'DSP worker unavailable');
    }

    final reply = ReceivePort();
    commandPort.send(<String, Object>{
      'type': 'sourceConnect',
      'host': host,
      'port': port,
      'sampleRateHz': sampleRateHz,
      'frequencyHz': frequencyHz,
      'reply': reply.sendPort,
    });

    try {
      final result = await reply.first.timeout(
        const Duration(seconds: 8),
      );
      if (result is Map<Object?, Object?>) {
        return (
          ok: result['ok'] == true,
          error: result['error'] as String? ?? '',
        );
      }
      return (ok: false, error: 'Invalid native source response');
    } on TimeoutException {
      return (ok: false, error: 'RTL-TCP native connection timed out');
    } finally {
      reply.close();
    }
  }

  Future<({
    bool ok,
    String error,
    int sampleRateHz,
    int centerFrequencyHz,
  })> openFileSource({
    required String path,
    required bool float32Mode,
    int centerFrequencyHz = 0,
  }) async {
    await start();
    final commandPort = _commandPort;
    if (commandPort == null) {
      return (
        ok: false,
        error: 'DSP worker unavailable',
        sampleRateHz: 0,
        centerFrequencyHz: 0,
      );
    }

    final reply = ReceivePort();
    commandPort.send(<String, Object>{
      'type': 'sourceOpenFile',
      'path': path,
      'float32Mode': float32Mode,
      'centerFrequencyHz': centerFrequencyHz,
      'reply': reply.sendPort,
    });

    try {
      final result = await reply.first.timeout(
        const Duration(seconds: 5),
      );
      if (result is Map<Object?, Object?>) {
        return (
          ok: result['ok'] == true,
          error: result['error'] as String? ?? '',
          sampleRateHz: result['sampleRateHz'] as int? ?? 0,
          centerFrequencyHz:
              result['centerFrequencyHz'] as int? ?? 0,
        );
      }
      return (
        ok: false,
        error: 'Invalid native File Source response',
        sampleRateHz: 0,
        centerFrequencyHz: 0,
      );
    } on TimeoutException {
      return (
        ok: false,
        error: 'Native File Source timed out',
        sampleRateHz: 0,
        centerFrequencyHz: 0,
      );
    } finally {
      reply.close();
    }
  }

  Future<({
    bool ok,
    String error,
    int sampleRateHz,
    int centerFrequencyHz,
  })> connectNetworkSource({
    required String host,
    required int port,
    required int sampleRateHz,
    required int protocol,
    required int sampleType,
    int centerFrequencyHz = 0,
  }) async {
    await start();
    final commandPort = _commandPort;
    if (commandPort == null) {
      return (
        ok: false,
        error: 'DSP worker unavailable',
        sampleRateHz: 0,
        centerFrequencyHz: 0,
      );
    }

    final reply = ReceivePort();
    commandPort.send(<String, Object>{
      'type': 'sourceConnectNetwork',
      'host': host,
      'port': port,
      'sampleRateHz': sampleRateHz,
      'protocol': protocol,
      'sampleType': sampleType,
      'centerFrequencyHz': centerFrequencyHz,
      'reply': reply.sendPort,
    });

    try {
      final result = await reply.first.timeout(
        const Duration(seconds: 8),
      );
      if (result is Map<Object?, Object?>) {
        return (
          ok: result['ok'] == true,
          error: result['error'] as String? ?? '',
          sampleRateHz: result['sampleRateHz'] as int? ?? 0,
          centerFrequencyHz:
              result['centerFrequencyHz'] as int? ?? 0,
        );
      }
      return (
        ok: false,
        error: 'Invalid native Network Source response',
        sampleRateHz: 0,
        centerFrequencyHz: 0,
      );
    } on TimeoutException {
      return (
        ok: false,
        error: 'Native Network Source timed out',
        sampleRateHz: 0,
        centerFrequencyHz: 0,
      );
    } finally {
      reply.close();
    }
  }

  Future<({
    bool ok,
    String error,
    int sampleRateHz,
    int centerFrequencyHz,
  })> connectRtlSdrUsbSource({
    required int systemFd,
    required int sampleRateHz,
    required int frequencyHz,
  }) async {
    await start();
    final commandPort = _commandPort;
    if (commandPort == null) {
      return (
        ok: false,
        error: 'DSP worker unavailable',
        sampleRateHz: 0,
        centerFrequencyHz: 0,
      );
    }

    final reply = ReceivePort();
    commandPort.send(<String, Object>{
      'type': 'sourceConnectRtlSdrUsb',
      'systemFd': systemFd,
      'sampleRateHz': sampleRateHz,
      'frequencyHz': frequencyHz,
      'reply': reply.sendPort,
    });

    try {
      final result = await reply.first.timeout(
        const Duration(seconds: 10),
      );
      if (result is Map<Object?, Object?>) {
        return (
          ok: result['ok'] == true,
          error: result['error'] as String? ?? '',
          sampleRateHz: result['sampleRateHz'] as int? ?? 0,
          centerFrequencyHz:
              result['centerFrequencyHz'] as int? ?? 0,
        );
      }
      return (
        ok: false,
        error: 'Invalid RTL-SDR USB response',
        sampleRateHz: 0,
        centerFrequencyHz: 0,
      );
    } on TimeoutException {
      return (
        ok: false,
        error: 'RTL-SDR USB connection timed out',
        sampleRateHz: 0,
        centerFrequencyHz: 0,
      );
    } finally {
      reply.close();
    }
  }

  Future<({
    bool ok,
    String error,
    int sampleRateHz,
    int centerFrequencyHz,
  })> connectSdrppServerSource({
    required String host,
    required int port,
    required int frequencyHz,
  }) async {
    await start();
    final commandPort = _commandPort;
    if (commandPort == null) {
      return (
        ok: false,
        error: 'DSP worker unavailable',
        sampleRateHz: 0,
        centerFrequencyHz: 0,
      );
    }

    final reply = ReceivePort();
    commandPort.send(<String, Object>{
      'type': 'sourceConnectSdrppServer',
      'host': host,
      'port': port,
      'frequencyHz': frequencyHz,
      'reply': reply.sendPort,
    });

    try {
      final result = await reply.first.timeout(
        const Duration(seconds: 12),
      );
      if (result is Map<Object?, Object?>) {
        return (
          ok: result['ok'] == true,
          error: result['error'] as String? ?? '',
          sampleRateHz: result['sampleRateHz'] as int? ?? 0,
          centerFrequencyHz:
              result['centerFrequencyHz'] as int? ?? 0,
        );
      }
      return (
        ok: false,
        error: 'Invalid SDR++ Server response',
        sampleRateHz: 0,
        centerFrequencyHz: 0,
      );
    } on TimeoutException {
      return (
        ok: false,
        error: 'SDR++ Server connection timed out',
        sampleRateHz: 0,
        centerFrequencyHz: 0,
      );
    } finally {
      reply.close();
    }
  }

  Future<({
    bool ok,
    String error,
    int sampleRateHz,
    int centerFrequencyHz,
  })> connectSpyServerSource({
    required String host,
    required int port,
    required int sampleRateHz,
    required int frequencyHz,
  }) async {
    await start();
    final commandPort = _commandPort;
    if (commandPort == null) {
      return (
        ok: false,
        error: 'DSP worker unavailable',
        sampleRateHz: 0,
        centerFrequencyHz: 0,
      );
    }

    final reply = ReceivePort();
    commandPort.send(<String, Object>{
      'type': 'sourceConnectSpyServer',
      'host': host,
      'port': port,
      'sampleRateHz': sampleRateHz,
      'frequencyHz': frequencyHz,
      'reply': reply.sendPort,
    });

    try {
      final result = await reply.first.timeout(
        const Duration(seconds: 10),
      );
      if (result is Map<Object?, Object?>) {
        return (
          ok: result['ok'] == true,
          error: result['error'] as String? ?? '',
          sampleRateHz: result['sampleRateHz'] as int? ?? 0,
          centerFrequencyHz:
              result['centerFrequencyHz'] as int? ?? 0,
        );
      }
      return (
        ok: false,
        error: 'Invalid SpyServer response',
        sampleRateHz: 0,
        centerFrequencyHz: 0,
      );
    } on TimeoutException {
      return (
        ok: false,
        error: 'SpyServer connection timed out',
        sampleRateHz: 0,
        centerFrequencyHz: 0,
      );
    } finally {
      reply.close();
    }
  }

  Future<({
    bool ok,
    String error,
    int sampleRateHz,
    int centerFrequencyHz,
  })> connectRfspaceSource({
    required String host,
    required int port,
    required int sampleRateHz,
    required int frequencyHz,
    required int gainDb,
  }) =>
      _connectRemoteNativeSource(
        type: 'sourceConnectRfspace',
        arguments: <String, Object>{
          'host': host,
          'port': port,
          'sampleRateHz': sampleRateHz,
          'frequencyHz': frequencyHz,
          'gainDb': gainDb,
        },
      );

  Future<({
    bool ok,
    String error,
    int sampleRateHz,
    int centerFrequencyHz,
  })> connectHermesSource({
    required String host,
    required int port,
    required int sampleRateHz,
    required int frequencyHz,
    required int gainDb,
  }) =>
      _connectRemoteNativeSource(
        type: 'sourceConnectHermes',
        arguments: <String, Object>{
          'host': host,
          'port': port,
          'sampleRateHz': sampleRateHz,
          'frequencyHz': frequencyHz,
          'gainDb': gainDb,
        },
      );

  Future<({
    bool ok,
    String error,
    int sampleRateHz,
    int centerFrequencyHz,
  })> connectSpectranHttpSource({
    required String host,
    required int port,
    required int frequencyHz,
  }) =>
      _connectRemoteNativeSource(
        type: 'sourceConnectSpectranHttp',
        arguments: <String, Object>{
          'host': host,
          'port': port,
          'frequencyHz': frequencyHz,
        },
      );

  Future<({
    bool ok,
    String error,
    int sampleRateHz,
    int centerFrequencyHz,
  })> _connectRemoteNativeSource({
    required String type,
    required Map<String, Object> arguments,
  }) async {
    await start();
    final commandPort = _commandPort;
    if (commandPort == null) {
      return (
        ok: false,
        error: 'DSP worker unavailable',
        sampleRateHz: 0,
        centerFrequencyHz: 0,
      );
    }

    final reply = ReceivePort();
    commandPort.send(<String, Object>{
      'type': type,
      ...arguments,
      'reply': reply.sendPort,
    });
    try {
      final result = await reply.first.timeout(
        const Duration(seconds: 12),
      );
      if (result is Map<Object?, Object?>) {
        return (
          ok: result['ok'] == true,
          error: result['error'] as String? ?? '',
          sampleRateHz: result['sampleRateHz'] as int? ?? 0,
          centerFrequencyHz:
              result['centerFrequencyHz'] as int? ?? 0,
        );
      }
      return (
        ok: false,
        error: 'Invalid native source response',
        sampleRateHz: 0,
        centerFrequencyHz: 0,
      );
    } on TimeoutException {
      return (
        ok: false,
        error: 'Native source connection timed out',
        sampleRateHz: 0,
        centerFrequencyHz: 0,
      );
    } finally {
      reply.close();
    }
  }

  Future<List<String>> enumerateSoapy({
    String filter = '',
  }) async {
    await start();
    final commandPort = _commandPort;
    if (commandPort == null) {
      return const <String>[];
    }

    final reply = ReceivePort();
    commandPort.send(<String, Object>{
      'type': 'sourceEnumerateSoapy',
      'filter': filter,
      'reply': reply.sendPort,
    });
    try {
      final result = await reply.first.timeout(
        const Duration(seconds: 6),
      );
      if (result is List) {
        return result.whereType<String>().toList(growable: false);
      }
      return const <String>[];
    } on TimeoutException {
      return const <String>[];
    } finally {
      reply.close();
    }
  }

  Future<({
    bool ok,
    String error,
    int sampleRateHz,
    int centerFrequencyHz,
    String driver,
    String hardware,
  })> connectSoapySource({
    required String deviceArgs,
    required int sampleRateHz,
    required int frequencyHz,
    required double rfBandwidthHz,
    required double gainDb,
    required bool agc,
    int channel = 0,
  }) async {
    await start();
    final commandPort = _commandPort;
    if (commandPort == null) {
      return (
        ok: false,
        error: 'DSP worker unavailable',
        sampleRateHz: 0,
        centerFrequencyHz: 0,
        driver: '',
        hardware: '',
      );
    }

    final reply = ReceivePort();
    commandPort.send(<String, Object>{
      'type': 'sourceConnectSoapy',
      'deviceArgs': deviceArgs,
      'sampleRateHz': sampleRateHz,
      'frequencyHz': frequencyHz,
      'rfBandwidthHz': rfBandwidthHz,
      'gainDb': gainDb,
      'agc': agc,
      'channel': channel,
      'reply': reply.sendPort,
    });

    try {
      final result = await reply.first.timeout(
        const Duration(seconds: 15),
      );
      if (result is Map<Object?, Object?>) {
        return (
          ok: result['ok'] == true,
          error: result['error'] as String? ?? '',
          sampleRateHz: result['sampleRateHz'] as int? ?? 0,
          centerFrequencyHz:
              result['centerFrequencyHz'] as int? ?? 0,
          driver: result['driver'] as String? ?? '',
          hardware: result['hardware'] as String? ?? '',
        );
      }
      return (
        ok: false,
        error: 'Invalid SoapySDR source response',
        sampleRateHz: 0,
        centerFrequencyHz: 0,
        driver: '',
        hardware: '',
      );
    } on TimeoutException {
      return (
        ok: false,
        error: 'SoapySDR connection timed out',
        sampleRateHz: 0,
        centerFrequencyHz: 0,
        driver: '',
        hardware: '',
      );
    } finally {
      reply.close();
    }
  }

  void disconnectSource() {
    _commandPort?.send(<String, Object>{
      'type': 'sourceDisconnect',
    });
  }

  void sourceSetFrequency(int frequencyHz) {
    _commandPort?.send(<String, Object>{
      'type': 'sourceFrequency',
      'frequencyHz': frequencyHz,
    });
  }

  void sourceSetSampleRate(int sampleRateHz) {
    _commandPort?.send(<String, Object>{
      'type': 'sourceSampleRate',
      'sampleRateHz': sampleRateHz,
    });
  }

  void sourceSetTunerAgc(bool enabled) {
    _commandPort?.send(<String, Object>{
      'type': 'sourceTunerAgc',
      'enabled': enabled,
    });
  }

  void sourceSetGainIndex(int index) {
    _commandPort?.send(<String, Object>{
      'type': 'sourceGainIndex',
      'index': index,
    });
  }

  void sourceSetGainDb(double gainDb) {
    _commandPort?.send(<String, Object>{
      'type': 'sourceGainDb',
      'gainDb': gainDb,
    });
  }

  void sourceSetPpm(int ppm) {
    _commandPort?.send(<String, Object>{
      'type': 'sourcePpm',
      'ppm': ppm,
    });
  }

  void sourceSetRtlAgc(bool enabled) {
    _commandPort?.send(<String, Object>{
      'type': 'sourceRtlAgc',
      'enabled': enabled,
    });
  }

  void sourceSetDirectSampling(int mode) {
    _commandPort?.send(<String, Object>{
      'type': 'sourceDirectSampling',
      'mode': mode,
    });
  }

  void sourceSetOffsetTuning(bool enabled) {
    _commandPort?.send(<String, Object>{
      'type': 'sourceOffsetTuning',
      'enabled': enabled,
    });
  }

  void sourceSetBiasTee(bool enabled) {
    _commandPort?.send(<String, Object>{
      'type': 'sourceBiasTee',
      'enabled': enabled,
    });
  }

  void sourceSetRfBandwidth(double bandwidthHz) {
    _commandPort?.send(<String, Object>{
      'type': 'sourceRfBandwidth',
      'bandwidthHz': bandwidthHz,
    });
  }

  void addIq(Uint8List data) {
    final port = _commandPort;
    if (port == null || data.isEmpty) {
      return;
    }
    port.send(<String, Object>{
      'type': 'iq',
      'data': TransferableTypedData.fromList(<Uint8List>[data]),
    });
  }


  void reset() {
    _commandPort?.send(<String, Object>{'type': 'reset'});
  }

  Future<void> dispose() async {
    _commandPort?.send(<String, Object>{'type': 'stop'});
    _commandPort = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    await _receiveSubscription?.cancel();
    _receiveSubscription = null;
    _receivePort?.close();
    _receivePort = null;
    await _spectrumController.close();
    await _audioController.close();
    await _backendController.close();
    await _rdsController.close();
    await _ctcssController.close();
    await _sourceStateController.close();
  }
}

void _sdrDspWorkerMain(SendPort mainPort) {
  final commandPort = ReceivePort();
  final processor = _DspProcessor(mainPort);
  mainPort.send(commandPort.sendPort);

  commandPort.listen((message) {
    if (message is! Map<Object?, Object?>) {
      return;
    }

    switch (message['type']) {
      case 'config':
        processor.configure(
          sampleRateHz: message['sampleRateHz'] as int,
          mode: message['mode'] as String,
          bandwidthHz: (message['bandwidthHz'] as num).toDouble(),
        );
        break;
      case 'mode':
        processor.setMode(message['mode'] as String);
        break;
      case 'bandwidth':
        processor.setBandwidth((message['bandwidthHz'] as num).toDouble());
        break;
      case 'sampleRate':
        processor.setSampleRate(message['sampleRateHz'] as int);
        break;
      case 'squelch':
        processor.setSquelch(
          message['enabled'] as bool,
          (message['thresholdDb'] as num).toDouble(),
        );
        break;
      case 'noiseBlanker':
        processor.setNoiseBlanker(
          message['enabled'] as bool,
          (message['level'] as num).toDouble(),
        );
        break;
      case 'highPass':
        processor.setHighPass(message['enabled'] as bool);
        break;
      case 'deemphasis':
        processor.setDeemphasis(message['modeUs'] as int);
        break;
      case 'ctcss':
        processor.setCtcss(
          message['mode'] as int,
          message['toneIndex'] as int,
        );
        break;
      case 'fmIfNr':
        processor.setFmIfNr(
          message['enabled'] as bool,
          message['preset'] as int,
        );
        break;
      case 'amAgc':
        processor.setAmAgc(
          message['carrier'] as bool,
          (message['attackMs'] as num).toDouble(),
          (message['decayMs'] as num).toDouble(),
        );
        break;
      case 'ssbAgc':
        processor.setSsbAgc(
          (message['attackMs'] as num).toDouble(),
          (message['decayMs'] as num).toDouble(),
        );
        break;
      case 'cwOptions':
        processor.setCwOptions(
          message['toneHz'] as int,
          (message['attackMs'] as num).toDouble(),
          (message['decayMs'] as num).toDouble(),
        );
        break;
      case 'nfmOptions':
        processor.setNfmOptions(message['lowPass'] as bool);
        break;
      case 'nfmVoiceFilter':
        processor.setNfmVoiceFilter(message['enabled'] as bool);
        break;
      case 'wfmOptions':
        processor.setWfmOptions(
          message['stereo'] as bool,
          message['lowPass'] as bool,
          message['rdsEnabled'] as bool,
        );
        break;
      case 'sourceConnect':
        final reply = message['reply'];
        final result = processor.connectRtlTcpSource(
          host: message['host'] as String,
          port: message['port'] as int,
          sampleRateHz: message['sampleRateHz'] as int,
          frequencyHz: message['frequencyHz'] as int,
        );
        if (reply is SendPort) {
          reply.send(<String, Object>{
            'ok': result.ok,
            'error': result.error,
          });
        }
        break;
      case 'sourceOpenFile':
        final reply = message['reply'];
        final result = processor.openFileSource(
          path: message['path'] as String,
          float32Mode: message['float32Mode'] as bool,
          centerFrequencyHz:
              message['centerFrequencyHz'] as int,
        );
        if (reply is SendPort) {
          reply.send(<String, Object>{
            'ok': result.ok,
            'error': result.error,
            'sampleRateHz': result.sampleRateHz,
            'centerFrequencyHz': result.centerFrequencyHz,
          });
        }
        break;
      case 'sourceConnectNetwork':
        final reply = message['reply'];
        final result = processor.connectNetworkSource(
          host: message['host'] as String,
          port: message['port'] as int,
          sampleRateHz: message['sampleRateHz'] as int,
          protocol: message['protocol'] as int,
          sampleType: message['sampleType'] as int,
          centerFrequencyHz:
              message['centerFrequencyHz'] as int,
        );
        if (reply is SendPort) {
          reply.send(<String, Object>{
            'ok': result.ok,
            'error': result.error,
            'sampleRateHz': result.sampleRateHz,
            'centerFrequencyHz': result.centerFrequencyHz,
          });
        }
        break;
      case 'sourceConnectRtlSdrUsb':
        final reply = message['reply'];
        final result = processor.connectRtlSdrUsbSource(
          systemFd: message['systemFd'] as int,
          sampleRateHz: message['sampleRateHz'] as int,
          frequencyHz: message['frequencyHz'] as int,
        );
        if (reply is SendPort) {
          reply.send(<String, Object>{
            'ok': result.ok,
            'error': result.error,
            'sampleRateHz': result.sampleRateHz,
            'centerFrequencyHz': result.centerFrequencyHz,
          });
        }
        break;
      case 'sourceConnectSdrppServer':
        final reply = message['reply'];
        final result = processor.connectSdrppServerSource(
          host: message['host'] as String,
          port: message['port'] as int,
          frequencyHz: message['frequencyHz'] as int,
        );
        if (reply is SendPort) {
          reply.send(<String, Object>{
            'ok': result.ok,
            'error': result.error,
            'sampleRateHz': result.sampleRateHz,
            'centerFrequencyHz': result.centerFrequencyHz,
          });
        }
        break;
      case 'sourceConnectSpyServer':
        final reply = message['reply'];
        final result = processor.connectSpyServerSource(
          host: message['host'] as String,
          port: message['port'] as int,
          sampleRateHz: message['sampleRateHz'] as int,
          frequencyHz: message['frequencyHz'] as int,
        );
        if (reply is SendPort) {
          reply.send(<String, Object>{
            'ok': result.ok,
            'error': result.error,
            'sampleRateHz': result.sampleRateHz,
            'centerFrequencyHz': result.centerFrequencyHz,
          });
        }
        break;
      case 'sourceConnectRfspace':
        final reply = message['reply'];
        final result = processor.connectRfspaceSource(
          host: message['host'] as String,
          port: message['port'] as int,
          sampleRateHz: message['sampleRateHz'] as int,
          frequencyHz: message['frequencyHz'] as int,
          gainDb: message['gainDb'] as int,
        );
        if (reply is SendPort) {
          reply.send(<String, Object>{
            'ok': result.ok,
            'error': result.error,
            'sampleRateHz': result.sampleRateHz,
            'centerFrequencyHz': result.centerFrequencyHz,
          });
        }
        break;
      case 'sourceConnectHermes':
        final reply = message['reply'];
        final result = processor.connectHermesSource(
          host: message['host'] as String,
          port: message['port'] as int,
          sampleRateHz: message['sampleRateHz'] as int,
          frequencyHz: message['frequencyHz'] as int,
          gainDb: message['gainDb'] as int,
        );
        if (reply is SendPort) {
          reply.send(<String, Object>{
            'ok': result.ok,
            'error': result.error,
            'sampleRateHz': result.sampleRateHz,
            'centerFrequencyHz': result.centerFrequencyHz,
          });
        }
        break;
      case 'sourceConnectSpectranHttp':
        final reply = message['reply'];
        final result = processor.connectSpectranHttpSource(
          host: message['host'] as String,
          port: message['port'] as int,
          frequencyHz: message['frequencyHz'] as int,
        );
        if (reply is SendPort) {
          reply.send(<String, Object>{
            'ok': result.ok,
            'error': result.error,
            'sampleRateHz': result.sampleRateHz,
            'centerFrequencyHz': result.centerFrequencyHz,
          });
        }
        break;
      case 'sourceEnumerateSoapy':
        final reply = message['reply'];
        final devices = processor.enumerateSoapy(
          message['filter'] as String? ?? '',
        );
        if (reply is SendPort) {
          reply.send(devices);
        }
        break;
      case 'sourceConnectSoapy':
        final reply = message['reply'];
        final result = processor.connectSoapySource(
          deviceArgs: message['deviceArgs'] as String,
          sampleRateHz: message['sampleRateHz'] as int,
          frequencyHz: message['frequencyHz'] as int,
          rfBandwidthHz:
              (message['rfBandwidthHz'] as num).toDouble(),
          gainDb: (message['gainDb'] as num).toDouble(),
          agc: message['agc'] as bool,
          channel: message['channel'] as int,
        );
        if (reply is SendPort) {
          reply.send(<String, Object>{
            'ok': result.ok,
            'error': result.error,
            'sampleRateHz': result.sampleRateHz,
            'centerFrequencyHz': result.centerFrequencyHz,
            'driver': result.driver,
            'hardware': result.hardware,
          });
        }
        break;
      case 'sourceDisconnect':
        processor.disconnectSource();
        break;
      case 'sourceFrequency':
        processor.sourceSetFrequency(
          message['frequencyHz'] as int,
        );
        break;
      case 'sourceSampleRate':
        processor.sourceSetSampleRate(
          message['sampleRateHz'] as int,
        );
        break;
      case 'sourceTunerAgc':
        processor.sourceSetTunerAgc(
          message['enabled'] as bool,
        );
        break;
      case 'sourceGainIndex':
        processor.sourceSetGainIndex(
          message['index'] as int,
        );
        break;
      case 'sourceGainDb':
        processor.sourceSetGainDb(
          (message['gainDb'] as num).toDouble(),
        );
        break;
      case 'sourcePpm':
        processor.sourceSetPpm(
          message['ppm'] as int,
        );
        break;
      case 'sourceRtlAgc':
        processor.sourceSetRtlAgc(
          message['enabled'] as bool,
        );
        break;
      case 'sourceDirectSampling':
        processor.sourceSetDirectSampling(
          message['mode'] as int,
        );
        break;
      case 'sourceOffsetTuning':
        processor.sourceSetOffsetTuning(
          message['enabled'] as bool,
        );
        break;
      case 'sourceBiasTee':
        processor.sourceSetBiasTee(
          message['enabled'] as bool,
        );
        break;
      case 'sourceRfBandwidth':
        processor.sourceSetRfBandwidth(
          (message['bandwidthHz'] as num).toDouble(),
        );
        break;
      case 'iq':
        final data = message['data'];
        if (data is TransferableTypedData) {
          processor.processIq(data.materialize().asUint8List());
        }
        break;
      case 'reset':
        processor.reset();
        break;
      case 'stop':
        processor.dispose();
        commandPort.close();
        break;
    }
  });
}

class _DspProcessor {
  _DspProcessor(this.mainPort) {
    _native = NativeDspBridge.tryCreate(
      sampleRateHz: sampleRateHz,
      mode: mode,
      bandwidthHz: bandwidthHz,
    );
    final native = _native;
    if (native != null) {
      _source = NativeRtlTcpSourceBridge.tryCreate(native);
    }
    mainPort.send(<String, Object>{
      'type': 'backend',
      'name': native?.backendName ?? 'Dart fallback DSP',
    });
  }

  final SendPort mainPort;
  NativeDspBridge? _native;
  NativeRtlTcpSourceBridge? _source;
  Timer? _sourcePollTimer;
  bool _sourceConnected = false;

  int sampleRateHz = 1024000;
  String mode = 'AM';
  double bandwidthHz = 10000;

  int _fftSkipSamples = 0;
  DateTime _lastRdsPoll = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastRdsPs = '';
  String _lastRdsText = '';
  DateTime _lastCtcssPoll = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastCtcssToneIndex = -999;

  double _sumI = 0;
  double _sumQ = 0;
  int _decimCount = 0;

  double _previousI = 0;
  double _previousQ = 0;
  bool _havePreviousIq = false;

  double _amPreviousInput = 0;
  double _amDcState = 0;
  double _amEnvelope = 0.05;
  double _audioLowPass = 0;
  double _deemphasisState = 0;
  double _outputPhase = 0;
  double _cwPhase = 0;
  double _rfPowerDb = -120;
  bool _squelchEnabled = false;
  double _squelchThresholdDb = -82;

  final Int16List _pcm = Int16List(1920);
  int _pcmCount = 0;

  void configure({
    required int sampleRateHz,
    required String mode,
    required double bandwidthHz,
  }) {
    this.sampleRateHz = sampleRateHz;
    this.mode = mode;
    this.bandwidthHz = bandwidthHz;
    final native = _native;
    if (native != null) {
      native.setSampleRate(sampleRateHz);
      native.setMode(mode);
      native.setBandwidth(bandwidthHz);
    }
    reset();
  }

  void setMode(String value) {
    mode = value;
    _native?.setMode(value);
    resetDemodState();
  }

  void setBandwidth(double value) {
    bandwidthHz = value;
    _native?.setBandwidth(value);
  }

  void setSampleRate(int value) {
    sampleRateHz = value;
    _native?.setSampleRate(value);
    reset();
  }

  void setSquelch(bool enabled, double thresholdDb) {
    _squelchEnabled = enabled;
    _squelchThresholdDb = thresholdDb;
    _native?.setSquelch(enabled, thresholdDb);
  }

  void setNoiseBlanker(bool enabled, double level) {
    _native?.setNoiseBlanker(enabled, level);
  }

  void setHighPass(bool enabled) {
    _native?.setHighPass(enabled);
  }

  void setDeemphasis(int modeUs) {
    _native?.setDeemphasis(modeUs);
  }

  void setCtcss(int mode, int toneIndex) {
    _native?.setCtcss(mode, toneIndex);
    _lastCtcssToneIndex = -999;
  }

  void setFmIfNr(bool enabled, int preset) {
    _native?.setFmIfNr(enabled, preset);
  }

  void setAmAgc(bool carrier, double attackMs, double decayMs) {
    _native?.setAmAgc(
      carrier: carrier,
      attackMs: attackMs,
      decayMs: decayMs,
    );
  }

  void setSsbAgc(double attackMs, double decayMs) {
    _native?.setSsbAgc(
      attackMs: attackMs,
      decayMs: decayMs,
    );
  }

  void setCwOptions(int toneHz, double attackMs, double decayMs) {
    _native?.setCwOptions(
      toneHz: toneHz,
      attackMs: attackMs,
      decayMs: decayMs,
    );
  }

  void setNfmOptions(bool lowPass) {
    _native?.setNfmOptions(lowPass: lowPass);
  }

  void setNfmVoiceFilter(bool enabled) {
    _native?.setNfmVoiceFilter(enabled);
  }

  void setWfmOptions(bool stereo, bool lowPass, bool rdsEnabled) {
    _native?.setWfmOptions(
      stereo: stereo,
      lowPass: lowPass,
      rdsEnabled: rdsEnabled,
    );
  }

  ({bool ok, String error}) connectRtlTcpSource({
    required String host,
    required int port,
    required int sampleRateHz,
    required int frequencyHz,
  }) {
    final source = _source;
    if (source == null) {
      return (
        ok: false,
        error: 'Native SDR++ RTL-TCP source is unavailable',
      );
    }

    source.disconnect();
    final ok = source.connect(
      host: host,
      port: port,
      sampleRateHz: sampleRateHz,
      frequencyHz: frequencyHz,
    );
    if (!ok) {
      _sourceConnected = false;
      return (ok: false, error: source.lastError);
    }

    this.sampleRateHz = sampleRateHz;
    _sourceConnected = true;
    _sourcePollTimer?.cancel();
    _sourcePollTimer = Timer.periodic(
      const Duration(milliseconds: 20),
      (_) => _pollNativeSource(),
    );
    mainPort.send(<String, Object>{
      'type': 'sourceState',
      'connected': true,
      'error': '',
    });
    return (ok: true, error: '');
  }

  ({
    bool ok,
    String error,
    int sampleRateHz,
    int centerFrequencyHz,
  }) openFileSource({
    required String path,
    required bool float32Mode,
    required int centerFrequencyHz,
  }) {
    final source = _source;
    if (source == null) {
      return (
        ok: false,
        error: 'Native SDR++ File Source is unavailable',
        sampleRateHz: 0,
        centerFrequencyHz: 0,
      );
    }

    source.disconnect();
    final ok = source.openFile(
      path: path,
      float32Mode: float32Mode,
      centerFrequencyHz: centerFrequencyHz,
    );
    if (!ok) {
      _sourceConnected = false;
      return (
        ok: false,
        error: source.lastError,
        sampleRateHz: 0,
        centerFrequencyHz: 0,
      );
    }

    sampleRateHz = source.sampleRateHz;
    _sourceConnected = true;
    _sourcePollTimer?.cancel();
    _sourcePollTimer = Timer.periodic(
      const Duration(milliseconds: 20),
      (_) => _pollNativeSource(),
    );
    mainPort.send(<String, Object>{
      'type': 'sourceState',
      'connected': true,
      'error': '',
    });
    return (
      ok: true,
      error: '',
      sampleRateHz: source.sampleRateHz,
      centerFrequencyHz: source.centerFrequencyHz,
    );
  }

  ({
    bool ok,
    String error,
    int sampleRateHz,
    int centerFrequencyHz,
  }) connectNetworkSource({
    required String host,
    required int port,
    required int sampleRateHz,
    required int protocol,
    required int sampleType,
    required int centerFrequencyHz,
  }) {
    final source = _source;
    if (source == null) {
      return (
        ok: false,
        error: 'Native SDR++ Network Source is unavailable',
        sampleRateHz: 0,
        centerFrequencyHz: 0,
      );
    }

    source.disconnect();
    final ok = source.connectNetwork(
      host: host,
      port: port,
      sampleRateHz: sampleRateHz,
      protocol: protocol,
      sampleType: sampleType,
      centerFrequencyHz: centerFrequencyHz,
    );
    if (!ok) {
      _sourceConnected = false;
      return (
        ok: false,
        error: source.lastError,
        sampleRateHz: 0,
        centerFrequencyHz: 0,
      );
    }

    this.sampleRateHz = source.sampleRateHz;
    _sourceConnected = true;
    _sourcePollTimer?.cancel();
    _sourcePollTimer = Timer.periodic(
      const Duration(milliseconds: 20),
      (_) => _pollNativeSource(),
    );
    mainPort.send(<String, Object>{
      'type': 'sourceState',
      'connected': true,
      'error': '',
    });
    return (
      ok: true,
      error: '',
      sampleRateHz: source.sampleRateHz,
      centerFrequencyHz: source.centerFrequencyHz,
    );
  }

  ({
    bool ok,
    String error,
    int sampleRateHz,
    int centerFrequencyHz,
  }) connectRtlSdrUsbSource({
    required int systemFd,
    required int sampleRateHz,
    required int frequencyHz,
  }) {
    final source = _source;
    if (source == null) {
      return (
        ok: false,
        error: 'Native RTL-SDR USB source is unavailable',
        sampleRateHz: 0,
        centerFrequencyHz: 0,
      );
    }

    source.disconnect();
    final ok = source.connectRtlSdrFd(
      systemFd: systemFd,
      sampleRateHz: sampleRateHz,
      frequencyHz: frequencyHz,
    );
    if (!ok) {
      _sourceConnected = false;
      return (
        ok: false,
        error: source.lastError,
        sampleRateHz: 0,
        centerFrequencyHz: 0,
      );
    }

    this.sampleRateHz = source.sampleRateHz;
    _sourceConnected = true;
    _sourcePollTimer?.cancel();
    _sourcePollTimer = Timer.periodic(
      const Duration(milliseconds: 20),
      (_) => _pollNativeSource(),
    );
    mainPort.send(<String, Object>{
      'type': 'sourceState',
      'connected': true,
      'error': '',
    });
    return (
      ok: true,
      error: '',
      sampleRateHz: source.sampleRateHz,
      centerFrequencyHz: source.centerFrequencyHz,
    );
  }

  ({
    bool ok,
    String error,
    int sampleRateHz,
    int centerFrequencyHz,
  }) connectSdrppServerSource({
    required String host,
    required int port,
    required int frequencyHz,
  }) {
    final source = _source;
    if (source == null) {
      return (
        ok: false,
        error: 'Native SDR++ Server source is unavailable',
        sampleRateHz: 0,
        centerFrequencyHz: 0,
      );
    }

    source.disconnect();
    final ok = source.connectSdrppServer(
      host: host,
      port: port,
      frequencyHz: frequencyHz,
    );
    if (!ok) {
      _sourceConnected = false;
      return (
        ok: false,
        error: source.lastError,
        sampleRateHz: 0,
        centerFrequencyHz: 0,
      );
    }

    sampleRateHz = source.sampleRateHz;
    _sourceConnected = true;
    _sourcePollTimer?.cancel();
    _sourcePollTimer = Timer.periodic(
      const Duration(milliseconds: 20),
      (_) => _pollNativeSource(),
    );
    mainPort.send(<String, Object>{
      'type': 'sourceState',
      'connected': true,
      'error': '',
    });
    return (
      ok: true,
      error: '',
      sampleRateHz: source.sampleRateHz,
      centerFrequencyHz: source.centerFrequencyHz,
    );
  }

  ({
    bool ok,
    String error,
    int sampleRateHz,
    int centerFrequencyHz,
  }) connectSpyServerSource({
    required String host,
    required int port,
    required int sampleRateHz,
    required int frequencyHz,
  }) {
    final source = _source;
    if (source == null) {
      return (
        ok: false,
        error: 'Native SpyServer source is unavailable',
        sampleRateHz: 0,
        centerFrequencyHz: 0,
      );
    }

    source.disconnect();
    final ok = source.connectSpyServer(
      host: host,
      port: port,
      sampleRateHz: sampleRateHz,
      frequencyHz: frequencyHz,
    );
    if (!ok) {
      _sourceConnected = false;
      return (
        ok: false,
        error: source.lastError,
        sampleRateHz: 0,
        centerFrequencyHz: 0,
      );
    }

    this.sampleRateHz = source.sampleRateHz;
    _sourceConnected = true;
    _sourcePollTimer?.cancel();
    _sourcePollTimer = Timer.periodic(
      const Duration(milliseconds: 20),
      (_) => _pollNativeSource(),
    );
    mainPort.send(<String, Object>{
      'type': 'sourceState',
      'connected': true,
      'error': '',
    });
    return (
      ok: true,
      error: '',
      sampleRateHz: source.sampleRateHz,
      centerFrequencyHz: source.centerFrequencyHz,
    );
  }

  ({
    bool ok,
    String error,
    int sampleRateHz,
    int centerFrequencyHz,
  }) _finishNativeSourceConnect(bool ok) {
    final source = _source;
    if (!ok || source == null) {
      _sourceConnected = false;
      return (
        ok: false,
        error: source?.lastError ?? 'Native source unavailable',
        sampleRateHz: 0,
        centerFrequencyHz: 0,
      );
    }

    sampleRateHz = source.sampleRateHz;
    _sourceConnected = true;
    _sourcePollTimer?.cancel();
    _sourcePollTimer = Timer.periodic(
      const Duration(milliseconds: 20),
      (_) => _pollNativeSource(),
    );
    mainPort.send(<String, Object>{
      'type': 'sourceState',
      'connected': true,
      'error': '',
    });
    return (
      ok: true,
      error: '',
      sampleRateHz: source.sampleRateHz,
      centerFrequencyHz: source.centerFrequencyHz,
    );
  }

  ({
    bool ok,
    String error,
    int sampleRateHz,
    int centerFrequencyHz,
  }) connectRfspaceSource({
    required String host,
    required int port,
    required int sampleRateHz,
    required int frequencyHz,
    required int gainDb,
  }) {
    final source = _source;
    if (source == null) {
      return _finishNativeSourceConnect(false);
    }
    source.disconnect();
    return _finishNativeSourceConnect(
      source.connectRfspace(
        host: host,
        port: port,
        sampleRateHz: sampleRateHz,
        frequencyHz: frequencyHz,
        gainDb: gainDb,
      ),
    );
  }

  ({
    bool ok,
    String error,
    int sampleRateHz,
    int centerFrequencyHz,
  }) connectHermesSource({
    required String host,
    required int port,
    required int sampleRateHz,
    required int frequencyHz,
    required int gainDb,
  }) {
    final source = _source;
    if (source == null) {
      return _finishNativeSourceConnect(false);
    }
    source.disconnect();
    return _finishNativeSourceConnect(
      source.connectHermes(
        host: host,
        port: port,
        sampleRateHz: sampleRateHz,
        frequencyHz: frequencyHz,
        gainDb: gainDb,
      ),
    );
  }

  ({
    bool ok,
    String error,
    int sampleRateHz,
    int centerFrequencyHz,
  }) connectSpectranHttpSource({
    required String host,
    required int port,
    required int frequencyHz,
  }) {
    final source = _source;
    if (source == null) {
      return _finishNativeSourceConnect(false);
    }
    source.disconnect();
    return _finishNativeSourceConnect(
      source.connectSpectranHttp(
        host: host,
        port: port,
        frequencyHz: frequencyHz,
      ),
    );
  }

  List<String> enumerateSoapy(String filter) {
    final source = _source;
    if (source == null || !source.soapyAvailable) {
      return const <String>[];
    }
    return source.enumerateSoapy(filter: filter);
  }

  ({
    bool ok,
    String error,
    int sampleRateHz,
    int centerFrequencyHz,
    String driver,
    String hardware,
  }) connectSoapySource({
    required String deviceArgs,
    required int sampleRateHz,
    required int frequencyHz,
    required double rfBandwidthHz,
    required double gainDb,
    required bool agc,
    required int channel,
  }) {
    final source = _source;
    if (source == null || !source.soapyAvailable) {
      return (
        ok: false,
        error: 'SoapySDR runtime is unavailable',
        sampleRateHz: 0,
        centerFrequencyHz: 0,
        driver: '',
        hardware: '',
      );
    }

    source.disconnect();
    final ok = source.connectSoapy(
      deviceArgs: deviceArgs,
      sampleRateHz: sampleRateHz,
      frequencyHz: frequencyHz,
      rfBandwidthHz: rfBandwidthHz,
      gainDb: gainDb,
      agc: agc,
      channel: channel,
    );
    final common = _finishNativeSourceConnect(ok);
    return (
      ok: common.ok,
      error: common.error,
      sampleRateHz: common.sampleRateHz,
      centerFrequencyHz: common.centerFrequencyHz,
      driver: common.ok ? source.soapyDriver : '',
      hardware: common.ok ? source.soapyHardware : '',
    );
  }

  void disconnectSource() {
    _sourcePollTimer?.cancel();
    _sourcePollTimer = null;
    _source?.disconnect();
    _sourceConnected = false;
    mainPort.send(<String, Object>{
      'type': 'sourceState',
      'connected': false,
      'error': '',
    });
  }

  void sourceSetFrequency(int value) {
    _source?.setFrequency(value);
  }

  void sourceSetSampleRate(int value) {
    sampleRateHz = value;
    _source?.setSampleRate(value);
  }

  void sourceSetTunerAgc(bool enabled) {
    _source?.setTunerAgc(enabled);
  }

  void sourceSetGainIndex(int index) {
    _source?.setGainIndex(index);
  }

  void sourceSetGainDb(double gainDb) {
    _source?.setGainDb(gainDb);
  }

  void sourceSetPpm(int ppm) {
    _source?.setPpm(ppm);
  }

  void sourceSetRtlAgc(bool enabled) {
    _source?.setRtlAgc(enabled);
  }

  void sourceSetDirectSampling(int mode) {
    _source?.setDirectSampling(mode);
  }

  void sourceSetOffsetTuning(bool enabled) {
    _source?.setOffsetTuning(enabled);
  }

  void sourceSetBiasTee(bool enabled) {
    _source?.setBiasTee(enabled);
  }

  void sourceSetRfBandwidth(double bandwidthHz) {
    _source?.setRfBandwidth(bandwidthHz);
  }

  void _pollNativeSource() {
    final source = _source;
    if (source == null || !_sourceConnected) {
      return;
    }

    if (!source.isConnected) {
      _sourceConnected = false;
      _sourcePollTimer?.cancel();
      _sourcePollTimer = null;
      mainPort.send(<String, Object>{
        'type': 'sourceState',
        'connected': false,
        'error': source.lastError,
      });
      return;
    }

    final pcm = source.readAudio();
    if (pcm.isNotEmpty) {
      mainPort.send(<String, Object>{
        'type': 'audio',
        'data': TransferableTypedData.fromList(<Uint8List>[pcm]),
      });
    }

    final spectrum = source.readSpectrum();
    if (spectrum != null && spectrum.isNotEmpty) {
      mainPort.send(<String, Object>{
        'type': 'spectrum',
        'data': TransferableTypedData.fromList(
          <Uint8List>[spectrum.buffer.asUint8List()],
        ),
      });
    }

    _pollNativeMetadata(DateTime.now());
  }

  void _pollNativeMetadata(DateTime now) {
    final native = _native;
    if (native == null) {
      return;
    }

    if (mode == 'WFM' &&
        now.difference(_lastRdsPoll).inMilliseconds >= 500) {
      _lastRdsPoll = now;
      final rds = native.getRds();
      if (rds != null &&
          (rds.programService != _lastRdsPs ||
              rds.radioText != _lastRdsText)) {
        _lastRdsPs = rds.programService;
        _lastRdsText = rds.radioText;
        mainPort.send(<String, Object>{
          'type': 'rds',
          'programService': _lastRdsPs,
          'radioText': _lastRdsText,
        });
      }
    }

    if (mode == 'NFM' &&
        now.difference(_lastCtcssPoll).inMilliseconds >= 250) {
      _lastCtcssPoll = now;
      final tone = native.getCtcss();
      final toneIndex = tone?.toneIndex ?? -1;
      if (toneIndex != _lastCtcssToneIndex) {
        _lastCtcssToneIndex = toneIndex;
        mainPort.send(<String, Object>{
          'type': 'ctcss',
          'toneIndex': toneIndex,
          'toneHz': tone?.toneHz ?? 0.0,
        });
      }
    }
  }
  void reset() {
    _fftSkipSamples = 0;
    _native?.reset();
    _lastRdsPs = '';
    _lastRdsText = '';
    _lastCtcssToneIndex = -999;
    resetDemodState();
  }

  void resetDemodState() {
    _sumI = 0;
    _sumQ = 0;
    _decimCount = 0;
    _previousI = 0;
    _previousQ = 0;
    _havePreviousIq = false;
    _amPreviousInput = 0;
    _amDcState = 0;
    _amEnvelope = 0.05;
    _audioLowPass = 0;
    _deemphasisState = 0;
    _outputPhase = 0;
    _cwPhase = 0;
    _rfPowerDb = -120;
    _pcmCount = 0;
  }

  void processIq(Uint8List bytes) {
    final sampleCount = bytes.length ~/ 2;
    if (sampleCount <= 0) {
      return;
    }

    if (_fftSkipSamples <= 0 && bytes.length >= 2048) {
      final fftFrame = Uint8List.sublistView(bytes, 0, 2048);
      final spectrum = _fft1024(fftFrame);
      mainPort.send(<String, Object>{
        'type': 'spectrum',
        'data': TransferableTypedData.fromList(
          <Uint8List>[spectrum.buffer.asUint8List()],
        ),
      });
      _fftSkipSamples =
          math.max(1024, sampleRateHz ~/ 20).toInt();
    }
    _fftSkipSamples -= sampleCount;

    final native = _native;
    if (native != null) {
      final pcm = native.process(bytes);
      if (pcm.isNotEmpty) {
        mainPort.send(<String, Object>{
          'type': 'audio',
          'data': TransferableTypedData.fromList(<Uint8List>[pcm]),
        });
      }

      final now = DateTime.now();
      if (mode == 'WFM' &&
          now.difference(_lastRdsPoll).inMilliseconds >= 500) {
        _lastRdsPoll = now;
        final rds = native.getRds();
        if (rds != null &&
            (rds.programService != _lastRdsPs ||
                rds.radioText != _lastRdsText)) {
          _lastRdsPs = rds.programService;
          _lastRdsText = rds.radioText;
          mainPort.send(<String, Object>{
            'type': 'rds',
            'programService': _lastRdsPs,
            'radioText': _lastRdsText,
          });
        }
      }

      if (mode == 'NFM' &&
          now.difference(_lastCtcssPoll).inMilliseconds >= 250) {
        _lastCtcssPoll = now;
        final tone = native.getCtcss();
        final toneIndex = tone?.toneIndex ?? -1;
        if (toneIndex != _lastCtcssToneIndex) {
          _lastCtcssToneIndex = toneIndex;
          mainPort.send(<String, Object>{
            'type': 'ctcss',
            'toneIndex': toneIndex,
            'toneHz': tone?.toneHz ?? 0.0,
          });
        }
      }
      return;
    }

    if (mode == 'RAW') {
      return;
    }

    final decimation = mode == 'WFM' ? 4 : 16;
    final decimatedRate = sampleRateHz / decimation;

    for (var i = 0; i < sampleCount; i++) {
      final re = (bytes[i * 2] - 127.5) / 127.5;
      final im = (bytes[i * 2 + 1] - 127.5) / 127.5;

      _sumI += re;
      _sumQ += im;
      _decimCount++;

      if (_decimCount < decimation) {
        continue;
      }

      final avgI = _sumI / decimation;
      final avgQ = _sumQ / decimation;
      _sumI = 0;
      _sumQ = 0;
      _decimCount = 0;

      final power = avgI * avgI + avgQ * avgQ;
      final instantDb = 10 * math.log(power + 1e-12) / math.ln10;
      _rfPowerDb = 0.995 * _rfPowerDb + 0.005 * instantDb;

      var audio = switch (mode) {
        'AM' => _demodAm(avgI, avgQ, decimatedRate),
        'NFM' => _demodFm(avgI, avgQ, decimatedRate, 5000),
        'WFM' => _demodWfm(avgI, avgQ, decimatedRate),
        'USB' => _demodSsb(avgI, avgQ, decimatedRate, 1),
        'LSB' => _demodSsb(avgI, avgQ, decimatedRate, -1),
        'DSB' => _demodDsb(avgI, decimatedRate),
        'CW' => _demodCw(avgI, avgQ, decimatedRate),
        _ => 0.0,
      };

      if (_squelchEnabled && _rfPowerDb < _squelchThresholdDb) {
        audio = 0;
      }

      _resampleToAudio(audio, decimatedRate);
    }
  }

  double _demodAm(double re, double im, double rate) {
    final magnitude = math.sqrt(re * re + im * im);

    final dcBlocked =
        magnitude - _amPreviousInput + 0.995 * _amDcState;
    _amPreviousInput = magnitude;
    _amDcState = dcBlocked;

    final absolute = dcBlocked.abs();
    _amEnvelope = 0.999 * _amEnvelope + 0.001 * absolute;
    final agc = dcBlocked / math.max(0.03, _amEnvelope * 5.0);

    final cutoff =
        math.min(6000.0, math.max(1500.0, bandwidthHz * 0.45)).toDouble();
    final alpha = 1 - math.exp(-2 * math.pi * cutoff / rate);
    _audioLowPass += alpha * (agc - _audioLowPass);
    return _audioLowPass.clamp(-1.0, 1.0).toDouble();
  }

  double _demodFm(
    double re,
    double im,
    double rate,
    double deviationHz,
  ) {
    if (!_havePreviousIq) {
      _previousI = re;
      _previousQ = im;
      _havePreviousIq = true;
      return 0;
    }

    final real = re * _previousI + im * _previousQ;
    final imag = im * _previousI - re * _previousQ;
    _previousI = re;
    _previousQ = im;

    final delta = math.atan2(imag, real);
    final maxDelta = 2 * math.pi * deviationHz / rate;
    final normalized = (delta / math.max(1e-9, maxDelta))
        .clamp(-1.0, 1.0)
        .toDouble();

    final cutoff =
        math.min(6500.0, math.max(2500.0, bandwidthHz * 0.42)).toDouble();
    final alpha = 1 - math.exp(-2 * math.pi * cutoff / rate);
    _audioLowPass += alpha * (normalized - _audioLowPass);
    return _audioLowPass;
  }

  double _demodWfm(double re, double im, double rate) {
    final detected = _demodFm(re, im, rate, 75000);

    const tau = 50e-6;
    final alpha = 1 - math.exp(-1 / (rate * tau));
    _deemphasisState += alpha * (detected - _deemphasisState);
    return _deemphasisState.clamp(-1.0, 1.0).toDouble();
  }

  double _demodSsb(double re, double im, double rate, int sideband) {
    // RTL-TCP is tuned to the carrier. The complex baseband already preserves
    // sideband orientation; taking the in-phase component after a voice LPF
    // is a practical lightweight SSB detector for the mobile preview.
    final selected = sideband > 0 ? re + 0.15 * im : re - 0.15 * im;
    final cutoff = math.min(3200.0, math.max(1800.0, bandwidthHz * 0.48));
    final alpha = 1 - math.exp(-2 * math.pi * cutoff / rate);
    _audioLowPass += alpha * (selected - _audioLowPass);
    return (_audioLowPass * 3.2).clamp(-1.0, 1.0).toDouble();
  }

  double _demodDsb(double re, double rate) {
    final cutoff = math.min(5000.0, math.max(1800.0, bandwidthHz * 0.48));
    final alpha = 1 - math.exp(-2 * math.pi * cutoff / rate);
    _audioLowPass += alpha * (re - _audioLowPass);
    return (_audioLowPass * 3.0).clamp(-1.0, 1.0).toDouble();
  }

  double _demodCw(double re, double im, double rate) {
    const toneHz = 700.0;
    _cwPhase += 2 * math.pi * toneHz / rate;
    if (_cwPhase > 2 * math.pi) {
      _cwPhase -= 2 * math.pi;
    }
    final mixed =
        re * math.cos(_cwPhase) - im * math.sin(_cwPhase);
    final cutoff = math.min(1200.0, math.max(350.0, bandwidthHz * 0.48));
    final alpha = 1 - math.exp(-2 * math.pi * cutoff / rate);
    _audioLowPass += alpha * (mixed - _audioLowPass);
    return (_audioLowPass * 4.0).clamp(-1.0, 1.0).toDouble();
  }

  void _resampleToAudio(double sample, double inputRate) {
    const outputRate = 48000.0;
    _outputPhase += outputRate;

    if (_outputPhase < inputRate) {
      return;
    }

    _outputPhase -= inputRate;
    final scaled = (sample * 26000)
        .clamp(-32767.0, 32767.0)
        .round();
    // Fallback path is mono; duplicate each sample to stereo so the
    // audio sink contract stays identical to the native SDR++ backend.
    if (_pcmCount + 1 < _pcm.length) {
      _pcm[_pcmCount++] = scaled;
      _pcm[_pcmCount++] = scaled;
    }

    if (_pcmCount >= _pcm.length) {
      final bytes = Uint8List(_pcm.length * 2);
      final view = ByteData.view(bytes.buffer);
      for (var i = 0; i < _pcm.length; i++) {
        view.setInt16(i * 2, _pcm[i], Endian.little);
      }
      mainPort.send(<String, Object>{
        'type': 'audio',
        'data': TransferableTypedData.fromList(<Uint8List>[bytes]),
      });
      _pcmCount = 0;
    }
  }

  void dispose() {
    _sourcePollTimer?.cancel();
    _sourcePollTimer = null;
    _source?.dispose();
    _source = null;
    _native?.dispose();
    _native = null;
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

      for (var start = 0; start < n; start += length) {
        var wRe = 1.0;
        var wIm = 0.0;
        final half = length >> 1;

        for (var k = 0; k < half; k++) {
          final even = start + k;
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
}
