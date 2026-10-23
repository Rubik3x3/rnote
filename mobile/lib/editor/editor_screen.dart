import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../library/library_service.dart';
import '../rnote/model.dart';
import '../rnote/rnote_file.dart';
import '../settings/app_settings.dart';
import '../ui/color_picker.dart';
import '../ui/common_widgets.dart';
import '../ui/settings_screen.dart';
import 'canvas_view.dart';
import 'chrome_controller.dart';
import 'dialogs.dart';
import 'editor_controller.dart';
import 'import_export.dart';
import 'tool_options.dart';

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.file, required this.settings, required this.library});

  final File file;
  final AppSettings settings;
  final LibraryService library;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> with WidgetsBindingObserver {
  EditorController? controller;
  late final ChromeController chrome = ChromeController(widget.settings);
  String? error;

  AppSettings get settings => widget.settings;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await widget.file.readAsBytes();
      final doc = RnoteFile.load(bytes);
      final c = EditorController(settings: settings, doc: doc, file: widget.file);
      c.onTextRequest = _onTextRequest;
      setState(() => controller = c);
      chrome.poke();
    } catch (e) {
      setState(() => error = e.toString());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      final c = controller;
      if (c != null && c.dirty) c.save();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller?.dispose();
    chrome.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    final c = controller;
    if (c != null) {
      if (c.dirty) await c.save();
      await writeThumbnail(c, widget.library.thumbnailFor(c.file));
    }
    if (mounted) Navigator.of(context).pop(c?.file);
  }

  Future<void> _onTextRequest(Offset pos, TextStroke? existing) async {
    final c = controller!;
    final base = existing?.style ??
        TextStyleData(fontSize: settings.textSize, color: RColor.fromUi(settings.textColor));
    final result = await showTextDialog(context,
        style: base, initialText: existing?.text ?? '', editing: existing != null);
    if (result == null) return;
    final (text, style) = result;
    c.commitText(pos, existing, text, style);
  }

  Future<void> _rename() async {
    final c = controller!;
    final ctrl = TextEditingController(text: c.title);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Renombrar'),
        content: TextField(controller: ctrl, autofocus: true, onSubmitted: (v) => Navigator.pop(ctx, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Aceptar')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty || name == c.title) return;
    try {
      final oldThumb = widget.library.thumbnailFor(c.file);
      await c.rename(name);
      if (await oldThumb.exists()) await oldThumb.rename(widget.library.thumbnailFor(c.file).path);
    } catch (e) {
      _toast('No se pudo renombrar: $e');
    }
  }

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (c == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: error == null
              ? const CircularProgressIndicator()
              : Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('No se pudo abrir el documento:\n$error', textAlign: TextAlign.center),
                ),
        ),
      );
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyZ, control: true): c.undo,
          const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): c.undo,
          const SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true): c.redo,
          const SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true): c.redo,
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): c.save,
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true): c.save,
          const SingleActivator(LogicalKeyboardKey.delete): c.deleteSelection,
          const SingleActivator(LogicalKeyboardKey.backspace): c.deleteSelection,
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            resizeToAvoidBottomInset: false,
            body: ListenableBuilder(
              listenable: Listenable.merge([c, chrome, settings]),
              builder: (context, _) => _buildBody(context, c),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, EditorController c) {
    final visible = chrome.visible;
    final right = settings.toolbarOnRight;
    final scale = settings.buttonScale;
    final railCollapsed = settings.railCollapsed;
    return Stack(children: [
      Positioned.fill(child: CanvasView(controller: c, chrome: chrome)),

      // --- top bar ---
      SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: IgnorePointer(
            ignoring: !visible,
            child: AnimatedSlide(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              offset: visible ? Offset.zero : const Offset(0, -1.6),
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: visible ? 1 : 0,
                child: _TopBar(
                  controller: c,
                  chrome: chrome,
                  scale: scale,
                  onBack: _close,
                  onRename: _rename,
                  onMenu: (action) => _onMenu(context, c, action),
                ),
              ),
            ),
          ),
        ),
      ),

      // --- handle to bring back the menus ---
      if (!visible)
        SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: _RevealHandle(onTap: chrome.poke),
          ),
        ),

      // --- tool rail ---
      SafeArea(
        child: Align(
          alignment: right ? Alignment.centerRight : Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 64),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: SlideTransition(
                  position: Tween(begin: Offset(right ? 0.4 : -0.4, 0), end: Offset.zero).animate(anim),
                  child: child,
                ),
              ),
              child: visible && !railCollapsed
                  ? _ToolRail(
                      key: const ValueKey('rail'),
                      controller: c,
                      chrome: chrome,
                      scale: scale,
                    )
                  : _MiniToolBubble(
                      key: const ValueKey('bubble'),
                      controller: c,
                      scale: scale,
                      onTap: () {
                        if (settings.railCollapsed) settings.railCollapsed = false;
                        chrome.poke();
                      },
                    ),
            ),
          ),
        ),
      ),

      // --- tool options popup ---
      if (visible && chrome.openPopup != null && !railCollapsed)
        SafeArea(
          child: Align(
            alignment: right ? Alignment.centerRight : Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.only(
                  left: right ? 0 : 76 * scale, right: right ? 76 * scale : 0, top: 64, bottom: 24),
              child: _Popup(
                onInteract: chrome.poke,
                child: ToolOptionsPanel(
                  controller: c,
                  tool: Tool.values.firstWhere((t) => t.name == chrome.openPopup, orElse: () => c.tool),
                ),
              ),
            ),
          ),
        ),

      // --- selection actions ---
      if (c.hasSelection && c.active == null)
        SafeArea(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _SelectionBar(controller: c),
            ),
          ),
        ),

      // --- zoom chip ---
      if (settings.showZoomChip)
        SafeArea(
          child: Align(
            alignment: right ? Alignment.bottomLeft : Alignment.bottomRight,
            child: IgnorePointer(
              ignoring: !visible,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: visible ? 1 : 0,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: _ZoomChip(controller: c),
                ),
              ),
            ),
          ),
        ),
    ]);
  }

  Future<void> _onMenu(BuildContext context, EditorController c, String action) async {
    chrome.poke();
    switch (action) {
      case 'doc':
        await showDocumentSettings(context, c);
      case 'image':
        await insertImage(context, c, gallery: true);
      case 'image_file':
        await insertImage(context, c);
      case 'share_rnote':
        await shareRnoteFile(context, c);
      case 'share_png':
        await sharePng(context, c);
      case 'save':
        await c.save();
        _toast('Guardado');
      case 'fit_width':
        c.fitWidth();
      case 'fit_all':
        c.fitContent();
      case 'zoom_100':
        c.resetZoom();
      case 'select_all':
        c.selectAll();
      case 'pin':
        chrome.togglePinned();
      case 'settings':
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => SettingsScreen(settings: settings, library: widget.library)));
    }
  }
}

