import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:rnote_mobile/rnote/geometry.dart';
import 'package:rnote_mobile/rnote/json_codec.dart';
import 'package:rnote_mobile/rnote/model.dart';
import 'package:rnote_mobile/rnote/rnote_file.dart';

/// Directory where generated files are written, so that they can be checked
/// with `rnote-cli test`.
final outDir = Directory(Platform.environment['RNOTE_TEST_OUT'] ?? '${Directory.systemTemp.path}/rnote_mobile_test');

RnoteDocument sampleDocument() {
  final doc = RnoteDocument(config: const DocConfig(layout: Layout.fixedSize));
  void add(Stroke s, [StrokeLayer layer = StrokeLayer.user0]) =>
      doc.strokes.add(StrokeEntry(s, layer, doc.nextChrono()));
  add(BrushStroke(
    PenPath.fromElements([
      for (var i = 0; i < 50; i++) PathElement(Offset(100 + i * 4.0, 100 + (i % 7) * 3.0), i / 50)
    ]),
    const SmoothStyle(strokeWidth: 4, strokeColor: RColor(0.2, 0.3, 0.8, 1)),
  ));
  add(
      BrushStroke(
        PenPath.fromElements([
          for (var i = 0; i < 20; i++) PathElement(Offset(100 + i * 10.0, 200), 0.5)
        ]),
        const SmoothStyle(
            strokeWidth: 12, strokeColor: RColor(1, 0.9, 0, 0.5), pressureCurve: PressureCurve.constant),
      ),
      StrokeLayer.highlighter);
  add(ShapeStroke(const LineShape(Offset(10, 10), Offset(300, 40)), const SmoothStyle()));
  add(ShapeStroke(const ArrowShape(Offset(10, 300), Offset(200, 260), head: 'filled'), const SmoothStyle()));
  add(ShapeStroke(RectShape.fromRect(const Rect.fromLTWH(300, 300, 120, 80)),
      const SmoothStyle(fillColor: RColor(0, 1, 0, 0.3))));
  add(ShapeStroke(EllipseShape(const Offset(50, 30), Affine.translation(const Offset(500, 500))),
      const SmoothStyle()));
  add(ShapeStroke(const PolyShape(Offset(0, 0), [Offset(10, 10), Offset(20, 0)], closed: true),
      const RoughStyle(seed: U64('12126857806287394736'))));
  add(TextStroke('Hola Rnote ñ', Affine.translation(const Offset(50, 600)), const TextStyleData()));
  add(VectorImageStroke(
      '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>',
      const Offset(10, 10),
      RectShape.fromRect(const Rect.fromLTWH(600, 600, 10, 10))));
  add(
      BitmapImageStroke(
        dataBase64: 'AAAA/wAAAP8AAAD/AAAA/w==',
        pixelWidth: 2,
        pixelHeight: 2,
        imageRectangle: RectShape(const Offset(1, 1), Affine.translation(const Offset(1, 1))),
        rectangle: RectShape(const Offset(1, 1), const Affine(20, 0, 0, 20, 700, 700)),
      ),
      StrokeLayer.image);
  return doc;
}

void main() {
  setUpAll(() => outDir.createSync(recursive: true));

  test('u64 values survive a JSON round trip', () {
    const text = '{"seed":12126857806287394736,"s":"x:12126857806287394736,","n":-5,"f":1.5e3}';
    final decoded = decodeJsonPreservingU64(text) as Map;
    expect(decoded['seed'], isA<U64>());
    expect(decoded['s'], 'x:12126857806287394736,');
    expect(encodeJsonPreservingU64(decoded),
        '{"seed":12126857806287394736,"s":"x:12126857806287394736,","n":-5,"f":1500.0}');
  });

  test('round trips the Rnote test files', () {
    final dir = Directory('../misc');
    final files = dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.rnote'))
        .toList();
    var loaded = 0;
    for (final f in files) {
      final RnoteDocument doc;
      try {
        doc = RnoteFile.load(f.readAsBytesSync());
      } on RnoteFormatException {
        continue; // too old
      }
      loaded++;
      expect(doc.strokes, isNotEmpty);
      final name = f.uri.pathSegments.last.replaceAll('.rnote', '');
      File('${outDir.path}/roundtrip_$name.rnote').writeAsBytesSync(RnoteFile.save(doc));
      File('${outDir.path}/roundtrip_legacy_$name.rnote')
          .writeAsBytesSync(RnoteFile.save(doc, legacy: true));
      // moving every stroke exercises the merge of modified strokes
      for (var i = 0; i < doc.strokes.length; i++) {
        final e = doc.strokes[i];
        doc.strokes[i] = e.withStroke(e.stroke.transformed(Affine.translation(const Offset(10, 10))));
      }
      File('${outDir.path}/moved_$name.rnote').writeAsBytesSync(RnoteFile.save(doc));
      final reloaded = RnoteFile.load(RnoteFile.save(doc));
      expect(reloaded.strokes.length, doc.strokes.length);
    }
    expect(loaded, greaterThan(0));
  });

  test('writes new documents with every stroke type', () {
    final doc = sampleDocument();
    final bytes = RnoteFile.save(doc);
    File('${outDir.path}/new_document.rnote').writeAsBytesSync(bytes);
    File('${outDir.path}/new_document_legacy.rnote')
        .writeAsBytesSync(RnoteFile.save(sampleDocument(), legacy: true));
    final reloaded = RnoteFile.load(bytes);
    expect(reloaded.strokes.length, doc.strokes.length);
    expect(reloaded.strokes.map((e) => e.stroke.runtimeType).toSet().length, 5);
    final rough = reloaded.strokes
        .map((e) => e.stroke)
        .whereType<ShapeStroke>()
        .map((s) => s.style)
        .whereType<RoughStyle>()
        .single;
    expect(rough.seed?.digits, '12126857806287394736');
  });
}
