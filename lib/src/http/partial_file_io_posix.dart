import 'dart:io';

import 'package:flutter/foundation.dart';

import 'partial_file_identity.dart';
import 'partial_file_io.dart';
import 'partial_file_stat.dart';
import 'partial_file_writer_posix.dart';
import 'posix_syscalls.dart';

/// POSIX desktop partial file safety (Linux + macOS).
base class PosixPartialFileIo implements PartialFileIo {
  PosixPartialFileIo({PosixSyscalls? syscalls})
    : _syscalls = syscalls ?? LibcPosixSyscalls();

  final PosixSyscalls _syscalls;
  final _uid = platformCurrentUserId();

  @visibleForTesting
  PosixSyscalls get syscalls => _syscalls;

  @override
  PartialPathInspection inspectPath(String path) {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return const PartialPathInspection(
        isAbsent: true,
        isSymlink: false,
        isRegularFile: false,
        linkCount: null,
        ownedByUs: false,
      );
    }
    if (type == FileSystemEntityType.link) {
      return const PartialPathInspection(
        isAbsent: false,
        isSymlink: true,
        isRegularFile: false,
        linkCount: null,
        ownedByUs: false,
      );
    }
    if (type != FileSystemEntityType.file) {
      return const PartialPathInspection(
        isAbsent: false,
        isSymlink: false,
        isRegularFile: false,
        linkCount: null,
        ownedByUs: false,
      );
    }
    final stat = platformLstat(path);
    if (stat == null) {
      return const PartialPathInspection(
        isAbsent: false,
        isSymlink: false,
        isRegularFile: true,
        linkCount: null,
        ownedByUs: false,
      );
    }
    final owned = stat.ownerUid == _uid;
    return PartialPathInspection(
      isAbsent: false,
      isSymlink: false,
      isRegularFile: true,
      linkCount: stat.linkCount,
      ownedByUs: owned,
      identity: stat,
    );
  }

  @override
  PartialPathSafety classifyPartialPath(String path) {
    final inspection = inspectPath(path);
    if (inspection.isAbsent) {
      return const PartialPathSafety(mayAppend: false, shouldUnlinkEntry: false);
    }
    if (!inspection.isSafeRegularFileOwnedByUs) {
      return const PartialPathSafety(mayAppend: false, shouldUnlinkEntry: true);
    }
    return const PartialPathSafety(mayAppend: true, shouldUnlinkEntry: false);
  }

  @override
  void unlinkPartialEntry(String path) {
    try {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) return;
      if (type == FileSystemEntityType.link) {
        Link(path).deleteSync();
        return;
      }
      File(path).deleteSync();
    } on FileSystemException {
      // Best effort.
    }
  }

  @override
  void prepareDestinationForCommit(String destinationPath) {
    final type = FileSystemEntity.typeSync(
      destinationPath,
      followLinks: false,
    );
    if (type == FileSystemEntityType.link) {
      Link(destinationPath).deleteSync();
    }
  }

  @override
  Future<void> syncFile(String path) async {
    if (!File(path).existsSync()) {
      throw FileSystemException('Cannot fsync missing file', path);
    }
    if (Platform.isMacOS) {
      // Durability is handled by fsync on the partial fd in PosixPartialFileWriter.close().
      return;
    }
    final raf = await File(path).open(mode: FileMode.read);
    try {
      await raf.flush();
    } finally {
      await raf.close();
    }
  }

  @override
  Future<void> syncDirectory(String directoryPath) async {
    if (!Platform.isLinux && !Platform.isMacOS) {
      throw FileSystemException(
        'Directory fsync unavailable on this platform',
        directoryPath,
      );
    }
    final flags = Platform.isLinux ? _oRdonly | _oDirectory : _oRdonly;
    final fd = _syscalls.openDirectory(directoryPath, flags);
    if (fd < 0) {
      throw FileSystemException('Cannot open directory for fsync', directoryPath);
    }
    try {
      final result = _syscalls.fsync(fd);
      if (result != 0) {
        throw FileSystemException('fsync failed for directory', directoryPath);
      }
    } finally {
      final closed = _syscalls.close(fd);
      if (closed != 0) {
        throw FileSystemException('close failed for directory fd', directoryPath);
      }
    }
  }

  @override
  Future<PartialFileWriter> openVerifiedPartialWriter(
    String path, {
    required bool append,
    PartialFileIdentity? expectedIdentity,
  }) async {
    return PosixPartialFileWriter.open(
      path,
      append: append,
      currentUid: _uid,
      expectedIdentity: expectedIdentity,
    );
  }
}

const _oRdonly = 0;
const _oDirectory = 0x00010000;
