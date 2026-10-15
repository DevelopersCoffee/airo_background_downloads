import 'dart:io';

import 'partial_file_io.dart';

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
    _sanitizeOne(metaPath);
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
    return File(partialPath).lengthSync();
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
