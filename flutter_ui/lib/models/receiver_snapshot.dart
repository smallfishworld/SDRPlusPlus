import 'dart:typed_data';

class ReceiverSnapshot {
  ReceiverSnapshot({
    required this.frequencyHz,
    required this.sampleRateHz,
    required this.mode,
    required this.bandwidthHz,
    required this.spectrum,
    required this.waterfall,
  });

  int frequencyHz;
  int sampleRateHz;
  String mode;
  double bandwidthHz;
  Float32List spectrum;
  List<Float32List> waterfall;
}
