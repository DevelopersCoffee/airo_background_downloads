import 'partial_file_io_impl.dart' as impl;

import 'partial_file_identity.dart';

/// Platform file safety + durability helpers for `.partial` commits.
abstract class PartialFileIo {
  factory PartialFileIo() => impl.createPartialFileIo();

  PartialPathInspection inspectPath(String path);

  PartialPathSafety classifyPartialPath(String path);

  void unlinkPartialEntry(String path);

  void prepareDestinationForCommit(String destinationPath);

  Future<void> syncFile(
    String path, {
    PartialFileIdentity? expectedIdentityAtReopen,
  });

  /// POSIX: directory fsync via open(O_RDONLY)/fsync.
  ///
  /// **Windows:** intentionally unsupported (no-op that completes successfully).
  /// Desktop HTTP downloads treat missing directory durability as acceptable on
  /// Windows; file-level [syncFile] still runs via FlushFileBuffers.
  Future<void> syncDirectory(String directoryPath);

  /// Opens a partial path for writing without following symlinks, then fstats
  /// the open handle to verify nlink, owner, and optional [expectedIdentity].
  Future<PartialFileWriter> openVerifiedPartialWriter(
    String path, {
    required bool append,
    PartialFileIdentity? expectedIdentity,
  });
}

class PartialPathInspection {
  const PartialPathInspection({
    required this.isAbsent,
    required this.isSymlink,
    required this.isRegularFile,
    required this.linkCount,
    required this.ownedByUs,
    this.identity,
  });

  final bool isAbsent;
  final bool isSymlink;
  final bool isRegularFile;
  final int? linkCount;
  final bool ownedByUs;
  final PartialFileIdentity? identity;

  /// Fail closed: unknown nlink/owner or hardlinked inode is never reusable.
  bool get isSafeRegularFileOwnedByUs =>
      isRegularFile &&
      !isSymlink &&
      linkCount == 1 &&
      ownedByUs &&
      identity != null;
}

class PartialPathSafety {
  const PartialPathSafety({
    required this.mayAppend,
    required this.shouldUnlinkEntry,
  });

  final bool mayAppend;
  final bool shouldUnlinkEntry;
}

abstract class PartialFileWriter {
  PartialFileIdentity get identity;

  void writeBytes(List<int> bytes);

  /// Reads the entire partial from the open fd (POSIX only, before [close]).
  Future<List<int>> readAllBytesFromOpenFd() async {
    throw UnsupportedError('readAllBytesFromOpenFd');
  }

  Future<void> close();
}
