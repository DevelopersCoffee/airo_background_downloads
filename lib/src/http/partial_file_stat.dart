import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

import 'package:flutter/foundation.dart';

import 'partial_file_identity.dart';

/// lstat/fstat without following symlinks. Returns null on failure.
PartialFileIdentity? platformLstat(String path) {
  if (Platform.isLinux) {
    return _linuxLstat(path);
  }
  if (Platform.isMacOS) {
    return _darwinLstat(path);
  }
  if (Platform.isWindows) {
    return _windowsPathStat(path);
  }
  return null;
}

PartialFileIdentity? platformFstat(int fd) {
  if (Platform.isLinux) {
    return _linuxFstat(fd);
  }
  if (Platform.isMacOS) {
    return _darwinFstat(fd);
  }
  return null;
}

int platformCurrentUserId() {
  if (Platform.isLinux || Platform.isMacOS) {
    final lib = DynamicLibrary.open(
      Platform.isLinux ? 'libc.so.6' : 'libSystem.dylib',
    );
    final getuid = lib.lookupFunction<GetUidNative, GetUidDart>('getuid');
    return getuid();
  }
  return 0;
}

bool get _isLinuxArm64 =>
    Platform.isLinux && Abi.current() == Abi.linuxArm64;

typedef _StatPathNative = Int32 Function(Pointer<Utf8>, Pointer<Void>);
typedef _StatPathDart = int Function(Pointer<Utf8>, Pointer<Void>);
typedef _StatFdNative = Int32 Function(Int32, Pointer<Void>);
typedef _StatFdDart = int Function(int, Pointer<Void>);

_StatPathDart? _lookupDarwinLstat(DynamicLibrary lib) {
  if (Platform.isMacOS) {
    try {
      return lib.lookupFunction<_StatPathNative, _StatPathDart>(
        'lstat\$INODE64',
      );
    } on Object {
      // Fall back below.
    }
  }
  try {
    return lib.lookupFunction<_StatPathNative, _StatPathDart>('lstat');
  } on Object {
    return null;
  }
}

_StatFdDart? _lookupDarwinFstat(DynamicLibrary lib) {
  if (Platform.isMacOS) {
    try {
      return lib.lookupFunction<_StatFdNative, _StatFdDart>('fstat\$INODE64');
    } on Object {
      // Fall back below.
    }
  }
  try {
    return lib.lookupFunction<_StatFdNative, _StatFdDart>('fstat');
  } on Object {
    return null;
  }
}

PartialFileIdentity? _linuxLstat(String path) {
  final lib = DynamicLibrary.open('libc.so.6');
  final lstatFn = _lookupLinuxLstat(lib);
  if (lstatFn == null) return null;
  final pathPtr = path.toNativeUtf8();
  final buf = calloc<Uint8>(_linuxStatBufSize);
  try {
    if (lstatFn(pathPtr, buf.cast()) != 0) return null;
    return _parseLinuxStat(buf);
  } finally {
    calloc.free(buf);
    malloc.free(pathPtr);
  }
}

PartialFileIdentity? _linuxFstat(int fd) {
  final lib = DynamicLibrary.open('libc.so.6');
  final fstatFn = lib.lookupFunction<
      Int32 Function(Int32, Pointer<Void>),
      int Function(int, Pointer<Void>)>('fstat');
  final buf = calloc<Uint8>(_linuxStatBufSize);
  try {
    if (fstatFn(fd, buf.cast()) != 0) return null;
    return _parseLinuxStat(buf);
  } finally {
    calloc.free(buf);
  }
}

const _linuxStatBufSize = 144;

typedef _LstatNative = Int32 Function(Pointer<Utf8>, Pointer<Void>);
typedef _LstatDart = int Function(Pointer<Utf8>, Pointer<Void>);

