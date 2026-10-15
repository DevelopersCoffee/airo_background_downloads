import 'dart:io';

import 'package:airo_background_downloads/src/http/download_directory_guard.dart';
import 'package:airo_background_downloads/src/http/partial_storage_paths.dart';
import 'package:airo_background_downloads/src/http/partial_file_stat.dart';
import 'package:airo_background_downloads/src/http/partial_file_writer_posix.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('creates .airo_partials as 0700 owned by us', () {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    final base = Directory.systemTemp.createTempSync('dl-dir-');
    addTearDown(() => base.deleteSync(recursive: true));
    final destination = '${base.path}/nested/model.bin';
    ensurePrivatePartialStorage(destination);
    final storage = PartialStoragePaths.forDestination(destination).storageDirectory;
    final mode = platformPathMode(storage)! & 0x1FF;
    expect(mode & 63, equals(0));
    final stat = platformLstat(storage);
    expect(stat, isNotNull);
    expect(stat!.ownerUid, equals(platformCurrentUserId()));
    expect(stat.linkCount, greaterThanOrEqualTo(1));
  });

  test('does not chmod an existing 0755 parent directory', () {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    final base = Directory.systemTemp.createTempSync('dl-parent-mode-');
    addTearDown(() => base.deleteSync(recursive: true));
    final parent = Directory('${base.path}/Documents');
    parent.createSync();
    final before = parent.statSync().mode & 0x1FF;
    expect(before & 511, equals(493)); // 0777 mask, expect 0755
    final destination = '${parent.path}/m.bin';
    ensurePrivatePartialStorage(destination);
    final after = parent.statSync().mode & 0x1FF;
    expect(after, equals(before));
    expect(
      Directory(PartialStoragePaths.forDestination(destination).storageDirectory)
          .existsSync(),
      isTrue,
    );
  });

  test('refuses symlinked partial storage directory', () async {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    final base = Directory.systemTemp.createTempSync('dl-dir-symlink-');
    addTearDown(() => base.deleteSync(recursive: true));
    final victim = Directory('${base.path}/real');
    victim.createSync();
    final linkPath =
        '${base.path}${Platform.pathSeparator}$airoPartialsDirectoryName';
    await Link(linkPath).create(victim.path);
    expect(
      () => ensurePrivatePartialStorage('${base.path}/file.bin'),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('system temp destination uses private .airo_partials leaf', () {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    final destination = '${Directory.systemTemp.path}/airo-dl-e3-${DateTime.now().microsecondsSinceEpoch}.bin';
    ensurePrivatePartialStorage(destination);
    final storage = PartialStoragePaths.forDestination(destination).storageDirectory;
    expect(Directory(storage).existsSync(), isTrue);
    final mode = platformPathMode(storage)! & 0x1FF;
    expect(mode & 63, equals(0));
  });

  test('posix partial writer works under ensured partial storage', () {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    final base = Directory.systemTemp.createTempSync('writer-');
    addTearDown(() => base.deleteSync(recursive: true));
    final destination = '${base.path}/x.bin';
    ensurePrivatePartialStorage(destination);
    final path = PartialStoragePaths.forDestination(destination).partialPath;
    final writer = PosixPartialFileWriter.open(
      path,
      append: false,
      currentUid: platformCurrentUserId(),
    );
    writer.writeBytes([1, 2]);
    writer.close();
    expect(File(path).lengthSync(), equals(2));
  });
}
