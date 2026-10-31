import 'dart:math' as math;
import 'dart:ui';

/// Recognition of hand-drawn strokes as ideal shapes, the same as in the desktop app.
///
/// Strokes are classified from their geometry alone: lines (snapped to horizontal and vertical), polylines, arcs,
/// parabolas, cubics, triangles, rectangles, squares, regular polygons, stars, circles and ellipses. Strokes that
/// match none of them are smoothed. Tolerances are relative to the stroke size, so the zoom doesn't matter.

enum RecognizedKind {
  line,
  polyline,
  arc,
  parabola,
  cubic,
  curve,
  triangle,
  rectangle,
  square,
  quadrilateral,
  pentagon,
  hexagon,
  polygon,
  star,
  circle,
  ellipse,
  closedCurve;

  bool get closed => index >= RecognizedKind.triangle.index;
}

/// A recognized shape, as a dense outline.
class RecognizedShape {
  RecognizedShape(this.kind, this.points);

  final RecognizedKind kind;
  final List<Offset> points;

  static const _samples = 128;
  static const _axisSnapTol = 10 * math.pi / 180;
  static const _cornerAngleMin = 38 * math.pi / 180;
  static const _closeTol = 0.2;
  static const _closeWinding = 1.25 * math.pi;
  static const _closeGapMax = 0.6;
  static const _closedFitTol = 0.05;
  static const _circlePreference = 0.75;
  static const _hookAngle = 50 * math.pi / 180;

  /// How much a circle may be squashed and still become a circle instead of an ellipse, by default.
  static const circleToleranceDefault = 0.25;
  static const _curveFitTol = 0.012;

  /// How far the outlines may deviate from the ideal curves by default, in document units.
  static const flatnessDefault = 0.05;

  /// How far the outlines may deviate from the ideal curves, set for each recognition.
  static double _flatness = flatnessDefault;

  Offset get start => points.first;
  Offset get end => points.last;

  Offset get center {
    final b = _bounds(points);
    return b.center;
  }

  /// Recognizes the shape of a stroke. [minSize] is the smallest diagonal a stroke must have.
  ///
  /// [circleTolerance] is how much a circle may be squashed and still become a circle instead of an ellipse.
  /// [flatness] is how far the outline may deviate from the ideal curves, keeps them smooth when zoomed in.
  static RecognizedShape? recognize(
    List<Offset> input,
    double minSize, {
    double circleTolerance = circleToleranceDefault,
    double flatness = flatnessDefault,
  }) {
    _flatness = math.max(flatness, 1e-4);
    final pts0 = _dedup(input);
    if (pts0.length < 2) return null;
    final b = _bounds(pts0);
    final diag = Offset(b.width, b.height).distance;
    if (!diag.isFinite || diag < math.max(minSize, 1e-6)) return null;
    final pts = _resample(pts0, _samples);
    final drawn = _closedPart(pts, diag);
    final shape = drawn != null
        ? _recognizeClosed(_resampleClosed(drawn, _samples), _resample(drawn, _samples), diag, circleTolerance)
        : _recognizeOpen(pts, diag);
    return RecognizedShape(shape.kind, _densify(shape.points, math.max(diag / 64, 1.5)));
  }

  /// The shape adjusted to a pen that moved from [anchor] to [pos] after recognition.
  ///
  /// Lines end at the pen and keep snapping, other open shapes rotate and scale around their start so their end
  /// follows the pen, closed shapes scale around their center.
  RecognizedShape adjusted(Offset anchor, Offset pos) {
    if (kind == RecognizedKind.line) {
      return RecognizedShape(kind, _densify([start, _snapLineEnd(start, pos)], 4));
    }
    if (kind.closed) {
      final c = center;
      final from = (anchor - c).distance;
      if (from < 1e-6) return this;
      final s = math.max((pos - c).distance / from, 0.05);
      return RecognizedShape(kind, [for (final p in points) c + (p - c) * s]);
    }
    final from = anchor - start, to = pos - start;
    if (from.distance < 1e-6 || to.distance < 1e-6) return this;
    final s = to.distance / from.distance;
    final a = to.direction - from.direction;
    final cosA = math.cos(a) * s, sinA = math.sin(a) * s;
    return RecognizedShape(kind, [
      for (final p in points)
        start +
            Offset(
              (p.dx - start.dx) * cosA - (p.dy - start.dy) * sinA,
              (p.dx - start.dx) * sinA + (p.dy - start.dy) * cosA,
            ),
    ]);
  }

  // -------------------------------------------------------------------------

  static _Shape? _lineShape(List<Offset> pts) {
    final first = pts.first, last = pts.last;
    final chord = (last - first).distance;
    if (chord <= 0 || _length(pts) > 1.2 * chord) return null;
    final maxDev = pts.map((p) => _distToLine(p, first, last)).fold(0.0, math.max);
    return maxDev <= 0.07 * chord ? _Shape(RecognizedKind.line, [first, _snapLineEnd(first, last)]) : null;
  }

  /// The range of the stroke without the hooks where the pen landed or lifted: sharp turns close to its ends.
  static (int, int) _withoutHooks(List<Offset> pts) {
    final n = pts.length;
    final k = math.max(n ~/ 40, 2);
    final zone = n ~/ 10;
    if (zone <= k || n < 4 * zone) return (0, n - 1);
    int? sharpest(int from, int to) {
      int? best;
      var bestTurn = _hookAngle;
      for (var i = from; i <= to; i++) {
        final t = _turning(pts, i, k, false).abs();
        if (t >= bestTurn) {
          best = i;
          bestTurn = t;
        }
      }
      return best;
    }

    return (sharpest(k, zone) ?? 0, sharpest(n - 1 - zone, n - 1 - k) ?? n - 1);
  }

