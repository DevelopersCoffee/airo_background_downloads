import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'partial_file_identity.dart';

/// Documented fallback when neither [expectedBytes] nor [maxDownloadBytes] is set.
const int kDocumentedFallbackMaxDownloadBytes = 8 * 1024 * 1024 * 1024; // 8 GiB

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

PartialFileIdentity? _darwinLstat(String path) {
  final lib = DynamicLibrary.open('libSystem.dylib');
  final lstatFn = lib.lookupFunction<
      Int32 Function(Pointer<Utf8>, Pointer<Void>),
      int Function(Pointer<Utf8>, Pointer<Void>)>('lstat');
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
  final fstatFn = lib.lookupFunction<
      Int32 Function(Int32, Pointer<Void>),
      int Function(int, Pointer<Void>)>('fstat');
  final buf = calloc<Uint8>(_darwinStatBufSize);
  try {
    if (fstatFn(fd, buf.cast()) != 0) return null;
    return _parseDarwinStat(buf);
  } finally {
    calloc.free(buf);
  }
}

const _darwinStatBufSize = 144;

PartialFileIdentity? _parseDarwinStat(Pointer<Uint8> buf) {
  final view = buf.asTypedList(_darwinStatBufSize).buffer.asByteData();
  // Darwin `struct stat` (64-bit inode): dev@0 u32, nlink@6 u16, ino@8 u64, uid@16 u32.
  final dev = view.getUint32(0, Endian.host);
  final nlink = view.getUint16(6, Endian.host);
  final ino = view.getUint64(8, Endian.host);
  final uid = view.getUint32(16, Endian.host);
  return PartialFileIdentity(
    deviceId: dev,
    inode: ino,
    linkCount: nlink,
    ownerUid: uid,
  );
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
      return PartialFileIdentity(
        deviceId: view.getUint32(28, Endian.host),
        inode: view.getUint32(44, Endian.host),
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
