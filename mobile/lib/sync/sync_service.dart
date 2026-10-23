import 'dart:convert';
import 'dart:io';

import 'webdav_client.dart';

class SyncReport {
  int uploaded = 0, downloaded = 0, deletedLocal = 0, deletedRemote = 0, conflicts = 0;
  final errors = <String>[];

  bool get changedAnything => uploaded + downloaded + deletedLocal + deletedRemote + conflicts > 0;

  @override
  String toString() {
    final parts = [
      if (uploaded > 0) '$uploaded subidos',
      if (downloaded > 0) '$downloaded descargados',
      if (deletedLocal + deletedRemote > 0) '${deletedLocal + deletedRemote} borrados',
      if (conflicts > 0) '$conflicts conflictos (se guardaron ambas versiones)',
      if (errors.isNotEmpty) '${errors.length} errores',
    ];
    return parts.isEmpty ? 'Todo está sincronizado' : parts.join(', ');
  }
}

class _SyncEntry {
  int localModified;
  int localSize;
  String remoteVersion;

  _SyncEntry(this.localModified, this.localSize, this.remoteVersion);

  factory _SyncEntry.fromJson(Map<String, dynamic> j) =>
      _SyncEntry(j['lm'] as int? ?? 0, j['ls'] as int? ?? 0, j['rv'] as String? ?? '');

  Map<String, dynamic> toJson() => {'lm': localModified, 'ls': localSize, 'rv': remoteVersion};
}

/// Two-way synchronization of a local folder with a WebDAV folder.
///
/// The state of the last synchronization is kept, so that changes on both
/// sides can be detected:
/// * changed on one side → copied to the other,
/// * changed on both sides → the local version is kept as a conflict copy and
///   the remote version is downloaded,
/// * deleted on one side and unchanged on the other → deleted.
class SyncService {
  SyncService({required this.localDir, required this.stateFile, required this.client});

  final Directory localDir;
  final File stateFile;
  final WebDavClient client;

  /// Called with a short description of the current step.
  void Function(String step)? onProgress;

  Future<Map<String, _SyncEntry>> _loadState() async {
    try {
      final json = jsonDecode(await stateFile.readAsString()) as Map<String, dynamic>;
      if (json['base'] != client.base.toString()) return {};
      final files = json['files'] as Map<String, dynamic>;
      return files.map((k, v) => MapEntry(k, _SyncEntry.fromJson(v as Map<String, dynamic>)));
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveState(Map<String, _SyncEntry> state) async {
    await stateFile.parent.create(recursive: true);
    await stateFile.writeAsString(jsonEncode({
      'base': client.base.toString(),
      'files': state.map((k, v) => MapEntry(k, v.toJson())),
    }));
  }

  Future<Map<String, File>> _localFiles() async {
    final out = <String, File>{};
    await for (final e in localDir.list()) {
      if (e is File && e.path.toLowerCase().endsWith('.rnote')) out[e.uri.pathSegments.last] = e;
    }
    return out;
  }

  Future<SyncReport> sync() async {
    final report = SyncReport();
    onProgress?.call('Conectando…');
    await client.ensureFolder();
    final state = await _loadState();
    final remote = {for (final r in await client.list()) r.name: r};
    final local = await _localFiles();
    final names = {...remote.keys, ...local.keys, ...state.keys};

    Future<void> recordAfterDownload(String name, RemoteFile r) async {
      final st = await File('${localDir.path}/$name').stat();
      state[name] = _SyncEntry(st.modified.millisecondsSinceEpoch, st.size, r.version);
    }

    Future<void> download(String name, RemoteFile r) async {
      onProgress?.call('Descargando $name');
      final bytes = await client.download(name);
      final tmp = File('${localDir.path}/.$name.part');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename('${localDir.path}/$name');
      report.downloaded++;
      await recordAfterDownload(name, r);
    }

    Future<void> upload(String name, File f) async {
      onProgress?.call('Subiendo $name');
      await client.upload(name, await f.readAsBytes());
      report.uploaded++;
    }

    final uploadedNames = <String>[];
    for (final name in names) {
      try {
        final l = local[name];
        final r = remote[name];
        final s = state[name];
        final lStat = l == null ? null : await l.stat();
        final localChanged = l != null &&
            (s == null ||
                s.localModified != lStat!.modified.millisecondsSinceEpoch ||
                s.localSize != lStat.size);
        final remoteChanged = r != null && (s == null || s.remoteVersion != r.version);

        if (l != null && r == null) {
          if (s != null && !localChanged) {
            // deleted remotely
            await l.delete();
            report.deletedLocal++;
            state.remove(name);
          } else {
            await upload(name, l);
            uploadedNames.add(name);
          }
        } else if (l == null && r != null) {
          if (s != null && !remoteChanged) {
            // deleted locally
            onProgress?.call('Borrando $name');
            await client.delete(name);
            report.deletedRemote++;
            state.remove(name);
          } else {
            await download(name, r);
          }
        } else if (l != null && r != null) {
          if (s == null) {
            // first sync with both present: identical sizes count as equal,
            // otherwise keep both
            if (lStat!.size == r.size) {
              state[name] = _SyncEntry(lStat.modified.millisecondsSinceEpoch, lStat.size, r.version);
            } else {
              await _keepConflict(name, l, report);
              await download(name, r);
            }
          } else if (localChanged && remoteChanged) {
            await _keepConflict(name, l, report);
            await download(name, r);
          } else if (localChanged) {
            await upload(name, l);
            uploadedNames.add(name);
          } else if (remoteChanged) {
            await download(name, r);
          }
        } else {
          state.remove(name);
        }
      } catch (e) {
        report.errors.add('$name: $e');
      }
    }

    // the remote versions of uploaded files are only known after listing again
    if (uploadedNames.isNotEmpty) {
      final after = {for (final r in await client.list()) r.name: r};
      for (final name in uploadedNames) {
        final r = after[name];
        final f = File('${localDir.path}/$name');
        if (r == null || !await f.exists()) continue;
        final st = await f.stat();
        state[name] = _SyncEntry(st.modified.millisecondsSinceEpoch, st.size, r.version);
      }
    }
    await _saveState(state);
    onProgress?.call('');
    return report;
  }

  /// Renames the local file to a conflict copy, which gets uploaded later.
  Future<void> _keepConflict(String name, File local, SyncReport report) async {
    final base = name.substring(0, name.length - '.rnote'.length);
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}${two(now.minute)}';
    var target = File('${localDir.path}/$base (conflicto móvil $stamp).rnote');
    var i = 2;
    while (await target.exists()) {
      target = File('${localDir.path}/$base (conflicto móvil $stamp $i).rnote');
      i++;
    }
    await local.rename(target.path);
    final conflictName = target.uri.pathSegments.last;
    await client.upload(conflictName, await target.readAsBytes());
    report.conflicts++;
  }
}
