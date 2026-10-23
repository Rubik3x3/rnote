import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../rnote/model.dart';

/// Decodes images of image strokes asynchronously and notifies when one
/// becomes available, so that the canvas can repaint.
class AssetCache extends ChangeNotifier {
  final _bitmaps = Expando<ui.Image>('bitmaps');
  final _vectors = Expando<PictureInfo>('vectors');
  final _pending = Expando<bool>('pending');

  ui.Image? bitmap(BitmapImageStroke s) {
    final img = _bitmaps[s];
    if (img != null) return img;
    if (_pending[s] == true) return null;
    _pending[s] = true;
    _decodeBitmap(s);
    return null;
  }

  Future<void> _decodeBitmap(BitmapImageStroke s) async {
    try {
      final bytes = base64Decode(s.dataBase64);
      if (bytes.length < s.pixelWidth * s.pixelHeight * 4) return;
      final image = await _decodePixels(bytes, s.pixelWidth, s.pixelHeight);
      _bitmaps[s] = image;
      notifyListeners();
    } catch (e) {
      debugPrint('failed to decode bitmap image: $e');
    }
  }

  Future<ui.Image> _decodePixels(Uint8List bytes, int w, int h) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = ui.ImageDescriptor.raw(buffer,
        width: w, height: h, pixelFormat: ui.PixelFormat.rgba8888);
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  PictureInfo? vector(VectorImageStroke s) {
    final pic = _vectors[s];
    if (pic != null) return pic;
    if (_pending[s] == true) return null;
    _pending[s] = true;
    vg.loadPicture(SvgStringLoader(s.svgData), null).then((info) {
      _vectors[s] = info;
      notifyListeners();
    }).catchError((Object e) {
      debugPrint('failed to load svg: $e');
    });
    return null;
  }
}

/// Paints strokes the way Rnote composes them.
abstract final class StrokeRenderer {
  static final _brushPaths = Expando<Path>('brushPaths');
  static final _texturedPaths = Expando<Path>('texturedPaths');
  static final _textPainters = Expando<TextPainter>('textPainters');

  static void paintEntry(Canvas canvas, StrokeEntry e, AssetCache assets) {
    final multiply = e.layer.kind == LayerKind.highlighter;
    paintStroke(canvas, e.stroke, assets, blendMode: multiply ? BlendMode.multiply : null);
  }

  static void paintStroke(Canvas canvas, Stroke stroke, AssetCache assets,
      {BlendMode? blendMode}) {
    switch (stroke) {
      case BrushStroke():
        _paintBrush(canvas, stroke, blendMode);
      case ShapeStroke():
        _paintShape(canvas, stroke);
      case TextStroke():
        _paintText(canvas, stroke);
      case VectorImageStroke():
        _paintVector(canvas, stroke, assets);
      case BitmapImageStroke():
        _paintBitmap(canvas, stroke, assets);
      case UnknownStroke():
        break;
    }
  }

  // -------------------------------------------------------------------------
  // Brush strokes
  // -------------------------------------------------------------------------

  static void _paintBrush(Canvas canvas, BrushStroke s, BlendMode? blendMode) {
    final style = s.style;
    final color = style.strokeColor;
    if (color == null) return;
    final paint = Paint()
      ..color = color.toUi()
      ..isAntiAlias = true;
    if (blendMode != null) paint.blendMode = blendMode;

    switch (style) {
      case TexturedStyle():
        final path = _texturedPaths[s] ??= buildTexturedPath(s.flattened, style);
        canvas.drawPath(path, paint);
      case SmoothStyle(:final pressureCurve, :final lineStyle) when
            pressureCurve == PressureCurve.constant || lineStyle != LineStyle.solid:
        _strokeConstantWidth(canvas, s.flattened, style, paint);
      case SmoothStyle(:final pressureCurve):
        final path = _brushPaths[s] ??=
            buildVariableWidthPath(s.flattened, style.strokeWidth, pressureCurve);
        canvas.drawPath(path, paint);
      case RoughStyle():
        _strokeConstantWidth(canvas, s.flattened, const SmoothStyle(), paint,
            width: style.strokeWidth);
    }
  }

  static void _strokeConstantWidth(
      Canvas canvas, List<PathElement> pts, SmoothStyle style, Paint paint,
      {double? width}) {
    final w = width ?? style.strokeWidth;
    if (pts.length == 1 || pts.every((e) => e.pos == pts.first.pos)) {
      canvas.drawCircle(pts.first.pos, w / 2, paint);
      return;
    }
    final path = Path()..moveTo(pts.first.pos.dx, pts.first.pos.dy);
    for (final p in pts.skip(1)) {
      path.lineTo(p.pos.dx, p.pos.dy);
    }
    paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = style.lineCap == 'straight' && style.lineStyle != LineStyle.solid
          ? StrokeCap.butt
          : StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(style.lineStyle == LineStyle.solid ? path : dashPath(path, style.dashPattern()),
        paint);
  }

