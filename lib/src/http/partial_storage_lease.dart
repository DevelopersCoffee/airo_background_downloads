import 'package:flutter/foundation.dart';

import 'partial_storage_cleanup.dart';
import 'partial_storage_paths.dart';

final Map<String, int> _activePartialStorageLeases = {};

String _leaseKeyForDestination(String destinationPath) =>
    PartialStoragePaths.forDestination(destinationPath).storageDirectory;

/// Registers this download job as using the shared partial storage directory.
void acquirePartialStorageLease(String destinationPath) {
  final key = _leaseKeyForDestination(destinationPath);
  _activePartialStorageLeases[key] = (_activePartialStorageLeases[key] ?? 0) + 1;
}

/// Drops this job's lease and may remove empty storage when no other job holds it.
void releasePartialStorageLeaseAndMaybeCleanup(String destinationPath) {
  final key = _leaseKeyForDestination(destinationPath);
  final count = _activePartialStorageLeases[key] ?? 0;
  if (count <= 0) {
    return;
  }
  if (count == 1) {
    tryRemoveEmptyPartialStorageDirectory(destinationPath);
  }
  final next = count - 1;
  if (next == 0) {
    _activePartialStorageLeases.remove(key);
  } else {
    _activePartialStorageLeases[key] = next;
  }
}

@visibleForTesting
int partialStorageLeaseCountForDestination(String destinationPath) {
  return _activePartialStorageLeases[_leaseKeyForDestination(destinationPath)] ??
      0;
}

@visibleForTesting
void resetPartialStorageLeasesForTest() {
  _activePartialStorageLeases.clear();
}
