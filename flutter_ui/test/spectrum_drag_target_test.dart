import 'package:flutter_test/flutter_test.dart';
import 'package:sdrpp_flutter/models/spectrum_drag_target.dart';

void main() {
  group('Spectrum touch hit-testing', () {
    test('dragging the VFO line or a nearby finger target tunes', () {
      for (final x in [176.0, 195.0, 200.0, 220.0, 224.0]) {
        expect(
          classifySpectrumDrag(
            touchX: x,
            vfoX: 200,
            passbandWidth: 8,
            viewWidth: 400,
          ),
          SpectrumDragTarget.vfo,
        );
      }
    });

    test('dragging free spectrum space pans rather than retunes', () {
      for (final x in [0.0, 120.0, 175.0, 225.0, 399.0]) {
        expect(
          classifySpectrumDrag(
            touchX: x,
            vfoX: 200,
            passbandWidth: 8,
            viewWidth: 400,
          ),
          SpectrumDragTarget.pan,
        );
      }
    });

    test('wide demodulation passbands remain draggable for tuning', () {
      expect(
        classifySpectrumDrag(
          touchX: 250,
          vfoX: 200,
          passbandWidth: 80,
          viewWidth: 400,
        ),
        SpectrumDragTarget.vfo,
      );
      expect(
        classifySpectrumDrag(
          touchX: 255,
          vfoX: 200,
          passbandWidth: 80,
          viewWidth: 400,
        ),
        SpectrumDragTarget.pan,
      );
    });

    test('invalid view geometry never starts accidental tuning', () {
      expect(
        classifySpectrumDrag(
          touchX: 0,
          vfoX: 0,
          passbandWidth: 0,
          viewWidth: 0,
        ),
        SpectrumDragTarget.pan,
      );
    });
  });
}
