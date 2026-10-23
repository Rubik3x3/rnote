import 'dart:math' as math;
import 'dart:ui';

import '../rnote/model.dart';

/// Paints the document background, its pattern and page borders.
///
/// Expects the canvas to be in document coordinates.
abstract final class BackgroundRenderer {
  static void paint(
    Canvas canvas,
    RnoteDocument doc, {
    required Rect viewport,
    required double zoom,
    required Color deskColor,
  }) {
    final config = doc.config;
    final bg = config.background;
    final infinite = config.layout == Layout.infinite;

    // Area covered by the document, for infinite documents everything visible.
    Rect area;
    if (infinite) {
      area = viewport;
    } else {
      canvas.drawRect(viewport, Paint()..color = deskColor);
      final docRect = _docRect(doc, viewport);
      area = docRect.intersect(viewport);
      if (area.width <= 0 || area.height <= 0) return;
      // subtle shadow around the document
      canvas.drawRect(
          docRect.inflate(1 / zoom),
          Paint()
            ..color = const Color(0x33000000)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, 4 / zoom));
    }
    canvas.drawRect(area, Paint()..color = bg.color.toUi());
    _paintPattern(canvas, bg, area, zoom);

    if (!infinite && config.format.showBorders) {
      _paintPageBorders(canvas, doc, area, zoom);
    }
    if (config.format.showOriginIndicator &&
        (config.layout == Layout.infinite || config.layout == Layout.semiInfinite)) {
      _paintOrigin(canvas, config.format.borderColor.toUi(), zoom);
    }
  }

  static Rect _docRect(RnoteDocument doc, Rect viewport) {
    final f = doc.config.format;
    switch (doc.config.layout) {
      case Layout.semiInfinite:
        // grows to the right and bottom as the user navigates
        return Rect.fromLTRB(0, 0, math.max(doc.x + doc.width, viewport.right),
            math.max(doc.y + doc.height, viewport.bottom));
      case Layout.continuousVertical:
        return Rect.fromLTWH(0, 0, f.width, math.max(doc.height, f.height));
      default:
        return Rect.fromLTWH(doc.x, doc.y, math.max(doc.width, f.width),
            math.max(doc.height, f.height));
    }
  }

  static void _paintPattern(Canvas canvas, Background bg, Rect area, double zoom) {
    final w = bg.patternSize.dx, h = bg.patternSize.dy;
    if (bg.pattern == PatternStyle.none || w <= 0 || h <= 0) return;
    // too dense to be useful, and expensive
    if (math.min(w, h) * zoom < 5) return;

    final color = bg.patternColor.toUi();
    final linePaint = Paint()
      ..color = color
      ..strokeWidth = math.max(0.5, 1 / zoom)
      ..style = PaintingStyle.stroke;
    final dotPaint = Paint()
      ..color = color
      ..strokeWidth = math.max(1.5 * 2, 2 / zoom)
      ..strokeCap = StrokeCap.round;

    double floorTo(double v, double step) => (v / step).floorToDouble() * step;

    switch (bg.pattern) {
      case PatternStyle.lines:
        final pts = <Offset>[];
        for (var y = floorTo(area.top, h); y <= area.bottom; y += h) {
          if (y < area.top) continue;
          pts
            ..add(Offset(area.left, y))
            ..add(Offset(area.right, y));
        }
        canvas.drawPoints(PointMode.lines, pts, linePaint);
      case PatternStyle.grid:
        final pts = <Offset>[];
        for (var y = floorTo(area.top, h); y <= area.bottom; y += h) {
          if (y < area.top) continue;
          pts
            ..add(Offset(area.left, y))
            ..add(Offset(area.right, y));
        }
        for (var x = floorTo(area.left, w); x <= area.right; x += w) {
          if (x < area.left) continue;
          pts
            ..add(Offset(x, area.top))
            ..add(Offset(x, area.bottom));
        }
        canvas.drawPoints(PointMode.lines, pts, linePaint);
      case PatternStyle.dots:
        final pts = <Offset>[];
        for (var y = floorTo(area.top, h); y <= area.bottom; y += h) {
          for (var x = floorTo(area.left, w); x <= area.right; x += w) {
            if (x >= area.left && y >= area.top) pts.add(Offset(x, y));
          }
        }
        canvas.drawPoints(PointMode.points, pts, dotPaint);
      case PatternStyle.isometricGrid:
        canvas.save();
        canvas.clipRect(area);
        final y0 = floorTo(area.top, h);
        final cot = 1 / math.tan(math.pi / 3);
        final side = 2 * h * cot;
        final pts = <Offset>[];
        for (var y = y0; y <= area.bottom; y += h) {
          pts
            ..add(Offset(area.left, y))
            ..add(Offset(area.right, y));
        }
        // diagonals at +-60 degrees, meeting on the rows
        final span = area.height * cot + side;
        final top = area.top - y0, bottom = area.bottom - y0;
        for (var x = floorTo(area.left - span, side); x <= area.right + span; x += side) {
          pts
            ..add(Offset(x + top * cot, area.top))
            ..add(Offset(x + bottom * cot, area.bottom))
            ..add(Offset(x - top * cot, area.top))
            ..add(Offset(x - bottom * cot, area.bottom));
        }
        canvas.drawPoints(PointMode.lines, pts, linePaint);
        canvas.restore();
      case PatternStyle.isometricDots:
        final pts = <Offset>[];
        final rowH = h;
        var row = (area.top / rowH).floor();
        for (var y = row * rowH; y <= area.bottom; y += rowH, row++) {
          final shift = row.isOdd ? w / 2 : 0.0;
          for (var x = floorTo(area.left, w) + shift; x <= area.right; x += w) {
            if (x >= area.left && y >= area.top) pts.add(Offset(x, y));
          }
        }
        canvas.drawPoints(PointMode.points, pts, dotPaint);
    }
  }

  static void _paintPageBorders(Canvas canvas, RnoteDocument doc, Rect area, double zoom) {
    final f = doc.config.format;
    final paint = Paint()
      ..color = f.borderColor.toUi()
      ..strokeWidth = math.max(1, 2 / zoom)
      ..style = PaintingStyle.stroke;
    if (f.height <= 0 || f.width <= 0) return;
    final pts = <Offset>[];
    for (var y = (area.top / f.height).ceilToDouble() * f.height; y <= area.bottom; y += f.height) {
      pts
        ..add(Offset(area.left, y))
        ..add(Offset(area.right, y));
    }
    if (doc.config.layout != Layout.continuousVertical) {
      for (var x = (area.left / f.width).ceilToDouble() * f.width; x <= area.right; x += f.width) {
        pts
          ..add(Offset(x, area.top))
          ..add(Offset(x, area.bottom));
      }
    }
    canvas.drawPoints(PointMode.lines, pts, paint);
  }

  static void _paintOrigin(Canvas canvas, Color color, double zoom) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2 / zoom
      ..style = PaintingStyle.stroke;
    final l = 12 / zoom;
    canvas.drawLine(Offset(-l, 0), Offset(l, 0), paint);
    canvas.drawLine(Offset(0, -l), Offset(0, l), paint);
  }
}
