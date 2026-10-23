import 'dart:io';

import 'package:flutter/foundation.dart';

import '../library/library_service.dart';
import '../settings/app_settings.dart';
import 'sync_service.dart';
import 'webdav_client.dart';

/// Runs synchronizations and exposes their progress to the UI.
class SyncController extends ChangeNotifier {
  SyncController(this.settings, this.library);

  final AppSettings settings;
  final LibraryService library;

  bool running = false;
  String step = '';
  SyncReport? lastReport;
  String? lastError;

  File get _stateFile => File('${library.support.path}/sync_state.json');

  Future<SyncReport?> sync() async {
    if (running || !settings.syncConfigured) return null;
    running = true;
    lastError = null;
    step = 'Conectando…';
    notifyListeners();
    final client = WebDavClient(settings.syncUrl,
        user: settings.syncUser, password: settings.syncPassword);
    try {
      final service = SyncService(localDir: library.root, stateFile: _stateFile, client: client)
        ..onProgress = (s) {
          step = s;
          notifyListeners();
        };
      final report = await service.sync();
      lastReport = report;
      settings.lastSync = DateTime.now();
      return report;
    } catch (e) {
      lastError = e is SocketException ? 'No se pudo conectar con el servidor (${e.message})' : '$e';
      return null;
    } finally {
      client.close();
      running = false;
      step = '';
      notifyListeners();
    }
  }

  /// Checks the connection with the given parameters. Throws on failure.
  static Future<String> test(String url, String user, String password) async {
    final client = WebDavClient(url, user: user, password: password);
    try {
      await client.ensureFolder();
      final files = await client.list();
      return 'Conexión correcta: ${files.length} documentos en el servidor';
    } finally {
      client.close();
    }
  }
}
