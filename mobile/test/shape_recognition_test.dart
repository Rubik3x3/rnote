import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rnote_mobile/editor/shape_recognition.dart';

List<Offset> jitter(List<Offset> pts, double amount) => [
  for (var i = 0; i < pts.length; i++) pts[i] + Offset(math.sin(i * 1.7), math.cos(i * 2.3)) * amount,
];

List<Offset> polygon(List<Offset> v, {required bool closed, int perEdge = 40}) {
  final pts = <Offset>[];
  final count = closed ? v.length : v.length - 1;
  for (var i = 0; i < count; i++) {
    final a = v[i], b = v[(i + 1) % v.length];
    for (var j = 0; j < perEdge; j++) {
      pts.add(Offset.lerp(a, b, j / perEdge)!);
    }
  }
  pts.add(closed ? v.first : v.last);
  return pts;
}

List<Offset> regular(int n, double r, double rotation) => [
  for (var i = 0; i < n; i++) Offset.fromDirection(rotation + i * 2 * math.pi / n, r),
];

RecognizedKind kind(List<Offset> pts) => RecognizedShape.recognize(pts, 5)!.kind;

void main() {
  test('line snaps to horizontal', () {
    final s = RecognizedShape.recognize(jitter(polygon(const [Offset(0, 0), Offset(300, 20)], closed: false), 1.5), 5)!;
    expect(s.kind, RecognizedKind.line);
    expect((s.start.dy - s.end.dy).abs(), lessThan(1e-9));
  });

  test('diagonal line is kept', () {
    final s = RecognizedShape.recognize(polygon(const [Offset(0, 0), Offset(200, 150)], closed: false), 5)!;
    expect(s.kind, RecognizedKind.line);
    expect((s.end - const Offset(200, 150)).distance, lessThan(1e-6));
  });

  test('polyline', () {
    expect(
      kind(jitter(polygon(const [Offset(0, 0), Offset(0, 200), Offset(250, 200)], closed: false), 1)),
      RecognizedKind.polyline,
    );
  });

  test('circle with overshoot', () {
    expect(
      kind(jitter([for (var i = 0; i <= 220; i++) Offset.fromDirection(i / 200 * 2 * math.pi, 100)], 2)),
      RecognizedKind.circle,
    );
  });

  test('ellipse', () {
    expect(
      kind([
        for (var i = 0; i <= 200; i++)
          Offset(math.cos(i / 200 * 2 * math.pi) * 200, math.sin(i / 200 * 2 * math.pi) * 80),
      ]),
      RecognizedKind.ellipse,
    );
  });

  test('rectangle and square', () {
    expect(
      kind(jitter(polygon(const [Offset(0, 0), Offset(300, 8), Offset(305, 150), Offset(-4, 145)], closed: true), 1.5)),
      RecognizedKind.rectangle,
    );
    expect(
      kind(polygon(const [Offset(0, 0), Offset(200, 0), Offset(205, 190), Offset(0, 200)], closed: true)),
      RecognizedKind.square,
    );
  });

  test('triangle, pentagon, hexagon and star', () {
    expect(
      kind(jitter(polygon(regular(3, 100, -math.pi / 2 + 0.05), closed: true, perEdge: 50), 1)),
      RecognizedKind.triangle,
    );
    expect(kind(jitter(polygon(regular(5, 120, 0.3), closed: true), 1)), RecognizedKind.pentagon);
    expect(kind(jitter(polygon(regular(6, 120, 0.1), closed: true), 1)), RecognizedKind.hexagon);
    final star = [
      for (var i = 0; i < 10; i++) Offset.fromDirection(-math.pi / 2 + i * math.pi / 5, i.isEven ? 150 : 60),
    ];
    expect(kind(polygon(star, closed: true, perEdge: 30)), RecognizedKind.star);
  });

  test('parabola, cubic and arc', () {
    expect(
      kind(jitter([for (var i = 0; i <= 100; i++) Offset(-100.0 + 2 * i, 0.02 * math.pow(-100.0 + 2 * i, 2))], 0.8)),
      RecognizedKind.parabola,
    );
    expect(
      kind([
        for (var i = 0; i <= 100; i++)
          () {
            final x = -100.0 + 2 * i;
            return Offset(x, 0.0001 * x * x * x - 0.5 * x);
          }(),
      ]),
      RecognizedKind.cubic,
    );
    expect(
      kind([for (var i = 0; i <= 100; i++) Offset.fromDirection(math.pi + i / 100 * math.pi * 1.2, 100)]),
      RecognizedKind.arc,
    );
  });

  test('squiggle is smoothed and tiny strokes are ignored', () {
    expect(
      kind([
        for (var i = 0; i <= 200; i++) Offset(i / 200 * 300, math.sin(i / 200 * 20) * 40 + math.pow(i / 200, 2) * 80),
      ]),
      RecognizedKind.curve,
    );
    expect(
      RecognizedShape.recognize(polygon(const [Offset(0, 0), Offset(3, 0)], closed: false, perEdge: 5), 5),
      isNull,
    );
  });

  test('adjusting a line follows the pen and snaps', () {
    final s = RecognizedShape.recognize(polygon(const [Offset(0, 0), Offset(100, 0)], closed: false), 5)!;
    final a = s.adjusted(const Offset(100, 0), const Offset(180, 5));
    expect((a.end - const Offset(180, 0)).distance, lessThan(1e-6));
  });

  List<Offset> handDrawn(List<Offset> outline, double start, double amount) {
    final ring = [...outline];
    final n = ring.length.toDouble();
    final count = (amount * n).floor();
    return [
      for (var i = 0; i <= count; i++)
        () {
          final t = i.toDouble();
          final idx = (start * n + t + math.sin(t * 0.05) * 3).floor() % ring.length;
          return ring[idx] +
              Offset(math.sin(t * 0.07) * 3, math.cos(t * 0.05) * 3) +
              Offset(math.sin(t * 1.7), math.cos(t * 2.3)) * 1.2;
        }(),
    ];
  }

  List<Offset> dense(List<Offset> v, int perEdge) {
    final pts = polygon(v, closed: true, perEdge: perEdge);
    return pts.sublist(0, pts.length - 1);
  }

  test('incomplete circles and squares are completed', () {
    final circle = [for (var i = 0; i < 400; i++) Offset.fromDirection(i / 400 * 2 * math.pi, 100)];
    final square = dense(const [Offset(0, 0), Offset(200, 0), Offset(200, 200), Offset(0, 200)], 100);
    final rect = dense(const [Offset(0, 0), Offset(320, 0), Offset(320, 150), Offset(0, 150)], 100);
    final tri = dense(regular(3, 120, -math.pi / 2), 130);
    for (final amount in [0.75, 0.85, 0.92, 1.0, 1.08]) {
      for (final start in [0.0, 0.1, 0.4]) {
        final c = RecognizedShape.recognize(handDrawn(circle, start, amount), 5)!;
        expect(c.kind, RecognizedKind.circle, reason: 'circle $amount $start');
        expect((c.start - c.end).distance, lessThan(1e-6));
        if (amount >= 0.85) {
          expect(kind(handDrawn(square, start, amount)), RecognizedKind.square, reason: 'square $amount $start');
          expect(kind(handDrawn(rect, start, amount)), RecognizedKind.rectangle, reason: 'rect $amount $start');
        }
        if (amount >= 0.92) {
          expect(kind(handDrawn(tri, start, amount)), RecognizedKind.triangle, reason: 'tri $amount $start');
        }
      }
    }
  });

  test('smoothed curves keep their ends, peaks and valleys', () {
    Offset wave(double t) => Offset(t * 500, math.sin(t * 12) * (40 + t * 60));
    final pts = [for (var i = 0; i <= 400; i++) wave(i / 400)];
    final s = RecognizedShape.recognize(jitter(pts, 1.5), 5)!;
    expect(s.kind, RecognizedKind.curve);
    expect((s.start - pts.first).distance, lessThan(3));
    expect((s.end - pts.last).distance, lessThan(3));
    for (var k = 0; k < 4; k++) {
      final peak = wave((math.pi / 2 + k * math.pi) / 12);
      final nearest = s.points.reduce((a, b) => (a.dx - peak.dx).abs() < (b.dx - peak.dx).abs() ? a : b);
      expect((nearest.dy - peak.dy).abs(), lessThan(4), reason: 'peak $k');
    }
  });

  test('hooks at the ends of curves are left out', () {
    Offset wave(double t) => Offset(t * 500, math.sin(t * 9) * 70);
    final pts = [
      wave(0) + const Offset(6, 22),
      for (var i = 0; i <= 300; i++) wave(i / 300),
      wave(1) + const Offset(-8, -20),
    ];
    final s = RecognizedShape.recognize(jitter(pts, 1), 5)!;
    expect(s.kind, RecognizedKind.curve);
    expect((s.start - wave(0)).distance, lessThan(6));
    expect((s.end - wave(1)).distance, lessThan(6));
  });

  test('circle tolerance', () {
    final oval = [
      for (var i = 0; i <= 220; i++)
        Offset(math.cos(i / 200 * 2 * math.pi) * 100, math.sin(i / 200 * 2 * math.pi) * 80),
    ];
    expect(kind(oval), RecognizedKind.circle);
    expect(RecognizedShape.recognize(oval, 5, circleTolerance: 0.1)!.kind, RecognizedKind.ellipse);
  });

  test('circles stay smooth at the given flatness', () {
    // a big circle, as when drawn zoomed in it fills the screen
    final pts = [for (var i = 0; i <= 200; i++) Offset.fromDirection(i / 200 * 2 * math.pi, 1000)];
    double worst(RecognizedShape s) {
      expect(s.kind, RecognizedKind.circle);
      final c = s.center, r = (s.points.first - c).distance;
      var w = 0.0;
      for (var i = 0; i + 1 < s.points.length; i++) {
        final mid = (s.points[i] + s.points[i + 1]) / 2;
        w = math.max(w, (r - (mid - c).distance).abs());
      }
      return w;
    }

    expect(worst(RecognizedShape.recognize(pts, 5, flatness: 0.01)!), lessThan(0.02));
    expect(worst(RecognizedShape.recognize(pts, 5)!), lessThan(0.1));
  });
}
