import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../render/stroke_renderer.dart';
import '../rnote/geometry.dart';
import '../rnote/json_codec.dart';
import '../rnote/model.dart';
import '../rnote/rnote_file.dart';
import '../settings/app_settings.dart';

enum Tool {
  pen('Lápiz'),
  highlighter('Resaltador'),
  eraser('Borrador'),
  select('Selección'),
  shape('Formas'),
  text('Texto'),
  pan('Mover');

  final String label;
  const Tool(this.label);
}

/// An interaction in progress, started by a pointer.
sealed class ActiveAction {}

class DrawAction extends ActiveAction {
  final Tool tool;
  final List<PathElement> elements = [];
  Offset? smoothed;
  DrawAction(this.tool);
}

class EraseAction extends ActiveAction {
  Offset? last;
  bool changed = false;
}

class LassoAction extends ActiveAction {
  final bool rect;
  final List<Offset> points = [];
  LassoAction(this.rect);
}

class MoveSelectionAction extends ActiveAction {
  final Offset start;
  Offset delta = Offset.zero;
  MoveSelectionAction(this.start);
}

class ResizeSelectionAction extends ActiveAction {
  final Rect startBounds;
  double scale = 1;
  ResizeSelectionAction(this.startBounds);
}

class ShapeAction extends ActiveAction {
  final Offset start;
  Offset end;
  ShapeAction(this.start) : end = start;
}

/// Holds an open document and implements the editing operations.
class EditorController extends ChangeNotifier {
  EditorController({required this.settings, required this.doc, required this.file}) {
    doc.sortStrokes();
  }

  final AppSettings settings;
  RnoteDocument doc;
  File file;
  final assets = AssetCache();

  /// Bumped whenever the committed strokes or the camera change.
  final docRepaint = ValueNotifier<int>(0);

  /// Bumped whenever the in-progress overlay changes.
  final overlayRepaint = ValueNotifier<int>(0);

  bool dirty = false;
  Timer? _autosaveTimer;
  bool _saving = false;

  /// Requests to edit/create a text, handled by the UI.
  void Function(Offset docPos, TextStroke? existing)? onTextRequest;

  String get title {
    final name = file.uri.pathSegments.last;
    return name.endsWith('.rnote') ? name.substring(0, name.length - 6) : name;
  }

  void _repaintDoc() => docRepaint.value++;
  void _repaintOverlay() => overlayRepaint.value++;

  // -------------------------------------------------------------------------
  // Tools
  // -------------------------------------------------------------------------

  Tool get tool => Tool.values.firstWhere((t) => t.name == settings.tool, orElse: () => Tool.pen);

  set tool(Tool t) {
    if (t != Tool.select) clearSelection();
    settings.tool = t.name;
    notifyListeners();
  }

  Color colorOf(Tool t) => switch (t) {
        Tool.highlighter => settings.highlighterColor,
        Tool.shape => settings.shapeColor,
        Tool.text => settings.textColor,
        _ => settings.penColor,
      };

