/// RFC 9110: weak entity tags must not appear in If-Range.
bool isStrongEtag(String? etag) {
  if (etag == null || etag.isEmpty) return false;
  final trimmed = etag.trim();
  if (trimmed.startsWith('W/') || trimmed.startsWith('w/')) {
    return false;
  }
  return true;
}

String? strongEtagOrNull(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  return isStrongEtag(trimmed) ? trimmed : null;
}
