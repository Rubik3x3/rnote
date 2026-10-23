import 'dart:convert';
import 'dart:io' show gzip, GZipCodec;
import 'dart:typed_data';

import 'json_codec.dart';
import 'model.dart';

/// Version of the file format written by default. Matches Rnote 0.15.
const String rnoteFormatVersion = '0.15.0';

/// Version written in compatibility mode, readable by Rnote 0.13 and 0.14.
const String rnoteLegacyFormatVersion = '0.14.2';

class RnoteFormatException implements Exception {
  final String message;
  RnoteFormatException(this.message);

  @override
  String toString() => message;
}

class _Version implements Comparable<_Version> {
  final int major, minor, patch;
  const _Version(this.major, this.minor, this.patch);

  factory _Version.parse(String s) {
    final core = s.split(RegExp(r'[-+]')).first.split('.');
    int part(int i) => i < core.length ? int.tryParse(core[i]) ?? 0 : 0;
    return _Version(part(0), part(1), part(2));
  }

  @override
  int compareTo(_Version o) => major != o.major
      ? major.compareTo(o.major)
      : minor != o.minor
          ? minor.compareTo(o.minor)
          : patch.compareTo(o.patch);

  bool operator >=(_Version o) => compareTo(o) >= 0;

  bool operator <(_Version o) => compareTo(o) < 0;
}

/// Loads and saves Rnote's `.rnote` files: gzip compressed JSON of the form
/// `{"version": "...", "data": {"engine_snapshot": {...}}}`.
abstract final class RnoteFile {
  static RnoteDocument load(Uint8List bytes) {
    final List<int> decompressed;
    try {
      decompressed = gzip.decode(bytes);
    } catch (_) {
      throw RnoteFormatException('El archivo no es un documento de Rnote válido.');
    }
    final root = decodeJsonPreservingU64(utf8.decode(decompressed));
    if (root is! Map<String, dynamic> || root['data'] is! Map) {
      throw RnoteFormatException('Estructura de archivo desconocida.');
    }
    final version = _Version.parse(root['version']?.toString() ?? '0.0.0');
    final data = root['data'] as Map<String, dynamic>;
    if (version < const _Version(0, 5, 9)) {
      throw RnoteFormatException(
          'Archivo de Rnote ${root['version']} demasiado antiguo. Ábrelo y guárdalo '
          'con una versión reciente de Rnote en el PC.');
    }
    // conversions of older formats, mirroring `rnoteformat/maj0min*.rs`
    if (version < const _Version(0, 5, 10)) _migrateMaj0Min5Patch9(data);
    // 0.6 -> 0.9 only added the camera, which has a default here
    if (version < const _Version(0, 13, 0)) _migrateMaj0Min9(data);
    if (version < const _Version(0, 15, 0)) _migrateMaj0Min13(data);
    final snapshot = data['engine_snapshot'];
    if (snapshot is! Map<String, dynamic>) {
      throw RnoteFormatException('Falta "engine_snapshot".');
    }
    return _readSnapshot(snapshot);
  }

  static RnoteDocument _readSnapshot(Map<String, dynamic> snap) {
    final docJson = snap['document'] as Map<String, dynamic>? ?? const {};
    final strokesJson = snap['stroke_components'] as List? ?? const [];
    final chronoJson = snap['chrono_components'] as List? ?? const [];

    final entries = <StrokeEntry>[];
    var maxT = 0;
    for (var i = 0; i < strokesJson.length; i++) {
      final slot = strokesJson[i];
      if (slot is! Map || slot['value'] is! Map<String, dynamic>) continue;
      final value = slot['value'] as Map<String, dynamic>;
      if (value.isEmpty) continue;
      final version = toInt(slot['version']);
      var layer = StrokeLayer.user0;
      var t = 0;
      if (i < chronoJson.length) {
        final c = chronoJson[i];
        if (c is Map && c['value'] is Map && toInt(c['version']) == version) {
          final cv = c['value'] as Map;
          t = toInt(cv['t']);
          layer = StrokeLayer.fromJson(cv['layer']);
        }
      }
      if (t > maxT) maxT = t;
      entries.add(StrokeEntry(Stroke.fromJson(value), layer, t));
    }

    final doc = RnoteDocument(
      config: DocConfig.fromJson(docJson['config']),
      x: toDouble(docJson['x']),
      y: toDouble(docJson['y']),
      width: toDouble(docJson['width'], 793.701),
      height: toDouble(docJson['height'], 1122.52),
      camera: CameraState.fromJson(snap['camera']),
      strokes: entries,
      chronoCounter: toInt(snap['chrono_counter']) < maxT ? maxT : toInt(snap['chrono_counter']),
      extraSnapshotFields: {
        for (final e in snap.entries)
          if (!const {
            'document',
            'camera',
            'stroke_components',
            'chrono_components',
            'chrono_counter'
          }.contains(e.key))
            e.key: e.value,
      },
    );
    doc.sortStrokes();
    return doc;
  }

