/// Pure resume / Content-Range validation (desktop HTTP downloads).
library;

/// Parsed `Content-Range: bytes start-end/total` header.
class ContentRangeSpec {
  const ContentRangeSpec({
    required this.start,
    required this.end,
    this.total,
  });

  final int start;
  final int end;

  /// `null` when the header used `*` for total length.
  final int? total;

  int get segmentLength => end - start + 1;
}

ContentRangeSpec? parseContentRangeHeader(String? header) {
  if (header == null) return null;
  final match = RegExp(
    r'^bytes (\d+)-(\d+)/(\d+|\*)$',
  ).firstMatch(header.trim());
  if (match == null) return null;
  final totalGroup = match.group(3);
  return ContentRangeSpec(
    start: int.parse(match.group(1)!),
    end: int.parse(match.group(2)!),
    total: totalGroup == '*' ? null : int.parse(totalGroup!),
  );
}

/// Whether resume is allowed for an existing partial byte count.
bool resumeIntegrityPinPresent({
  required bool hasExpectedSha256,
  required bool hasStoredValidator,
}) {
  return hasExpectedSha256 || hasStoredValidator;
}

/// Fresh downloads (`resumeOffset == 0`) must not accept 206 (B3).
bool responseStatusAllowed({
  required int resumeOffset,
  required int statusCode,
  required int httpOk,
  required int httpPartialContent,
}) {
  if (resumeOffset == 0) {
    return statusCode == httpOk;
  }
  return statusCode == httpOk || statusCode == httpPartialContent;
}

/// Header-level Content-Range checks before reading the body (B2).
bool contentRangeHeadersPermitAppend({
  required ContentRangeSpec range,
  required int resumeOffset,
  required int? expectedBytes,
  required int? responseContentLength,
}) {
  if (range.start != resumeOffset) {
    return false;
  }
  final total = range.total;
  if (total == null) {
    return false;
  }
  if (range.end != total - 1) {
    return false;
  }
  if (expectedBytes != null && total != expectedBytes) {
    return false;
  }
  final segment = range.segmentLength;
  if (responseContentLength != null &&
      responseContentLength >= 0 &&
      responseContentLength != segment) {
    return false;
  }
  return true;
}

/// Full Content-Range validation including bytes received for this response (B2).
bool contentRangeBodyPermitsAppend({
  required ContentRangeSpec range,
  required int resumeOffset,
  required int? expectedBytes,
  required int? responseContentLength,
  required int bytesReceived,
}) {
  if (!contentRangeHeadersPermitAppend(
    range: range,
    resumeOffset: resumeOffset,
    expectedBytes: expectedBytes,
    responseContentLength: responseContentLength,
  )) {
    return false;
  }
  return bytesReceived == range.segmentLength;
}
