import 'dart:math' as math;
import 'dart:ui';

import 'geometry.dart';
import 'json_codec.dart';

// ---------------------------------------------------------------------------
// Colors
// ---------------------------------------------------------------------------

class RColor {
  final double r, g, b, a;

  const RColor(this.r, this.g, this.b, this.a);

  static const black = RColor(0, 0, 0, 1);
  static const white = RColor(1, 1, 1, 1);
  static const transparent = RColor(0, 0, 0, 0);

  static RColor? maybeFromJson(dynamic j) => j is Map ? RColor.fromJson(j) : null;

  factory RColor.fromJson(dynamic j) {
    if (j is! Map) return black;
    return RColor(toDouble(j['r']), toDouble(j['g']), toDouble(j['b']),
        toDouble(j['a'], 1));
  }

  factory RColor.fromUi(Color c) => RColor(c.r, c.g, c.b, c.a);

  Map<String, dynamic> toJson() => {'r': dp3(r), 'g': dp3(g), 'b': dp3(b), 'a': dp3(a)};

  Color toUi() => Color.from(
      alpha: a.clamp(0, 1), red: r.clamp(0, 1), green: g.clamp(0, 1), blue: b.clamp(0, 1));

  RColor withAlpha(double alpha) => RColor(r, g, b, alpha);

  @override
  bool operator ==(Object other) =>
      other is RColor && other.r == r && other.g == g && other.b == b && other.a == a;

  @override
  int get hashCode => Object.hash(r, g, b, a);
}

// ---------------------------------------------------------------------------
// Styles
// ---------------------------------------------------------------------------

/// Values of Rnote's `PressureCurve`.
abstract final class PressureCurve {
  static const constant = 'const';
  static const linear = 'linear';
  static const sqrt = 'sqrt';
  static const cbrt = 'cbrt';
  static const pow2 = 'pow2';
  static const pow3 = 'pow3';
  static const all = [constant, linear, sqrt, cbrt, pow2, pow3];

  static double apply(String curve, double width, double pressure) {
    switch (curve) {
      case constant:
        return width;
      case sqrt:
        return width * math.sqrt(pressure);
      case cbrt:
        return width * math.pow(pressure, 1 / 3);
      case pow2:
        return width * pressure * pressure;
      case pow3:
        return width * pressure * pressure * pressure;
      case linear:
      default:
        return width * pressure;
    }
  }
}

abstract final class LineStyle {
  static const solid = 'solid';
  static const dotted = 'dotted';
  static const dashedNarrow = 'dashed_narrow';
  static const dashedEquidistant = 'dashed_equidistant';
  static const dashedWide = 'dashed_wide';
  static const all = [solid, dotted, dashedNarrow, dashedEquidistant, dashedWide];

  /// Unscaled dash pattern, mirrors `LineStyle::as_unscaled_vector()`.
  static List<double> unscaled(String style) {
    switch (style) {
      case dotted:
        return [0.0, 1.0];
      case dashedNarrow:
        return [1.0, 0.5];
      case dashedEquidistant:
        return [1.0, 1.0];
      case dashedWide:
        return [1.0, 2.0];
      default:
        return const [];
    }
  }
}

sealed class StrokeStyle {
  const StrokeStyle();

  static StrokeStyle fromJson(dynamic j) {
    if (j is Map) {
      if (j['smooth'] is Map) return SmoothStyle.fromJson(j['smooth']);
      if (j['rough'] is Map) return RoughStyle.fromJson(j['rough']);
      if (j['textured'] is Map) return TexturedStyle.fromJson(j['textured']);
    }
    return const SmoothStyle();
  }

  Map<String, dynamic> toJson();

  double get strokeWidth;
  RColor? get strokeColor;
  RColor? get fillColor => null;

  StrokeStyle withWidth(double w);
  StrokeStyle withColor(RColor? c);
}

class SmoothStyle extends StrokeStyle {
  @override
  final double strokeWidth;
  @override
  final RColor? strokeColor;
  @override
  final RColor? fillColor;
  final String pressureCurve;
  final String lineStyle;
  final String lineCap;

  const SmoothStyle({
    this.strokeWidth = 2.0,
    this.strokeColor = RColor.black,
    this.fillColor,
    this.pressureCurve = PressureCurve.linear,
    this.lineStyle = LineStyle.solid,
    this.lineCap = 'straight',
  });

  factory SmoothStyle.fromJson(Map j) => SmoothStyle(
        strokeWidth: toDouble(j['stroke_width'], 2),
        strokeColor: RColor.maybeFromJson(j['stroke_color']),
        fillColor: RColor.maybeFromJson(j['fill_color']),
        pressureCurve: j['pressure_curve'] as String? ?? PressureCurve.linear,
        lineStyle: j['line_style'] as String? ?? LineStyle.solid,
        lineCap: j['line_cap'] as String? ?? 'straight',
      );

  @override
  Map<String, dynamic> toJson() => {
        'smooth': {
          'stroke_width': dp3(strokeWidth),
          'stroke_color': strokeColor?.toJson(),
          'fill_color': fillColor?.toJson(),
          'pressure_curve': pressureCurve,
          'line_style': lineStyle,
          'line_cap': lineCap,
        }
      };

  SmoothStyle copyWith({
    double? strokeWidth,
    RColor? strokeColor,
    RColor? fillColor,
    bool clearFill = false,
    String? pressureCurve,
    String? lineStyle,
    String? lineCap,
  }) =>
      SmoothStyle(
        strokeWidth: strokeWidth ?? this.strokeWidth,
        strokeColor: strokeColor ?? this.strokeColor,
        fillColor: clearFill ? null : (fillColor ?? this.fillColor),
        pressureCurve: pressureCurve ?? this.pressureCurve,
        lineStyle: lineStyle ?? this.lineStyle,
        lineCap: lineCap ?? this.lineCap,
      );

  @override
  SmoothStyle withWidth(double w) => copyWith(strokeWidth: w);

  @override
  SmoothStyle withColor(RColor? c) => copyWith(strokeColor: c);

