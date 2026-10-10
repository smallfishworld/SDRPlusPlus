import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/sdr_module_catalog.dart';
import '../services/android_usb_service.dart';
import '../services/audio_output.dart';
import '../services/pcm_recorder.dart';
import '../services/rtl_tcp_client.dart';

class ReceiverScreen extends StatefulWidget {
  const ReceiverScreen({super.key});

  @override
  State<ReceiverScreen> createState() => _ReceiverScreenState();
}

class _ReceiverScreenState extends State<ReceiverScreen> {
  final RtlTcpClient _client = RtlTcpClient();
  final AudioOutput _audio = AudioOutput();
  final PcmRecorder _recorder = PcmRecorder();
  final TextEditingController _hostController =
      TextEditingController(text: '192.168.2.110');
  final TextEditingController _portController =
      TextEditingController(text: '1234');
  final TextEditingController _networkHostController =
      TextEditingController(text: '127.0.0.1');
  final TextEditingController _networkPortController =
      TextEditingController(text: '1234');
  final TextEditingController _sdrppServerHostController =
      TextEditingController(text: '127.0.0.1');
  final TextEditingController _sdrppServerPortController =
      TextEditingController(text: '50000');
  final TextEditingController _spyServerHostController =
      TextEditingController(text: '127.0.0.1');
  final TextEditingController _spyServerPortController =
      TextEditingController(text: '5555');
  final TextEditingController _nativeRemoteHostController =
      TextEditingController(text: '127.0.0.1');
  final TextEditingController _nativeRemotePortController =
      TextEditingController(text: '50000');
  final TextEditingController _soapyArgsController =
      TextEditingController(text: 'driver=rtlsdr');
  final TextEditingController _soapySampleRateController =
      TextEditingController(text: '2048000');
  final TextEditingController _soapyBandwidthController =
      TextEditingController(text: '0');
  final TextEditingController _soapyChannelController =
      TextEditingController(text: '0');
  int _nativeRemoteGainDb = 0;
  double _soapyGainDb = 0;
  List<String> _soapyDevices = const <String>[];
  List<AndroidSdrUsbDevice> _soapyUsbDevices =
      const <AndroidSdrUsbDevice>[];
  String? _soapyUsbDeviceName;
  bool _soapyRefreshing = false;

  StreamSubscription<Float32List>? _spectrumSubscription;
  StreamSubscription<Uint8List>? _audioSubscription;
  StreamSubscription<String>? _backendSubscription;
  StreamSubscription<({String programService, String radioText})>?
      _rdsSubscription;
  StreamSubscription<({int toneIndex, double toneHz})>?
      _ctcssSubscription;
  StreamSubscription<RtlTcpConnectionState>? _stateSubscription;
  Timer? _scannerTimer;
  Timer? _retuneAudioTimer;
  Timer? _recordUiTimer;
  String? _lastRecordingPath;

  ReceiverSourceKind _selectedSourceKind = ReceiverSourceKind.rtlTcp;
  String _iqFilePath = '';
  bool _iqFileFloat32 = false;
  int _networkProtocol = 0; // 0 TCP client, 1 UDP
  int _networkSampleType = 1; // 0 I8, 1 I16, 2 I32, 3 F32
  List<AndroidRtlSdrDevice> _rtlUsbDevices =
      const <AndroidRtlSdrDevice>[];
  String? _rtlUsbDeviceName;
  bool _rtlUsbRefreshing = false;

  int _tab = 0;
  String _presetCategory = 'All';
  int _frequencyHz = 127250000;
  int _centerFrequencyHz = 127250000;
  int? _panPreviewCenterFrequencyHz;
  int _panStartCenterFrequencyHz = 127250000;
  double _panDragTotalPx = 0;
  int _sampleRateHz = 2400000;
  String _mode = 'AM';
  double _bandwidthKhz = 10;
  bool _tunerAgc = false;
  bool _rtlAgc = false;
  bool _biasTee = false;
  bool _offsetTuning = false;
  int _directSampling = 0;
  int _ppm = 0;
  double _manualGainDb = 0;
  bool _squelchEnabled = false;
  double _squelchDb = -82;
  bool _noiseBlankerEnabled = false;
  double _noiseBlankerLevel = 10;
  bool _highPassEnabled = false;
  int _deemphasisUs = 50;

  int _ctcssMode = 0; // 0 off, 1 decode-only, 2 mute
  int _ctcssToneIndex = -2; // -2 = any valid tone
  double _detectedCtcssHz = 0;
  bool _fmIfNrEnabled = false;
  int _fmIfNrPreset = 1; // Voice
  String _fmProfile = 'Clean';

  bool _amCarrierAgc = false;
  double _amAgcAttackMs = 50;
  double _amAgcDecayMs = 5;
  double _ssbAgcAttackMs = 50;
  double _ssbAgcDecayMs = 5;
  int _cwToneHz = 800;
  double _cwAgcAttackMs = 100;
  double _cwAgcDecayMs = 5;
  bool _nfmLowPass = true;
  bool _nfmVoiceFilter = true;
  bool _wfmStereo = false;
  bool _wfmLowPass = true;
  bool _wfmRdsEnabled = true;

  double _volume = 0.72;
  int _tuningStepHz = 25000;
  bool _scanning = false;
  int _scanFrequencyHz = 118000000;
  RtlTcpConnectionState _connectionState =
      RtlTcpConnectionState.disconnected;
  String _connectionError = '';
  String _dspBackend = 'Detecting DSP backend…';
  String _rdsProgramService = '';
  String _rdsRadioText = '';

  Float32List _spectrum = Float32List(256);
  final List<Float32List> _waterfall = <Float32List>[];
  final List<int> _scanHits = <int>[];

  static const List<String> _modes = <String>[
    'AM',
    'NFM',
    'WFM',
    'USB',
    'LSB',
    'DSB',
    'CW',
    'RAW',
  ];

  static const List<int> _tuningSteps = <int>[
    10,
    100,
    500,
    1000,
    2500,
    5000,
    8330,
    10000,
    12500,
    25000,
    100000,
  ];

  static const List<double> _ctcssTones = <double>[
    67.0, 69.3, 71.9, 74.4, 77.0, 79.7, 82.5, 85.4, 88.5,
    91.5, 94.8, 97.4, 100.0, 103.5, 107.2, 110.9, 114.8,
    118.8, 123.0, 127.3, 131.8, 136.5, 141.3, 146.2, 150.0,
    151.4, 156.7, 159.8, 162.2, 165.5, 167.9, 171.3, 173.8,
    177.3, 179.9, 183.5, 186.2, 189.9, 192.8, 196.6, 199.5,
    203.5, 206.5, 210.7, 218.1, 225.7, 229.1, 233.6, 241.8,
    250.3, 254.1,
  ];

  static const List<_Preset> _presets = <_Preset>[
    // Hangzhou / Xiaoshan airband.
    _Preset('Hangzhou ATIS', 127250000, 'AM', 10000, 'Airband'),
    _Preset('Hangzhou Tower', 118300000, 'AM', 10000, 'Airband'),
    _Preset('Hangzhou Tower 2', 123650000, 'AM', 10000, 'Airband'),
    _Preset('Hangzhou Ground', 121650000, 'AM', 10000, 'Airband'),
    _Preset('Hangzhou Delivery', 121950000, 'AM', 10000, 'Airband'),
    _Preset('Hangzhou Approach', 125550000, 'AM', 10000, 'Airband'),
    _Preset('Hangzhou Approach 2', 126050000, 'AM', 10000, 'Airband'),

    // Hangzhou / Zhejiang public FM broadcasting.
    _Preset('浙江之声', 88000000, 'WFM', 150000, 'Hangzhou FM'),
    _Preset('杭州之声', 89000000, 'WFM', 150000, 'Hangzhou FM'),
    _Preset('Z907 城市资讯', 90700000, 'WFM', 150000, 'Hangzhou FM'),
    _Preset('杭州交通 918', 91800000, 'WFM', 150000, 'Hangzhou FM'),
    _Preset('浙江交通之声', 93000000, 'WFM', 150000, 'Hangzhou FM'),
    _Preset('浙江经济广播', 95000000, 'WFM', 150000, 'Hangzhou FM'),
    _Preset('动听 968', 96800000, 'WFM', 150000, 'Hangzhou FM'),
    _Preset('浙江民生资讯', 99600000, 'WFM', 150000, 'Hangzhou FM'),
    _Preset('浙江旅游之声', 104500000, 'WFM', 150000, 'Hangzhou FM'),
    _Preset('西湖之声', 105400000, 'WFM', 150000, 'Hangzhou FM'),
    _Preset('浙江城市之声', 107000000, 'WFM', 150000, 'Hangzhou FM'),

    // Common amateur-radio receive presets around Hangzhou.
    _Preset('杭州 2m 常用直频', 145100000, 'NFM', 12500, 'Amateur Radio'),
    _Preset('BR5AI 杭州中继下行', 145400000, 'NFM', 12500, 'Amateur Radio'),
    _Preset('UHF 常用直频', 438500000, 'NFM', 12500, 'Amateur Radio'),
  ];

  @override
  void initState() {
    super.initState();
    _spectrumSubscription = _client.spectrumStream.listen((frame) {
      if (!mounted) {
        return;
      }
      setState(() {
        _spectrum = frame;
        _waterfall.insert(0, Float32List.fromList(frame));
        if (_waterfall.length > 92) {
          _waterfall.removeLast();
        }
      });
    });
    _audioSubscription = _client.audioStream.listen((pcm) {
      _audio.addPcm(pcm);
      unawaited(_recorder.addPcm(pcm));
    });
    _backendSubscription = _client.backendStream.listen((name) {
      if (!mounted) {
        return;
      }
      setState(() => _dspBackend = name);
    });
    _rdsSubscription = _client.rdsStream.listen((rds) {
      if (!mounted) {
        return;
      }
      setState(() {
        _rdsProgramService = rds.programService;
        _rdsRadioText = rds.radioText;
      });
    });
    _ctcssSubscription = _client.ctcssStream.listen((tone) {
      if (!mounted) {
        return;
      }
      setState(() {
        _detectedCtcssHz = tone.toneHz;
      });
    });
    _stateSubscription = _client.stateStream.listen((state) {
      if (!mounted) {
        return;
      }
      setState(() {
        _connectionState = state;
        _connectionError = _client.lastError;
      });
    });
  }

