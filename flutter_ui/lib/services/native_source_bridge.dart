import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'native_dsp_bridge.dart';

typedef _SourceCreateNative = Pointer<Void> Function(Pointer<Void>);
typedef _SourceCreateDart = Pointer<Void> Function(Pointer<Void>);

typedef _SourceDestroyNative = Void Function(Pointer<Void>);
typedef _SourceDestroyDart = void Function(Pointer<Void>);

typedef _SourceConnectNative = Int32 Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Int32,
  Uint32,
  Uint32,
);
typedef _SourceConnectDart = int Function(
  Pointer<Void>,
  Pointer<Utf8>,
  int,
  int,
  int,
);

typedef _SourceOpenFileNative = Int32 Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Int32,
  Uint32,
);
typedef _SourceOpenFileDart = int Function(
  Pointer<Void>,
  Pointer<Utf8>,
  int,
  int,
);

typedef _SourceConnectNetworkNative = Int32 Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Int32,
  Uint32,
  Int32,
  Int32,
  Uint32,
);
typedef _SourceConnectNetworkDart = int Function(
  Pointer<Void>,
  Pointer<Utf8>,
  int,
  int,
  int,
  int,
  int,
);

typedef _SourceConnectSdrppServerNative = Int32 Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Int32,
  Uint32,
);
typedef _SourceConnectSdrppServerDart = int Function(
  Pointer<Void>,
  Pointer<Utf8>,
  int,
  int,
);

typedef _SourceConnectSpyServerNative = Int32 Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Int32,
  Uint32,
  Uint32,
);
typedef _SourceConnectSpyServerDart = int Function(
  Pointer<Void>,
  Pointer<Utf8>,
  int,
  int,
  int,
);

typedef _SourceConnectRfspaceNative = Int32 Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Int32,
  Uint32,
  Uint32,
  Int32,
);
typedef _SourceConnectRfspaceDart = int Function(
  Pointer<Void>,
  Pointer<Utf8>,
  int,
  int,
  int,
  int,
);

typedef _SourceConnectHermesNative = Int32 Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Int32,
  Uint32,
  Uint32,
  Int32,
);
typedef _SourceConnectHermesDart = int Function(
  Pointer<Void>,
  Pointer<Utf8>,
  int,
  int,
  int,
  int,
);

typedef _SourceConnectSpectranHttpNative = Int32 Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Int32,
  Uint32,
);
typedef _SourceConnectSpectranHttpDart = int Function(
  Pointer<Void>,
  Pointer<Utf8>,
  int,
  int,
);

typedef _SourceConnectRtlSdrFdNative = Int32 Function(
  Pointer<Void>,
  Int32,
  Uint32,
  Uint32,
);
typedef _SourceConnectRtlSdrFdDart = int Function(
  Pointer<Void>,
  int,
  int,
  int,
);

typedef _SourceSoapyAvailableNative = Int32 Function();
typedef _SourceSoapyAvailableDart = int Function();

typedef _SourceSoapyEnumerateNative = UintPtr Function(
  Pointer<Utf8>,
  Pointer<Uint8>,
  UintPtr,
);
typedef _SourceSoapyEnumerateDart = int Function(
  Pointer<Utf8>,
  Pointer<Uint8>,
  int,
);

typedef _SourceConnectSoapyNative = Int32 Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Uint32,
  Uint32,
  Double,
  Double,
  Int32,
  Uint32,
);
typedef _SourceConnectSoapyDart = int Function(
  Pointer<Void>,
  Pointer<Utf8>,
  int,
  int,
  double,
  double,
  int,
  int,
);

typedef _SourceSetDoubleNative = Int32 Function(Pointer<Void>, Double);
typedef _SourceSetDoubleDart = int Function(Pointer<Void>, double);

typedef _SourceVoidNative = Void Function(Pointer<Void>);
typedef _SourceVoidDart = void Function(Pointer<Void>);

typedef _SourceGetU32Native = Uint32 Function(Pointer<Void>);
typedef _SourceGetU32Dart = int Function(Pointer<Void>);

typedef _SourceBoolNative = Int32 Function(Pointer<Void>);
typedef _SourceBoolDart = int Function(Pointer<Void>);