  /// The dash pattern, mirrors `SmoothOptions::compute_piet_stroke_style()`.
  List<double> dashPattern() {
    final pattern = LineStyle.unscaled(lineStyle);
    const ratio = math.e;
    final dotted = lineStyle == LineStyle.dotted;
    return [
      for (var i = 0; i < pattern.length; i++)
        (lineCap == 'rounded' && dotted ? pattern[i] : pattern[i] * strokeWidth * ratio) +
            (lineCap == 'rounded' && i.isOdd ? 2 * strokeWidth : 0),
    ];
  }
}

class RoughStyle extends StrokeStyle {
  @override
  final RColor? strokeColor;
  @override
  final double strokeWidth;
  @override
  final RColor? fillColor;
  final String fillStyle;
  final double hachureAngle;
  final U64? seed;

  const RoughStyle({
    this.strokeColor = RColor.black,
    this.strokeWidth = 2.4,
    this.fillColor,
    this.fillStyle = 'hachure',
    this.hachureAngle = -0.715585,
    this.seed,
  });

  factory RoughStyle.fromJson(Map j) => RoughStyle(
        strokeColor: RColor.maybeFromJson(j['stroke_color']),
        strokeWidth: toDouble(j['stroke_width'], 2.4),
        fillColor: RColor.maybeFromJson(j['fill_color']),
        fillStyle: j['fill_style'] as String? ?? 'hachure',
        hachureAngle: toDouble(j['hachure_angle'], -0.715585),
        seed: switch (j['seed']) {
          final U64 s => s,
          final int s => U64.fromInt(s),
          _ => null,
        },
      );

  @override
  Map<String, dynamic> toJson() => {
        'rough': {
          'stroke_color': strokeColor?.toJson(),
          'stroke_width': dp3(strokeWidth),
          'fill_color': fillColor?.toJson(),
          'fill_style': fillStyle,
          'hachure_angle': dp3(hachureAngle),
          'seed': seed,
        }
      };

  @override
  RoughStyle withWidth(double w) => RoughStyle(
      strokeColor: strokeColor,
      strokeWidth: w,
      fillColor: fillColor,
      fillStyle: fillStyle,
      hachureAngle: hachureAngle,
      seed: seed);

  @override
  RoughStyle withColor(RColor? c) => RoughStyle(
      strokeColor: c,
      strokeWidth: strokeWidth,
      fillColor: fillColor,
      fillStyle: fillStyle,
      hachureAngle: hachureAngle,
      seed: seed);
}

class TexturedStyle extends StrokeStyle {
  final U64? seed;
  @override
  final double strokeWidth;
  @override
  final RColor? strokeColor;
  final double density;
  final String distribution;
  final String pressureCurve;

  const TexturedStyle({
    this.seed,
    this.strokeWidth = 6.0,
    this.strokeColor = RColor.black,
    this.density = 5.0,
    this.distribution = 'Normal',
    this.pressureCurve = PressureCurve.linear,
  });

  factory TexturedStyle.fromJson(Map j) => TexturedStyle(
        seed: switch (j['seed']) {
          final U64 s => s,
          final int s => U64.fromInt(s),
          _ => null,
        },
        strokeWidth: toDouble(j['stroke_width'], 6),
        strokeColor: RColor.maybeFromJson(j['stroke_color']),
        density: toDouble(j['density'], 5),
        distribution: j['distribution'] as String? ?? 'Normal',
        pressureCurve: j['pressure_curve'] as String? ?? PressureCurve.linear,
      );

  @override
  Map<String, dynamic> toJson() => {
        'textured': {
          'seed': seed,
          'stroke_width': dp3(strokeWidth),
          'stroke_color': strokeColor?.toJson(),
          'density': dp3(density),
          'distribution': distribution,
          'pressure_curve': pressureCurve,
        }
      };

  @override
  TexturedStyle withWidth(double w) => TexturedStyle(
      seed: seed,
      strokeWidth: w,
      strokeColor: strokeColor,
      density: density,
      distribution: distribution,
      pressureCurve: pressureCurve);

  @override
  TexturedStyle withColor(RColor? c) => TexturedStyle(
      seed: seed,
      strokeWidth: strokeWidth,
      strokeColor: c,
      density: density,
      distribution: distribution,
      pressureCurve: pressureCurve);
}

// ---------------------------------------------------------------------------
// Pen path
// ---------------------------------------------------------------------------

class PathElement {
  final Offset pos;
  final double pressure;

  const PathElement(this.pos, [this.pressure = 0.5]);

  factory PathElement.fromJson(dynamic j) => j is Map
      ? PathElement(readVec(j['pos']), toDouble(j['pressure'], 0.5))
      : const PathElement(Offset.zero);

  Map<String, dynamic> toJson() => {'pos': vecJson(pos), 'pressure': dp3(pressure)};

  PathElement map(Affine t) => PathElement(t.apply(pos), pressure);
}

sealed class Segment {
  const Segment();

  PathElement get end;

  static Segment fromJson(dynamic j) {
    if (j is Map) {
      final line = j['lineto'] ?? j['line'];
      if (line is Map) return LineTo(PathElement.fromJson(line['end']));
      final quad = j['quadbezto'] ?? j['quadbez'];
      if (quad is Map) {
        return QuadBezTo(readVec(quad['cp']), PathElement.fromJson(quad['end']));
      }
      final cub = j['cubbezto'] ?? j['cubbez'];
      if (cub is Map) {
        return CubBezTo(readVec(cub['cp1']), readVec(cub['cp2']),
            PathElement.fromJson(cub['end']));
      }
    }
    return const LineTo(PathElement(Offset.zero));
  }

  Map<String, dynamic> toJson();

  Segment map(Affine t);
}

class LineTo extends Segment {
  @override
  final PathElement end;

  const LineTo(this.end);

  @override
  Map<String, dynamic> toJson() => {
        'lineto': {'end': end.toJson()}
      };

  @override
  LineTo map(Affine t) => LineTo(end.map(t));
}