  /// Builds a filled outline for a stroke with variable width.
  ///
  /// The ribbon is built clockwise (in y-down coordinates), like the circles
  /// added for the caps and sharp joints, so that the non-zero fill rule
  /// unites all parts without holes.
  static Path buildVariableWidthPath(
      List<PathElement> input, double width, String pressureCurve) {
    final pts = <PathElement>[];
    for (final e in input) {
      if (pts.isEmpty || (pts.last.pos - e.pos).distanceSquared > 1e-6) pts.add(e);
    }
    double halfWidth(PathElement e) =>
        math.max(PressureCurve.apply(pressureCurve, width, e.pressure) * 0.5, 0.15);

    final path = Path();
    if (pts.isEmpty) return path;
    if (pts.length == 1) {
      return path..addOval(Rect.fromCircle(center: pts.first.pos, radius: halfWidth(pts.first)));
    }

    final n = pts.length;
    final left = List<Offset>.filled(n, Offset.zero);
    final right = List<Offset>.filled(n, Offset.zero);
    Offset dirOf(Offset v) {
      final d = v.distance;
      return d == 0 ? Offset.zero : v / d;
    }

    for (var i = 0; i < n; i++) {
      final prev = i > 0 ? dirOf(pts[i].pos - pts[i - 1].pos) : null;
      final next = i < n - 1 ? dirOf(pts[i + 1].pos - pts[i].pos) : null;
      var t = (prev ?? next!) + (next ?? prev!);
      if (t.distanceSquared < 1e-9) t = next ?? prev!;
      t = dirOf(t);
      final normal = Offset(t.dy, -t.dx);
      final h = halfWidth(pts[i]);
      left[i] = pts[i].pos + normal * h;
      right[i] = pts[i].pos - normal * h;
    }

    path.moveTo(left[0].dx, left[0].dy);
    for (var i = 1; i < n; i++) {
      path.lineTo(left[i].dx, left[i].dy);
    }
    for (var i = n - 1; i >= 0; i--) {
      path.lineTo(right[i].dx, right[i].dy);
    }
    path.close();

    // round caps
    path.addOval(Rect.fromCircle(center: pts.first.pos, radius: halfWidth(pts.first)));
    path.addOval(Rect.fromCircle(center: pts.last.pos, radius: halfWidth(pts.last)));
    // round joints where the direction changes sharply
    for (var i = 1; i < n - 1; i++) {
      final a = dirOf(pts[i].pos - pts[i - 1].pos);
      final b = dirOf(pts[i + 1].pos - pts[i].pos);
      if (a.dx * b.dx + a.dy * b.dy < 0.85) {
        path.addOval(Rect.fromCircle(center: pts[i].pos, radius: halfWidth(pts[i])));
      }
    }
    return path;
  }

  /// Approximates Rnote's textured style with small, randomly scattered dots.
  static Path buildTexturedPath(List<PathElement> pts, TexturedStyle style) {
    final seed = style.seed?.digits.hashCode ?? pts.length;
    final rnd = math.Random(seed);
    final path = Path();
    double gauss() {
      final u1 = math.max(rnd.nextDouble(), 1e-9);
      final u2 = rnd.nextDouble();
      return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
    }

    for (var i = 1; i < pts.length; i++) {
      final a = pts[i - 1], b = pts[i];
      final seg = b.pos - a.pos;
      final len = seg.distance;
      if (len == 0) continue;
      final dir = seg / len;
      final normal = Offset(-dir.dy, dir.dx);
      final w = PressureCurve.apply(style.pressureCurve, style.strokeWidth, (a.pressure + b.pressure) / 2);
      final count = (len * w * style.density * 0.05).ceil().clamp(1, 400);
      final rx = 1.2 * (1 + 0.1 * w), ry = 0.3 * (1 + 0.1 * w);
      final angle = math.atan2(dir.dy, dir.dx);
      for (var k = 0; k < count; k++) {
        final along = rnd.nextDouble() * len;
        final across = (gauss() * 0.3).clamp(-0.5, 0.5) * w;
        final c = a.pos + dir * along + normal * across;
        final m = Float64List.fromList([
          math.cos(angle), math.sin(angle), 0, 0, //
          -math.sin(angle), math.cos(angle), 0, 0, //
          0, 0, 1, 0, //
          c.dx, c.dy, 0, 1,
        ]);
        path.addPath(
            Path()..addOval(Rect.fromCenter(center: Offset.zero, width: rx * 2, height: ry * 2)),
            Offset.zero,
            matrix4: m);
      }
    }
    return path;
  }

