import 'dart:typed_data';

import 'package:airo_background_downloads/src/http/partial_file_stat.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Darwin stat64 parser uses fixed offsets and fails closed on nlink 0', () {
    final buf = Uint8List(144);
    final view = ByteData.sublistView(buf);
    view.setUint32(0, 0x1234, Endian.host);
    view.setUint16(4, 33188, Endian.host); // 0100644
    view.setUint16(6, 0, Endian.host);
    view.setUint64(8, 42, Endian.host);
    view.setUint32(16, 501, Endian.host);

    expect(parseDarwinStatBytes(buf), isNull);

    view.setUint16(6, 2, Endian.host);
    final id = parseDarwinStatBytes(buf);
    expect(id, isNotNull);
    expect(id!.linkCount, equals(2));
    expect(id.inode, equals(42));
    expect(id.ownerUid, equals(501));
    expect(id.deviceId, equals(0x1234));
  });
}
