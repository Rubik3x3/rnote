import 'dart:io';

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
  testWidgets('stylus, eraser end, palm rejection and two finger undo', (tester) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final settings = await AppSettings.load();
    settings.autosaveSeconds = 0;
    final tmp = Directory.systemTemp.createTempSync('input');
    final library = LibraryService.at(tmp, tmp);
    final file = File('${tmp.path}/t.rnote')
      ..writeAsBytesSync(RnoteFile.save(library.newDocument(settings)));

    await tester.binding.setSurfaceSize(const Size(1200, 900));
    await tester.pumpWidget(MaterialApp(
      home: EditorScreen(file: file, settings: settings, library: library),
    ));
    final state = tester.state(find.byType(EditorScreen)) as dynamic;
    for (var i = 0; i < 100 && state.controller == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    final EditorController c = state.controller;
    expect(c.doc.strokes, isEmpty);

    // draw with the stylus
    final pen = await tester.createGesture(kind: PointerDeviceKind.stylus, pointer: 1);
    await pen.down(const Offset(600, 400));
    // a palm touching meanwhile must be ignored
    final palm = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 2);
    await palm.down(const Offset(700, 700));
    for (var i = 1; i <= 20; i++) {
      await pen.moveTo(Offset(600 + i * 8.0, 400 + i * 3.0));
    }
    await palm.moveTo(const Offset(720, 720));
    await pen.up();
    await palm.up();
    await tester.pump();
    expect(c.doc.strokes.length, 1);
    expect(c.doc.strokes.single.stroke, isA<BrushStroke>());
    expect((c.doc.strokes.single.stroke as BrushStroke).flattened.length, greaterThan(10));

    // after a stylus was seen, a finger navigates instead of drawing
    final zoomBefore = c.camera.offset;
    final finger = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 3);
    await finger.down(const Offset(500, 500));
    await finger.moveTo(const Offset(400, 450));
    await finger.moveTo(const Offset(300, 400));
    await finger.up();
    await tester.pump();
    expect(c.doc.strokes.length, 1);
    expect(c.camera.offset, isNot(zoomBefore));

    // erase with the eraser end of the stylus
    final eraserEnd = await tester.createGesture(kind: PointerDeviceKind.invertedStylus, pointer: 4);
    final mid = c.camera.docToScreen(c.doc.strokes.single.stroke.bounds.center);
    await eraserEnd.down(mid - const Offset(40, 15));
    await eraserEnd.moveTo(mid + const Offset(40, 15));
    await eraserEnd.up();
    await tester.pump();
    expect(c.doc.strokes, isEmpty);
    expect(c.tool, Tool.pen, reason: 'the eraser end does not change the tool');

    // two finger tap undoes the erasing
    final a = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 5);
    final b = await tester.createGesture(kind: PointerDeviceKind.touch, pointer: 6);
    await a.down(const Offset(300, 300));
    await b.down(const Offset(400, 300));
    await a.up();
    await b.up();
    await tester.pump();
    expect(c.doc.strokes.length, 1);

    // the result is a valid file
    await tester.runAsync(c.save);
    expect(RnoteFile.load(file.readAsBytesSync()).strokes.length, 1);
    c.dirty = false;
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });
}