typedef _SourceSetU32Native = Int32 Function(Pointer<Void>, Uint32);
typedef _SourceSetU32Dart = int Function(Pointer<Void>, int);

typedef _SourceSetI32Native = Int32 Function(Pointer<Void>, Int32);
typedef _SourceSetI32Dart = int Function(Pointer<Void>, int);

typedef _SourceReadAudioNative = UintPtr Function(
  Pointer<Void>,
  Pointer<Int16>,
  UintPtr,
);
typedef _SourceReadAudioDart = int Function(
  Pointer<Void>,
  Pointer<Int16>,
  int,
);

typedef _SourceReadSpectrumNative = UintPtr Function(
  Pointer<Void>,
  Pointer<Float>,
  UintPtr,
);
typedef _SourceReadSpectrumDart = int Function(
  Pointer<Void>,
  Pointer<Float>,
  int,
);

typedef _SourceErrorNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  UintPtr,
);
typedef _SourceErrorDart = int Function(
  Pointer<Void>,
  Pointer<Uint8>,
  int,
);

class NativeRtlTcpSourceBridge {
  NativeRtlTcpSourceBridge._(
    this._source,
    this._destroy,
    this._connect,
    this._openFile,
    this._connectNetwork,
    this._connectSdrppServer,
    this._connectSpyServer,
    this._connectRtlSdrFd,
    this._connectRfspace,
    this._connectHermes,
    this._connectSpectranHttp,
    this._soapyAvailable,
    this._soapyEnumerate,
    this._connectSoapy,
    this._getSoapyDriver,
    this._getSoapyHardware,
    this._setRfBandwidth,
    this._getKind,
    this._getSampleRate,
    this._getCenterFrequency,
    this._disconnect,
    this._isConnected,
    this._setFrequency,
    this._setSampleRate,
    this._setTunerAgc,
    this._setGainIndex,
    this._setGainTenthDb,
    this._setPpm,
    this._setRtlAgc,
    this._setDirectSampling,
    this._setOffsetTuning,
    this._setBiasTee,
    this._readAudio,
    this._readSpectrum,
    this._getLastError,
  ) {
    _audio = calloc<Int16>(_audioCapacity);
    _spectrum = calloc<Float>(_spectrumCapacity);
  }

  static const int _audioCapacity = 48000 * 2;
  static const int _spectrumCapacity = 256;

  final Pointer<Void> _source;
  final _SourceDestroyDart _destroy;
  final _SourceConnectDart _connect;
  final _SourceOpenFileDart _openFile;
  final _SourceConnectNetworkDart _connectNetwork;
  final _SourceConnectSdrppServerDart _connectSdrppServer;
  final _SourceConnectSpyServerDart _connectSpyServer;
  final _SourceConnectRtlSdrFdDart _connectRtlSdrFd;
  final _SourceConnectRfspaceDart _connectRfspace;
  final _SourceConnectHermesDart _connectHermes;
  final _SourceConnectSpectranHttpDart _connectSpectranHttp;
  final _SourceSoapyAvailableDart _soapyAvailable;
  final _SourceSoapyEnumerateDart _soapyEnumerate;
  final _SourceConnectSoapyDart _connectSoapy;
  final _SourceErrorDart _getSoapyDriver;
  final _SourceErrorDart _getSoapyHardware;
  final _SourceSetDoubleDart _setRfBandwidth;
  final _SourceBoolDart _getKind;
  final _SourceGetU32Dart _getSampleRate;
  final _SourceGetU32Dart _getCenterFrequency;
  final _SourceVoidDart _disconnect;
  final _SourceBoolDart _isConnected;
  final _SourceSetU32Dart _setFrequency;
  final _SourceSetU32Dart _setSampleRate;
  final _SourceSetI32Dart _setTunerAgc;
  final _SourceSetI32Dart _setGainIndex;
  final _SourceSetI32Dart _setGainTenthDb;
  final _SourceSetI32Dart _setPpm;
  final _SourceSetI32Dart _setRtlAgc;
  final _SourceSetI32Dart _setDirectSampling;
  final _SourceSetI32Dart _setOffsetTuning;
  final _SourceSetI32Dart _setBiasTee;
  final _SourceReadAudioDart _readAudio;
  final _SourceReadSpectrumDart _readSpectrum;
  final _SourceErrorDart _getLastError;

