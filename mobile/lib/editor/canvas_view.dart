import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../render/background_renderer.dart';
import '../render/stroke_renderer.dart';
import '../settings/app_settings.dart';
import 'chrome_controller.dart';
import 'editor_controller.dart';

/// The drawing surface. Routes raw pointer events to the editor:
///
/// * styluses draw with the current tool (or the tool bound to a stylus
///   button / the eraser end), touches are ignored while a stylus is down,
/// * fingers draw or navigate depending on [FingerMode],
/// * two fingers pan and zoom, two/three finger taps undo/redo,
/// * mouse: left draws, right/middle pans, wheel scrolls, ctrl+wheel zooms.
class CanvasView extends StatefulWidget {
  const CanvasView({super.key, required this.controller, required this.chrome});

  final EditorController controller;
  final ChromeController chrome;

  @override
  State<CanvasView> createState() => _CanvasViewState();
}

class _GesturePointer {
  Offset position;
  _GesturePointer(this.position);
}

class _CanvasViewState extends State<CanvasView> {
  EditorController get c => widget.controller;
  AppSettings get settings => c.settings;

  int? _drawPointer;
  PointerDeviceKind? _drawKind;
  DateTime _drawStart = DateTime.now();

  final _gesture = <int, _GesturePointer>{};
  double _gStartZoom = 1, _gStartSpan = 1;
  Offset _gDocFocal = Offset.zero;
  DateTime _gStartTime = DateTime.now();
  int _gMaxPointers = 0;
  double _gTravel = 0;
  bool _gDrawCancelled = false;

  /// Whether a stylus has been used in this session.
  bool _stylusSeen = false;
  Timer? _hoverTimer;

  // trackpad pan/zoom gestures
  double _trackpadStartZoom = 1;
  Offset _trackpadDocFocal = Offset.zero;
  Offset _trackpadLastPan = Offset.zero;

  static bool _isStylus(PointerDeviceKind k) =>
      k == PointerDeviceKind.stylus || k == PointerDeviceKind.invertedStylus;

  double _pressureOf(PointerEvent e) {
    final stylus = _isStylus(e.kind);
    if (!stylus && !(e.kind == PointerDeviceKind.touch && settings.touchPressure)) return 0.5;
    final min = e.pressureMin, max = e.pressureMax;
    double p;
    if (max > 1.5) {
      // Apple Pencil reports the force, with a maximum of ~4.2. Typical
      // writing force is well below that.
      p = (e.pressure - min) / ((max - min) * 0.4);
    } else if (max > min) {
      p = (e.pressure - min) / (max - min);
    } else {
      p = e.pressure;
    }
    if (!p.isFinite) p = 0.5;
    p = p.clamp(0.0, 1.0);
    p = math.pow(p, settings.pressureGamma).toDouble();
    return p.clamp(0.03, 1.0);
  }

  Tool? _toolFor(StylusAction a) => switch (a) {
        StylusAction.none => null,
        StylusAction.eraser => Tool.eraser,
        StylusAction.select => Tool.select,
        StylusAction.pan => Tool.pan,
        StylusAction.highlighter => Tool.highlighter,
      };

  /// The tool to use for a pointer, considering stylus buttons.
  Tool _toolForEvent(PointerEvent e) {
    if (e.kind == PointerDeviceKind.invertedStylus) {
      return _toolFor(settings.eraserEnd) ?? c.tool;
    }
    if (e.kind == PointerDeviceKind.stylus) {
      if (e.buttons & kSecondaryStylusButton != 0) return _toolFor(settings.stylusButton2) ?? c.tool;
      if (e.buttons & kPrimaryStylusButton != 0) return _toolFor(settings.stylusButton1) ?? c.tool;
    }
    return c.tool;
  }

  bool get _fingersDraw => switch (settings.fingerMode) {
        FingerMode.draw => true,
        FingerMode.navigate => false,
        FingerMode.auto => !_stylusSeen,
      };

  // -------------------------------------------------------------------------
  // Pointer handling
  // -------------------------------------------------------------------------

