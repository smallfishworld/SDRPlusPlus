import 'dart:math' as math;
import 'package:flutter/material.dart';

class ReceiverScreen extends StatefulWidget {
  const ReceiverScreen({super.key});

  @override
  State<ReceiverScreen> createState() => _ReceiverScreenState();
}

class _ReceiverScreenState extends State<ReceiverScreen> {
  int _tab = 0;
  String _mode = 'AM';
  double _bandwidthKhz = 10;

  static const modes = ['AM', 'NFM', 'WFM', 'USB', 'LSB'];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 760;
            final content = _receiverBody();
            return wide
                ? Row(
                    children: [
                      NavigationRail(
                        selectedIndex: _tab,
                        onDestinationSelected: (value) => setState(() => _tab = value),
                        destinations: const [
                          NavigationRailDestination(icon: Icon(Icons.graphic_eq), label: Text('Receive')),
                          NavigationRailDestination(icon: Icon(Icons.star_outline), label: Text('Presets')),
                          NavigationRailDestination(icon: Icon(Icons.radar), label: Text('Scan')),
                          NavigationRailDestination(icon: Icon(Icons.tune), label: Text('Settings')),
                        ],
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(child: content),
                    ],
                  )
                : content;
          },
        ),
      ),
      bottomNavigationBar: MediaQuery.sizeOf(context).width < 760
          ? NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (value) => setState(() => _tab = value),
              destinations: const [
                NavigationDestination(icon: Icon(Icons.graphic_eq), label: 'Receive'),
                NavigationDestination(icon: Icon(Icons.star_outline), label: 'Presets'),
                NavigationDestination(icon: Icon(Icons.radar), label: 'Scan'),
                NavigationDestination(icon: Icon(Icons.tune), label: 'Settings'),
              ],
            )
          : null,
    );
  }

  Widget _receiverBody() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        children: [
          _header(),
          const SizedBox(height: 14),
          _frequencyCard(),
          const SizedBox(height: 14),
          Expanded(child: _spectrumCard()),
          const SizedBox(height: 14),
          _modeBar(),
        ],
      ),
    );
  }

  Widget _header() {
    return Row(
      children: [
        const Text(
          'SDR++',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        ),
        const Spacer(),
        FilledButton.tonalIcon(
          onPressed: () {},
          icon: const Icon(Icons.circle, size: 10),
          label: const Text('Orange Pi · Connected'),
        ),
        const SizedBox(width: 8),
        IconButton(onPressed: () {}, icon: const Icon(Icons.settings_outlined)),
      ],
    );
  }

  Widget _frequencyCard() {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: _showFrequencyPad,
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 18, vertical: 18),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('127.250.000', style: TextStyle(fontSize: 34, fontWeight: FontWeight.w700, letterSpacing: 1)),
                    SizedBox(height: 2),
                    Text('MHz  ·  Hangzhou ATIS', style: TextStyle(color: Color(0xFF93A4B7))),
                  ],
                ),
              ),
              Icon(Icons.dialpad_rounded),
            ],
          ),
        ),
      ),
    );
  }

  Widget _spectrumCard() {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Expanded(
            flex: 4,
            child: CustomPaint(
              painter: SpectrumPainter(),
              child: const SizedBox.expand(),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            flex: 6,
            child: CustomPaint(
              painter: WaterfallPainter(),
              child: const SizedBox.expand(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeBar() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          children: [
            Row(
              children: [
                for (final mode in modes)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: ChoiceChip(
                        selected: _mode == mode,
                        label: SizedBox(width: double.infinity, child: Center(child: Text(mode))),
                        onSelected: (_) => setState(() => _mode = mode),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _metric('BW', '${_bandwidthKhz.toStringAsFixed(0)} kHz', () {
                  setState(() => _bandwidthKhz = _bandwidthKhz == 10 ? 12 : 10);
                }),
                _metric('SQL', 'Off', () {}),
                _metric('GAIN', 'Auto', () {}),
                _metric('VOL', '72%', () {}),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _metric(String label, String value, VoidCallback onTap) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 9),
          child: Column(
            children: [
              Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF718297))),
              const SizedBox(height: 3),
              Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showFrequencyPad() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => const Padding(
        padding: EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('127.250 MHz', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700)),
            SizedBox(height: 16),
            _KeypadPreview(),
          ],
        ),
      ),
    );
  }
}

class _KeypadPreview extends StatelessWidget {
  const _KeypadPreview();

  @override
  Widget build(BuildContext context) {
    const keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '.', '0', '⌫'];
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 2.1,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      children: [
        for (final key in keys) FilledButton.tonal(onPressed: () {}, child: Text(key, style: const TextStyle(fontSize: 20))),
      ],
    );
  }
}

class SpectrumPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()..color = const Color(0xFF1C2733)..strokeWidth = 1;
    for (var i = 1; i < 6; i++) {
      final y = size.height * i / 6;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    for (var i = 1; i < 8; i++) {
      final x = size.width * i / 8;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }

    final path = Path();
    for (var i = 0; i <= 180; i++) {
      final x = size.width * i / 180;
      final noise = math.sin(i * .51) * 4 + math.sin(i * .17) * 2;
      final peak = 52 * math.exp(-math.pow((i - 104) / 5.0, 2));
      final y = size.height * .72 - noise - peak;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, Paint()..color = const Color(0xFF67E8F9)..style = PaintingStyle.stroke..strokeWidth = 2);
    canvas.drawLine(
      Offset(size.width * .58, 0),
      Offset(size.width * .58, size.height),
      Paint()..color = const Color(0xFFFF566E)..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class WaterfallPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = const Color(0xFF071018);
    canvas.drawRect(Offset.zero & size, bg);
    final line = Paint()..strokeWidth = 1;
    for (var y = 0.0; y < size.height; y += 4) {
      final t = y / size.height;
      final v = (90 + 100 * math.sin(y * .08)).round().clamp(0, 255);
      line.color = Color.fromARGB(255, 8, v ~/ 3, 80 + (80 * (1 - t)).round());
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
    final signal = Paint()..color = const Color(0xB36EE7F9)..strokeWidth = 3;
    canvas.drawLine(Offset(size.width * .58, 0), Offset(size.width * .58, size.height), signal);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