  // -------------------------------------------------------------------------
  // Shapes
  // -------------------------------------------------------------------------

  static void _paintShape(Canvas canvas, ShapeStroke s) {
    final style = s.style;
    final shape = s.shape;
    final path = shape is ArrowShape ? shape.toPathWithWidth(style.strokeWidth) : shape.toPath();
    final fill = style.fillColor;
    if (fill != null && fill.a > 0 && shape.isClosed) {
      canvas.drawPath(path, Paint()..color = fill.toUi());
    }
    final color = style.strokeColor;
    if (color == null) return;
    final smooth = style is SmoothStyle ? style : null;
    final paint = Paint()
      ..color = color.toUi()
      ..style = PaintingStyle.stroke
      ..strokeWidth = style.strokeWidth
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = (smooth?.lineCap ?? 'rounded') == 'rounded' ? StrokeCap.round : StrokeCap.butt;
    if (shape is ArrowShape && shape.head == 'filled') {
      final (l, r) = shape.headPoints(style.strokeWidth);
      canvas.drawPath(
          Path()
            ..moveTo(l.dx, l.dy)
            ..lineTo(shape.tip.dx, shape.tip.dy)
            ..lineTo(r.dx, r.dy)
            ..close(),
          Paint()..color = color.toUi());
    }
    final dashed = smooth != null && smooth.lineStyle != LineStyle.solid;
    canvas.drawPath(dashed ? dashPath(path, smooth.dashPattern()) : path, paint);
  }

  // -------------------------------------------------------------------------
  // Text
  // -------------------------------------------------------------------------

  static String? mapFontFamily(String family) {
    final f = family.toLowerCase();
    final ios = !kIsWeb && (Platform.isIOS || Platform.isMacOS);
    if (f == 'serif' || f.contains('serif') && !f.contains('sans')) {
      return ios ? 'Times New Roman' : 'serif';
    }
    if (f.contains('mono') || f == 'courier') return ios ? 'Menlo' : 'monospace';
    return null;
  }

  static TextStyle _baseTextStyle(TextStyleData s) => TextStyle(
        fontFamily: mapFontFamily(s.fontFamily),
        fontSize: s.fontSize,
        fontWeight: FontWeight.values[((s.fontWeight / 100).round() - 1).clamp(0, 8)],
        fontStyle: s.fontStyle == 'italic' ? FontStyle.italic : FontStyle.normal,
        color: s.color.toUi(),
        height: 1.2,
      );

  /// Converts an UTF-8 byte offset (as stored by Rnote) into an UTF-16 index.
  static int _byteToCharIndex(String text, int byteOffset) {
    var bytes = 0;
    var i = 0;
    for (final rune in text.runes) {
      if (bytes >= byteOffset) break;
      bytes += rune < 0x80 ? 1 : rune < 0x800 ? 2 : rune < 0x10000 ? 3 : 4;
      i += rune >= 0x10000 ? 2 : 1;
    }
    return i;
  }

  static TextSpan buildTextSpan(String text, TextStyleData style) {
    final base = _baseTextStyle(style);
    final ranges = <(int, int, Map)>[];
    for (final r in style.rangedAttributes) {
      if (r is! Map || r['range'] is! Map || r['attribute'] is! Map) continue;
      final range = r['range'] as Map;
      final start = _byteToCharIndex(text, (range['start'] as num?)?.toInt() ?? 0);
      final end = _byteToCharIndex(text, (range['end'] as num?)?.toInt() ?? 0);
      if (end > start) ranges.add((start, end, r['attribute'] as Map));
    }
    if (ranges.isEmpty) return TextSpan(text: text, style: base);

    final cuts = <int>{0, text.length};
    for (final (s, e, _) in ranges) {
      cuts
        ..add(s.clamp(0, text.length))
        ..add(e.clamp(0, text.length));
    }
    final sorted = cuts.toList()..sort();
    final children = <TextSpan>[];
    for (var i = 0; i < sorted.length - 1; i++) {
      final a = sorted[i], b = sorted[i + 1];
      if (b <= a) continue;
      var ts = base;
      final decorations = <TextDecoration>[];
      for (final (s, e, attr) in ranges) {
        if (s > a || e < b) continue;
        final (key, value) = (attr.keys.first, attr.values.first);
        switch (key) {
          case 'font_family':
            ts = ts.copyWith(fontFamily: mapFontFamily(value.toString()));
          case 'font_size':
            ts = ts.copyWith(fontSize: (value as num).toDouble());
          case 'font_weight':
            ts = ts.copyWith(
                fontWeight: FontWeight.values[(((value as num) / 100).round() - 1).clamp(0, 8)]);
          case 'text_color':
            ts = ts.copyWith(color: RColor.fromJson(value).toUi());
          case 'font_style':
            ts = ts.copyWith(fontStyle: value == 'italic' ? FontStyle.italic : FontStyle.normal);
          case 'underline' when value == true:
            decorations.add(TextDecoration.underline);
          case 'strikethrough' when value == true:
            decorations.add(TextDecoration.lineThrough);
        }
      }
      if (decorations.isNotEmpty) {
        ts = ts.copyWith(decoration: TextDecoration.combine(decorations), decorationColor: ts.color);
      }
      children.add(TextSpan(text: text.substring(a, b), style: ts));
    }
    return TextSpan(style: base, children: children);
  }