_LstatDart? _lookupLinuxLstat(DynamicLibrary lib) {
  try {
    return lib.lookupFunction<_LstatNative, _LstatDart>('lstat');
  } on Object {
    try {
      return lib.lookupFunction<_LstatNative, _LstatDart>('lstat64');
    } on Object {
      return null;
    }
  }
}

PartialFileIdentity? _parseLinuxStat(Pointer<Uint8> buf) {
  final view = buf.asTypedList(_linuxStatBufSize).buffer.asByteData();
  final dev = view.getUint64(0, Endian.host);
  final ino = view.getUint64(8, Endian.host);
  final nlink = _isLinuxArm64
      ? view.getUint32(20, Endian.host)
      : view.getUint64(16, Endian.host);
  final uid = _isLinuxArm64
      ? view.getUint32(24, Endian.host)
      : view.getUint32(28, Endian.host);
  return PartialFileIdentity(
    deviceId: dev,
    inode: ino,
    linkCount: nlink,
    ownerUid: uid,
  );
}

int? _linuxStatSize(Pointer<Uint8> buf) {
  final view = buf.asTypedList(_linuxStatBufSize).buffer.asByteData();
  return _isLinuxArm64
      ? view.getInt64(32, Endian.host)
      : view.getInt64(48, Endian.host);
}

PartialFileIdentity? _darwinLstat(String path) {
  final lib = DynamicLibrary.open('libSystem.dylib');
  final lstatFn = _lookupDarwinLstat(lib);
  if (lstatFn == null) return null;
  final pathPtr = path.toNativeUtf8();
  final buf = calloc<Uint8>(_darwinStatBufSize);
  try {
    if (lstatFn(pathPtr, buf.cast()) != 0) return null;
    return _parseDarwinStat(buf);
  } finally {
    calloc.free(buf);
    malloc.free(pathPtr);
  }
}

PartialFileIdentity? _darwinFstat(int fd) {
  final lib = DynamicLibrary.open('libSystem.dylib');
  final fstatFn = _lookupDarwinFstat(lib);
  if (fstatFn == null) return null;
  final buf = calloc<Uint8>(_darwinStatBufSize);
  try {
    if (fstatFn(fd, buf.cast()) != 0) return null;
    return _parseDarwinStat(buf);
  } finally {
    calloc.free(buf);
  }
}

/// st_mode for a path (POSIX). Returns null when stat fails.
int? platformPathMode(String path) {
  if (Platform.isLinux) {
    return _linuxPathMode(path);
  }
  if (Platform.isMacOS) {
    return _darwinPathMode(path);
  }
  return null;
}

int? _linuxPathMode(String path) {
  final lib = DynamicLibrary.open('libc.so.6');
  final lstatFn = _lookupLinuxLstat(lib);
  if (lstatFn == null) return null;
  final pathPtr = path.toNativeUtf8();
  final buf = calloc<Uint8>(_linuxStatBufSize);
  try {
    if (lstatFn(pathPtr, buf.cast()) != 0) return null;
    final view = buf.asTypedList(_linuxStatBufSize).buffer.asByteData();
    return _isLinuxArm64
        ? view.getUint32(16, Endian.host)
        : view.getUint32(24, Endian.host);
  } finally {
    calloc.free(buf);
    malloc.free(pathPtr);
  }
}

int? _darwinPathMode(String path) {
  final lib = DynamicLibrary.open('libSystem.dylib');
  final lstatFn = _lookupDarwinLstat(lib);
  if (lstatFn == null) return null;
  final pathPtr = path.toNativeUtf8();
  final buf = calloc<Uint8>(_darwinStatBufSize);
  try {
    if (lstatFn(pathPtr, buf.cast()) != 0) return null;
    return _darwinModeFromBuf(buf);
  } finally {
    calloc.free(buf);
    malloc.free(pathPtr);
  }
}

int? _darwinModeFromBuf(Pointer<Uint8> buf) {
  final view = buf.asTypedList(_darwinStatBufSize).buffer.asByteData();
  return view.getUint16(4, Endian.host);
}

