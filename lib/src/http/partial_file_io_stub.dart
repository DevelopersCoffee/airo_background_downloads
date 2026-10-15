import 'partial_file_io.dart';

class StubPartialFileIo implements PartialFileIo {
  @override
  PartialPathInspection inspectPath(String path) =>
      const PartialPathInspection(
        isAbsent: true,
        isSymlink: false,
        isRegularFile: false,
        linkCount: null,
        ownedByUs: false,
      );

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