class QuadBezTo extends Segment {
  final Offset cp;
  @override
  final PathElement end;

  const QuadBezTo(this.cp, this.end);

  @override
  Map<String, dynamic> toJson() => {
        'quadbezto': {'cp': vecJson(cp), 'end': end.toJson()}
      };

  @override
  QuadBezTo map(Affine t) => QuadBezTo(t.apply(cp), end.map(t));
}

class CubBezTo extends Segment {
  final Offset cp1, cp2;
  @override
  final PathElement end;

  const CubBezTo(this.cp1, this.cp2, this.end);

  @override
  Map<String, dynamic> toJson() => {
        'cubbezto': {'cp1': vecJson(cp1), 'cp2': vecJson(cp2), 'end': end.toJson()}
      };

  @override
  CubBezTo map(Affine t) => CubBezTo(t.apply(cp1), t.apply(cp2), end.map(t));
}

class PenPath {
  final PathElement start;
  final List<Segment> segments;

  const PenPath(this.start, this.segments);

  factory PenPath.fromJson(dynamic j) {
    if (j is! Map) return const PenPath(PathElement(Offset.zero), []);
    final segs = j['segments'];
    return PenPath(
      PathElement.fromJson(j['start']),
      segs is List ? [for (final s in segs) Segment.fromJson(s)] : const [],
    );
  }

  factory PenPath.fromElements(List<PathElement> elements) => PenPath(
      elements.first, [for (final e in elements.skip(1)) LineTo(e)]);

  Map<String, dynamic> toJson() => {
        'start': start.toJson(),
        'segments': [for (final s in segments) s.toJson()],
      };

  PenPath map(Affine t) => PenPath(start.map(t), [for (final s in segments) s.map(t)]);

  /// Flattens the path into elements (bezier segments are subdivided).
  List<PathElement> flatten() {
    final out = <PathElement>[start];
    var prev = start;
    for (final seg in segments) {
      switch (seg) {
        case LineTo(:final end):
          out.add(end);
        case QuadBezTo(:final cp, :final end):
          final n = math.max(2, ((prev.pos - end.pos).distance / 4).ceil()).clamp(2, 32);
          for (var i = 1; i <= n; i++) {
            final t = i / n;
            out.add(PathElement(quadPoint(prev.pos, cp, end.pos, t),
                prev.pressure + (end.pressure - prev.pressure) * t));
          }
        case CubBezTo(:final cp1, :final cp2, :final end):
          final n = math.max(2, ((prev.pos - end.pos).distance / 4).ceil()).clamp(2, 32);
          for (var i = 1; i <= n; i++) {
            final t = i / n;
            out.add(PathElement(cubicPoint(prev.pos, cp1, cp2, end.pos, t),
                prev.pressure + (end.pressure - prev.pressure) * t));
          }
      }
      prev = seg.end;
    }
    return out;
  }
}

// ---------------------------------------------------------------------------
// Shapes
// ---------------------------------------------------------------------------

sealed class Shape {
  const Shape();

  static Shape fromJson(dynamic j) {
    if (j is Map) {
      if (j['line'] is Map) {
        final l = j['line'] as Map;
        return LineShape(readVec(l['start']), readVec(l['end']));
      }
      if (j['arrow'] is Map) {
        final a = j['arrow'] as Map;
        return ArrowShape(readVec(a['start']), readVec(a['tip']),
            head: a['head'] as String? ?? 'open');
      }
      if (j['rect'] is Map) return RectShape.fromJson(j['rect']);
      if (j['ellipse'] is Map) {
        final e = j['ellipse'] as Map<String, dynamic>;
        return EllipseShape(readVec(e['radii']), Affine.readFrom(e));
      }
      if (j['quadbez'] is Map) {
        final q = j['quadbez'] as Map;
        return QuadBezShape(readVec(q['start']), readVec(q['cp']), readVec(q['end']));
      }
      if (j['cubbez'] is Map) {
        final c = j['cubbez'] as Map;
        return CubBezShape(readVec(c['start']), readVec(c['cp1']), readVec(c['cp2']),
            readVec(c['end']));
      }
      if (j['polyline'] is Map || j['polygon'] is Map) {
        final closed = j['polygon'] is Map;
        final p = (closed ? j['polygon'] : j['polyline']) as Map;
        final path = p['path'];
        return PolyShape(
          readVec(p['start']),
          path is List ? [for (final v in path) readVec(v)] : const [],
          closed: closed,
        );
      }
    }
    return const LineShape(Offset.zero, Offset.zero);
  }

  Map<String, dynamic> toJson();

  Shape map(Affine t);

  /// The outline of the shape in document coordinates.
  Path toPath();

  /// Polylines approximating the outline, used for hit testing.
  List<List<Offset>> outlinePolylines();

  /// Whether the shape encloses an area that can be filled.
  bool get isClosed => false;

  Rect get bounds => boundsOfPoints(outlinePolylines().expand((e) => e));
}

class LineShape extends Shape {
  final Offset start, end;

  const LineShape(this.start, this.end);

  @override
  Map<String, dynamic> toJson() => {
        'line': {'start': vecJson(start), 'end': vecJson(end)}
      };

  @override
  LineShape map(Affine t) => LineShape(t.apply(start), t.apply(end));

  @override
  Path toPath() => Path()
    ..moveTo(start.dx, start.dy)
    ..lineTo(end.dx, end.dy);

  @override
  List<List<Offset>> outlinePolylines() => [
        [start, end]
      ];
}

class ArrowShape extends Shape {
  final Offset start, tip;
  final String head;

  const ArrowShape(this.start, this.tip, {this.head = 'open'});

  static const _tipLinesDefaultLength = 10.0;
  static const _tipAngle = (13.0 / 16.0) * math.pi;

  @override
  Map<String, dynamic> toJson() => {
        'arrow': {'start': vecJson(start), 'tip': vecJson(tip), 'head': head}
      };

  @override
  ArrowShape map(Affine t) => ArrowShape(t.apply(start), t.apply(tip), head: head);