  void _onDown(PointerDownEvent e) {
    widget.chrome.dismissPopups();
    final kind = e.kind;
    if (_isStylus(kind)) {
      _stylusSeen = true;
      c.setHover(null, null);
      if (_drawPointer != null && !_isStylus(_drawKind!)) {
        // a palm or finger was drawing: drop it in favour of the stylus
        c.cancel();
        _drawPointer = null;
      }
      if (_drawPointer != null) return;
      _startDrawing(e);
      return;
    }

    if (kind == PointerDeviceKind.mouse) {
      if (e.buttons & (kSecondaryMouseButton | kMiddleMouseButton) != 0) {
        _addGesturePointer(e);
      } else if (_drawPointer == null) {
        _startDrawing(e);
      }
      return;
    }

    // touch (and unknown kinds)
    if (_drawPointer != null && _isStylus(_drawKind!)) return; // palm rejection
    if (_drawPointer != null) {
      // second finger: turn the stroke in progress into a gesture if it just
      // started, otherwise ignore the extra finger
      final young = DateTime.now().difference(_drawStart) < const Duration(milliseconds: 250) ||
          c.activePointCount < 6;
      if (young) {
        c.cancel();
        widget.chrome.drawingEnded(cancelled: true);
        final first = _drawPointer!;
        _drawPointer = null;
        _gesture[first] = _GesturePointer(_lastPos[first] ?? e.localPosition);
        _gDrawCancelled = true;
        _addGesturePointer(e, resetStats: false);
      }
      return;
    }
    if (_gesture.isEmpty && _fingersDraw && c.tool != Tool.pan) {
      _startDrawing(e);
    } else {
      _addGesturePointer(e);
    }
  }

  final _lastPos = <int, Offset>{};

  void _startDrawing(PointerDownEvent e) {
    final tool = _toolForEvent(e);
    _lastPos[e.pointer] = e.localPosition;
    if (tool == Tool.pan) {
      _addGesturePointer(e);
      return;
    }
    _drawPointer = e.pointer;
    _drawKind = e.kind;
    _drawStart = DateTime.now();
    c.begin(tool, e.localPosition, _pressureOf(e));
    if (c.active != null) widget.chrome.drawingStarted();
  }

  void _addGesturePointer(PointerDownEvent e, {bool resetStats = true}) {
    _gesture[e.pointer] = _GesturePointer(e.localPosition);
    if (resetStats && _gesture.length == 1) {
      _gStartTime = DateTime.now();
      _gMaxPointers = 0;
      _gTravel = 0;
      _gDrawCancelled = false;
    }
    if (!resetStats) _gStartTime = _drawStart;
    _gMaxPointers = math.max(_gMaxPointers, _gesture.length);
    _resetGestureBaseline();
  }

  void _resetGestureBaseline() {
    if (_gesture.isEmpty) return;
    final focal = _focal();
    _gDocFocal = c.camera.screenToDoc(focal);
    _gStartZoom = c.camera.zoom;
    _gStartSpan = math.max(_span(focal), 1);
  }

  Offset _focal() {
    var sum = Offset.zero;
    for (final p in _gesture.values) {
      sum += p.position;
    }
    return sum / _gesture.length.toDouble();
  }

  double _span(Offset focal) {
    if (_gesture.length < 2) return 1;
    var sum = 0.0;
    for (final p in _gesture.values) {
      sum += (p.position - focal).distance;
    }
    return sum / _gesture.length;
  }

  void _onMove(PointerMoveEvent e) {
    if (e.pointer == _drawPointer) {
      _lastPos[e.pointer] = e.localPosition;
      // use the coalesced samples when the platform provides them
      c.move(e.localPosition, _pressureOf(e));
      return;
    }
    final g = _gesture[e.pointer];
    if (g != null) {
      _gTravel += e.delta.distance;
      g.position = e.localPosition;
      final focal = _focal();
      final zoom = _gesture.length >= 2 ? _gStartZoom * _span(focal) / _gStartSpan : c.camera.zoom;
      c.setCamera(zoom, _gDocFocal, focal);
      return;
    }
    _lastPos[e.pointer] = e.localPosition;
  }