  static _Shape _recognizeOpen(List<Offset> input, double diag) {
    final line = _lineShape(input);
    if (line != null) return line;

    // leave out the hooks where the pen landed or lifted
    final (hookFrom, hookTo) = _withoutHooks(input);
    final pts = input.sublist(hookFrom, hookTo + 1);
    if (hookFrom != 0 || hookTo != input.length - 1) {
      final line = _lineShape(pts);
      if (line != null) return line;
    }

    // polyline, without the corners right at the ends
    final k = math.max(pts.length ~/ 40, 2);
    final corners = _findCorners(pts, k, false);
    final hook = pts.length * 8 ~/ 100;
    var from = 0, to = pts.length - 1;
    if (corners.isNotEmpty && corners.first <= hook) from = corners.removeAt(0);
    if (corners.isNotEmpty && corners.last + hook >= pts.length - 1) to = corners.removeLast();
    final trimmed = pts.sublist(from, to + 1);
    if (corners.isEmpty && (from != 0 || to != pts.length - 1)) {
      final line = _lineShape(trimmed);
      if (line != null) return line;
    } else if (corners.isNotEmpty && corners.length <= 4) {
      final bounds = [0, for (final c in corners) c - from, trimmed.length - 1];
      final vertices = _fitPolyline(trimmed, bounds, k, diag);
      if (vertices != null) return _Shape(RecognizedKind.polyline, vertices);
    }

    // arc and function graphs, the best fit wins
    (double, _Shape)? best;
    void consider((double, _Shape)? fit) {
      if (fit != null && (best == null || fit.$1 < best!.$1)) best = fit;
    }

    consider(_fitArc(pts, diag));
    for (final axis in [true, false]) {
      for (final fit in _fitFunction(pts, axis, diag)) {
        consider(fit);
      }
    }
    if (best != null) return best!.$2;

    return _Shape(RecognizedKind.curve, _smoothCurve(pts, diag));
  }

  /// Smooths an open stroke between its key points: the ends, and the peaks and valleys where it turns back
  /// horizontally or vertically. Key points stay where they were drawn, peaks and valleys get a level tangent.
  static List<Offset> _smoothCurve(List<Offset> pts, double diag) {
    final n = pts.length;
    final heavy = _smooth(pts, 4, false);
    // positions of key points, smoothed only lightly so peaks are not flattened
    final light = _smooth(pts, 1, false);
    final prominence = 0.04 * diag;
    const margin = 3;

    // the ends follow the direction the stroke starts and ends with, without the jitter of the first points
    final m = (n * 6 ~/ 100).clamp(4, n - 1);
    (Offset, Offset) endLine(List<Offset> part, Offset toward, Offset end, Offset fallback) {
      final line = _Line.fit(part);
      if (line == null) return (end, fallback);
      final dir = _dot(line.dir, toward) < 0 ? -line.dir : line.dir;
      return (line.project(end), dir);
    }

    final (start, startDir) = endLine(heavy.sublist(0, m + 1), heavy[m] - heavy[0], light[0], _endTangent(heavy, true));
    final (end, endDir) = endLine(
      heavy.sublist(n - 1 - m),
      heavy[n - 1] - heavy[n - 1 - m],
      light[n - 1],
      -_endTangent(heavy, false),
    );

    final keys = <(int, Offset)>[(0, startDir)];
    final extrema = [
      for (final i in _extremaIndices([for (final p in heavy) p.dy], prominence)) (i, true),
      for (final i in _extremaIndices([for (final p in heavy) p.dx], prominence)) (i, false),
    ].where((e) => e.$1 >= margin && e.$1 + margin < n).toList()..sort((a, b) => a.$1.compareTo(b.$1));
    for (final (i, levelY) in extrema) {
      final central = _unit(heavy[math.min(i + 2, n - 1)] - heavy[math.max(i - 2, 0)]);
      final tangent = levelY ? Offset(central.dx.sign, 0) : Offset(0, central.dy.sign);
      final last = keys.last;
      if (last.$1 != 0 && i - last.$1 < margin) {
        // a peak in x and y at once is a cusp, keep its own direction
        keys[keys.length - 1] = (last.$1, central);
      } else {
        keys.add((i, central.distance > 0 ? tangent : central));
      }
    }
    keys.add((n - 1, endDir));

    final points = List.of(heavy);
    for (final (i, _) in keys) {
      points[i] = light[i];
    }
    points[0] = start;
    points[n - 1] = end;
    final out = <Offset>[points.first];
    final tol = _curveFitTol * diag;
    for (var k = 0; k + 1 < keys.length; k++) {
      final (a, ta) = keys[k];
      final (b, tb) = keys[k + 1];
      _fitCubic(points.sublist(a, b + 1), ta, -tb, tol * tol, out, 0);
    }
    return out;
  }

  /// Indices of the peaks and valleys of the values that stand out by at least the prominence.
  static List<int> _extremaIndices(List<double> v, double prominence) {
    final out = <int>[];
    var dir = 0, hi = 0, lo = 0;
    for (var i = 1; i < v.length; i++) {
      if (dir == 0) {
        if (v[i] - v[0] >= prominence) {
          dir = 1;
          hi = i;
        } else if (v[0] - v[i] >= prominence) {
          dir = -1;
          lo = i;
        }
      } else if (dir == 1) {
        if (v[i] > v[hi]) {
          hi = i;
        } else if (v[hi] - v[i] >= prominence) {
          out.add(hi);
          dir = -1;
          lo = i;
        }
      } else {
        if (v[i] < v[lo]) {
          lo = i;
        } else if (v[i] - v[lo] >= prominence) {
          out.add(lo);
          dir = 1;
          hi = i;
        }
      }
    }
    return out;
  }

