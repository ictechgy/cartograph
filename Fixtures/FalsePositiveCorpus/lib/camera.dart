import 'package:flutter/services.dart';

const channel = MethodChannel('com.example/camera');

Future<void> takePhoto() => channel.invokeMethod('takePhoto');
