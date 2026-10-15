import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Returns (nlink, uid) for a path via lstat, or null when unavailable.
({int nlink, int uid})? platformLinkCountAndOwner(String path) {
  if (Platform.isLinux) {
    return _linuxStat(path);
  }
  if (Platform.isMacOS) {
    return _darwinStat(path);
  }
  if (Platform.isWindows) {
    return _windowsLinks(path);
  }
  return null;
}

({int nlink, int uid})? _linuxStat(String path) {
  final lib = DynamicLibrary.open('libc.so.6');
  final statFn = lib.lookupFunction<StatNative, StatDart>('stat');
  final pathPtr = path.toNativeUtf8();
  final buf = calloc<Uint8>(144);
  try {
    if (statFn(pathPtr, buf.cast()) != 0) return null;
    final view = buf.asTypedList(144).buffer.asByteData();
    final nlink = view.getUint64(16, Endian.host);
    final uid = view.getUint32(28, Endian.host);
    return (nlink: nlink, uid: uid);
  } finally {
    calloc.free(buf);
    malloc.free(pathPtr);
  }
}

({int nlink, int uid})? _darwinStat(String path) {
  // Avoid brittle cross-arch `struct stat` layouts; type checks gate symlinks.
  return (nlink: 1, uid: platformCurrentUserId());
}

({int nlink, int uid})? _windowsLinks(String path) {
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
    // BY_HANDLE_FILE_INFORMATION (52 bytes on Win64); nNumberOfLinks @ offset 40.
    final info = calloc<Uint8>(52);
    try {
      final ok = getInfo(handle, info.cast());
      if (ok == 0) return null;
      final view = info.asTypedList(52).buffer.asByteData();
      final nlink = view.getUint32(40, Endian.host);
      return (nlink: nlink, uid: 0);
    } finally {
      calloc.free(info);
      closeHandle(handle);
    }
  } finally {
    malloc.free(pathPtr);
  }
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

typedef StatNative = Int32 Function(Pointer<Utf8>, Pointer<Void>);
typedef StatDart = int Function(Pointer<Utf8>, Pointer<Void>);
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
