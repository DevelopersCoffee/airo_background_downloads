import 'dart:convert';
import 'dart:io';

import '../download_models.dart';
import 'etag_utils.dart';
import 'partial_file_identity.dart';
import 'partial_file_io.dart';

class ResumeValidatorStore {
  ResumeValidatorStore(
    String partialPath, {
    PartialFileIo? partialFileIo,
  }) : _metaPath = '$partialPath.meta',
       _partialFileIo = partialFileIo ?? PartialFileIo();

  final String _metaPath;
  final PartialFileIo _partialFileIo;

  Future<bool> hasValidatorFor(DownloadArtifactRequest request) async {
    final record = await _readRecord();
    if (record == null) return false;
    if (!_recordMatchesRequest(record, request)) return false;
    return record.hasStrongResumeValidator;
  }

  Future<PartialFileIdentity?> readPartialIdentityFor(
    DownloadArtifactRequest request,
  ) async {
    final record = await _readRecord();
    if (record == null || !_recordMatchesRequest(record, request)) {
      return null;
    }
    return record.partialIdentity;
  }

  Future<void> attachPartialIdentity(PartialFileIdentity identity) async {
    final existing = await _readRecord();
    if (existing == null) return;
    await _writeRecord(
      _ResumeRecord(
        source: existing.source,
        expectedBytes: existing.expectedBytes,
        expectedSha256: existing.expectedSha256,
        strongEtag: existing.strongEtag,
        lastModified: existing.lastModified,
        partialIdentity: identity,
      ),
    );
  }

  Future<ResumeValidators?> readValidatorsFor(
    DownloadArtifactRequest request,
  ) async {
    final record = await _readRecord();
    if (record == null || !_recordMatchesRequest(record, request)) {
      return null;
    }
    if (!record.hasStrongResumeValidator) return null;
    return ResumeValidators(
      etag: record.strongEtag,
      lastModified: record.lastModified,
    );
  }

  Future<void> writeFromResponse(
    HttpClientResponse response, {
    required DownloadArtifactRequest request,
    PartialFileIdentity? partialIdentity,
  }) async {
    final strongEtag = strongEtagOrNull(
      response.headers.value(HttpHeaders.etagHeader),
    );
    final lastModified = response.headers.value(
      HttpHeaders.lastModifiedHeader,
    )?.trim();
    if (strongEtag == null &&
        (lastModified == null || lastModified.isEmpty)) {
      return;
    }
    final existing = await _readRecord();
    final record = _ResumeRecord(
      source: request.source.toString(),
      expectedBytes: request.expectedBytes,
      expectedSha256: request.expectedSha256,
      strongEtag: strongEtag,
      lastModified:
          (lastModified != null && lastModified.isNotEmpty) ? lastModified : null,
      partialIdentity: partialIdentity ?? existing?.partialIdentity,
    );
    await _writeRecord(record);
  }

  Future<_ResumeRecord?> _readRecord() async {
    final inspection = _partialFileIo.inspectPath(_metaPath);
    if (inspection.isAbsent) return null;
    if (!inspection.isSafeRegularFileOwnedByUs) {
      _partialFileIo.unlinkPartialEntry(_metaPath);
      return null;
    }
    try {
      final map =
          jsonDecode(await File(_metaPath).readAsString())
              as Map<String, dynamic>;
      return _ResumeRecord.fromMap(map);
    } on Object {
      _partialFileIo.unlinkPartialEntry(_metaPath);
      return null;
    }
  }

  void deleteSync() {
    _partialFileIo.unlinkPartialEntry(_metaPath);
  }

  Future<void> delete() async {
    deleteSync();
  }

  bool _recordMatchesRequest(
    _ResumeRecord record,
    DownloadArtifactRequest request,
  ) {
    if (record.source != request.source.toString()) return false;
    if (record.expectedBytes != request.expectedBytes) return false;
    if (record.expectedSha256 != request.expectedSha256) return false;
    return true;
  }

  Future<void> _writeRecord(_ResumeRecord record) async {
    _partialFileIo.unlinkPartialEntry(_metaPath);
    final parent = Directory(File(_metaPath).parent.path);
    if (!parent.existsSync()) {
      parent.createSync(recursive: true);
    }
    File(_metaPath).createSync(exclusive: true);
    await File(_metaPath).writeAsString(jsonEncode(record.toMap()));
  }
}

class ResumeValidators {
  const ResumeValidators({this.etag, this.lastModified});

  final String? etag;
  final String? lastModified;
}

class _ResumeRecord {
  const _ResumeRecord({
    required this.source,
    this.expectedBytes,
    this.expectedSha256,
    this.strongEtag,
    this.lastModified,
    this.partialIdentity,
  });

  final String source;
  final int? expectedBytes;
  final String? expectedSha256;
  final String? strongEtag;
  final String? lastModified;
  final PartialFileIdentity? partialIdentity;

  bool get hasStrongResumeValidator =>
      (strongEtag?.isNotEmpty ?? false) ||
      (lastModified?.isNotEmpty ?? false);

  Map<String, Object?> toMap() => {
    'source': source,
    if (expectedBytes != null) 'expectedBytes': expectedBytes,
    if (expectedSha256 != null) 'expectedSha256': expectedSha256,
    if (strongEtag != null) 'etag': strongEtag,
    if (lastModified != null) 'lastModified': lastModified,
    if (partialIdentity != null) 'partialIdentity': partialIdentity!.toJson(),
  };

  factory _ResumeRecord.fromMap(Map<String, dynamic> map) {
    return _ResumeRecord(
      source: map['source'] as String? ?? '',
      expectedBytes: (map['expectedBytes'] as num?)?.toInt(),
      expectedSha256: map['expectedSha256'] as String?,
      strongEtag: strongEtagOrNull(map['etag'] as String?),
      lastModified: map['lastModified'] as String?,
      partialIdentity: PartialFileIdentity.fromJson(
        map['partialIdentity'] as Map<String, dynamic>?,
      ),
    );
  }
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
  DownloadArtifactRequest artifactRequest,
) async {
  final validators = await store.readValidatorsFor(artifactRequest);
  if (validators == null) return;
  applyIfRangeHeader(request, validators);
}
