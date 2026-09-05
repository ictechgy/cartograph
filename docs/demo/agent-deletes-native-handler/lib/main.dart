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
    try {
      final path = await _channel.invokeMethod<String>('takePhoto');
      setState(() => _status = 'saved $path');
    } on PlatformException catch (error) {
      setState(() => _status = 'error ${error.message}');
    } on MissingPluginException {
      setState(() => _status = 'no native handler for takePhoto');
    }
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
