import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'dart:async';

import 'buds_connector.dart';
import 'buds_protocol.dart';

void main() {
  runApp(const BudsControllerApp());
}

class BudsControllerApp extends StatelessWidget {
  const BudsControllerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Galaxy Buds 3 Controller',
      home: const BudsHomePage(),
    );
  }
}

class BudsHomePage extends StatefulWidget {
  const BudsHomePage({super.key});

  @override
  State<BudsHomePage> createState() => _BudsHomePageState();
}

class _BudsHomePageState extends State<BudsHomePage> {
  final BudsConnector _connector = BudsConnector();
  StreamSubscription<Uint8List>? _rawDataSubscription;

  bool _isConnecting = false;
  bool _isConnected = false;
  String _status = 'Hazir';
  String _rawData = '-';
  String _parsedData = '-';
  PacketFormat _packetFormat = PacketFormat.sppHeader;

  bool get _isWindowsTarget => !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  Future<void> _connect() async {
    setState(() {
      _isConnecting = true;
      _status = 'Buds baglantisi baslatiliyor...';
    });

    try {
      await _connector.connectToBuds();
      await _rawDataSubscription?.cancel();
      _rawDataSubscription = _connector.rawDataStream.listen((Uint8List bytes) {
        final String hex = bytes
            .map((int byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join(' ')
            .toUpperCase();
        final BudsPacket? parsed = BudsProtocol.parsePacket(bytes);
        final String parsedText = parsed == null
            ? 'Parse edilemedi'
            : 'Format=${parsed.format.name}, MsgId=0x${parsed.msgId.toRadixString(16).padLeft(2, '0').toUpperCase()}, '
                'Payload=${parsed.payload.length} byte, CRC=${parsed.crcValid ? 'OK' : 'FAIL'}';

        setState(() {
          _rawData = hex.isEmpty ? '(bos)' : hex;
          _parsedData = parsedText;
        });
      });

      setState(() {
        _isConnected = true;
        _status = 'Buds baglandi';
      });
    } catch (e) {
      setState(() {
        _status = 'Baglanti hatasi: $e';
      });
    } finally {
      setState(() {
        _isConnecting = false;
      });
    }
  }

  Future<void> _toggleAnc() async {
    final Uint8List packet = BudsProtocol.createPacket(
      BudsProtocol.msgIdSetNoiseReduction,
      <int>[0x01],
      format: _packetFormat,
    );

    try {
      await _connector.sendPacket(packet);
      setState(() {
        _status = 'ANC komutu gonderildi';
      });
    } catch (e) {
      setState(() {
        _status = 'Gonderim hatasi: $e';
      });
    }
  }

  Future<void> _setAncOff() async {
    await _sendCommand(
      msgId: BudsProtocol.msgIdSetNoiseReduction,
      payload: <int>[0x00],
      success: 'ANC kapatma komutu gonderildi',
    );
  }

  Future<void> _setAmbientOn() async {
    await _sendCommand(
      msgId: BudsProtocol.msgIdSetAmbientMode,
      payload: <int>[0x01],
      success: 'Ambient acma komutu gonderildi',
    );
  }

  Future<void> _setAmbientOff() async {
    await _sendCommand(
      msgId: BudsProtocol.msgIdSetAmbientMode,
      payload: <int>[0x00],
      success: 'Ambient kapatma komutu gonderildi',
    );
  }

  Future<void> _setEq(int mode) async {
    await _sendCommand(
      msgId: BudsProtocol.msgIdEqualizer,
      payload: <int>[mode & 0xFF],
      success: 'EQ komutu gonderildi (Mode=$mode)',
    );
  }

  Future<void> _requestStatus() async {
    await _sendCommand(
      msgId: BudsProtocol.msgIdStatus,
      payload: <int>[],
      success: 'Status istegi gonderildi',
    );
  }

  Future<void> _sendCommand({
    required int msgId,
    required List<int> payload,
    required String success,
  }) async {
    final Uint8List packet = BudsProtocol.createPacket(
      msgId,
      payload,
      format: _packetFormat,
    );

    try {
      await _connector.sendPacket(packet);
      setState(() {
        _status = success;
      });
    } catch (e) {
      setState(() {
        _status = 'Gonderim hatasi: $e';
      });
    }
  }

  @override
  void dispose() {
    _rawDataSubscription?.cancel();
    _connector.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Galaxy Buds 3 Controller'),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              ElevatedButton(
                onPressed: _isConnecting ? null : _connect,
                child: Text(
                  _isConnecting ? 'Baglaniyor...' : 'Buds\'a Baglan',
                ),
              ),
              if (_isWindowsTarget) ...<Widget>[
                const SizedBox(height: 8),
                const Text(
                  'Windows test modu: hardcoded MAC ile direkt baglanti denenir.',
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 12),
              DropdownButton<PacketFormat>(
                value: _packetFormat,
                items: const <DropdownMenuItem<PacketFormat>>[
                  DropdownMenuItem<PacketFormat>(
                    value: PacketFormat.sppHeader,
                    child: Text('Paket Formati: SPP Header'),
                  ),
                  DropdownMenuItem<PacketFormat>(
                    value: PacketFormat.simple,
                    child: Text('Paket Formati: Simple'),
                  ),
                ],
                onChanged: (PacketFormat? value) {
                  if (value == null) {
                    return;
                  }
                  setState(() {
                    _packetFormat = value;
                  });
                },
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _isConnected ? _toggleAnc : null,
                child: const Text('ANC Ac'),
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: _isConnected ? _setAncOff : null,
                child: const Text('ANC Kapat'),
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: _isConnected ? _setAmbientOn : null,
                child: const Text('Ambient Ac'),
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: _isConnected ? _setAmbientOff : null,
                child: const Text('Ambient Kapat'),
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: _isConnected ? _requestStatus : null,
                child: const Text('Status Iste'),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  ElevatedButton(
                    onPressed: _isConnected ? () => _setEq(1) : null,
                    child: const Text('EQ 1'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _isConnected ? () => _setEq(2) : null,
                    child: const Text('EQ 2'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _isConnected ? () => _setEq(3) : null,
                    child: const Text('EQ 3'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text('Durum: $_status'),
              const SizedBox(height: 10),
              Text(
                'Raw Data: $_rawData',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                'Parsed: $_parsedData',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}