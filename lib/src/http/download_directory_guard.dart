import 'dart:io';

import 'partial_file_stat.dart';
import 'partial_storage_paths.dart';
import 'posix_variadic.dart';

const _privateDirMode = 0x1C0; // 0700

/// Ensures [PartialStoragePaths.storageDirectory] exists and is private (0700, owned by us, not a symlink).
///
/// Never chmods the destination parent or any pre-existing user directory.
void ensurePrivatePartialStorage(String destinationPath) {
  if (destinationPath.isEmpty) {
    throw FileSystemException('Destination path is empty');
  }
  if (Platform.isWindows) {
    _ensureWindowsPartialStorage(destinationPath);
    return;
  }
  if (!Platform.isLinux && !Platform.isMacOS) {
    final paths = PartialStoragePaths.forDestination(destinationPath);
    Directory(paths.storageDirectory).createSync(recursive: true);
    return;
  }

  final destParent = File(destinationPath).parent;
  if (!destParent.existsSync()) {
    destParent.createSync(recursive: true);
  }

  final paths = PartialStoragePaths.forDestination(destinationPath);
  _ensurePrivatePosixLeaf(paths.storageDirectory);
}

void _ensurePrivatePosixLeaf(String directoryPath) {
  final type = FileSystemEntity.typeSync(directoryPath, followLinks: false);
  if (type == FileSystemEntityType.link) {
    throw FileSystemException(
      'Partial storage directory cannot be a symlink',
      directoryPath,
    );
  }
  if (type == FileSystemEntityType.notFound) {
    for (var attempt = 0; attempt < 3; attempt++) {
      if (Directory(directoryPath).existsSync()) {
        break;
      }
      final result = posixMkdir(directoryPath, _privateDirMode);
      if (result == 0 || Directory(directoryPath).existsSync()) {
        break;
      }
      if (attempt == 2) {
        throw FileSystemException(
          'Cannot create partial storage directory',
          directoryPath,
        );
      }
    }
  }
  _verifyPrivatePosixDirectory(directoryPath);
}

void _verifyPrivatePosixDirectory(String directoryPath) {
  final type = FileSystemEntity.typeSync(directoryPath, followLinks: false);
  if (type == FileSystemEntityType.link) {
    throw FileSystemException(
      'Partial storage directory cannot be a symlink',
      directoryPath,
    );
  }
  if (type == FileSystemEntityType.notFound) {
    throw FileSystemException('Partial storage directory missing', directoryPath);
  }
  final stat = platformLstat(directoryPath);
  if (stat == null) {
    throw FileSystemException(
      'Cannot stat partial storage directory',
      directoryPath,
    );
  }
  final uid = platformCurrentUserId();
  if (stat.ownerUid != uid) {
    throw FileSystemException(
      'Partial storage directory not owned by current user',
      directoryPath,
    );
  }
  if (stat.linkCount < 1) {
    throw FileSystemException(
      'Partial storage directory has invalid link count',
      directoryPath,
    );
  }
  final mode = platformPathMode(directoryPath);
  if (mode == null) {
    throw FileSystemException(
      'Cannot read mode of partial storage directory',
      directoryPath,
    );
  }
  if ((mode & 0x1FF) & 63 != 0) {
    throw FileSystemException(
      'Partial storage directory must be mode 0700 (no group/other access)',
      directoryPath,
    );
  }
}

void _ensureWindowsPartialStorage(String destinationPath) {
  final paths = PartialStoragePaths.forDestination(destinationPath);
  final destParent = File(destinationPath).parent;
  if (!destParent.existsSync()) {
    destParent.createSync(recursive: true);
  }
  Directory(paths.storageDirectory).createSync(recursive: true);
  final type = FileSystemEntity.typeSync(
    paths.storageDirectory,
    followLinks: false,
  );
  if (type == FileSystemEntityType.link) {
    throw FileSystemException(
      'Partial storage directory cannot be a symlink',
      paths.storageDirectory,
    );
  }
}
