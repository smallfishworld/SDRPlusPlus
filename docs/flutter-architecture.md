# SDR++ Flutter Architecture

This branch replaces the desktop-oriented ImGui presentation layer with one shared modern Flutter UI for Android, iOS, Windows and macOS. SDR/DSP work stays native.

## Platform support

| Platform | Flutter UI | RTL-TCP / network SDR | Direct USB RTL-SDR |
| --- | --- | --- | --- |
| Android | Yes | Yes | Planned via USB Host |
| iOS | Yes | Yes | Not a primary target; iOS does not offer general-purpose raw USB host access for arbitrary RTL-SDR dongles |
| Windows | Yes | Yes | Planned through native librtlsdr |
| macOS | Yes | Yes | Planned through native librtlsdr |

RTL-TCP is the first common transport across all four platforms.

## Layers

```text
Flutter UI
  Receiver / Presets / Scanner / Settings
          |
          | dart:ffi
          v
Stable C ABI
  mobile/native/include/sdrpp_mobile_api.h
          |
          v
Native SDR engine
  source -> DSP -> demod -> audio
          |
          +--> 1024/2048-bin FFT frames -> Flutter renderer
          +--> native/platform audio path
```

Flutter should not receive raw multi-megasample IQ unless required for a feature. Native code owns the high-rate path. The UI receives control/state events and downsampled spectrum frames.

## UI goals

- Material 3 inspired dark interface rather than desktop panels.
- Frequency is a first-class control with a large touch keypad.
- Spectrum and waterfall dominate the receiver screen.
- AM/NFM/WFM/USB/LSB are one-tap controls.
- Source configuration lives in Settings, not permanently on the receiver screen.
- Responsive navigation: bottom bar on phones, navigation rail on larger screens and desktops.
- One UI codebase with platform-specific capabilities exposed through the engine.

## Migration

The earlier `android-mobile-ui` ImGui work remains an experiment and should not be merged into `master`.

This branch starts from clean `master` and adds Flutter incrementally:

1. Flutter receiver shell and responsive design.
2. Stable C ABI.
3. RTL-TCP engine and FFT bridge.
4. AM/NFM/WFM/USB/LSB demodulation.
5. Audio sinks.
6. Presets and scanner.
7. Direct USB RTL-SDR on Android/Windows/macOS.
