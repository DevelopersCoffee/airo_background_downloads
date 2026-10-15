import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'partial_file_identity.dart';
import 'partial_file_io.dart';
import 'partial_file_stat.dart';
import 'partial_file_writer_windows.dart';

base class WindowsPartialFileIo implements PartialFileIo {
  WindowsPartialFileIo() {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    _createFileW = kernel32.lookupFunction<CreateFileWNative, CreateFileWDart>(
      'CreateFileW',
    );
    _flushFileBuffers = kernel32.lookupFunction<
        FlushFileBuffersNative,
        FlushFileBuffersDart>('FlushFileBuffers');
    _closeHandle = kernel32.lookupFunction<CloseHandleNative, CloseHandleDart>(
      'CloseHandle',
    );
  }

  late final CreateFileWDart _createFileW;
  late final FlushFileBuffersDart _flushFileBuffers;
  late final CloseHandleDart _closeHandle;

  static const _genericWrite = 0x40000000;
  static const _fileShareRead = 0x00000001;
  static const _fileShareWrite = 0x00000002;
  static const _openExisting = 3;
  static const _fileAttributeNormal = 0x00000080;
  static const _invalidHandle = -1;

  @override
  PartialPathInspection inspectPath(String path) {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return const PartialPathInspection(
        isAbsent: true,
        isSymlink: false,
        isRegularFile: false,
        linkCount: null,
        ownedByUs: false,
      );
    }
    if (type == FileSystemEntityType.link) {
      return const PartialPathInspection(
        isAbsent: false,
        isSymlink: true,
        isRegularFile: false,
        linkCount: null,
        ownedByUs: false,
      );
    }
    if (type != FileSystemEntityType.file) {
      return const PartialPathInspection(
        isAbsent: false,
        isSymlink: false,
        isRegularFile: false,
        linkCount: null,
        ownedByUs: false,
      );
    }
    final stat = platformLstat(path);
    if (stat == null) {
      return const PartialPathInspection(
        isAbsent: false,
        isSymlink: false,
        isRegularFile: true,
        linkCount: null,
        ownedByUs: false,
      );
    }
    // Windows has no portable POSIX owner uid; nlink is enforced instead.
    return PartialPathInspection(
      isAbsent: false,
      isSymlink: false,
      isRegularFile: true,
      linkCount: stat.linkCount,
      ownedByUs: true,
      identity: stat,
    );
  }

  @override
  PartialPathSafety classifyPartialPath(String path) {
    final inspection = inspectPath(path);
    if (inspection.isAbsent) {
      return const PartialPathSafety(mayAppend: false, shouldUnlinkEntry: false);
    }
    if (!inspection.isSafeRegularFileOwnedByUs) {
      return const PartialPathSafety(mayAppend: false, shouldUnlinkEntry: true);
    }
    return const PartialPathSafety(mayAppend: true, shouldUnlinkEntry: false);
  }

  @override
  void unlinkPartialEntry(String path) {
    try {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) return;
      if (type == FileSystemEntityType.link) {
        Link(path).deleteSync();
        return;
      }
      File(path).deleteSync();
    } on FileSystemException {
      // Best effort.
    }
  }

  @override
  void prepareDestinationForCommit(String destinationPath) {
    final type = FileSystemEntity.typeSync(
      destinationPath,
      followLinks: false,
    );
    if (type == FileSystemEntityType.link) {
      Link(destinationPath).deleteSync();
    }
  }

  @override
  Future<void> syncFile(String path) async {
    if (!File(path).existsSync()) {
      throw FileSystemException('Cannot fsync missing file', path);
    }
    final handle = _openWriteHandle(path);
    if (handle == _invalidHandle) {
      throw FileSystemException('Cannot open file for fsync', path);
    }
    try {
      final flushed = _flushFileBuffers(handle);
      if (flushed == 0) {
        throw FileSystemException('FlushFileBuffers failed', path);
      }
    } finally {
      final closed = _closeHandle(handle);
      if (closed == 0) {
        throw FileSystemException('CloseHandle failed after fsync', path);
      }
    }
  }

  /// Windows has no supported directory durability hook; see [PartialFileIo.syncDirectory].
  @override
  Future<void> syncDirectory(String directoryPath) async {}

  @override
  Future<PartialFileWriter> openVerifiedPartialWriter(
    String path, {
    required bool append,
    PartialFileIdentity? expectedIdentity,
  }) async {
    return WindowsPartialFileWriter.open(
      path,
      append: append,
      expectedIdentity: expectedIdentity,
    );
  }

  int _openWriteHandle(String path) {
    final pathPtr = path.toNativeUtf16();
    try {
      return _createFileW(
        pathPtr,
        _genericWrite,
        _fileShareRead | _fileShareWrite,
        nullptr,
        _openExisting,
        _fileAttributeNormal,
        nullptr,
      );
    } finally {
      malloc.free(pathPtr);
    }
  }
}

typedef CreateFileWNative =
    IntPtr Function(
      Pointer<Utf16> lpFileName,
      Uint32 dwDesiredAccess,
      Uint32 dwShareMode,
      Pointer<Void> lpSecurityAttributes,
      Uint32 dwCreationDisposition,
      Uint32 dwFlagsAndAttributes,
      Pointer<Void> hTemplateFile,
    );
typedef CreateFileWDart =
    int Function(
      Pointer<Utf16> lpFileName,
      int dwDesiredAccess,
      int dwShareMode,
      Pointer<Void> lpSecurityAttributes,
      int dwCreationDisposition,
      int dwFlagsAndAttributes,
      Pointer<Void> hTemplateFile,
    );
typedef FlushFileBuffersNative = Int32 Function(IntPtr hFile);
typedef FlushFileBuffersDart = int Function(int hFile);
typedef CloseHandleNative = Int32 Function(IntPtr hObject);
typedef CloseHandleDart = int Function(int hObject);
