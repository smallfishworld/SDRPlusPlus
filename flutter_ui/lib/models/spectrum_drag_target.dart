import 'dart:math' as math;

/// A horizontal drag on the selected channel retunes its VFO; a drag
/// elsewhere pans the sampled RF spectrum without retuning that channel.
enum SpectrumDragTarget { vfo, pan }

/// Treat the entire highlighted passband and a 24 px touch target around
/// the VFO cursor as the tuning handle. Taps use separate tune-on-tap logic.
SpectrumDragTarget classifySpectrumDrag({
  required double touchX,
  required double vfoX,
  required double passbandWidth,
  required double viewWidth,
}) {
  if (viewWidth <= 1 || !touchX.isFinite || !vfoX.isFinite) {
    return SpectrumDragTarget.pan;
  }

  final hitRadius = math.max(24.0, passbandWidth / 2 + 12.0);
  return (touchX - vfoX).abs() <= hitRadius
      ? SpectrumDragTarget.vfo
      : SpectrumDragTarget.pan;
}
