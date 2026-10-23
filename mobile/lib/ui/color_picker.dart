import 'package:flutter/material.dart';

/// Shows a HSV color picker with opacity. Returns null if cancelled.
Future<Color?> showColorPicker(BuildContext context, Color initial, {bool alpha = true}) {
  return showDialog<Color>(
    context: context,
    builder: (_) => _ColorPickerDialog(initial: initial, alpha: alpha),
  );
}

class _ColorPickerDialog extends StatefulWidget {
  const _ColorPickerDialog({required this.initial, required this.alpha});
  final Color initial;
  final bool alpha;

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  late HSVColor hsv = HSVColor.fromColor(widget.initial);
  late final hexController = TextEditingController(text: _hex(widget.initial));

  static String _hex(Color c) =>
      c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase().substring(2);

  void _update(HSVColor v) {
    setState(() => hsv = v);
    hexController.text = _hex(v.toColor());
  }

  @override
  Widget build(BuildContext context) {
    final color = hsv.toColor();
    return AlertDialog(
      title: const Text('Elegir color'),
      content: SizedBox(
        width: 320,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            height: 48,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
            ),
          ),
          const SizedBox(height: 16),
          _GradientSlider(
            label: 'Tono',
            value: hsv.hue / 360,
            colors: [
              for (var h = 0; h <= 360; h += 60) HSVColor.fromAHSV(1, h.toDouble(), 1, 1).toColor()
            ],
            onChanged: (v) => _update(hsv.withHue(v * 360)),
          ),
          _GradientSlider(
            label: 'Saturación',
            value: hsv.saturation,
            colors: [hsv.withSaturation(0).withAlpha(1).toColor(), hsv.withSaturation(1).withAlpha(1).toColor()],
            onChanged: (v) => _update(hsv.withSaturation(v)),
          ),
          _GradientSlider(
            label: 'Brillo',
            value: hsv.value,
            colors: [Colors.black, hsv.withValue(1).withAlpha(1).toColor()],
            onChanged: (v) => _update(hsv.withValue(v)),
          ),
          if (widget.alpha)
            _GradientSlider(
              label: 'Opacidad',
              value: hsv.alpha,
              colors: [hsv.withAlpha(0).toColor(), hsv.withAlpha(1).toColor()],
              onChanged: (v) => _update(hsv.withAlpha(v)),
            ),
          const SizedBox(height: 8),
          TextField(
            controller: hexController,
            decoration: const InputDecoration(prefixText: '#', labelText: 'Hex', isDense: true),
            onSubmitted: (t) {
              final v = int.tryParse(t.replaceAll('#', ''), radix: 16);
              if (v != null && t.replaceAll('#', '').length == 6) {
                setState(() => hsv = HSVColor.fromColor(Color(0xFF000000 | v)).withAlpha(hsv.alpha));
              }
            },
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(context, color), child: const Text('Aceptar')),
      ],
    );
  }
}

class _GradientSlider extends StatelessWidget {
  const _GradientSlider({
    required this.label,
    required this.value,
    required this.colors,
    required this.onChanged,
  });

  final String label;
  final double value;
  final List<Color> colors;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 4),
        LayoutBuilder(builder: (context, constraints) {
          final w = constraints.maxWidth;
          void handle(Offset local) => onChanged((local.dx / w).clamp(0.0, 1.0));
          return GestureDetector(
            onPanDown: (d) => handle(d.localPosition),
            onPanUpdate: (d) => handle(d.localPosition),
            child: SizedBox(
              height: 28,
              child: Stack(clipBehavior: Clip.none, children: [
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      gradient: LinearGradient(colors: colors),
                      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                    ),
                  ),
                ),
                Positioned(
                  left: (value.clamp(0.0, 1.0) * w) - 14,
                  top: 0,
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 3),
                      boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black38)],
                    ),
                  ),
                ),
              ]),
            ),
          );
        }),
      ]),
    );
  }
}
