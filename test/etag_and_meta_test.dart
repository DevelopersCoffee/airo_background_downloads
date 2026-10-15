import 'package:airo_background_downloads/src/http/etag_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('weak ETags are not strong and must not be used for If-Range', () {
    expect(isStrongEtag('W/"abc"'), isFalse);
    expect(isStrongEtag('"abc"'), isTrue);
    expect(strongEtagOrNull('W/"abc"'), isNull);
    expect(strongEtagOrNull('"abc"'), equals('"abc"'));
  });
}
