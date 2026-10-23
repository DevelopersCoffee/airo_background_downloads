import 'dart:io';

import 'package:flutter/foundation.dart';

import 'partial_file_stat.dart';
import 'partial_storage_paths.dart';

@visibleForTesting
void Function(String destinationPath)?
    removeEmptyPartialStorageOverrideForTest;

/// Removes [PartialStoragePaths.storageDirectory] when it is empty and still ours.
///
/// Best-effort only: never throws; failures must not affect download status/events.
void tryRemoveEmptyPartialStorageDirectory(String destinationPath) {
  try {
    final override = removeEmptyPartialStorageOverrideForTest;
    if (override != null) {
      override(destinationPath);
      return;
    }
    _removeEmptyPartialStorageDirectoryImpl(destinationPath);
  } on Object {
    // Best effort — ignore AV locks, read-only parents, concurrent mkdir races, etc.
  }
}

void _removeEmptyPartialStorageDirectoryImpl(String destinationPath) {
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
