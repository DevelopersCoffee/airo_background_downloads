import 'partial_file_io_impl.dart' as impl;

/// Platform file safety + durability helpers for `.partial` commits.
abstract class PartialFileIo {
  factory PartialFileIo() => impl.createPartialFileIo();

  PartialPathInspection inspectPath(String path);

  PartialPathSafety classifyPartialPath(String path);

  void unlinkPartialEntry(String path);

  void prepareDestinationForCommit(String destinationPath);

  Future<void> syncFile(String path);

  Future<void> syncDirectory(String directoryPath);
}

class PartialPathInspection {
  const PartialPathInspection({
    required this.isAbsent,
    required this.isSymlink,
    required this.isRegularFile,
    required this.linkCount,
    required this.ownedByUs,
  });

  final bool isAbsent;
  final bool isSymlink;
  final bool isRegularFile;
  final int? linkCount;
  final bool ownedByUs;

  bool get isSafeRegularFileOwnedByUs =>
      isRegularFile &&
      !isSymlink &&
      (linkCount == null || linkCount == 1) &&
      ownedByUs;
}

class PartialPathSafety {
  const PartialPathSafety({
    required this.mayAppend,
    required this.shouldUnlinkEntry,
  });

  final bool mayAppend;
  final bool shouldUnlinkEntry;
}
