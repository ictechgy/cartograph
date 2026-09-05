import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const DemoApp());

class DemoApp extends StatelessWidget {
  const DemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: CameraPage());
  }
}

class CameraPage extends StatefulWidget {
  const CameraPage({super.key});

  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> {
  // The only link to the Swift handler is this string.
  static const MethodChannel _channel = MethodChannel('demo/camera');
  String _status = 'idle';

  Future<void> _takePhoto() async {
    // Deliberately no catch: a missing native handler must surface as an unhandled
    // MissingPluginException in the console, not disappear into a status label.
    final path = await _channel.invokeMethod<String>('takePhoto');
    setState(() => _status = 'saved $path');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_status),
            ElevatedButton(onPressed: _takePhoto, child: const Text('Take photo')),
          ],
        ),
      ),
    );
  }
}