// ---------------------------------------------------------------------------
// Top bar
// ---------------------------------------------------------------------------

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.controller,
    required this.chrome,
    required this.scale,
    required this.onBack,
    required this.onRename,
    required this.onMenu,
  });

  final EditorController controller;
  final ChromeController chrome;
  final double scale;
  final VoidCallback onBack;
  final VoidCallback onRename;
  final ValueChanged<String> onMenu;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final scheme = Theme.of(context).colorScheme;
    final iconSize = 22 * scale;
    Widget btn(IconData icon, String tip, VoidCallback? onPressed) => IconButton(
          iconSize: iconSize,
          tooltip: tip,
          visualDensity: VisualDensity.compact,
          icon: Icon(icon),
          onPressed: onPressed == null
              ? null
              : () {
                  chrome.poke();
                  onPressed();
                },
        );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
        child: Material(
          elevation: 3,
          color: scheme.surfaceContainerHigh.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(children: [
              btn(Icons.arrow_back, 'Volver a la biblioteca', onBack),
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: onRename,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                    child: Row(children: [
                      Flexible(
                        child: Text(
                          c.title,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      if (c.dirty)
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Icon(Icons.circle, size: 8, color: scheme.primary),
                        ),
                    ]),
                  ),
                ),
              ),
              btn(Icons.undo, 'Deshacer', c.canUndo ? c.undo : null),
              btn(Icons.redo, 'Rehacer', c.canRedo ? c.redo : null),
              btn(Icons.tune, 'Documento y fondo', () => onMenu('doc')),
              PopupMenuButton<String>(
                tooltip: 'Insertar',
                icon: Icon(Icons.add_photo_alternate_outlined, size: iconSize),
                onOpened: chrome.poke,
                onSelected: onMenu,
                itemBuilder: (_) => const [
                  PopupMenuItem(
                      value: 'image',
                      child: ListTile(leading: Icon(Icons.photo_library_outlined), title: Text('Imagen de la galería'))),
                  PopupMenuItem(
                      value: 'image_file',
                      child: ListTile(leading: Icon(Icons.file_open_outlined), title: Text('Archivo de imagen o SVG'))),
                ],
              ),
              PopupMenuButton<String>(
                tooltip: 'Compartir / exportar',
                icon: Icon(Icons.ios_share, size: iconSize),
                onOpened: chrome.poke,
                onSelected: onMenu,
                itemBuilder: (_) => const [
                  PopupMenuItem(
                      value: 'share_rnote',
                      child: ListTile(leading: Icon(Icons.description_outlined), title: Text('Archivo .rnote'))),
                  PopupMenuItem(
                      value: 'share_png',
                      child: ListTile(leading: Icon(Icons.image_outlined), title: Text('Imagen PNG'))),
                ],
              ),
              PopupMenuButton<String>(
                tooltip: 'Más',
                icon: Icon(Icons.more_vert, size: iconSize),
                onOpened: chrome.poke,
                onSelected: onMenu,
                itemBuilder: (_) => [
                  const PopupMenuItem(
                      value: 'save', child: ListTile(leading: Icon(Icons.save_outlined), title: Text('Guardar ahora'))),
                  const PopupMenuItem(
                      value: 'fit_width', child: ListTile(leading: Icon(Icons.fit_screen), title: Text('Ajustar al ancho'))),
                  const PopupMenuItem(
                      value: 'fit_all', child: ListTile(leading: Icon(Icons.zoom_out_map), title: Text('Ver todo'))),
                  const PopupMenuItem(
                      value: 'zoom_100', child: ListTile(leading: Icon(Icons.youtube_searched_for), title: Text('Zoom 100 %'))),
                  const PopupMenuItem(
                      value: 'select_all', child: ListTile(leading: Icon(Icons.select_all), title: Text('Seleccionar todo'))),
                  PopupMenuItem(
                    value: 'pin',
                    child: ListTile(
                      leading: Icon(chrome.pinned ? Icons.push_pin : Icons.push_pin_outlined),
                      title: Text(chrome.pinned ? 'Permitir ocultar menús' : 'Fijar menús visibles'),
                    ),
                  ),
                  const PopupMenuItem(
                      value: 'settings', child: ListTile(leading: Icon(Icons.settings_outlined), title: Text('Ajustes'))),
                ],
              ),
              btn(Icons.expand_less, 'Ocultar menús', chrome.hide),
            ]),
          ),
        ),
      ),
    );
  }
}

