import 'package:flutter/material.dart';
import 'screens/connection_screen.dart';
import 'services/inference_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final svc = InferenceService();
  await svc.loadModel();
  print('[TEST] Modelo cargado: ${svc.isLoaded}');

  runApp(const TFGApp());
}

class TFGApp extends StatelessWidget {
  const TFGApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TFG - Deteccion Aerea',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const ConnectionScreen(),
    );
  }
}