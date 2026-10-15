import 'dart:io';

import 'package:airo_background_downloads/src/http/partial_file_stat.dart';
import 'package:airo_background_downloads/src/http/partial_file_writer_posix.dart';
import 'package:airo_background_downloads/src/http/download_directory_guard.dart';
import 'package:airo_background_downloads/src/http/partial_storage_paths.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exclusive partial create uses mode 0600 on POSIX', () async {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    final base = Directory.systemTemp.createTempSync('partial-mode-');
    addTearDown(() => base.deleteSync(recursive: true));
    final destination = '${base.path}/payload.bin';
    ensurePrivatePartialStorage(destination);
    final path = PartialStoragePaths.forDestination(destination).partialPath;
    final writer = PosixPartialFileWriter.open(
      path,
      append: false,
      currentUid: platformCurrentUserId(),
    );
    await writer.close();
    final mode = platformPathMode(path);
    expect(mode, isNotNull);
    expect(mode! & 0x1FF, equals(384)); // 0600
  });

  test('append reopen uses O_NOFOLLOW and enforces identity', () {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    final base = Directory.systemTemp.createTempSync('partial-append-');
    addTearDown(() => base.deleteSync(recursive: true));
    final destination = '${base.path}/payload.bin';
    ensurePrivatePartialStorage(destination);
    final path = PartialStoragePaths.forDestination(destination).partialPath;
    final writer = PosixPartialFileWriter.open(
      path,
      append: false,
      currentUid: platformCurrentUserId(),
    );
    writer.writeBytes([1]);
    writer.close();
    final identity = platformLstat(path)!;

    final appendWriter = PosixPartialFileWriter.open(
      path,
      append: true,
      currentUid: platformCurrentUserId(),
      expectedIdentity: identity,
    );
    appendWriter.writeBytes([2]);
    appendWriter.close();
    expect(File(path).readAsBytesSync(), equals([1, 2]));

    final victim = File('${base.path}/victim.bin')..writeAsBytesSync([9]);
    File(path).deleteSync();
    Link(path).createSync(victim.path);
    expect(
      () => PosixPartialFileWriter.open(
        path,
        append: true,
        currentUid: platformCurrentUserId(),
        expectedIdentity: identity,
      ),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('close still closes fd when fsync fails', () async {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    final base = Directory.systemTemp.createTempSync('partial-fsync-');
    addTearDown(() => base.deleteSync(recursive: true));
    final path = '${base.path}/fsync-fail.partial';
    File(path).createSync();
    final libClose = PosixPartialFileWriter.open(
      path,
      append: true,
      currentUid: platformCurrentUserId(),
      fsyncFn: (_) => -1,
    );
    expect(
      () async => libClose.close(),
      throwsA(isA<FileSystemException>()),
    );
    // Second append open succeeds only if the first fd was closed.
    final second = PosixPartialFileWriter.open(
      path,
      append: true,
      currentUid: platformCurrentUserId(),
    );
    second.writeBytes([1]);
    await second.close();
    expect(File(path).lengthSync(), greaterThan(0));
  });
}