  (Offset, Offset) headPoints(double strokeWidth) {
    final stem = tip - start;
    final len = stem.distance;
    final dir = len == 0 ? const Offset(1, 0) : stem / len;
    final tipLen = _tipLinesDefaultLength * (1 + 0.18 * strokeWidth);
    Offset rot(Offset v, double a) => Offset(
        v.dx * math.cos(a) - v.dy * math.sin(a), v.dx * math.sin(a) + v.dy * math.cos(a));
    return (rot(dir * tipLen, _tipAngle) + tip, rot(dir * tipLen, -_tipAngle) + tip);
  }

  @override
  Path toPath() => toPathWithWidth(0);

  Path toPathWithWidth(double strokeWidth) {
    final (l, r) = headPoints(strokeWidth);
    final p = Path()
      ..moveTo(start.dx, start.dy)
      ..lineTo(tip.dx, tip.dy)
      ..moveTo(l.dx, l.dy)
      ..lineTo(tip.dx, tip.dy)
      ..lineTo(r.dx, r.dy);
    if (head == 'filled') p.close();
    return p;
  }

  @override
  List<List<Offset>> outlinePolylines() {
    final (l, r) = headPoints(2);
    return [
      [start, tip],
      [l, tip, r]
    ];
  }
}

class RectShape extends Shape {
  final Offset halfExtents;
  final Affine affine;

  const RectShape(this.halfExtents, this.affine);

  factory RectShape.fromJson(dynamic j) {
    if (j is! Map<String, dynamic>) return const RectShape(Offset.zero, Affine.identity);
    final cuboid = j['cuboid'];
    return RectShape(
      cuboid is Map ? readVec(cuboid['half_extents']) : Offset.zero,
      Affine.readFrom(j),
    );
  }

  factory RectShape.fromRect(Rect r) =>
      RectShape(Offset(r.width / 2, r.height / 2), Affine.translation(r.center));

  Map<String, dynamic> toInnerJson() => {
        'cuboid': {'half_extents': vecJson(halfExtents)},
        'affine': affine.toJson(),
      };

  @override
  Map<String, dynamic> toJson() => {'rect': toInnerJson()};

  @override
  RectShape map(Affine t) => RectShape(halfExtents, t.multiply(affine));

  Rect get localRect => Rect.fromLTRB(
      -halfExtents.dx, -halfExtents.dy, halfExtents.dx, halfExtents.dy);

  List<Offset> get corners {
    final r = localRect;
    return [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft].map(affine.apply).toList();
  }

  @override
  bool get isClosed => true;

  @override
  Path toPath() => Path()..addPolygon(corners, true);

  @override
  List<List<Offset>> outlinePolylines() => [
        [...corners, corners.first]
      ];
}

class EllipseShape extends Shape {
  final Offset radii;
  final Affine affine;

  const EllipseShape(this.radii, this.affine);

  @override
  Map<String, dynamic> toJson() => {
        'ellipse': {'radii': vecJson(radii), 'affine': affine.toJson()}
      };

  @override
  EllipseShape map(Affine t) => EllipseShape(radii, t.multiply(affine));

  @override
  bool get isClosed => true;

  @override
  Path toPath() => (Path()
        ..addOval(Rect.fromCenter(
            center: Offset.zero, width: radii.dx * 2, height: radii.dy * 2)))
      .transform(affine.toMatrix4());

  @override
  List<List<Offset>> outlinePolylines() {
    const n = 48;
    return [
      [
        for (var i = 0; i <= n; i++)
          affine.apply(Offset(radii.dx * math.cos(2 * math.pi * i / n),
              radii.dy * math.sin(2 * math.pi * i / n)))
      ]
    ];
  }
}

class QuadBezShape extends Shape {
  final Offset start, cp, end;

  const QuadBezShape(this.start, this.cp, this.end);

  @override
  Map<String, dynamic> toJson() => {
        'quadbez': {'start': vecJson(start), 'cp': vecJson(cp), 'end': vecJson(end)}
      };

  @override
  QuadBezShape map(Affine t) => QuadBezShape(t.apply(start), t.apply(cp), t.apply(end));

  @override
  Path toPath() => Path()
    ..moveTo(start.dx, start.dy)
    ..quadraticBezierTo(cp.dx, cp.dy, end.dx, end.dy);

  @override
  List<List<Offset>> outlinePolylines() => [
        [for (var i = 0; i <= 24; i++) quadPoint(start, cp, end, i / 24)]
      ];
}

class CubBezShape extends Shape {
  final Offset start, cp1, cp2, end;

  const CubBezShape(this.start, this.cp1, this.cp2, this.end);

  @override
  Map<String, dynamic> toJson() => {
        'cubbez': {
          'start': vecJson(start),
          'cp1': vecJson(cp1),
          'cp2': vecJson(cp2),
          'end': vecJson(end),
        }
      };

  @override
  CubBezShape map(Affine t) =>
      CubBezShape(t.apply(start), t.apply(cp1), t.apply(cp2), t.apply(end));

  @override
  Path toPath() => Path()
    ..moveTo(start.dx, start.dy)
    ..cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, end.dx, end.dy);

  @override
  List<List<Offset>> outlinePolylines() => [
        [for (var i = 0; i <= 32; i++) cubicPoint(start, cp1, cp2, end, i / 32)]
      ];
}

class PolyShape extends Shape {
  final Offset start;
  final List<Offset> path;
  final bool closed;

  const PolyShape(this.start, this.path, {this.closed = false});

  @override
  Map<String, dynamic> toJson() => {
        closed ? 'polygon' : 'polyline': {
          'start': [start.dx, start.dy],
          'path': [
            for (final p in path) [p.dx, p.dy]
          ],
        }
      };

  @override
  PolyShape map(Affine t) =>
      PolyShape(t.apply(start), [for (final p in path) t.apply(p)], closed: closed);

  @override
  bool get isClosed => closed;

  @override
  Path toPath() => Path()..addPolygon([start, ...path], closed);

