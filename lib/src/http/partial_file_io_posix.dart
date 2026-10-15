import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'partial_file_io.dart';
import 'partial_file_stat.dart';

base class PosixPartialFileIo implements PartialFileIo {
  PosixPartialFileIo() {
    if (Platform.isLinux || Platform.isMacOS) {
      final lib = DynamicLibrary.open(
        Platform.isLinux ? 'libc.so.6' : 'libSystem.dylib',
      );
      _open = lib.lookupFunction<OpenNative, OpenDart>('open');
      _fsync = lib.lookupFunction<FsyncNative, FsyncDart>('fsync');
      _close = lib.lookupFunction<CloseNative, CloseDart>('close');
    }
  }

  OpenDart? _open;
  FsyncDart? _fsync;
  CloseDart? _close;
  final _uid = platformCurrentUserId();

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
    final stat = platformLinkCountAndOwner(path);
    final owned = stat == null || stat.uid == _uid;
    return PartialPathInspection(
      isAbsent: false,
      isSymlink: false,
      isRegularFile: true,
      linkCount: stat?.nlink,
      ownedByUs: owned,
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
    final raf = await File(path).open(mode: FileMode.read);
    try {
      await raf.flush();
    } finally {
      await raf.close();
    }
  }

  @override
  Future<void> syncDirectory(String directoryPath) async {
    final open = _open;
    final fsync = _fsync;
    final close = _close;
    if (open == null || fsync == null || close == null) {
      throw FileSystemException(
        'Directory fsync unavailable on this platform',
        directoryPath,
      );
    }
    final pathPtr = directoryPath.toNativeUtf8();
    try {
      final flags = Platform.isLinux ? _oRdonly | _oDirectory : _oRdonly;
      final fd = open(pathPtr, flags);
      if (fd < 0) {
        throw FileSystemException('Cannot open directory for fsync', directoryPath);
      }
      try {
        final result = fsync(fd);
        if (result != 0) {
          throw FileSystemException('fsync failed for directory', directoryPath);
        }
      } finally {
        final closed = close(fd);
        if (closed != 0) {
          throw FileSystemException('close failed for directory fd', directoryPath);
        }
      }
    } finally {
      malloc.free(pathPtr);
    }
  }
}

const _oRdonly = 0;
const _oDirectory = 0x00010000;

typedef OpenNative = Int32 Function(Pointer<Utf8>, Int32);
typedef OpenDart = int Function(Pointer<Utf8>, int);
typedef FsyncNative = Int32 Function(Int32);
typedef FsyncDart = int Function(int);
typedef CloseNative = Int32 Function(Int32);
typedef CloseDart = int Function(int);
