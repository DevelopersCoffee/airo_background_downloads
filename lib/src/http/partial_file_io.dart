import 'partial_file_io_impl.dart' as impl;

/// Platform file safety + durability helpers for `.partial` commits.
abstract class PartialFileIo {
  factory PartialFileIo() => impl.createPartialFileIo();

  /// Whether [path] is a regular file we own with a single link (B4/B5).
  PartialPathSafety classifyPartialPath(String path);

  /// Removes a symlink or hardlink entry at [path] without following it.
  void unlinkPartialEntry(String path);

  /// Ensures the destination path is not a symlink before rename (B5).
  void prepareDestinationForCommit(String destinationPath);

  /// Fsync file contents before rename (B7).
  Future<void> syncFile(String path);

  /// Fsync parent directory after rename; no-op on Windows (B7).
  Future<void> syncDirectory(String directoryPath);
}

class PartialPathSafety {
  const PartialPathSafety({
    required this.mayAppend,
    required this.shouldUnlinkEntry,
  });

  /// Safe to open [path] for append.
  final bool mayAppend;

  /// Remove the path entry (symlink / hardlink name) and recreate fresh.
  final bool shouldUnlinkEntry;
}
