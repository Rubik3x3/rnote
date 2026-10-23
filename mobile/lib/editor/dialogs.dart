import 'package:flutter/material.dart';

import '../rnote/model.dart';
import '../ui/color_picker.dart';
import '../ui/common_widgets.dart';
import 'editor_controller.dart';

/// Page formats in Rnote's units (pixels at 96 dpi).
const pageFormats = <String, (String, double, double)>{
  'a6': ('A6', 396.85, 559.37),
  'a5': ('A5', 559.37, 793.701),
  'a4': ('A4', 793.701, 1122.52),
  'a3': ('A3', 1122.52, 1587.402),
  'letter': ('Carta', 816, 1056),
  'legal': ('Oficio (Legal)', 816, 1344),
};

const layoutLabels = {
  Layout.infinite: ('Infinito', Icons.all_out),
  Layout.semiInfinite: ('Semi-infinito', Icons.south_east),
  Layout.continuousVertical: ('Vertical continuo', Icons.view_day_outlined),
  Layout.fixedSize: ('Páginas fijas', Icons.description_outlined),
};

const patternLabels = {
  PatternStyle.none: 'Liso',
  PatternStyle.lines: 'Líneas',
  PatternStyle.grid: 'Cuadrícula',
  PatternStyle.dots: 'Puntos',
  PatternStyle.isometricGrid: 'Isométrica',
  PatternStyle.isometricDots: 'Puntos isom.',
};

const backgroundPresets = <(String, Color, Color)>[
  ('Blanco', Color(0xFFFFFFFF), Color(0xFFCCE5FF)),
  ('Crema', Color(0xFFFBF6E9), Color(0xFFD9CBB0)),
  ('Gris', Color(0xFF3A3A3E), Color(0xFF5A5A60)),
  ('Pizarra', Color(0xFF1F3B2D), Color(0xFF3C5A4A)),
  ('Negro', Color(0xFF121212), Color(0xFF333333)),
];

String? formatKeyFor(DocFormat f) {
  for (final e in pageFormats.entries) {
    final (_, w, h) = e.value;
    if (((f.width - w).abs() < 2 && (f.height - h).abs() < 2) ||
        ((f.width - h).abs() < 2 && (f.height - w).abs() < 2)) {
      return e.key;
    }
  }
  return null;
}

DocFormat applyFormat(DocFormat f, String key, String orientation) {
  final (_, w, h) = pageFormats[key]!;
  final landscape = orientation == 'landscape';
  return f.copyWith(width: landscape ? h : w, height: landscape ? w : h, orientation: orientation);
}