  @override
  List<List<Offset>> outlinePolylines() => [
        [start, ...path, if (closed) start]
      ];
}

// ---------------------------------------------------------------------------
// Strokes
// ---------------------------------------------------------------------------

/// Base class of all strokes.
///
/// Strokes are immutable. Strokes loaded from a file keep their original JSON
/// in [raw], which is written back unchanged if the stroke was not modified,
/// so that data this app does not understand is never lost.
sealed class Stroke {
  final Map<String, dynamic>? raw;
  final bool modified;

  const Stroke({this.raw, this.modified = true});

  String get tag;

  Map<String, dynamic> innerJson();

  Map<String, dynamic> toJson() {
    final inner = raw == null
        ? innerJson()
        : (modified ? mergeJson(raw, innerJson()) as Map<String, dynamic> : raw!);
    return {tag: inner};
  }

  static Stroke fromJson(Map<String, dynamic> j) {
    final (tag, value) = (j.keys.first, j.values.first);
    if (value is! Map<String, dynamic>) return UnknownStroke(j);
    switch (tag) {
      case 'brushstroke':
        return BrushStroke(PenPath.fromJson(value['path']),
            StrokeStyle.fromJson(value['style']),
            raw: value, modified: false);
      case 'shapestroke':
        return ShapeStroke(
            Shape.fromJson(value['shape']), StrokeStyle.fromJson(value['style']),
            raw: value, modified: false);
      case 'textstroke':
        return TextStroke(
          value['text'] as String? ?? '',
          Affine.readFrom(value),
          TextStyleData.fromJson(value['text_style']),
          raw: value,
          modified: false,
        );
      case 'vectorimage':
        return VectorImageStroke(
          value['svg_data'] as String? ?? '',
          readVec(value['intrinsic_size']),
          RectShape.fromJson(value['rectangle']),
          raw: value,
          modified: false,
        );
      case 'bitmapimage':
        final image = value['image'] as Map<String, dynamic>? ?? const {};
        return BitmapImageStroke(
          dataBase64: image['data'] as String? ?? '',
          pixelWidth: toInt(image['pixel_width']),
          pixelHeight: toInt(image['pixel_height']),
          imageRectangle: RectShape.fromJson(image['rectangle']),
          rectangle: RectShape.fromJson(value['rectangle']),
          raw: value,
          modified: false,
        );
      default:
        return UnknownStroke(j);
    }
  }

  /// Returns a copy with the transform applied to all geometry.
  /// Stroke widths are scaled if [scaleWidths] is set.
  Stroke transformed(Affine t, {bool scaleWidths = false});

  /// Bounds including the stroke width.
  Rect get bounds;

  /// Whether the stroke is hit by a circle at [p] with [radius].
  bool hitTest(Offset p, double radius);

  /// Points used to test whether a stroke is inside a lasso selection.
  List<Offset> get selectionPoints;

  Stroke recolored(RColor color) => this;
}

class BrushStroke extends Stroke {
  final PenPath path;
  final StrokeStyle style;

  BrushStroke(this.path, this.style, {super.raw, super.modified});

  @override
  String get tag => 'brushstroke';

  @override
  Map<String, dynamic> innerJson() => {'path': path.toJson(), 'style': style.toJson()};

  late final List<PathElement> flattened = path.flatten();

  @override
  late final Rect bounds =
      boundsOfPoints(flattened.map((e) => e.pos)).inflate(style.strokeWidth * 0.5 + 1);

  @override
  BrushStroke transformed(Affine t, {bool scaleWidths = false}) => BrushStroke(
      path.map(t), scaleWidths ? style.withWidth(style.strokeWidth * t.meanScale) : style,
      raw: raw);

  @override
  bool hitTest(Offset p, double radius) {
    if (!bounds.inflate(radius).contains(p)) return false;
    final r = radius + style.strokeWidth * 0.5;
    final r2 = r * r;
    final pts = flattened;
    if (pts.length == 1) return (pts.first.pos - p).distanceSquared <= r2;
    for (var i = 1; i < pts.length; i++) {
      if (distSqToSegment(p, pts[i - 1].pos, pts[i].pos) <= r2) return true;
    }
    return false;
  }

  @override
  List<Offset> get selectionPoints => [for (final e in flattened) e.pos];

  @override
  BrushStroke recolored(RColor color) => BrushStroke(path, style.withColor(color), raw: raw);
}

class ShapeStroke extends Stroke {
  final Shape shape;
  final StrokeStyle style;

  ShapeStroke(this.shape, this.style, {super.raw, super.modified});

  @override
  String get tag => 'shapestroke';

  @override
  Map<String, dynamic> innerJson() => {'shape': shape.toJson(), 'style': style.toJson()};

  @override
  late final Rect bounds = shape.bounds.inflate(style.strokeWidth + 8);

  @override
  ShapeStroke transformed(Affine t, {bool scaleWidths = false}) => ShapeStroke(
      shape.map(t), scaleWidths ? style.withWidth(style.strokeWidth * t.meanScale) : style,
      raw: raw);

  @override
  bool hitTest(Offset p, double radius) {
    if (!bounds.inflate(radius).contains(p)) return false;
    final r = radius + style.strokeWidth * 0.5;
    for (final line in shape.outlinePolylines()) {
      for (var i = 1; i < line.length; i++) {
        if (distSqToSegment(p, line[i - 1], line[i]) <= r * r) return true;
      }
    }
    if (shape.isClosed && style.fillColor != null && style.fillColor!.a > 0) {
      return pointInPolygon(p, shape.outlinePolylines().first);
    }
    return false;
  }

  @override
  List<Offset> get selectionPoints => shape.outlinePolylines().expand((e) => e).toList();

  @override
  ShapeStroke recolored(RColor color) => ShapeStroke(shape, style.withColor(color), raw: raw);
}

class TextStyleData {
  final String fontFamily;
  final double fontSize;
  final int fontWeight;
  final String fontStyle;
  final RColor color;
  final double? maxWidth;
  final String alignment;
  final List<dynamic> rangedAttributes;

