import 'dart:convert';
import 'dart:io';

/// Persists ETag / Last-Modified from the first complete response for If-Range.
class ResumeValidatorStore {
  ResumeValidatorStore(String partialPath)
    : _metaPath = '$partialPath.meta';

  final String _metaPath;

  Future<bool> hasValidator() async {
    final data = await read();
    return data != null &&
        ((data.etag != null && data.etag!.isNotEmpty) ||
            (data.lastModified != null && data.lastModified!.isNotEmpty));
  }

  Future<ResumeValidators?> read() async {
    final file = File(_metaPath);
    if (!await file.exists()) return null;
    try {
      final map = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return ResumeValidators(
        etag: map['etag'] as String?,
        lastModified: map['lastModified'] as String?,
      );
    } on Object {
      return null;
    }
  }

  Future<void> writeFromResponse(HttpClientResponse response) async {
    final etag = response.headers.value(HttpHeaders.etagHeader)?.trim();
    final lastModified = response.headers.value(
      HttpHeaders.lastModifiedHeader,
    )?.trim();
    if ((etag == null || etag.isEmpty) &&
        (lastModified == null || lastModified.isEmpty)) {
      return;
    }
    final file = File(_metaPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode(<String, String?>{
        if (etag != null && etag.isNotEmpty) 'etag': etag,
        if (lastModified != null && lastModified.isNotEmpty)
          'lastModified': lastModified,
      }),
    );
  }

  void deleteSync() {
    final file = File(_metaPath);
    if (file.existsSync()) {
      file.deleteSync();
    }
  }

  Future<void> delete() async {
    final file = File(_metaPath);
    if (await file.exists()) {
      await file.delete();
    }
  }
}

class ResumeValidators {
  const ResumeValidators({this.etag, this.lastModified});

  final String? etag;
  final String? lastModified;
}

void applyIfRangeHeader(HttpClientRequest request, ResumeValidators validators) {
  final etag = validators.etag;
  if (etag != null && etag.isNotEmpty) {
    request.headers.set(HttpHeaders.ifRangeHeader, etag);
    return;
  }
  final lastModified = validators.lastModified;
  if (lastModified != null && lastModified.isNotEmpty) {
    request.headers.set(HttpHeaders.ifRangeHeader, lastModified);
  }
}

Future<void> applyIfRangeFromStore(
  HttpClientRequest request,
  ResumeValidatorStore store,
) async {
  final validators = await store.read();
  if (validators == null) return;
  applyIfRangeHeader(request, validators);
}