/// Document settings: layout, page format and background.
Future<void> showDocumentSettings(BuildContext context, EditorController controller) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => ListenableBuilder(
      listenable: controller,
      builder: (ctx, _) {
        final config = controller.doc.config;
        final bg = config.background;
        final format = config.format;
        final formatKey = formatKeyFor(format);
        void update(DocConfig c) => controller.updateConfig(c);
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          maxChildSize: 0.95,
          builder: (ctx, scroll) => ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            children: [
              Text('Documento', style: Theme.of(ctx).textTheme.titleLarge),
              const SectionLabel('Diseño'),
              Wrap(spacing: 8, runSpacing: 6, children: [
                for (final e in layoutLabels.entries)
                  ChoiceChip(
                    avatar: Icon(e.value.$2, size: 18),
                    label: Text(e.value.$1),
                    selected: config.layout == e.key,
                    onSelected: (_) => update(config.copyWith(layout: e.key)),
                  ),
              ]),
              const SectionLabel('Formato de página'),
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<String?>(
                    initialValue: formatKey,
                    isDense: true,
                    decoration: const InputDecoration(isDense: true),
                    items: [
                      for (final e in pageFormats.entries)
                        DropdownMenuItem(value: e.key, child: Text(e.value.$1)),
                      if (formatKey == null)
                        DropdownMenuItem(
                            value: null,
                            child: Text('Personalizado ${format.width.round()}×${format.height.round()}')),
                    ],
                    onChanged: (k) {
                      if (k != null) {
                        update(config.copyWith(format: applyFormat(format, k, format.orientation)));
                      }
                    },
                  ),
                ),
                const SizedBox(width: 12),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'portrait', icon: Icon(Icons.crop_portrait)),
                    ButtonSegment(value: 'landscape', icon: Icon(Icons.crop_landscape)),
                  ],
                  selected: {format.width > format.height ? 'landscape' : 'portrait'},
                  onSelectionChanged: (v) {
                    final o = v.first;
                    final landscape = o == 'landscape';
                    final w = landscape ? format.height : format.width;
                    final h = landscape ? format.width : format.height;
                    if ((format.width > format.height) == landscape) return;
                    update(config.copyWith(format: format.copyWith(width: w, height: h, orientation: o)));
                  },
                ),
              ]),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Mostrar bordes de página'),
                value: format.showBorders,
                onChanged: (v) => update(config.copyWith(format: format.copyWith(showBorders: v))),
              ),
              const SectionLabel('Fondo'),
              Wrap(children: [
                for (final (name, color, pattern) in backgroundPresets)
                  Tooltip(
                    message: name,
                    child: ColorSwatchButton(
                      size: 36,
                      color: color,
                      selected: bg.color.toUi().toARGB32() == color.toARGB32(),
                      onTap: () => update(config.copyWith(
                          background: bg.copyWith(
                              color: RColor.fromUi(color), patternColor: RColor.fromUi(pattern)))),
                    ),
                  ),
                IconButton(
                  icon: const Icon(Icons.palette_outlined),
                  tooltip: 'Color personalizado',
                  onPressed: () async {
                    final c = await showColorPicker(ctx, bg.color.toUi(), alpha: false);
                    if (c != null) update(config.copyWith(background: bg.copyWith(color: RColor.fromUi(c))));
                  },
                ),
              ]),
              const SectionLabel('Patrón'),
              Wrap(spacing: 8, runSpacing: 6, children: [
                for (final e in patternLabels.entries)
                  ChoiceChip(
                    label: Text(e.value),
                    selected: bg.pattern == e.key,
                    onSelected: (_) => update(config.copyWith(background: bg.copyWith(pattern: e.key))),
                  ),
              ]),
              LabeledSlider(
                label: 'Tamaño del patrón',
                value: bg.patternSize.dx,
                min: 8,
                max: 128,
                format: (v) => '${v.round()} px',
                onChanged: (v) =>
                    update(config.copyWith(background: bg.copyWith(patternSize: Offset(v, v)))),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Color del patrón'),
                trailing: ColorSwatchButton(color: bg.patternColor.toUi()),
                onTap: () async {
                  final c = await showColorPicker(ctx, bg.patternColor.toUi());
                  if (c != null) {
                    update(config.copyWith(background: bg.copyWith(patternColor: RColor.fromUi(c))));
                  }
                },
              ),
            ],
          ),
        );
      },
    ),
  );
}

/// Dialog to write or edit a text.
Future<(String, TextStyleData)?> showTextDialog(
  BuildContext context, {
  required TextStyleData style,
  String initialText = '',
  bool editing = false,
}) {
  final controller = TextEditingController(text: initialText);
  var current = style;
  return showDialog<(String, TextStyleData)>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(editing ? 'Editar texto' : 'Nuevo texto'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: controller,
              autofocus: true,
              minLines: 2,
              maxLines: 8,
              style: TextStyle(fontSize: 18, color: current.color.toUi().withValues(alpha: 1)),
              decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'Escribe aquí…'),
            ),
            LabeledSlider(
              label: 'Tamaño',
              value: current.fontSize,
              min: 8,
              max: 160,
              format: (v) => v.round().toString(),
              onChanged: (v) => setState(() => current = current.copyWith(fontSize: v)),
            ),
            Row(children: [
              const Text('Fuente'),
              const SizedBox(width: 12),
              Expanded(
                child: SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'sans-serif', label: Text('Sans')),
                    ButtonSegment(value: 'serif', label: Text('Serif')),
                    ButtonSegment(value: 'monospace', label: Text('Mono')),
                  ],
                  selected: {
                    const ['sans-serif', 'serif', 'monospace'].contains(current.fontFamily)
                        ? current.fontFamily
                        : 'sans-serif'
                  },
                  onSelectionChanged: (v) => setState(() => current = current.copyWith(fontFamily: v.first)),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              FilterChip(
                label: const Text('Negrita'),
                selected: current.fontWeight >= 600,
                onSelected: (v) => setState(() => current = current.copyWith(fontWeight: v ? 700 : 500)),
              ),
              const SizedBox(width: 8),
              FilterChip(
                label: const Text('Cursiva'),
                selected: current.fontStyle == 'italic',
                onSelected: (v) =>
                    setState(() => current = current.copyWith(fontStyle: v ? 'italic' : 'regular')),
              ),
            ]),
          ]),
        ),
        actions: [
          if (editing)
            TextButton(
              onPressed: () => Navigator.pop(ctx, ('', current)),
              child: const Text('Eliminar'),
            ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, (controller.text, current)),
            child: const Text('Aceptar'),
          ),
        ],
      ),
    ),
  );
}