  const TextStyleData({
    this.fontFamily = 'sans-serif',
    this.fontSize = 32,
    this.fontWeight = 500,
    this.fontStyle = 'regular',
    this.color = RColor.black,
    this.maxWidth,
    this.alignment = 'start',
    this.rangedAttributes = const [],
  });

  factory TextStyleData.fromJson(dynamic j) {
    if (j is! Map) return const TextStyleData();
    return TextStyleData(
      fontFamily: j['font_family'] as String? ?? 'serif',
      fontSize: toDouble(j['font_size'], 32),
      fontWeight: toInt(j['font_weight'], 500),
      fontStyle: j['font_style'] as String? ?? 'regular',
      color: RColor.fromJson(j['color']),
      maxWidth: j['max_width'] is num ? toDouble(j['max_width']) : null,
      alignment: j['alignment'] as String? ?? 'start',
      rangedAttributes: j['ranged_text_attributes'] is List
          ? j['ranged_text_attributes'] as List
          : const [],
    );
  }

  Map<String, dynamic> toJson() => {
        'font_family': fontFamily,
        'font_size': fontSize,
        'font_weight': fontWeight,
        'font_style': fontStyle,
        'color': color.toJson(),
        'max_width': maxWidth,
        'alignment': alignment,
        'ranged_text_attributes': deepCopyJson(rangedAttributes),
      };

  TextStyleData copyWith({
    String? fontFamily,
    double? fontSize,
    int? fontWeight,
    String? fontStyle,
    RColor? color,
    double? maxWidth,
    String? alignment,
    List<dynamic>? rangedAttributes,
  }) =>
      TextStyleData(
        fontFamily: fontFamily ?? this.fontFamily,
        fontSize: fontSize ?? this.fontSize,
        fontWeight: fontWeight ?? this.fontWeight,
        fontStyle: fontStyle ?? this.fontStyle,
        color: color ?? this.color,
        maxWidth: maxWidth ?? this.maxWidth,
        alignment: alignment ?? this.alignment,
        rangedAttributes: rangedAttributes ?? this.rangedAttributes,
      );
}

class TextStroke extends Stroke {
  final String text;
  final Affine affine;
  final TextStyleData style;

  TextStroke(this.text, this.affine, this.style, {super.raw, super.modified});

  @override
  String get tag => 'textstroke';

  @override
  Map<String, dynamic> innerJson() =>
      {'text': text, 'affine': affine.toJson(), 'text_style': style.toJson()};

  /// Size of the laid out text in local coordinates, set by the renderer.
  static final Expando<Size> layoutSize = Expando('textLayoutSize');

  Size get _approxSize {
    final known = layoutSize[this];
    if (known != null) return known;
    final lines = text.split('\n');
    final longest = lines.fold<int>(0, (m, l) => math.max(m, l.length));
    var w = longest * style.fontSize * 0.55;
    if (style.maxWidth != null) w = math.min(w, style.maxWidth!);
    return Size(math.max(w, style.fontSize), lines.length * style.fontSize * 1.25);
  }

  @override
  Rect get bounds => affine.mapRect(Offset.zero & _approxSize);

  @override
  TextStroke transformed(Affine t, {bool scaleWidths = false}) =>
      TextStroke(text, t.multiply(affine), style, raw: raw);

  @override
  bool hitTest(Offset p, double radius) => bounds.inflate(radius).contains(p);

  @override
  List<Offset> get selectionPoints {
    final r = bounds;
    return [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight, r.center];
  }

  @override
  TextStroke recolored(RColor color) =>
      TextStroke(text, affine, style.copyWith(color: color), raw: raw);
}

class VectorImageStroke extends Stroke {
  final String svgData;
  final Offset intrinsicSize;
  final RectShape rectangle;

  VectorImageStroke(this.svgData, this.intrinsicSize, this.rectangle,
      {super.raw, super.modified});

  @override
  String get tag => 'vectorimage';

  @override
  Map<String, dynamic> innerJson() => {
        'svg_data': svgData,
        'intrinsic_size': vecJson(intrinsicSize),
        'rectangle': rectangle.toInnerJson(),
      };

  @override
  late final Rect bounds = rectangle.bounds;

  @override
  VectorImageStroke transformed(Affine t, {bool scaleWidths = false}) =>
      VectorImageStroke(svgData, intrinsicSize, rectangle.map(t), raw: raw);

  @override
  bool hitTest(Offset p, double radius) =>
      bounds.inflate(radius).contains(p) && pointInPolygon(p, rectangle.corners);

  @override
  List<Offset> get selectionPoints => [...rectangle.corners, bounds.center];
}

class BitmapImageStroke extends Stroke {
  /// Base64 encoded premultiplied RGBA8 pixels.
  final String dataBase64;
  final int pixelWidth, pixelHeight;
  final RectShape imageRectangle;
  final RectShape rectangle;

  BitmapImageStroke({
    required this.dataBase64,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.imageRectangle,
    required this.rectangle,
    super.raw,
    super.modified,
  });

  @override
  String get tag => 'bitmapimage';

  @override
  Map<String, dynamic> innerJson() => {
        'image': {
          'data': dataBase64,
          'rectangle': imageRectangle.toInnerJson(),
          'pixel_width': pixelWidth,
          'pixel_height': pixelHeight,
          'memory_format': 'R8g8b8a8Premultiplied',
        },
        'rectangle': rectangle.toInnerJson(),
      };

  /// Like [Stroke.toJson], but avoids copying the (large) pixel data.
  @override
  Map<String, dynamic> toJson() {
    if (raw != null && !modified) return {tag: raw!};
    final inner = innerJson();
    if (raw != null) {
      final rawImage = Map<String, dynamic>.of(raw!['image'] as Map<String, dynamic>? ?? {})
        ..remove('data');
      final merged = mergeJson({...raw!, 'image': rawImage}, {
        ...inner,
        'image': {...(inner['image'] as Map<String, dynamic>)}..remove('data'),
      }) as Map<String, dynamic>;
      (merged['image'] as Map<String, dynamic>)['data'] = dataBase64;
      return {tag: merged};
    }
    return {tag: inner};
  }

