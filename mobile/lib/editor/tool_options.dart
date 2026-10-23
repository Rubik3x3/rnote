import 'package:flutter/material.dart';

import '../rnote/model.dart';
import '../settings/app_settings.dart';
import '../ui/color_picker.dart';
import '../ui/common_widgets.dart';
import 'editor_controller.dart';

const pressureCurveLabels = {
  PressureCurve.constant: 'Constante',
  PressureCurve.linear: 'Lineal',
  PressureCurve.sqrt: 'Suave (√)',
  PressureCurve.cbrt: 'Muy suave (∛)',
  PressureCurve.pow2: 'Marcada (x²)',
  PressureCurve.pow3: 'Muy marcada (x³)',
};

const lineStyleLabels = {
  LineStyle.solid: 'Continua',
  LineStyle.dashedNarrow: 'Guiones cortos',
  LineStyle.dashedEquidistant: 'Guiones',
  LineStyle.dashedWide: 'Guiones largos',
  LineStyle.dotted: 'Puntos',
};

const shapeTypeLabels = {
  'line': ('Línea', Icons.horizontal_rule),
  'arrow': ('Flecha', Icons.north_east),
  'rect': ('Rectángulo', Icons.crop_square),
  'ellipse': ('Elipse', Icons.circle_outlined),
};

/// The options of the current tool, shown in a popup next to the tool rail.
class ToolOptionsPanel extends StatelessWidget {
  const ToolOptionsPanel({super.key, required this.controller, required this.tool});

  final EditorController controller;
  final Tool tool;

  AppSettings get s => controller.settings;

