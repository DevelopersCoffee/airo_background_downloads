import 'dart:io';

import 'package:airo_background_downloads/src/http/partial_file_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('syncFile throws when the target file is missing', () async {
    final io = PartialFileIo();
    await expectLater(
      io.syncFile(
        '${Directory.systemTemp.path}/missing-partial-${DateTime.now().microsecondsSinceEpoch}.partial',
      ),
      throwsA(isA<FileSystemException>()),
    );
  });
}
