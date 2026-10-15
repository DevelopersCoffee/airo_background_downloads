import 'dart:io';

import 'package:airo_background_downloads/src/http/partial_file_io_posix.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('macOS syncFile runs F_FULLFSYNC reopen path', () async {
    if (!Platform.isMacOS) return;
    final dir = await Directory.systemTemp.createTemp('airo-macos-sync-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/sync-target.bin');
    await file.writeAsBytes([1, 2, 3, 4]);
    final io = PosixPartialFileIo();
    await expectLater(io.syncFile(file.path), completes);
  });
}
