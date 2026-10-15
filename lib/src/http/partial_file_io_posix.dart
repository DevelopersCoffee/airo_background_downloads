import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'partial_file_io.dart';

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

  @override
  PartialPathSafety classifyPartialPath(String path) {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return const PartialPathSafety(mayAppend: false, shouldUnlinkEntry: false);
    }
    if (type != FileSystemEntityType.file) {
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
    final file = File(path);
    if (!await file.exists()) return;
    final raf = await file.open(mode: FileMode.read);
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
    if (open == null || fsync == null || close == null) return;
    final pathPtr = directoryPath.toNativeUtf8();
    try {
      final flags = Platform.isLinux ? _oRdonly | _oDirectory : _oRdonly;
      final fd = open(pathPtr, flags);
      if (fd < 0) return;
      try {
        fsync(fd);
      } finally {
        close(fd);
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
