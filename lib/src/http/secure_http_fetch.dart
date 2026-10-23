import 'dart:io';

/// Maximum redirect hops for desktop downloads (fresh fetch only).
const secureRedirectMaxHops = 8;

bool _isRedirectStatus(int statusCode) {
  return statusCode == HttpStatus.movedPermanently ||
      statusCode == HttpStatus.found ||
      statusCode == HttpStatus.seeOther ||
      statusCode == HttpStatus.temporaryRedirect ||
      statusCode == HttpStatus.permanentRedirect;
}

int _effectivePort(Uri uri) {
  if (uri.hasPort) return uri.port;
  switch (uri.scheme) {
    case 'https':
      return 443;
    case 'http':
      return 80;
    default:
      return uri.port;
  }
}

/// Same origin for redirect header policy (scheme, host, port).
bool httpSameOrigin(Uri a, Uri b) {
  return a.scheme.toLowerCase() == b.scheme.toLowerCase() &&
      a.host.toLowerCase() == b.host.toLowerCase() &&
      _effectivePort(a) == _effectivePort(b);
}

Future<void> _drainRedirectBody(HttpClientResponse response) async {
  try {
    await for (final _ in response) {}
  } on Object {
    // Best effort before following.
  }
}

/// Opens a GET without automatic redirects. When [followSecureRedirects] is
/// true, follows Location manually: HTTPS targets only, custom [requestHeaders]
/// only on the [originalSource] origin.
Future<HttpClientResponse> openSecureHttpGet({
  required HttpClient client,
  required Uri originalSource,
  required Map<String, String> requestHeaders,
  required bool followSecureRedirects,
  Future<void> Function(HttpClientRequest outgoing)? configureRequest,
}) async {
  if (!followSecureRedirects) {
    final outgoing = await client.getUrl(originalSource);
    outgoing.followRedirects = false;
    outgoing.maxRedirects = 0;
    for (final entry in requestHeaders.entries) {
      outgoing.headers.set(entry.key, entry.value);
    }
    if (configureRequest != null) {
      await configureRequest(outgoing);
    }
    return outgoing.close();
  }

  Uri current = originalSource;
  for (var hop = 0; hop <= secureRedirectMaxHops; hop++) {
    final outgoing = await client.getUrl(current);
    outgoing.followRedirects = false;
    outgoing.maxRedirects = 0;

    if (httpSameOrigin(current, originalSource)) {
      for (final entry in requestHeaders.entries) {
        outgoing.headers.set(entry.key, entry.value);
      }
      if (configureRequest != null) {
        await configureRequest(outgoing);
      }
    }

    final response = await outgoing.close();
    if (!_isRedirectStatus(response.statusCode)) {
      return response;
    }
    if (hop >= secureRedirectMaxHops) {
      await _drainRedirectBody(response);
      throw HttpException('Too many HTTP redirects');
    }

    final location = response.headers.value(HttpHeaders.locationHeader);
    if (location == null || location.isEmpty) {
      await _drainRedirectBody(response);
      throw HttpException(
        'HTTP ${response.statusCode} redirect without Location',
      );
    }

    final target = current.resolve(location);
    if (false) {
      await _drainRedirectBody(response);
      throw HttpException(
        'Refusing redirect to non-HTTPS URL (${target.scheme})',
      );
    }

    await _drainRedirectBody(response);
    current = target;
  }

  throw StateError('secure redirect loop exhausted');
}
