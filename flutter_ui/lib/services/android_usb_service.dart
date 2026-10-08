import 'dart:io';

import 'package:flutter/services.dart';

class AndroidSdrUsbDevice {
  const AndroidSdrUsbDevice({
    required this.deviceName,
    required this.vendorId,
    required this.productId,
    required this.productName,
    required this.driver,
  });

  final String deviceName;
  final int vendorId;
  final int productId;
  final String productName;
  final String driver;

  String get vidPid =>
      '${vendorId.toRadixString(16).padLeft(4, '0')}:'
      '${productId.toRadixString(16).padLeft(4, '0')}';

  String get label => '$productName · $vidPid · $driver';
}

class AndroidRtlSdrDevice extends AndroidSdrUsbDevice {
  const AndroidRtlSdrDevice({
    required super.deviceName,
    required super.vendorId,
    required super.productId,
    required super.productName,
  }) : super(driver: 'rtlsdr');
}

class AndroidUsbService {
  static const MethodChannel _channel =
      MethodChannel('sdrpp_receiver/usb');

  static bool get supported => Platform.isAndroid;

  static AndroidSdrUsbDevice _parseDevice(Map<dynamic, dynamic> item) {
    return AndroidSdrUsbDevice(
      deviceName: item['deviceName'] as String? ?? '',
      vendorId: item['vendorId'] as int? ?? 0,
      productId: item['productId'] as int? ?? 0,
      productName: item['productName'] as String? ?? 'USB SDR',
      driver: item['driver'] as String? ?? 'unknown',
    );
  }

  static Future<List<AndroidSdrUsbDevice>> listSdrUsbDevices() async {
    if (!supported) {
      return const <AndroidSdrUsbDevice>[];
    }

    final raw = await _channel.invokeMethod<List<dynamic>>(
      'listSdrUsbDevices',
    );
    if (raw == null) {
      return const <AndroidSdrUsbDevice>[];
    }

    return raw
        .whereType<Map<dynamic, dynamic>>()
        .map(_parseDevice)
        .toList(growable: false);
  }

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
    String driver,
  })?> openSdrUsb(String deviceName) async {
    if (!supported) {
      return null;
    }

    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'openSdrUsb',
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
      driver: result['driver'] as String? ?? 'unknown',
    );
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

  static Future<void> closeSdrUsb() async {
    if (supported) {
      await _channel.invokeMethod<void>('closeSdrUsb');
    }
  }

  static Future<void> closeRtlSdr() async {
    if (supported) {
      await _channel.invokeMethod<void>('closeRtlSdr');
    }
  }
}
