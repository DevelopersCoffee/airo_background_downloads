import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

import 'partial_file_identity.dart';
import 'partial_file_io.dart';
import 'partial_file_stat.dart';

class WindowsPartialFileWriter implements PartialFileWriter {
  WindowsPartialFileWriter._(
    this._handle,
    this.identity,
    this._writeFile,
    this._closeHandle,
  );

  final int _handle;
  @override
  final PartialFileIdentity identity;
  final WriteFileDart _writeFile;
  final CloseHandleDart _closeHandle;

  @override
  Future<List<int>> readAllBytesFromOpenFd() async {
    throw UnsupportedError('readAllBytesFromOpenFd');
  }

  @override
  void writeBytes(List<int> bytes) {
    if (bytes.isEmpty) return;
    final buffer = calloc<Uint8>(bytes.length);
    final written = calloc<Uint32>();
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      final ok = _writeFile(
        _handle,
        buffer.cast(),
        bytes.length,
        written,
        nullptr,
      );
      if (ok == 0) {
        throw FileSystemException('WriteFile failed');
      }
    } finally {
      calloc.free(buffer);
      calloc.free(written);
    }
  }

  @override
  Future<void> close() async {
    final closed = _closeHandle(_handle);
    if (closed == 0) {
      throw FileSystemException('CloseHandle failed for partial writer');
    }
  }

  static WindowsPartialFileWriter open(
    String path, {
    required bool append,
    PartialFileIdentity? expectedIdentity,
  }) {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final createFileW = kernel32.lookupFunction<CreateFileWNative, CreateFileWDart>(
      'CreateFileW',
    );
    final writeFile = kernel32.lookupFunction<WriteFileNative, WriteFileDart>(
      'WriteFile',
    );
    final closeHandle = kernel32.lookupFunction<CloseHandleNative, CloseHandleDart>(
      'CloseHandle',
    );
    const genericWrite = 0x40000000;
    const shareRead = 0x00000001;
    const shareWrite = 0x00000002;
    const createNew = 1;
    const openExisting = 3;
    const fileAttributeNormal = 0x00000080;
    const invalidHandle = -1;

    final pathPtr = path.toNativeUtf16();
    try {
      final handle = createFileW(
        pathPtr,
        genericWrite,
        shareRead | shareWrite,
        nullptr,
        append ? openExisting : createNew,
        fileAttributeNormal,
        nullptr,
      );
      if (handle == invalidHandle) {
        throw FileSystemException('Cannot open partial for write', path);
      }
      final stat = platformLstat(path);
      if (stat == null || stat.linkCount != 1) {
        closeHandle(handle);
        throw FileSystemException('Refusing to write: unsafe partial nlink', path);
      }
      if (expectedIdentity != null && !expectedIdentity.matches(stat)) {
        closeHandle(handle);
        throw FileSystemException('Refusing to write: partial identity changed', path);
      }
      return WindowsPartialFileWriter._(
        handle,
        stat,
        writeFile,
        closeHandle,
      );
    } finally {
      malloc.free(pathPtr);
    }
  }
}

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
typedef WriteFileNative =
    Int32 Function(
      IntPtr,
      Pointer<Void>,
      Uint32,
      Pointer<Uint32>,
      Pointer<Void>,
    );
typedef WriteFileDart =
    int Function(
      int,
      Pointer<Void>,
      int,
      Pointer<Uint32>,
      Pointer<Void>,
    );
typedef CloseHandleNative = Int32 Function(IntPtr);
typedef CloseHandleDart = int Function(int);