  @override
  void dispose() {
    _scannerTimer?.cancel();
    _retuneAudioTimer?.cancel();
    _recordUiTimer?.cancel();
    unawaited(_spectrumSubscription?.cancel());
    unawaited(_audioSubscription?.cancel());
    unawaited(_backendSubscription?.cancel());
    unawaited(_rdsSubscription?.cancel());
    unawaited(_ctcssSubscription?.cancel());
    unawaited(_stateSubscription?.cancel());
    unawaited(_client.dispose());
    unawaited(_audio.dispose());
    unawaited(_recorder.dispose());
    _hostController.dispose();
    _portController.dispose();
    _networkHostController.dispose();
    _networkPortController.dispose();
    _sdrppServerHostController.dispose();
    _sdrppServerPortController.dispose();
    _spyServerHostController.dispose();
    _spyServerPortController.dispose();
    _nativeRemoteHostController.dispose();
    _nativeRemotePortController.dispose();
    _soapyArgsController.dispose();
    _soapySampleRateController.dispose();
    _soapyBandwidthController.dispose();
    _soapyChannelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 840;

    return Scaffold(
      body: SafeArea(
        child: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                Color(0xFF0A0E13),
                Color(0xFF080B10),
              ],
            ),
          ),
          child: wide
              ? Row(
                  children: <Widget>[
                    _navigationRail(),
                    const VerticalDivider(width: 1, color: Color(0xFF1B2632)),
                    Expanded(child: _currentPage()),
                  ],
                )
              : _currentPage(),
        ),
      ),
      bottomNavigationBar: wide ? null : _bottomNavigation(),
    );
  }

  Widget _currentPage() {
    switch (_tab) {
      case 1:
        return _presetsPage();
      case 2:
        return _scannerPage();
      case 3:
        return _recordPage();
      case 4:
        return _settingsPage();
      default:
        return _receiverPage();
    }
  }

  Widget _navigationRail() {
    return NavigationRail(
      selectedIndex: _tab,
      onDestinationSelected: (value) => setState(() => _tab = value),
      labelType: NavigationRailLabelType.all,
      groupAlignment: -0.75,
      destinations: const <NavigationRailDestination>[
        NavigationRailDestination(
          icon: Icon(Icons.graphic_eq_rounded),
          selectedIcon: Icon(Icons.graphic_eq_rounded),
          label: Text('Receive'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.star_outline_rounded),
          selectedIcon: Icon(Icons.star_rounded),
          label: Text('Presets'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.radar_rounded),
          label: Text('Scanner'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.fiber_manual_record_outlined),
          selectedIcon: Icon(Icons.fiber_manual_record_rounded),
          label: Text('Record'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.tune_rounded),
          label: Text('Settings'),
        ),
      ],
    );
  }

  Widget _bottomNavigation() {
    return NavigationBar(
      selectedIndex: _tab,
      onDestinationSelected: (value) => setState(() => _tab = value),
      destinations: const <NavigationDestination>[
        NavigationDestination(
          icon: Icon(Icons.graphic_eq_rounded),
          label: 'Receive',
        ),
        NavigationDestination(
          icon: Icon(Icons.star_outline_rounded),
          selectedIcon: Icon(Icons.star_rounded),
          label: 'Presets',
        ),
        NavigationDestination(
          icon: Icon(Icons.radar_rounded),
          label: 'Scanner',
        ),
        NavigationDestination(
          icon: Icon(Icons.fiber_manual_record_outlined),
          selectedIcon: Icon(Icons.fiber_manual_record_rounded),
          label: 'Record',
        ),
        NavigationDestination(
          icon: Icon(Icons.tune_rounded),
          label: 'Settings',
        ),
      ],
    );
  }

  Widget _receiverPage() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        children: <Widget>[
          _appHeader('Receiver'),
          const SizedBox(height: 14),
          _frequencyCard(),
          if (_mode == 'WFM' &&
              (_rdsProgramService.isNotEmpty ||
                  _rdsRadioText.isNotEmpty)) ...<Widget>[
            const SizedBox(height: 10),
            _rdsCard(),
          ],
          const SizedBox(height: 14),
          Expanded(child: _spectrumCard()),
          const SizedBox(height: 14),
          _modePanel(),
        ],
      ),
    );
  }

  Widget _appHeader(String title) {
    return Row(
      children: <Widget>[
        const _BrandMark(size: 38),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'SDR++ Receiver',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            Text(
              title,
              style: const TextStyle(
                color: Color(0xFF7E90A5),
                fontSize: 12,
              ),
            ),
          ],
        ),
        const Spacer(),
        _connectionPill(),
      ],
    );
  }

  Widget _connectionPill() {
    final connected = _connectionState == RtlTcpConnectionState.connected;
    final connecting = _connectionState == RtlTcpConnectionState.connecting;
    final color = connected
        ? const Color(0xFF69F0AE)
        : connecting
            ? const Color(0xFFFFD166)
            : const Color(0xFF708090);
    final label = connected
        ? 'Orange Pi'
        : connecting
            ? 'Connecting'
            : 'Offline';

    return InkWell(
      onTap: () => setState(() => _tab = 4),
      borderRadius: BorderRadius.circular(99),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF111923),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: const Color(0xFF213040)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 7),
            Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _frequencyCard() {
    final mhz = _frequencyHz / 1000000.0;
    final subtitle = _presetNameFor(_frequencyHz);

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: _showFrequencyPad,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 15, 14, 15),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      mhz.toStringAsFixed(6),
                      style: const TextStyle(
                        fontSize: 34,
                        height: 1,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(height: 7),
                    Row(
                      children: <Widget>[
                        const Text(
                          'MHz',
                          style: TextStyle(
                            color: Color(0xFF67E8F9),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (subtitle.isNotEmpty || _rdsProgramService.isNotEmpty)
                          ...<Widget>[
                            const SizedBox(width: 8),
                            const Text(
                              '·',
                              style: TextStyle(color: Color(0xFF526377)),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                _rdsProgramService.isNotEmpty
                                    ? _rdsProgramService
                                    : subtitle,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFF8EA0B5),
                                ),
                              ),
                            ),
                          ],
                      ],
                    ),
                  ],
                ),
              ),
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: const Color(0xFF17232F),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.dialpad_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _rdsCard() {
    if (_mode != 'WFM' ||
        (_rdsProgramService.isEmpty && _rdsRadioText.isEmpty)) {
      return const SizedBox.shrink();
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          children: <Widget>[
            const Icon(
              Icons.radio_rounded,
              color: Color(0xFF67E8F9),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (_rdsProgramService.isNotEmpty)
                    Text(
                      _rdsProgramService,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  if (_rdsRadioText.isNotEmpty)
                    Text(
                      _rdsRadioText,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF8193A7),
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
            const Text(
              'RDS',
              style: TextStyle(
                color: Color(0xFF67E8F9),
                fontWeight: FontWeight.w800,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _spectrumCard() {
    final streamLabel = _connectionState == RtlTcpConnectionState.connected
        ? '${(_sampleRateHz / 1000000).toStringAsFixed(3)} MSPS'
        : 'No RF stream';

    return LayoutBuilder(
      builder: (context, constraints) => Card(
        clipBehavior: Clip.antiAlias,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) => _handleSpectrumTap(
            details.localPosition.dx,
            constraints.maxWidth,
          ),
          onHorizontalDragStart: (_) => _dragAccumulatorPx = 0,
          onHorizontalDragUpdate: (details) =>
              _handleSpectrumDrag(details.primaryDelta ?? 0),
          onHorizontalDragEnd: (_) => _dragAccumulatorPx = 0,
          onDoubleTap: _showFrequencyPad,
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: Column(
                  children: <Widget>[
                    Expanded(
                      flex: 43,
                      child: CustomPaint(
                        painter: SpectrumPainter(
                          spectrum: _spectrum,
                          centerFrequencyHz: _frequencyHz,
                          sampleRateHz: _sampleRateHz,
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                    const Divider(height: 1, color: Color(0xFF1B2835)),
                    Expanded(
                      flex: 57,
                      child: CustomPaint(
                        painter: WaterfallPainter(
                          history: _waterfall,
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                left: 12,
                top: 10,
                child: _tinyBadge(streamLabel),
              ),
              Positioned(
                right: 12,
                top: 10,
                child: _tinyBadge(
                  '$_mode · Peak Δ ${_currentPeakAboveNoise().toStringAsFixed(1)} dB',
                ),
              ),
              Positioned(
                left: 12,
                bottom: 10,
                child: _tinyBadge(
                  'Tap/drag to tune · step ${_formatStep(_tuningStepHz)}',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tinyBadge(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xCC0B1118),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: const Color(0xFF263747)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFFB8C6D5),
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _modePanel() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          children: <Widget>[
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: <Widget>[
                  for (final mode in _modes)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: SizedBox(
                        width: 72,
                        child: _modeButton(mode),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                _metric(
                  'BW',
                  _bandwidthKhz >= 100
                      ? '${_bandwidthKhz.toStringAsFixed(0)} kHz'
                      : '${_bandwidthKhz.toStringAsFixed(1)} kHz',
                  _showBandwidthSheet,
                ),
                _squelchQuickMetric(),
                _metric(
                  'GAIN',
                  _tunerAgc ? 'Auto' : '${_manualGainDb.toStringAsFixed(1)} dB',
                  _showGainSheet,
                ),
                _metric(
                  'VOL',
                  '${(_volume * 100).round()}%',
                  _showVolumeSheet,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _modeButton(String mode) {
    final selected = _mode == mode;
    return InkWell(
      onTap: () {
        setState(() {
          _mode = mode;
          _bandwidthKhz = switch (mode) {
            'WFM' => 150,
            'NFM' => 12.5,
            'AM' => 10,
            'USB' || 'LSB' => 2.8,
            'DSB' => 4.6,
            'CW' => 0.2,
            'RAW' => 48,
            _ => 10,
          };
          _tuningStepHz = switch (mode) {
            'WFM' => 100000,
            'NFM' => 2500,
            'AM' => 1000,
            'USB' || 'LSB' || 'DSB' => 100,
            'CW' => 10,
            'RAW' => 2500,
            _ => 1000,
          };
          if (mode != 'NFM') {
            _ctcssMode = 0;
            _detectedCtcssHz = 0;
          }
          if (mode == 'WFM') {
            // Broadcast music should default to the same full 15 kHz stereo
            // path users expect from desktop SDR++. Weak-signal mono/IFNR
            // remains available as the "Weak" profile.
            _fmIfNrEnabled = false;
            _fmIfNrPreset = 3;
            _fmProfile = 'Stereo';
            _wfmStereo = true;
            _wfmLowPass = true;
            _deemphasisUs = 50;
            _highPassEnabled = false;
            _noiseBlankerEnabled = false;
          }
          else if (mode == 'NFM') {
            // Handheld-style communications profile: keep the official FM
            // detector low-pass, suppress IF noise and limit recovered audio
            // to the voice band instead of exposing discriminator hiss.
            _fmIfNrEnabled = true;
            _fmIfNrPreset = 1;
            _highPassEnabled = true;
            _nfmLowPass = true;
            _nfmVoiceFilter = true;
            _noiseBlankerEnabled = false;
          }
          else {
            _fmIfNrEnabled = false;
          }
        });
        _client.setMode(mode);
        _client.setBandwidth(_bandwidthKhz * 1000);
        _applyRadioDetailOptions();
      },
      borderRadius: BorderRadius.circular(13),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(13),
          color: selected
              ? const Color(0xFF193D47)
              : const Color(0xFF111A23),
          border: Border.all(
            color: selected
                ? const Color(0xFF67E8F9)
                : const Color(0xFF1E2C39),
          ),
        ),
        child: Text(
          mode,
          style: TextStyle(
            color: selected
                ? const Color(0xFF9AF2FF)
                : const Color(0xFF93A5B9),
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _squelchQuickMetric() {
    final enabled = _squelchEnabled;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(13),
        onTap: _toggleSquelch,
        onLongPress: _showSquelchSheet,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(13),
            color: enabled
                ? const Color(0x1F35D0FF)
                : Colors.transparent,
            border: Border.all(
              color: enabled
                  ? const Color(0xFF35D0FF)
                  : Colors.transparent,
            ),
          ),
          child: Column(
            children: <Widget>[
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Icon(
                    enabled
                        ? Icons.volume_off_rounded
                        : Icons.volume_up_rounded,
                    size: 13,
                    color: enabled
                        ? const Color(0xFF6FE3FF)
                        : const Color(0xFF607286),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'SQL',
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 0.8,
                      color: enabled
                          ? const Color(0xFF6FE3FF)
                          : const Color(0xFF607286),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                enabled
                    ? 'ON ${_squelchDb.toStringAsFixed(0)}'
                    : 'OFF',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: enabled
                      ? const Color(0xFF9DEBFF)
                      : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _toggleSquelch() {
    final enabled = !_squelchEnabled;
    setState(() {
      _squelchEnabled = enabled;
      if (enabled) {
        // Power squelch and tone squelch are mutually exclusive, matching
        // SDR++ RadioModule semantics.
        _ctcssMode = 0;
        _detectedCtcssHz = 0;
      }
    });

    _client.setSquelch(enabled, _squelchDb);
    if (enabled) {
      _client.setCtcss(0, _ctcssToneIndex);
    }
  }

  Widget _metric(String label, String value, VoidCallback onTap) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(13),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            children: <Widget>[
              Text(
                label,
                style: const TextStyle(
                  fontSize: 10,
                  letterSpacing: 0.8,
                  color: Color(0xFF607286),
                ),
              ),
              const SizedBox(height: 3),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _presetsPage() {
    final filtered = _presetCategory == 'All'
        ? _presets
        : _presets
            .where((preset) => preset.category == _presetCategory)
            .toList(growable: false);
    const categories = <String>[
      'All',
      'Airband',
      'Hangzhou FM',
      'Amateur Radio',
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        children: <Widget>[
          _appHeader('Presets'),
          const SizedBox(height: 14),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                for (final category in categories)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      selected: _presetCategory == category,
                      label: Text(category),
                      onSelected: (_) =>
                          setState(() => _presetCategory = category),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ListView.separated(
              itemCount: filtered.length,
              separatorBuilder: (_, __) => const SizedBox(height: 9),
              itemBuilder: (context, index) {
                final preset = filtered[index];
                final subtitle =
                    '${(preset.frequencyHz / 1000000).toStringAsFixed(3)} MHz  ·  ${preset.category}';
                return Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 7,
                    ),
                    leading: Container(
                      width: 42,
                      height: 42,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: const Color(0xFF132630),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        preset.mode,
                        style: const TextStyle(
                          color: Color(0xFF67E8F9),
                          fontWeight: FontWeight.w800,
                          fontSize: 11,
                        ),
                      ),
                    ),
                    title: Text(
                      preset.name,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(subtitle),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () {
                      _applyPreset(preset);
                      setState(() => _tab = 0);
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _scannerPage() {
    final snr = _currentPeakAboveNoise();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _appHeader('Airband Scanner'),
          const SizedBox(height: 18),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      const Text(
                        '118.000',
                        style: TextStyle(color: Color(0xFF8091A6)),
                      ),
                      const Expanded(
                        child: Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12),
                          child: Divider(color: Color(0xFF263746)),
                        ),
                      ),
                      Text(
                        (_scanFrequencyHz / 1000000).toStringAsFixed(3),
                        style: const TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF67E8F9),
                        ),
                      ),
                      const Expanded(
                        child: Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12),
                          child: Divider(color: Color(0xFF263746)),
                        ),
                      ),
                      const Text(
                        '137.000',
                        style: TextStyle(color: Color(0xFF8091A6)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    '25 kHz step · peak +${snr.toStringAsFixed(1)} dB',
                    style: const TextStyle(color: Color(0xFF8294A9)),
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _toggleScanner,
                      icon: Icon(
                        _scanning
                            ? Icons.stop_rounded
                            : Icons.play_arrow_rounded,
                      ),
                      label: Text(_scanning ? 'Stop scanning' : 'Start scanning'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'Detected activity',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _scanHits.isEmpty
                ? const Center(
                    child: Text(
                      'No activity captured yet',
                      style: TextStyle(color: Color(0xFF6E8094)),
                    ),
                  )
                : ListView.builder(
                    itemCount: _scanHits.length,
                    itemBuilder: (context, index) {
                      final frequency = _scanHits[index];
                      return ListTile(
                        leading: const Icon(Icons.wifi_tethering_rounded),
                        title: Text(
                          '${(frequency / 1000000).toStringAsFixed(3)} MHz',
                        ),
                        subtitle: const Text('Activity detected'),
                        trailing: IconButton(
                          onPressed: () {
                            _tuneFrequency(frequency);
                            setState(() => _tab = 0);
                          },
                          icon: const Icon(Icons.play_arrow_rounded),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _recordPage() {
    final connected = _connectionState == RtlTcpConnectionState.connected;
    final recording = _recorder.isRecording;
    final elapsed = _recorder.elapsed;
    final mm = elapsed.inMinutes.toString().padLeft(2, '0');
    final ss = (elapsed.inSeconds % 60).toString().padLeft(2, '0');

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _appHeader('Recorder'),
          const SizedBox(height: 18),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: <Widget>[
                  Container(
                    width: 84,
                    height: 84,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: recording
                          ? const Color(0x33FF4D6D)
                          : const Color(0xFF121C27),
                      border: Border.all(
                        color: recording
                            ? const Color(0xFFFF4D6D)
                            : const Color(0xFF2A3A49),
                        width: 2,
                      ),
                    ),
                    child: Icon(
                      recording
                          ? Icons.stop_rounded
                          : Icons.mic_none_rounded,
                      size: 38,
                      color: recording
                          ? const Color(0xFFFF7388)
                          : const Color(0xFF8FA2B6),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    recording ? '$mm:$ss' : 'Ready to record',
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${(_frequencyHz / 1000000).toStringAsFixed(6)} MHz · $_mode · 48 kHz stereo WAV',
                    style: const TextStyle(color: Color(0xFF8193A7)),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: !connected && !recording
                          ? null
                          : recording
                              ? _stopRecording
                              : _startRecording,
                      style: recording
                          ? FilledButton.styleFrom(
                              backgroundColor: const Color(0xFFFF4D6D),
                              foregroundColor: Colors.white,
                            )
                          : null,
                      icon: Icon(
                        recording
                            ? Icons.stop_rounded
                            : Icons.fiber_manual_record_rounded,
                      ),
                      label: Text(
                        recording ? 'Stop recording' : 'Start recording',
                      ),
                    ),
                  ),
                  if (!connected && !recording) ...<Widget>[
                    const SizedBox(height: 10),
                    const Text(
                      'Connect a receiver before recording.',
                      style: TextStyle(color: Color(0xFF6E8094)),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Card(
            child: ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('Last recording'),
              subtitle: Text(
                _lastRecordingPath ??
                    'WAV recordings are stored in the app documents folder.',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          const SizedBox(height: 14),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Recording captures the demodulated 48 kHz stereo PCM stream produced by the active SDR++ DSP backend. Frequency and demodulation mode are included in the filename.',
                style: TextStyle(
                  color: Color(0xFF8193A7),
                  height: 1.45,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _startRecording() async {
    final path = await _recorder.start(
      frequencyHz: _frequencyHz,
      mode: _mode,
    );
    _lastRecordingPath = path;
    _recordUiTimer?.cancel();
    _recordUiTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (mounted) {
          setState(() {});
        }
      },
    );
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _stopRecording() async {
    _recordUiTimer?.cancel();
    _recordUiTimer = null;
    final path = await _recorder.stop();
    if (mounted) {
      setState(() => _lastRecordingPath = path);
    }
  }

  Widget _sourceSettingsCard(bool connected) {
    final isRtlTcp = _selectedSourceKind == ReceiverSourceKind.rtlTcp;
    final backendText = connected
        ? (_client.usingNativeSource
            ? switch (_client.sourceKind) {
                ReceiverSourceKind.rtlTcp =>
                  'Backend: official SDR++ native rtl_tcp client',
                ReceiverSourceKind.file =>
                  'Backend: official SDR++ native File Source',
                ReceiverSourceKind.network =>
                  'Backend: official SDR++ native Network Source',
                ReceiverSourceKind.sdrppServer =>
                  'Backend: official SDR++ Server protocol runtime',
                ReceiverSourceKind.spyServer =>
                  'Backend: official SpyServer protocol runtime',
                ReceiverSourceKind.rtlSdrUsb =>
                  'Backend: official librtlsdr USB runtime',
                ReceiverSourceKind.rfspace =>
                  'Backend: official RFspace native protocol runtime',
                ReceiverSourceKind.hermes =>
                  'Backend: official Hermes/OpenHPSDR native runtime',
                ReceiverSourceKind.spectranHttp =>
                  'Backend: official Spectran HTTP native runtime',
                ReceiverSourceKind.soapy =>
                  'Backend: SoapySDR · ${_client.soapyDriver.isEmpty ? 'generic hardware' : _client.soapyDriver}${_client.soapyHardware.isEmpty ? '' : ' / ${_client.soapyHardware}'}',
              }
            : 'Backend: Dart compatibility transport')
        : 'Backend: native SDR++ source runtime';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text(
              'Source',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 5),
            const Text(
              'Native sources include RTL-TCP, direct RTL-SDR USB, network protocols and generic SoapySDR hardware discovery.',
              style: TextStyle(color: Color(0xFF7F91A5)),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<ReceiverSourceKind>(
              initialValue: _selectedSourceKind,
              decoration: const InputDecoration(
                labelText: 'Source adapter',
                prefixIcon: Icon(Icons.sensors_rounded),
                border: OutlineInputBorder(),
              ),
              items: const <DropdownMenuItem<ReceiverSourceKind>>[
                DropdownMenuItem(
                  value: ReceiverSourceKind.rtlTcp,
                  child: Text('RTL-TCP'),
                ),
                DropdownMenuItem(
                  value: ReceiverSourceKind.file,
                  child: Text('IQ File'),
                ),
                DropdownMenuItem(
                  value: ReceiverSourceKind.network,
                  child: Text('Network Source'),
                ),
                DropdownMenuItem(
                  value: ReceiverSourceKind.sdrppServer,
                  child: Text('SDR++ Server'),
                ),
                DropdownMenuItem(
                  value: ReceiverSourceKind.spyServer,
                  child: Text('SpyServer'),
                ),
                DropdownMenuItem(
                  value: ReceiverSourceKind.rtlSdrUsb,
                  child: Text('RTL-SDR USB (Android)'),
                ),
                DropdownMenuItem(
                  value: ReceiverSourceKind.rfspace,
                  child: Text('RFspace'),
                ),
                DropdownMenuItem(
                  value: ReceiverSourceKind.hermes,
                  child: Text('Hermes / OpenHPSDR'),
                ),
                DropdownMenuItem(
                  value: ReceiverSourceKind.spectranHttp,
                  child: Text('Spectran HTTP'),
                ),
                DropdownMenuItem(
                  value: ReceiverSourceKind.soapy,
                  child: Text('SoapySDR · Generic Hardware'),
                ),
              ],
              onChanged: connected
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() => _selectedSourceKind = value);
                        if (value == ReceiverSourceKind.rtlSdrUsb) {
                          unawaited(_refreshRtlUsbDevices());
                        }
                        if (value == ReceiverSourceKind.soapy) {
                          unawaited(_refreshSoapyDevices());
                        }
                        if (value == ReceiverSourceKind.rfspace) {
                          _nativeRemotePortController.text = '50000';
                        } else if (value == ReceiverSourceKind.hermes) {
                          _nativeRemotePortController.text = '1024';
                        } else if (value == ReceiverSourceKind.spectranHttp) {
                          _nativeRemotePortController.text = '54664';
                        }
                      }
                    },
            ),
            const SizedBox(height: 8),
            Text(
              backendText,
              style: const TextStyle(
                color: Color(0xFF67E8F9),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 18),
            if (isRtlTcp) ..._rtlTcpSourceControls(connected),
            if (_selectedSourceKind == ReceiverSourceKind.file)
              ..._fileSourceControls(connected),
            if (_selectedSourceKind == ReceiverSourceKind.network)
              ..._networkSourceControls(connected),
            if (_selectedSourceKind == ReceiverSourceKind.sdrppServer)
              ..._sdrppServerSourceControls(connected),
            if (_selectedSourceKind == ReceiverSourceKind.spyServer)
              ..._spyServerSourceControls(connected),
            if (_selectedSourceKind == ReceiverSourceKind.rtlSdrUsb)
              ..._rtlSdrUsbSourceControls(connected),
            if (_selectedSourceKind == ReceiverSourceKind.rfspace ||
                _selectedSourceKind == ReceiverSourceKind.hermes ||
                _selectedSourceKind == ReceiverSourceKind.spectranHttp)
              ..._nativeRemoteSourceControls(connected),
            if (_selectedSourceKind == ReceiverSourceKind.soapy)
              ..._soapySourceControls(connected),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: connected ? _disconnect : _connectSelectedSource,
              icon: Icon(
                connected
                    ? Icons.link_off_rounded
                    : switch (_selectedSourceKind) {
                        ReceiverSourceKind.rtlTcp => Icons.link_rounded,
                        ReceiverSourceKind.file => Icons.play_arrow_rounded,
                        ReceiverSourceKind.network => Icons.hub_rounded,
                        ReceiverSourceKind.sdrppServer =>
                          Icons.dns_rounded,
                        ReceiverSourceKind.spyServer =>
                          Icons.wifi_tethering_rounded,
                        ReceiverSourceKind.rtlSdrUsb =>
                          Icons.usb_rounded,
                        ReceiverSourceKind.rfspace =>
                          Icons.router_rounded,
                        ReceiverSourceKind.hermes =>
                          Icons.settings_input_antenna_rounded,
                        ReceiverSourceKind.spectranHttp =>
                          Icons.language_rounded,
                        ReceiverSourceKind.soapy =>
                          Icons.memory_rounded,
                      },
              ),
              label: Text(
                connected
                    ? 'Disconnect'
                    : switch (_selectedSourceKind) {
                        ReceiverSourceKind.rtlTcp =>
                          'Connect to receiver',
                        ReceiverSourceKind.file => 'Open IQ file',
                        ReceiverSourceKind.network =>
                          'Connect Network Source',
                        ReceiverSourceKind.sdrppServer =>
                          'Connect SDR++ Server',
                        ReceiverSourceKind.spyServer =>
                          'Connect SpyServer',
                        ReceiverSourceKind.rtlSdrUsb =>
                          'Open RTL-SDR USB',
                        ReceiverSourceKind.rfspace =>
                          'Connect RFspace',
                        ReceiverSourceKind.hermes =>
                          'Connect Hermes',
                        ReceiverSourceKind.spectranHttp =>
                          'Connect Spectran HTTP',
                        ReceiverSourceKind.soapy =>
                          'Open SoapySDR device',
                      },
              ),
            ),
            if (_connectionError.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                _connectionError,
                style: const TextStyle(
                  color: Color(0xFFFF7A8D),
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _rtlTcpSourceControls(bool connected) {
    return <Widget>[
      TextField(
        controller: _hostController,
        enabled: !connected,
        decoration: const InputDecoration(
          labelText: 'Host',
          prefixIcon: Icon(Icons.dns_outlined),
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _portController,
        enabled: !connected,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          labelText: 'Port',
          prefixIcon: Icon(Icons.lan_outlined),
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<int>(
        key: ValueKey<int>(_sampleRateHz),
        initialValue: _sampleRateHz,
        decoration: const InputDecoration(
          labelText: 'Sample rate',
          prefixIcon: Icon(Icons.speed_rounded),
          border: OutlineInputBorder(),
        ),
        items: const <DropdownMenuItem<int>>[
          DropdownMenuItem(
            value: 1024000,
            child: Text('1.024 MSPS'),
          ),
          DropdownMenuItem(
            value: 2048000,
            child: Text('2.048 MSPS'),
          ),
          DropdownMenuItem(
            value: 2400000,
            child: Text('2.400 MSPS'),
          ),
        ],
        onChanged: (value) {
          if (value == null) {
            return;
          }
          setState(() => _sampleRateHz = value);
          _client.setSampleRate(value);
        },
      ),
      const SizedBox(height: 10),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Tuner AGC'),
        subtitle: const Text('Automatic tuner gain control'),
        value: _tunerAgc,
        onChanged: (value) {
          setState(() => _tunerAgc = value);
          _client.setTunerAgc(value);
          if (!value) {
            _client.setGainDb(_manualGainDb);
          }
        },
      ),
      if (!_tunerAgc) ...<Widget>[
        Text(
          'Manual gain  ${_manualGainDb.toStringAsFixed(1)} dB',
        ),
        Slider(
          value: _manualGainDb,
          min: -9.9,
          max: 19.7,
          divisions: 296,
          label: '${_manualGainDb.toStringAsFixed(1)} dB',
          onChanged: (value) {
            setState(() => _manualGainDb = value);
            _client.setGainDb(value);
          },
        ),
      ],
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('RTL AGC'),
        subtitle: const Text('RTL2832 digital AGC'),
        value: _rtlAgc,
        onChanged: (value) {
          setState(() => _rtlAgc = value);
          _client.setRtlAgc(value);
        },
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Bias-T'),
        subtitle: const Text(
          'Enable antenna bias power when supported',
        ),
        value: _biasTee,
        onChanged: (value) {
          setState(() => _biasTee = value);
          _client.setBiasTee(value);
        },
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Offset tuning'),
        value: _offsetTuning,
        onChanged: (value) {
          setState(() => _offsetTuning = value);
          _client.setOffsetTuning(value);
        },
      ),
      const SizedBox(height: 8),
      DropdownButtonFormField<int>(
        key: ValueKey<String>('direct-$_directSampling'),
        initialValue: _directSampling,
        decoration: const InputDecoration(
          labelText: 'Direct sampling',
          prefixIcon: Icon(Icons.swap_vert_rounded),
          border: OutlineInputBorder(),
        ),
        items: const <DropdownMenuItem<int>>[
          DropdownMenuItem(value: 0, child: Text('Disabled')),
          DropdownMenuItem(value: 1, child: Text('I branch')),
          DropdownMenuItem(value: 2, child: Text('Q branch')),
        ],
        onChanged: (value) {
          if (value == null) {
            return;
          }
          setState(() => _directSampling = value);
          _client.setDirectSampling(value);
        },
      ),
      const SizedBox(height: 14),
      Text('Frequency correction  $_ppm ppm'),
      Slider(
        value: _ppm.toDouble(),
        min: -100,
        max: 100,
        divisions: 200,
        label: '$_ppm ppm',
        onChanged: (value) {
          final ppm = value.round();
          setState(() => _ppm = ppm);
          _client.setPpm(ppm);
        },
      ),
    ];
  }

  List<Widget> _fileSourceControls(bool connected) {
    final fileName = _iqFilePath.isEmpty
        ? 'No IQ WAV selected'
        : _iqFilePath.split(RegExp(r'[/\\]')).last;

    return <Widget>[
      OutlinedButton.icon(
        onPressed: connected ? null : _pickIqFile,
        icon: const Icon(Icons.folder_open_rounded),
        label: Text(
          fileName,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      const SizedBox(height: 8),
      const Text(
        'Supports SDR++ File Source compatible stereo 16-bit IQ WAV files. Float32 IQ can be enabled for files recorded in that format. If the filename contains “145100000Hz”, the center frequency is detected automatically.',
        style: TextStyle(
          color: Color(0xFF7F91A5),
          fontSize: 12,
          height: 1.4,
        ),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Float32 IQ'),
        subtitle: const Text(
          'Match the upstream SDR++ File Source Float32 mode',
        ),
        value: _iqFileFloat32,
        onChanged: connected
            ? null
            : (value) => setState(() => _iqFileFloat32 = value),
      ),
      if (connected &&
          _client.sourceKind == ReceiverSourceKind.file)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.info_outline_rounded),
          title: Text(
            '${(_sampleRateHz / 1000000).toStringAsFixed(3)} MSPS',
          ),
          subtitle: Text(
            'File center: ${(_client.frequencyHz / 1000000).toStringAsFixed(6)} MHz',
          ),
        ),
    ];
  }

  List<Widget> _networkSourceControls(bool connected) {
    const sampleTypes = <String>[
      'Int8 IQ',
      'Int16 IQ',
      'Int32 IQ',
      'Float32 IQ',
    ];

    return <Widget>[
      TextField(
        controller: _networkHostController,
        enabled: !connected,
        decoration: const InputDecoration(
          labelText: 'Remote host',
          prefixIcon: Icon(Icons.dns_outlined),
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _networkPortController,
        enabled: !connected,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          labelText: 'Port',
          prefixIcon: Icon(Icons.lan_outlined),
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<int>(
        initialValue: _networkProtocol,
        decoration: const InputDecoration(
          labelText: 'Protocol',
          prefixIcon: Icon(Icons.swap_horiz_rounded),
          border: OutlineInputBorder(),
        ),
        items: const <DropdownMenuItem<int>>[
          DropdownMenuItem(
            value: 0,
            child: Text('TCP client'),
          ),
          DropdownMenuItem(
            value: 1,
            child: Text('UDP'),
          ),
        ],
        onChanged: connected
            ? null
            : (value) {
                if (value != null) {
                  setState(() => _networkProtocol = value);
                }
              },
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<int>(
        initialValue: _networkSampleType,
        decoration: const InputDecoration(
          labelText: 'IQ sample type',
          prefixIcon: Icon(Icons.data_object_rounded),
          border: OutlineInputBorder(),
        ),
        items: <DropdownMenuItem<int>>[
          for (var i = 0; i < sampleTypes.length; i++)
            DropdownMenuItem(
              value: i,
              child: Text(sampleTypes[i]),
            ),
        ],
        onChanged: connected
            ? null
            : (value) {
                if (value != null) {
                  setState(() => _networkSampleType = value);
                }
              },
      ),
      const SizedBox(height: 12),
      Text(
        'Sample rate  ${(_sampleRateHz / 1000000).toStringAsFixed(3)} MSPS',
      ),
      Slider(
        value: _sampleRateHz.toDouble(),
        min: 250000,
        max: 3200000,
        divisions: 59,
        label:
            '${(_sampleRateHz / 1000000).toStringAsFixed(3)} MSPS',
        onChanged: connected
            ? null
            : (value) {
                setState(
                  () => _sampleRateHz =
                      (value / 50000).round() * 50000,
                );
              },
      ),
      const Text(
        'Matches the upstream SDR++ Network Source: TCP client/UDP with Int8, Int16, Int32 or Float32 interleaved IQ.',
        style: TextStyle(
          color: Color(0xFF7F91A5),
          fontSize: 12,
          height: 1.4,
        ),
      ),
    ];
  }

  List<Widget> _sdrppServerSourceControls(bool connected) {
    return <Widget>[
      TextField(
        controller: _sdrppServerHostController,
        enabled: !connected,
        decoration: const InputDecoration(
          labelText: 'SDR++ Server host',
          prefixIcon: Icon(Icons.dns_outlined),
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _sdrppServerPortController,
        enabled: !connected,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          labelText: 'Port',
          prefixIcon: Icon(Icons.lan_outlined),
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 10),
      const Text(
        'Uses the upstream SDR++ Server wire protocol. The server owns the source sample rate; the mobile runtime follows sample-rate changes automatically and feeds the same native DSP chain.',
        style: TextStyle(
          color: Color(0xFF7F91A5),
          fontSize: 12,
          height: 1.4,
        ),
      ),
      if (connected &&
          _client.sourceKind == ReceiverSourceKind.sdrppServer) ...<Widget>[
        const SizedBox(height: 8),
        Text(
          'Server sample rate: ${(_sampleRateHz / 1000000).toStringAsFixed(3)} MSPS',
          style: const TextStyle(color: Color(0xFF67E8F9)),
        ),
      ],
    ];
  }

  List<Widget> _spyServerSourceControls(bool connected) {
    return <Widget>[
      TextField(
        controller: _spyServerHostController,
        enabled: !connected,
        decoration: const InputDecoration(
          labelText: 'SpyServer host',
          prefixIcon: Icon(Icons.dns_outlined),
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _spyServerPortController,
        enabled: !connected,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          labelText: 'Port',
          prefixIcon: Icon(Icons.lan_outlined),
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),
      Text(
        'Requested sample rate  ${(_sampleRateHz / 1000000).toStringAsFixed(3)} MSPS',
      ),
      Slider(
        value: _sampleRateHz.toDouble().clamp(250000, 3200000),
        min: 250000,
        max: 3200000,
        divisions: 59,
        label:
            '${(_sampleRateHz / 1000000).toStringAsFixed(3)} MSPS',
        onChanged: connected
            ? null
            : (value) {
                setState(
                  () => _sampleRateHz =
                      (value / 50000).round() * 50000,
                );
              },
      ),
      const Text(
        'The nearest decimation stage advertised by the SpyServer is selected automatically. Int16 IQ is requested unless the server forces another supported IQ format.',
        style: TextStyle(
          color: Color(0xFF7F91A5),
          fontSize: 12,
          height: 1.4,
        ),
      ),
    ];
  }

  List<Widget> _nativeRemoteSourceControls(bool connected) {
    final isSpectran =
        _selectedSourceKind == ReceiverSourceKind.spectranHttp;
    final isRfspace =
        _selectedSourceKind == ReceiverSourceKind.rfspace;
    final title = switch (_selectedSourceKind) {
      ReceiverSourceKind.rfspace => 'RFspace',
      ReceiverSourceKind.hermes => 'Hermes / OpenHPSDR',
      ReceiverSourceKind.spectranHttp => 'Spectran HTTP',
      _ => 'Native source',
    };

    return <Widget>[
      TextField(
        controller: _nativeRemoteHostController,
        enabled: !connected,
        decoration: InputDecoration(
          labelText: '$title host',
          prefixIcon: const Icon(Icons.dns_outlined),
          border: const OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _nativeRemotePortController,
        enabled: !connected,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          labelText: 'Port',
          prefixIcon: Icon(Icons.lan_outlined),
          border: OutlineInputBorder(),
        ),
      ),
      if (!isSpectran) ...<Widget>[
        const SizedBox(height: 12),
        Text(
          'Requested sample rate  ${(_sampleRateHz / 1000).round()} kSPS',
        ),
        Slider(
          value: _sampleRateHz.toDouble().clamp(
                _selectedSourceKind == ReceiverSourceKind.hermes
                    ? 48000
                    : 50000,
                _selectedSourceKind == ReceiverSourceKind.hermes
                    ? 384000
                    : 2000000,
              ),
          min: _selectedSourceKind == ReceiverSourceKind.hermes
              ? 48000
              : 50000,
          max: _selectedSourceKind == ReceiverSourceKind.hermes
              ? 384000
              : 2000000,
          divisions: _selectedSourceKind == ReceiverSourceKind.hermes
              ? 7
              : 39,
          onChanged: connected
              ? null
              : (value) =>
                  setState(() => _sampleRateHz = value.round()),
        ),
      ],
      if (!isSpectran) ...<Widget>[
        const SizedBox(height: 8),
        Text(
          isRfspace
              ? 'RF gain  $_nativeRemoteGainDb dB'
              : 'LNA gain  $_nativeRemoteGainDb dB',
        ),
        Slider(
          value: _nativeRemoteGainDb.toDouble().clamp(
                isRfspace ? -30 : 0,
                isRfspace ? 0 : 60,
              ),
          min: isRfspace ? -30 : 0,
          max: isRfspace ? 0 : 60,
          divisions: isRfspace ? 30 : 60,
          onChanged: connected
              ? null
              : (value) => setState(
                    () => _nativeRemoteGainDb = value.round(),
                  ),
        ),
      ],
      const SizedBox(height: 8),
      Text(
        switch (_selectedSourceKind) {
          ReceiverSourceKind.rfspace =>
            'Uses SDR++ RFspace TCP/UDP control and complex IQ streaming.',
          ReceiverSourceKind.hermes =>
            'Uses SDR++ Hermes/OpenHPSDR Metis protocol with 48/96/192/384 kSPS.',
          ReceiverSourceKind.spectranHttp =>
            'Uses SDR++ Spectran HTTP streaming and follows device-reported center frequency/sample rate.',
          _ => '',
        },
        style: const TextStyle(
          color: Color(0xFF7F91A5),
          fontSize: 12,
          height: 1.4,
        ),
      ),
    ];
  }

  List<Widget> _rtlSdrUsbSourceControls(bool connected) {
    final supported = AndroidUsbService.supported;
    return <Widget>[
      if (!supported)
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text(
            'Direct USB is currently available on Android. Windows/macOS use the desktop SDR++ hardware source path in a later packaging step.',
            style: TextStyle(color: Color(0xFFFFB86B), height: 1.4),
          ),
        ),
      Row(
        children: <Widget>[
          Expanded(
            child: DropdownButtonFormField<String>(
              key: ValueKey<String?>(
                'rtl-usb-$_rtlUsbDeviceName-${_rtlUsbDevices.length}',
              ),
              initialValue: _rtlUsbDevices.any(
                (device) => device.deviceName == _rtlUsbDeviceName,
              )
                  ? _rtlUsbDeviceName
                  : null,
              decoration: const InputDecoration(
                labelText: 'RTL-SDR USB device',
                prefixIcon: Icon(Icons.usb_rounded),
                border: OutlineInputBorder(),
              ),
              items: <DropdownMenuItem<String>>[
                for (final device in _rtlUsbDevices)
                  DropdownMenuItem<String>(
                    value: device.deviceName,
                    child: Text(
                      '${device.productName}  ${device.vidPid}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: connected || !supported
                  ? null
                  : (value) =>
                      setState(() => _rtlUsbDeviceName = value),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            tooltip: 'Refresh USB devices',
            onPressed: connected || !supported || _rtlUsbRefreshing
                ? null
                : _refreshRtlUsbDevices,
            icon: _rtlUsbRefreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<int>(
        key: ValueKey<String>('usb-sr-$_sampleRateHz'),
        initialValue: <int>[1024000, 2048000, 2400000]
                .contains(_sampleRateHz)
            ? _sampleRateHz
            : 1024000,
        decoration: const InputDecoration(
          labelText: 'Sample rate',
          prefixIcon: Icon(Icons.speed_rounded),
          border: OutlineInputBorder(),
        ),
        items: const <DropdownMenuItem<int>>[
          DropdownMenuItem(value: 1024000, child: Text('1.024 MSPS')),
          DropdownMenuItem(value: 2048000, child: Text('2.048 MSPS')),
          DropdownMenuItem(value: 2400000, child: Text('2.400 MSPS')),
        ],
        onChanged: connected
            ? null
            : (value) {
                if (value != null) {
                  setState(() => _sampleRateHz = value);
                }
              },
      ),
      const SizedBox(height: 8),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Tuner AGC'),
        value: _tunerAgc,
        onChanged: (value) {
          setState(() => _tunerAgc = value);
          if (connected) {
            _client.setTunerAgc(value);
          }
        },
      ),
      if (!_tunerAgc) ...<Widget>[
        Text('Manual gain  ${_manualGainDb.toStringAsFixed(1)} dB'),
        Slider(
          value: _manualGainDb,
          min: -9.9,
          max: 49.6,
          divisions: 595,
          label: '${_manualGainDb.toStringAsFixed(1)} dB',
          onChanged: (value) {
            setState(() => _manualGainDb = value);
            if (connected) {
              _client.setGainDb(value);
            }
          },
        ),
      ],
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('RTL AGC'),
        value: _rtlAgc,
        onChanged: (value) {
          setState(() => _rtlAgc = value);
          if (connected) {
            _client.setRtlAgc(value);
          }
        },
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Bias-T'),
        subtitle: const Text('Only enable for powered antenna/LNA hardware'),
        value: _biasTee,
        onChanged: (value) {
          setState(() => _biasTee = value);
          if (connected) {
            _client.setBiasTee(value);
          }
        },
      ),
      DropdownButtonFormField<int>(
        key: ValueKey<String>('usb-direct-$_directSampling'),
        initialValue: _directSampling,
        decoration: const InputDecoration(
          labelText: 'Direct sampling',
          border: OutlineInputBorder(),
        ),
        items: const <DropdownMenuItem<int>>[
          DropdownMenuItem(value: 0, child: Text('Disabled')),
          DropdownMenuItem(value: 1, child: Text('I branch')),
          DropdownMenuItem(value: 2, child: Text('Q branch')),
        ],
        onChanged: (value) {
          if (value != null) {
            setState(() => _directSampling = value);
            if (connected) {
              _client.setDirectSampling(value);
            }
          }
        },
      ),
      const SizedBox(height: 12),
      Text('Frequency correction  $_ppm ppm'),
      Slider(
        value: _ppm.toDouble(),
        min: -100,
        max: 100,
        divisions: 200,
        label: '$_ppm ppm',
        onChanged: (value) {
          final ppm = value.round();
          setState(() => _ppm = ppm);
          if (connected) {
            _client.setPpm(ppm);
          }
        },
      ),
      const Text(
        'Android uses UsbManager permission + the official SDR++ librtlsdr system-device path. No RTL-TCP server is required.',
        style: TextStyle(
          color: Color(0xFF7F91A5),
          fontSize: 12,
          height: 1.4,
        ),
      ),
    ];
  }

  Future<void> _refreshRtlUsbDevices() async {
    if (!AndroidUsbService.supported) {
      return;
    }
    setState(() => _rtlUsbRefreshing = true);
    try {
      final devices = await AndroidUsbService.listRtlSdrDevices();
      if (!mounted) {
        return;
      }
      setState(() {
        _rtlUsbDevices = devices;
        if (devices.isEmpty) {
          _rtlUsbDeviceName = null;
        } else if (!devices.any(
          (device) => device.deviceName == _rtlUsbDeviceName,
        )) {
          _rtlUsbDeviceName = devices.first.deviceName;
        }
      });
    } catch (error) {
      if (mounted) {
        setState(() => _connectionError = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _rtlUsbRefreshing = false);
      }
    }
  }

  Future<void> _pickIqFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['wav'],
      allowMultiple: false,
    );
    final path = result?.files.single.path;
    if (path == null || path.isEmpty || !mounted) {
      return;
    }
    setState(() => _iqFilePath = path);
  }

  Future<void> _connectSelectedSource() async {
    switch (_selectedSourceKind) {
      case ReceiverSourceKind.file:
        await _connectFileSource();
        break;
      case ReceiverSourceKind.network:
        await _connectNetworkSource();
        break;
      case ReceiverSourceKind.sdrppServer:
        await _connectSdrppServerSource();
        break;
      case ReceiverSourceKind.spyServer:
        await _connectSpyServerSource();
        break;
      case ReceiverSourceKind.rtlSdrUsb:
        await _connectRtlSdrUsbSource();
        break;
      case ReceiverSourceKind.rfspace:
        await _connectRfspaceSource();
        break;
      case ReceiverSourceKind.hermes:
        await _connectHermesSource();
        break;
      case ReceiverSourceKind.spectranHttp:
        await _connectSpectranHttpSource();
        break;
      case ReceiverSourceKind.rtlTcp:
        await _connect();
        break;
      case ReceiverSourceKind.soapy:
        await _connectSoapySource();
        break;
    }
  }

  Future<void> _connectRfspaceSource() async {
    final port =
        int.tryParse(_nativeRemotePortController.text.trim()) ?? 50000;
    await _connectConfiguredNativeSource(
      () => _client.connectRfspace(
        host: _nativeRemoteHostController.text.trim(),
        port: port,
        sampleRateHz: _sampleRateHz,
        frequencyHz: _frequencyHz,
        gainDb: _nativeRemoteGainDb.clamp(-30, 0),
        mode: _mode,
        bandwidthHz: _bandwidthKhz * 1000,
      ),
    );
  }

  Future<void> _connectHermesSource() async {
    final port =
        int.tryParse(_nativeRemotePortController.text.trim()) ?? 1024;
    await _connectConfiguredNativeSource(
      () => _client.connectHermes(
        host: _nativeRemoteHostController.text.trim(),
        port: port,
        sampleRateHz: _sampleRateHz,
        frequencyHz: _frequencyHz,
        gainDb: _nativeRemoteGainDb.clamp(0, 60),
        mode: _mode,
        bandwidthHz: _bandwidthKhz * 1000,
      ),
    );
  }

  Future<void> _connectSpectranHttpSource() async {
    final port =
        int.tryParse(_nativeRemotePortController.text.trim()) ?? 54664;
    await _connectConfiguredNativeSource(
      () => _client.connectSpectranHttp(
        host: _nativeRemoteHostController.text.trim(),
        port: port,
        frequencyHz: _frequencyHz,
        mode: _mode,
        bandwidthHz: _bandwidthKhz * 1000,
      ),
    );
  }

  Future<void> _connectConfiguredNativeSource(
    Future<void> Function() connect,
  ) async {
    setState(() {
      _connectionError = '';
      _waterfall.clear();
    });

    try {
      await _audio.start();
      _audio.setVolume(_volume);
      await connect();
      _client.setSquelch(_squelchEnabled, _squelchDb);
      _client.setNoiseBlanker(
        _noiseBlankerEnabled,
        _noiseBlankerLevel,
      );
      _client.setHighPass(_highPassEnabled);
      _client.setDeemphasis(_deemphasisUs);
      _applyRadioDetailOptions();

      if (mounted) {
        setState(() {
          _sampleRateHz = _client.sampleRateHz;
          _frequencyHz = _client.frequencyHz;
          _scanFrequencyHz = _frequencyHz;
          _tab = 0;
        });
      }
    } catch (error) {
      if (mounted) {
        final message = _client.lastError.isNotEmpty
            ? _client.lastError
            : error.toString();
        setState(() => _connectionError = message);
      }
    }
  }

  Future<void> _connectRtlSdrUsbSource() async {
    if (_rtlUsbDeviceName == null) {
      await _refreshRtlUsbDevices();
      if (_rtlUsbDeviceName == null) {
        if (mounted) {
          setState(
            () => _connectionError =
                'No supported RTL-SDR USB device was found',
          );
        }
        return;
      }
    }

    setState(() {
      _connectionError = '';
      _waterfall.clear();
    });

    try {
      await _audio.start();
      _audio.setVolume(_volume);
      await _client.connectRtlSdrUsb(
        deviceName: _rtlUsbDeviceName!,
        sampleRateHz: _sampleRateHz,
        frequencyHz: _frequencyHz,
        mode: _mode,
        bandwidthHz: _bandwidthKhz * 1000,
      );

      _client.setTunerAgc(_tunerAgc);
      if (!_tunerAgc) {
        _client.setGainDb(_manualGainDb);
      }
      _client.setRtlAgc(_rtlAgc);
      _client.setBiasTee(_biasTee);
      _client.setDirectSampling(_directSampling);
      _client.setPpm(_ppm);
      _client.setOffsetTuning(_offsetTuning);
      _client.setSquelch(_squelchEnabled, _squelchDb);
      _client.setNoiseBlanker(
        _noiseBlankerEnabled,
        _noiseBlankerLevel,
      );
      _client.setHighPass(_highPassEnabled);
      _client.setDeemphasis(_deemphasisUs);
      _applyRadioDetailOptions();

      if (mounted) {
        setState(() {
          _sampleRateHz = _client.sampleRateHz;
          _frequencyHz = _client.frequencyHz;
          _scanFrequencyHz = _frequencyHz;
          _tab = 0;
        });
      }
    } catch (error) {
      if (mounted) {
        final message = _client.lastError.isNotEmpty
            ? _client.lastError
            : error.toString();
        setState(() => _connectionError = message);
      }
    }
  }

  Future<void> _connectSdrppServerSource() async {
    final port =
        int.tryParse(_sdrppServerPortController.text.trim()) ?? 50000;
    setState(() {
      _connectionError = '';
      _waterfall.clear();
    });

    try {
      await _audio.start();
      _audio.setVolume(_volume);
      await _client.connectSdrppServer(
        host: _sdrppServerHostController.text.trim(),
        port: port,
        frequencyHz: _frequencyHz,
        mode: _mode,
        bandwidthHz: _bandwidthKhz * 1000,
      );
      if (mounted) {
        setState(() {
          _sampleRateHz = _client.sampleRateHz;
          _frequencyHz = _client.frequencyHz;
          _scanFrequencyHz = _frequencyHz;
          _tab = 0;
        });
      }
      _client.setSquelch(_squelchEnabled, _squelchDb);
      _client.setNoiseBlanker(
        _noiseBlankerEnabled,
        _noiseBlankerLevel,
      );
      _client.setHighPass(_highPassEnabled);
      _client.setDeemphasis(_deemphasisUs);
      _applyRadioDetailOptions();
    } catch (error) {
      if (mounted) {
        final message = _client.lastError.isNotEmpty
            ? _client.lastError
            : error.toString();
        setState(() => _connectionError = message);
      }
    }
  }

  Future<void> _connectSpyServerSource() async {
    final port =
        int.tryParse(_spyServerPortController.text.trim()) ?? 5555;
    setState(() {
      _connectionError = '';
      _waterfall.clear();
    });

    try {
      await _audio.start();
      _audio.setVolume(_volume);
      await _client.connectSpyServer(
        host: _spyServerHostController.text.trim(),
        port: port,
        sampleRateHz: _sampleRateHz,
        frequencyHz: _frequencyHz,
        mode: _mode,
        bandwidthHz: _bandwidthKhz * 1000,
      );
      if (mounted) {
        setState(() {
          _sampleRateHz = _client.sampleRateHz;
          _frequencyHz = _client.frequencyHz;
          _scanFrequencyHz = _frequencyHz;
          _tab = 0;
        });
      }
      _client.setSquelch(_squelchEnabled, _squelchDb);
      _client.setNoiseBlanker(
        _noiseBlankerEnabled,
        _noiseBlankerLevel,
      );
      _client.setHighPass(_highPassEnabled);
      _client.setDeemphasis(_deemphasisUs);
      _applyRadioDetailOptions();
    } catch (error) {
      if (mounted) {
        final message = _client.lastError.isNotEmpty
            ? _client.lastError
            : error.toString();
        setState(() => _connectionError = message);
      }
    }
  }

  Future<void> _refreshSoapyDevices() async {
    if (_soapyRefreshing) {
      return;
    }
    setState(() => _soapyRefreshing = true);
    try {
      final devices = await _client.enumerateSoapy();
      final usbDevices = await AndroidUsbService.listSdrUsbDevices();
      if (!mounted) {
        return;
      }
      setState(() {
        _soapyDevices = devices;
        _soapyUsbDevices = usbDevices
            .where((device) => device.driver != 'rtlsdr')
            .toList(growable: false);
        if (_soapyUsbDeviceName != null &&
            !_soapyUsbDevices.any(
              (device) => device.deviceName == _soapyUsbDeviceName,
            )) {
          _soapyUsbDeviceName = null;
        }
        if (devices.isNotEmpty &&
            _soapyUsbDeviceName == null &&
            (_soapyArgsController.text.trim().isEmpty ||
                _soapyArgsController.text.trim() == 'driver=rtlsdr')) {
          _soapyArgsController.text = devices.first;
        }
      });
    } finally {
      if (mounted) {
        setState(() => _soapyRefreshing = false);
      }
    }
  }

  List<Widget> _soapySourceControls(bool connected) {
    final selectedArgs = _soapyArgsController.text.trim();
    final dropdownValue =
        _soapyDevices.contains(selectedArgs) ? selectedArgs : null;

    return <Widget>[
      if (AndroidUsbService.supported) ...<Widget>[
        DropdownButtonFormField<String>(
          initialValue: _soapyUsbDeviceName,
          decoration: const InputDecoration(
            labelText: 'Android USB SDR',
            prefixIcon: Icon(Icons.usb_rounded),
            border: OutlineInputBorder(),
          ),
          items: _soapyUsbDevices
              .map(
                (device) => DropdownMenuItem<String>(
                  value: device.deviceName,
                  child: Text(
                    device.label,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(growable: false),
          onChanged: connected
              ? null
              : (value) {
                  setState(() {
                    _soapyUsbDeviceName = value;
                    if (value != null) {
                      final device = _soapyUsbDevices.firstWhere(
                        (item) => item.deviceName == value,
                      );
                      _soapyArgsController.text =
                          'driver=${device.driver}';
                    }
                  });
                },
        ),
        const SizedBox(height: 12),
      ],
      Row(
        children: <Widget>[
          Expanded(
            child: DropdownButtonFormField<String>(
              key: ValueKey<String?>(dropdownValue),
              initialValue: dropdownValue,
              decoration: const InputDecoration(
                labelText: 'Detected SoapySDR devices',
                prefixIcon: Icon(Icons.usb_rounded),
                border: OutlineInputBorder(),
              ),
              items: _soapyDevices
                  .map(
                    (device) => DropdownMenuItem<String>(
                      value: device,
                      child: Text(
                        device,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(growable: false),
              onChanged: connected
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() {
                          _soapyArgsController.text = value;
                        });
                      }
                    },
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            onPressed: connected || _soapyRefreshing
                ? null
                : _refreshSoapyDevices,
            tooltip: 'Refresh SoapySDR devices',
            icon: _soapyRefreshing
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _soapyArgsController,
        enabled: !connected,
        decoration: const InputDecoration(
          labelText: 'Device arguments',
          hintText: 'driver=rtlsdr  /  remote=192.168.1.20:55132',
          prefixIcon: Icon(Icons.code_rounded),
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),
      Row(
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: _soapySampleRateController,
              enabled: !connected,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Sample rate (Hz)',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _soapyBandwidthController,
              enabled: !connected,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'RF bandwidth (Hz)',
                helperText: '0 = driver default',
                border: OutlineInputBorder(),
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _soapyChannelController,
        enabled: !connected,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          labelText: 'RX channel',
          prefixIcon: Icon(Icons.call_split_rounded),
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 6),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Hardware AGC'),
        subtitle: const Text(
          'Uses SoapySDR gain-mode capability when supported',
        ),
        value: _tunerAgc,
        onChanged: (value) {
          setState(() => _tunerAgc = value);
          if (connected) {
            _client.setTunerAgc(value);
          }
        },
      ),
      if (!_tunerAgc) ...<Widget>[
        Text('Gain  ${_soapyGainDb.toStringAsFixed(1)} dB'),
        Slider(
          value: _soapyGainDb,
          min: -30,
          max: 80,
          divisions: 220,
          label: '${_soapyGainDb.toStringAsFixed(1)} dB',
          onChanged: (value) {
            setState(() => _soapyGainDb = value);
            if (connected) {
              _client.setGainDb(value);
            }
          },
        ),
      ],
      const Text(
        'SoapySDR is active. RTL-SDR can be used locally; SoapyRemote can connect to any SoapySDR hardware on a server with remote=HOST:55132. Direct Android drivers for additional vendor hardware are being packaged separately.',
        style: TextStyle(
          color: Color(0xFF7F91A5),
          fontSize: 12,
          height: 1.4,
        ),
      ),
    ];
  }

  Future<void> _connectSoapySource() async {
    final args = _soapyArgsController.text.trim();
    if (args.isEmpty) {
      setState(() => _connectionError = 'Enter or select a SoapySDR device.');
      return;
    }

    final sampleRate =
        int.tryParse(_soapySampleRateController.text.trim()) ?? 2048000;
    final rfBandwidth =
        double.tryParse(_soapyBandwidthController.text.trim()) ?? 0;
    final channel =
        int.tryParse(_soapyChannelController.text.trim()) ?? 0;

    setState(() {
      _connectionError = '';
      _waterfall.clear();
    });

    try {
      await _audio.start();
      final usbName = _soapyUsbDeviceName;
      if (usbName != null) {
        final device = _soapyUsbDevices.firstWhere(
          (item) => item.deviceName == usbName,
        );
        await _client.connectSoapyUsb(
          deviceName: usbName,
          driver: device.driver,
          sampleRateHz: sampleRate,
          frequencyHz: _frequencyHz,
          rfBandwidthHz: rfBandwidth,
          gainDb: _soapyGainDb,
          agc: _tunerAgc,
          channel: channel,
          mode: _mode,
          bandwidthHz: _bandwidthKhz * 1000,
        );
      } else {
        await _client.connectSoapy(
          deviceArgs: args,
          sampleRateHz: sampleRate,
          frequencyHz: _frequencyHz,
          rfBandwidthHz: rfBandwidth,
          gainDb: _soapyGainDb,
          agc: _tunerAgc,
          channel: channel,
          mode: _mode,
          bandwidthHz: _bandwidthKhz * 1000,
        );
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _sampleRateHz = _client.sampleRateHz;
        _frequencyHz = _client.frequencyHz;
      });
    } catch (error) {
      if (mounted) {
        setState(() => _connectionError = error.toString());
      }
    }
  }

  Future<void> _connectNetworkSource() async {
    final port =
        int.tryParse(_networkPortController.text.trim()) ?? 1234;
    setState(() {
      _connectionError = '';
      _waterfall.clear();
    });

    try {
      await _audio.start();
      _audio.setVolume(_volume);
      await _client.connectNetwork(
        host: _networkHostController.text.trim(),
        port: port,
        sampleRateHz: _sampleRateHz,
        protocol: _networkProtocol,
        sampleType: _networkSampleType,
        centerFrequencyHz: _frequencyHz,
        mode: _mode,
        bandwidthHz: _bandwidthKhz * 1000,
      );
      _client.setSquelch(_squelchEnabled, _squelchDb);
      _client.setNoiseBlanker(
        _noiseBlankerEnabled,
        _noiseBlankerLevel,
      );
      _client.setHighPass(_highPassEnabled);
      _client.setDeemphasis(_deemphasisUs);
      _applyRadioDetailOptions();
      if (mounted) {
        setState(() => _tab = 0);
      }
    } catch (error) {
      if (mounted) {
        final message = _client.lastError.isNotEmpty
            ? _client.lastError
            : error.toString();
        setState(() => _connectionError = message);
      }
    }
  }

  Future<void> _connectFileSource() async {
    if (_iqFilePath.isEmpty) {
      await _pickIqFile();
      if (_iqFilePath.isEmpty) {
        return;
      }
    }

    setState(() {
      _connectionError = '';
      _waterfall.clear();
    });

    try {
      await _audio.start();
      _audio.setVolume(_volume);
      await _client.openFile(
        path: _iqFilePath,
        float32Mode: _iqFileFloat32,
        centerFrequencyHz: 0,
        mode: _mode,
        bandwidthHz: _bandwidthKhz * 1000,
      );
      if (mounted) {
        setState(() {
          _sampleRateHz = _client.sampleRateHz;
          _frequencyHz = _client.frequencyHz;
          _scanFrequencyHz = _frequencyHz;
          _tab = 0;
        });
      }
      _client.setSquelch(_squelchEnabled, _squelchDb);
      _client.setNoiseBlanker(
        _noiseBlankerEnabled,
        _noiseBlankerLevel,
      );
      _client.setHighPass(_highPassEnabled);
      _client.setDeemphasis(_deemphasisUs);
      _applyRadioDetailOptions();
    } catch (error) {
      if (mounted) {
        final message = _client.lastError.isNotEmpty
            ? _client.lastError
            : error.toString();
        setState(() => _connectionError = message);
      }
    }
  }

  Widget _settingsPage() {
    final connected = _connectionState == RtlTcpConnectionState.connected;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        children: <Widget>[
          _appHeader('Settings'),
          const SizedBox(height: 18),
          Expanded(
            child: ListView(
              children: <Widget>[
                _sourceSettingsCard(connected),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        const Text(
                          'Radio DSP',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Official SDR++ post-processing chain',
                          style: TextStyle(color: Color(0xFF7F91A5)),
                        ),
                        const SizedBox(height: 10),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Noise blanker'),
                          subtitle: Text(
                            'Impulse suppression · level ${_noiseBlankerLevel.toStringAsFixed(1)}',
                          ),
                          value: _noiseBlankerEnabled,
                          onChanged: (value) {
                            setState(() => _noiseBlankerEnabled = value);
                            _client.setNoiseBlanker(
                              value,
                              _noiseBlankerLevel,
                            );
                          },
                        ),
                        Slider(
                          value: _noiseBlankerLevel,
                          min: 1,
                          max: 10,
                          divisions: 90,
                          label: _noiseBlankerLevel.toStringAsFixed(1),
                          onChanged: _noiseBlankerEnabled
                              ? (value) {
                                  setState(
                                    () => _noiseBlankerLevel = value,
                                  );
                                  _client.setNoiseBlanker(
                                    true,
                                    value,
                                  );
                                }
                              : null,
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('High-pass filter'),
                          subtitle: const Text(
                            '300 Hz speech high-pass filter',
                          ),
                          value: _highPassEnabled,
                          onChanged: (value) {
                            setState(() => _highPassEnabled = value);
                            _client.setHighPass(value);
                          },
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<int>(
                          initialValue: _deemphasisUs,
                          decoration: const InputDecoration(
                            labelText: 'De-emphasis',
                            prefixIcon: Icon(Icons.multiline_chart_rounded),
                            border: OutlineInputBorder(),
                          ),
                          items: const <DropdownMenuItem<int>>[
                            DropdownMenuItem(
                              value: 0,
                              child: Text('None'),
                            ),
                            DropdownMenuItem(
                              value: 22,
                              child: Text('22 µs'),
                            ),
                            DropdownMenuItem(
                              value: 50,
                              child: Text('50 µs'),
                            ),
                            DropdownMenuItem(
                              value: 75,
                              child: Text('75 µs'),
                            ),
                          ],
                          onChanged: (value) {
                            if (value == null) {
                              return;
                            }
                            setState(() => _deemphasisUs = value);
                            _client.setDeemphasis(value);
                          },
                        ),
                        const SizedBox(height: 12),
                        ..._radioDetailControls(),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.extension_rounded),
                    title: const Text('Sources & modules'),
                    subtitle: const Text(
                      'Complete upstream SDR++ source/decoder/plugin mapping',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: _showModuleCatalog,
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.memory_rounded),
                    title: const Text('DSP backend'),
                    subtitle: Text(
                      _dspBackend == 'Dart fallback DSP'
                          ? 'Fallback active. Official native SDR++ DSP library was not loaded.'
                          : '$_dspBackend\nOfficial SDR++ C++ demodulator/resampler path is active.',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _radioDetailControls() {
    final widgets = <Widget>[];

    if (_mode == 'NFM' || _mode == 'WFM') {
      widgets.addAll(<Widget>[
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('IF Noise Reduction'),
          subtitle: const Text('Official SDR++ FM IF spectral noise reducer'),
          value: _fmIfNrEnabled,
          onChanged: (value) {
            setState(() => _fmIfNrEnabled = value);
            _client.setFmIfNr(value, _fmIfNrPreset);
          },
        ),
        const SizedBox(height: 6),
        if (_mode == 'WFM')
          const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.auto_fix_high_rounded),
            title: Text('IFNR preset'),
            subtitle: Text('Broadcast · 32 bins (SDR++ default)'),
          )
        else
          DropdownButtonFormField<int>(
            key: ValueKey<int>(_fmIfNrPreset),
            initialValue: _fmIfNrPreset,
            decoration: const InputDecoration(
              labelText: 'IFNR preset',
              prefixIcon: Icon(Icons.auto_fix_high_rounded),
              border: OutlineInputBorder(),
            ),
            items: const <DropdownMenuItem<int>>[
              DropdownMenuItem(value: 0, child: Text('NOAA APT · 9 bins')),
              DropdownMenuItem(value: 1, child: Text('Voice · 15 bins')),
              DropdownMenuItem(value: 2, child: Text('Narrow Band · 31 bins')),
            ],
            onChanged: _fmIfNrEnabled
                ? (value) {
                    if (value == null) {
                      return;
                    }
                    setState(() => _fmIfNrPreset = value);
                    _client.setFmIfNr(true, value);
                  }
                : null,
          ),
        const SizedBox(height: 12),
      ]);
    }

    if (_mode == 'NFM') {
      widgets.addAll(<Widget>[
        DropdownButtonFormField<int>(
          key: ValueKey<String>('ctcss-$_ctcssMode'),
          initialValue: _ctcssMode,
          decoration: const InputDecoration(
            labelText: 'CTCSS',
            prefixIcon: Icon(Icons.graphic_eq_rounded),
            border: OutlineInputBorder(),
          ),
          items: const <DropdownMenuItem<int>>[
            DropdownMenuItem(value: 0, child: Text('Off')),
            DropdownMenuItem(value: 1, child: Text('Decode only')),
            DropdownMenuItem(value: 2, child: Text('Mute / tone squelch')),
          ],
          onChanged: (value) {
            if (value == null) {
              return;
            }
            setState(() {
              _ctcssMode = value;
              if (value == 0) {
                _detectedCtcssHz = 0;
              }
              else {
                _squelchEnabled = false;
              }
            });
            if (value != 0) {
              _client.setSquelch(false, _squelchDb);
            }
            _client.setCtcss(value, _ctcssToneIndex);
          },
        ),
        if (_ctcssMode == 2) ...<Widget>[
          const SizedBox(height: 10),
          DropdownButtonFormField<int>(
            key: ValueKey<String>('tone-$_ctcssToneIndex'),
            initialValue: _ctcssToneIndex,
            decoration: const InputDecoration(
              labelText: 'Required CTCSS tone',
              border: OutlineInputBorder(),
            ),
            items: <DropdownMenuItem<int>>[
              const DropdownMenuItem(value: -2, child: Text('Any valid tone')),
              for (var i = 0; i < _ctcssTones.length; i++)
                DropdownMenuItem(
                  value: i,
                  child: Text('${_ctcssTones[i].toStringAsFixed(1)} Hz'),
                ),
            ],
            onChanged: (value) {
              if (value == null) {
                return;
              }
              setState(() => _ctcssToneIndex = value);
              _client.setCtcss(_ctcssMode, value);
            },
          ),
        ],
        const SizedBox(height: 8),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            _detectedCtcssHz > 0
                ? Icons.radio_button_checked_rounded
                : Icons.radio_button_unchecked_rounded,
          ),
          title: const Text('Detected CTCSS'),
          subtitle: Text(
            _detectedCtcssHz > 0
                ? '${_detectedCtcssHz.toStringAsFixed(1)} Hz'
                : 'No valid tone',
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('NFM low-pass'),
          subtitle: const Text('Official FM discriminator low-pass'),
          value: _nfmLowPass,
          onChanged: (value) {
            setState(() => _nfmLowPass = value);
            _client.setNfmOptions(value);
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Voice clean filter'),
          subtitle: const Text(
            '300 Hz high-pass + 3.2 kHz voice low-pass for handheld-style audio',
          ),
          value: _nfmVoiceFilter,
          onChanged: (value) {
            setState(() {
              _nfmVoiceFilter = value;
              if (value) {
                _highPassEnabled = true;
              }
            });
            _client.setNfmVoiceFilter(value);
            if (value) {
              _client.setHighPass(true);
            }
          },
        ),
      ]);
    }

    if (_mode == 'WFM') {
      widgets.addAll(<Widget>[
        const SizedBox(height: 6),
        const Text(
          'FM quality',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const <ButtonSegment<String>>[
            ButtonSegment<String>(
              value: 'Clean',
              label: Text('Clean'),
              icon: Icon(Icons.cleaning_services_rounded),
            ),
            ButtonSegment<String>(
              value: 'Weak',
              label: Text('Weak'),
              icon: Icon(Icons.signal_cellular_alt_1_bar_rounded),
            ),
            ButtonSegment<String>(
              value: 'Stereo',
              label: Text('Stereo'),
              icon: Icon(Icons.surround_sound_rounded),
            ),
            ButtonSegment<String>(
              value: 'HiFi',
              label: Text('Hi-Fi'),
              icon: Icon(Icons.graphic_eq_rounded),
            ),
          ],
          selected: <String>{_fmProfile},
          onSelectionChanged: (selection) {
            if (selection.isEmpty) {
              return;
            }
            _applyFmProfile(selection.first);
          },
        ),
        const SizedBox(height: 6),
        Text(
          _fmProfile == 'Clean'
              ? 'Low-noise default: mono + 15 kHz audio low-pass, IF noise reduction off.'
              : _fmProfile == 'Weak'
                  ? 'Weak-signal mode: mono + Broadcast IF noise reduction.'
                  : _fmProfile == 'Stereo'
                      ? 'Stereo + 15 kHz low-pass, IF noise reduction off.'
                      : 'Stereo with minimum processing for strong, clean stations.',
          style: const TextStyle(
            color: Color(0xFF7F91A5),
            fontSize: 12,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Stereo'),
          subtitle: const Text('19 kHz pilot stereo decoder'),
          value: _wfmStereo,
          onChanged: (value) {
            setState(() => _wfmStereo = value);
            _client.setWfmOptions(
              _wfmStereo,
              _wfmLowPass,
              _wfmRdsEnabled,
            );
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('WFM low-pass'),
          value: _wfmLowPass,
          onChanged: (value) {
            setState(() => _wfmLowPass = value);
            _client.setWfmOptions(
              _wfmStereo,
              _wfmLowPass,
              _wfmRdsEnabled,
            );
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Decode RDS'),
          subtitle: const Text('57 kHz RDS Program Service / RadioText'),
          value: _wfmRdsEnabled,
          onChanged: (value) {
            setState(() {
              _wfmRdsEnabled = value;
              if (!value) {
                _rdsProgramService = '';
                _rdsRadioText = '';
              }
            });
            _client.setWfmOptions(
              _wfmStereo,
              _wfmLowPass,
              _wfmRdsEnabled,
            );
          },
        ),
      ]);
    }

    if (_mode == 'AM') {
      widgets.addAll(<Widget>[
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Carrier AGC'),
          subtitle: const Text('Use carrier rather than audio AGC'),
          value: _amCarrierAgc,
          onChanged: (value) {
            setState(() => _amCarrierAgc = value);
            _client.setAmAgc(
              value,
              _amAgcAttackMs,
              _amAgcDecayMs,
            );
          },
        ),
        Text('AGC attack · ${_amAgcAttackMs.toStringAsFixed(0)} ms'),
        Slider(
          value: _amAgcAttackMs,
          min: 1,
          max: 200,
          divisions: 199,
          onChanged: (value) {
            setState(() => _amAgcAttackMs = value);
            _client.setAmAgc(
              _amCarrierAgc,
              value,
              _amAgcDecayMs,
            );
          },
        ),
        Text('AGC decay · ${_amAgcDecayMs.toStringAsFixed(0)} ms'),
        Slider(
          value: _amAgcDecayMs,
          min: 1,
          max: 20,
          divisions: 19,
          onChanged: (value) {
            setState(() => _amAgcDecayMs = value);
            _client.setAmAgc(
              _amCarrierAgc,
              _amAgcAttackMs,
              value,
            );
          },
        ),
      ]);
    }

    if (_mode == 'USB' || _mode == 'LSB' || _mode == 'DSB') {
      widgets.addAll(<Widget>[
        Text('SSB AGC attack · ${_ssbAgcAttackMs.toStringAsFixed(0)} ms'),
        Slider(
          value: _ssbAgcAttackMs,
          min: 1,
          max: 200,
          divisions: 199,
          onChanged: (value) {
            setState(() => _ssbAgcAttackMs = value);
            _client.setSsbAgc(value, _ssbAgcDecayMs);
          },
        ),
        Text('SSB AGC decay · ${_ssbAgcDecayMs.toStringAsFixed(0)} ms'),
        Slider(
          value: _ssbAgcDecayMs,
          min: 1,
          max: 20,
          divisions: 19,
          onChanged: (value) {
            setState(() => _ssbAgcDecayMs = value);
            _client.setSsbAgc(_ssbAgcAttackMs, value);
          },
        ),
      ]);
    }

    if (_mode == 'CW') {
      widgets.addAll(<Widget>[
        Text('CW tone · $_cwToneHz Hz'),
        Slider(
          value: _cwToneHz.toDouble(),
          min: 250,
          max: 1250,
          divisions: 100,
          onChanged: (value) {
            final tone = value.round();
            setState(() => _cwToneHz = tone);
            _client.setCwOptions(
              tone,
              _cwAgcAttackMs,
              _cwAgcDecayMs,
            );
          },
        ),
        Text('CW AGC attack · ${_cwAgcAttackMs.toStringAsFixed(0)} ms'),
        Slider(
          value: _cwAgcAttackMs,
          min: 1,
          max: 200,
          divisions: 199,
          onChanged: (value) {
            setState(() => _cwAgcAttackMs = value);
            _client.setCwOptions(
              _cwToneHz,
              value,
              _cwAgcDecayMs,
            );
          },
        ),
        Text('CW AGC decay · ${_cwAgcDecayMs.toStringAsFixed(0)} ms'),
        Slider(
          value: _cwAgcDecayMs,
          min: 1,
          max: 20,
          divisions: 19,
          onChanged: (value) {
            setState(() => _cwAgcDecayMs = value);
            _client.setCwOptions(
              _cwToneHz,
              _cwAgcAttackMs,
              value,
            );
          },
        ),
      ]);
    }

    return widgets;
  }

  Future<void> _showModuleCatalog() async {
    var selectedKind = SdrModuleKind.source;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          final modules = SdrModuleCatalog.ofKind(selectedKind);
          String kindLabel(SdrModuleKind kind) => switch (kind) {
                SdrModuleKind.source => 'Sources',
                SdrModuleKind.decoder => 'Decoders',
                SdrModuleKind.utility => 'Utilities',
                SdrModuleKind.sink => 'Sinks',
              };
          String supportLabel(SdrModuleSupport support) => switch (support) {
                SdrModuleSupport.active => 'Active',
                SdrModuleSupport.mapped => 'Mapped',
                SdrModuleSupport.nativeSdk => 'Native SDK',
              };

          return SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.82,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Column(
                  children: <Widget>[
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'SDR++ Sources & Modules',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(height: 5),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Every upstream source, decoder, utility and sink is mapped here. Active means the Flutter/Native adapter is already wired; Native SDK entries require the vendor backend to be packaged for the platform.',
                        style: TextStyle(
                          color: Color(0xFF8193A7),
                          height: 1.4,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: <Widget>[
                          for (final kind in SdrModuleKind.values)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                selected: selectedKind == kind,
                                label: Text(kindLabel(kind)),
                                onSelected: (_) => setSheetState(
                                  () => selectedKind = kind,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: ListView.separated(
                        itemCount: modules.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final module = modules[index];
                          return Card(
                            child: ListTile(
                              leading: Icon(
                                module.support == SdrModuleSupport.active
                                    ? Icons.check_circle_rounded
                                    : module.support ==
                                            SdrModuleSupport.nativeSdk
                                        ? Icons.memory_rounded
                                        : Icons.route_rounded,
                              ),
                              title: Text(module.name),
                              subtitle: Text(
                                '${module.description}\n${module.upstreamPath}',
                              ),
                              isThreeLine: true,
                              trailing: Text(
                                supportLabel(module.support),
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: module.support ==
                                          SdrModuleSupport.active
                                      ? const Color(0xFF67E8F9)
                                      : const Color(0xFF8C9EB2),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _showBandwidthSheet() async {
    final options = switch (_mode) {
      'CW' => <double>[0.05, 0.1, 0.2, 0.3, 0.5],
      'USB' || 'LSB' => <double>[0.5, 1.0, 1.8, 2.4, 2.8, 3.0, 4.0, 6.0, 8.0, 12.0],
      'DSB' => <double>[1.0, 2.4, 4.6, 6.0, 8.0, 10.0, 12.0],
      'AM' => <double>[1.0, 2.4, 5.0, 6.0, 8.0, 10.0, 12.5, 15.0],
      'NFM' => <double>[1.0, 2.5, 5.0, 6.25, 8.33, 10.0, 12.5, 15.0, 20.0, 25.0, 50.0],
      'WFM' => <double>[50.0, 100.0, 150.0, 180.0, 200.0, 250.0],
      'RAW' => <double>[48.0],
      _ => <double>[10.0],
    };
    final value = await showModalBottomSheet<double>(
      context: context,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final bw in options)
              ChoiceChip(
                selected: (_bandwidthKhz - bw).abs() < 0.01,
                label: Text(bw >= 100 ? '${bw.toInt()} kHz' : '$bw kHz'),
                onSelected: (_) => Navigator.of(context).pop(bw),
              ),
          ],
        ),
      ),
    );
    if (value != null) {
      setState(() => _bandwidthKhz = value);
      _client.setBandwidth(value * 1000);
    }
  }

  Future<void> _showSquelchSheet() async {
    var enabled = _squelchEnabled;
    var threshold = _squelchDb;
    final result = await showModalBottomSheet<(bool, double)>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Squelch'),
                subtitle: const Text('Mute audio below the RF threshold'),
                value: enabled,
                onChanged: (value) => setSheetState(() => enabled = value),
              ),
              Text('Threshold  ${threshold.toStringAsFixed(0)} dBFS'),
              Slider(
                value: threshold,
                min: -100,
                max: -20,
                divisions: 80,
                label: '${threshold.toStringAsFixed(0)} dBFS',
                onChanged: enabled
                    ? (value) => setSheetState(() => threshold = value)
                    : null,
              ),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop((enabled, threshold)),
                  child: const Text('Apply'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (result != null) {
      setState(() {
        _squelchEnabled = result.$1;
        _squelchDb = result.$2;
        if (_squelchEnabled) {
          _ctcssMode = 0;
          _detectedCtcssHz = 0;
        }
      });
      _client.setSquelch(_squelchEnabled, _squelchDb);
      if (_squelchEnabled) {
        _client.setCtcss(0, _ctcssToneIndex);
      }
    }
  }

  Future<void> _showGainSheet() async {
    var auto = _tunerAgc;
    var gain = _manualGainDb;
    final result = await showModalBottomSheet<(bool, double)>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Automatic tuner gain'),
                value: auto,
                onChanged: (value) => setSheetState(() => auto = value),
              ),
              Text('Manual gain  ${gain.toStringAsFixed(1)} dB'),
              Slider(
                value: gain,
                min: -9.9,
                max: 19.7,
                divisions: 296,
                label: '${gain.toStringAsFixed(1)} dB',
                onChanged: auto
                    ? null
                    : (value) => setSheetState(() => gain = value),
              ),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop((auto, gain)),
                  child: const Text('Apply'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (result != null) {
      setState(() {
        _tunerAgc = result.$1;
        _manualGainDb = result.$2;
      });
      _client.setTunerAgc(_tunerAgc);
      if (!_tunerAgc) {
        _client.setGainDb(_manualGainDb);
      }
    }
  }

  Future<void> _showVolumeSheet() async {
    var volume = _volume;
    final result = await showModalBottomSheet<double>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text('Volume  ${(volume * 100).round()}%'),
              Slider(
                value: volume,
                onChanged: (value) {
                  setSheetState(() => volume = value);
                  _audio.setVolume(value);
                },
              ),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(volume),
                  child: const Text('Done'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (result != null) {
      setState(() => _volume = result);
      _audio.setVolume(result);
    }
  }

  void _applyFmProfile(String profile) {
    setState(() {
      _fmProfile = profile;
      _bandwidthKhz = 150;
      _wfmLowPass = true;
      _deemphasisUs = 50;
      _highPassEnabled = false;
      _noiseBlankerEnabled = false;

      switch (profile) {
        case 'Clean':
          _wfmStereo = false;
          _fmIfNrEnabled = false;
          _fmIfNrPreset = 3;
          break;
        case 'Weak':
          _wfmStereo = false;
          _fmIfNrEnabled = true;
          _fmIfNrPreset = 3;
          break;
        case 'Stereo':
          _wfmStereo = true;
          _fmIfNrEnabled = false;
          _fmIfNrPreset = 3;
          break;
        case 'HiFi':
          _wfmStereo = true;
          _fmIfNrEnabled = false;
          _fmIfNrPreset = 3;
          _wfmLowPass = false;
          break;
      }
    });

    _client.setBandwidth(150000);
    _client.setDeemphasis(50);
    _client.setHighPass(false);
    _client.setNoiseBlanker(false, _noiseBlankerLevel);
    _client.setFmIfNr(_fmIfNrEnabled, _fmIfNrPreset);
    _client.setWfmOptions(
      _wfmStereo,
      _wfmLowPass,
      _wfmRdsEnabled,
    );
  }

  void _applyRadioDetailOptions() {
    _client.setCtcss(_ctcssMode, _ctcssToneIndex);
    _client.setFmIfNr(_fmIfNrEnabled, _fmIfNrPreset);
    _client.setAmAgc(
      _amCarrierAgc,
      _amAgcAttackMs,
      _amAgcDecayMs,
    );
    _client.setSsbAgc(
      _ssbAgcAttackMs,
      _ssbAgcDecayMs,
    );
    _client.setCwOptions(
      _cwToneHz,
      _cwAgcAttackMs,
      _cwAgcDecayMs,
    );
    _client.setNfmOptions(_nfmLowPass);
    _client.setNfmVoiceFilter(_nfmVoiceFilter);
    _client.setWfmOptions(
      _wfmStereo,
      _wfmLowPass,
      _wfmRdsEnabled,
    );
  }

  Future<void> _connect() async {
    final port = int.tryParse(_portController.text.trim()) ?? 1234;
    setState(() {
      _connectionError = '';
      _waterfall.clear();
    });

    try {
      await _audio.start();
      _audio.setVolume(_volume);
      await _client.connect(
        host: _hostController.text.trim(),
        port: port,
        sampleRateHz: _sampleRateHz,
        frequencyHz: _frequencyHz,
        mode: _mode,
        bandwidthHz: _bandwidthKhz * 1000,
      );
      _client.setTunerAgc(_tunerAgc);
      if (!_tunerAgc) {
        _client.setGainDb(_manualGainDb);
      }
      _client.setRtlAgc(_rtlAgc);
      _client.setBiasTee(_biasTee);
      _client.setOffsetTuning(_offsetTuning);
      _client.setDirectSampling(_directSampling);
      _client.setPpm(_ppm);
      _client.setSquelch(_squelchEnabled, _squelchDb);
      _client.setNoiseBlanker(
        _noiseBlankerEnabled,
        _noiseBlankerLevel,
      );
      _client.setHighPass(_highPassEnabled);
      _client.setDeemphasis(_deemphasisUs);
      _applyRadioDetailOptions();
      if (mounted) {
        setState(() => _tab = 0);
      }
    } catch (error) {
      if (mounted) {
        final message = _client.lastError.isNotEmpty
            ? _client.lastError
            : error.toString();
        setState(() => _connectionError = message);
      }
    }
  }

  Future<void> _disconnect() async {
    _stopScanner();
    await _client.disconnect();
    await _audio.stopStream();
  }

  void _tuneFrequency(
    int frequencyHz, {
    bool recoverAudio = true,
  }) {
    final clamped =
        frequencyHz.clamp(100000, 6000000000).toInt();
    setState(() {
      _frequencyHz = clamped;
      _scanFrequencyHz = clamped;
      _rdsProgramService = '';
      _rdsRadioText = '';
    });
    _client.setFrequency(clamped);

    if (recoverAudio) {
      _scheduleAudioRecovery();
    }
  }

  void _scheduleAudioRecovery() {
    _retuneAudioTimer?.cancel();
    if (_connectionState != RtlTcpConnectionState.connected) {
      return;
    }

    _retuneAudioTimer = Timer(const Duration(milliseconds: 180), () async {
      if (!mounted ||
          _connectionState != RtlTcpConnectionState.connected) {
        return;
      }

      // Recreate the streaming voice after the tuner/DSP chain has settled.
      // This clears a SoLoud underrun or stale PCM queue after fast VFO moves.
      await _audio.start();
      _audio.setVolume(_volume);
    });
  }

  void _handleSpectrumTap(double x, double width) {
    if (width <= 1) {
      return;
    }

    final normalized = (x / width).clamp(0.0, 1.0);
    final offsetHz =
        ((normalized - 0.5) * _sampleRateHz).round();
    final target = _frequencyHz + offsetHz;
    final snapped =
        (target / _tuningStepHz).round() * _tuningStepHz;
    _tuneFrequency(snapped);
  }

  void _handleSpectrumDrag(double deltaPx) {
    _dragAccumulatorPx += deltaPx;
    const pixelsPerStep = 7.0;
    final wholeSteps = (_dragAccumulatorPx / pixelsPerStep).truncate();
    if (wholeSteps == 0) {
      return;
    }
    _dragAccumulatorPx -= wholeSteps * pixelsPerStep;
    // Dragging the spectrum to the right moves the RF view down in frequency.
    _tuneFrequency(_frequencyHz - wholeSteps * _tuningStepHz);
  }

  String _formatStep(int hz) {
    if (hz >= 1000000) {
      return '${hz / 1000000} MHz';
    }
    if (hz >= 1000) {
      final khz = hz / 1000;
      return khz == khz.roundToDouble()
          ? '${khz.toInt()} kHz'
          : '${khz.toStringAsFixed(2)} kHz';
    }
    return '$hz Hz';
  }

  String _presetNameFor(int frequencyHz) {
    for (final preset in _presets) {
      if ((preset.frequencyHz - frequencyHz).abs() <= 1000) {
        return preset.name;
      }
    }
    return '';
  }

  void _applyPreset(_Preset preset) {
    setState(() {
      _mode = preset.mode;
      _bandwidthKhz = preset.bandwidthHz / 1000;

      if (preset.mode == 'NFM') {
        _fmIfNrEnabled = true;
        _fmIfNrPreset = 1;
        _highPassEnabled = true;
        _nfmLowPass = true;
        _nfmVoiceFilter = true;
        _noiseBlankerEnabled = false;
      }
      else if (preset.mode == 'WFM') {
        // Public FM presets are music-first: stereo + the official 15 kHz
        // BroadcastFM low-pass + 50 us de-emphasis. "Weak" switches to
        // mono + broadcast IFNR when reception is marginal.
        _fmProfile = 'Stereo';
        _fmIfNrEnabled = false;
        _fmIfNrPreset = 3;
        _wfmStereo = true;
        _wfmLowPass = true;
        _deemphasisUs = 50;
        _highPassEnabled = false;
        _noiseBlankerEnabled = false;
      }
    });
    _client.setMode(_mode);
    _client.setBandwidth(preset.bandwidthHz);
    _client.setDeemphasis(_deemphasisUs);
    _client.setHighPass(_highPassEnabled);
    _client.setNoiseBlanker(
      _noiseBlankerEnabled,
      _noiseBlankerLevel,
    );
    _applyRadioDetailOptions();
    _tuneFrequency(preset.frequencyHz);
  }

  Future<void> _showFrequencyPad() async {
    var unit = 'MHz';
    var text = (_frequencyHz / 1000000).toStringAsFixed(6);

    final result = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: const Color(0xFF0E151E),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            void changeUnit(String nextUnit) {
              setSheetState(() {
                unit = nextUnit;
                text = switch (unit) {
                  'Hz' => _frequencyHz.toString(),
                  'kHz' => (_frequencyHz / 1000).toStringAsFixed(3),
                  _ => (_frequencyHz / 1000000).toStringAsFixed(6),
                };
              });
            }

            void press(String value) {
              setSheetState(() {
                if (value == 'back') {
                  if (text.isNotEmpty) {
                    text = text.substring(0, text.length - 1);
                  }
                  return;
                }
                if (value == '.' && text.contains('.')) {
                  return;
                }
                if (text.length < 14) {
                  text += value;
                }
              });
            }

            int? parseHz() {
              final value = double.tryParse(text);
              if (value == null || value <= 0) {
                return null;
              }
              return switch (unit) {
                'Hz' => value.round(),
                'kHz' => (value * 1000).round(),
                _ => (value * 1000000).round(),
              };
            }

            return Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                4,
                20,
                20 + MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Text(
                    'Tune frequency',
                    style: TextStyle(color: Color(0xFF8193A8)),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '$text $unit',
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<String>(
                    segments: const <ButtonSegment<String>>[
                      ButtonSegment(value: 'Hz', label: Text('Hz')),
                      ButtonSegment(value: 'kHz', label: Text('kHz')),
                      ButtonSegment(value: 'MHz', label: Text('MHz')),
                    ],
                    selected: <String>{unit},
                    onSelectionChanged: (value) => changeUnit(value.first),
                  ),
                  const SizedBox(height: 12),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: <Widget>[
                        for (final step in _tuningSteps)
                          Padding(
                            padding: const EdgeInsets.only(right: 7),
                            child: ChoiceChip(
                              selected: _tuningStepHz == step,
                              label: Text(_formatStep(step)),
                              onSelected: (_) {
                                setState(() => _tuningStepHz = step);
                                setSheetState(() {});
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  GridView.count(
                    crossAxisCount: 3,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    childAspectRatio: 2.2,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    children: <Widget>[
                      for (final key in const <String>[
                        '1', '2', '3', '4', '5', '6',
                        '7', '8', '9', '.', '0', 'back',
                      ])
                        FilledButton.tonal(
                          onPressed: () => press(key),
                          child: key == 'back'
                              ? const Icon(Icons.backspace_outlined)
                              : Text(key, style: const TextStyle(fontSize: 20)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () {
                            final hz = parseHz();
                            if (hz != null) {
                              setSheetState(() {
                                final next = hz - _tuningStepHz;
                                text = switch (unit) {
                                  'Hz' => next.toString(),
                                  'kHz' => (next / 1000).toStringAsFixed(3),
                                  _ => (next / 1000000).toStringAsFixed(6),
                                };
                              });
                            }
                          },
                          child: Text('- ${_formatStep(_tuningStepHz)}'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () {
                            final hz = parseHz();
                            if (hz != null) {
                              setSheetState(() {
                                final next = hz + _tuningStepHz;
                                text = switch (unit) {
                                  'Hz' => next.toString(),
                                  'kHz' => (next / 1000).toStringAsFixed(3),
                                  _ => (next / 1000000).toStringAsFixed(6),
                                };
                              });
                            }
                          },
                          child: Text('+ ${_formatStep(_tuningStepHz)}'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(parseHz()),
                      child: const Text('Tune'),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    if (result != null && result > 0) {
      _tuneFrequency(result);
    }
  }

  void _toggleScanner() {
    if (_scanning) {
      _stopScanner();
      return;
    }
    if (_connectionState != RtlTcpConnectionState.connected) {
      setState(() => _tab = 4);
      return;
    }

    setState(() {
      _scanHits.clear();
      _scanning = true;
      _scanFrequencyHz = 118000000;
      _mode = 'AM';
      _bandwidthKhz = 10;
    });
    _client.setMode('AM');
    _client.setBandwidth(10000);
    _tuneFrequency(_scanFrequencyHz);

    _scannerTimer = Timer.periodic(const Duration(milliseconds: 650), (_) {
      if (!mounted) {
        return;
      }

      final activity = _currentPeakAboveNoise();
      if (activity >= 13 && !_scanHits.contains(_scanFrequencyHz)) {
        setState(() {
          _scanHits.insert(0, _scanFrequencyHz);
          if (_scanHits.length > 40) {
            _scanHits.removeLast();
          }
        });
      }

      var next = _scanFrequencyHz + 25000;
      if (next > 137000000) {
        next = 118000000;
      }
      _scanFrequencyHz = next;
      _tuneFrequency(next, recoverAudio: false);
    });
  }

  void _stopScanner() {
    _scannerTimer?.cancel();
    _scannerTimer = null;
    if (mounted) {
      setState(() => _scanning = false);
    } else {
      _scanning = false;
    }
  }

  double _currentPeakAboveNoise() {
    if (_spectrum.isEmpty) {
      return 0;
    }
    final sorted = _spectrum.toList()..sort();
    final noise = sorted[sorted.length ~/ 2];
    final peak = sorted.last;
    return math.max(0.0, peak - noise).toDouble();
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _BrandMarkPainter(),
    );
  }
}

class _BrandMarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final radius = Radius.circular(size.width * 0.28);

    final background = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[
          Color(0xFF0B1724),
          Color(0xFF0A1020),
        ],
      ).createShader(rect);
    canvas.drawRRect(RRect.fromRectAndRadius(rect, radius), background);

    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.055
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[
          Color(0xFF24D6FF),
          Color(0xFF8B5CF6),
          Color(0xFFC56BFF),
        ],
      ).createShader(rect);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        rect.deflate(size.width * 0.04),
        Radius.circular(size.width * 0.25),
      ),
      border,
    );

    const heights = <double>[0.32, 0.52, 0.72, 1.0, 0.8, 0.58, 0.36];
    final barWidth = size.width * 0.065;
    final gap = size.width * 0.055;
    final total = heights.length * barWidth + (heights.length - 1) * gap;
    var x = (size.width - total) / 2;

    for (var i = 0; i < heights.length; i++) {
      final h = size.height * 0.54 * heights[i];
      final t = i / (heights.length - 1);
      final color = Color.lerp(
        const Color(0xFF27D7FF),
        const Color(0xFFB05CFF),
        t,
      )!;
      final bar = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(x + barWidth / 2, size.height / 2),
          width: barWidth,
          height: h,
        ),
        Radius.circular(barWidth / 2),
      );
      canvas.drawRRect(bar, Paint()..color = color);
      x += barWidth + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _BrandMarkPainter oldDelegate) => false;
}

class _Preset {
  const _Preset(
    this.name,
    this.frequencyHz,
    this.mode,
    this.bandwidthHz,
    this.category,
  );

  final String name;
  final int frequencyHz;
  final String mode;
  final double bandwidthHz;
  final String category;
}

class SpectrumPainter extends CustomPainter {
  SpectrumPainter({
    required this.spectrum,
    required this.centerFrequencyHz,
    required this.sampleRateHz,
  });

  final Float32List spectrum;
  final int centerFrequencyHz;
  final int sampleRateHz;

  @override
  void paint(Canvas canvas, Size size) {
    const minDb = -115.0;
    const maxDb = -20.0;
    final grid = Paint()
      ..color = const Color(0xFF192632)
      ..strokeWidth = 1;

    for (var i = 1; i < 5; i++) {
      final y = size.height * i / 5;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    for (var i = 1; i < 8; i++) {
      final x = size.width * i / 8;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }

    if (spectrum.isNotEmpty) {
      final path = Path();
      for (var i = 0; i < spectrum.length; i++) {
        final denominator = math.max(1, spectrum.length - 1).toDouble();
        final x = size.width * i / denominator;
        final normalized = ((spectrum[i] - minDb) / (maxDb - minDb))
            .clamp(0.0, 1.0)
            .toDouble();
        final y = size.height * (1.0 - normalized);
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }

      final fill = Path.from(path)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close();

      canvas.drawPath(
        fill,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[
              Color(0x4D67E8F9),
              Color(0x0067E8F9),
            ],
          ).createShader(Offset.zero & size),
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0xFF67E8F9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.7,
      );
    }

    final center = size.width / 2;
    canvas.drawLine(
      Offset(center, 0),
      Offset(center, size.height),
      Paint()
        ..color = const Color(0xFFFF5D73)
        ..strokeWidth = 1.3,
    );

    final leftMhz = (centerFrequencyHz - sampleRateHz / 2) / 1000000;
    final centerMhz = centerFrequencyHz / 1000000;
    final rightMhz = (centerFrequencyHz + sampleRateHz / 2) / 1000000;
    _drawLabel(canvas, '${leftMhz.toStringAsFixed(3)}M', 8, size.height - 22);
    _drawLabel(
      canvas,
      '${centerMhz.toStringAsFixed(3)}M',
      center - 30,
      size.height - 22,
    );
    _drawLabel(
      canvas,
      '${rightMhz.toStringAsFixed(3)}M',
      size.width - 70,
      size.height - 22,
    );
  }

  void _drawLabel(Canvas canvas, String text, double x, double y) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Color(0xFF66798E),
          fontSize: 10,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, Offset(x, y));
  }

  @override
  bool shouldRepaint(covariant SpectrumPainter oldDelegate) {
    return oldDelegate.spectrum != spectrum ||
        oldDelegate.centerFrequencyHz != centerFrequencyHz ||
        oldDelegate.sampleRateHz != sampleRateHz;
  }
}

class WaterfallPainter extends CustomPainter {
  WaterfallPainter({required this.history});

  final List<Float32List> history;

  static const minDb = -115.0;
  static const maxDb = -25.0;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF050A10),
    );

    if (history.isEmpty) {
      final painter = TextPainter(
        text: const TextSpan(
          text: 'Connect RTL-TCP to start live spectrum',
          style: TextStyle(
            color: Color(0xFF526579),
            fontSize: 13,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(
        canvas,
        Offset(
          (size.width - painter.width) / 2,
          (size.height - painter.height) / 2,
        ),
      );
      return;
    }

    final rows = history.length < 92 ? history.length : 92;
    final rowHeight = size.height / rows;
    final paint = Paint();

    for (var row = 0; row < rows; row++) {
      final bins = history[row];
      final cellWidth = size.width / bins.length;
      for (var col = 0; col < bins.length; col++) {
        paint.color = _heatColor(bins[col]);
        canvas.drawRect(
          Rect.fromLTWH(
            col * cellWidth,
            row * rowHeight,
            cellWidth + 0.4,
            rowHeight + 0.4,
          ),
          paint,
        );
      }
    }

    canvas.drawLine(
      Offset(size.width / 2, 0),
      Offset(size.width / 2, size.height),
      Paint()
        ..color = const Color(0x99FF5D73)
        ..strokeWidth = 1,
    );
  }

  Color _heatColor(double db) {
    final t = ((db - minDb) / (maxDb - minDb)).clamp(0.0, 1.0).toDouble();
    if (t < 0.25) {
      return Color.lerp(
            const Color(0xFF02050A),
            const Color(0xFF082B6E),
            t / 0.25,
          ) ??
          const Color(0xFF02050A);
    }
    if (t < 0.5) {
      return Color.lerp(
            const Color(0xFF082B6E),
            const Color(0xFF00C8E8),
            (t - 0.25) / 0.25,
          ) ??
          const Color(0xFF082B6E);
    }
    if (t < 0.75) {
      return Color.lerp(
            const Color(0xFF00C8E8),
            const Color(0xFFFFE45E),
            (t - 0.5) / 0.25,
          ) ??
          const Color(0xFF00C8E8);
    }
    return Color.lerp(
          const Color(0xFFFFE45E),
          const Color(0xFFFF4D6D),
          (t - 0.75) / 0.25,
        ) ??
        const Color(0xFFFF4D6D);
  }

  @override
  bool shouldRepaint(covariant WaterfallPainter oldDelegate) => true;
}
