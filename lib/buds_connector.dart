import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'buds_protocol.dart';
import 'windows_rfcomm_bridge.dart';

class BudsConnector {
  static const String targetMac = '7C:7B:BF:59:31:35';
  static final Guid sppServiceUuid =
      Guid('00001101-0000-1000-8000-00805f9b34fb');

  BluetoothDevice? _device;
  BluetoothCharacteristic? _writeCharacteristic;
  BluetoothCharacteristic? _notifyCharacteristic;
  StreamSubscription<List<int>>? _notifySubscription;
  String _lastDiscoveryReport = '';
  final WindowsRfcommBridge _windowsBridge = WindowsRfcommBridge();
  StreamSubscription<Uint8List>? _windowsRawSub;
  final StreamController<Uint8List> _rawDataController =
      StreamController<Uint8List>.broadcast();
  final StreamController<Uint8List> _status61Controller =
      StreamController<Uint8List>.broadcast();

  Stream<Uint8List> get rawDataStream => _rawDataController.stream;
  Stream<Uint8List> get status61Stream => _status61Controller.stream;
  String get lastDiscoveryReport => _lastDiscoveryReport;
  bool get isConnected => _device?.isConnected == true;

  static String _normalizeId(String value) {
    return value.toUpperCase().replaceAll(':', '').replaceAll('-', '');
  }

  Future<void> connectToBuds() async {
    if (Platform.isWindows) {
      await _connectViaWindowsBridge();
      return;
    }

    final BluetoothDevice device = await _resolveDirectDevice();
    _device = device;

    final List<BluetoothService> services = await _connectAndDiscover(device);

    if (services.isEmpty) {
      throw StateError('Cihazda kesfedilen servis bulunamadi.');
    }

    _writeCharacteristic = null;
    _notifyCharacteristic = null;
    await _notifySubscription?.cancel();
    _notifySubscription = null;

    final List<String> reportLines = <String>[];

    // Pass 1: prefer SPP service if present.
    for (final BluetoothService service in services) {
      final bool isSpp = service.uuid == sppServiceUuid;
      reportLines.add('SERVICE ${service.uuid} ${isSpp ? "(SPP)" : ""}'.trim());

      for (final BluetoothCharacteristic characteristic in service.characteristics) {
        final CharacteristicProperties p = characteristic.properties;
        reportLines.add(
          '  CHAR ${characteristic.uuid} [w=${p.write}, wnr=${p.writeWithoutResponse}, n=${p.notify}, i=${p.indicate}]',
        );

        if (!isSpp) {
          continue;
        }

        if (_writeCharacteristic == null && (p.write || p.writeWithoutResponse)) {
          _writeCharacteristic = characteristic;
        }

        if (_notifyCharacteristic == null && (p.notify || p.indicate)) {
          _notifyCharacteristic = characteristic;
        }
      }
    }

    // Pass 2: fallback to any BLE service/characteristic pair for diagnostics.
    if (_writeCharacteristic == null || _notifyCharacteristic == null) {
      for (final BluetoothService service in services) {
        for (final BluetoothCharacteristic characteristic in service.characteristics) {
          final CharacteristicProperties p = characteristic.properties;

          if (_writeCharacteristic == null && (p.write || p.writeWithoutResponse)) {
            _writeCharacteristic = characteristic;
          }

          if (_notifyCharacteristic == null && (p.notify || p.indicate)) {
            _notifyCharacteristic = characteristic;
          }
        }
      }
    }

    _lastDiscoveryReport = reportLines.join('\n');

    if (_writeCharacteristic == null || _notifyCharacteristic == null) {
      throw StateError(
        'Yazma/notify characteristic bulunamadi. Kesif raporu:\n$_lastDiscoveryReport',
      );
    }

    await _notifyCharacteristic!.setNotifyValue(true);
    _notifySubscription = _notifyCharacteristic!.onValueReceived.listen((List<int> value) {
      final Uint8List data = Uint8List.fromList(value);
      _rawDataController.add(data);

      final BudsPacket? parsed = BudsProtocol.parsePacket(data);
      if (parsed != null && parsed.msgId == 0x61) {
        _status61Controller.add(parsed.payload);
      }
    });
  }

  Future<void> _connectViaWindowsBridge() async {
    await _windowsRawSub?.cancel();
    await _windowsBridge.connect(
      mac: targetMac,
      uuid: sppServiceUuid.toString(),
    );

    _windowsRawSub = _windowsBridge.rawDataStream.listen((Uint8List data) {
      _rawDataController.add(data);
      final BudsPacket? parsed = BudsProtocol.parsePacket(data);
      if (parsed != null && parsed.msgId == 0x61) {
        _status61Controller.add(parsed.payload);
      }
    });
  }

