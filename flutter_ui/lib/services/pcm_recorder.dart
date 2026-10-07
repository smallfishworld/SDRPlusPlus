import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

class PcmRecorder {
  RandomAccessFile? _file;
  String? _path;
  int _pcmBytes = 0;
  DateTime? _startedAt;

  bool get isRecording => _file != null;
  String? get path => _path;
  Duration get elapsed => _startedAt == null
      ? Duration.zero
      : DateTime.now().difference(_startedAt!);

  Future<String> start({
    required int frequencyHz,
    required String mode,
    int sampleRateHz = 48000,
  }) async {
    await stop();

    final dir = await getApplicationDocumentsDirectory();
    final recDir = Directory('${dir.path}/SDRPP Receiver/Recordings');
    if (!await recDir.exists()) {
      await recDir.create(recursive: true);
    }

    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final mhz = (frequencyHz / 1000000).toStringAsFixed(6);
    final filename = '${stamp}_${mhz}MHz_$mode.wav';
    final path = '${recDir.path}/$filename';

    final file = await File(path).open(mode: FileMode.write);
    await file.writeFrom(Uint8List(44)); // WAV header placeholder.
    _file = file;
    _path = path;
    _pcmBytes = 0;
    _startedAt = DateTime.now();
    _sampleRateHz = sampleRateHz;
    return path;
  }

  int _sampleRateHz = 48000;

  Future<void> addPcm(Uint8List pcm) async {
    final file = _file;
    if (file == null || pcm.isEmpty) {
      return;
    }
    await file.writeFrom(pcm);
    _pcmBytes += pcm.length;
  }

  Future<String?> stop() async {
    final file = _file;
    final path = _path;
    if (file == null) {
      return path;
    }

    final header = _wavHeader(
      sampleRate: _sampleRateHz,
      channels: 1,
      bitsPerSample: 16,
      pcmBytes: _pcmBytes,
    );
    await file.setPosition(0);
    await file.writeFrom(header);
    await file.flush();
    await file.close();

    _file = null;
    _startedAt = null;
    return path;
  }

  Uint8List _wavHeader({
    required int sampleRate,
    required int channels,
    required int bitsPerSample,
    required int pcmBytes,
  }) {
    final header = ByteData(44);
    void ascii(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        header.setUint8(offset + i, value.codeUnitAt(i));
      }
    }

    final bytesPerSample = bitsPerSample ~/ 8;
    final blockAlign = channels * bytesPerSample;
    final byteRate = sampleRate * blockAlign;

    ascii(0, 'RIFF');
    header.setUint32(4, 36 + pcmBytes, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little); // PCM
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, bitsPerSample, Endian.little);
    ascii(36, 'data');
    header.setUint32(40, pcmBytes, Endian.little);
    return header.buffer.asUint8List();
  }

  Future<void> dispose() async {
    await stop();
  }
}