  @override
  late final Rect bounds = rectangle.bounds;

  @override
  BitmapImageStroke transformed(Affine t, {bool scaleWidths = false}) => BitmapImageStroke(
        dataBase64: dataBase64,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        imageRectangle: imageRectangle,
        rectangle: rectangle.map(t),
        raw: raw,
      );

  @override
  bool hitTest(Offset p, double radius) =>
      bounds.inflate(radius).contains(p) && pointInPolygon(p, rectangle.corners);

  @override
  List<Offset> get selectionPoints => [...rectangle.corners, bounds.center];
}

/// A stroke type unknown to this app. Preserved, but not rendered.
class UnknownStroke extends Stroke {
  final Map<String, dynamic> original;

  UnknownStroke(this.original) : super(modified: false);

  @override
  String get tag => original.keys.first;

  @override
  Map<String, dynamic> innerJson() => const {};

  @override
  Map<String, dynamic> toJson() => original;

  @override
  Rect get bounds => Rect.zero;

  @override
  UnknownStroke transformed(Affine t, {bool scaleWidths = false}) => this;

  @override
  bool hitTest(Offset p, double radius) => false;

  @override
  List<Offset> get selectionPoints => const [];
}

// ---------------------------------------------------------------------------
// Layers and chrono components
// ---------------------------------------------------------------------------

enum LayerKind { document, image, user, highlighter }

class StrokeLayer {
  final LayerKind kind;
  final int index;

  const StrokeLayer(this.kind, [this.index = 0]);

  static const user0 = StrokeLayer(LayerKind.user);
  static const highlighter = StrokeLayer(LayerKind.highlighter);
  static const image = StrokeLayer(LayerKind.image);

  factory StrokeLayer.fromJson(dynamic j) {
    if (j is Map) {
      final l = j['user_layer'] ?? j['UserLayer'];
      return StrokeLayer(LayerKind.user, toInt(l));
    }
    switch (j) {
      case 'highlighter' || 'Highlighter':
        return highlighter;
      case 'image' || 'Image':
        return image;
      case 'document' || 'Document':
        return const StrokeLayer(LayerKind.document);
    }
    return user0;
  }

  dynamic toJson() => switch (kind) {
        LayerKind.user => {'user_layer': index},
        LayerKind.highlighter => 'highlighter',
        LayerKind.image => 'image',
        LayerKind.document => 'document',
      };

  /// Rendering order key, mirrors `impl Ord for StrokeLayer`.
  int get order => switch (kind) {
        LayerKind.document => 0,
        LayerKind.image => 1,
        LayerKind.user => 2 + index,
        LayerKind.highlighter => 1 << 40,
      };
}

class StrokeEntry {
  final Stroke stroke;
  final StrokeLayer layer;
  final int t;

  const StrokeEntry(this.stroke, this.layer, this.t);

  StrokeEntry withStroke(Stroke s) => StrokeEntry(s, layer, t);
}

// ---------------------------------------------------------------------------
// Document
// ---------------------------------------------------------------------------

abstract final class Layout {
  static const fixedSize = 'fixed_size';
  static const continuousVertical = 'continuous_vertical';
  static const semiInfinite = 'semi_infinite';
  static const infinite = 'infinite';
  static const all = [fixedSize, continuousVertical, semiInfinite, infinite];
}

abstract final class PatternStyle {
  static const none = 'none';
  static const lines = 'lines';
  static const grid = 'grid';
  static const dots = 'dots';
  static const isometricGrid = 'isometric_grid';
  static const isometricDots = 'isometric_dots';
  static const all = [none, lines, grid, dots, isometricGrid, isometricDots];
}

class DocFormat {
  final double width, height, dpi;
  final String orientation;
  final RColor borderColor;
  final bool showBorders;
  final bool showOriginIndicator;

  const DocFormat({
    this.width = 793.701,
    this.height = 1122.52,
    this.dpi = 96,
    this.orientation = 'portrait',
    this.borderColor = const RColor(0.871, 0.867, 0.855, 1),
    this.showBorders = true,
    this.showOriginIndicator = true,
  });

