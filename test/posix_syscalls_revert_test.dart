import 'dart:io';

import 'package:airo_background_downloads/src/http/partial_file_io_posix.dart';
import 'package:airo_background_downloads/src/http/posix_syscalls.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('K2 injected fsync -1 fails closed', () async {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    final syscalls = _RecordingPosixSyscalls(
      openResult: 42,
      fsyncResult: -1,
      closeResult: 0,
    );
    final io = PosixPartialFileIo(syscalls: syscalls);
    await expectLater(
      io.syncDirectory('/tmp'),
      throwsA(isA<FileSystemException>()),
    );
    expect(syscalls.openCalled, isTrue);
    expect(syscalls.fsyncCalled, isTrue);
    expect(syscalls.closeCalled, isTrue);
  });

  test('K2 injected open -1 fails closed without calling fsync', () async {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    final syscalls = _RecordingPosixSyscalls(
      openResult: -1,
      fsyncResult: 0,
      closeResult: 0,
    );
    final io = PosixPartialFileIo(syscalls: syscalls);
    await expectLater(
      io.syncDirectory('/tmp'),
      throwsA(isA<FileSystemException>()),
    );
    expect(syscalls.openCalled, isTrue);
    expect(syscalls.fsyncCalled, isFalse);
    expect(syscalls.closeCalled, isFalse);
  });
}

class _RecordingPosixSyscalls implements PosixSyscalls {
  _RecordingPosixSyscalls({
    required this.openResult,
    required this.fsyncResult,
    required this.closeResult,
  });

  final int openResult;
  final int fsyncResult;
  final int closeResult;

  bool openCalled = false;
  bool fsyncCalled = false;
  bool closeCalled = false;

  @override
  int openDirectory(String path, int flags) {
    openCalled = true;
    return openResult;
  }

  @override
  int fsync(int fd) {
    fsyncCalled = true;
    return fsyncResult;
  }

  @override
  int close(int fd) {
    closeCalled = true;
    return closeResult;
  }
}