  Future<List<BluetoothService>> _connectAndDiscover(BluetoothDevice device) async {
    Object? lastError;

    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        if (!device.isConnected) {
          await device.connect(
            license: License.free,
            autoConnect: false,
            timeout: const Duration(seconds: 20),
          );

          // Some Windows adapters do not emit a reliable "connected" event to this stream.
          if (!device.isConnected) {
            try {
              await device.connectionState
                  .firstWhere((state) => state == BluetoothConnectionState.connected)
                  .timeout(const Duration(seconds: 4));
            } catch (_) {
              // Continue and try discoverServices directly.
            }
          }
        }

        await Future<void>.delayed(const Duration(milliseconds: 400));
        final List<BluetoothService> services = await device.discoverServices();
        return services;
      } catch (e) {
        lastError = e;

        try {
          await device.disconnect();
        } catch (_) {
          // Ignore disconnect errors between retries.
        }

        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
    }

    throw StateError(
      'Baglanti kurulamadi. Windows cihaz eslesmis gorunse bile BLE app baglantisi olusmamis olabilir. Son hata: $lastError',
    );
  }

  Future<BluetoothDevice> _resolveDirectDevice() async {
    if (!Platform.isWindows) {
      return BluetoothDevice.fromId(targetMac);
    }

    // Windows'ta önce kısa bir arka plan taramasıyla gerçek device instance'ını al.
    // UI scan listesi yok; sadece hedefi yakalamaya çalışıyoruz.
    try {
      final BluetoothDevice? fromScan = await _resolveFromBackgroundScan();
      if (fromScan != null) {
        return fromScan;
      }
    } catch (_) {
      // Continue with systemDevices/direct fallback.
    }

    try {
        final List<BluetoothDevice> devices =
          await FlutterBluePlus.systemDevices(<Guid>[Guid('1800')]);

        final String targetNormalized = _normalizeId(targetMac);

      for (final BluetoothDevice device in devices) {
          final String id = _normalizeId(device.remoteId.toString());
          if (id == targetNormalized || id.endsWith(targetNormalized)) {
          return device;
        }
      }

      for (final BluetoothDevice device in devices) {
        final String name = device.platformName.toUpperCase();
        if (name.contains('BUDS')) {
          return device;
        }
      }
    } catch (_) {
      // Fall back to direct id below.
    }

    return BluetoothDevice.fromId(targetMac);
  }

  Future<BluetoothDevice?> _resolveFromBackgroundScan() async {
    final Completer<BluetoothDevice?> completer = Completer<BluetoothDevice?>();
    StreamSubscription<List<ScanResult>>? sub;

    try {
      sub = FlutterBluePlus.onScanResults.listen((List<ScanResult> results) {
        final String targetNormalized = _normalizeId(targetMac);
        for (final ScanResult result in results) {
          final String id = _normalizeId(result.device.remoteId.toString());
          final String name = result.device.advName.toUpperCase();
          if (id == targetNormalized || id.endsWith(targetNormalized) || name.contains('BUDS')) {
            if (!completer.isCompleted) {
              completer.complete(result.device);
            }
            return;
          }
        }
      });

      await FlutterBluePlus.stopScan();
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 6));

      final BluetoothDevice? found = await completer.future.timeout(
        const Duration(seconds: 7),
        onTimeout: () => null,
      );

      await FlutterBluePlus.stopScan();
      return found;
    } finally {
      await sub?.cancel();
    }
  }

  Future<void> sendPacket(Uint8List packet) async {
    if (Platform.isWindows) {
      await _windowsBridge.send(packet);
      return;
    }

    if (_writeCharacteristic == null) {
      throw StateError('Baglanti veya write characteristic hazir degil.');
    }

    final bool withoutResponse = !_writeCharacteristic!.properties.write &&
      _writeCharacteristic!.properties.writeWithoutResponse;
    await _writeCharacteristic!.write(packet, withoutResponse: withoutResponse);
  }

  Future<void> dispose() async {
    await _windowsRawSub?.cancel();
    await _windowsBridge.dispose();
    await _notifySubscription?.cancel();
    await _rawDataController.close();
    await _status61Controller.close();

    if (_device != null) {
      try {
        await _device!.disconnect();
      } catch (_) {
        // Ignore disconnect errors during cleanup.
      }
    }
  }
}
