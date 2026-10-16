import 'dart:io';

import 'partial_file_io.dart';
import 'partial_file_stat.dart';

/// Sanitizes download temp paths without following symlinks.
class PartialPathGuard {
  PartialPathGuard(this._io);

  final PartialFileIo _io;

  void sanitizeAllForJob({
    required String destinationPath,
    required String partialPath,
    required String metaPath,
  }) {
    final dest = _io.inspectPath(destinationPath);
    if (dest.isSymlink) {
      _io.unlinkPartialEntry(destinationPath);
    }
    _sanitizeOne(partialPath);
    _sanitizeOne('$partialPath.work');
    _sanitizeMeta(metaPath);
  }

  /// `.meta` is app-owned JSON; do not require inode identity parity with partials.
  void _sanitizeMeta(String metaPath) {
    final type = FileSystemEntity.typeSync(metaPath, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type == FileSystemEntityType.link ||
        type != FileSystemEntityType.file) {
      _io.unlinkPartialEntry(metaPath);
    }
  }

  void _sanitizeOne(String path) {
    final inspection = _io.inspectPath(path);
    if (inspection.isAbsent) return;
    if (inspection.isSafeRegularFileOwnedByUs) return;
    _io.unlinkPartialEntry(path);
  }

  /// Returns byte length when [partialPath] is a reusable regular file.
  int reusablePartialBytes(String partialPath) {
    final inspection = _io.inspectPath(partialPath);
    if (!inspection.isSafeRegularFileOwnedByUs) {
      if (!inspection.isAbsent) {
        _io.unlinkPartialEntry(partialPath);
      }
      return 0;
    }
    final size = platformPathFileSize(partialPath);
    if (size == null || size < 0) {
      // Keep the partial when lstat size is unavailable (macOS libc 0600);
      // resume byte count may still come from `.meta`.
      return 0;
    }
    return size;
  }

  Future<void> createExclusiveEmptyFile(String path) async {
    _sanitizeOne(path);
    final writer = await _io.openVerifiedPartialWriter(path, append: false);
    await writer.close();
  }

  void requireSafeRegularPartialBeforeCommit(String partialPath) {
    final inspection = _io.inspectPath(partialPath);
    if (!inspection.isSafeRegularFileOwnedByUs) {
      throw FileSystemException(
        'Refusing to commit: partial is not a safe regular file',
        partialPath,
      );
    }
  }
}