  void _onUp(PointerEvent e, {bool cancelled = false}) {
    _lastPos.remove(e.pointer);
    if (e.pointer == _drawPointer) {
      _drawPointer = null;
      if (cancelled) {
        c.cancel();
      } else {
        c.end();
      }
      widget.chrome.drawingEnded(cancelled: cancelled);
      return;
    }
    if (_gesture.remove(e.pointer) != null) {
      if (_gesture.isEmpty) {
        _maybeTapGesture();
      } else {
        _resetGestureBaseline();
      }
    }
  }

  void _maybeTapGesture() {
    final quick = DateTime.now().difference(_gStartTime) < const Duration(milliseconds: 300);
    if (!quick || _gTravel > 24) return;
    if (_gMaxPointers == 2 && settings.twoFingerTapUndo) {
      c.undo();
      HapticFeedback.lightImpact();
    } else if (_gMaxPointers == 3 && settings.threeFingerTapRedo) {
      c.redo();
      HapticFeedback.lightImpact();
    } else if (_gMaxPointers == 1 && !_gDrawCancelled) {
      // a tap with a navigating finger reveals the menus
      widget.chrome.toggle();
    }
  }

  void _onHover(PointerHoverEvent e) {
    if (!_isStylus(e.kind) && e.kind != PointerDeviceKind.mouse) return;
    if (_isStylus(e.kind)) _stylusSeen = true;
    final tool = _toolForEvent(e);
    c.setHover(e.localPosition, tool);
    _hoverTimer?.cancel();
    _hoverTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) c.setHover(null, null);
    });
  }

  void _onSignal(PointerSignalEvent e) {
    if (e is PointerScrollEvent) {
      final keys = HardwareKeyboard.instance;
      if (keys.isControlPressed || keys.isMetaPressed) {
        c.zoomAt(math.exp(-e.scrollDelta.dy / 300), e.localPosition);
      } else {
        final d = keys.isShiftPressed ? Offset(e.scrollDelta.dy, e.scrollDelta.dx) : e.scrollDelta;
        c.panBy(-d);
      }
    } else if (e is PointerScaleEvent) {
      c.zoomAt(e.scale, e.localPosition);
    }
  }

  void _onPanZoomStart(PointerPanZoomStartEvent e) {
    _trackpadStartZoom = c.camera.zoom;
    _trackpadDocFocal = c.camera.screenToDoc(e.localPosition);
    _trackpadLastPan = Offset.zero;
  }

  void _onPanZoomUpdate(PointerPanZoomUpdateEvent e) {
    if (e.scale != 1) {
      final focal = e.localPosition + e.pan;
      c.setCamera(_trackpadStartZoom * e.scale, _trackpadDocFocal, focal);
    } else {
      c.panBy(e.pan - _trackpadLastPan);
    }
    _trackpadLastPan = e.pan;
  }

  @override
  void dispose() {
    _hoverTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final desk = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF2B2B2E)
        : const Color(0xFFE6E6E8);
    final accent = Theme.of(context).colorScheme.primary;
    return LayoutBuilder(builder: (context, constraints) {
      c.setViewportSize(constraints.biggest);
      return Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _onDown,
        onPointerMove: _onMove,
        onPointerUp: _onUp,
        onPointerCancel: (e) => _onUp(e, cancelled: true),
        onPointerHover: _onHover,
        onPointerSignal: _onSignal,
        onPointerPanZoomStart: _onPanZoomStart,
        onPointerPanZoomUpdate: _onPanZoomUpdate,
        child: Stack(fit: StackFit.expand, children: [
          RepaintBoundary(
            child: CustomPaint(
              painter: DocumentPainter(c, deskColor: desk),
              isComplex: true,
            ),
          ),
          RepaintBoundary(
            child: CustomPaint(painter: OverlayPainter(c, accent: accent)),
          ),
        ]),
      );
    });
  }
}

/// Paints the background and all committed strokes.
class DocumentPainter extends CustomPainter {
  DocumentPainter(this.c, {required this.deskColor})
      : super(repaint: Listenable.merge([c.docRepaint, c.assets]));

  final EditorController c;
  final Color deskColor;

