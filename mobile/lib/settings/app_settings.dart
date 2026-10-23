import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Actions that can be bound to stylus buttons and the eraser end.
enum StylusAction {
  none('Herramienta actual'),
  eraser('Borrador'),
  select('Selección'),
  pan('Desplazar'),
  highlighter('Resaltador');

  final String label;
  const StylusAction(this.label);
}

/// How touches of fingers are handled.
enum FingerMode {
  auto('Automático', 'El dedo dibuja hasta que se detecta un lápiz; luego sólo navega'),
  draw('Dibujar', 'El dedo siempre dibuja, dos dedos navegan'),
  navigate('Navegar', 'El dedo sólo desplaza y hace zoom (sólo dibuja el lápiz)');

  final String label;
  final String description;
  const FingerMode(this.label, this.description);
}

/// Persistent, user configurable settings.
class AppSettings extends ChangeNotifier {
  AppSettings._(this._prefs, this._values, this._syncPassword);

  static const _key = 'settings_v1';
  static const _passwordKey = 'webdav_password';
  static const _secure = FlutterSecureStorage();

  final SharedPreferences _prefs;
  final Map<String, dynamic> _values;
  String _syncPassword;
  Timer? _saveTimer;

  static const defaultPalette = <int>[
    0xFF1E1E1E, 0xFFE01B24, 0xFFFF7800, 0xFFF6D32D, //
    0xFF33D17A, 0xFF3584E4, 0xFF9141AC, 0xFFFFFFFF,
  ];

