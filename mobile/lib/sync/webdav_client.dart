import 'dart:convert';
import 'dart:io' show HttpDate;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

class RemoteFile {
  final String name;
  final String? etag;
  final DateTime? lastModified;
  final int size;

  const RemoteFile(this.name, {this.etag, this.lastModified, this.size = 0});

  /// Identifies the remote version of the file.
  String get version => etag ?? '${lastModified?.millisecondsSinceEpoch}:$size';
}

class WebDavException implements Exception {
  final String message;
  final int? status;
  WebDavException(this.message, [this.status]);

  @override
  String toString() => status == null ? message : '$message (HTTP $status)';
}

/// Minimal WebDAV client: enough to list, download, upload and delete the
/// files of one remote folder (Nextcloud, ownCloud, Synology, rclone,
/// the bundled `rnote_sync_server.py`, ...).
class WebDavClient {
  WebDavClient(String url, {String? user, String? password, http.Client? client})
      : base = Uri.parse(url.endsWith('/') ? url : '$url/'),
        _auth = (user != null && user.isNotEmpty)
            ? 'Basic ${base64Encode(utf8.encode('$user:${password ?? ''}'))}'
            : null,
        _client = client ?? http.Client();

  final Uri base;
  final String? _auth;
  final http.Client _client;

  Map<String, String> get _headers => {if (_auth != null) 'Authorization': _auth};

  Uri _fileUri(String name) => base.resolve(Uri.encodeComponent(name));

  Future<http.Response> _send(String method, Uri uri,
      {Map<String, String>? headers, List<int>? body}) async {
    final req = http.Request(method, uri)..headers.addAll({..._headers, ...?headers});
    if (body != null) req.bodyBytes = body;
    final streamed = await _client.send(req).timeout(const Duration(seconds: 60));
    return http.Response.fromStream(streamed);
  }

  static const _propfindBody = '<?xml version="1.0" encoding="utf-8"?>'
      '<d:propfind xmlns:d="DAV:"><d:prop>'
      '<d:getetag/><d:getlastmodified/><d:getcontentlength/><d:resourcetype/>'
      '</d:prop></d:propfind>';

  /// Creates the remote folder if it does not exist.
  Future<void> ensureFolder() async {
    final res = await _send('PROPFIND', base,
        headers: {'Depth': '0', 'Content-Type': 'application/xml'}, body: utf8.encode(_propfindBody));
    if (res.statusCode == 207 || res.statusCode == 200) return;
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw WebDavException('Usuario o contraseña incorrectos', res.statusCode);
    }
    if (res.statusCode == 404) {
      final mk = await _send('MKCOL', base);
      if (mk.statusCode == 201 || mk.statusCode == 405) return;
      throw WebDavException('No se pudo crear la carpeta remota', mk.statusCode);
    }
    throw WebDavException('El servidor no respondió como WebDAV', res.statusCode);
  }

  /// Lists the `.rnote` files of the remote folder.
  Future<List<RemoteFile>> list() async {
    final res = await _send('PROPFIND', base,
        headers: {'Depth': '1', 'Content-Type': 'application/xml'}, body: utf8.encode(_propfindBody));
    if (res.statusCode != 207 && res.statusCode != 200) {
      throw WebDavException('No se pudo listar la carpeta remota', res.statusCode);
    }
    final doc = XmlDocument.parse(utf8.decode(res.bodyBytes, allowMalformed: true));
    final out = <RemoteFile>[];
    for (final response in doc.descendants.whereType<XmlElement>().where((e) => e.localName == 'response')) {
      XmlElement? find(XmlElement parent, String name) {
        for (final e in parent.descendants.whereType<XmlElement>()) {
          if (e.localName == name) return e;
        }
        return null;
      }

      final href = find(response, 'href')?.innerText.trim();
      if (href == null) continue;
      if (find(response, 'collection') != null) continue;
      final path = Uri.decodeFull(Uri.parse(href).path);
      final segments = path.split('/').where((s) => s.isNotEmpty).toList();
      if (segments.isEmpty) continue;
      final name = segments.last;
      if (!name.toLowerCase().endsWith('.rnote')) continue;
      DateTime? modified;
      final lm = find(response, 'getlastmodified')?.innerText.trim();
      if (lm != null && lm.isNotEmpty) {
        try {
          modified = HttpDate.parse(lm);
        } catch (_) {
          modified = DateTime.tryParse(lm);
        }
      }
      final etag = find(response, 'getetag')?.innerText.trim();
      out.add(RemoteFile(
        name,
        etag: (etag == null || etag.isEmpty) ? null : etag.replaceAll('W/', ''),
        lastModified: modified,
        size: int.tryParse(find(response, 'getcontentlength')?.innerText.trim() ?? '') ?? 0,
      ));
    }
    return out;
  }

  Future<Uint8List> download(String name) async {
    final res = await _send('GET', _fileUri(name));
    if (res.statusCode != 200) throw WebDavException('No se pudo descargar "$name"', res.statusCode);
    return res.bodyBytes;
  }

  Future<void> upload(String name, Uint8List data) async {
    final res = await _send('PUT', _fileUri(name),
        headers: {'Content-Type': 'application/octet-stream'}, body: data);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw WebDavException('No se pudo subir "$name"', res.statusCode);
    }
  }

  Future<void> delete(String name) async {
    final res = await _send('DELETE', _fileUri(name));
    if (res.statusCode != 404 && (res.statusCode < 200 || res.statusCode >= 300)) {
      throw WebDavException('No se pudo borrar "$name"', res.statusCode);
    }
  }

  void close() => _client.close();
}
