import 'dart:math' as math;
import 'package:flutter/material.dart';

class PackGauge extends StatelessWidget {
  final String label;
  final double value;
  final String unit;
  final double min;
  final double max;

  const PackGauge({
    super.key,
    required this.label,
    required this.value,
    required this.unit,
    required this.min,
    required this.max,
  });

  @override
  Widget build(BuildContext context) {
    final valid = !value.isNaN && !value.isInfinite;
    final pct = valid ? ((value - min) / (max - min)).clamp(0.0, 1.0) : 0.0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            Text(label,
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
            const SizedBox(height: 4),
            SizedBox(
              width: 80,
              height: 80,
              child: CustomPaint(
                painter: _GaugePainter(pct),
                child: Center(
                  child: Text(
                    valid ? value.toStringAsFixed(1) : '--',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
            Text(unit, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  final double pct;
  _GaugePainter(this.pct);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 4;
    const startAngle = 2.3;
    const sweepAngle = 4.7;

    final bgPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..color = Colors.grey.withValues(alpha: 0.2)
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepAngle,
      false,
      bgPaint,
    );

    if (pct > 0) {
      final fgPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..color = pct < 0.2
            ? Colors.red
            : pct < 0.8
                ? Colors.green
                : Colors.blue
        ..strokeCap = StrokeCap.round;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweepAngle * pct,
        false,
        fgPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_GaugePainter old) => old.pct != pct;
}
