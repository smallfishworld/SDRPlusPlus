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

typedef _SetNoiseBlankerNative =
    Int32 Function(Pointer<Void>, Int32, Float);
typedef _SetNoiseBlankerDart =
    int Function(Pointer<Void>, int, double);

typedef _SetHighPassNative = Int32 Function(Pointer<Void>, Int32);
typedef _SetHighPassDart = int Function(Pointer<Void>, int);

typedef _SetDeemphasisNative = Int32 Function(Pointer<Void>, Int32);
typedef _SetDeemphasisDart = int Function(Pointer<Void>, int);

typedef _SetCtcssNative = Int32 Function(Pointer<Void>, Int32, Int32);
typedef _SetCtcssDart = int Function(Pointer<Void>, int, int);

typedef _GetCtcssNative = Int32 Function(
  Pointer<Void>,
  Pointer<Int32>,
  Pointer<Float>,
);
typedef _GetCtcssDart = int Function(
  Pointer<Void>,
  Pointer<Int32>,
  Pointer<Float>,
);

typedef _SetFmIfNrNative = Int32 Function(Pointer<Void>, Int32, Int32);
typedef _SetFmIfNrDart = int Function(Pointer<Void>, int, int);

typedef _SetAmAgcNative = Int32 Function(
  Pointer<Void>,
  Int32,
  Float,
  Float,
);
typedef _SetAmAgcDart = int Function(
  Pointer<Void>,
  int,
  double,
  double,
);

typedef _SetSsbAgcNative = Int32 Function(
  Pointer<Void>,
  Float,
  Float,
);
typedef _SetSsbAgcDart = int Function(
  Pointer<Void>,
  double,
  double,
);

typedef _SetCwOptionsNative = Int32 Function(
  Pointer<Void>,
  Int32,
  Float,
  Float,
);
typedef _SetCwOptionsDart = int Function(
  Pointer<Void>,
  int,
  double,
  double,
);

typedef _SetNfmOptionsNative = Int32 Function(Pointer<Void>, Int32);
typedef _SetNfmOptionsDart = int Function(Pointer<Void>, int);

typedef _SetNfmVoiceFilterNative = Int32 Function(Pointer<Void>, Int32);
typedef _SetNfmVoiceFilterDart = int Function(Pointer<Void>, int);

typedef _SetWfmOptionsNative = Int32 Function(
  Pointer<Void>,
  Int32,
  Int32,
  Int32,
);
typedef _SetWfmOptionsDart = int Function(
  Pointer<Void>,
  int,
  int,
  int,
);