  late final Pointer<Int16> _audio;
  late final Pointer<Float> _spectrum;
  bool _disposed = false;

  static NativeRtlTcpSourceBridge? tryCreate(
    NativeDspBridge dsp,
  ) {
    try {
      final library = _openLibrary();
      final create = library.lookupFunction<
          _SourceCreateNative,
          _SourceCreateDart>('sdrpp_source_create');
      final destroy = library.lookupFunction<
          _SourceDestroyNative,
          _SourceDestroyDart>('sdrpp_source_destroy');
      final connect = library.lookupFunction<
          _SourceConnectNative,
          _SourceConnectDart>('sdrpp_source_connect_rtl_tcp');
      final openFile = library.lookupFunction<
          _SourceOpenFileNative,
          _SourceOpenFileDart>('sdrpp_source_open_file');
      final connectNetwork = library.lookupFunction<
          _SourceConnectNetworkNative,
          _SourceConnectNetworkDart>('sdrpp_source_connect_network');
      final connectSdrppServer = library.lookupFunction<
          _SourceConnectSdrppServerNative,
          _SourceConnectSdrppServerDart>(
        'sdrpp_source_connect_sdrpp_server',
      );
      final connectSpyServer = library.lookupFunction<
          _SourceConnectSpyServerNative,
          _SourceConnectSpyServerDart>(
        'sdrpp_source_connect_spyserver',
      );
      final connectRtlSdrFd = library.lookupFunction<
          _SourceConnectRtlSdrFdNative,
          _SourceConnectRtlSdrFdDart>(
        'sdrpp_source_connect_rtl_sdr_fd',
      );
      final connectRfspace = library.lookupFunction<
          _SourceConnectRfspaceNative,
          _SourceConnectRfspaceDart>(
        'sdrpp_source_connect_rfspace',
      );
      final connectHermes = library.lookupFunction<
          _SourceConnectHermesNative,
          _SourceConnectHermesDart>(
        'sdrpp_source_connect_hermes',
      );
      final connectSpectranHttp = library.lookupFunction<
          _SourceConnectSpectranHttpNative,
          _SourceConnectSpectranHttpDart>(
        'sdrpp_source_connect_spectran_http',
      );
      final soapyAvailable = library.lookupFunction<
          _SourceSoapyAvailableNative,
          _SourceSoapyAvailableDart>('sdrpp_source_soapy_available');
      final soapyEnumerate = library.lookupFunction<
          _SourceSoapyEnumerateNative,
          _SourceSoapyEnumerateDart>('sdrpp_source_soapy_enumerate');
      final connectSoapy = library.lookupFunction<
          _SourceConnectSoapyNative,
          _SourceConnectSoapyDart>('sdrpp_source_connect_soapy');
      final getSoapyDriver = library.lookupFunction<
          _SourceErrorNative,
          _SourceErrorDart>('sdrpp_source_get_soapy_driver');
      final getSoapyHardware = library.lookupFunction<
          _SourceErrorNative,
          _SourceErrorDart>('sdrpp_source_get_soapy_hardware');
      final setRfBandwidth = library.lookupFunction<
          _SourceSetDoubleNative,
          _SourceSetDoubleDart>('sdrpp_source_set_rf_bandwidth');
      final getKind = library.lookupFunction<
          _SourceBoolNative,
          _SourceBoolDart>('sdrpp_source_get_kind');
      final getSampleRate = library.lookupFunction<
          _SourceGetU32Native,
          _SourceGetU32Dart>('sdrpp_source_get_sample_rate');
      final getCenterFrequency = library.lookupFunction<
          _SourceGetU32Native,
          _SourceGetU32Dart>('sdrpp_source_get_center_frequency');
      final disconnect = library.lookupFunction<
          _SourceVoidNative,
          _SourceVoidDart>('sdrpp_source_disconnect');
      final isConnected = library.lookupFunction<
          _SourceBoolNative,
          _SourceBoolDart>('sdrpp_source_is_connected');
      final setFrequency = library.lookupFunction<
          _SourceSetU32Native,
          _SourceSetU32Dart>('sdrpp_source_set_frequency');
      final setSampleRate = library.lookupFunction<
          _SourceSetU32Native,
          _SourceSetU32Dart>('sdrpp_source_set_sample_rate');
      final setTunerAgc = library.lookupFunction<
          _SourceSetI32Native,
          _SourceSetI32Dart>('sdrpp_source_set_tuner_agc');
      final setGainIndex = library.lookupFunction<
          _SourceSetI32Native,
          _SourceSetI32Dart>('sdrpp_source_set_gain_index');
      final setGainTenthDb = library.lookupFunction<
          _SourceSetI32Native,
          _SourceSetI32Dart>('sdrpp_source_set_gain_tenth_db');
      final setPpm = library.lookupFunction<
          _SourceSetI32Native,
          _SourceSetI32Dart>('sdrpp_source_set_ppm');
      final setRtlAgc = library.lookupFunction<
          _SourceSetI32Native,
          _SourceSetI32Dart>('sdrpp_source_set_rtl_agc');
      final setDirectSampling = library.lookupFunction<
          _SourceSetI32Native,
          _SourceSetI32Dart>('sdrpp_source_set_direct_sampling');
      final setOffsetTuning = library.lookupFunction<
          _SourceSetI32Native,
          _SourceSetI32Dart>('sdrpp_source_set_offset_tuning');
      final setBiasTee = library.lookupFunction<
          _SourceSetI32Native,
          _SourceSetI32Dart>('sdrpp_source_set_bias_tee');
      final readAudio = library.lookupFunction<
          _SourceReadAudioNative,
          _SourceReadAudioDart>('sdrpp_source_read_audio');
      final readSpectrum = library.lookupFunction<
          _SourceReadSpectrumNative,
          _SourceReadSpectrumDart>('sdrpp_source_read_spectrum');
      final getLastError = library.lookupFunction<
          _SourceErrorNative,
          _SourceErrorDart>('sdrpp_source_get_last_error');

      final source = create(dsp.nativeHandle);
      if (source == nullptr) {
        return null;
      }

      return NativeRtlTcpSourceBridge._(
        source,
        destroy,
        connect,
        openFile,
        connectNetwork,
        connectSdrppServer,
        connectSpyServer,
        connectRtlSdrFd,
        connectRfspace,
        connectHermes,
        connectSpectranHttp,
        soapyAvailable,
        soapyEnumerate,
        connectSoapy,
        getSoapyDriver,
        getSoapyHardware,
        setRfBandwidth,
        getKind,
        getSampleRate,
        getCenterFrequency,
        disconnect,
        isConnected,
        setFrequency,
        setSampleRate,
        setTunerAgc,
        setGainIndex,
        setGainTenthDb,
        setPpm,
        setRtlAgc,
        setDirectSampling,
        setOffsetTuning,
        setBiasTee,
        readAudio,
        readSpectrum,
        getLastError,
      );
    } catch (_) {
      return null;
    }
  }

