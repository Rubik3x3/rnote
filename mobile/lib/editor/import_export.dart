import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../render/background_renderer.dart';
import '../render/stroke_renderer.dart';
import '../rnote/model.dart';
import 'editor_controller.dart';

/// The area of a document that is exported / used for thumbnails.
Rect exportArea(RnoteDocument doc) {
  final f = doc.config.format;
  final content = doc.contentBounds();
  switch (doc.config.layout) {
    case Layout.fixedSize || Layout.continuousVertical:
      final bottom = math.max(content?.bottom ?? 0, 1.0);
      final pages = doc.config.layout == Layout.fixedSize
          ? (bottom / f.height).ceil() * f.height
          : math.max(bottom + 20, f.height);
      return Rect.fromLTWH(0, 0, f.width, pages);
    default:
      return (content ?? Rect.fromLTWH(0, 0, f.width, f.height)).inflate(30);
  }
}

/// Renders a region of the document to an image.
Future<ui.Image> renderDocument(RnoteDocument doc, AssetCache assets, Rect area, double scale) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.scale(scale);
  canvas.translate(-area.left, -area.top);
  BackgroundRenderer.paint(canvas, doc,
      viewport: area, zoom: scale, deskColor: doc.config.background.color.toUi());
  for (final e in doc.strokes) {
    if (!e.stroke.bounds.overlaps(area)) continue;
    StrokeRenderer.paintEntry(canvas, e, assets);
  }
  final picture = recorder.endRecording();
  return picture.toImage(
    math.max(1, (area.width * scale).ceil()),
    math.max(1, (area.height * scale).ceil()),
  );
}

/// Waits briefly until the images of image strokes are decoded.
Future<void> _preloadImages(EditorController c) async {
  var pending = false;
  for (final e in c.doc.strokes) {
    final s = e.stroke;
    if (s is BitmapImageStroke && c.assets.bitmap(s) == null) pending = true;
    if (s is VectorImageStroke && c.assets.vector(s) == null) pending = true;
  }
  if (pending) await Future<void>.delayed(const Duration(milliseconds: 600));
}

Future<Uint8List?> renderPng(EditorController c, {double maxSide = 4096}) async {
  await _preloadImages(c);
  final area = exportArea(c.doc);
  final scale = math.min(2.0, maxSide / math.max(area.width, area.height));
  final image = await renderDocument(c.doc, c.assets, area, scale);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data?.buffer.asUint8List();
}

/// Writes a small preview of the document, shown in the library.
Future<void> writeThumbnail(EditorController c, File target) async {
  try {
    final area = exportArea(c.doc);
    final aspectArea = c.doc.config.layout == Layout.infinite || c.doc.config.layout == Layout.semiInfinite
        ? area
        : Rect.fromLTWH(area.left, area.top, area.width,
            math.min(area.height, c.doc.config.format.height));
    final scale = 360 / math.max(aspectArea.width, 1);
    final image = await renderDocument(c.doc, c.assets, aspectArea, scale);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) return;
    await target.parent.create(recursive: true);
    await target.writeAsBytes(data.buffer.asUint8List());
  } catch (e) {
    debugPrint('thumbnail failed: $e');
  }
}

Rect? _shareOrigin(BuildContext context) {
  final box = context.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}

Future<void> shareRnoteFile(BuildContext context, EditorController c) async {
  await c.save();
  if (!context.mounted) return;
  await SharePlus.instance.share(ShareParams(
    files: [XFile(c.file.path, mimeType: 'application/x-rnote')],
    sharePositionOrigin: _shareOrigin(context),
  ));
}

Future<void> sharePng(BuildContext context, EditorController c) async {
  final png = await renderPng(c);
  if (png == null || !context.mounted) return;
  final dir = await getTemporaryDirectory();
  final f = File('${dir.path}/${c.title}.png');
  await f.writeAsBytes(png);
  if (!context.mounted) return;
  await SharePlus.instance.share(ShareParams(
    files: [XFile(f.path, mimeType: 'image/png')],
    sharePositionOrigin: _shareOrigin(context),
  ));
}

/// Lets the user pick an image (bitmap or SVG) and inserts it.
Future<void> insertImage(BuildContext context, EditorController c, {bool gallery = false}) async {
  final files = await FilePicker.pickFiles(
    type: gallery ? FileType.image : FileType.custom,
    allowedExtensions: gallery ? null : const ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'svg'],
  );
  if (files.isEmpty) return;
  final file = files.first;
  final bytes = await file.xFile.readAsBytes();
  if (file.name.toLowerCase().endsWith('.svg')) {
    final svg = utf8.decode(bytes, allowMalformed: true);
    final info = await vg.loadPicture(SvgStringLoader(svg), null);
    c.insertSvg(svg, info.size);
    info.picture.dispose();
    return;
  }
  // decode, downscale huge images, convert to premultiplied RGBA like Rnote
  const maxSide = 2560;
  final probe = await ui.instantiateImageCodec(bytes);
  final probeFrame = await probe.getNextFrame();
  final w0 = probeFrame.image.width, h0 = probeFrame.image.height;
  probeFrame.image.dispose();
  final scale = math.min(1.0, maxSide / math.max(w0, h0));
  final codec = await ui.instantiateImageCodec(bytes,
      targetWidth: (w0 * scale).round(), targetHeight: (h0 * scale).round());
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) return;
  c.insertBitmap(base64Encode(data.buffer.asUint8List()), image.width, image.height);
  image.dispose();
}
