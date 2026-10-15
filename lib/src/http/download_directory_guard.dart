import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'partial_file_stat.dart';

bool _isPublicTempRoot(String directoryPath) {
  if (directoryPath == '/tmp') return true;
  if (directoryPath == Directory.systemTemp.path) return true;
  return false;
}

/// Ensures [directoryPath] exists as a private directory (0700, owned by us, not a symlink).
void ensurePrivateDownloadDirectory(String directoryPath) {
  if (directoryPath.isEmpty) return;
  if (_isPublicTempRoot(directoryPath)) {
    return;
  }
  if (Platform.isWindows) {
    _ensureWindowsPrivateDownloadDirectory(directoryPath);
    return;
  }
  if (!Platform.isLinux && !Platform.isMacOS) {
    Directory(directoryPath).createSync(recursive: true);
    return;
  }

  final type = FileSystemEntity.typeSync(directoryPath, followLinks: false);
  if (type == FileSystemEntityType.link) {
    throw FileSystemException(
      'Download directory cannot be a symlink',
      directoryPath,
    );
  }
  if (type == FileSystemEntityType.notFound) {
    final parent = Directory(directoryPath).parent;
    if (parent.path.isNotEmpty && parent.path != directoryPath) {
      ensurePrivateDownloadDirectory(parent.path);
    }
    final mkdirResult = _posixMkdir(directoryPath, 0x1C0);
    if (mkdirResult != 0 && !Directory(directoryPath).existsSync()) {
      throw FileSystemException('Cannot create download directory', directoryPath);
    }
  }
  if (_posixChmod(directoryPath, 0x1C0) != 0) {
    throw FileSystemException('Cannot chmod download directory to 0700', directoryPath);
  }
  _verifyPrivatePosixDirectory(directoryPath);
}

void _verifyPrivatePosixDirectory(String directoryPath) {
  final type = FileSystemEntity.typeSync(directoryPath, followLinks: false);
  if (type == FileSystemEntityType.link) {
    throw FileSystemException(
      'Download directory cannot be a symlink',
      directoryPath,
    );
  }
  if (type == FileSystemEntityType.notFound) {
    throw FileSystemException('Download directory missing', directoryPath);
  }
  final stat = platformLstat(directoryPath);
  if (stat == null) {
    throw FileSystemException(
      'Cannot stat download directory',
      directoryPath,
    );
  }
  final uid = platformCurrentUserId();
  if (stat.ownerUid != uid) {
    throw FileSystemException(
      'Download directory not owned by current user',
      directoryPath,
    );
  }
  if (stat.linkCount < 1) {
    throw FileSystemException(
      'Download directory has invalid link count',
      directoryPath,
    );
  }
  var mode = File(directoryPath).statSync().mode & 0x1FF;
  if ((mode & 63) != 0) {
    _posixChmod(directoryPath, 0x1C0);
    mode = File(directoryPath).statSync().mode & 0x1FF;
  }
  if ((mode & 63) != 0) {
    throw FileSystemException(
      'Download directory must be mode 0700 (no group/other access)',
      directoryPath,
    );
  }
}

void _ensureWindowsPrivateDownloadDirectory(String directoryPath) {
  Directory(directoryPath).createSync(recursive: true);
  final type = FileSystemEntity.typeSync(directoryPath, followLinks: false);
  if (type == FileSystemEntityType.link) {
    throw FileSystemException(
      'Download directory cannot be a symlink',
      directoryPath,
    );
  }
}

int _posixMkdir(String path, int mode) {
  final lib = DynamicLibrary.open(
    Platform.isLinux ? 'libc.so.6' : 'libSystem.dylib',
  );
  final mkdirFn = lib.lookupFunction<MkdirNative, MkdirDart>('mkdir');
  final pathPtr = path.toNativeUtf8();
  try {
    return mkdirFn(pathPtr, mode);
  } finally {
    malloc.free(pathPtr);
  }
}

int _posixChmod(String path, int mode) {
  final lib = DynamicLibrary.open(
    Platform.isLinux ? 'libc.so.6' : 'libSystem.dylib',
  );
  final chmodFn = lib.lookupFunction<ChmodNative, ChmodDart>('chmod');
  final pathPtr = path.toNativeUtf8();
  try {
    return chmodFn(pathPtr, mode);
  } finally {
    malloc.free(pathPtr);
  }
}

typedef MkdirNative = Int32 Function(Pointer<Utf8>, Int32);
typedef MkdirDart = int Function(Pointer<Utf8>, int);
typedef ChmodNative = Int32 Function(Pointer<Utf8>, Int32);
typedef ChmodDart = int Function(Pointer<Utf8>, int);
