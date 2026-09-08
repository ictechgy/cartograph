import 'package:flutter/services.dart';

const channel = MethodChannel('com.example/camera');

Future<void> takePhoto() => channel.invokeMethod('takePhoto');

// ObjC 구현도 조인하되 Swift 보존 이름을 지어내지 않는 왕복 사례다.
const nativeChannel = MethodChannel('com.example/objc-camera');
Future<void> takeNativePhoto() => nativeChannel.invokeMethod('nativePhoto');