const _darwinStatBufSize = 144;

/// Darwin `stat` / `stat64` layout (64-bit inode): dev @0, mode u16 @4, nlink u16 @6,
/// ino u64 @8, uid u32 @16.
@visibleForTesting
PartialFileIdentity? parseDarwinStatBytes(List<int> bytes) {
  if (bytes.length < _darwinStatBufSize) return null;
  final buf = calloc<Uint8>(bytes.length);
  try {
    buf.asTypedList(bytes.length).setAll(0, bytes);
    return _parseDarwinStat(buf);
  } finally {
    calloc.free(buf);
  }
}

PartialFileIdentity? _parseDarwinStat(Pointer<Uint8> buf) {
  final view = buf.asTypedList(_darwinStatBufSize).buffer.asByteData();
  final dev = view.getUint32(0, Endian.host);
  final nlink = view.getUint16(6, Endian.host);
  if (nlink < 1) {
    return null;
  }
  final ino = view.getUint64(8, Endian.host);
  final uid = view.getUint32(16, Endian.host);
  return PartialFileIdentity(
    deviceId: dev,
    inode: ino,
    linkCount: nlink,
    ownerUid: uid,
  );
}

int? _darwinStatSize(Pointer<Uint8> buf) {
  final view = buf.asTypedList(_darwinStatBufSize).buffer.asByteData();
  return view.getInt64(96, Endian.host);
}

/// File size from fstat on an open fd, or null when stat fails.
int? platformFstatFileSize(int fd) {
  if (Platform.isLinux) {
    final lib = DynamicLibrary.open('libc.so.6');
    final fstatFn = lib.lookupFunction<
        Int32 Function(Int32, Pointer<Void>),
        int Function(int, Pointer<Void>)>('fstat');
    final buf = calloc<Uint8>(_linuxStatBufSize);
    try {
      if (fstatFn(fd, buf.cast()) != 0) return null;
      return _linuxStatSize(buf);
    } finally {
      calloc.free(buf);
    }
  }
  if (Platform.isMacOS) {
    final lib = DynamicLibrary.open('libSystem.dylib');
    final fstatFn = _lookupDarwinFstat(lib);
    if (fstatFn == null) return null;
    final buf = calloc<Uint8>(_darwinStatBufSize);
    try {
      if (fstatFn(fd, buf.cast()) != 0) return null;
      return _darwinStatSize(buf);
    } finally {
      calloc.free(buf);
    }
  }
  return null;
}

/// File size from fstat after `open(O_RDONLY)` (no follow on Linux).
int? platformPathFileSizeFstat(String path) {
  if (!Platform.isLinux && !Platform.isMacOS) return null;
  final lib = DynamicLibrary.open(
    Platform.isLinux ? 'libc.so.6' : 'libSystem.dylib',
  );
  final openFn = lib.lookupFunction<
      Int32 Function(Pointer<Utf8>, Int32),
      int Function(Pointer<Utf8>, int)>('open');
  final closeFn = lib.lookupFunction<
      Int32 Function(Int32),
      int Function(int)>('close');
  final flags = Platform.isLinux ? 0x8000 /* O_RDONLY|O_NOFOLLOW */ : 0;
  final pathPtr = path.toNativeUtf8();
  final fd = openFn(pathPtr, flags);
  malloc.free(pathPtr);
  if (fd < 0) return null;
  try {
    return platformFstatFileSize(fd);
  } finally {
    closeFn(fd);
  }
}

