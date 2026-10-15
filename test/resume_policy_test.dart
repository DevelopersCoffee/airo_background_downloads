import 'package:airo_background_downloads/src/http/resume_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('B2 Content-Range validation', () {
    test('rejects star total', () {
      final range = ContentRangeSpec(start: 40, end: 49, total: null);
      expect(
        contentRangeHeadersPermitAppend(
          range: range,
          resumeOffset: 40,
          expectedBytes: null,
          responseContentLength: 10,
        ),
        isFalse,
      );
    });

    test('rejects end before total minus one', () {
      final range = ContentRangeSpec(start: 40, end: 48, total: 100);
      expect(
        contentRangeHeadersPermitAppend(
          range: range,
          resumeOffset: 40,
          expectedBytes: 100,
          responseContentLength: 9,
        ),
        isFalse,
      );
    });

    test('rejects content length mismatch', () {
      final range = ContentRangeSpec(start: 10, end: 19, total: 100);
      expect(
        contentRangeHeadersPermitAppend(
          range: range,
          resumeOffset: 10,
          expectedBytes: 100,
          responseContentLength: 5,
        ),
        isFalse,
      );
    });

    test('rejects body shorter than Content-Range segment', () {
      final range = ContentRangeSpec(start: 10, end: 19, total: 100);
      expect(
        contentRangeBodyPermitsAppend(
          range: range,
          resumeOffset: 10,
          expectedBytes: 100,
          responseContentLength: 10,
          bytesReceived: 9,
        ),
        isFalse,
      );
    });

    test('accepts valid full-file 206 tail', () {
      final range = ContentRangeSpec(start: 90, end: 99, total: 100);
      expect(
        contentRangeBodyPermitsAppend(
          range: range,
          resumeOffset: 90,
          expectedBytes: 100,
          responseContentLength: 10,
          bytesReceived: 10,
        ),
        isTrue,
      );
    });
  });

  group('B3 fresh download status', () {
    test('rejects 206 when resume offset is zero', () {
      expect(
        responseStatusAllowed(
          resumeOffset: 0,
          statusCode: 206,
          httpOk: 200,
          httpPartialContent: 206,
        ),
        isFalse,
      );
    });

    test('accepts 200 when resume offset is zero', () {
      expect(
        responseStatusAllowed(
          resumeOffset: 0,
          statusCode: 200,
          httpOk: 200,
          httpPartialContent: 206,
        ),
        isTrue,
      );
    });
  });

  group('B1 integrity pin', () {
    test('requires sha256 or stored validator to resume', () {
      expect(
        resumeIntegrityPinPresent(
          hasExpectedSha256: false,
          hasStoredValidator: false,
        ),
        isFalse,
      );
      expect(
        resumeIntegrityPinPresent(
          hasExpectedSha256: true,
          hasStoredValidator: false,
        ),
        isTrue,
      );
      expect(
        resumeIntegrityPinPresent(
          hasExpectedSha256: false,
          hasStoredValidator: true,
        ),
        isTrue,
      );
    });
  });
}
