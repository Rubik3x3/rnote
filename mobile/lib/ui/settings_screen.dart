import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../editor/dialogs.dart';
import '../library/library_service.dart';
import '../rnote/model.dart';
import '../settings/app_settings.dart';
import '../sync/sync_controller.dart';
import 'color_picker.dart';
import 'common_widgets.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.settings, required this.library});

  final AppSettings settings;
  final LibraryService library;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ajustes')),
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) {
          final s = settings;
          return ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              _header(context, 'Apariencia'),
              ListTile(
                title: const Text('Tema'),
                trailing: SegmentedButton<ThemeMode>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto)),
                    ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode)),
                    ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode)),
                  ],
                  selected: {s.themeMode},
                  onSelectionChanged: (v) => s.themeMode = v.first,
                ),
              ),
              ListTile(
                title: const Text('Barra de herramientas'),
                subtitle: const Text('Lado de la pantalla (útil para zurdos)'),
                trailing: SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: false, label: Text('Izq.')),
                    ButtonSegment(value: true, label: Text('Der.')),
                  ],
                  selected: {s.toolbarOnRight},
                  onSelectionChanged: (v) => s.toolbarOnRight = v.first,
                ),
              ),
              _sliderTile(
                context,
                title: 'Tamaño de los botones',
                value: s.buttonScale,
                min: 0.8,
                max: 1.4,
                divisions: 6,
                format: (v) => '${(v * 100).round()} %',
                onChanged: (v) => s.buttonScale = v,
              ),

              _header(context, 'Menús autoocultables'),
              SwitchListTile(
                title: const Text('Ocultar menús al dibujar'),
                subtitle: const Text('Libera toda la pantalla mientras escribes'),
                value: s.hideWhileDrawing,
                onChanged: (v) => s.hideWhileDrawing = v,
              ),
              _sliderTile(
                context,
                title: 'Ocultar tras inactividad',
                value: s.autoHideSeconds.toDouble(),
                min: 0,
                max: 30,
                divisions: 30,
                format: (v) => v == 0 ? 'Nunca' : '${v.round()} s',
                onChanged: (v) => s.autoHideSeconds = v.round(),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Con los menús ocultos, toca la pestaña superior, el botón de herramienta o el lienzo '
                  'con un dedo (en modo navegación) para mostrarlos de nuevo.',
                ),
              ),
              SwitchListTile(
                title: const Text('Colores rápidos en la barra'),
                value: s.showQuickColors,
                onChanged: (v) => s.showQuickColors = v,
              ),
              SwitchListTile(
                title: const Text('Indicador de zoom'),
                value: s.showZoomChip,
                onChanged: (v) => s.showZoomChip = v,
              ),

              _header(context, 'Lápiz y tableta'),
              ListTile(
                title: const Text('Uso del dedo'),
                subtitle: Text(s.fingerMode.description),
                trailing: DropdownButton<FingerMode>(
                  value: s.fingerMode,
                  items: [
                    for (final m in FingerMode.values) DropdownMenuItem(value: m, child: Text(m.label)),
                  ],
                  onChanged: (v) => s.fingerMode = v ?? FingerMode.auto,
                ),
              ),
              _sliderTile(
                context,
                title: 'Sensibilidad a la presión',
                subtitle: 'Valores bajos: trazo grueso con poca presión',
                value: s.pressureGamma,
                min: 0.3,
                max: 2.5,
                divisions: 22,
                format: (v) => v.toStringAsFixed(1),
                onChanged: (v) => s.pressureGamma = v,
              ),
              _PressurePreview(gamma: s.pressureGamma),
              _sliderTile(
                context,
                title: 'Suavizado del trazo',
                value: s.smoothing,
                min: 0,
                max: 0.8,
                divisions: 16,
                format: (v) => v == 0 ? 'Desactivado' : '${(v * 100).round()} %',
                onChanged: (v) => s.smoothing = v,
              ),
              SwitchListTile(
                title: const Text('Usar presión del dedo'),
                subtitle: const Text('Sólo en pantallas que la reportan'),
                value: s.touchPressure,
                onChanged: (v) => s.touchPressure = v,
              ),
              _actionTile('Botón lateral 1 del lápiz', s.stylusButton1, (a) => s.stylusButton1 = a),
              _actionTile('Botón lateral 2 del lápiz', s.stylusButton2, (a) => s.stylusButton2 = a),
              _actionTile('Extremo borrador del lápiz', s.eraserEnd, (a) => s.eraserEnd = a),
              SwitchListTile(
                title: const Text('Tocar con dos dedos: deshacer'),
                value: s.twoFingerTapUndo,
                onChanged: (v) => s.twoFingerTapUndo = v,
              ),
              SwitchListTile(
                title: const Text('Tocar con tres dedos: rehacer'),
                value: s.threeFingerTapRedo,
                onChanged: (v) => s.threeFingerTapRedo = v,
              ),

              _header(context, 'Documentos nuevos'),
              ListTile(
                title: const Text('Diseño'),
                trailing: DropdownButton<String>(
                  value: s.newDocLayout,
                  items: [
                    for (final e in layoutLabels.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value.$1)),
                  ],
                  onChanged: (v) => s.newDocLayout = v ?? Layout.infinite,
                ),
              ),
              ListTile(
                title: const Text('Formato de página'),
                trailing: DropdownButton<String>(
                  value: s.newDocFormat,
                  items: [
                    for (final e in pageFormats.entries) DropdownMenuItem(value: e.key, child: Text(e.value.$1)),
                  ],
                  onChanged: (v) => s.newDocFormat = v ?? 'a4',
                ),
              ),
              ListTile(
                title: const Text('Orientación'),
                trailing: SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'portrait', icon: Icon(Icons.crop_portrait)),
                    ButtonSegment(value: 'landscape', icon: Icon(Icons.crop_landscape)),
                  ],
                  selected: {s.newDocOrientation},
                  onSelectionChanged: (v) => s.newDocOrientation = v.first,
                ),
              ),
              ListTile(
                title: const Text('Patrón de fondo'),
                trailing: DropdownButton<String>(
                  value: s.newDocPattern,
                  items: [
                    for (final e in patternLabels.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: (v) => s.newDocPattern = v ?? PatternStyle.dots,
                ),
              ),
              ListTile(
                title: const Text('Color de fondo'),
                trailing: ColorSwatchButton(color: s.newDocBackground),
                onTap: () async {
                  final c = await showColorPicker(context, s.newDocBackground, alpha: false);
                  if (c != null) s.newDocBackground = c;
                },
              ),

              _header(context, 'Guardado'),
              _sliderTile(
                context,
                title: 'Autoguardado',
                value: s.autosaveSeconds.toDouble(),
                min: 0,
                max: 120,
                divisions: 24,
                format: (v) => v == 0 ? 'Al salir' : '${v.round()} s',
                onChanged: (v) => s.autosaveSeconds = v.round(),
              ),
              SwitchListTile(
                title: const Text('Compatibilidad con Rnote 0.13 / 0.14'),
                subtitle: const Text(
                    'Guarda en el formato anterior para abrir los archivos con versiones estables antiguas. '
                    'Desactivado: formato de Rnote 0.15.'),
                value: s.legacyFormat,
                onChanged: (v) => s.legacyFormat = v,
              ),
              ListTile(
                title: const Text('Carpeta de documentos'),
                subtitle: Text(library.root.path),
              ),

              _header(context, 'Sincronización con el PC'),
              _SyncSettings(settings: s),

              const SizedBox(height: 16),
              Center(
                child: TextButton.icon(
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Restablecer ajustes'),
                  onPressed: s.resetToDefaults,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _header(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
        child: Text(text,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );

  Widget _sliderTile(
    BuildContext context, {
    required String title,
    String? subtitle,
    required double value,
    required double min,
    required double max,
    int? divisions,
    required String Function(double) format,
    required ValueChanged<double> onChanged,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          LabeledSlider(
            label: title,
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            format: format,
            onChanged: onChanged,
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            ),
        ]),
      );

  Widget _actionTile(String title, StylusAction value, ValueChanged<StylusAction> onChanged) => ListTile(
        title: Text(title),
        trailing: DropdownButton<StylusAction>(
          value: value,
          items: [for (final a in StylusAction.values) DropdownMenuItem(value: a, child: Text(a.label))],
          onChanged: (v) => onChanged(v ?? StylusAction.none),
        ),
      );
}

/// Shows how the pressure sensitivity maps stylus pressure to width.
class _PressurePreview extends StatelessWidget {
  const _PressurePreview({required this.gamma});
  final double gamma;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        child: SizedBox(
          height: 36,
          child: CustomPaint(
            painter: _PressurePainter(gamma, Theme.of(context).colorScheme.onSurface),
            size: Size.infinite,
          ),
        ),
      );
}

class _PressurePainter extends CustomPainter {
  _PressurePainter(this.gamma, this.color);
  final double gamma;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    const n = 60;
    final top = <Offset>[], bottom = <Offset>[];
    for (var i = 0; i <= n; i++) {
      final t = i / n;
      final w = (size.height / 2) * (0.04 + 0.96 * math.pow(t, gamma));
      final x = t * size.width;
      top.add(Offset(x, size.height / 2 - w));
      bottom.add(Offset(x, size.height / 2 + w));
    }
    path.addPolygon([...top, ...bottom.reversed], true);
    canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.7));
  }

  @override
  bool shouldRepaint(_PressurePainter old) => old.gamma != gamma || old.color != color;
}