  /// Serializes the document. With [legacy] the file is written in the format
  /// of Rnote 0.13/0.14, so that older desktop installations can open it.
  static Uint8List save(RnoteDocument doc, {bool legacy = false}) {
    doc.resizeToFitContent();
    final strokeSlots = <Map<String, dynamic>>[
      {'value': null, 'version': 0}
    ];
    final chronoSlots = <Map<String, dynamic>>[
      {'value': null, 'version': 0}
    ];
    for (final e in doc.strokes) {
      var json = e.stroke.toJson();
      if (legacy) json = _toLegacy(json);
      strokeSlots.add({'value': json, 'version': 1});
      chronoSlots.add({
        'value': {'t': e.t, 'layer': e.layer.toJson()},
        'version': 1,
      });
    }
    final snapshot = <String, dynamic>{
      ...doc.extraSnapshotFields,
      'document': {
        'config': doc.config.toJson(),
        'x': dp3(doc.x),
        'y': dp3(doc.y),
        'width': dp3(doc.width),
        'height': dp3(doc.height),
      },
      'camera': doc.camera.toJson(),
      'stroke_components': strokeSlots,
      'chrono_components': chronoSlots,
      'chrono_counter': doc.chronoCounter,
    };
    final wrapper = {
      'version': legacy ? rnoteLegacyFormatVersion : rnoteFormatVersion,
      'data': {'engine_snapshot': snapshot},
    };
    final text = encodeJsonPreservingU64(wrapper);
    return Uint8List.fromList(GZipCodec(level: 5).encode(utf8.encode(text)));
  }

  // -------------------------------------------------------------------------
  // Format conversions between 0.13/0.14 and 0.15, mirroring
  // `rnoteformat/maj0min15.rs`.
  // -------------------------------------------------------------------------

  static void _migrateMaj0Min5Patch9(Map<String, dynamic> data) {
    final store = data.remove('store_snapshot');
    final document = data.remove('document') ?? data.remove('sheet');
    if (store is! Map) return;
    data['engine_snapshot'] = <String, dynamic>{
      'document': document,
      'stroke_components': store['stroke_components'],
      'chrono_components': store['chrono_components'],
      'chrono_counter': store['chrono_counter'],
    };
  }

  /// Moves format, background and layout into the document config.
  static void _migrateMaj0Min9(Map<String, dynamic> data) {
    final snap = data['engine_snapshot'];
    if (snap is! Map || snap['document'] is! Map) return;
    final document = snap['document'] as Map;
    if (document['config'] is Map) return;
    document.remove('snap_positions');
    document['config'] = <String, dynamic>{
      'format': document.remove('format'),
      'background': document.remove('background'),
      'layout': document.remove('layout') ?? document.remove('expand_mode'),
    };
  }

  static void _migrateMaj0Min13(Map<String, dynamic> data) {
    final snap = data['engine_snapshot'];
    if (snap is! Map) return;
    final comps = snap['stroke_components'];
    if (comps is! List) return;
    for (final comp in comps) {
      if (comp is! Map || comp['value'] is! Map) continue;
      _forEachTransformedObject(comp['value'] as Map, (obj) {
        final transform = obj.remove('transform');
        if (transform is Map && transform['affine'] is List) {
          final m = transform['affine'] as List;
          obj['affine'] = [m[0], m[1], m[3], m[4], m[6], m[7]];
        }
      });
    }
  }

  static Map<String, dynamic> _toLegacy(Map<String, dynamic> strokeJson) {
    final copy = deepCopyJson(strokeJson) as Map<String, dynamic>;
    _forEachTransformedObject(copy, (obj) {
      final affine = obj.remove('affine');
      if (affine is List && affine.length >= 6) {
        obj['transform'] = {
          'affine': [affine[0], affine[1], 0.0, affine[2], affine[3], 0.0, affine[4], affine[5], 1.0]
        };
      }
    });
    return copy;
  }

  /// Calls [f] on every object of a stroke that holds a transform.
  static void _forEachTransformedObject(Map value, void Function(Map obj) f) {
    final shape = value['shapestroke'];
    if (shape is Map && shape['shape'] is Map) {
      final s = shape['shape'] as Map;
      if (s['rect'] is Map) f(s['rect'] as Map);
      if (s['ellipse'] is Map) f(s['ellipse'] as Map);
    }
    if (value['textstroke'] is Map) f(value['textstroke'] as Map);
    final vector = value['vectorimage'];
    if (vector is Map && vector['rectangle'] is Map) f(vector['rectangle'] as Map);
    final bitmap = value['bitmapimage'];
    if (bitmap is Map) {
      final image = bitmap['image'];
      if (image is Map && image['rectangle'] is Map) f(image['rectangle'] as Map);
      if (bitmap['rectangle'] is Map) f(bitmap['rectangle'] as Map);
    }
  }
}
