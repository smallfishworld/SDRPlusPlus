import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';

class AudioOutput {
  AudioSource? _source;
  SoundHandle? _handle;
  bool _ready = false;
  double _volume = 0.72;

  bool get ready => _ready;
  double get volume => _volume;

  Future<void> start() async {
    final soloud = SoLoud.instance;
    if (!soloud.isInitialized) {
      await soloud.init(
        sampleRate: 48000,
        bufferSize: 2048,
        channels: Channels.stereo,
        lowLatency: true,
      );
    }

    await stopStream();

    final source = soloud.setBufferStream(
      maxBufferSizeDuration: const Duration(seconds: 8),
      bufferingType: BufferingType.released,
      // A few hundred milliseconds prevents network/DSP jitter from causing
      // audible stop-start playback while keeping SDR latency reasonable.
      bufferingTimeNeeds: 0.35,
      sampleRate: 48000,
      channels: Channels.mono,
      format: BufferType.s16le,
    );
    _source = source;
    _handle = soloud.play(source, volume: _volume);
    _ready = true;
  }

  void addPcm(Uint8List bytes) {
    final source = _source;
    if (!_ready || source == null || bytes.isEmpty) {
      return;
    }

    try {
      SoLoud.instance.addAudioDataStream(source, bytes);
    } catch (_) {
      // A transient full buffer should not take down the SDR stream.
    }
  }

  void setVolume(double value) {
    _volume = value.clamp(0.0, 1.0).toDouble();
    final handle = _handle;
    if (handle != null && SoLoud.instance.isInitialized) {
      SoLoud.instance.setVolume(handle, _volume);
    }
  }

  Future<void> stopStream() async {
    final source = _source;
    _source = null;
    _handle = null;
    _ready = false;

    if (source != null && SoLoud.instance.isInitialized) {
      try {
        await SoLoud.instance.disposeSource(source);
      } catch (_) {
        // Ignore shutdown races during reconnect/app close.
      }
    }
  }

  Future<void> dispose() async {
    await stopStream();
    if (SoLoud.instance.isInitialized) {
      await SoLoud.instance.deinitAsync();
    }
  }
}