  static DynamicLibrary _openLibrary() {
    if (Platform.isAndroid) {
      return DynamicLibrary.open('libsdrpp_mobile.so');
    }
    if (Platform.isWindows) {
      return DynamicLibrary.open('sdrpp_mobile.dll');
    }
    if (Platform.isMacOS || Platform.isIOS) {
      return DynamicLibrary.process();
    }
    return DynamicLibrary.open('libsdrpp_mobile.so');
  }

  bool connect({
    required String host,
    required int port,
    required int sampleRateHz,
    required int frequencyHz,
  }) {
    if (_disposed) {
      return false;
    }

    final nativeHost = host.toNativeUtf8();
    try {
      return _connect(
            _source,
            nativeHost,
            port,
            sampleRateHz,
            frequencyHz,
          ) ==
          0;
    } finally {
      calloc.free(nativeHost);
    }
  }

  bool openFile({
    required String path,
    required bool float32Mode,
    int centerFrequencyHz = 0,
  }) {
    if (_disposed) {
      return false;
    }

    final nativePath = path.toNativeUtf8();
    try {
      return _openFile(
            _source,
            nativePath,
            float32Mode ? 1 : 0,
            centerFrequencyHz,
          ) ==
          0;
    } finally {
      calloc.free(nativePath);
    }
  }

