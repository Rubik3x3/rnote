import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../editor/editor_screen.dart';
import '../library/library_service.dart';
import '../settings/app_settings.dart';
import '../sync/sync_controller.dart';
import 'settings_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.settings, required this.library});

  final AppSettings settings;
  final LibraryService library;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> with WidgetsBindingObserver {
  late final SyncController sync = SyncController(widget.settings, widget.library);
  List<File> files = [];
  final Map<String, DateTime> modified = {};
  bool loading = true;

  LibraryService get library => widget.library;
  AppSettings get settings => widget.settings;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reload().then((_) {
      if (settings.syncOnStart && settings.syncConfigured) _sync();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    sync.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // documents may have been opened from other apps meanwhile
    if (state == AppLifecycleState.resumed) _reload();
  }

  Future<void> _reload() async {
    final list = await library.list();
    for (final f in list) {
      modified[f.path] = (await f.stat()).modified;
    }
    if (!mounted) return;
    setState(() {
      files = list;
      loading = false;
    });
  }

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _sync() async {
    if (!settings.syncConfigured) {
      _toast('Configura la sincronización en Ajustes');
      await _openSettings();
      return;
    }
    final report = await sync.sync();
    await _reload();
    if (!mounted) return;
    if (report != null) {
      _toast(report.errors.isEmpty ? report.toString() : '$report\n${report.errors.first}');
    } else if (sync.lastError != null) {
      _toast('Error de sincronización: ${sync.lastError}');
    }
  }

  Future<void> _open(File f) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => EditorScreen(file: f, settings: settings, library: library),
    ));
    await _reload();
    if (settings.syncOnClose && settings.syncConfigured) _sync();
  }

  Future<void> _create() async {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final ctrl = TextEditingController(
        text: 'Nota ${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}.${two(now.minute)}');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nuevo documento'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Nombre'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Crear')),
        ],
      ),
    );
    if (name == null) return;
    final f = await library.create(name, settings);
    await _reload();
    if (mounted) await _open(f);
  }

  Future<void> _import() async {
    final picked = await FilePicker.pickFiles(type: FileType.any);
    var imported = 0;
    for (final p in picked) {
      if (!p.name.toLowerCase().endsWith('.rnote')) {
        _toast('"${p.name}" no es un archivo .rnote');
        continue;
      }
      try {
        await library.importBytes(p.name, await p.xFile.readAsBytes());
        imported++;
      } catch (e) {
        _toast('No se pudo importar "${p.name}": $e');
      }
    }
    if (imported > 0) _toast('$imported documento(s) importado(s)');
    await _reload();
  }

  Future<void> _openSettings() => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => SettingsScreen(settings: settings, library: library),
      ));

  Future<void> _actions(File f, Rect origin) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(LibraryService.nameOf(f), style: Theme.of(ctx).textTheme.titleMedium)),
          ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Renombrar'),
              onTap: () => Navigator.pop(ctx, 'rename')),
          ListTile(
              leading: const Icon(Icons.content_copy),
              title: const Text('Duplicar'),
              onTap: () => Navigator.pop(ctx, 'duplicate')),
          ListTile(
              leading: const Icon(Icons.ios_share),
              title: const Text('Compartir / exportar'),
              onTap: () => Navigator.pop(ctx, 'share')),
          ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Eliminar'),
              onTap: () => Navigator.pop(ctx, 'delete')),
        ]),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'rename':
        final ctrl = TextEditingController(text: LibraryService.nameOf(f));
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
        if (name != null && name.trim().isNotEmpty) {
          try {
            await library.rename(f, name);
          } catch (e) {
            _toast('$e');
          }
        }
      case 'duplicate':
        await library.duplicate(f);
      case 'share':
        await SharePlus.instance.share(ShareParams(
          files: [XFile(f.path, mimeType: 'application/x-rnote')],
          sharePositionOrigin: origin,
        ));
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('¿Eliminar "${LibraryService.nameOf(f)}"?'),
            content: Text(settings.syncConfigured
                ? 'También se eliminará del servidor en la próxima sincronización.'
                : 'Se moverá a la papelera de la app durante 30 días.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Eliminar')),
            ],
          ),
        );
        if (ok == true) await library.delete(f);
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Rnote'),
        actions: [
          ListenableBuilder(
            listenable: sync,
            builder: (context, _) => IconButton(
              tooltip: settings.syncConfigured ? 'Sincronizar con el PC' : 'Configurar sincronización',
              icon: sync.running
                  ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(settings.syncConfigured ? Icons.sync : Icons.sync_disabled),
              onPressed: sync.running ? null : _sync,
            ),
          ),
          IconButton(tooltip: 'Importar .rnote', icon: const Icon(Icons.file_open_outlined), onPressed: _import),
          IconButton(tooltip: 'Ajustes', icon: const Icon(Icons.settings_outlined), onPressed: _openSettings),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: ListenableBuilder(
            listenable: sync,
            builder: (context, _) =>
                sync.running ? const LinearProgressIndicator(minHeight: 2) : const SizedBox(height: 2),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: const Text('Nuevo'),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: settings.syncConfigured ? _sync : _reload,
              child: files.isEmpty ? _empty(context) : _grid(context),
            ),
    );
  }

  Widget _empty(BuildContext context) => ListView(children: [
        const SizedBox(height: 120),
        Icon(Icons.draw_outlined, size: 72, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 16),
        Center(child: Text('Tu pizarra está vacía', style: Theme.of(context).textTheme.titleLarge)),
        const SizedBox(height: 8),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            'Crea un documento nuevo, importa un archivo .rnote o configura la sincronización con tu PC.',
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 16),
        Wrap(alignment: WrapAlignment.center, spacing: 12, children: [
          FilledButton.icon(onPressed: _create, icon: const Icon(Icons.add), label: const Text('Nuevo')),
          OutlinedButton.icon(
              onPressed: _import, icon: const Icon(Icons.file_open_outlined), label: const Text('Importar')),
        ]),
      ]);

  Widget _grid(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.78,
      ),
      itemCount: files.length,
      itemBuilder: (context, i) {
        final f = files[i];
        final date = modified[f.path];
        final thumb = library.thumbnailFor(f);
        final scheme = Theme.of(context).colorScheme;
        return Builder(builder: (cardContext) {
          Rect origin() {
            final box = cardContext.findRenderObject() as RenderBox;
            return box.localToGlobal(Offset.zero) & box.size;
          }

          return Card(
            clipBehavior: Clip.antiAlias,
            elevation: 1,
            child: InkWell(
              onTap: () => _open(f),
              onLongPress: () => _actions(f, origin()),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(
                  child: Container(
                    color: scheme.surfaceContainerHighest,
                    child: thumb.existsSync()
                        ? Image.file(
                            thumb,
                            key: ValueKey('${thumb.path}${thumb.lastModifiedSync()}'),
                            fit: BoxFit.cover,
                            alignment: Alignment.topCenter,
                            gaplessPlayback: true,
                          )
                        : Icon(Icons.description_outlined, size: 48, color: scheme.outline),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 2, 8),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(LibraryService.nameOf(f),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall),
                        if (date != null)
                          Text(_formatDate(date),
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.outline)),
                      ]),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.more_vert, size: 20),
                      onPressed: () => _actions(f, origin()),
                    ),
                  ]),
                ),
              ]),
            ),
          );
        });
      },
    );
  }

  static String _formatDate(DateTime d) {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    if (d.year == now.year && d.month == now.month && d.day == now.day) {
      return 'Hoy ${two(d.hour)}:${two(d.minute)}';
    }
    return '${two(d.day)}/${two(d.month)}/${d.year}';
  }
}
