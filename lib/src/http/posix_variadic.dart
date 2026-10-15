import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'partial_file_identity.dart';
import 'partial_file_stat.dart';

DynamicLibrary posixLib() {
  return DynamicLibrary.open(
    Platform.isLinux ? 'libc.so.6' : 'libSystem.dylib',
  );
}

int posixOpen(String path, int flags, {int? mode}) {
  final pathPtr = path.toNativeUtf8();
  try {
    if (mode != null) {
      return _posixOpen3(pathPtr, flags, mode);
    }
    return _posixOpen2(pathPtr, flags);
  } finally {
    malloc.free(pathPtr);
  }
}

final int Function(Pointer<Utf8>, int) _posixOpen2 = posixLib()
    .lookupFunction<
        Int32 Function(Pointer<Utf8>, Int32),
        int Function(Pointer<Utf8>, int)>('open');

final int Function(Pointer<Utf8>, int, int) _posixOpen3 = posixLib()
    .lookupFunction<
        Int32 Function(Pointer<Utf8>, Int32, VarArgs<(Int32,)>),
        int Function(Pointer<Utf8>, int, int)>('open');

int posixFcntl(int fd, int cmd, [int arg = 0]) {
  return _posixFcntl(fd, cmd, arg);
}

final int Function(int, int, int) _posixFcntl = posixLib()
    .lookupFunction<
        Int32 Function(Int32, Int32, VarArgs<(Int32,)>),
        int Function(int, int, int)>('fcntl');

typedef MkdirNative = Int32 Function(Pointer<Utf8>, Int32);
typedef MkdirDart = int Function(Pointer<Utf8>, int);

int posixMkdir(String path, int mode) {
  final mkdirFn = posixLib().lookupFunction<MkdirNative, MkdirDart>('mkdir');
  final pathPtr = path.toNativeUtf8();
  try {
    return mkdirFn(pathPtr, mode);
  } finally {
    malloc.free(pathPtr);
  }
}

/// Darwin `fcntl(F_FULLFSYNC)` — flush buffers and force on-storage durability.
const darwinFullFsyncCmd = 51;

int posixDarwinFullFsync(int fd) => posixFcntl(fd, darwinFullFsyncCmd);

int posixFchmod(int fd, int mode) {
  final fchmodFn = posixLib().lookupFunction<
      Int32 Function(Int32, Int32),
      int Function(int, int)>('fchmod');
  return fchmodFn(fd, mode);
}

/// Current process umask without permanently changing it.
int posixCurrentUmask() {
  final umaskFn = posixLib().lookupFunction<
      Int32 Function(Int32),
      int Function(int)>('umask');
  final previous = umaskFn(0);
  umaskFn(previous);
  return previous & 511; // 0777
}

/// Mode for committed regular files: `0666 & ~umask`.
int posixCommittedRegularFileMode() =>
    (438 & ~posixCurrentUmask()) & 511; // 0666 & ~umask & 0777

void _posixCloseChecked(int fd, String path) {
  final closeFn = posixLib().lookupFunction<
      Int32 Function(Int32),
      int Function(int)>('close');
  if (closeFn(fd) != 0) {
    throw FileSystemException('close failed', path);
  }
}

void _verifyReopenedIdentity(int fd, String path, PartialFileIdentity? expected) {
  if (expected == null) return;
  final stat = platformFstat(fd);
  if (stat == null || !expected.matches(stat)) {
    throw FileSystemException(
      'Partial file identity changed after reopen',
      path,
    );
  }
}

int _openReadOnlyNoFollow(String path) {
  const linuxORdonly = 0;
  const linuxONoFollow = 0x8000;
  const darwinORdonly = 0;
  const darwinONoFollow = 0x0100;
  final flags = Platform.isLinux
      ? linuxORdonly | linuxONoFollow
      : darwinORdonly | darwinONoFollow;
  return posixOpen(path, flags);
}

void _syncOpenFd(int fd, String path) {
  if (Platform.isMacOS) {
    if (posixDarwinFullFsync(fd) != 0) {
      throw FileSystemException('F_FULLFSYNC failed', path);
    }
    return;
  }
  final fsyncFn = posixLib().lookupFunction<
      Int32 Function(Int32),
      int Function(int)>('fsync');
  if (fsyncFn(fd) != 0) {
    throw FileSystemException('fsync failed', path);
  }
}

/// macOS [PartialFileIo.syncFile]: `open(O_RDONLY|O_NOFOLLOW)` + `F_FULLFSYNC`.
void posixSyncRegularFileViaFd(
  String path, {
  PartialFileIdentity? expectedIdentity,
}) {
  if (!Platform.isLinux && !Platform.isMacOS) {
    return;
  }
  final fd = _openReadOnlyNoFollow(path);
  if (fd < 0) {
    throw FileSystemException('Cannot open file for sync', path);
  }
  try {
    _verifyReopenedIdentity(fd, path, expectedIdentity);
    _syncOpenFd(fd, path);
  } finally {
    _posixCloseChecked(fd, path);
  }
}

/// Before rename: `fchmod(mode)` on the fd, then fsync / F_FULLFSYNC.
void posixFchmodAndSyncBeforeRename(
  String path, {
  int? mode,
  PartialFileIdentity? expectedIdentity,
}) {
  if (!Platform.isLinux && !Platform.isMacOS) {
    return;
  }
  final commitMode = mode ?? posixCommittedRegularFileMode();
  final fd = _openReadOnlyNoFollow(path);
  if (fd < 0) {
    throw FileSystemException('Cannot open partial for fchmod before rename', path);
  }
  try {
    _verifyReopenedIdentity(fd, path, expectedIdentity);
    if (posixFchmod(fd, commitMode) != 0) {
      throw FileSystemException('fchmod failed before rename', path);
    }
    _syncOpenFd(fd, path);
  } finally {
    _posixCloseChecked(fd, path);
  }
}
