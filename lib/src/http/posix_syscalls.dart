import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Injectable POSIX syscalls used for directory durability (tests + production).
abstract class PosixSyscalls {
  int openDirectory(String path, int flags);

  int fsync(int fd);

  int close(int fd);
}

/// Production [PosixSyscalls] backed by libc.
class LibcPosixSyscalls implements PosixSyscalls {
  LibcPosixSyscalls() {
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
  int openDirectory(String path, int flags) {
    final open = _open;
    if (open == null) return -1;
    final pathPtr = path.toNativeUtf8();
    try {
      return open(pathPtr, flags);
    } finally {
      malloc.free(pathPtr);
    }
  }

  @override
  int fsync(int fd) => _fsync?.call(fd) ?? -1;

  @override
  int close(int fd) => _close?.call(fd) ?? -1;
}

typedef OpenNative = Int32 Function(Pointer<Utf8>, Int32);
typedef OpenDart = int Function(Pointer<Utf8>, int);
typedef FsyncNative = Int32 Function(Int32);
typedef FsyncDart = int Function(int);
typedef CloseNative = Int32 Function(Int32);
typedef CloseDart = int Function(int);