  static final Map<String, dynamic> _defaults = {
    // appearance
    'themeMode': 'system',
    'toolbarSide': 'left',
    'buttonScale': 1.0,
    // auto-hiding menus
    'hideWhileDrawing': true,
    'autoHideSeconds': 5,
    'showQuickColors': true,
    'showZoomChip': true,
    // stylus & touch
    'fingerMode': FingerMode.auto.name,
    'pressureGamma': 1.0,
    'touchPressure': false,
    'smoothing': 0.25,
    'stylusButton1': StylusAction.eraser.name,
    'stylusButton2': StylusAction.select.name,
    'eraserEnd': StylusAction.eraser.name,
    'twoFingerTapUndo': true,
    'threeFingerTapRedo': true,
    // documents
    'newDocLayout': 'infinite',
    'newDocFormat': 'a4',
    'newDocOrientation': 'portrait',
    'newDocPattern': 'dots',
    'newDocBackground': 0xFFFFFFFF,
    'autosaveSeconds': 15,
    'legacyFormat': false,
    // sync
    'syncUrl': '',
    'syncUser': '',
    'syncOnStart': false,
    'syncOnClose': true,
    'lastSync': 0,
    // tools
    'tool': 'pen',
    'penWidth': 3.0,
    'penColor': 0xFF1E1E1E,
    'penCurve': 'linear',
    'penStyle': 'smooth',
    'highlighterWidth': 18.0,
    'highlighterColor': 0x80F6D32D,
    'eraserMode': 'stroke',
    'eraserSize': 24.0,
    'shapeType': 'line',
    'shapeWidth': 2.0,
    'shapeColor': 0xFF1E1E1E,
    'shapeFill': false,
    'shapeLineStyle': 'solid',
    'textSize': 32.0,
    'textColor': 0xFF1E1E1E,
    'selectMode': 'lasso',
    'palette': defaultPalette,
    'railCollapsed': false,
  };

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    Map<String, dynamic> values = {};
    final stored = prefs.getString(_key);
    if (stored != null) {
      try {
        values = jsonDecode(stored) as Map<String, dynamic>;
      } catch (_) {}
    }
    String password = '';
    try {
      password = await _secure.read(key: _passwordKey).timeout(const Duration(seconds: 3)) ?? '';
    } catch (_) {}
    return AppSettings._(prefs, values, password);
  }

  T _get<T>(String key) {
    final v = _values[key];
    final d = _defaults[key];
    if (v is T) return v;
    if (T == double && v is num) return v.toDouble() as T;
    if (d is List && v is List) return List<int>.from(v) as T;
    return d as T;
  }

  void _set(String key, Object? value) {
    if (_values[key] == value) return;
    _values[key] = value;
    notifyListeners();
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), _persist);
  }

  void _persist() => _prefs.setString(_key, jsonEncode(_values));

  void resetToDefaults() {
    final keep = {'syncUrl', 'syncUser', 'lastSync'};
    _values.removeWhere((k, _) => !keep.contains(k));
    notifyListeners();
    _persist();
  }

  // appearance
  ThemeMode get themeMode =>
      ThemeMode.values.firstWhere((m) => m.name == _get<String>('themeMode'),
          orElse: () => ThemeMode.system);
  set themeMode(ThemeMode m) => _set('themeMode', m.name);

  bool get toolbarOnRight => _get<String>('toolbarSide') == 'right';
  set toolbarOnRight(bool v) => _set('toolbarSide', v ? 'right' : 'left');

  double get buttonScale => _get<double>('buttonScale');
  set buttonScale(double v) => _set('buttonScale', v);

  // menus
  bool get hideWhileDrawing => _get<bool>('hideWhileDrawing');
  set hideWhileDrawing(bool v) => _set('hideWhileDrawing', v);

  int get autoHideSeconds => _get<int>('autoHideSeconds');
  set autoHideSeconds(int v) => _set('autoHideSeconds', v);

  bool get showQuickColors => _get<bool>('showQuickColors');
  set showQuickColors(bool v) => _set('showQuickColors', v);

  bool get showZoomChip => _get<bool>('showZoomChip');
  set showZoomChip(bool v) => _set('showZoomChip', v);

  bool get railCollapsed => _get<bool>('railCollapsed');
  set railCollapsed(bool v) => _set('railCollapsed', v);

  // stylus
  FingerMode get fingerMode => FingerMode.values
      .firstWhere((m) => m.name == _get<String>('fingerMode'), orElse: () => FingerMode.auto);
  set fingerMode(FingerMode m) => _set('fingerMode', m.name);

  double get pressureGamma => _get<double>('pressureGamma');
  set pressureGamma(double v) => _set('pressureGamma', v);

  bool get touchPressure => _get<bool>('touchPressure');
  set touchPressure(bool v) => _set('touchPressure', v);

  double get smoothing => _get<double>('smoothing');
  set smoothing(double v) => _set('smoothing', v);

  StylusAction _action(String key) => StylusAction.values
      .firstWhere((a) => a.name == _get<String>(key), orElse: () => StylusAction.none);

  StylusAction get stylusButton1 => _action('stylusButton1');
  set stylusButton1(StylusAction a) => _set('stylusButton1', a.name);

  StylusAction get stylusButton2 => _action('stylusButton2');
  set stylusButton2(StylusAction a) => _set('stylusButton2', a.name);

  StylusAction get eraserEnd => _action('eraserEnd');
  set eraserEnd(StylusAction a) => _set('eraserEnd', a.name);

  bool get twoFingerTapUndo => _get<bool>('twoFingerTapUndo');
  set twoFingerTapUndo(bool v) => _set('twoFingerTapUndo', v);

  bool get threeFingerTapRedo => _get<bool>('threeFingerTapRedo');
  set threeFingerTapRedo(bool v) => _set('threeFingerTapRedo', v);

  // documents
  String get newDocLayout => _get<String>('newDocLayout');
  set newDocLayout(String v) => _set('newDocLayout', v);

  String get newDocFormat => _get<String>('newDocFormat');
  set newDocFormat(String v) => _set('newDocFormat', v);

  String get newDocOrientation => _get<String>('newDocOrientation');
  set newDocOrientation(String v) => _set('newDocOrientation', v);

  String get newDocPattern => _get<String>('newDocPattern');
  set newDocPattern(String v) => _set('newDocPattern', v);

  Color get newDocBackground => Color(_get<int>('newDocBackground'));
  set newDocBackground(Color c) => _set('newDocBackground', c.toARGB32());

  int get autosaveSeconds => _get<int>('autosaveSeconds');
  set autosaveSeconds(int v) => _set('autosaveSeconds', v);

  bool get legacyFormat => _get<bool>('legacyFormat');
  set legacyFormat(bool v) => _set('legacyFormat', v);

  // sync
  String get syncUrl => _get<String>('syncUrl');
  set syncUrl(String v) => _set('syncUrl', v.trim());

  String get syncUser => _get<String>('syncUser');
  set syncUser(String v) => _set('syncUser', v.trim());

  String get syncPassword => _syncPassword;
  set syncPassword(String v) {
    _syncPassword = v;
    notifyListeners();
    _secure.write(key: _passwordKey, value: v).catchError((_) {});
  }

  bool get syncConfigured => syncUrl.isNotEmpty;

  bool get syncOnStart => _get<bool>('syncOnStart');
  set syncOnStart(bool v) => _set('syncOnStart', v);

  bool get syncOnClose => _get<bool>('syncOnClose');
  set syncOnClose(bool v) => _set('syncOnClose', v);

  DateTime? get lastSync {
    final ms = _get<int>('lastSync');
    return ms == 0 ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  set lastSync(DateTime? d) => _set('lastSync', d?.millisecondsSinceEpoch ?? 0);

  // tools
  String get tool => _get<String>('tool');
  set tool(String v) => _set('tool', v);

  double get penWidth => _get<double>('penWidth');
  set penWidth(double v) => _set('penWidth', v);

  Color get penColor => Color(_get<int>('penColor'));
  set penColor(Color c) => _set('penColor', c.toARGB32());

  String get penCurve => _get<String>('penCurve');
  set penCurve(String v) => _set('penCurve', v);

  String get penStyle => _get<String>('penStyle');
  set penStyle(String v) => _set('penStyle', v);

  double get highlighterWidth => _get<double>('highlighterWidth');
  set highlighterWidth(double v) => _set('highlighterWidth', v);

  Color get highlighterColor => Color(_get<int>('highlighterColor'));
  set highlighterColor(Color c) => _set('highlighterColor', c.toARGB32());

  String get eraserMode => _get<String>('eraserMode');
  set eraserMode(String v) => _set('eraserMode', v);

  double get eraserSize => _get<double>('eraserSize');
  set eraserSize(double v) => _set('eraserSize', v);

  String get shapeType => _get<String>('shapeType');
  set shapeType(String v) => _set('shapeType', v);

  double get shapeWidth => _get<double>('shapeWidth');
  set shapeWidth(double v) => _set('shapeWidth', v);

  Color get shapeColor => Color(_get<int>('shapeColor'));
  set shapeColor(Color c) => _set('shapeColor', c.toARGB32());

  bool get shapeFill => _get<bool>('shapeFill');
  set shapeFill(bool v) => _set('shapeFill', v);

  String get shapeLineStyle => _get<String>('shapeLineStyle');
  set shapeLineStyle(String v) => _set('shapeLineStyle', v);

  double get textSize => _get<double>('textSize');
  set textSize(double v) => _set('textSize', v);

  Color get textColor => Color(_get<int>('textColor'));
  set textColor(Color c) => _set('textColor', c.toARGB32());

  String get selectMode => _get<String>('selectMode');
  set selectMode(String v) => _set('selectMode', v);

  List<Color> get palette => _get<List<int>>('palette').map(Color.new).toList();
  set palette(List<Color> colors) => _set('palette', colors.map((c) => c.toARGB32()).toList());

  void setPaletteColor(int index, Color c) {
    final p = palette;
    if (index < 0 || index >= p.length) return;
    p[index] = c;
    palette = p;
  }
}
