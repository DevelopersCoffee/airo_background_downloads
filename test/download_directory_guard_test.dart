import 'dart:io';

import 'package:airo_background_downloads/src/http/download_directory_guard.dart';
import 'package:airo_background_downloads/src/http/partial_file_stat.dart';
import 'package:airo_background_downloads/src/http/partial_file_writer_posix.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('creates download directory as 0700 owned by us', () {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    final base = Directory.systemTemp.createTempSync('dl-dir-');
    addTearDown(() => base.deleteSync(recursive: true));
    final target = '${base.path}/nested/downloads';
    ensurePrivateDownloadDirectory(target);
    final mode = File(target).statSync().mode & 0x1FF;
    expect(mode & 63, equals(0));
    final stat = platformLstat(target);
    expect(stat, isNotNull);
    expect(stat!.ownerUid, equals(platformCurrentUserId()));
    expect(stat.linkCount, greaterThanOrEqualTo(1));
  });

  test('refuses symlinked download directory', () async {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    final base = Directory.systemTemp.createTempSync('dl-dir-symlink-');
    addTearDown(() => base.deleteSync(recursive: true));
    final victim = Directory('${base.path}/real');
    victim.createSync();
    final linkPath = '${base.path}/linked';
    await Link(linkPath).create(victim.path);
    expect(
      () => ensurePrivateDownloadDirectory(linkPath),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('posix partial writer works in ensured download directory', () {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    final base = Directory.systemTemp.createTempSync('writer-');
    addTearDown(() => base.deleteSync(recursive: true));
    ensurePrivateDownloadDirectory(base.path);
    final path = '${base.path}/x.partial';
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
