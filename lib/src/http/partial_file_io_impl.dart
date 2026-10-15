import 'dart:io';

import 'partial_file_io.dart';
import 'partial_file_io_posix.dart';
import 'partial_file_io_windows.dart';

PartialFileIo createPartialFileIo() {
  if (Platform.isWindows) {
    return WindowsPartialFileIo();
  }
  return PosixPartialFileIo();
}
