import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

import 'partial_file_identity.dart';
import 'partial_file_io.dart';
import 'partial_file_stat.dart';

class PosixPartialFileWriter implements PartialFileWriter {
  PosixPartialFileWriter._(
    this._fd,
    this.identity,
    this._close,
    this._write,
    this._fsync,
  );

  final int _fd;
  @override
  final PartialFileIdentity identity;
  final CloseDart _close;
  final WriteDart _write;
  final FsyncDart _fsync;

  @override
  void writeBytes(List<int> bytes) {
    if (bytes.isEmpty) return;
    var offset = 0;
    while (offset < bytes.length) {
      final slice = bytes.sublist(offset);
      final buffer = calloc<Uint8>(slice.length);
      try {
        buffer.asTypedList(slice.length).setAll(0, slice);
        final written = _write(_fd, buffer.cast(), slice.length);
        if (written < 0) {
          throw FileSystemException('write failed');
        }
        offset += written;
      } finally {
        calloc.free(buffer);
      }
    }
  }

  @override
  Future<List<int>> readAllBytesFromOpenFd() async {
    final lib = DynamicLibrary.open(
      Platform.isLinux ? 'libc.so.6' : 'libSystem.dylib',
    );
    final lseekFn = lib.lookupFunction<LseekNative, LseekDart>('lseek');
    final readFn = lib.lookupFunction<ReadNative, ReadDart>('read');
    final offset = lseekFn(_fd, 0, _seekSet);
    if (offset < 0) {
      throw FileSystemException('lseek failed for partial fd');
    }
    final chunks = <int>[];
    final buffer = calloc<Uint8>(65536);
    try {
      while (true) {
        final n = readFn(_fd, buffer.cast(), 65536);
        if (n < 0) {
          throw FileSystemException('read failed for partial fd');
        }
        if (n == 0) break;
        chunks.addAll(buffer.asTypedList(n));
      }
    } finally {
      calloc.free(buffer);
    }
    return chunks;
  }

  @override
  Future<void> close() async {
    if (Platform.isLinux) {
      if (_fsync(_fd) != 0) {
        throw FileSystemException('fsync failed for partial fd');
      }
    } else if (Platform.isMacOS) {
      if (_darwinFullFsync(_fd) != 0) {
        throw FileSystemException('F_FULLFSYNC failed for partial fd');
      }
    }
    final result = _close(_fd);
    if (result != 0) {
      throw FileSystemException('close failed for partial fd');
    }
  }

  static PosixPartialFileWriter open(
    String path, {
    required bool append,
    required int currentUid,
    PartialFileIdentity? expectedIdentity,
    PartialFileIdentity? Function(int fd)? fstatFn,
  }) {
    final lib = DynamicLibrary.open(
      Platform.isLinux ? 'libc.so.6' : 'libSystem.dylib',
    );
    final openFn = lib.lookupFunction<OpenNative, OpenDart>('open');
    final closeFn = lib.lookupFunction<CloseNative, CloseDart>('close');
    final writeFn = lib.lookupFunction<WriteNative, WriteDart>('write');
    final fsyncFn = lib.lookupFunction<FsyncNative, FsyncDart>('fsync');

    final flags = append
        ? _openFlagsAppend()
        : _openFlagsCreateExclusive();
    final pathPtr = path.toNativeUtf8();
    try {
      final fd = openFn(pathPtr, flags, 384); // 0600
      if (fd < 0) {
        throw FileSystemException('Cannot open partial without following links', path);
      }
      try {
        final stat = (fstatFn ?? platformFstat)(fd);
        if (stat == null) {
          closeFn(fd);
          throw FileSystemException('fstat failed after open', path);
        }
        if (stat.linkCount != 1) {
          closeFn(fd);
          throw FileSystemException(
            'Refusing to write: partial nlink=${stat.linkCount}',
            path,
          );
        }
        if (stat.ownerUid != currentUid) {
          closeFn(fd);
          throw FileSystemException(
            'Refusing to write: partial owned by uid ${stat.ownerUid}',
            path,
          );
        }
        if (expectedIdentity != null && !expectedIdentity.matches(stat)) {
          closeFn(fd);
          throw FileSystemException(
            'Refusing to write: partial identity changed',
            path,
          );
        }
        return PosixPartialFileWriter._(fd, stat, closeFn, writeFn, fsyncFn);
      } on Object {
        closeFn(fd);
        rethrow;
      }
    } finally {
      malloc.free(pathPtr);
    }
  }
}

int _openFlagsAppend() {
  if (Platform.isLinux) {
    return _linuxOWronly | _linuxOAppend | _linuxONoFollow;
  }
  // macOS: O_RDWR so SHA-256 can read back from the open fd before close.
  // Re-open for append omits O_NOFOLLOW; the path was sanitized at job start.
  return _darwinORdwr | _darwinOAppend;
}

int _openFlagsCreateExclusive() {
  if (Platform.isLinux) {
    return _linuxOWronly | _linuxOCreat | _linuxOExcl | _linuxONoFollow;
  }
  return _darwinORdwr | _darwinOCreat | _darwinOExcl | _darwinONoFollow;
}

// Linux fcntl.h
const _linuxOWronly = 1;
const _linuxOCreat = 64;
const _linuxOExcl = 128;
const _linuxOAppend = 1024;
const _linuxONoFollow = 0x8000; // 0100000 octal

// Darwin fcntl.h
const _darwinORdwr = 0x0002;
const _darwinOCreat = 0x0200;
const _darwinOExcl = 0x0800;
const _darwinOAppend = 0x0008;
const _darwinONoFollow = 0x0100;

typedef OpenNative = Int32 Function(Pointer<Utf8>, Int32, Int32);
typedef OpenDart = int Function(Pointer<Utf8>, int, int);
typedef CloseNative = Int32 Function(Int32);
typedef CloseDart = int Function(int);
typedef WriteNative =
    IntPtr Function(Int32 fd, Pointer<Void> buf, IntPtr count);
typedef WriteDart = int Function(int fd, Pointer<Void> buf, int count);
typedef FsyncNative = Int32 Function(Int32);
typedef FsyncDart = int Function(int);
typedef LseekNative = Int64 Function(Int32, Int64, Int32);
typedef LseekDart = int Function(int, int, int);
typedef ReadNative = IntPtr Function(Int32, Pointer<Void>, IntPtr);
typedef ReadDart = int Function(int, Pointer<Void>, int);

const _seekSet = 0;

// Darwin fcntl.h — F_FULLFSYNC
const _darwinFullFsyncCmd = 51;

int _darwinFullFsync(int fd) {
  final lib = DynamicLibrary.open('libSystem.dylib');
  final fcntlFn = lib.lookupFunction<FcntlNative, FcntlDart>('fcntl');
  return fcntlFn(fd, _darwinFullFsyncCmd, 0);
}

typedef FcntlNative = Int32 Function(Int32, Int32, Int32);
typedef FcntlDart = int Function(int, int, int);
