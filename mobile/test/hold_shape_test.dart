import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rnote_mobile/editor/editor_controller.dart';
import 'package:rnote_mobile/editor/editor_screen.dart';
import 'package:rnote_mobile/library/library_service.dart';
import 'package:rnote_mobile/rnote/model.dart';
import 'package:rnote_mobile/rnote/rnote_file.dart';
import 'package:rnote_mobile/settings/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('holding the pen turns the stroke into a shape, undo brings the stroke back', (tester) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final settings = await AppSettings.load();
    settings.autosaveSeconds = 0;
    settings.autosaveOnChange = false;
    final tmp = Directory.systemTemp.createTempSync('hold');
    final library = LibraryService.at(tmp, tmp);
    final file = File('${tmp.path}/t.rnote')..writeAsBytesSync(RnoteFile.save(library.newDocument(settings)));

    await tester.binding.setSurfaceSize(const Size(1200, 900));
    await tester.pumpWidget(MaterialApp(home: EditorScreen(file: file, settings: settings, library: library)));
    final state = tester.state(find.byType(EditorScreen)) as dynamic;
    for (var i = 0; i < 100 && state.controller == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    final EditorController c = state.controller;

    const center = Offset(600, 450);
    Offset wobbly(int i) => center + Offset.fromDirection(i / 120 * 2 * math.pi, 150 + math.sin(i * 1.3) * 5);

    final pen = await tester.createGesture(kind: PointerDeviceKind.stylus, pointer: 1);
    await pen.down(wobbly(0));
    for (var i = 1; i <= 60; i++) {
      await pen.moveTo(wobbly(i));
    }
    // a pause in the middle turns half the circle into an arc, drawing on continues the stroke
    await tester.pump(const Duration(milliseconds: 700));
    for (var i = 61; i <= 120; i++) {
      await pen.moveTo(wobbly(i));
    }
    // hold still
    await tester.pump(const Duration(milliseconds: 700));
    await pen.up();
    await tester.pump();

    List<double> radii() {
      final s = c.doc.strokes.single.stroke as BrushStroke;
      final docCenter = c.camera.screenToDoc(center);
      return [for (final p in s.flattened) (p.pos - docCenter).distance];
    }

    double spread(List<double> v) => v.reduce(math.max) - v.reduce(math.min);

    expect(c.doc.strokes.length, 1);
    final r = radii();
    expect(spread(r) / (r.reduce((a, b) => a + b) / r.length), lessThan(0.03));
    final docCenter = c.camera.screenToDoc(center);
    final points = (c.doc.strokes.single.stroke as BrushStroke).flattened;
    for (var q = 0; q < 4; q++) {
      final dir = Offset.fromDirection(q * math.pi / 2 + math.pi / 4);
      expect(
          points.any((e) {
            final d = e.pos - docCenter;
            return (d.dx * dir.dx + d.dy * dir.dy) / d.distance > 0.99;
          }),
          isTrue,
          reason: 'quadrant $q is missing');
    }

    c.undo();
    expect(c.doc.strokes.length, 1);
    expect(spread(radii()) / 150, greaterThan(0.04));
    c.undo();
    expect(c.doc.strokes, isEmpty);
  });
}
