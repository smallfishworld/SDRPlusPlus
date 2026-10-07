import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _CreateNative = Pointer<Void> Function(Uint32, Int32, Float);
typedef _CreateDart = Pointer<Void> Function(int, int, double);

typedef _DestroyNative = Void Function(Pointer<Void>);
typedef _DestroyDart = void Function(Pointer<Void>);

typedef _SetSampleRateNative = Int32 Function(Pointer<Void>, Uint32);
typedef _SetSampleRateDart = int Function(Pointer<Void>, int);

typedef _SetModeNative = Int32 Function(Pointer<Void>, Int32);
typedef _SetModeDart = int Function(Pointer<Void>, int);

typedef _SetBandwidthNative = Int32 Function(Pointer<Void>, Float);
typedef _SetBandwidthDart = int Function(Pointer<Void>, double);

typedef _SetSquelchNative =
    Int32 Function(Pointer<Void>, Int32, Float);
typedef _SetSquelchDart =
    int Function(Pointer<Void>, int, double);

typedef _ResetNative = Void Function(Pointer<Void>);
typedef _ResetDart = void Function(Pointer<Void>);

typedef _ProcessNative = UintPtr Function(
  Pointer<Void>,
  Pointer<Uint8>,
  UintPtr,
  Pointer<Int16>,
  UintPtr,
);
typedef _ProcessDart = int Function(
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  Pointer<Int16>,
  int,
);

typedef _BackendNameNative = Pointer<Utf8> Function();
typedef _BackendNameDart = Pointer<Utf8> Function();

class NativeDspBridge {
  NativeDspBridge._(
    this._library,
    this._handle,
    this._destroy,
    this._setSampleRate,
    this._setMode,
    this._setBandwidth,
    this._setSquelch,
    this._reset,
    this._process,
    this.backendName,
  ) {
    _iq = calloc<Uint8>(_maxIqBytes);
    _pcm = calloc<Int16>(_maxPcmSamples);
  }

  static const int _maxIqBytes = 256 * 1024;
  static const int _maxPcmSamples = 128 * 1024;

  final DynamicLibrary _library;
  final Pointer<Void> _handle;
  final _DestroyDart _destroy;
  final _SetSampleRateDart _setSampleRate;
  final _SetModeDart _setMode;
  final _SetBandwidthDart _setBandwidth;
  final _SetSquelchDart _setSquelch;
  final _ResetDart _reset;
  final _ProcessDart _process;
  final String backendName;

  late final Pointer<Uint8> _iq;
  late final Pointer<Int16> _pcm;
  bool _disposed = false;

  static NativeDspBridge? tryCreate({
    int sampleRateHz = 1024000,
    String mode = 'AM',
    double bandwidthHz = 10000,
  }) {
    try {
      final library = _openLibrary();

      final create = library
          .lookupFunction<_CreateNative, _CreateDart>('sdrpp_dsp_create');
      final destroy = library
          .lookupFunction<_DestroyNative, _DestroyDart>('sdrpp_dsp_destroy');
      final setSampleRate = library.lookupFunction<
          _SetSampleRateNative,
          _SetSampleRateDart>('sdrpp_dsp_set_sample_rate');
      final setMode = library.lookupFunction<_SetModeNative, _SetModeDart>(
        'sdrpp_dsp_set_mode',
      );
      final setBandwidth = library.lookupFunction<
          _SetBandwidthNative,
          _SetBandwidthDart>('sdrpp_dsp_set_bandwidth');
      final setSquelch = library.lookupFunction<
          _SetSquelchNative,
          _SetSquelchDart>('sdrpp_dsp_set_squelch');
      final reset = library.lookupFunction<_ResetNative, _ResetDart>(
        'sdrpp_dsp_reset',
      );
      final process = library.lookupFunction<_ProcessNative, _ProcessDart>(
        'sdrpp_dsp_process_u8',
      );
      final backendNameFn = library.lookupFunction<
          _BackendNameNative,
          _BackendNameDart>('sdrpp_dsp_backend_name');

      final handle = create(
        sampleRateHz,
        modeId(mode),
        bandwidthHz,
      );
      if (handle == nullptr) {
        return null;
      }

      return NativeDspBridge._(
        library,
        handle,
        destroy,
        setSampleRate,
        setMode,
        setBandwidth,
        setSquelch,
        reset,
        process,
        backendNameFn().toDartString(),
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

  static int modeId(String mode) {
    return switch (mode) {
      'NFM' => 0,
      'WFM' => 1,
      'AM' => 2,
      'DSB' => 3,
      'USB' => 4,
      'CW' => 5,
      'LSB' => 6,
      'RAW' => 7,
      _ => 2,
    };
  }

  void setSampleRate(int sampleRateHz) {
    if (!_disposed) {
      _setSampleRate(_handle, sampleRateHz);
    }
  }

  void setMode(String mode) {
    if (!_disposed) {
      _setMode(_handle, modeId(mode));
    }
  }

  void setBandwidth(double bandwidthHz) {
    if (!_disposed) {
      _setBandwidth(_handle, bandwidthHz);
    }
  }

  void setSquelch(bool enabled, double levelDb) {
    if (!_disposed) {
      _setSquelch(_handle, enabled ? 1 : 0, levelDb);
    }
  }

  void reset() {
    if (!_disposed) {
      _reset(_handle);
    }
  }

  Uint8List process(Uint8List iqBytes) {
    if (_disposed || iqBytes.isEmpty) {
      return Uint8List(0);
    }

    var offset = 0;
    final output = BytesBuilder(copy: false);

    while (offset < iqBytes.length) {
      var chunkBytes = iqBytes.length - offset;
      if (chunkBytes > _maxIqBytes) {
        chunkBytes = _maxIqBytes;
      }
      // Keep I/Q pairs aligned at the FFI boundary.
      chunkBytes &= ~1;
      if (chunkBytes <= 0) {
        break;
      }

      final nativeIq = _iq.asTypedList(chunkBytes);
      nativeIq.setRange(
        0,
        chunkBytes,
        iqBytes,
        offset,
      );

      final sampleCount = _process(
        _handle,
        _iq,
        chunkBytes,
        _pcm,
        _maxPcmSamples,
      );

      if (sampleCount > 0) {
        final pcmBytes = _pcm
            .cast<Uint8>()
            .asTypedList(sampleCount * Int16.size);
        output.add(Uint8List.fromList(pcmBytes));
      }

      offset += chunkBytes;
    }

    return output.takeBytes();
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _destroy(_handle);
    calloc.free(_iq);
    calloc.free(_pcm);
  }
}
