import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:path_provider/path_provider.dart';

import '../editor/dialogs.dart' show pageFormats;
import '../rnote/model.dart';
import '../rnote/rnote_file.dart';
import '../settings/app_settings.dart';

/// Manages the folder holding the user's `.rnote` documents.
///
/// On iOS the folder lives in the app's Documents directory, which is visible
/// in the Files app ("En mi iPad › Rnote Mobile › Rnote").
class LibraryService {
  LibraryService._(this.root, this.support);

  /// A library in the given folders, e.g. for tests.
  LibraryService.at(this.root, this.support);

  final Directory root;
  final Directory support;

  Directory get thumbs => Directory('${support.path}/thumbs');
  Directory get trash => Directory('${support.path}/trash');

  static Future<LibraryService> init() async {
    final docs = await getApplicationDocumentsDirectory();
    final support = await getApplicationSupportDirectory();
    final root = Directory('${docs.path}/Rnote');
    await root.create(recursive: true);
    final lib = LibraryService._(root, support);
    await lib.importInbox();
    return lib;
  }

  static String nameOf(File f) {
    final n = f.uri.pathSegments.last;
    return n.endsWith('.rnote') ? n.substring(0, n.length - 6) : n;
  }

  Future<List<File>> list() async {
    await importInbox();
    final files = <File>[];
    await for (final e in root.list()) {
      if (e is File && e.path.toLowerCase().endsWith('.rnote')) files.add(e);
    }
    final stats = {for (final f in files) f.path: await f.stat()};
    files.sort((a, b) => stats[b.path]!.modified.compareTo(stats[a.path]!.modified));
    return files;
  }

  File thumbnailFor(File f) => File('${thumbs.path}/${nameOf(f)}.png');

  /// A file in the library that does not exist yet.
  Future<File> uniqueFile(String baseName) async {
    final clean = baseName.trim().replaceAll(RegExp(r'[/\\:*?"<>|]'), '_');
    final base = clean.isEmpty ? 'Sin título' : clean;
    var f = File('${root.path}/$base.rnote');
    var i = 2;
    while (await f.exists()) {
      f = File('${root.path}/$base ($i).rnote');
      i++;
    }
    return f;
  }

  RnoteDocument newDocument(AppSettings s) {
    final key = pageFormats.containsKey(s.newDocFormat) ? s.newDocFormat : 'a4';
    final (_, w, h) = pageFormats[key]!;
    final landscape = s.newDocOrientation == 'landscape';
    final bg = s.newDocBackground;
    final dark = bg.computeLuminance() < 0.3;
    final doc = RnoteDocument(
      config: DocConfig(
        layout: s.newDocLayout,
        format: DocFormat(
          width: landscape ? h : w,
          height: landscape ? w : h,
          orientation: landscape ? 'landscape' : 'portrait',
        ),
        background: Background(
          color: RColor.fromUi(bg),
          pattern: s.newDocPattern,
          patternColor: dark ? const RColor(0.35, 0.37, 0.4, 1) : const RColor(0.8, 0.9, 1.0, 1.0),
        ),
      ),
    );
    doc.camera.zoom = 1;
    doc.camera.offset = const Offset(-40, -40);
    return doc;
  }

  Future<File> create(String name, AppSettings s) async {
    final f = await uniqueFile(name);
    await f.writeAsBytes(RnoteFile.save(newDocument(s), legacy: s.legacyFormat));
    return f;
  }

  /// Imports a file, after checking that it can be read.
  Future<File> importBytes(String fileName, Uint8List bytes) async {
    RnoteFile.load(bytes);
    final base = fileName.toLowerCase().endsWith('.rnote')
        ? fileName.substring(0, fileName.length - 6)
        : fileName;
    final f = await uniqueFile(base);
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }

  Future<File> duplicate(File f) async {
    final target = await uniqueFile('${nameOf(f)} (copia)');
    return f.copy(target.path);
  }

  Future<File> rename(File f, String newName) async {
    final clean = newName.trim().replaceAll(RegExp(r'[/\\:*?"<>|]'), '_');
    final target = File('${root.path}/$clean.rnote');
    if (await target.exists()) throw const FileSystemException('Ya existe un documento con ese nombre');
    final thumb = thumbnailFor(f);
    final renamed = await f.rename(target.path);
    if (await thumb.exists()) await thumb.rename(thumbnailFor(renamed).path);
    return renamed;
  }

  /// Moves a document to the trash (kept for 30 days).
  Future<void> delete(File f) async {
    await trash.create(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    await f.rename('${trash.path}/$stamp-${f.uri.pathSegments.last}');
    final thumb = thumbnailFor(f);
    if (await thumb.exists()) await thumb.delete();
    await _purgeTrash();
  }

  Future<void> _purgeTrash() async {
    final limit = DateTime.now().subtract(const Duration(days: 30));
    await for (final e in trash.list()) {
      if (e is File && (await e.stat()).modified.isBefore(limit)) await e.delete();
    }
  }

  /// iOS copies documents opened with "Open in Rnote Mobile" to
  /// Documents/Inbox. Move them into the library.
  Future<void> importInbox() async {
    final inbox = Directory('${root.parent.path}/Inbox');
    if (!await inbox.exists()) return;
    await for (final e in inbox.list()) {
      if (e is! File || !e.path.toLowerCase().endsWith('.rnote')) continue;
      try {
        final target = await uniqueFile(nameOf(e));
        await e.copy(target.path);
        await e.delete();
      } catch (_) {}
    }
  }
}
