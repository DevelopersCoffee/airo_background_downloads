import 'dart:io';

import 'partial_file_stat.dart';
import 'partial_storage_paths.dart';

/// Removes [PartialStoragePaths.storageDirectory] when it is empty and still ours.
void tryRemoveEmptyPartialStorageDirectory(String destinationPath) {
  final storagePath =
      PartialStoragePaths.forDestination(destinationPath).storageDirectory;
  final dir = Directory(storagePath);
  if (!dir.existsSync()) {
    return;
  }
  if (Platform.isWindows) {
    final type = FileSystemEntity.typeSync(storagePath, followLinks: false);
    if (type == FileSystemEntityType.link) {
      return;
    }
    if (dir.listSync(followLinks: false).isNotEmpty) {
      return;
    }
    dir.deleteSync();
    return;
  }
  if (!Platform.isLinux && !Platform.isMacOS) {
    return;
  }
  final type = FileSystemEntity.typeSync(storagePath, followLinks: false);
  if (type == FileSystemEntityType.link) {
    return;
  }
  final stat = platformLstat(storagePath);
  if (stat == null || stat.ownerUid != platformCurrentUserId()) {
    return;
  }
  final mode = platformPathMode(storagePath);
  if (mode == null || (mode & 0x1FF) & 63 != 0) {
    return;
  }
  if (dir.listSync(followLinks: false).isNotEmpty) {
    return;
  }
  dir.deleteSync();
}
