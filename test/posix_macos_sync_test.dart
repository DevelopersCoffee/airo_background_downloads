import 'dart:io';

import 'package:airo_background_downloads/src/http/partial_file_identity.dart';
import 'package:airo_background_downloads/src/http/partial_file_io_posix.dart';
import 'package:airo_background_downloads/src/http/partial_file_stat.dart';
import 'package:airo_background_downloads/src/http/posix_variadic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('macOS syncFile invokes F_FULLFSYNC path', () async {
    if (!Platform.isMacOS) return;
    var fullFsyncCalls = 0;
    darwinFullFsyncOverrideForTest = (fd) {
      fullFsyncCalls += 1;
      return 0;
    };
    addTearDown(() => darwinFullFsyncOverrideForTest = null);

    final dir = await Directory.systemTemp.createTemp('airo-macos-sync-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/sync-target.bin');
    await file.writeAsBytes([1, 2, 3, 4]);
    final io = PosixPartialFileIo();
    await io.syncFile(file.path);
    expect(fullFsyncCalls, greaterThan(0));
  });

  test('macOS syncFile fails closed when F_FULLFSYNC fails', () async {
    if (!Platform.isMacOS) return;
    darwinFullFsyncOverrideForTest = (_) => -1;
    addTearDown(() => darwinFullFsyncOverrideForTest = null);

    final dir = await Directory.systemTemp.createTemp('airo-macos-sync-fail-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/sync-target.bin');
    await file.writeAsBytes([9]);

    await expectLater(
      PosixPartialFileIo().syncFile(file.path),
      throwsA(
        isA<FileSystemException>().having(
          (e) => e.message,
          'message',
          'F_FULLFSYNC failed',
        ),
      ),
    );
  });

  test('macOS sync with stored identity rejects inode mismatch', () async {
    if (!Platform.isMacOS) return;
    final dir = await Directory.systemTemp.createTemp('airo-macos-id-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/sync-target.bin');
    await file.writeAsBytes([1]);
    final wrong = PartialFileIdentity(
      deviceId: 0,
      inode: 0,
      linkCount: 1,
      ownerUid: platformCurrentUserId(),
    );
    await expectLater(
      PosixPartialFileIo().syncFile(
        file.path,
        expectedIdentityAtReopen: wrong,
      ),
      throwsA(isA<FileSystemException>()),
    );
  });
}
