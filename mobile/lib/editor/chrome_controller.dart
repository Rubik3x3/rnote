import 'dart:async';

import 'package:flutter/foundation.dart';

import '../settings/app_settings.dart';

/// Controls the visibility of the auto-hiding menus ("chrome") around the
/// canvas.
///
/// * While drawing, the menus are hidden (if enabled in the settings).
/// * After a configurable time without interacting with them they hide.
/// * They come back with a tap on the handles, a tap with a navigating finger
///   or, when the inactivity timer is disabled, as soon as drawing ends.
class ChromeController extends ChangeNotifier {
  ChromeController(this.settings);

  final AppSettings settings;

  bool _visible = true;
  bool pinned = false;

  /// The id of the open tool options popup, if any.
  String? openPopup;

  Timer? _hideTimer;
  Timer? _showTimer;

  bool get visible => _visible || pinned;

  void _setVisible(bool v) {
    if (_visible == v) return;
    _visible = v;
    if (!v) openPopup = null;
    notifyListeners();
  }

  /// Call on any interaction with the menus: shows them and restarts the
  /// inactivity timer.
  void poke() {
    _showTimer?.cancel();
    _setVisible(true);
    _restartTimer();
  }

  void _restartTimer() {
    _hideTimer?.cancel();
    final secs = settings.autoHideSeconds;
    if (secs > 0 && !pinned) {
      _hideTimer = Timer(Duration(seconds: secs), () {
        if (openPopup == null) {
          _setVisible(false);
        } else {
          _restartTimer();
        }
      });
    }
  }

  void hide() {
    _hideTimer?.cancel();
    _setVisible(false);
  }

  void toggle() => visible ? hide() : poke();

  void togglePinned() {
    pinned = !pinned;
    if (pinned) {
      _setVisible(true);
      _hideTimer?.cancel();
    } else {
      _restartTimer();
    }
    notifyListeners();
  }

  void drawingStarted() {
    _showTimer?.cancel();
    if (openPopup != null) {
      openPopup = null;
      notifyListeners();
    }
    if (settings.hideWhileDrawing && !pinned) {
      _hideTimer?.cancel();
      _setVisible(false);
    }
  }

  void drawingEnded({bool cancelled = false}) {
    if (!settings.hideWhileDrawing || pinned) return;
    // Without inactivity timer the menus return shortly after drawing,
    // otherwise they stay out of the way until requested.
    if (settings.autoHideSeconds == 0 || cancelled) {
      _showTimer?.cancel();
      _showTimer = Timer(const Duration(milliseconds: 900), () => _setVisible(true));
    }
  }

  void openPopupToggle(String id) {
    openPopup = openPopup == id ? null : id;
    _setVisible(true);
    _restartTimer();
    notifyListeners();
  }

  void dismissPopups() {
    if (openPopup == null) return;
    openPopup = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _showTimer?.cancel();
    super.dispose();
  }
}