  @override
  Widget build(BuildContext context) {
    final children = switch (tool) {
      Tool.pen => _pen(context),
      Tool.highlighter => _highlighter(context),
      Tool.eraser => _eraser(context),
      Tool.select => _select(context),
      Tool.shape => _shape(context),
      Tool.text => _text(context),
      Tool.pan => [
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text('Arrastra para desplazar el lienzo. Pellizca con dos dedos para hacer zoom.'),
          )
        ],
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
          child: Text(tool.label, style: Theme.of(context).textTheme.titleMedium),
        ),
        ...children,
      ],
    );
  }

  Widget _colors(BuildContext context, {bool translucent = false}) {
    final current = controller.colorOf(tool);
    final palette = s.palette;
    return Wrap(children: [
      for (var i = 0; i < palette.length; i++)
        ColorSwatchButton(
          color: translucent ? palette[i].withValues(alpha: current.a) : palette[i],
          selected: palette[i].toARGB32() & 0xFFFFFF == current.toARGB32() & 0xFFFFFF,
          onTap: () => controller.setColorFor(
              tool, translucent ? palette[i].withValues(alpha: current.a) : palette[i]),
          onLongPress: () async {
            final picked = await showColorPicker(context, palette[i], alpha: false);
            if (picked != null) s.setPaletteColor(i, picked);
          },
        ),
      IconButton(
        tooltip: 'Color personalizado',
        icon: const Icon(Icons.palette_outlined),
        onPressed: () async {
          final picked = await showColorPicker(context, current);
          if (picked != null) controller.setColorFor(tool, picked);
        },
      ),
    ]);
  }

  List<Widget> _pen(BuildContext context) => [
        LabeledSlider(
          label: 'Grosor',
          value: s.penWidth,
          min: 0.5,
          max: 30,
          format: (v) => v.toStringAsFixed(1),
          onChanged: (v) => s.penWidth = v,
        ),
        const SectionLabel('Color'),
        _colors(context),
        const SectionLabel('Estilo'),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'smooth', label: Text('Liso'), icon: Icon(Icons.gesture)),
            ButtonSegment(value: 'textured', label: Text('Lápiz'), icon: Icon(Icons.texture)),
          ],
          selected: {s.penStyle},
          onSelectionChanged: (v) => s.penStyle = v.first,
        ),
        const SectionLabel('Respuesta a la presión'),
        Wrap(spacing: 6, runSpacing: 4, children: [
          for (final e in pressureCurveLabels.entries)
            ChoiceChip(
              label: Text(e.value),
              selected: s.penCurve == e.key,
              onSelected: (_) => s.penCurve = e.key,
            ),
        ]),
      ];

  List<Widget> _highlighter(BuildContext context) => [
        LabeledSlider(
          label: 'Grosor',
          value: s.highlighterWidth,
          min: 4,
          max: 80,
          format: (v) => v.toStringAsFixed(0),
          onChanged: (v) => s.highlighterWidth = v,
        ),
        LabeledSlider(
          label: 'Opacidad',
          value: s.highlighterColor.a,
          min: 0.1,
          max: 0.9,
          format: (v) => '${(v * 100).round()} %',
          onChanged: (v) => s.highlighterColor = s.highlighterColor.withValues(alpha: v),
        ),
        const SectionLabel('Color'),
        _colors(context, translucent: true),
      ];

  List<Widget> _eraser(BuildContext context) => [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'stroke', label: Text('Trazos')),
            ButtonSegment(value: 'split', label: Text('Partes')),
          ],
          selected: {s.eraserMode},
          onSelectionChanged: (v) => s.eraserMode = v.first,
        ),
        Padding(
          padding: const EdgeInsets.all(4),
          child: Text(
            s.eraserMode == 'stroke'
                ? 'Borra los trazos completos que toca.'
                : 'Borra sólo la parte de los trazos que toca.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        LabeledSlider(
          label: 'Tamaño',
          value: s.eraserSize,
          min: 8,
          max: 140,
          format: (v) => '${v.round()} px',
          onChanged: (v) => s.eraserSize = v,
        ),
        const SizedBox(height: 4),
        OutlinedButton.icon(
          icon: const Icon(Icons.delete_sweep_outlined),
          label: const Text('Borrar todo'),
          onPressed: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('¿Borrar todo el contenido?'),
                content: const Text('Se puede deshacer.'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
                  FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Borrar')),
                ],
              ),
            );
            if (ok == true) controller.clearAll();
          },
        ),
      ];

  List<Widget> _select(BuildContext context) => [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'lasso', label: Text('Lazo'), icon: Icon(Icons.gesture)),
            ButtonSegment(value: 'rect', label: Text('Rectángulo'), icon: Icon(Icons.crop_free)),
          ],
          selected: {s.selectMode},
          onSelectionChanged: (v) => s.selectMode = v.first,
        ),
        const SizedBox(height: 8),
        Text(
          'Rodea trazos para seleccionarlos o toca uno. Arrastra la selección para moverla y el '
          'punto de la esquina para cambiar su tamaño.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.select_all),
          label: const Text('Seleccionar todo'),
          onPressed: controller.selectAll,
        ),
      ];

  List<Widget> _shape(BuildContext context) => [
        Wrap(spacing: 6, children: [
          for (final e in shapeTypeLabels.entries)
            ChoiceChip(
              avatar: Icon(e.value.$2, size: 18),
              label: Text(e.value.$1),
              selected: s.shapeType == e.key,
              onSelected: (_) => s.shapeType = e.key,
            ),
        ]),
        LabeledSlider(
          label: 'Grosor',
          value: s.shapeWidth,
          min: 0.5,
          max: 20,
          onChanged: (v) => s.shapeWidth = v,
        ),
        DropdownButtonFormField<String>(
          initialValue: s.shapeLineStyle,
          decoration: const InputDecoration(labelText: 'Línea', isDense: true),
          items: [
            for (final e in lineStyleLabels.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
          ],
          onChanged: (v) => s.shapeLineStyle = v ?? LineStyle.solid,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('Relleno'),
          value: s.shapeFill,
          onChanged: (v) => s.shapeFill = v,
        ),
        const SectionLabel('Color'),
        _colors(context),
      ];

  List<Widget> _text(BuildContext context) => [
        LabeledSlider(
          label: 'Tamaño',
          value: s.textSize,
          min: 8,
          max: 160,
          format: (v) => v.round().toString(),
          onChanged: (v) => s.textSize = v,
        ),
        const SectionLabel('Color'),
        _colors(context),
        Padding(
          padding: const EdgeInsets.all(4),
          child: Text('Toca el lienzo para escribir, o un texto para editarlo.',
              style: Theme.of(context).textTheme.bodySmall),
        ),
      ];
}