  static TextPainter textPainterFor(TextStroke s) {
    final existing = _textPainters[s];
    if (existing != null) return existing;
    final painter = TextPainter(
      text: buildTextSpan(s.text, s.style),
      textDirection: TextDirection.ltr,
      textAlign: switch (s.style.alignment) {
        'center' => TextAlign.center,
        'end' => TextAlign.end,
        'fill' => TextAlign.justify,
        _ => TextAlign.start,
      },
    )..layout(maxWidth: s.style.maxWidth ?? double.infinity);
    TextStroke.layoutSize[s] = Size(
        math.max(painter.width, s.style.maxWidth ?? 0), math.max(painter.height, s.style.fontSize));
    _textPainters[s] = painter;
    return painter;
  }

  static void _paintText(Canvas canvas, TextStroke s) {
    final painter = textPainterFor(s);
    canvas.save();
    canvas.transform(s.affine.toMatrix4());
    painter.paint(canvas, Offset.zero);
    canvas.restore();
  }

  // -------------------------------------------------------------------------
  // Images
  // -------------------------------------------------------------------------

  static void _paintPlaceholder(Canvas canvas, RectShape rect) {
    canvas.drawPath(
        rect.toPath(),
        Paint()
          ..color = const Color(0x22808080)
          ..style = PaintingStyle.fill);
  }

  static void _paintVector(Canvas canvas, VectorImageStroke s, AssetCache assets) {
    final info = assets.vector(s);
    if (info == null) {
      _paintPlaceholder(canvas, s.rectangle);
      return;
    }
    final he = s.rectangle.halfExtents;
    final size = info.size;
    canvas.save();
    canvas.transform(s.rectangle.affine.toMatrix4());
    canvas.translate(-he.dx, -he.dy);
    if (size.width > 0 && size.height > 0) {
      canvas.scale(he.dx * 2 / size.width, he.dy * 2 / size.height);
    }
    canvas.drawPicture(info.picture);
    canvas.restore();
  }

  static void _paintBitmap(Canvas canvas, BitmapImageStroke s, AssetCache assets) {
    final image = assets.bitmap(s);
    if (image == null) {
      _paintPlaceholder(canvas, s.rectangle);
      return;
    }
    final he = s.rectangle.halfExtents;
    canvas.save();
    canvas.transform(s.rectangle.affine.toMatrix4());
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTRB(-he.dx, -he.dy, he.dx, he.dy),
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();
  }
}

/// Splits a path into dashes following [pattern] (on/off lengths).
Path dashPath(Path source, List<double> pattern) {
  if (pattern.isEmpty || pattern.every((e) => e <= 0)) return source;
  final out = Path();
  for (final metric in source.computeMetrics()) {
    var distance = 0.0;
    var i = 0;
    var draw = true;
    while (distance < metric.length) {
      final len = math.max(pattern[i % pattern.length], 0.01);
      if (draw) {
        out.addPath(metric.extractPath(distance, distance + len), Offset.zero);
      }
      distance += len;
      draw = !draw;
      i++;
    }
  }
  return out;
}

/// Bounds of strokes rendered in a canvas, used e.g. for exporting images.
Rect? boundsOfEntries(Iterable<StrokeEntry> entries) {
  Rect? r;
  for (final e in entries) {
    final b = e.stroke.bounds;
    if (b == Rect.zero) continue;
    r = r == null ? b : r.expandToInclude(b);
  }
  return r;
}