  bool connectNetwork({
    required String host,
    required int port,
    required int sampleRateHz,
    required int protocol,
    required int sampleType,
    int centerFrequencyHz = 0,
  }) {
    if (_disposed) {
      return false;
    }

    final nativeHost = host.toNativeUtf8();
    try {
      return _connectNetwork(
            _source,
            nativeHost,
            port,
            sampleRateHz,
            protocol,
            sampleType,
            centerFrequencyHz,
          ) ==
          0;
    } finally {
      calloc.free(nativeHost);
    }
  }

  bool connectSdrppServer({
    required String host,
    required int port,
    required int frequencyHz,
  }) {
    if (_disposed) {
      return false;
    }

    final nativeHost = host.toNativeUtf8();
    try {
      return _connectSdrppServer(
            _source,
            nativeHost,
            port,
            frequencyHz,
          ) ==
          0;
    } finally {
      calloc.free(nativeHost);
    }
  }

  bool connectSpyServer({
    required String host,
    required int port,
    required int sampleRateHz,
    required int frequencyHz,
  }) {
    if (_disposed) {
      return false;
    }

    final nativeHost = host.toNativeUtf8();
    try {
      return _connectSpyServer(
            _source,
            nativeHost,
            port,
            sampleRateHz,
            frequencyHz,
          ) ==
          0;
    } finally {
      calloc.free(nativeHost);
    }
  }

  bool connectRtlSdrFd({
    required int systemFd,
    required int sampleRateHz,
    required int frequencyHz,
  }) {
    if (_disposed || systemFd < 0) {
      return false;
    }
    return _connectRtlSdrFd(
          _source,
          systemFd,
          sampleRateHz,
          frequencyHz,
        ) ==
        0;
  }

  bool connectRfspace({
    required String host,
    required int port,
    required int sampleRateHz,
    required int frequencyHz,
    required int gainDb,
  }) {
    if (_disposed) {
      return false;
    }
    final nativeHost = host.toNativeUtf8();
    try {
      return _connectRfspace(
            _source,
            nativeHost,
            port,
            sampleRateHz,
            frequencyHz,
            gainDb,
          ) ==
          0;
    } finally {
      calloc.free(nativeHost);
    }
  }

  bool connectHermes({
    required String host,
    required int port,
    required int sampleRateHz,
    required int frequencyHz,
    required int gainDb,
  }) {
    if (_disposed) {
      return false;
    }
    final nativeHost = host.toNativeUtf8();
    try {
      return _connectHermes(
            _source,
            nativeHost,
            port,
            sampleRateHz,
            frequencyHz,
            gainDb,
          ) ==
          0;
    } finally {
      calloc.free(nativeHost);
    }
  }

  bool connectSpectranHttp({
    required String host,
    required int port,
    required int frequencyHz,
  }) {
    if (_disposed) {
      return false;
    }
    final nativeHost = host.toNativeUtf8();
    try {
      return _connectSpectranHttp(
            _source,
            nativeHost,
            port,
            frequencyHz,
          ) ==
          0;
    } finally {
      calloc.free(nativeHost);
    }
  }

  bool get soapyAvailable =>
      !_disposed && _soapyAvailable() != 0;

  List<String> enumerateSoapy({String filter = ''}) {
    if (_disposed || _soapyAvailable() == 0) {
      return const <String>[];
    }
    const capacity = 16384;
    final out = calloc<Uint8>(capacity);
    final nativeFilter = filter.toNativeUtf8();
    try {
      final count = _soapyEnumerate(
        nativeFilter,
        out,
        capacity,
      );
      if (count <= 0) {
        return const <String>[];
      }
      return out
          .cast<Utf8>()
          .toDartString()
          .split('\n')
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toList(growable: false);
    } finally {
      calloc.free(nativeFilter);
      calloc.free(out);
    }
  }

