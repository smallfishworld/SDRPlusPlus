import 'dart:io';

import 'package:flutter/services.dart';

class AndroidRtlSdrDevice {
  const AndroidRtlSdrDevice({
    required this.deviceName,
    required this.vendorId,
    required this.productId,
    required this.productName,
  });

  final String deviceName;
  final int vendorId;
  final int productId;
  final String productName;

  String get vidPid =>
      '${vendorId.toRadixString(16).padLeft(4, '0')}:'
      '${productId.toRadixString(16).padLeft(4, '0')}';
}

class AndroidUsbService {
  static const MethodChannel _channel =
      MethodChannel('sdrpp_receiver/usb');

  static bool get supported => Platform.isAndroid;

  static Future<List<AndroidRtlSdrDevice>> listRtlSdrDevices() async {
    if (!supported) {
      return const <AndroidRtlSdrDevice>[];
    }

    final raw = await _channel.invokeMethod<List<dynamic>>(
      'listRtlSdrDevices',
    );
    if (raw == null) {
      return const <AndroidRtlSdrDevice>[];
    }

    return raw
        .whereType<Map<dynamic, dynamic>>()
        .map(
          (item) => AndroidRtlSdrDevice(
            deviceName: item['deviceName'] as String? ?? '',
            vendorId: item['vendorId'] as int? ?? 0,
            productId: item['productId'] as int? ?? 0,
            productName: item['productName'] as String? ?? 'RTL-SDR',
          ),
        )
        .toList(growable: false);
  }

  static Future<({
    int fd,
    int vendorId,
    int productId,
    String deviceName,
  })?> openRtlSdr(String deviceName) async {
    if (!supported) {
      return null;
    }

    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'openRtlSdr',
      <String, Object>{'deviceName': deviceName},
    );
    if (result == null) {
      return null;
    }

    final fd = result['fd'] as int? ?? -1;
    if (fd < 0) {
      return null;
    }

    return (
      fd: fd,
      vendorId: result['vendorId'] as int? ?? 0,
      productId: result['productId'] as int? ?? 0,
      deviceName: result['deviceName'] as String? ?? deviceName,
    );
  }

  static Future<void> closeRtlSdr() async {
    if (supported) {
      await _channel.invokeMethod<void>('closeRtlSdr');
    }
  }
}