  /// [ring] is the drawn stroke closed by a line between its ends, [drawn] only the drawn part. Sharp polygons are
  /// recognized from their corners, everything else is compared with the ideal shapes and the closest one wins.
  static _Shape _recognizeClosed(List<Offset> ring, List<Offset> drawn, double diag, double circleTolerance) {
    final k = math.max(ring.length ~/ 40, 2);
    final corners = _findCorners(ring, k, true);
    final turns = [for (final i in corners) _turning(ring, i, k, true)];
    final orientation = _signedArea(ring).sign;

    final convex = turns.every((t) => t.sign == orientation);
    bool alternating(int offset) {
      for (var i = 0; i < turns.length; i++) {
        if ((turns[i].sign == orientation) != (i % 2 == offset)) return false;
      }
      return true;
    }

    final star = corners.length == 10 && (alternating(0) || alternating(1));
    if ((convex && corners.length >= 5 && corners.length <= 6) || star) {
      final vertices = _fitPolygon(ring, corners, k, diag);
      if (vertices != null) return _regularizePolygon(vertices, star);
    }

    final candidates = <_Shape>[];
    if (convex && corners.length >= 3 && corners.length <= 4) {
      final vertices = _fitPolygon(ring, corners, k, diag);
      if (vertices != null) candidates.add(_regularizePolygon(vertices, false));
    }
    final triangle = _fitTriangle(drawn, diag);
    if (triangle != null) candidates.add(_regularizePolygon(triangle, false));
    final quad = _fitQuadrilateral(drawn, diag);
    if (quad != null) candidates.add(_regularizePolygon(quad, false));
    candidates.addAll(_fitCircleOrEllipse(drawn, diag, circleTolerance));

    _Shape? best;
    var bestErr = double.infinity;
    for (final c in candidates) {
      final err = _outlineError(drawn, c.points) / diag;
      // circles win unless the other shapes fit clearly better
      final weighted = c.kind == RecognizedKind.circle ? err * _circlePreference : err;
      if (err <= _closedFitTol && weighted < bestErr) {
        best = c;
        bestErr = weighted;
      }
    }
    if (best != null) return best;

    final smoothed = _smooth(ring, 3, true);
    final seam = _unit(smoothed[1] - smoothed.last);
    return _Shape(
      RecognizedKind.closedCurve,
      _fitBeziers([...smoothed, smoothed.first], seam, -seam, _curveFitTol * diag),
    );
  }

  /// The largest triangle in the stroke, with its edges fitted to the stroke.
  static List<Offset>? _fitTriangle(List<Offset> drawn, double diag) {
    final hull = _convexHull(drawn);
    final h = hull.length;
    if (h < 3) return null;
    var best = 0.0;
    var idx = const [0, 1, 2];
    for (var i = 0; i < h; i++) {
      for (var j = i + 1; j < h; j++) {
        for (var l = j + 1; l < h; l++) {
          final a = _cross(hull[j] - hull[i], hull[l] - hull[i]).abs();
          if (a > best) {
            best = a;
            idx = [i, j, l];
          }
        }
      }
    }
    if (best < 1e-9) return null;
    return _refinePolygon(drawn, [for (final i in idx) hull[i]], diag);
  }

  /// The quadrilateral around the stroke, oriented along its dominant directions, with its edges fitted to it.
  static List<Offset>? _fitQuadrilateral(List<Offset> drawn, double diag) {
    var s = 0.0, c = 0.0;
    for (var i = 0; i + 1 < drawn.length; i++) {
      final d = drawn[i + 1] - drawn[i];
      final a = d.direction * 4;
      s += math.sin(a) * d.distance;
      c += math.cos(a) * d.distance;
    }
    final angle = math.atan2(s, c) / 4;
    final u = Offset(math.cos(angle), math.sin(angle));
    final v = Offset(-u.dy, u.dx);
    var x0 = double.infinity, x1 = -double.infinity, y0 = double.infinity, y1 = -double.infinity;
    for (final p in drawn) {
      x0 = math.min(x0, _dot(p, u));
      x1 = math.max(x1, _dot(p, u));
      y0 = math.min(y0, _dot(p, v));
      y1 = math.max(y1, _dot(p, v));
    }
    if (x1 - x0 < 1e-6 || y1 - y0 < 1e-6) return null;
    Offset corner(double x, double y) => u * x + v * y;
    return _refinePolygon(drawn, [corner(x0, y0), corner(x1, y0), corner(x1, y1), corner(x0, y1)], diag);
  }

  /// Fits each edge of the polygon to the stroke points closest to it, leaving out the rounded corners.
  static List<Offset> _refinePolygon(List<Offset> drawn, List<Offset> vertices, double diag) {
    final n = vertices.length;
    final groups = List.generate(n, (_) => <Offset>[]);
    for (final p in drawn) {
      var edge = 0;
      var param = 0.0;
      var dist = double.infinity;
      for (var i = 0; i < n; i++) {
        final a = vertices[i], d = vertices[(i + 1) % n] - a;
        final t = (_dot(p - a, d) / math.max(d.distanceSquared, 1e-12)).clamp(0.0, 1.0);
        final e = (p - (a + d * t)).distance;
        if (e < dist) {
          dist = e;
          edge = i;
          param = t;
        }
      }
      if (param >= 0.15 && param <= 0.85) groups[edge].add(p);
    }
    final lines = <_Line>[];
    for (var i = 0; i < n; i++) {
      final a = vertices[i], b = vertices[(i + 1) % n];
      final line = (groups[i].length >= 4 ? _Line.fit(groups[i]) : null) ?? _Line(a, _unit(b - a));
      var dir = line.dir;
      if (_dot(dir, b - a) < 0) dir = -dir;
      lines.add(_Line(line.point, _snapDir(dir)));
    }
    final refined = <Offset>[];
    for (var i = 0; i < n; i++) {
      final v = lines[(i + n - 1) % n].intersect(lines[i]);
      if (v == null || (v - vertices[i]).distance >= 0.3 * diag) return vertices;
      refined.add(v);
    }
    return refined;
  }

  /// The circle and, when it is not round, the ellipse that fit the stroke. The stroke may leave a gap.
  static List<_Shape> _fitCircleOrEllipse(List<Offset> drawn, double diag, double circleTolerance) {
    const steps = 96;
    final shapes = <_Shape>[];
    final circle = _fitCircle(drawn, diag);
    if (circle != null && circle.$2 <= 2 * diag) {
      shapes.add(
        _Shape(
          RecognizedKind.circle,
          _sample((t) => circle.$1 + Offset.fromDirection(t * 2 * math.pi, circle.$2), steps),
        ),
      );
    }
    final ellipse = _fitConicEllipse(drawn, diag);
    if (ellipse != null) {
      final (center, rx, ry, rot) = ellipse;
      var rotation = rot;
      if (math.min(rx, ry) / math.max(rx, ry) < 1 - circleTolerance.clamp(0.0, 1.0) && math.max(rx, ry) <= 2 * diag) {
        final quarter = (rotation / (math.pi / 2)).round() * (math.pi / 2);
        if ((rotation - quarter).abs() <= _axisSnapTol) rotation = quarter;
        final cr = math.cos(rotation), sr = math.sin(rotation);
        shapes.add(
          _Shape(
            RecognizedKind.ellipse,
            _sample((t) {
              final x = rx * math.cos(t * 2 * math.pi), y = ry * math.sin(t * 2 * math.pi);
              return center + Offset(x * cr - y * sr, x * sr + y * cr);
            }, steps),
          ),
        );
      }
    }
    return shapes;
  }

