import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

import 'posix_variadic.dart';

/// Reads a regular file via `open(O_RDONLY|O_NOFOLLOW)` + `read(2)`.
Future<List<int>> readRegularFileBytesPosix(String path) async {
  if (!Platform.isLinux && !Platform.isMacOS) {
    return File(path).readAsBytes();
  }
  final lib = posixLib();
  final readFn = lib.lookupFunction<ReadNative, ReadDart>('read');
  final closeFn = lib.lookupFunction<CloseNative, CloseDart>('close');

  const linuxORdonly = 0;
  const linuxONoFollow = 0x8000;
  const darwinORdonly = 0;
  const darwinONoFollow = 0x0100;
  final flags = Platform.isLinux
      ? linuxORdonly | linuxONoFollow
      : darwinORdonly | darwinONoFollow;
  final fd = posixOpen(path, flags);
  if (fd < 0) {
    throw FileSystemException('Cannot open file for read', path);
  }
  final chunks = <int>[];
  final buffer = calloc<Uint8>(65536);
  try {
    while (true) {
      final n = readFn(fd, buffer.cast(), 65536);
      if (n < 0) {
        throw FileSystemException('read failed', path);
      }
      if (n == 0) break;
      chunks.addAll(buffer.asTypedList(n));
    }
  } finally {
    calloc.free(buffer);
    closeFn(fd);
  }
  return chunks;
}

typedef ReadNative = IntPtr Function(Int32, Pointer<Void>, IntPtr);
typedef ReadDart = int Function(int, Pointer<Void>, int);
typedef CloseNative = Int32 Function(Int32);
typedef CloseDart = int Function(int);
