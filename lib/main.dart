import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'services/connection_service.dart';
import 'services/camera_service.dart';
import 'screens/camera_screen.dart';
import 'screens/connect_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock to landscape+portrait (user chooses per session)
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  // Immersive mode — no status bar distracting during live
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.black,
  ));

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ConnectionService()),
        ChangeNotifierProvider(create: (_) => CameraService()),
      ],
      child: const VortexCamApp(),
    ),
  );
}

class VortexCamApp extends StatelessWidget {
  const VortexCamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VortexCam',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00BBDD),   // electric cyan — matches desktop UI
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.black,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0D0D0D),
          foregroundColor: Colors.white,
          elevation: 0,
        ),
      ),
      home: const AppNavigator(),
    );
  }
}

class AppNavigator extends StatelessWidget {
  const AppNavigator({super.key});

  @override
  Widget build(BuildContext context) {
    final conn = context.watch<ConnectionService>();
    return conn.isConnected ? const CameraScreen() : const ConnectScreen();
  }
}