typedef _GetRdsNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  UintPtr,
  Pointer<Uint8>,
  UintPtr,
);
typedef _GetRdsDart = int Function(
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
);

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
    this._handle,
    this._destroy,
    this._setSampleRate,
    this._setMode,
    this._setBandwidth,
    this._setSquelch,
    this._setNoiseBlanker,
    this._setHighPass,
    this._setDeemphasis,
    this._setCtcss,
    this._getCtcss,
    this._setFmIfNr,
    this._setAmAgc,
    this._setSsbAgc,
    this._setCwOptions,
    this._setNfmOptions,
    this._setNfmVoiceFilter,
    this._setWfmOptions,
    this._getRds,
    this._reset,
    this._process,
    this.backendName,
  ) {
    _iq = calloc<Uint8>(_maxIqBytes);
    _pcm = calloc<Int16>(_maxPcmSamples);
  }

  static const int _maxIqBytes = 256 * 1024;
  static const int _maxPcmSamples = 128 * 1024;

  final Pointer<Void> _handle;
  final _DestroyDart _destroy;
  final _SetSampleRateDart _setSampleRate;
  final _SetModeDart _setMode;
  final _SetBandwidthDart _setBandwidth;
  final _SetSquelchDart _setSquelch;
  final _SetNoiseBlankerDart _setNoiseBlanker;
  final _SetHighPassDart _setHighPass;
  final _SetDeemphasisDart _setDeemphasis;
  final _SetCtcssDart _setCtcss;
  final _GetCtcssDart _getCtcss;
  final _SetFmIfNrDart _setFmIfNr;
  final _SetAmAgcDart _setAmAgc;
  final _SetSsbAgcDart _setSsbAgc;
  final _SetCwOptionsDart _setCwOptions;
  final _SetNfmOptionsDart _setNfmOptions;
  final _SetNfmVoiceFilterDart _setNfmVoiceFilter;
  final _SetWfmOptionsDart _setWfmOptions;
  final _GetRdsDart _getRds;
  final _ResetDart _reset;
  final _ProcessDart _process;
  final String backendName;

  Pointer<Void> get nativeHandle => _handle;

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
      final setNoiseBlanker = library.lookupFunction<
          _SetNoiseBlankerNative,
          _SetNoiseBlankerDart>('sdrpp_dsp_set_noise_blanker');
      final setHighPass = library.lookupFunction<
          _SetHighPassNative,
          _SetHighPassDart>('sdrpp_dsp_set_high_pass');
      final setDeemphasis = library.lookupFunction<
          _SetDeemphasisNative,
          _SetDeemphasisDart>('sdrpp_dsp_set_deemphasis');
      final setCtcss = library.lookupFunction<
          _SetCtcssNative,
          _SetCtcssDart>('sdrpp_dsp_set_ctcss');
      final getCtcss = library.lookupFunction<
          _GetCtcssNative,
          _GetCtcssDart>('sdrpp_dsp_get_ctcss');
      final setFmIfNr = library.lookupFunction<
          _SetFmIfNrNative,
          _SetFmIfNrDart>('sdrpp_dsp_set_fm_ifnr');
      final setAmAgc = library.lookupFunction<
          _SetAmAgcNative,
          _SetAmAgcDart>('sdrpp_dsp_set_am_agc');
      final setSsbAgc = library.lookupFunction<
          _SetSsbAgcNative,
          _SetSsbAgcDart>('sdrpp_dsp_set_ssb_agc');
      final setCwOptions = library.lookupFunction<
          _SetCwOptionsNative,
          _SetCwOptionsDart>('sdrpp_dsp_set_cw_options');
      final setNfmOptions = library.lookupFunction<
          _SetNfmOptionsNative,
          _SetNfmOptionsDart>('sdrpp_dsp_set_nfm_options');
      final setNfmVoiceFilter = library.lookupFunction<
          _SetNfmVoiceFilterNative,
          _SetNfmVoiceFilterDart>('sdrpp_dsp_set_nfm_voice_filter');
      final setWfmOptions = library.lookupFunction<
          _SetWfmOptionsNative,
          _SetWfmOptionsDart>('sdrpp_dsp_set_wfm_options');
      final getRds = library.lookupFunction<
          _GetRdsNative,
          _GetRdsDart>('sdrpp_dsp_get_rds');
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
        handle,
        destroy,
        setSampleRate,
        setMode,
        setBandwidth,
        setSquelch,
        setNoiseBlanker,
        setHighPass,
        setDeemphasis,
        setCtcss,
        getCtcss,
        setFmIfNr,
        setAmAgc,
        setSsbAgc,
        setCwOptions,
        setNfmOptions,
        setNfmVoiceFilter,
        setWfmOptions,
        getRds,
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

  void setNoiseBlanker(bool enabled, double level) {
    if (!_disposed) {
      _setNoiseBlanker(_handle, enabled ? 1 : 0, level);
    }
  }

  void setHighPass(bool enabled) {
    if (!_disposed) {
      _setHighPass(_handle, enabled ? 1 : 0);
    }
  }

  void setDeemphasis(int modeUs) {
    if (!_disposed) {
      _setDeemphasis(_handle, modeUs);
    }
  }

  void setCtcss(int mode, int toneIndex) {
    if (!_disposed) {
      _setCtcss(_handle, mode, toneIndex);
    }
  }

  ({int toneIndex, double toneHz})? getCtcss() {
    if (_disposed) {
      return null;
    }
    final toneIndex = calloc<Int32>();
    final toneHz = calloc<Float>();
    try {
      final valid = _getCtcss(_handle, toneIndex, toneHz);
      if (valid == 0) {
        return null;
      }
      return (
        toneIndex: toneIndex.value,
        toneHz: toneHz.value.toDouble(),
      );
    } finally {
      calloc.free(toneIndex);
      calloc.free(toneHz);
    }
  }

  void setFmIfNr(bool enabled, int preset) {
    if (!_disposed) {
      _setFmIfNr(_handle, enabled ? 1 : 0, preset);
    }
  }

  void setAmAgc({
    required bool carrier,
    required double attackMs,
    required double decayMs,
  }) {
    if (!_disposed) {
      _setAmAgc(
        _handle,
        carrier ? 1 : 0,
        attackMs,
        decayMs,
      );
    }
  }

  void setSsbAgc({
    required double attackMs,
    required double decayMs,
  }) {
    if (!_disposed) {
      _setSsbAgc(_handle, attackMs, decayMs);
    }
  }

  void setCwOptions({
    required int toneHz,
    required double attackMs,
    required double decayMs,
  }) {
    if (!_disposed) {
      _setCwOptions(
        _handle,
        toneHz,
        attackMs,
        decayMs,
      );
    }
  }

  void setNfmOptions({required bool lowPass}) {
    if (!_disposed) {
      _setNfmOptions(_handle, lowPass ? 1 : 0);
    }
  }

  void setNfmVoiceFilter(bool enabled) {
    if (!_disposed) {
      _setNfmVoiceFilter(_handle, enabled ? 1 : 0);
    }
  }

  void setWfmOptions({
    required bool stereo,
    required bool lowPass,
    required bool rdsEnabled,
  }) {
    if (!_disposed) {
      _setWfmOptions(
        _handle,
        stereo ? 1 : 0,
        lowPass ? 1 : 0,
        rdsEnabled ? 1 : 0,
      );
    }
  }

  ({String programService, String radioText})? getRds() {
    if (_disposed) {
      return null;
    }

    const capacity = 160;
    final ps = calloc<Uint8>(capacity);
    final rt = calloc<Uint8>(capacity);
    try {
      final valid = _getRds(
        _handle,
        ps,
        capacity,
        rt,
        capacity,
      );
      if (valid == 0) {
        return null;
      }
      return (
        programService: ps.cast<Utf8>().toDartString().trim(),
        radioText: rt.cast<Utf8>().toDartString().trim(),
      );
    } finally {
      calloc.free(ps);
      calloc.free(rt);
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
            .asTypedList(sampleCount * sizeOf<Int16>());
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
