import 'dart:io';

import 'partial_file_identity.dart';
import 'partial_file_io.dart';

/// Fallback writer when native create/append flags are finicky (Windows append).
class DartAppendPartialWriter implements PartialFileWriter {
  DartAppendPartialWriter._(this._raf, this.identity);

  final RandomAccessFile _raf;
  @override
  final PartialFileIdentity identity;

  static Future<DartAppendPartialWriter> open(
    String path,
    PartialPathInspection inspection,
  ) async {
    if (!inspection.isSafeRegularFileOwnedByUs || inspection.identity == null) {
      throw FileSystemException('Refusing to append: partial is not safe', path);
    }
    final raf = await File(path).open(mode: FileMode.append);
    return DartAppendPartialWriter._(raf, inspection.identity!);
  }

  @override
  void writeBytes(List<int> bytes) {
    _raf.writeFromSync(bytes);
  }

  @override
  Future<void> close() async {
    await _raf.flush();
    await _raf.close();
  }
}

class DartCreatePartialWriter implements PartialFileWriter {
  DartCreatePartialWriter._(this._raf, this.identity);

  final RandomAccessFile _raf;
  @override
  final PartialFileIdentity identity;

  static Future<DartCreatePartialWriter> createEmpty(
    PartialFileIo io,
    String path,
  ) async {
    io.unlinkPartialEntry(path);
    if (Platform.isMacOS) {
      for (var i = 0; i < 3; i++) {
        final type = FileSystemEntity.typeSync(path, followLinks: false);
        if (type == FileSystemEntityType.notFound) break;
        io.unlinkPartialEntry(path);
      }
    }
    final file = File(path);
    file.createSync(exclusive: true);
    final inspection = io.inspectPath(path);
    if (!inspection.isSafeRegularFileOwnedByUs || inspection.identity == null) {
      throw FileSystemException('Refusing to create partial', path);
    }
    final raf = await file.open(mode: FileMode.write);
    return DartCreatePartialWriter._(raf, inspection.identity!);
  }

  @override
  void writeBytes(List<int> bytes) {
    _raf.writeFromSync(bytes);
  }

  @override
  Future<void> close() async {
    await _raf.flush();
    await _raf.close();
  }
}