  /// Least squares conic a·x² + b·xy + c·y² + d·x + e·y = 1 around the mean, when it is an ellipse.
  static (Offset, double, double, double)? _fitConicEllipse(List<Offset> pts, double diag) {
    final mean = pts.reduce((a, b) => a + b) / pts.length.toDouble();
    final m = List.generate(5, (_) => List.filled(5, 0.0));
    final r = List.filled(5, 0.0);
    for (final p in pts) {
      final q = (p - mean) / diag;
      final row = [q.dx * q.dx, q.dx * q.dy, q.dy * q.dy, q.dx, q.dy];
      for (var i = 0; i < 5; i++) {
        for (var j = 0; j < 5; j++) {
          m[i][j] += row[i] * row[j];
        }
        r[i] += row[i];
      }
    }
    final sol = _solve(m, r);
    if (sol == null) return null;
    final [a, b, c, d, e] = sol;
    if (b * b - 4 * a * c >= 0) return null;
    final center = _solve(
      [
        [2 * a, b],
        [b, 2 * c],
      ],
      [-d, -e],
    );
    if (center == null) return null;
    final [cx, cy] = center;
    final f0 = a * cx * cx + b * cx * cy + c * cy * cy + d * cx + e * cy - 1;
    final rotation = 0.5 * math.atan2(b, a - c);
    final sn = math.sin(rotation), cs = math.cos(rotation);
    final l1 = a * cs * cs + b * sn * cs + c * sn * sn;
    final l2 = a * sn * sn - b * sn * cs + c * cs * cs;
    final r1 = -f0 / l1, r2 = -f0 / l2;
    if (r1 <= 0 || r2 <= 0) return null;
    return (mean + Offset(cx, cy) * diag, math.sqrt(r1) * diag, math.sqrt(r2) * diag, rotation);
  }

  /// Algebraic circle fit, works for arcs too. Returns the center and radius.
  static (Offset, double)? _fitCircle(List<Offset> pts, double diag) {
    final mean = pts.reduce((a, b) => a + b) / pts.length.toDouble();
    final m = List.generate(3, (_) => List.filled(3, 0.0));
    final r = List.filled(3, 0.0);
    for (final p in pts) {
      final q = (p - mean) / diag;
      final row = [q.dx, q.dy, 1.0];
      final rhs = -(q.dx * q.dx + q.dy * q.dy);
      for (var i = 0; i < 3; i++) {
        for (var j = 0; j < 3; j++) {
          m[i][j] += row[i] * row[j];
        }
        r[i] += row[i] * rhs;
      }
    }
    final sol = _solve(m, r);
    if (sol == null) return null;
    final c = Offset(-sol[0] / 2, -sol[1] / 2);
    final radiusSq = c.distanceSquared - sol[2];
    if (radiusSq <= 0) return null;
    return (mean + c * diag, math.sqrt(radiusSq) * diag);
  }

  /// Mean distance from the stroke points to the outline.
  static double _outlineError(List<Offset> drawn, List<Offset> outline) {
    var sum = 0.0;
    for (final p in drawn) {
      sum += _distToOutline(p, outline);
    }
    return sum / math.max(drawn.length, 1);
  }

  static double _distToOutline(Offset p, List<Offset> outline) {
    if (outline.length == 1) return (p - outline.first).distance;
    var best = double.infinity;
    for (var i = 0; i + 1 < outline.length; i++) {
      final a = outline[i], d = outline[i + 1] - a;
      final t = (_dot(p - a, d) / math.max(d.distanceSquared, 1e-12)).clamp(0.0, 1.0);
      best = math.min(best, (p - (a + d * t)).distance);
    }
    return best;
  }

  /// Convex hull with Andrew's monotone chain.
  static List<Offset> _convexHull(List<Offset> points) {
    final pts = List.of(points)..sort((a, b) => a.dx != b.dx ? a.dx.compareTo(b.dx) : a.dy.compareTo(b.dy));
    if (pts.length < 3) return pts;
    double cross(Offset o, Offset a, Offset b) => _cross(a - o, b - o);
    final hull = <Offset>[];
    for (final pass in [pts, pts.reversed.toList()]) {
      final start = hull.length;
      for (final p in pass) {
        while (hull.length >= start + 2 && cross(hull[hull.length - 2], hull.last, p) <= 0) {
          hull.removeLast();
        }
        hull.add(p);
      }
      hull.removeLast();
    }
    return hull;
  }

  /// Total signed direction change along the polyline.
  static double _winding(List<Offset> points) {
    var sum = 0.0;
    for (var i = 0; i + 2 < points.length; i++) {
      final a = points[i + 1] - points[i], b = points[i + 2] - points[i + 1];
      sum += math.atan2(_cross(a, b), _dot(a, b));
    }
    return sum;
  }

  static Offset _snapLineEnd(Offset start, Offset end) {
    final d = end - start;
    if (d.distance < 1e-9) return end;
    final dir = _snapDir(d / d.distance);
    return start + dir * _dot(d, dir);
  }

  static Offset _snapDir(Offset dir) {
    final angle = dir.direction;
    final quarter = (angle / (math.pi / 2)).round() * (math.pi / 2);
    return (angle - quarter).abs() <= _axisSnapTol ? Offset(math.cos(quarter), math.sin(quarter)) : dir;
  }

  static List<Offset>? _fitPolyline(List<Offset> pts, List<int> bounds, int k, double diag) {
    final total = _length(pts);
    final lines = <_Line>[];
    for (var i = 0; i + 1 < bounds.length; i++) {
      if ((pts[bounds[i + 1]] - pts[bounds[i]]).distance < 0.1 * total) return null;
      final line = _fitEdge(pts, bounds[i], bounds[i + 1], k, diag, false);
      if (line == null) return null;
      lines.add(line);
    }
    final vertices = [lines.first.project(pts.first)];
    for (var i = 0; i + 1 < lines.length; i++) {
      final v = lines[i].intersect(lines[i + 1]);
      if (v == null) return null;
      vertices.add(v);
    }
    vertices.add(lines.last.project(pts.last));
    return vertices;
  }

