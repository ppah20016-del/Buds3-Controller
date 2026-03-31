import 'dart:typed_data';

enum PacketFormat { simple, sppHeader }

class BudsPacket {
  final PacketFormat format;
  final int msgId;
  final Uint8List payload;
  final bool isRequest;
  final bool isFragment;
  final bool crcValid;

  const BudsPacket({
    required this.format,
    required this.msgId,
    required this.payload,
    required this.isRequest,
    required this.isFragment,
    required this.crcValid,
  });
}

class BudsProtocol {
  static const int som = 0xFD;
  static const int eom = 0xDD;

  static const int msgIdStatus = 0x61;
  static const int msgIdExtendedStatusUpdated = 0x61;
  static const int msgIdSetAmbientMode = 0x80;
  static const int msgIdEqualizer = 0x86;
  static const int msgIdAnc = 0x98;
  static const int msgIdSetNoiseReduction = 0x98;

  static int _reflect8(int value) {
    int result = 0;
    for (int i = 0; i < 8; i++) {
      if ((value & (1 << i)) != 0) {
        result |= 1 << (7 - i);
      }
    }
    return result;
  }

  /// CRC16-CCITT (Poly: 0x1021, Init: 0x0000, RefIn: true, RefOut: false)
  static int calculateCRC(List<int> data) {
    int crc = 0x0000;

    for (final value in data) {
      final int reflected = _reflect8(value & 0xFF);
      crc ^= (reflected << 8) & 0xFFFF;

      for (int i = 0; i < 8; i++) {
        if ((crc & 0x8000) != 0) {
          crc = ((crc << 1) ^ 0x1021) & 0xFFFF;
        } else {
          crc = (crc << 1) & 0xFFFF;
        }
      }
    }

    return crc & 0xFFFF;
  }

  /// CRC16-CCITT table style used by GalaxyBudsClient SPP encoder.
  static int calculateSppCRC(List<int> data) {
    int crc = 0;

    for (final int value in data) {
      crc ^= (value & 0xFF) << 8;
      for (int i = 0; i < 8; i++) {
        if ((crc & 0x8000) != 0) {
          crc = ((crc << 1) ^ 0x1021) & 0xFFFF;
        } else {
          crc = (crc << 1) & 0xFFFF;
        }
      }
    }

    return crc & 0xFFFF;
  }

  static Uint8List createPacket(
    int msgId,
    List<int> payload, {
    PacketFormat format = PacketFormat.simple,
    bool isRequest = true,
    bool isFragment = false,
  }) {
    if (format == PacketFormat.sppHeader) {
      return _createSppPacket(
        msgId,
        payload,
        isRequest: isRequest,
        isFragment: isFragment,
      );
    }

    return _createSimplePacket(msgId, payload);
  }

  static Uint8List _createSimplePacket(int msgId, List<int> payload) {
    final int payloadLength = payload.length & 0xFF;
    final List<int> crcInput = <int>[payloadLength, msgId & 0xFF, ...payload];
    final int crc = calculateCRC(crcInput);

    final List<int> packet = <int>[
      som,
      payloadLength,
      msgId & 0xFF,
      ...payload,
      crc & 0xFF,
      (crc >> 8) & 0xFF,
      eom,
    ];

    return Uint8List.fromList(packet);
  }

  static Uint8List _createSppPacket(
    int msgId,
    List<int> payload, {
    required bool isRequest,
    required bool isFragment,
  }) {
    final int size = 1 + payload.length + 2;
    int header = size & 0x03FF;

    if (isFragment) {
      header |= 0x2000;
    }

    if (!isRequest) {
      header |= 0x1000;
    }

    final int crc = calculateSppCRC(<int>[msgId & 0xFF, ...payload]);

    return Uint8List.fromList(<int>[
      som,
      header & 0xFF,
      (header >> 8) & 0xFF,
      msgId & 0xFF,
      ...payload,
      crc & 0xFF,
      (crc >> 8) & 0xFF,
      eom,
    ]);
  }

  static BudsPacket? parsePacket(Uint8List raw) {
    if (raw.length < 7 || raw.first != som || raw.last != eom) {
      return null;
    }

    final BudsPacket? simple = _parseSimple(raw);
    if (simple != null) {
      return simple;
    }

    return _parseSpp(raw);
  }

  static BudsPacket? _parseSimple(Uint8List raw) {
    final int payloadLength = raw[1];
    final int expectedLength = 1 + 1 + 1 + payloadLength + 2 + 1;
    if (raw.length != expectedLength) {
      return null;
    }

    final int msgId = raw[2];
    final Uint8List payload = Uint8List.fromList(
      raw.sublist(3, 3 + payloadLength),
    );

    final int packetCrc = raw[3 + payloadLength] | (raw[4 + payloadLength] << 8);
    final int expectedCrc = calculateCRC(<int>[payloadLength, msgId, ...payload]);

    return BudsPacket(
      format: PacketFormat.simple,
      msgId: msgId,
      payload: payload,
      isRequest: true,
      isFragment: false,
      crcValid: packetCrc == expectedCrc,
    );
  }

  static BudsPacket? _parseSpp(Uint8List raw) {
    if (raw.length < 8) {
      return null;
    }

    final int header = raw[1] | (raw[2] << 8);
    final bool isFragment = (header & 0x2000) != 0;
    final bool isRequest = (header & 0x1000) == 0;
    final int size = header & 0x03FF;
    final int expectedLength = 1 + 2 + size + 1;

    if (raw.length != expectedLength || size < 3) {
      return null;
    }

    final int msgId = raw[3];
    final int payloadLength = size - 3;
    final Uint8List payload = Uint8List.fromList(
      raw.sublist(4, 4 + payloadLength),
    );

    final int packetCrc = raw[4 + payloadLength] | (raw[5 + payloadLength] << 8);
    final int expectedCrc = calculateSppCRC(<int>[msgId, ...payload]);

    return BudsPacket(
      format: PacketFormat.sppHeader,
      msgId: msgId,
      payload: payload,
      isRequest: isRequest,
      isFragment: isFragment,
      crcValid: packetCrc == expectedCrc,
    );
  }
}
