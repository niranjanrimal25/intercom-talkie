import 'package:flutter/material.dart';

import 'core/app_log.dart';
import 'engine/intercom_engine.dart';
import 'engine/settings.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final settings = IntercomSettings();
  try {
    await settings.load();
  } catch (error) {
    AppLog.instance
        .w('boot', 'Could not load settings (using defaults): $error');
  }

  final engine = IntercomEngine(settings: settings);

  AppLog.instance.i('boot', 'Talkie starting');

  runApp(IntercomApp(engine: engine));
}

class IntercomApp extends StatelessWidget {
  const IntercomApp({super.key, required this.engine});

  final IntercomEngine engine;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Talkie',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00BFA5),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF101413),
      ),
      themeMode: ThemeMode.dark,
      home: HomeScreen(engine: engine),
    );
  }
}