  static List<Offset>? _fitPolygon(List<Offset> ring, List<int> corners, int k, double diag) {
    final n = corners.length;
    final edges = <_Line>[];
    for (var i = 0; i < n; i++) {
      final e = _fitEdge(ring, corners[i], corners[(i + 1) % n], k, diag, true);
      if (e == null) return null;
      edges.add(e);
    }
    final vertices = <Offset>[];
    for (var i = 0; i < n; i++) {
      final v = edges[(i + n - 1) % n].intersect(edges[i]);
      if (v == null) return null;
      vertices.add(v);
    }
    final c = _bounds(ring).center;
    if (vertices.any((v) => (v - c).distance > diag)) return null;
    return vertices;
  }

  static _Line? _fitEdge(List<Offset> pts, int from, int to, int k, double diag, bool cyclic) {
    final n = pts.length;
    final count = cyclic ? (to + n - from) % n : to - from;
    if (count < 2) return null;
    final edge = [for (var i = 0; i <= count; i++) pts[(from + i) % n]];
    final a = edge.first, b = edge.last;
    final len = (b - a).distance;
    final maxDev = edge.map((p) => _distToLine(p, a, b)).fold(0.0, math.max);
    if (len < 1e-6 || maxDev > math.max(0.07 * len, 0.02 * diag)) return null;
    final trim = math.min(k ~/ 2, edge.length ~/ 4);
    final inner = edge.sublist(trim, edge.length - trim);
    final line = _Line.fit(inner.length >= 2 ? inner : edge);
    if (line == null) return null;
    var dir = line.dir;
    if (_dot(dir, b - a) < 0) dir = -dir;
    return _Line(line.point, _snapDir(dir));
  }

  static _Shape _regularizePolygon(List<Offset> vertices, bool star) {
    final n = vertices.length;
    final centroid = vertices.reduce((a, b) => a + b) / n.toDouble();
    final radii = [for (final v in vertices) (v - centroid).distance];
    final sides = [for (var i = 0; i < n; i++) (vertices[(i + 1) % n] - vertices[i]).distance];
    bool uniform(List<double> values, double tol) {
      final mean = values.reduce((a, b) => a + b) / values.length;
      return values.every((v) => (v - mean).abs() <= tol * mean);
    }

    if (star) {
      final offset = radii[0] > radii[1] ? 0 : 1;
      var outer = 0.0, inner = 0.0;
      for (var i = 0; i < 5; i++) {
        outer += radii[2 * i + offset] / 5;
        inner += radii[2 * i + 1 - offset] / 5;
      }
      final rotation = _snapRotation((vertices[offset] - centroid).direction, 5);
      inner = inner.clamp(0.25 * outer, 0.7 * outer);
      final points = [
        for (var i = 0; i < 10; i++)
          centroid + Offset.fromDirection(rotation + i * math.pi / 5, i.isEven ? outer : inner),
      ];
      return _Shape(RecognizedKind.star, [...points, points.first]);
    }

    List<Offset> closedPath(List<Offset> v) => [...v, v.first];
    switch (n) {
      case 3:
        return uniform(sides, 0.12)
            ? _regularPolygon(RecognizedKind.triangle, vertices, centroid)
            : _Shape(RecognizedKind.triangle, closedPath(vertices));
      case 4:
        final rightAngles = List.generate(4, (i) {
          final a = vertices[(i + 3) % 4] - vertices[i];
          final b = vertices[(i + 1) % 4] - vertices[i];
          return (_dot(a / a.distance, b / b.distance)).abs() < math.sin(15 * math.pi / 180);
        }).every((x) => x);
        return rightAngles
            ? _rectangle(vertices, centroid)
            : _Shape(RecognizedKind.quadrilateral, closedPath(vertices));
      case 5 || 6 when uniform(sides, 0.3) && uniform(radii, 0.2):
        return _regularPolygon(n == 5 ? RecognizedKind.pentagon : RecognizedKind.hexagon, vertices, centroid);
      default:
        return _Shape(RecognizedKind.polygon, closedPath(vertices));
    }
  }

  static double _snapRotation(double angle, int n) {
    final step = 2 * math.pi / n;
    for (final upright in [-math.pi / 2, -math.pi / 2 + step / 2]) {
      var delta = (angle - upright) % step;
      if (delta < 0) delta += step;
      if (delta > step / 2) delta -= step;
      if (delta.abs() <= _axisSnapTol) return angle - delta;
    }
    return angle;
  }

  static _Shape _regularPolygon(RecognizedKind kind, List<Offset> vertices, Offset centroid) {
    final n = vertices.length;
    final radius = vertices.map((v) => (v - centroid).distance).reduce((a, b) => a + b) / n;
    final rotation = _snapRotation((vertices[0] - centroid).direction, n);
    final orientation = _signedArea(vertices).sign;
    final points = [
      for (var i = 0; i < n; i++) centroid + Offset.fromDirection(rotation + orientation * i * 2 * math.pi / n, radius),
    ];
    return _Shape(kind, [...points, points.first]);
  }

