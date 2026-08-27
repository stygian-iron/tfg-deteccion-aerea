import 'package:flutter/material.dart';
import 'stream_screen.dart';

class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key});
  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  final _ipController = TextEditingController(text: '192.168.1.');
  bool _connecting = false;

  void _connect(String ip) async {
    if (ip.isEmpty) return;
    setState(() => _connecting = true);
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => StreamScreen(serverIp: ip)),
    ).then((_) => setState(() => _connecting = false));
  }

  void _connectOffline() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => StreamScreen(serverIp: '')),
    );
  }

  @override
  void dispose() {
    _ipController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('TFG - Deteccion Aerea'),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.radar, size: 80, color: Colors.blue),
            const SizedBox(height: 32),
            const Text(
              'Conectar al servidor',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Introduce la IP del ordenador donde corre la API',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 32),
            TextField(
              controller: _ipController,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'IP del servidor',
                hintText: '192.168.1.X',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.computer),
              ),
            ),
            const SizedBox(height: 24),

            // Boton conectar por WiFi
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.wifi),
                onPressed: _connecting
                    ? null
                    : () => _connect(_ipController.text.trim()),
                label: _connecting
                    ? const CircularProgressIndicator()
                    : const Text('Conectar por WiFi',
                        style: TextStyle(fontSize: 18)),
              ),
            ),
            const SizedBox(height: 12),

            // Boton emulador
            TextButton(
              onPressed: () {
                _ipController.text = '10.0.2.2';
                _connect('10.0.2.2');
              },
              child: const Text('Usar emulador (10.0.2.2)'),
            ),
            const SizedBox(height: 8),

            // Divisor
            const Row(
              children: [
                Expanded(child: Divider()),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Text('o', style: TextStyle(color: Colors.grey)),
                ),
                Expanded(child: Divider()),
              ],
            ),
            const SizedBox(height: 8),

            // Boton sin servidor (on-device)
            SizedBox(
              width: double.infinity,
              height: 50,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.phone_android, color: Colors.greenAccent),
                label: const Text(
                  'Usar sin servidor (on-device)',
                  style: TextStyle(fontSize: 16, color: Colors.greenAccent),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.greenAccent),
                ),
                onPressed: _connectOffline,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'El modelo de IA corre directamente en el movil',
              style: TextStyle(color: Colors.grey, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}