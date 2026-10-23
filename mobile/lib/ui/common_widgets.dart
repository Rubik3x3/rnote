import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Material has no eraser icon, so it is painted.
class EraserIcon extends StatelessWidget {
  const EraserIcon({super.key, this.size = 24, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? IconTheme.of(context).color ?? Colors.black;
    return SizedBox.square(dimension: size, child: CustomPaint(painter: _EraserPainter(c)));
  }
}

class _EraserPainter extends CustomPainter {
  _EraserPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(-math.pi / 4);
    final body = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset.zero, width: 18 * s, height: 9 * s), Radius.circular(2 * s));
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8 * s;
    canvas.drawRRect(body, stroke);
    canvas.drawRRect(
        RRect.fromRectAndCorners(Rect.fromLTRB(-9 * s, -4.5 * s, -2 * s, 4.5 * s),
            topLeft: Radius.circular(2 * s), bottomLeft: Radius.circular(2 * s)),
        Paint()..color = color);
    canvas.restore();
    canvas.drawLine(Offset(9 * s, 21 * s), Offset(21 * s, 21 * s), stroke);
  }

  @override
  bool shouldRepaint(_EraserPainter old) => old.color != color;
}

/// A round color swatch.
class ColorSwatchButton extends StatelessWidget {
  const ColorSwatchButton({
    super.key,
    required this.color,
    this.selected = false,
    this.size = 28,
    this.onTap,
    this.onLongPress,
  });

  final Color color;
  final bool selected;
  final double size;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        width: size,
        height: size,
        margin: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 3 : 1,
          ),
        ),
        child: Padding(
          padding: EdgeInsets.all(selected ? 2 : 1),
          child: CustomPaint(painter: _CheckerCirclePainter(color)),
        ),
      ),
    );
  }
}

class _CheckerCirclePainter extends CustomPainter {
  _CheckerCirclePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide / 2;
    final center = size.center(Offset.zero);
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: center, radius: r)));
    if (color.a < 1) {
      final cell = r / 2;
      for (var y = 0.0; y < size.height; y += cell) {
        for (var x = 0.0; x < size.width; x += cell) {
          final dark = ((x / cell).floor() + (y / cell).floor()).isEven;
          canvas.drawRect(Rect.fromLTWH(x, y, cell, cell),
              Paint()..color = dark ? const Color(0xFFBBBBBB) : const Color(0xFFFFFFFF));
        }
      }
    }
    canvas.drawCircle(center, r, Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CheckerCirclePainter old) => old.color != color;
}

/// A slider with a label and the current value.
class LabeledSlider extends StatelessWidget {
  const LabeledSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.format,
    this.divisions,
  });

  final String label;
  final double value, min, max;
  final ValueChanged<double> onChanged;
  final String Function(double)? format;
  final int? divisions;

  @override
  Widget build(BuildContext context) {
    final text = format?.call(value) ?? value.toStringAsFixed(1);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(children: [
          Text(label, style: Theme.of(context).textTheme.labelLarge),
          const Spacer(),
          Text(text, style: Theme.of(context).textTheme.labelMedium),
        ]),
      ),
      SliderTheme(
        data: SliderTheme.of(context).copyWith(
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
        ),
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ),
    ]);
  }
}

/// Section title used in sheets and panels.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .labelLarge
                ?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}
