import 'dart:io';

import 'package:airo_background_downloads/airo_background_downloads.dart';
import 'package:flutter_test/flutter_test.dart';

/// Backs the README section "Privacy and telemetry": the package has no
/// analytics or HTTP-client dependency, and the telemetry types only hold
/// numbers in memory.
void main() {
  test('lib/ imports only flutter, crypto, ffi and its own files', () {
    final imported = <String>{};
    final importPattern = RegExp(
      r'''^(?:import|export)\s+['"]package:([a-z0-9_]+)/''',
    );
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      for (final line in entity.readAsLinesSync()) {
        final match = importPattern.firstMatch(line.trim());
        if (match != null) imported.add(match.group(1)!);
      }
    }
    expect(
      imported.difference({
        'flutter',
        'crypto',
        'ffi',
        'airo_background_downloads',
      }),
      isEmpty,
    );
  });

  test(
    'pubspec declares no runtime dependency beyond flutter, crypto, ffi',
    () {
      final lines = File('pubspec.yaml').readAsLinesSync();
      final start = lines.indexOf('dependencies:');
      expect(start, isNonNegative);
      final names = <String>{};
      for (final line in lines.skip(start + 1)) {
        if (line.isNotEmpty && !line.startsWith(' ')) break;
        final match = RegExp(r'^  ([a-z0-9_]+):').firstMatch(line);
        if (match != null) names.add(match.group(1)!);
      }
      expect(names, equals({'crypto', 'ffi', 'flutter'}));
    },
  );

  test('telemetry and notification sources do no I/O of their own', () {
    for (final path in [
      'lib/src/download_telemetry.dart',
      'lib/src/advanced_ux.dart',
    ]) {
      final imports = File(path)
          .readAsLinesSync()
          .where((l) => l.trimLeft().startsWith('import '))
          .toList();
      expect(imports, equals(["import 'download_models.dart';"]), reason: path);
    }
  });

  test('toMap() returns plain values only; nothing is sent', () {
    final logger = AiroDownloadTelemetryLogger();
    final map = logger.getSnapshot().toMap();
    expect(
      map.keys,
      containsAll(<String>['totalInitiated', 'failureCodeCounts']),
    );
    expect(map.values.every((v) => v is num || v is Map<String, int>), isTrue);
  });
}