  static _Shape _rectangle(List<Offset> vertices, Offset centroid) {
    var s = 0.0, c = 0.0;
    for (var i = 0; i < 4; i++) {
      final a = (vertices[(i + 1) % 4] - vertices[i]).direction * 4;
      s += math.sin(a);
      c += math.cos(a);
    }
    var angle = math.atan2(s, c) / 4;
    final quarter = (angle / (math.pi / 2)).round() * (math.pi / 2);
    if ((angle - quarter).abs() <= _axisSnapTol) angle = quarter;
    final u = Offset(math.cos(angle), math.sin(angle));
    final v = Offset(-u.dy, u.dx);
    final xs = [for (final p in vertices) _dot(p - centroid, u)]..sort();
    final ys = [for (final p in vertices) _dot(p - centroid, v)]..sort();
    final x0 = (xs[0] + xs[1]) / 2, x1 = (xs[2] + xs[3]) / 2;
    final y0 = (ys[0] + ys[1]) / 2, y1 = (ys[2] + ys[3]) / 2;
    final mid = centroid + u * ((x0 + x1) / 2) + v * ((y0 + y1) / 2);
    var w = x1 - x0, h = y1 - y0;
    var kind = RecognizedKind.rectangle;
    if ((w - h).abs() <= 0.12 * math.max(w, h)) {
      w = h = (w + h) / 2;
      kind = RecognizedKind.square;
    }
    final corners = [
      for (final (sx, sy) in [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)])
        mid + u * (sx * w / 2) + v * (sy * h / 2),
    ];
    return _Shape(kind, [...corners, corners.first]);
  }

  static (double, _Shape)? _fitArc(List<Offset> pts, double diag) {
    final n = pts.length.toDouble();
    final circle = _fitCircle(pts, diag);
    if (circle == null) return null;
    final (center, radius) = circle;
    if (radius > 4 * diag) return null;

    final rms = math.sqrt(pts.map((p) => math.pow((p - center).distance - radius, 2)).reduce((a, b) => a + b) / n);
    var sweep = 0.0;
    for (var i = 0; i + 1 < pts.length; i++) {
      final a = pts[i] - center, b = pts[i + 1] - center;
      sweep += math.atan2(_cross(a, b), _dot(a, b));
    }
    if (rms > 0.025 * radius || sweep.abs() < 30 * math.pi / 180 || sweep.abs() > 2 * math.pi * 0.95) return null;
    final start = (pts.first - center).direction;
    final steps = math.max(16, (sweep.abs() / (2 * math.pi) * 96).ceil());
    final points = _sample((t) => center + Offset.fromDirection(start + sweep * t, radius), steps);
    return (rms / diag, _Shape(RecognizedKind.arc, points));
  }

  /// Quadratic and cubic fits, when the stroke is the graph of a function over the x ([alongX]) or y axis.
  static List<(double, _Shape)> _fitFunction(List<Offset> pts, bool alongX, double diag) {
    double along(Offset p) => alongX ? p.dx : p.dy;
    double across(Offset p) => alongX ? p.dy : p.dx;
    Offset join(double a, double b) => alongX ? Offset(a, b) : Offset(b, a);

    final uFirst = along(pts.first), uLast = along(pts.last);
    final total = uLast - uFirst;
    if (total.abs() < 0.3 * diag) return const [];
    var backtrack = 0.0;
    for (var i = 0; i + 1 < pts.length; i++) {
      backtrack += math.max((along(pts[i + 1]) - along(pts[i])) * -total.sign, 0);
    }
    if (backtrack > 0.03 * total.abs()) return const [];

    final mid = (uFirst + uLast) / 2, half = total / 2;
    final samples = [for (final p in pts) ((along(p) - mid) / half, across(p))];
    final quad = _fitPoly(samples, 3), cubic = _fitPoly(samples, 4);
    if (quad == null || cubic == null) return const [];
    final err2 = _polyRms(samples, quad) / diag, err3 = _polyRms(samples, cubic) / diag;

    _Shape shape(RecognizedKind kind, List<double> c) {
      return _Shape(
        kind,
        _sample((t) {
          final s = -1 + 2 * t;
          final y = c.reversed.fold(0.0, (acc, ci) => acc * s + ci);
          return join(mid + half * s, y);
        }, 64),
      );
    }

    // the graph must also stay close everywhere, not only on average
    bool close(List<double> c) => samples.every((sv) {
      final y = c.reversed.fold(0.0, (acc, ci) => acc * sv.$1 + ci);
      return (y - sv.$2).abs() <= 0.045 * diag;
    });

    const tol = 0.015;
    return [
      if (err2 <= tol && close(quad)) (err2, shape(RecognizedKind.parabola, quad)),
      if (err3 <= tol && err3 < 0.6 * err2 && close(cubic)) (err3 * 1.5, shape(RecognizedKind.cubic, cubic)),
    ];
  }

  static List<double>? _fitPoly(List<(double, double)> samples, int n) {
    final m = List.generate(n, (_) => List.filled(n, 0.0));
    final r = List.filled(n, 0.0);
    for (final (s, v) in samples) {
      final powers = List.filled(n, 1.0);
      for (var i = 1; i < n; i++) {
        powers[i] = powers[i - 1] * s;
      }
      for (var i = 0; i < n; i++) {
        for (var j = 0; j < n; j++) {
          m[i][j] += powers[i] * powers[j];
        }
        r[i] += powers[i] * v;
      }
    }
    return _solve(m, r);
  }

  static double _polyRms(List<(double, double)> samples, List<double> c) {
    var sum = 0.0;
    for (final (s, v) in samples) {
      final y = c.reversed.fold(0.0, (acc, ci) => acc * s + ci);
      sum += (y - v) * (y - v);
    }
    return math.sqrt(sum / samples.length);
  }

  static List<double>? _solve(List<List<double>> m0, List<double> r0) {
    final n = r0.length;
    final m = [for (final row in m0) List.of(row)];
    final r = List.of(r0);
    for (var col = 0; col < n; col++) {
      var pivot = col;
      for (var row = col + 1; row < n; row++) {
        if (m[row][col].abs() > m[pivot][col].abs()) pivot = row;
      }
      if (m[pivot][col].abs() < 1e-12) return null;
      final tmp = m[col];
      m[col] = m[pivot];
      m[pivot] = tmp;
      final tr = r[col];
      r[col] = r[pivot];
      r[pivot] = tr;
      for (var row = col + 1; row < n; row++) {
        final f = m[row][col] / m[col][col];
        for (var k = col; k < n; k++) {
          m[row][k] -= f * m[col][k];
        }
        r[row] -= f * r[col];
      }
    }
    final x = List.filled(n, 0.0);
    for (var row = n - 1; row >= 0; row--) {
      var sum = 0.0;
      for (var k = row + 1; k < n; k++) {
        sum += m[row][k] * x[k];
      }
      x[row] = (r[row] - sum) / m[row][row];
    }
    return x.every((v) => v.isFinite) ? x : null;
  }

  static double _turning(List<Offset> pts, int i, int k, bool cyclic) {
    final n = pts.length;
    final prev = cyclic ? pts[(i + n - k) % n] : pts[math.max(i - k, 0)];
    final next = cyclic ? pts[(i + k) % n] : pts[math.min(i + k, n - 1)];
    final a = pts[i] - prev, b = next - pts[i];
    return math.atan2(_cross(a, b), _dot(a, b));
  }

  static List<int> _findCorners(List<Offset> pts, int k, bool cyclic) {
    final n = pts.length;
    if (n < 2 * k + 1) return const [];
    final turns = [for (var i = 0; i < n; i++) _turning(pts, i, k, cyclic).abs()];
    final result = <int>[];
    for (var i = cyclic ? 0 : k; i < (cyclic ? n : n - k); i++) {
      if (turns[i] < _cornerAngleMin) continue;
      var isMax = true;
      for (var d = 1; d <= k && isMax; d++) {
        final before = cyclic ? (i + n - d) % n : math.max(i - d, 0);
        final after = cyclic ? (i + d) % n : math.min(i + d, n - 1);
        isMax = turns[i] > turns[before] && turns[i] >= turns[after];
      }
      if (isMax) result.add(i);
    }
    return result;
  }

  static List<Offset>? _closedPart(List<Offset> pts, double diag) {
    final n = pts.length;
    var end = -1;
    var dist = double.infinity;
    for (var i = n * 3 ~/ 5; i < n; i++) {
      final d = (pts[i] - pts.first).distance;
      if (d < dist) {
        dist = d;
        end = i;
      }
    }
    if (end < 0) return null;
    // the stroke must go around, not just come back
    final part = pts.sublist(0, end + 1);
    final turned = _winding(_smooth(part, 2, false)).abs();
    final closed =
        _length(part) >= 1.5 * diag &&
        ((dist <= _closeTol * diag && turned >= math.pi) || (dist <= _closeGapMax * diag && turned >= _closeWinding));
    return closed ? part : null;
  }

  static List<Offset> _dedup(List<Offset> points) {
    final out = <Offset>[];
    for (final p in points) {
      if (p.isFinite && (out.isEmpty || (p - out.last).distance > 1e-9)) out.add(p);
    }
    return out;
  }

  static Rect _bounds(List<Offset> points) {
    var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
    for (final p in points) {
      minX = math.min(minX, p.dx);
      minY = math.min(minY, p.dy);
      maxX = math.max(maxX, p.dx);
      maxY = math.max(maxY, p.dy);
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  static double _length(List<Offset> points) {
    var sum = 0.0;
    for (var i = 0; i + 1 < points.length; i++) {
      sum += (points[i + 1] - points[i]).distance;
    }
    return sum;
  }

  static double _signedArea(List<Offset> points) {
    var sum = 0.0;
    for (var i = 0; i < points.length; i++) {
      sum += _cross(points[i], points[(i + 1) % points.length]);
    }
    return sum / 2;
  }

  static double _distToLine(Offset p, Offset a, Offset b) {
    final d = b - a;
    final len = d.distance;
    return len < 1e-12 ? (p - a).distance : _cross(d, p - a).abs() / len;
  }

  static List<Offset> _resample(List<Offset> points, int n) {
    final total = _length(points);
    if (total <= 0 || n < 2) return List.filled(math.max(n, 1), points.first);
    final step = total / (n - 1);
    final out = <Offset>[points.first];
    var acc = 0.0, target = step;
    for (var i = 0; i + 1 < points.length; i++) {
      final a = points[i], b = points[i + 1];
      final seg = (b - a).distance;
      while (acc + seg >= target && out.length < n - 1) {
        out.add(Offset.lerp(a, b, (target - acc) / seg)!);
        target += step;
      }
      acc += seg;
    }
    out.add(points.last);
    return out;
  }

  static List<Offset> _resampleClosed(List<Offset> ring, int n) {
    final out = _resample([...ring, ring.first], n + 1);
    return out.sublist(0, out.length - 1);
  }

  static List<Offset> _smooth(List<Offset> points, int passes, bool cyclic) {
    const radius = 2;
    final n = points.length;
    var cur = List.of(points);
    for (var pass = 0; pass < passes; pass++) {
      cur = [
        for (var i = 0; i < n; i++)
          () {
            // the window shrinks towards the ends of open strokes, the ends themselves stay
            final r = cyclic ? radius : math.min(radius, math.min(i, n - 1 - i));
            var sum = Offset.zero;
            for (var d = 0; d <= 2 * r; d++) {
              sum += cur[(i + n + d - r) % n];
            }
            return sum / (2 * r + 1);
          }(),
      ];
    }
    return cur;
  }

  static Offset _unit(Offset d) => d.distance < 1e-12 ? Offset.zero : d / d.distance;

  /// The direction from an end of the points into them.
  static Offset _endTangent(List<Offset> points, bool start) {
    final n = points.length;
    final k = math.min(3, n - 1);
    return start ? _unit(points[k] - points.first) : _unit(points[n - 1 - k] - points.last);
  }

  /// Smoothly joined cubic Béziers through the points within the tolerance (Schneider's algorithm), sampled.
  ///
  /// [t1] is the direction at the start into the curve, [t2] the direction at the end back into the curve.
  static List<Offset> _fitBeziers(List<Offset> points, Offset t1, Offset t2, double tolerance) {
    final out = <Offset>[points.first];
    if (points.length >= 2) _fitCubic(points, t1, t2, tolerance * tolerance, out, 0);
    return out;
  }

  static void _fitCubic(List<Offset> d, Offset t1, Offset t2, double errSq, List<Offset> out, int depth) {
    final n = d.length;
    void push(List<Offset> b) => out.addAll(_sample((t) => _bezEval(b, t), 16).skip(1));

    if (n <= 3 || depth > 10) {
      final dist = (d.last - d.first).distance / 3;
      push([d.first, d.first + t1 * dist, d.last + t2 * dist, d.last]);
      return;
    }
    final u = List.filled(n, 0.0);
    for (var i = 1; i < n; i++) {
      u[i] = u[i - 1] + (d[i] - d[i - 1]).distance;
    }
    final total = math.max(u.last, 1e-12);
    for (var i = 0; i < n; i++) {
      u[i] /= total;
    }
    var bez = _generateBezier(d, u, t1, t2);
    var (maxErr, split) = _maxError(d, bez, u);
    if (maxErr < errSq) return push(bez);
    if (maxErr < errSq * 4) {
      for (var it = 0; it < 20; it++) {
        for (var i = 0; i < n; i++) {
          u[i] = _newtonStep(bez, d[i], u[i]);
        }
        bez = _generateBezier(d, u, t1, t2);
        (maxErr, split) = _maxError(d, bez, u);
        if (maxErr < errSq) return push(bez);
      }
    }
    split = split.clamp(1, n - 2);
    final tc = _unit(d[split - 1] - d[split + 1]);
    _fitCubic(d.sublist(0, split + 1), t1, tc, errSq, out, depth + 1);
    _fitCubic(d.sublist(split), -tc, t2, errSq, out, depth + 1);
  }

  static List<Offset> _generateBezier(List<Offset> d, List<double> u, Offset t1, Offset t2) {
    final first = d.first, last = d.last;
    var c00 = 0.0, c01 = 0.0, c11 = 0.0, x0 = 0.0, x1 = 0.0;
    for (var i = 0; i < d.length; i++) {
      final t = u[i], mt = 1 - t;
      final b0 = mt * mt * mt, b1 = 3 * t * mt * mt, b2 = 3 * t * t * mt, b3 = t * t * t;
      final a1 = t1 * b1, a2 = t2 * b2;
      c00 += _dot(a1, a1);
      c01 += _dot(a1, a2);
      c11 += _dot(a2, a2);
      final tmp = d[i] - (first * (b0 + b1) + last * (b2 + b3));
      x0 += _dot(a1, tmp);
      x1 += _dot(a2, tmp);
    }
    final det = c00 * c11 - c01 * c01;
    final segLen = (last - first).distance;
    var alpha1 = det.abs() > 1e-12 ? (x0 * c11 - x1 * c01) / det : 0.0;
    var alpha2 = det.abs() > 1e-12 ? (c00 * x1 - c01 * x0) / det : 0.0;
    if (alpha1 < 1e-6 * segLen || alpha2 < 1e-6 * segLen || !alpha1.isFinite || !alpha2.isFinite) {
      alpha1 = alpha2 = segLen / 3;
    }
    return [first, first + t1 * alpha1, last + t2 * alpha2, last];
  }

  static Offset _bezEval(List<Offset> b, double t) {
    final mt = 1 - t;
    return b[0] * (mt * mt * mt) + b[1] * (3 * t * mt * mt) + b[2] * (3 * t * t * mt) + b[3] * (t * t * t);
  }

  static (double, int) _maxError(List<Offset> d, List<Offset> b, List<double> u) {
    var maxErr = 0.0;
    var split = d.length ~/ 2;
    for (var i = 1; i < d.length - 1; i++) {
      final e = (_bezEval(b, u[i]) - d[i]).distanceSquared;
      if (e > maxErr) {
        maxErr = e;
        split = i;
      }
    }
    return (maxErr, split);
  }

  static double _newtonStep(List<Offset> b, Offset p, double t) {
    final q = _bezEval(b, t);
    final d1 = [(b[1] - b[0]) * 3, (b[2] - b[1]) * 3, (b[3] - b[2]) * 3];
    final d2 = [(d1[1] - d1[0]) * 2, (d1[2] - d1[1]) * 2];
    final mt = 1 - t;
    final q1 = d1[0] * (mt * mt) + d1[1] * (2 * t * mt) + d1[2] * (t * t);
    final q2 = d2[0] * mt + d2[1] * t;
    final num = _dot(q - p, q1);
    final den = _dot(q1, q1) + _dot(q - p, q2);
    return den.abs() < 1e-12 ? t : (t - num / den).clamp(0.0, 1.0);
  }

  /// Samples the curve [f] over 0 to 1 in at least [minSteps] steps, halving them until the chords stay within
  /// [_flatness] of the curve.
  static List<Offset> _sample(Offset Function(double t) f, int minSteps) {
    final out = <Offset>[f(0)];
    void refine(double t0, Offset p0, double t1, Offset p1, int depth) {
      final tm = (t0 + t1) / 2;
      final pm = f(tm);
      if (depth < 10 && _distToLine(pm, p0, p1) > _flatness) {
        refine(t0, p0, tm, pm, depth + 1);
        refine(tm, pm, t1, p1, depth + 1);
      } else {
        out.add(p1);
      }
    }

    var prev = out.first;
    for (var i = 1; i <= minSteps; i++) {
      final p = f(i / minSteps);
      refine((i - 1) / minSteps, prev, i / minSteps, p, 0);
      prev = p;
    }
    return out;
  }

  /// Inserts points so no segment is longer than [maxLen], keeps erasing parts of the shape precise.
  static List<Offset> _densify(List<Offset> points, double maxLen) {
    if (points.length < 2) return points;
    final out = <Offset>[points.first];
    for (var i = 0; i + 1 < points.length; i++) {
      final a = points[i], b = points[i + 1];
      final steps = ((b - a).distance / maxLen).ceil().clamp(1, 512);
      for (var j = 1; j <= steps; j++) {
        out.add(Offset.lerp(a, b, j / steps)!);
      }
    }
    return out;
  }

  static double _dot(Offset a, Offset b) => a.dx * b.dx + a.dy * b.dy;
  static double _cross(Offset a, Offset b) => a.dx * b.dy - a.dy * b.dx;
}

class _Shape {
  _Shape(this.kind, this.points);
  final RecognizedKind kind;
  final List<Offset> points;
}

class _Line {
  _Line(this.point, this.dir);
  final Offset point;
  final Offset dir;

  static _Line? fit(List<Offset> pts) {
    final n = pts.length.toDouble();
    final point = pts.reduce((a, b) => a + b) / n;
    var sxx = 0.0, sxy = 0.0, syy = 0.0;
    for (final p in pts) {
      final d = p - point;
      sxx += d.dx * d.dx;
      sxy += d.dx * d.dy;
      syy += d.dy * d.dy;
    }
    if (sxx + syy < 1e-12) return null;
    final angle = 0.5 * math.atan2(2 * sxy, sxx - syy);
    return _Line(point, Offset(math.cos(angle), math.sin(angle)));
  }

  Offset project(Offset p) => point + dir * RecognizedShape._dot(p - point, dir);

  Offset? intersect(_Line other) {
    final denom = RecognizedShape._cross(dir, other.dir);
    if (denom.abs() < 0.1) return null;
    final t = RecognizedShape._cross(other.point - point, other.dir) / denom;
    return point + dir * t;
  }
}
