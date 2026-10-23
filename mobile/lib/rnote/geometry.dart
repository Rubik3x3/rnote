import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'json_codec.dart';

/// A 2D affine transform, laid out like glam's `DAffine2`:
/// `x' = a*x + c*y + tx`, `y' = b*x + d*y + ty`.
class Affine {
  final double a, b, c, d, tx, ty;

  const Affine(this.a, this.b, this.c, this.d, this.tx, this.ty);

  static const identity = Affine(1, 0, 0, 1, 0, 0);

  factory Affine.translation(Offset o) => Affine(1, 0, 0, 1, o.dx, o.dy);

  factory Affine.scale(double sx, double sy) => Affine(sx, 0, 0, sy, 0, 0);

  /// Reads the transform of an object, accepting both the current format
  /// (`"affine": [6 values]`) and the format of Rnote < 0.15
  /// (`"transform": {"affine": [9 values, column major]}`).
  factory Affine.readFrom(Map<String, dynamic> obj) {
    final affine = obj['affine'];
    if (affine is List && affine.length >= 6) {
      return Affine(toDouble(affine[0]), toDouble(affine[1]), toDouble(affine[2]),
          toDouble(affine[3]), toDouble(affine[4]), toDouble(affine[5]));
    }
    final transform = obj['transform'];
    if (transform is Map && transform['affine'] is List) {
      final m = transform['affine'] as List;
      if (m.length >= 8) {
        return Affine(toDouble(m[0]), toDouble(m[1]), toDouble(m[3]),
            toDouble(m[4]), toDouble(m[6]), toDouble(m[7]));
      }
    }
    return identity;
  }

  List<double> toJson() => [dp3(a), dp3(b), dp3(c), dp3(d), dp3(tx), dp3(ty)];

  Offset get translation => Offset(tx, ty);

  Offset apply(Offset p) => Offset(a * p.dx + c * p.dy + tx, b * p.dx + d * p.dy + ty);

  Offset applyVector(Offset v) => Offset(a * v.dx + c * v.dy, b * v.dx + d * v.dy);

  /// `this * other`: applies [other] first, then this.
  Affine multiply(Affine o) => Affine(
        a * o.a + c * o.b,
        b * o.a + d * o.b,
        a * o.c + c * o.d,
        b * o.c + d * o.d,
        a * o.tx + c * o.ty + tx,
        b * o.tx + d * o.ty + ty,
      );

  Affine translated(Offset o) => Affine(a, b, c, d, tx + o.dx, ty + o.dy);

  double get determinant => a * d - b * c;

  /// Mean scale factor, used to scale stroke widths.
  double get meanScale => math.sqrt(determinant.abs());

  Float64List toMatrix4() => Float64List.fromList(
      [a, b, 0, 0, c, d, 0, 0, 0, 0, 1, 0, tx, ty, 0, 1]);

  /// Transforms a local rectangle and returns the axis aligned bounds.
  Rect mapRect(Rect r) {
    final pts = [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight].map(apply);
    return boundsOfPoints(pts);
  }
}

Rect boundsOfPoints(Iterable<Offset> pts) {
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  for (final p in pts) {
    if (p.dx < minX) minX = p.dx;
    if (p.dy < minY) minY = p.dy;
    if (p.dx > maxX) maxX = p.dx;
    if (p.dy > maxY) maxY = p.dy;
  }
  if (minX == double.infinity) return Rect.zero;
  return Rect.fromLTRB(minX, minY, maxX, maxY);
}

Offset readVec(dynamic v, [Offset fallback = Offset.zero]) {
  if (v is List && v.length >= 2) return Offset(toDouble(v[0]), toDouble(v[1]));
  return fallback;
}

List<double> vecJson(Offset o) => [dp3(o.dx), dp3(o.dy)];

/// Squared distance from [p] to the segment [a]-[b].
double distSqToSegment(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final len2 = ab.distanceSquared;
  if (len2 == 0) return (p - a).distanceSquared;
  var t = ((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / len2;
  t = t.clamp(0.0, 1.0);
  final proj = a + ab * t;
  return (p - proj).distanceSquared;
}

Offset quadPoint(Offset p0, Offset p1, Offset p2, double t) {
  final mt = 1 - t;
  return p0 * (mt * mt) + p1 * (2 * mt * t) + p2 * (t * t);
}

Offset cubicPoint(Offset p0, Offset p1, Offset p2, Offset p3, double t) {
  final mt = 1 - t;
  return p0 * (mt * mt * mt) +
      p1 * (3 * mt * mt * t) +
      p2 * (3 * mt * t * t) +
      p3 * (t * t * t);
}

/// Even-odd point in polygon test.
bool pointInPolygon(Offset p, List<Offset> poly) {
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final pi = poly[i], pj = poly[j];
    if ((pi.dy > p.dy) != (pj.dy > p.dy) &&
        p.dx < (pj.dx - pi.dx) * (p.dy - pi.dy) / (pj.dy - pi.dy) + pi.dx) {
      inside = !inside;
    }
  }
  return inside;
}
