import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rnote_mobile/editor/editor_screen.dart';
import 'package:rnote_mobile/library/library_service.dart';
import 'package:rnote_mobile/settings/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Renders the editor with real Rnote documents and writes screenshots to
/// $RNOTE_TEST_OUT, to check the rendering by eye.
void main() {
  final out = Platform.environment['RNOTE_TEST_OUT'];

  for (final name in ['overview', 'lecture_note_1', 'pdf_annotation']) {
    testWidgets('editor screenshot $name', (tester) async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final settings = await AppSettings.load();
      settings.autoHideSeconds = 0;
      final tmp = Directory.systemTemp.createTempSync('shot');
      final file = File('${tmp.path}/$name.rnote');
      File('../misc/screenshots-pages/$name.rnote').copySync(file.path);
      final library = LibraryService.at(tmp, tmp);

      await tester.binding.setSurfaceSize(const Size(1366, 1024));
      final key = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(colorSchemeSeed: const Color(0xFF3584E4)),
          home: EditorScreen(file: file, settings: settings, library: library),
        ),
      ));
      final state = tester.state(find.byType(EditorScreen)) as dynamic;
      for (var i = 0; i < 100 && state.controller == null; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      state.controller.fitWidth();
      // let images decode
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
        await tester.pump();
      }
      expect(find.byType(CustomPaint), findsWidgets);
      if (out != null) {
        await tester.runAsync(() async {
          final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          File('$out/editor_$name.png').writeAsBytesSync(png!.buffer.asUint8List());
        });
      }
      state.controller.dirty = false;
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });
  }
}
