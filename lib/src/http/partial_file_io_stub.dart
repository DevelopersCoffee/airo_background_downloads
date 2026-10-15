import 'partial_file_io.dart';

/// Fallback when dart:io is unavailable (unused on desktop downloads).
class StubPartialFileIo implements PartialFileIo {
  @override
  PartialPathSafety classifyPartialPath(String path) =>
      const PartialPathSafety(mayAppend: true, shouldUnlinkEntry: false);

  @override
  void unlinkPartialEntry(String path) {}

  @override
  void prepareDestinationForCommit(String destinationPath) {}

  @override
  Future<void> syncFile(String path) async {}

  @override
  Future<void> syncDirectory(String directoryPath) async {}
}
