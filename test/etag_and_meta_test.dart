import 'dart:convert';
import 'dart:io';

import 'package:airo_background_downloads/airo_background_downloads.dart';
import 'package:airo_background_downloads/src/http/etag_utils.dart';
import 'package:airo_background_downloads/src/http/resume_validator_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('weak ETags are not strong and must not be used for If-Range', () {
    expect(isStrongEtag('W/"abc"'), isFalse);
    expect(isStrongEtag('"abc"'), isTrue);
    expect(strongEtagOrNull('W/"abc"'), isNull);
    expect(strongEtagOrNull('"abc"'), equals('"abc"'));
  });

  test('resume without sha requires strong validator in meta', () async {
    final dir = await Directory.systemTemp.createTemp('weak-meta-resume-');
    addTearDown(() => dir.delete(recursive: true));
    final partialPath = '${dir.path}/part.partial';
    await File(partialPath).writeAsBytes([1, 2, 3]);
    await File('$partialPath.meta').writeAsString(
      jsonEncode({
        'source': 'https://example.com/file',
        'etag': 'W/"weak-only"',
      }),
    );
    final store = ResumeValidatorStore(partialPath);
    final ok = await store.hasValidatorFor(
      DownloadArtifactRequest(
        artifactId: 'weak',
        source: Uri.parse('https://example.com/file'),
        destinationPath: '${dir.path}/out.bin',
      ),
    );
    expect(ok, isFalse);
  });
}
