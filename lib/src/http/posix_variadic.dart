import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

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