  @override
  void paint(Canvas canvas, Size size) {
    final cam = c.camera;
    canvas.save();
    canvas.translate(-cam.offset.dx, -cam.offset.dy);
    canvas.scale(cam.zoom);
    final viewport = cam.viewport;
    BackgroundRenderer.paint(canvas, c.doc, viewport: viewport, zoom: cam.zoom, deskColor: deskColor);

    final hideSelection = c.selectionPreviewTransform != null;
    for (final e in c.doc.strokes) {
      if (hideSelection && c.selection.contains(e)) continue;
      final b = e.stroke.bounds;
      if (!b.overlaps(viewport) && b != Rect.zero) continue;
      StrokeRenderer.paintEntry(canvas, e, c.assets);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(DocumentPainter old) => old.deskColor != deskColor || old.c != c;
}

/// Paints everything in progress: the current stroke, shape previews, the
/// selection, the lasso and the eraser / pen cursor.
class OverlayPainter extends CustomPainter {
  OverlayPainter(this.c, {required this.accent})
      : super(repaint: Listenable.merge([c.overlayRepaint, c.docRepaint]));

  final EditorController c;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final cam = c.camera;
    canvas.save();
    canvas.translate(-cam.offset.dx, -cam.offset.dy);
    canvas.scale(cam.zoom);

    final live = c.liveStroke();
    if (live != null) {
      final highlighter = (c.active as DrawAction).tool == Tool.highlighter;
      StrokeRenderer.paintStroke(canvas, live, c.assets,
          blendMode: highlighter ? BlendMode.multiply : null);
    }
    final shape = c.liveShape();
    if (shape != null) StrokeRenderer.paintStroke(canvas, shape, c.assets);

    final preview = c.selectionPreviewTransform;
    if (preview != null) {
      for (final e in c.doc.strokes) {
        if (!c.selection.contains(e)) continue;
        StrokeRenderer.paintEntry(
            canvas, e.withStroke(e.stroke.transformed(preview, scaleWidths: true)), c.assets);
      }
    }

    final px = 1 / cam.zoom;
    final active = c.active;
    if (active is LassoAction && active.points.length > 1) {
      final pts = active.points;
      final path = Path();
      if (active.rect) {
        path.addRect(Rect.fromPoints(pts.first, pts.last));
      } else {
        path.addPolygon(pts, true);
      }
      canvas.drawPath(path, Paint()..color = accent.withValues(alpha: 0.08));
      canvas.drawPath(
          dashPath(path, [6 * px, 4 * px]),
          Paint()
            ..color = accent
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5 * px);
    }

    var sel = c.selectionBounds;
    if (sel != null && c.selection.isNotEmpty) {
      if (preview != null) {
        sel = Rect.fromPoints(preview.apply(sel.topLeft), preview.apply(sel.bottomRight));
      }
      final r = sel.inflate(6 * px);
      canvas.drawRect(r, Paint()..color = accent.withValues(alpha: 0.06));
      canvas.drawPath(
          dashPath(Path()..addRect(r), [6 * px, 4 * px]),
          Paint()
            ..color = accent
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5 * px);
      // resize handle
      canvas.drawCircle(r.bottomRight, 9 * px, Paint()..color = accent);
      canvas.drawCircle(
          r.bottomRight,
          9 * px,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2 * px);
    }

    // eraser and pen cursors
    final hover = c.hoverPos;
    Offset? cursorPos;
    Tool? cursorTool;
    if (active is EraseAction && active.last != null) {
      cursorPos = active.last;
      cursorTool = Tool.eraser;
    } else if (hover != null && active == null) {
      cursorPos = cam.screenToDoc(hover);
      cursorTool = c.hoverTool;
    }
    if (cursorPos != null && cursorTool != null) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2 * px;
      switch (cursorTool) {
        case Tool.eraser:
          canvas.drawCircle(cursorPos, c.eraserRadiusDoc, Paint()..color = const Color(0x22FFFFFF));
          canvas.drawCircle(cursorPos, c.eraserRadiusDoc, paint..color = const Color(0xAA555555));
        case Tool.pen:
          canvas.drawCircle(
              cursorPos, math.max(c.settings.penWidth / 2, 1.5 * px), Paint()..color = c.settings.penColor);
        case Tool.highlighter:
          canvas.drawCircle(cursorPos, c.settings.highlighterWidth / 2,
              Paint()..color = c.settings.highlighterColor);
        default:
          canvas.drawCircle(cursorPos, 3 * px, paint..color = accent);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(OverlayPainter old) => old.accent != accent || old.c != c;
}
