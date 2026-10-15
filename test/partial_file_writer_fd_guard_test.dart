import 'dart:io';

import 'package:airo_background_downloads/src/http/partial_file_identity.dart';
import 'package:airo_background_downloads/src/http/partial_file_stat.dart';
import 'package:airo_background_downloads/src/http/partial_file_writer_posix.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fd-level nlink check rejects hardlinked inode when path lstat says nlink 1', () {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    final dir = Directory.systemTemp.createTempSync('fd-nlink-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/partial.bin';
    final file = File(path)..createSync();
    file.writeAsBytesSync([1, 2, 3]);
    final real = platformLstat(path)!;
    expect(
      () => PosixPartialFileWriter.open(
        path,
        append: true,
        currentUid: platformCurrentUserId(),
        expectedIdentity: real,
        fstatFn: (_) => PartialFileIdentity(
          deviceId: real.deviceId,
          inode: real.inode,
          linkCount: 2,
          ownerUid: real.ownerUid,
        ),
      ),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('fd-level owner check rejects foreign uid when path lstat looks owned', () {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    final dir = Directory.systemTemp.createTempSync('fd-owner-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/partial.bin';
    File(path).createSync();
    final real = platformLstat(path)!;
    final me = platformCurrentUserId();
    expect(
      () => PosixPartialFileWriter.open(
        path,
        append: true,
        currentUid: me,
        expectedIdentity: real,
        fstatFn: (_) => PartialFileIdentity(
          deviceId: real.deviceId,
          inode: real.inode,
          linkCount: 1,
          ownerUid: me + 1,
        ),
      ),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('fd-level identity check rejects changed dev/ino on append', () {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    final dir = Directory.systemTemp.createTempSync('fd-identity-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/partial.bin';
    File(path).createSync();
    final real = platformLstat(path)!;
    expect(
      () => PosixPartialFileWriter.open(
        path,
        append: true,
        currentUid: platformCurrentUserId(),
        expectedIdentity: real,
        fstatFn: (_) => PartialFileIdentity(
          deviceId: real.deviceId + 1,
          inode: real.inode + 1,
          linkCount: 1,
          ownerUid: real.ownerUid,
        ),
      ),
      throwsA(isA<FileSystemException>()),
    );
  });
}