class _RevealHandle extends StatelessWidget {
  const _RevealHandle({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onVerticalDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) > 0) onTap();
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 6, 32, 14),
        child: Container(
          width: 56,
          height: 6,
          decoration: BoxDecoration(
            color: scheme.onSurface.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tool rail
// ---------------------------------------------------------------------------

Widget toolIcon(Tool t, {double size = 24, Color? color}) => switch (t) {
      Tool.pen => Icon(Icons.edit, size: size, color: color),
      Tool.highlighter => Icon(Icons.border_color, size: size, color: color),
      Tool.eraser => EraserIcon(size: size, color: color),
      Tool.select => Icon(Icons.highlight_alt, size: size, color: color),
      Tool.shape => Icon(Icons.interests_outlined, size: size, color: color),
      Tool.text => Icon(Icons.text_fields, size: size, color: color),
      Tool.pan => Icon(Icons.pan_tool_outlined, size: size, color: color),
    };

class _ToolRail extends StatelessWidget {
  const _ToolRail({super.key, required this.controller, required this.chrome, required this.scale});

  final EditorController controller;
  final ChromeController chrome;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final s = c.settings;
    final scheme = Theme.of(context).colorScheme;
    final current = c.tool;
    final color = c.colorOf(current);
    final size = 44 * scale;

    Widget toolButton(Tool t) {
      final selected = t == current;
      return Tooltip(
        message: t.label,
        waitDuration: const Duration(milliseconds: 600),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () {
            if (selected) {
              chrome.openPopupToggle(t.name);
            } else {
              c.tool = t;
              chrome.dismissPopups();
              chrome.poke();
            }
          },
          onLongPress: () {
            c.tool = t;
            chrome.openPopupToggle(t.name);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: size,
            height: size,
            margin: const EdgeInsets.symmetric(vertical: 2),
            decoration: BoxDecoration(
              color: selected ? scheme.primaryContainer : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Stack(alignment: Alignment.center, children: [
              toolIcon(t, size: 22 * scale, color: selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant),
              if (selected)
                Positioned(
                  right: 4,
                  bottom: 4,
                  child: Icon(Icons.arrow_drop_down, size: 12 * scale, color: scheme.onPrimaryContainer),
                ),
            ]),
          ),
        ),
      );
    }

    final showsColor = const {Tool.pen, Tool.highlighter, Tool.shape, Tool.text}.contains(current);
    return Material(
      elevation: 3,
      color: scheme.surfaceContainerHigh.withValues(alpha: 0.96),
      borderRadius: BorderRadius.circular(22),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: size + 12),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () {
                s.railCollapsed = true;
                chrome.dismissPopups();
              },
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(s.toolbarOnRight ? Icons.chevron_right : Icons.chevron_left,
                    size: 20 * scale, color: scheme.outline),
              ),
            ),
            for (final t in Tool.values) toolButton(t),
            if (showsColor) ...[
              Divider(height: 14, indent: 6, endIndent: 6, color: scheme.outlineVariant),
              ColorSwatchButton(
                color: color,
                size: 30 * scale,
                selected: true,
                onTap: () => chrome.openPopupToggle(current.name),
                onLongPress: () async {
                  final picked = await showColorPicker(context, color);
                  if (picked != null) c.setColorFor(current, picked);
                },
              ),
              if (s.showQuickColors)
                for (final pc in s.palette.take(6))
                  ColorSwatchButton(
                    color: current == Tool.highlighter ? pc.withValues(alpha: color.a) : pc,
                    size: 22 * scale,
                    onTap: () {
                      chrome.poke();
                      c.setColorFor(current, current == Tool.highlighter ? pc.withValues(alpha: color.a) : pc);
                    },
                  ),
            ],
          ]),
        ),
      ),
    );
  }
}

