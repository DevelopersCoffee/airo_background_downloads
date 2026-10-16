import 'dart:io';

/// Directory name for partial files and `.meta` sidecars next to a download destination.
const airoPartialsDirectoryName = '.airo_partials';

/// Resolves partial/meta/work paths under a private `.airo_partials` leaf.
class PartialStoragePaths {
  PartialStoragePaths._(this.destinationPath, this._destinationParentPath);

  factory PartialStoragePaths.forDestination(String destinationPath) {
    final parent = File(destinationPath).parent.path;
    return PartialStoragePaths._(
      destinationPath,
      parent.isEmpty ? '.' : parent,
    );
  }

  final String destinationPath;
  final String _destinationParentPath;

  String get storageDirectory =>
      '$_destinationParentPath${Platform.pathSeparator}$airoPartialsDirectoryName';

  String get partialPath {
    final name = File(destinationPath).uri.pathSegments.last;
    return '$storageDirectory${Platform.pathSeparator}$name.partial';
  }

  String get metaPath => '$partialPath.meta';

  String get workPath => '$partialPath.work';
}