  factory DocFormat.fromJson(dynamic j) {
    if (j is! Map) return const DocFormat();
    return DocFormat(
      width: toDouble(j['width'], 793.701),
      height: toDouble(j['height'], 1122.52),
      dpi: toDouble(j['dpi'], 96),
      orientation: j['orientation'] as String? ?? 'portrait',
      borderColor: j['border_color'] is Map
          ? RColor.fromJson(j['border_color'])
          : const RColor(0.871, 0.867, 0.855, 1),
      showBorders: j['show_borders'] as bool? ?? true,
      showOriginIndicator: j['show_origin_indicator'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
        'width': dp3(width),
        'height': dp3(height),
        'dpi': dp3(dpi),
        'orientation': orientation,
        'border_color': borderColor.toJson(),
        'show_borders': showBorders,
        'show_origin_indicator': showOriginIndicator,
      };

  DocFormat copyWith({
    double? width,
    double? height,
    String? orientation,
    bool? showBorders,
    bool? showOriginIndicator,
  }) =>
      DocFormat(
        width: width ?? this.width,
        height: height ?? this.height,
        dpi: dpi,
        orientation: orientation ?? this.orientation,
        borderColor: borderColor,
        showBorders: showBorders ?? this.showBorders,
        showOriginIndicator: showOriginIndicator ?? this.showOriginIndicator,
      );
}

class Background {
  final RColor color;
  final String pattern;
  final Offset patternSize;
  final RColor patternColor;

  const Background({
    this.color = RColor.white,
    this.pattern = PatternStyle.dots,
    this.patternSize = const Offset(32, 32),
    this.patternColor = const RColor(0.8, 0.9, 1.0, 1.0),
  });

  factory Background.fromJson(dynamic j) {
    if (j is! Map) return const Background();
    return Background(
      color: j['color'] is Map ? RColor.fromJson(j['color']) : RColor.white,
      pattern: j['pattern'] as String? ?? PatternStyle.dots,
      patternSize: readVec(j['pattern_size'], const Offset(32, 32)),
      patternColor: j['pattern_color'] is Map
          ? RColor.fromJson(j['pattern_color'])
          : const RColor(0.8, 0.9, 1.0, 1.0),
    );
  }

  Map<String, dynamic> toJson() => {
        'color': color.toJson(),
        'pattern': pattern,
        'pattern_size': vecJson(patternSize),
        'pattern_color': patternColor.toJson(),
      };

  Background copyWith({
    RColor? color,
    String? pattern,
    Offset? patternSize,
    RColor? patternColor,
  }) =>
      Background(
        color: color ?? this.color,
        pattern: pattern ?? this.pattern,
        patternSize: patternSize ?? this.patternSize,
        patternColor: patternColor ?? this.patternColor,
      );
}

class DocConfig {
  final DocFormat format;
  final Background background;
  final String layout;
  final Map<String, dynamic>? raw;

  const DocConfig({
    this.format = const DocFormat(),
    this.background = const Background(),
    this.layout = Layout.infinite,
    this.raw,
  });

  factory DocConfig.fromJson(dynamic j) {
    if (j is! Map<String, dynamic>) return const DocConfig();
    return DocConfig(
      format: DocFormat.fromJson(j['format']),
      background: Background.fromJson(j['background']),
      layout: switch ((j['layout'] ?? j['expand_mode']) as String?) {
        'endless_vertical' => Layout.continuousVertical,
        final String l when Layout.all.contains(l) => l,
        _ => Layout.infinite,
      },
      raw: j,
    );
  }

  Map<String, dynamic> toJson() {
    final own = {
      'format': format.toJson(),
      'background': background.toJson(),
      'layout': layout,
    };
    if (raw == null) return own;
    final merged = mergeJson(raw, own) as Map<String, dynamic>..remove('expand_mode');
    return merged;
  }

  DocConfig copyWith({DocFormat? format, Background? background, String? layout}) => DocConfig(
        format: format ?? this.format,
        background: background ?? this.background,
        layout: layout ?? this.layout,
        raw: raw,
      );
}

class CameraState {
  /// Offset in surface coordinates: `surface = doc * zoom - offset`.
  Offset offset;
  Size size;
  double zoom;

  CameraState({this.offset = const Offset(-64, -64), this.size = const Size(800, 600), this.zoom = 1});

  factory CameraState.fromJson(dynamic j) {
    if (j is! Map) return CameraState();
    final s = readVec(j['size'], const Offset(800, 600));
    return CameraState(
      offset: readVec(j['offset'], const Offset(-64, -64)),
      size: Size(s.dx, s.dy),
      zoom: toDouble(j['zoom'], 1).clamp(0.05, 20),
    );
  }

  Map<String, dynamic> toJson() => {
        'offset': [offset.dx, offset.dy],
        'size': [size.width, size.height],
        'zoom': zoom,
      };

  Offset docToScreen(Offset p) => p * zoom - offset;

  Offset screenToDoc(Offset p) => (p + offset) / zoom;

  Rect get viewport => Rect.fromPoints(screenToDoc(Offset.zero),
      screenToDoc(Offset(size.width, size.height)));
}

class RnoteDocument {
  DocConfig config;
  double x, y, width, height;
  CameraState camera;
  List<StrokeEntry> strokes;
  int chronoCounter;

  /// Unknown fields of the engine snapshot, kept for round tripping.
  final Map<String, dynamic> extraSnapshotFields;

  RnoteDocument({
    this.config = const DocConfig(),
    this.x = 0,
    this.y = 0,
    this.width = 793.701,
    this.height = 1122.52,
    CameraState? camera,
    List<StrokeEntry>? strokes,
    this.chronoCounter = 0,
    Map<String, dynamic>? extraSnapshotFields,
  })  : camera = camera ?? CameraState(),
        strokes = strokes ?? [],
        extraSnapshotFields = extraSnapshotFields ?? {};

  Rect get bounds => Rect.fromLTWH(x, y, width, height);

  int nextChrono() => ++chronoCounter;

  void sortStrokes() {
    strokes.sort((a, b) {
      final c = a.layer.order.compareTo(b.layer.order);
      return c != 0 ? c : a.t.compareTo(b.t);
    });
  }

  Rect? contentBounds() {
    Rect? r;
    for (final e in strokes) {
      final b = e.stroke.bounds;
      if (b.isEmpty && b == Rect.zero) continue;
      r = r == null ? b : r.expandToInclude(b);
    }
    return r;
  }

  /// Resizes the document to fit its content, like
  /// `Document::resize_to_fit_content()` does.
  void resizeToFitContent() {
    final f = config.format;
    final content = contentBounds();
    final contentHeight = content?.bottom ?? 0;
    switch (config.layout) {
      case Layout.fixedSize:
        x = 0;
        y = 0;
        width = f.width;
        height = (math.max(contentHeight, 1) / f.height).ceil() * f.height;
      case Layout.continuousVertical:
        x = 0;
        y = 0;
        width = f.width;
        height = math.max(contentHeight, 0) + f.height;
      case Layout.semiInfinite:
        final pad = Offset(f.width * 2, f.height * 2);
        final c = content ?? Rect.fromLTWH(0, 0, f.width, f.height);
        final vp = camera.viewport;
        x = 0;
        y = 0;
        width = math.max(math.max(c.right, vp.right) + pad.dx, f.width);
        height = math.max(math.max(c.bottom, vp.bottom) + pad.dy, f.height);
      default:
        final pad = Offset(f.width * 2, f.height * 2);
        var c = (content ?? Rect.fromLTWH(0, 0, f.width, f.height)).expandToInclude(camera.viewport);
        c = Rect.fromLTRB(c.left - pad.dx, c.top - pad.dy, c.right + pad.dx, c.bottom + pad.dy);
        x = c.left;
        y = c.top;
        width = c.width;
        height = c.height;
    }
  }
}