/// File size from lstat (no follow), or null when stat fails.
int? platformPathFileSize(String path) {
  if (Platform.isLinux) {
    final lib = DynamicLibrary.open('libc.so.6');
    final lstatFn = _lookupLinuxLstat(lib);
    if (lstatFn == null) return null;
    final pathPtr = path.toNativeUtf8();
    final buf = calloc<Uint8>(_linuxStatBufSize);
    try {
      if (lstatFn(pathPtr, buf.cast()) != 0) return null;
      return _linuxStatSize(buf);
    } finally {
      calloc.free(buf);
      malloc.free(pathPtr);
    }
  }
  if (Platform.isMacOS) {
    final lib = DynamicLibrary.open('libSystem.dylib');
    final lstatFn = _lookupDarwinLstat(lib);
    if (lstatFn == null) return null;
    final pathPtr = path.toNativeUtf8();
    final buf = calloc<Uint8>(_darwinStatBufSize);
    try {
      if (lstatFn(pathPtr, buf.cast()) != 0) return null;
      return _darwinStatSize(buf);
    } finally {
      calloc.free(buf);
      malloc.free(pathPtr);
    }
  }
  if (Platform.isWindows) {
    return File(path).lengthSync();
  }
  return null;
}

PartialFileIdentity? _windowsPathStat(String path) {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final createFileW = kernel32.lookupFunction<CreateFileWNative, CreateFileWDart>(
    'CreateFileW',
  );
  final getInfo = kernel32.lookupFunction<
      GetFileInformationByHandleNative,
      GetFileInformationByHandleDart>('GetFileInformationByHandle');
  final closeHandle = kernel32.lookupFunction<CloseHandleNative, CloseHandleDart>(
    'CloseHandle',
  );
  const genericRead = 0x80000000;
  const shareRead = 0x00000001;
  const shareWrite = 0x00000002;
  const openExisting = 3;
  const fileAttributeNormal = 0x00000080;
  const invalidHandle = -1;

  final pathPtr = path.toNativeUtf16();
  try {
    final handle = createFileW(
      pathPtr,
      genericRead,
      shareRead | shareWrite,
      nullptr,
      openExisting,
      fileAttributeNormal,
      nullptr,
    );
    if (handle == invalidHandle) return null;
    final info = calloc<Uint8>(52);
    try {
      final ok = getInfo(handle, info.cast());
      if (ok == 0) return null;
      final view = info.asTypedList(52).buffer.asByteData();
      final nlink = view.getUint32(40, Endian.host);
      // Windows has no POSIX uid on files; owner checks are not enforced (see PartialFileIo docs).
      final indexLow = view.getUint32(48, Endian.host);
      final indexHigh = view.getUint32(44, Endian.host);
      final inode = (indexHigh << 32) | indexLow;
      return PartialFileIdentity(
        deviceId: view.getUint32(28, Endian.host),
        inode: inode,
        linkCount: nlink,
        ownerUid: 0,
      );
    } finally {
      calloc.free(info);
      closeHandle(handle);
    }
  } finally {
    malloc.free(pathPtr);
  }
}

/// Legacy helper used by path inspection (lstat, no follow).
({int nlink, int uid})? platformLinkCountAndOwner(String path) {
  final id = platformLstat(path);
  if (id == null) return null;
  return (nlink: id.linkCount, uid: id.ownerUid);
}

typedef GetUidNative = Uint32 Function();
typedef GetUidDart = int Function();
typedef CreateFileWNative =
    IntPtr Function(
      Pointer<Utf16>,
      Uint32,
      Uint32,
      Pointer<Void>,
      Uint32,
      Uint32,
      Pointer<Void>,
    );
typedef CreateFileWDart =
    int Function(
      Pointer<Utf16>,
      int,
      int,
      Pointer<Void>,
      int,
      int,
      Pointer<Void>,
    );
typedef GetFileInformationByHandleNative =
    Int32 Function(IntPtr hFile, Pointer<Void> lpFileInformation);
typedef GetFileInformationByHandleDart =
    int Function(int hFile, Pointer<Void> lpFileInformation);
typedef CloseHandleNative = Int32 Function(IntPtr);
typedef CloseHandleDart = int Function(int);