  bool connectSoapy({
    required String deviceArgs,
    required int sampleRateHz,
    required int frequencyHz,
    required double rfBandwidthHz,
    required double gainDb,
    required bool agc,
    int channel = 0,
  }) {
    if (_disposed) {
      return false;
    }
    final nativeArgs = deviceArgs.toNativeUtf8();
    try {
      return _connectSoapy(
            _source,
            nativeArgs,
            sampleRateHz,
            frequencyHz,
            rfBandwidthHz,
            gainDb,
            agc ? 1 : 0,
            channel,
          ) ==
          0;
    } finally {
      calloc.free(nativeArgs);
    }
  }

  void setRfBandwidth(double bandwidthHz) {
    if (!_disposed) {
      _setRfBandwidth(_source, bandwidthHz);
    }
  }

  String _readSourceString(_SourceErrorDart fn) {
    if (_disposed) {
      return '';
    }
    const capacity = 256;
    final buffer = calloc<Uint8>(capacity);
    try {
      final count = fn(_source, buffer, capacity);
      if (count <= 0) {
        return '';
      }
      return buffer.cast<Utf8>().toDartString();
    } finally {
      calloc.free(buffer);
    }
  }

  String get soapyDriver => _readSourceString(_getSoapyDriver);
  String get soapyHardware => _readSourceString(_getSoapyHardware);

  int get kind => _disposed ? 0 : _getKind(_source);
  int get sampleRateHz =>
      _disposed ? 0 : _getSampleRate(_source);
  int get centerFrequencyHz =>
      _disposed ? 0 : _getCenterFrequency(_source);

  void disconnect() {
    if (!_disposed) {
      _disconnect(_source);
    }
  }

  bool get isConnected =>
      !_disposed && _isConnected(_source) != 0;

  void setFrequency(int value) {
    if (!_disposed) {
      _setFrequency(_source, value);
    }
  }

  void setSampleRate(int value) {
    if (!_disposed) {
      _setSampleRate(_source, value);
    }
  }

  void setTunerAgc(bool enabled) {
    if (!_disposed) {
      _setTunerAgc(_source, enabled ? 1 : 0);
    }
  }

  void setGainIndex(int index) {
    if (!_disposed) {
      _setGainIndex(_source, index);
    }
  }

  void setGainDb(double db) {
    if (!_disposed) {
      _setGainTenthDb(_source, (db * 10).round());
    }
  }

  void setPpm(int ppm) {
    if (!_disposed) {
      _setPpm(_source, ppm);
    }
  }

  void setRtlAgc(bool enabled) {
    if (!_disposed) {
      _setRtlAgc(_source, enabled ? 1 : 0);
    }
  }

  void setDirectSampling(int mode) {
    if (!_disposed) {
      _setDirectSampling(_source, mode);
    }
  }

  void setOffsetTuning(bool enabled) {
    if (!_disposed) {
      _setOffsetTuning(_source, enabled ? 1 : 0);
    }
  }

  void setBiasTee(bool enabled) {
    if (!_disposed) {
      _setBiasTee(_source, enabled ? 1 : 0);
    }
  }

  Uint8List readAudio() {
    if (_disposed) {
      return Uint8List(0);
    }
    final count = _readAudio(
      _source,
      _audio,
      _audioCapacity,
    );
    if (count <= 0) {
      return Uint8List(0);
    }
    return Uint8List.fromList(
      _audio.cast<Uint8>().asTypedList(
            count * sizeOf<Int16>(),
          ),
    );
  }

  Float32List? readSpectrum() {
    if (_disposed) {
      return null;
    }
    final count = _readSpectrum(
      _source,
      _spectrum,
      _spectrumCapacity,
    );
    if (count <= 0) {
      return null;
    }
    return Float32List.fromList(
      _spectrum.asTypedList(count),
    );
  }

  String get lastError {
    if (_disposed) {
      return '';
    }
    const capacity = 512;
    final buffer = calloc<Uint8>(capacity);
    try {
      final count = _getLastError(
        _source,
        buffer,
        capacity,
      );
      if (count <= 0) {
        return '';
      }
      return buffer.cast<Utf8>().toDartString();
    } finally {
      calloc.free(buffer);
    }
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disconnect(_source);
    _destroy(_source);
    calloc.free(_audio);
    calloc.free(_spectrum);
    _disposed = true;
  }
}
