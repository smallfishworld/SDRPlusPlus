import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/audio_output.dart';
import '../services/rtl_tcp_client.dart';

class ReceiverScreen extends StatefulWidget {
  const ReceiverScreen({super.key});

  @override
  State<ReceiverScreen> createState() => _ReceiverScreenState();
}

class _ReceiverScreenState extends State<ReceiverScreen> {
  final RtlTcpClient _client = RtlTcpClient();
  final AudioOutput _audio = AudioOutput();
  final TextEditingController _hostController =
      TextEditingController(text: '192.168.2.110');
  final TextEditingController _portController =
      TextEditingController(text: '1234');

  StreamSubscription<Float32List>? _spectrumSubscription;
  StreamSubscription<Uint8List>? _audioSubscription;
  StreamSubscription<RtlTcpConnectionState>? _stateSubscription;
  Timer? _scannerTimer;

  int _tab = 0;
  int _frequencyHz = 127250000;
  int _sampleRateHz = 1024000;
  String _mode = 'AM';
  double _bandwidthKhz = 10;
  bool _tunerAgc = true;
  bool _rtlAgc = false;
  bool _biasTee = false;
  bool _offsetTuning = false;
  int _directSampling = 0;
  int _ppm = 0;
  double _manualGainDb = 0;
  bool _squelchEnabled = false;
  double _squelchDb = -82;
  double _volume = 0.72;
  int _tuningStepHz = 25000;
  double _dragAccumulatorPx = 0;
  bool _scanning = false;
  int _scanFrequencyHz = 118000000;
  RtlTcpConnectionState _connectionState =
      RtlTcpConnectionState.disconnected;
  String _connectionError = '';

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
    100,
    500,
    1000,
    5000,
    8330,
    10000,
    12500,
    25000,
    100000,
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
    _Preset('浙江之声', 88000000, 'WFM', 180000, 'Hangzhou FM'),
    _Preset('杭州之声', 89000000, 'WFM', 180000, 'Hangzhou FM'),
    _Preset('Z907 城市资讯', 90700000, 'WFM', 180000, 'Hangzhou FM'),
    _Preset('杭州交通 918', 91800000, 'WFM', 180000, 'Hangzhou FM'),
    _Preset('浙江交通之声', 93000000, 'WFM', 180000, 'Hangzhou FM'),
    _Preset('浙江经济广播', 95000000, 'WFM', 180000, 'Hangzhou FM'),
    _Preset('动听 968', 96800000, 'WFM', 180000, 'Hangzhou FM'),
    _Preset('浙江民生资讯', 99600000, 'WFM', 180000, 'Hangzhou FM'),
    _Preset('浙江旅游之声', 104500000, 'WFM', 180000, 'Hangzhou FM'),
    _Preset('西湖之声', 105400000, 'WFM', 180000, 'Hangzhou FM'),
    _Preset('浙江城市之声', 107000000, 'WFM', 180000, 'Hangzhou FM'),

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
    _audioSubscription = _client.audioStream.listen(_audio.addPcm);
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
    unawaited(_spectrumSubscription?.cancel());
    unawaited(_audioSubscription?.cancel());
    unawaited(_stateSubscription?.cancel());
    unawaited(_client.dispose());
    unawaited(_audio.dispose());
    _hostController.dispose();
    _portController.dispose();
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
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: const LinearGradient(
              colors: <Color>[Color(0xFF67E8F9), Color(0xFF8B5CF6)],
            ),
          ),
          child: const Icon(Icons.waves_rounded, color: Color(0xFF051014)),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'SDR++',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
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
      onTap: () => setState(() => _tab = 3),
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
                        if (subtitle.isNotEmpty) ...<Widget>[
                          const SizedBox(width: 8),
                          const Text(
                            '·',
                            style: TextStyle(color: Color(0xFF526377)),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              subtitle,
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

  Widget _spectrumCard() {
    final streamLabel = _connectionState == RtlTcpConnectionState.connected
        ? '${(_sampleRateHz / 1000000).toStringAsFixed(3)} MSPS'
        : 'No RF stream';

    return Card(
      clipBehavior: Clip.antiAlias,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
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
              child: _tinyBadge(_mode),
            ),
            Positioned(
              left: 12,
              bottom: 10,
              child: _tinyBadge('Drag to tune · step ${_formatStep(_tuningStepHz)}'),
            ),
          ],
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
                _metric(
                  'SQL',
                  _squelchEnabled
                      ? '${_squelchDb.toStringAsFixed(0)} dB'
                      : 'Off',
                  _showSquelchSheet,
                ),
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
            'WFM' => 180,
            'NFM' => 12.5,
            'USB' || 'LSB' => 2.7,
            'CW' => 0.8,
            'DSB' => 6.0,
            _ => 10,
          };
        });
        _client.setMode(mode);
        _client.setBandwidth(_bandwidthKhz * 1000);
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        children: <Widget>[
          _appHeader('Presets'),
          const SizedBox(height: 18),
          Expanded(
            child: ListView.separated(
              itemCount: _presets.length,
              separatorBuilder: (_, __) => const SizedBox(height: 9),
              itemBuilder: (context, index) {
                final preset = _presets[index];
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
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        const Text(
                          'RTL-TCP receiver',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 5),
                        const Text(
                          'Network SDR source shared across Android, iOS, Windows and macOS.',
                          style: TextStyle(color: Color(0xFF7F91A5)),
                        ),
                        const SizedBox(height: 18),
                        TextField(
                          controller: _hostController,
                          decoration: const InputDecoration(
                            labelText: 'Host',
                            prefixIcon: Icon(Icons.dns_outlined),
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _portController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Port',
                            prefixIcon: Icon(Icons.lan_outlined),
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<int>(
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
                          Text('Manual gain  ${_manualGainDb.toStringAsFixed(1)} dB'),
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
                          subtitle: const Text('Enable antenna bias power when supported'),
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
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          onPressed: connected ? _disconnect : _connect,
                          icon: Icon(
                            connected
                                ? Icons.link_off_rounded
                                : Icons.link_rounded,
                          ),
                          label: Text(
                            connected
                                ? 'Disconnect'
                                : 'Connect to receiver',
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
                ),
                const SizedBox(height: 12),
                Card(
                  child: const ListTile(
                    leading: Icon(Icons.memory_rounded),
                    title: Text('Native SDR engine'),
                    subtitle: Text(
                      'Live AM/NFM/WFM audio currently runs in an isolated Dart DSP worker with SoLoud output. The stable C ABI remains the path for the optimized native engine.',
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

  Future<void> _showBandwidthSheet() async {
    const options = <double>[0.5, 0.8, 1.8, 2.4, 2.7, 3.0, 6.0, 8.0, 10.0, 12.5, 15.0, 25.0, 50.0, 100.0, 150.0, 180.0, 200.0];
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
      });
      _client.setSquelch(_squelchEnabled, _squelchDb);
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

  void _tuneFrequency(int frequencyHz) {
    final clamped =
        frequencyHz.clamp(100000, 6000000000).toInt();
    setState(() {
      _frequencyHz = clamped;
      _scanFrequencyHz = clamped;
    });
    _client.setFrequency(clamped);
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
    });
    _client.setMode(_mode);
    _client.setBandwidth(preset.bandwidthHz);
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
      setState(() => _tab = 3);
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
      _tuneFrequency(next);
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