/// Small button left when the rail is hidden or collapsed: shows the current
/// tool and color and brings the rail back.
class _MiniToolBubble extends StatelessWidget {
  const _MiniToolBubble({super.key, required this.controller, required this.scale, required this.onTap});

  final EditorController controller;
  final double scale;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tool = controller.tool;
    return Opacity(
      opacity: 0.75,
      child: Material(
        elevation: 2,
        shape: const CircleBorder(),
        color: scheme.surfaceContainerHigh,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox.square(
            dimension: 40 * scale,
            child: Stack(alignment: Alignment.center, children: [
              toolIcon(tool, size: 20 * scale, color: scheme.onSurfaceVariant),
              Positioned(
                right: 5 * scale,
                bottom: 5 * scale,
                child: Container(
                  width: 9 * scale,
                  height: 9 * scale,
                  decoration: BoxDecoration(
                    color: controller.colorOf(tool),
                    shape: BoxShape.circle,
                    border: Border.all(color: scheme.surface, width: 1.5),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Popup extends StatelessWidget {
  const _Popup({required this.child, required this.onInteract});
  final Widget child;
  final VoidCallback onInteract;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Listener(
      onPointerDown: (_) => onInteract(),
      child: Material(
        elevation: 6,
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(14),
            child: child,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Selection bar and zoom chip
// ---------------------------------------------------------------------------

class _SelectionBar extends StatelessWidget {
  const _SelectionBar({required this.controller});
  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 4,
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text('${c.selection.length}', style: Theme.of(context).textTheme.labelLarge),
          ),
          IconButton(tooltip: 'Eliminar', icon: const Icon(Icons.delete_outline), onPressed: c.deleteSelection),
          IconButton(tooltip: 'Duplicar', icon: const Icon(Icons.content_copy), onPressed: c.duplicateSelection),
          IconButton(
            tooltip: 'Cambiar color',
            icon: const Icon(Icons.format_color_fill),
            onPressed: () async {
              final picked = await showColorPicker(context, c.settings.penColor);
              if (picked != null) c.recolorSelection(picked);
            },
          ),
          IconButton(tooltip: 'Traer al frente', icon: const Icon(Icons.flip_to_front), onPressed: c.bringSelectionToFront),
          IconButton(tooltip: 'Deseleccionar', icon: const Icon(Icons.close), onPressed: c.clearSelection),
        ]),
      ),
    );
  }
}

class _ZoomChip extends StatelessWidget {
  const _ZoomChip({required this.controller});
  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return PopupMenuButton<String>(
      tooltip: 'Zoom',
      onSelected: (v) => switch (v) {
        '100' => c.resetZoom(),
        'width' => c.fitWidth(),
        _ => c.fitContent(),
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: '100', child: Text('100 %')),
        PopupMenuItem(value: 'width', child: Text('Ajustar al ancho')),
        PopupMenuItem(value: 'all', child: Text('Ver todo')),
      ],
      child: Chip(
        visualDensity: VisualDensity.compact,
        avatar: const Icon(Icons.zoom_in, size: 18),
        label: Text('${(c.camera.zoom * 100).round()} %'),
      ),
    );
  }
}
