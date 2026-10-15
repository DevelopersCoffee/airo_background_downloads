import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

/// Reads a regular file via `open(O_RDONLY|O_NOFOLLOW)` + `read(2)`.
///
/// Used on macOS where Dart `File.openRead` can fail with EACCES on partials
/// created through libc with mode 0600.
Future<List<int>> readRegularFileBytesPosix(String path) async {
  if (!Platform.isLinux && !Platform.isMacOS) {
    return File(path).readAsBytes();
  }
  final lib = DynamicLibrary.open(
    Platform.isLinux ? 'libc.so.6' : 'libSystem.dylib',
  );
  final openFn = lib.lookupFunction<OpenNative, OpenDart>('open');
  final readFn = lib.lookupFunction<ReadNative, ReadDart>('read');
  final closeFn = lib.lookupFunction<CloseNative, CloseDart>('close');

  // macOS CI rejects O_RDONLY|O_NOFOLLOW reopen of libc 0600 partials; Linux keeps NOFOLLOW.
  final flags = Platform.isLinux
      ? _linuxORdonly | _linuxONoFollow
      : _darwinORdonly;
  final pathPtr = path.toNativeUtf8();
  final fd = openFn(pathPtr, flags);
  malloc.free(pathPtr);
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

const _linuxORdonly = 0;
const _linuxONoFollow = 0x8000;
const _darwinORdonly = 0;

typedef OpenNative = Int32 Function(Pointer<Utf8>, Int32);
typedef OpenDart = int Function(Pointer<Utf8>, int);
typedef ReadNative = IntPtr Function(Int32, Pointer<Void>, IntPtr);
typedef ReadDart = int Function(int, Pointer<Void>, int);
typedef CloseNative = Int32 Function(Int32);
typedef CloseDart = int Function(int);