class _SyncSettings extends StatefulWidget {
  const _SyncSettings({required this.settings});
  final AppSettings settings;

  @override
  State<_SyncSettings> createState() => _SyncSettingsState();
}

class _SyncSettingsState extends State<_SyncSettings> {
  late final url = TextEditingController(text: widget.settings.syncUrl);
  late final user = TextEditingController(text: widget.settings.syncUser);
  late final password = TextEditingController(text: widget.settings.syncPassword);
  bool testing = false;
  bool obscure = true;

  void _store() {
    widget.settings.syncUrl = url.text;
    widget.settings.syncUser = user.text;
    if (password.text != widget.settings.syncPassword) widget.settings.syncPassword = password.text;
  }

  Future<void> _test() async {
    _store();
    setState(() => testing = true);
    String msg;
    try {
      msg = await SyncController.test(url.text.trim(), user.text.trim(), password.text);
    } catch (e) {
      msg = 'Error: $e';
    }
    if (!mounted) return;
    setState(() => testing = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    _store();
    url.dispose();
    user.dispose();
    password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(
          'Sincroniza la biblioteca con una carpeta WebDAV: Nextcloud, ownCloud, un NAS o la carpeta de '
          'Rnote de tu PC usando el script incluido "rnote_sync_server.py" (ver README).',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: url,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'URL de la carpeta WebDAV',
            hintText: 'http://192.168.1.10:8080/  o  https://nube/remote.php/dav/files/usuario/Rnote',
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => _store(),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: TextField(
              controller: user,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Usuario', border: OutlineInputBorder()),
              onChanged: (_) => _store(),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: password,
              obscureText: obscure,
              decoration: InputDecoration(
                labelText: 'Contraseña',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => obscure = !obscure),
                ),
              ),
              onChanged: (_) => _store(),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            icon: testing
                ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.wifi_tethering),
            label: const Text('Probar conexión'),
            onPressed: testing || url.text.trim().isEmpty ? null : _test,
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Sincronizar al abrir la app'),
          value: s.syncOnStart,
          onChanged: (v) => s.syncOnStart = v,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Sincronizar al cerrar un documento'),
          value: s.syncOnClose,
          onChanged: (v) => s.syncOnClose = v,
        ),
        if (s.lastSync != null)
          Text('Última sincronización: ${s.lastSync!.toLocal().toString().substring(0, 16)}',
              style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }
}
