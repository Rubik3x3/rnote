import 'package:flutter/material.dart';

import 'library/library_service.dart';
import 'settings/app_settings.dart';
import 'ui/library_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await AppSettings.load();
  final library = await LibraryService.init();
  runApp(RnoteMobileApp(settings: settings, library: library));
}

class RnoteMobileApp extends StatefulWidget {
  const RnoteMobileApp({super.key, required this.settings, required this.library});

  final AppSettings settings;
  final LibraryService library;

  @override
  State<RnoteMobileApp> createState() => _RnoteMobileAppState();
}

class _RnoteMobileAppState extends State<RnoteMobileApp> {
  // Rnote's (GNOME) blue
  static const _seed = Color(0xFF3584E4);

  late ThemeMode _themeMode = widget.settings.themeMode;

  @override
  void initState() {
    super.initState();
    widget.settings.addListener(_onSettings);
  }

  @override
  void dispose() {
    widget.settings.removeListener(_onSettings);
    super.dispose();
  }

  // only the theme matters here, avoid rebuilding the app on every setting
  void _onSettings() {
    if (widget.settings.themeMode != _themeMode) {
      setState(() => _themeMode = widget.settings.themeMode);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rnote Mobile',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: ThemeData(colorSchemeSeed: _seed, brightness: Brightness.light),
      darkTheme: ThemeData(colorSchemeSeed: _seed, brightness: Brightness.dark),
      home: LibraryScreen(settings: widget.settings, library: widget.library),
    );
  }
}
