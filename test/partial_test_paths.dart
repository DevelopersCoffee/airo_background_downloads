import 'dart:io';

import 'package:airo_background_downloads/src/http/download_directory_guard.dart';
import 'package:airo_background_downloads/src/http/partial_storage_paths.dart';

void preparePartialStorage(File destination) {
  ensurePrivatePartialStorage(destination.path);
}

String partialPathFor(File destination) =>
    PartialStoragePaths.forDestination(destination.path).partialPath;

String metaPathFor(File destination) =>
    PartialStoragePaths.forDestination(destination.path).metaPath;

String workPathFor(File destination) =>
    PartialStoragePaths.forDestination(destination.path).workPath;
