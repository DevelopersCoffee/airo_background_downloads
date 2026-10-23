import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

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

int? _cachedProcessUmask;

@visibleForTesting
bool posixUmaskLastReadUsedExclusiveProbe = false;

@visibleForTesting
void resetPosixUmaskCacheForTest() {
  _cachedProcessUmask = null;
  posixUmaskLastReadUsedExclusiveProbe = false;
}

@visibleForTesting
int Function(int fd)? darwinFullFsyncOverrideForTest;

@visibleForTesting
int Function(int fd)? posixCloseOverrideForTest;

int posixDarwinFullFsync(int fd) {
  final override = darwinFullFsyncOverrideForTest;
  if (override != null) {
    return override(fd);
  }
  return posixFcntl(fd, darwinFullFsyncCmd);
}

int posixFchmod(int fd, int mode) {
  final fchmodFn = posixLib().lookupFunction<
      Int32 Function(Int32, Int32),
      int Function(int, int)>('fchmod');
  return fchmodFn(fd, mode);
}

/// Process umask, cached after first read (Linux: `/proc/self/status`).
int posixCurrentUmask() {
  final cached = _cachedProcessUmask;
  if (cached != null) {
    return cached;
  }
  if (Platform.isLinux) {
    try {
      for (final line in File('/proc/self/status').readAsLinesSync()) {
        if (!line.startsWith('Umask:')) continue;
        final parts = line.split(RegExp(r'\s+'));
        if (parts.length >= 2) {
          _cachedProcessUmask = int.parse(parts[1], radix: 8) & 511;
          return _cachedProcessUmask!;
        }
      }
    } on Object {
      // Fall through to race-free probe file.
    }
  }
  _cachedProcessUmask = _probeProcessUmaskViaExclusiveCreate();
  posixUmaskLastReadUsedExclusiveProbe = true;
  return _cachedProcessUmask!;
}

/// Reads umask without mutating the process umask (exclusive create at 0666).
int _probeProcessUmaskViaExclusiveCreate() {
  const requestedMode = 438; // 0666
  final dir = Directory.systemTemp.createTempSync('airo-umask-probe-');
  try {
    final path = '${dir.path}/probe';
    const linuxOCreat = 64;
    const linuxOExcl = 128;
    const linuxOWronly = 1;
    const darwinOCreat = 512;
    const darwinOExcl = 2048;
    const darwinOWronly = 1;
    final flags = Platform.isLinux
        ? linuxOWronly | linuxOCreat | linuxOExcl
        : darwinOWronly | darwinOCreat | darwinOExcl;
    final fd = posixOpen(path, flags, mode: requestedMode);
    if (fd < 0) {
      throw FileSystemException('umask probe create failed', path);
    }
    try {
      final actualMode = platformPathMode(path);
      if (actualMode == null) {
        throw FileSystemException('umask probe mode read failed', path);
      }
      return (requestedMode & ~actualMode) & 511;
    } finally {
      final closeFn = posixLib().lookupFunction<
          Int32 Function(Int32),
          int Function(int)>('close');
      closeFn(fd);
      try {
        File(path).deleteSync();
      } on Object {
        // Best effort.
      }
    }
  } finally {
    try {
      dir.deleteSync(recursive: true);
    } on Object {
      // Best effort.
    }
  }
}

/// Mode for committed regular files: `0666 & ~umask`.
int posixCommittedRegularFileMode() =>
    (438 & ~posixCurrentUmask()) & 511;

void _posixCloseChecked(int fd, String path) {
  final override = posixCloseOverrideForTest;
  final result = override != null ? override(fd) : _libcClose(fd);
  if (result != 0) {
    throw FileSystemException('close failed', path);
  }
}

int _libcClose(int fd) {
  final closeFn = posixLib().lookupFunction<
      Int32 Function(Int32),
      int Function(int)>('close');
  return closeFn(fd);
}

void _verifyReopenedIdentity(
  int fd,
  String path,
  PartialFileIdentity expected,
) {
  final stat = platformFstat(fd);
  if (stat == null || !expected.matches(stat)) {
    throw FileSystemException(
      'Partial file identity changed after reopen',
      path,
    );
  }
}

void _runWithCheckedClose(int fd, String path, void Function() action) {
  Object? actionError;
  StackTrace? actionStack;
  try {
    action();
  } on Object catch (error, stack) {
    actionError = error;
    actionStack = stack;
  } finally {
    try {
      _posixCloseChecked(fd, path);
    } on Object catch (closeError, closeStack) {
      if (actionError == null) {
        Error.throwWithStackTrace(closeError, closeStack);
      }
    }
  }
  final err = actionError;
  if (err != null) {
    Error.throwWithStackTrace(err, actionStack ?? StackTrace.current);
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
  _runWithCheckedClose(fd, path, () {
    if (expectedIdentity != null) {
      _verifyReopenedIdentity(fd, path, expectedIdentity);
    }
    _syncOpenFd(fd, path);
  });
}

/// Before rename: `fchmod(mode)` on the fd, then fsync / F_FULLFSYNC.
void posixFchmodAndSyncBeforeRename(
  String path, {
  int? mode,
  required PartialFileIdentity expectedIdentity,
}) {
  if (!Platform.isLinux && !Platform.isMacOS) {
    return;
  }
  final commitMode = mode ?? posixCommittedRegularFileMode();
  final fd = _openReadOnlyNoFollow(path);
  if (fd < 0) {
    throw FileSystemException('Cannot open partial for fchmod before rename', path);
  }
  _runWithCheckedClose(fd, path, () {
    _verifyReopenedIdentity(fd, path, expectedIdentity);
    if (posixFchmod(fd, commitMode) != 0) {
      throw FileSystemException('fchmod failed before rename', path);
    }
    _syncOpenFd(fd, path);
  });
}