  void setColorFor(Tool t, Color c) {
    switch (t) {
      case Tool.highlighter:
        // keep the highlighter translucent
        settings.highlighterColor = c.a > 0.85 ? c.withValues(alpha: 0.5) : c;
      case Tool.shape:
        settings.shapeColor = c;
      case Tool.text:
        settings.textColor = c;
      default:
        settings.penColor = c;
    }
    if (selection.isNotEmpty) recolorSelection(c);
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // History
  // -------------------------------------------------------------------------

  final _undo = <List<StrokeEntry>>[];
  final _redo = <List<StrokeEntry>>[];
  static const _historyLimit = 150;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  void _pushHistory() {
    _undo.add(List.of(doc.strokes));
    if (_undo.length > _historyLimit) _undo.removeAt(0);
    _redo.clear();
  }

  void undo() {
    if (!canUndo) return;
    _redo.add(List.of(doc.strokes));
    doc.strokes = _undo.removeLast();
    _afterChange();
  }

  void redo() {
    if (!canRedo) return;
    _undo.add(List.of(doc.strokes));
    doc.strokes = _redo.removeLast();
    _afterChange();
  }

  void _afterChange() {
    selection.removeWhere((e) => !doc.strokes.contains(e));
    _updateSelectionBounds();
    markDirty();
    _repaintDoc();
    _repaintOverlay();
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Saving
  // -------------------------------------------------------------------------

  void markDirty() {
    dirty = true;
    _autosaveTimer?.cancel();
    final secs = settings.autosaveSeconds;
    if (secs > 0) _autosaveTimer = Timer(Duration(seconds: secs), () => save());
  }

  Future<void> save() async {
    _autosaveTimer?.cancel();
    if (_saving || active != null) {
      if (active != null) markDirty();
      return;
    }
    _saving = true;
    try {
      final bytes = RnoteFile.save(doc, legacy: settings.legacyFormat);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);
      dirty = false;
      notifyListeners();
    } finally {
      _saving = false;
    }
  }

  Future<void> rename(String newName) async {
    final name = newName.trim().replaceAll(RegExp(r'[/\\:*?"<>|]'), '_');
    if (name.isEmpty) return;
    if (dirty) await save();
    final target = File('${file.parent.path}/$name.rnote');
    if (await target.exists()) throw const FileSystemException('Ya existe un documento con ese nombre');
    file = await file.rename(target.path);
    notifyListeners();
  }

  @override
  void dispose() {
    _autosaveTimer?.cancel();
    docRepaint.dispose();
    overlayRepaint.dispose();
    assets.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Camera
  // -------------------------------------------------------------------------

  CameraState get camera => doc.camera;
  static const minZoom = 0.08, maxZoom = 12.0;

  void setViewportSize(Size size) {
    if (size == camera.size || size.isEmpty) return;
    final oldCenter = camera.screenToDoc(Offset(camera.size.width / 2, camera.size.height / 2));
    final firstLayout = camera.size == const Size(800, 600);
    camera.size = size;
    if (!firstLayout) {
      camera.offset = oldCenter * camera.zoom - Offset(size.width / 2, size.height / 2);
    }
    _repaintDoc();
  }

  void panBy(Offset screenDelta) {
    camera.offset -= screenDelta;
    _repaintDoc();
    _repaintOverlay();
  }

  /// Sets zoom and offset so that [docFocal] appears at [screenFocal].
  void setCamera(double zoom, Offset docFocal, Offset screenFocal) {
    camera.zoom = zoom.clamp(minZoom, maxZoom);
    camera.offset = docFocal * camera.zoom - screenFocal;
    _repaintDoc();
    _repaintOverlay();
    notifyListeners();
  }

  void zoomAt(double factor, Offset screenFocal) =>
      setCamera(camera.zoom * factor, camera.screenToDoc(screenFocal), screenFocal);

  Offset get _screenCenter => Offset(camera.size.width / 2, camera.size.height / 2);

  void resetZoom() => setCamera(1, camera.screenToDoc(_screenCenter), _screenCenter);

  void fitWidth() {
    final f = doc.config.format;
    final layout = doc.config.layout;
    final width = (layout == Layout.infinite || layout == Layout.semiInfinite)
        ? (doc.contentBounds()?.width ?? f.width)
        : f.width;
    final zoom = (camera.size.width * 0.94) / math.max(width, 50);
    final content = doc.contentBounds();
    final left = (layout == Layout.infinite || layout == Layout.semiInfinite)
        ? (content?.left ?? 0)
        : 0.0;
    final infinite = layout == Layout.infinite || layout == Layout.semiInfinite;
    final docTop = infinite && content != null
        ? content.top - 80 / zoom
        : camera.screenToDoc(Offset.zero).dy;
    camera.zoom = zoom.clamp(minZoom, maxZoom);
    camera.offset = Offset(left * camera.zoom - camera.size.width * 0.03, docTop * camera.zoom);
    _repaintDoc();
    _repaintOverlay();
    notifyListeners();
  }

  /// Shows all content, or the first page for empty documents.
  void fitContent() {
    final f = doc.config.format;
    final b = doc.contentBounds() ?? Rect.fromLTWH(0, 0, f.width, f.height);
    final zoom = math.min(camera.size.width / (b.width + 60), camera.size.height / (b.height + 60));
    setCamera(zoom, b.center, _screenCenter);
  }

  // -------------------------------------------------------------------------
  // Pointer driven actions
  // -------------------------------------------------------------------------

  ActiveAction? active;

  /// Position (screen) and tool of a hovering stylus or mouse.
  Offset? hoverPos;
  Tool? hoverTool;

  void setHover(Offset? pos, Tool? tool) {
    hoverPos = pos;
    hoverTool = tool;
    _repaintOverlay();
  }

  double get eraserRadiusDoc => settings.eraserSize / 2 / camera.zoom;

  void begin(Tool tool, Offset screenPos, double pressure) {
    final p = camera.screenToDoc(screenPos);
    switch (tool) {
      case Tool.pen || Tool.highlighter:
        final a = DrawAction(tool)..smoothed = p;
        a.elements.add(PathElement(p, pressure));
        active = a;
      case Tool.eraser:
        final a = EraseAction();
        active = a;
        _eraseAlong(a, p);
      case Tool.select:
        final bounds = selectionBounds;
        final handle = 22 / camera.zoom;
        if (bounds != null && (p - bounds.bottomRight).distance < handle * 1.2) {
          active = ResizeSelectionAction(bounds);
        } else if (bounds != null && bounds.inflate(handle * 0.5).contains(p)) {
          active = MoveSelectionAction(p);
        } else {
          clearSelection();
          active = LassoAction(settings.selectMode == 'rect')..points.add(p);
        }
      case Tool.shape:
        active = ShapeAction(p);
      case Tool.text:
        active = null;
        final hit = _topmostHit(p, 6 / camera.zoom, (s) => s is TextStroke);
        onTextRequest?.call(p, hit?.stroke as TextStroke?);
      case Tool.pan:
        active = null;
    }
    _repaintOverlay();
  }

  void move(Offset screenPos, double pressure) {
    final a = active;
    if (a == null) return;
    final p = camera.screenToDoc(screenPos);
    switch (a) {
      case DrawAction():
        final minDist = 0.6 / camera.zoom;
        final s = settings.smoothing.clamp(0.0, 0.9);
        final sm = a.smoothed! + (p - a.smoothed!) * (1 - s);
        a.smoothed = sm;
        if ((a.elements.last.pos - sm).distance < minDist) return;
        a.elements.add(PathElement(sm, pressure));
      case EraseAction():
        _eraseAlong(a, p);
      case LassoAction():
        if (a.rect && a.points.length > 1) a.points.removeLast();
        a.points.add(p);
      case MoveSelectionAction():
        a.delta = p - a.start;
      case ResizeSelectionAction():
        final tl = a.startBounds.topLeft;
        final orig = a.startBounds.bottomRight - tl;
        final now = p - tl;
        final sx = orig.dx == 0 ? 1.0 : now.dx / orig.dx;
        final sy = orig.dy == 0 ? 1.0 : now.dy / orig.dy;
        a.scale = math.max(0.05, math.max(sx, sy));
      case ShapeAction():
        a.end = p;
    }
    _repaintOverlay();
  }

  void end() {
    final a = active;
    active = null;
    switch (a) {
      case DrawAction():
        _finishDraw(a);
      case EraseAction():
        if (a.changed) _afterChange();
      case LassoAction():
        _finishLasso(a);
      case MoveSelectionAction():
        if (a.delta != Offset.zero) {
          _transformSelection(Affine.translation(a.delta));
        }
      case ResizeSelectionAction():
        if (a.scale != 1) {
          final tl = a.startBounds.topLeft;
          final t = Affine.translation(tl)
              .multiply(Affine.scale(a.scale, a.scale))
              .multiply(Affine.translation(-tl));
          _transformSelection(t, scaleWidths: true);
        }
      case ShapeAction():
        _finishShape(a);
      case null:
        break;
    }
    _repaintOverlay();
  }

  void cancel() {
    final a = active;
    active = null;
    if (a is EraseAction && a.changed) {
      undo();
      _redo.clear();
    }
    _repaintOverlay();
  }

  /// Number of points of the stroke in progress (to tell taps and strokes apart).
  int get activePointCount => switch (active) {
        DrawAction(:final elements) => elements.length,
        _ => 0,
      };

  // --- drawing ---

  StrokeStyle styleFor(Tool tool) {
    if (tool == Tool.highlighter) {
      return SmoothStyle(
        strokeWidth: settings.highlighterWidth,
        strokeColor: RColor.fromUi(settings.highlighterColor),
        pressureCurve: PressureCurve.constant,
        lineCap: 'rounded',
      );
    }
    if (settings.penStyle == 'textured') {
      return TexturedStyle(
        seed: U64.fromInt(math.Random().nextInt(1 << 32) * (1 << 20) + math.Random().nextInt(1 << 20)),
        strokeWidth: settings.penWidth * 2,
        strokeColor: RColor.fromUi(settings.penColor),
        pressureCurve: settings.penCurve,
      );
    }
    return SmoothStyle(
      strokeWidth: settings.penWidth,
      strokeColor: RColor.fromUi(settings.penColor),
      pressureCurve: settings.penCurve,
      lineCap: 'rounded',
    );
  }

  /// The stroke being drawn, for rendering.
  BrushStroke? liveStroke() {
    final a = active;
    if (a is! DrawAction || a.elements.isEmpty) return null;
    return BrushStroke(PenPath.fromElements(a.elements), styleFor(a.tool));
  }

  void _finishDraw(DrawAction a) {
    if (a.elements.isEmpty) return;
    final last = a.elements.last;
    if (a.smoothed != null && (a.smoothed! - last.pos).distance > 0.01) {
      a.elements.add(PathElement(a.smoothed!, last.pressure));
    }
    final stroke = BrushStroke(PenPath.fromElements(a.elements), styleFor(a.tool));
    addStroke(stroke, a.tool == Tool.highlighter ? StrokeLayer.highlighter : StrokeLayer.user0);
  }

  void addStroke(Stroke stroke, StrokeLayer layer) {
    _pushHistory();
    doc.strokes.add(StrokeEntry(stroke, layer, doc.nextChrono()));
    doc.sortStrokes();
    markDirty();
    _repaintDoc();
    notifyListeners();
  }

  // --- erasing ---

  void _eraseAlong(EraseAction a, Offset p) {
    final r = eraserRadiusDoc;
    final samples = <Offset>[p];
    if (a.last != null) {
      final d = (p - a.last!).distance;
      final n = (d / (r * 0.7)).floor();
      for (var i = 1; i <= n; i++) {
        samples.add(Offset.lerp(a.last!, p, i / (n + 1))!);
      }
    }
    a.last = p;
    final split = settings.eraserMode == 'split';
    var changed = false;
    final result = <StrokeEntry>[];
    for (final e in doc.strokes) {
      final s = e.stroke;
      final hit = samples.any((q) => s.hitTest(q, r));
      if (!hit) {
        result.add(e);
        continue;
      }
      changed = true;
      if (split && s is BrushStroke) {
        for (final piece in _splitBrush(s, samples, r)) {
          result.add(StrokeEntry(piece, e.layer, e.t));
        }
      }
    }
    if (changed) {
      if (!a.changed) {
        // the previous list is not mutated anymore, it can be kept as is
        _undo.add(doc.strokes);
        if (_undo.length > _historyLimit) _undo.removeAt(0);
        _redo.clear();
      }
      a.changed = true;
      doc.strokes = result;
      selection.clear();
      selectionBounds = null;
      _repaintDoc();
    }
  }

  List<BrushStroke> _splitBrush(BrushStroke s, List<Offset> centers, double r) {
    final rr = r + s.style.strokeWidth * 0.3;
    final pieces = <List<PathElement>>[[]];
    for (final e in s.flattened) {
      final erased = centers.any((c) => (c - e.pos).distanceSquared <= rr * rr);
      if (erased) {
        if (pieces.last.isNotEmpty) pieces.add([]);
      } else {
        pieces.last.add(e);
      }
    }
    return [
      for (final p in pieces)
        if (p.length >= 2) BrushStroke(PenPath.fromElements(p), s.style),
    ];
  }

  // --- selection ---

  final Set<StrokeEntry> selection = {};
  Rect? selectionBounds;

  bool get hasSelection => selection.isNotEmpty;

  void _updateSelectionBounds() {
    selectionBounds = boundsOfEntries(selection);
  }

  void clearSelection() {
    if (selection.isEmpty) return;
    selection.clear();
    selectionBounds = null;
    _repaintDoc();
    _repaintOverlay();
    notifyListeners();
  }

  void selectAll() {
    selection
      ..clear()
      ..addAll(doc.strokes.where((e) => e.stroke is! UnknownStroke));
    _updateSelectionBounds();
    if (tool != Tool.select) settings.tool = Tool.select.name;
    _repaintDoc();
    _repaintOverlay();
    notifyListeners();
  }

  StrokeEntry? _topmostHit(Offset p, double r, [bool Function(Stroke)? filter]) {
    for (final e in doc.strokes.reversed) {
      if (filter != null && !filter(e.stroke)) continue;
      if (e.stroke.hitTest(p, r)) return e;
    }
    return null;
  }

  void _finishLasso(LassoAction a) {
    final pts = a.points;
    selection.clear();
    final b = boundsOfPoints(pts);
    if (b.width * camera.zoom < 6 && b.height * camera.zoom < 6) {
      final hit = _topmostHit(pts.first, 8 / camera.zoom);
      if (hit != null) selection.add(hit);
    } else {
      final poly = a.rect ? [b.topLeft, b.topRight, b.bottomRight, b.bottomLeft] : pts;
      for (final e in doc.strokes) {
        if (e.stroke is UnknownStroke) continue;
        final sp = e.stroke.selectionPoints;
        if (sp.isEmpty) continue;
        final inside = sp.where((q) => pointInPolygon(q, poly)).length;
        if (inside >= sp.length * 0.75) selection.add(e);
      }
    }
    _updateSelectionBounds();
    _repaintDoc();
    notifyListeners();
  }

  void _replaceSelection(Iterable<StrokeEntry> Function(StrokeEntry e) f) {
    _pushHistory();
    final newSel = <StrokeEntry>{};
    final result = <StrokeEntry>[];
    for (final e in doc.strokes) {
      if (selection.contains(e)) {
        final replaced = f(e).toList();
        result.addAll(replaced);
        newSel.addAll(replaced);
      } else {
        result.add(e);
      }
    }
    doc.strokes = result;
    doc.sortStrokes();
    selection
      ..clear()
      ..addAll(newSel);
    _afterChange();
  }

  void _transformSelection(Affine t, {bool scaleWidths = false}) =>
      _replaceSelection((e) => [e.withStroke(e.stroke.transformed(t, scaleWidths: scaleWidths))]);

  void deleteSelection() {
    if (selection.isEmpty) return;
    _replaceSelection((e) => const []);
  }

  void duplicateSelection() {
    if (selection.isEmpty) return;
    _pushHistory();
    final offset = Affine.translation(Offset(24 / camera.zoom, 24 / camera.zoom));
    final copies = [
      for (final e in doc.strokes.where(selection.contains))
        StrokeEntry(e.stroke.transformed(offset), e.layer, doc.nextChrono()),
    ];
    doc.strokes.addAll(copies);
    doc.sortStrokes();
    selection
      ..clear()
      ..addAll(copies);
    _afterChange();
  }

  void recolorSelection(Color c) {
    if (selection.isEmpty) return;
    _replaceSelection((e) => [e.withStroke(e.stroke.recolored(RColor.fromUi(c)))]);
  }

  void bringSelectionToFront() {
    if (selection.isEmpty) return;
    final ordered = doc.strokes.where(selection.contains).toList();
    _replaceSelection((e) => [StrokeEntry(e.stroke, e.layer, doc.nextChrono() + ordered.indexOf(e))]);
  }

  /// Offset applied while the selection is being dragged, for rendering.
  Affine? get selectionPreviewTransform => switch (active) {
        MoveSelectionAction(:final delta) => Affine.translation(delta),
        ResizeSelectionAction(:final startBounds, :final scale) => Affine.translation(startBounds.topLeft)
            .multiply(Affine.scale(scale, scale))
            .multiply(Affine.translation(-startBounds.topLeft)),
        _ => null,
      };

  // --- shapes ---

  Shape? shapeFor(Offset a, Offset b) {
    switch (settings.shapeType) {
      case 'arrow':
        return ArrowShape(a, b);
      case 'rect':
        return RectShape.fromRect(Rect.fromPoints(a, b));
      case 'ellipse':
        final r = Rect.fromPoints(a, b);
        return EllipseShape(Offset(r.width / 2, r.height / 2), Affine.translation(r.center));
      default:
        return LineShape(a, b);
    }
  }

  SmoothStyle get shapeStyle {
    final c = RColor.fromUi(settings.shapeColor);
    return SmoothStyle(
      strokeWidth: settings.shapeWidth,
      strokeColor: c,
      fillColor: settings.shapeFill ? c.withAlpha(c.a * 0.3) : null,
      pressureCurve: PressureCurve.constant,
      lineStyle: settings.shapeLineStyle,
      lineCap: 'rounded',
    );
  }

  ShapeStroke? liveShape() {
    final a = active;
    if (a is! ShapeAction) return null;
    final s = shapeFor(a.start, a.end);
    return s == null ? null : ShapeStroke(s, shapeStyle);
  }

  void _finishShape(ShapeAction a) {
    if ((a.end - a.start).distance * camera.zoom < 4) return;
    final s = shapeFor(a.start, a.end);
    if (s != null) addStroke(ShapeStroke(s, shapeStyle), StrokeLayer.user0);
  }

  // --- text ---

  void commitText(Offset docPos, TextStroke? existing, String text, TextStyleData style) {
    if (existing != null) {
      final idx = doc.strokes.indexWhere((e) => identical(e.stroke, existing));
      if (idx < 0) return;
      final entry = doc.strokes[idx];
      _pushHistory();
      if (text.trim().isEmpty) {
        doc.strokes.removeAt(idx);
      } else {
        final keepRanges = text == existing.text;
        doc.strokes[idx] = entry.withStroke(TextStroke(
          text,
          existing.affine,
          style.copyWith(rangedAttributes: keepRanges ? existing.style.rangedAttributes : const []),
          raw: existing.raw,
        ));
      }
      _afterChange();
    } else if (text.trim().isNotEmpty) {
      addStroke(TextStroke(text, Affine.translation(docPos), style), StrokeLayer.user0);
    }
  }

  // --- images ---

  /// Inserts premultiplied RGBA pixels centered in the viewport.
  void insertBitmap(String base64Rgba, int width, int height) {
    final vp = camera.viewport;
    final maxSize = Size(vp.width * 0.6, vp.height * 0.6);
    final scale = math.min(1.0, math.min(maxSize.width / width, maxSize.height / height));
    final half = Offset(width / 2, height / 2);
    final stroke = BitmapImageStroke(
      dataBase64: base64Rgba,
      pixelWidth: width,
      pixelHeight: height,
      imageRectangle: RectShape(half, Affine.translation(half)),
      rectangle: RectShape(half, Affine(scale, 0, 0, scale, vp.center.dx, vp.center.dy)),
    );
    addStroke(stroke, StrokeLayer.image);
    _selectOnly(doc.strokes.lastWhere((e) => identical(e.stroke, stroke)));
  }

  void insertSvg(String svg, Size intrinsic) {
    final vp = camera.viewport;
    final w = intrinsic.width > 0 ? intrinsic.width : 300.0;
    final h = intrinsic.height > 0 ? intrinsic.height : 300.0;
    final scale = math.min(1.0, math.min(vp.width * 0.6 / w, vp.height * 0.6 / h));
    final half = Offset(w / 2, h / 2);
    final stroke = VectorImageStroke(svg, Offset(w, h),
        RectShape(half, Affine(scale, 0, 0, scale, vp.center.dx, vp.center.dy)));
    addStroke(stroke, StrokeLayer.image);
    _selectOnly(doc.strokes.lastWhere((e) => identical(e.stroke, stroke)));
  }

  void _selectOnly(StrokeEntry e) {
    settings.tool = Tool.select.name;
    selection
      ..clear()
      ..add(e);
    _updateSelectionBounds();
    _repaintDoc();
    _repaintOverlay();
    notifyListeners();
  }

  // --- document settings ---

  void updateConfig(DocConfig config) {
    doc.config = config;
    markDirty();
    _repaintDoc();
    notifyListeners();
  }

  void clearAll() {
    if (doc.strokes.isEmpty) return;
    _pushHistory();
    doc.strokes = [];
    _afterChange();
  }
}

