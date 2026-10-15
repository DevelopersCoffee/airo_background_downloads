import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'background_downloads.dart';
import 'download_models.dart';
import 'http/partial_file_identity.dart';
import 'http/partial_file_io.dart';
import 'http/download_directory_guard.dart';
import 'http/partial_path_guard.dart';
import 'http/partial_file_stat.dart';
import 'http/posix_file_read.dart';
import 'http/resume_policy.dart';
import 'http/resume_validator_store.dart';
import 'processors/streaming_checksum.dart';

const Duration _defaultConnectionTimeout = Duration(seconds: 30);
const Duration _defaultIdleReadTimeout = Duration(seconds: 60);
class HttpBackgroundDownloads implements BackgroundDownloads {
  HttpBackgroundDownloads({
    HttpClient Function()? clientFactory,
    this._onBeforeCommitPartial,
    PartialFileIo? partialFileIo,
    Duration? connectionTimeout,
    Duration? idleReadTimeout,
    this._maxDownloadBytes,
  }) : _clientFactory = clientFactory ?? HttpClient.new,
       _partialFileIo = partialFileIo ?? PartialFileIo(),
       _connectionTimeout = connectionTimeout ?? _defaultConnectionTimeout,
       _idleReadTimeout = idleReadTimeout ?? _defaultIdleReadTimeout {
    if (Platform.isAndroid || Platform.isIOS) {
      throw UnsupportedError(
        'HttpBackgroundDownloads is desktop-only (Linux, macOS, Windows). '
        'On Android and iOS use BackgroundDownloads.platform() for native engines.',
      );
    }
  }

  final HttpClient Function() _clientFactory;
  final PartialFileIo _partialFileIo;
  final Duration _connectionTimeout;
  final Duration _idleReadTimeout;
  final int? _maxDownloadBytes;
  final Future<void> Function(File partial, File destination)?
  _onBeforeCommitPartial;
  final StreamController<DownloadProgress> _events =
      StreamController<DownloadProgress>.broadcast();
  final Map<String, _HttpDownloadJob> _jobs = {};

  PartialPathGuard get _pathGuard => PartialPathGuard(_partialFileIo);

  @visibleForTesting
  PartialFileIo get partialFileIo => _partialFileIo;

  @visibleForTesting
  Future<void> Function(File partial, File destination)?
  get onBeforeCommitPartial => _onBeforeCommitPartial;

  @override
  Stream<DownloadProgress> get events => _events.stream;

  @override
  Future<void> enqueue(DownloadArtifactRequest request) async {
    final existing = _jobs[request.artifactId];
    if (existing != null &&
        existing.status != DownloadStatus.failed &&
        existing.status != DownloadStatus.cancelled) {
      return;
    }

    final job = _HttpDownloadJob(request: request);
    job.runCycle = Completer<void>();
    _jobs[request.artifactId] = job;
    _emit(job.queued());
    unawaited(_run(job));
  }

  @override
  Future<void> pause(String artifactId) async {
    final job = _jobs[artifactId];
    if (job == null) return;
    job.cancelRequested = true;
    job.client?.close(force: true);
    await _persistPartialProgress(job);
    job.status = DownloadStatus.paused;
    _emit(job.snapshot());
  }

  @override
  Future<void> resume(String artifactId) async {
    final job = _jobs[artifactId];
    if (job == null) return;
    job.cancelRequested = false;
    unawaited(_run(job));
  }

  @override
  Future<void> retry(String artifactId) async {
    final job = _jobs[artifactId];
    if (job == null) return;
    job.cancelRequested = false;
    job.downloadedBytes = 0;
    job.retryCount += 1;
    job.status = DownloadStatus.queued;
    _emit(job.snapshot());
    unawaited(_run(job));
  }

  @override
  Future<void> cancel(String artifactId) async {
    final job = _jobs[artifactId];
    if (job == null) return;
    job.cancelRequested = true;
    job.client?.close(force: true);
    await job.runCycle?.future;
    job.status = DownloadStatus.cancelled;
    _emit(
      DownloadProgress(
        artifactId: artifactId,
        status: DownloadStatus.cancelled,
        downloadedBytes: job.downloadedBytes,
        totalBytes: job.totalBytes,
        retryCount: job.retryCount,
        failure: const DownloadFailure(code: DownloadFailureCode.cancelled),
      ),
    );
    _jobs.remove(artifactId);
  }

  @override
  Future<DownloadQueueSnapshot> getQueue() async {
    return DownloadQueueSnapshot(
      entries: [for (final job in _jobs.values) job.snapshot()],
    );
  }

  @override
  Future<int?> getAvailableBytes() async => null;

  Future<void> _run(_HttpDownloadJob job) async {
    if (job.cancelRequested) return;

    job.runCycle ??= Completer<void>();
    try {
      await _runDownload(job);
    } finally {
      job.runCycle?.complete();
      job.runCycle = null;
    }
  }

  Future<void> _runDownload(_HttpDownloadJob job) async {
    final partialPath = '${job.request.destinationPath}.partial';
    final partial = File(partialPath);
    final destination = File(job.request.destinationPath);
    final validatorStore = ResumeValidatorStore(
      partialPath,
      partialFileIo: _partialFileIo,
    );
    final parent = destination.parent;

    _pathGuard.sanitizeAllForJob(
      destinationPath: destination.path,
      partialPath: partialPath,
      metaPath: '$partialPath.meta',
    );

    job.status = DownloadStatus.downloading;
    _emit(job.snapshot());

    final client = _clientFactory();
    client.connectionTimeout = _connectionTimeout;
    client.userAgent = 'Airo/1.0 (platform_downloads; dart)';
    job.client = client;
    final startedAt = DateTime.now();

    try {
      ensurePrivateDownloadDirectory(parent.path);
      await _downloadBody(job, client, partial, validatorStore, startedAt);

      if (job.cancelRequested) {
        await _persistPartialProgress(job);
        return;
      }

      final expected = job.request.expectedBytes;
      if (expected != null && job.downloadedBytes != expected) {
        await _discardPartial(partial, validatorStore);
        job.status = DownloadStatus.failed;
        job.failure = const DownloadFailure(
          code: DownloadFailureCode.integrityMismatch,
          message: 'Downloaded size did not match the expected byte count.',
        );
        _emit(job.snapshot());
        return;
      }

      job.status = DownloadStatus.verifying;
      _emit(job.snapshot());

      final expectedSha256 = job.request.expectedSha256;
      final shaOk = expectedSha256 == null
          ? true
          : job.macosPartialShaBytes != null
          ? _sha256HexMatches(job.macosPartialShaBytes!, expectedSha256)
          : await fileMatchesSha256Hex(partial, expectedSha256);
      if (expectedSha256 != null && !shaOk) {
        job.macosPartialShaBytes = null;
        await _discardPartial(partial, validatorStore);
        job.status = DownloadStatus.failed;
        job.failure = const DownloadFailure(
          code: DownloadFailureCode.integrityMismatch,
          message: 'SHA-256 checksum did not match expected value.',
        );
        _emit(job.snapshot());
        return;
      }
      job.macosPartialShaBytes = null;

      final hook = _onBeforeCommitPartial;
      var runBeforeCommitHook = false;
      assert(() {
        runBeforeCommitHook = hook != null;
        return true;
      }());
      if (runBeforeCommitHook) {
        await hook!(partial, destination);
      }

      await _commitPartialFile(partial, destination, validatorStore);

      job.status = DownloadStatus.completed;
      job.downloadedBytes = destination.lengthSync();
      job.totalBytes = job.downloadedBytes;
      _emit(job.snapshot());
      _jobs.remove(job.request.artifactId);
    } on Object catch (error) {
      if (job.cancelRequested) {
        await _persistPartialProgress(job);
        return;
      }
      job.status = DownloadStatus.failed;
      job.failure = DownloadFailure(
        code: DownloadFailureCode.transport,
        message: '$error',
      );
      _emit(job.snapshot());
    } finally {
      client.close(force: true);
      job.client = null;
    }
  }

  Future<void> _downloadBody(
    _HttpDownloadJob job,
    HttpClient client,
    File partial,
    ResumeValidatorStore validatorStore,
    DateTime startedAt,
  ) async {
    while (true) {
      if (job.cancelRequested) return;

      _pathGuard.sanitizeAllForJob(
        destinationPath: job.request.destinationPath,
        partialPath: partial.path,
        metaPath: '${partial.path}.meta',
      );

      final storedOffset = await validatorStore.readResumeByteOffsetFor(
        job.request,
      );
      var resumeOffset = storedOffset != null && storedOffset > 0
          ? storedOffset
          : _pathGuard.reusablePartialBytes(partial.path);
      job.downloadedBytes = resumeOffset;

      final hasShaPin = job.request.expectedSha256 != null;
      final hasValidator = await validatorStore.hasValidatorFor(job.request);
      final maySendRange =
          resumeOffset > 0 &&
          resumeIntegrityPinPresent(
            hasExpectedSha256: hasShaPin,
            hasStrongStoredValidator: hasValidator,
          );

      if (resumeOffset > 0 && !maySendRange) {
        _partialFileIo.unlinkPartialEntry(partial.path);
        validatorStore.deleteSync();
        resumeOffset = 0;
        job.downloadedBytes = 0;
      }

      final outgoing = await client.getUrl(job.request.source);
      outgoing.followRedirects = !maySendRange;
      outgoing.maxRedirects = 8;
      for (final entry in job.request.headers.entries) {
        outgoing.headers.set(entry.key, entry.value);
      }
      if (maySendRange) {
        outgoing.headers.set(HttpHeaders.rangeHeader, 'bytes=$resumeOffset-');
        await applyIfRangeFromStore(outgoing, validatorStore, job.request);
        outgoing.headers.set(HttpHeaders.connectionHeader, 'close');
      }
      assert(() {
        if (Platform.environment['DEBUG_N2_CANCEL'] == '1') {
          // ignore: avoid_print
          print(
            'N2 debug getUrl artifact=${job.request.artifactId} '
            'storedOffset=$storedOffset resumeOffset=$resumeOffset '
            'maySendRange=$maySendRange shaPin=$hasShaPin validator=$hasValidator '
            'outRange=${outgoing.headers.value(HttpHeaders.rangeHeader)}',
          );
        }
        return true;
      }());

      final response = await outgoing.close();
      assert(() {
        if (Platform.environment['DEBUG_N2_CANCEL'] == '1' &&
            job.request.artifactId == 'n2-interrupted') {
          // ignore: avoid_print
          print(
            'N2 debug response status=${response.statusCode} '
            'contentRange=${response.headers.value(HttpHeaders.contentRangeHeader)} '
            'contentLength=${response.contentLength}',
          );
        }
        return true;
      }());
      _recordResumeCapability(job, response);

      if (response.statusCode == 401 || response.statusCode == 403) {
        final host = job.request.source.host;
        final gatedHf = host.contains('huggingface.co');
        throw HttpException(
          gatedHf
              ? 'HTTP ${response.statusCode}: this Hugging Face file is gated. '
                    'Use a public GGUF (Unsloth) or a token with license access.'
              : 'HTTP ${response.statusCode}',
        );
      }

      if (!responseStatusAllowed(
        resumeOffset: resumeOffset,
        statusCode: response.statusCode,
        httpOk: HttpStatus.ok,
        httpPartialContent: HttpStatus.partialContent,
      )) {
        await _drainResponse(response);
        _partialFileIo.unlinkPartialEntry(partial.path);
        validatorStore.deleteSync();
        job.downloadedBytes = 0;
        continue;
      }

      var parsedRange = parseContentRangeHeader(
        response.headers.value(HttpHeaders.contentRangeHeader),
      );
      if (parsedRange == null && Platform.isMacOS) {
        parsedRange = _syntheticContentRangeFor206(
          response: response,
          resumeOffset: resumeOffset,
          expectedBytes: job.request.expectedBytes,
        );
      }

      var append =
          maySendRange &&
          resumeOffset > 0 &&
          response.statusCode == HttpStatus.partialContent &&
          parsedRange != null &&
          contentRangeHeadersPermitAppend(
            range: parsedRange,
            resumeOffset: resumeOffset,
            expectedBytes: job.request.expectedBytes,
            responseContentLength: _expectedResponseBodyBytes(
              response,
              parsedRange,
            ),
          );

      if (!append &&
          Platform.isMacOS &&
          maySendRange &&
          resumeOffset > 0 &&
          response.statusCode == HttpStatus.ok &&
          job.request.expectedBytes != null) {
        final tailBytes = job.request.expectedBytes! - resumeOffset;
        final responseLen = _normalizedContentLength(response);
        if (tailBytes > 0 && responseLen == tailBytes) {
          parsedRange = ContentRangeSpec(
            start: resumeOffset,
            end: job.request.expectedBytes! - 1,
            total: job.request.expectedBytes,
          );
          append = true;
        }
      }

      if (resumeOffset > 0 && !append) {
        if (response.statusCode == HttpStatus.ok) {
          _partialFileIo.unlinkPartialEntry(partial.path);
          validatorStore.deleteSync();
          job.downloadedBytes = 0;
          resumeOffset = 0;
          append = false;
        } else {
          await _drainResponse(response);
          _partialFileIo.unlinkPartialEntry(partial.path);
          validatorStore.deleteSync();
          job.downloadedBytes = 0;
          continue;
        }
      }

      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        throw HttpException('HTTP ${response.statusCode}');
      }

      _applyTotalBytes(
        job,
        response,
        parsedRange: parsedRange,
        append: append,
        resumeOffset: resumeOffset,
      );

      final doAppend = append && resumeOffset > 0;
      PartialFileIdentity? expectedIdentity;
      if (doAppend) {
        expectedIdentity = await validatorStore.readPartialIdentityFor(
          job.request,
        );
      }

      PartialFileIdentity? identityForOpen = expectedIdentity;
      if (Platform.isMacOS && doAppend) {
        final storedOffset = await validatorStore.readResumeByteOffsetFor(
          job.request,
        );
        final partialSize = platformPathFileSize(partial.path);
        if (storedOffset != null &&
            partialSize != null &&
            storedOffset == partialSize &&
            storedOffset == resumeOffset) {
          identityForOpen = null;
        }
      }

      late final PartialFileWriter writer;
      try {
        writer = await _partialFileIo.openVerifiedPartialWriter(
          partial.path,
          append: doAppend,
          expectedIdentity: identityForOpen,
        );
        job.partialOpenFailures = 0;
      } on FileSystemException catch (e) {
        assert(() {
          if (Platform.environment['DEBUG_N2_CANCEL'] == '1' &&
              job.request.artifactId == 'n2-interrupted') {
            // ignore: avoid_print
            print(
              'N2 debug partial open failed: $e append=$doAppend '
              'identity=${identityForOpen != null}',
            );
          }
          return true;
        }());
        job.partialOpenFailures += 1;
        if (job.partialOpenFailures > 4) {
          rethrow;
        }
        _partialFileIo.unlinkPartialEntry(partial.path);
        validatorStore.deleteSync();
        job.downloadedBytes = 0;
        continue;
      }

      await validatorStore.writeFromResponse(
        response,
        request: job.request,
        partialIdentity: writer.identity,
      );
      if (!doAppend) {
        await validatorStore.attachPartialIdentity(writer.identity);
      }

      var bytesReceived = 0;
      var writerClosed = false;
      Future<void> closeWriter() async {
        if (writerClosed) return;
        await writer.close();
        writerClosed = true;
      }

      try {
        await for (final chunk in response.timeout(_idleReadTimeout)) {
          if (job.cancelRequested) {
            await validatorStore.persistResumeByteOffset(
              job.downloadedBytes,
              request: job.request,
            );
            await closeWriter();
            await _partialFileIo.syncFile(partial.path);
            return;
          }
          _enforceSizeCap(resumeOffset + bytesReceived + chunk.length, job);
          writer.writeBytes(chunk);
          bytesReceived += chunk.length;
          job.downloadedBytes = resumeOffset + bytesReceived;
          final elapsed = DateTime.now().difference(startedAt).inMilliseconds;
          job.speedBytesPerSecond = elapsed <= 0
              ? 0
              : job.downloadedBytes * 1000 / elapsed;
          _emit(job.snapshot());
        }
      } on TimeoutException {
        await closeWriter();
        await _partialFileIo.syncFile(partial.path);
        throw HttpException('HTTP idle read timeout');
      } on Object {
        if (job.cancelRequested) {
          await validatorStore.persistResumeByteOffset(
            job.downloadedBytes,
            request: job.request,
          );
          await closeWriter();
          await _partialFileIo.syncFile(partial.path);
          return;
        }
        await closeWriter();
        rethrow;
      }

      await closeWriter();
      if (Platform.isMacOS && job.request.expectedSha256 != null) {
        job.macosPartialShaBytes = await readRegularFileBytesPosix(
          partial.path,
        );
      }

      final declaredLength = _expectedResponseBodyBytes(response, parsedRange);
      if (declaredLength != null && bytesReceived != declaredLength) {
        if (bytesReceived > 0) {
          await validatorStore.persistResumeByteOffset(
            resumeOffset + bytesReceived,
            request: job.request,
          );
          await _partialFileIo.syncFile(partial.path);
        }
        throw HttpException(
          'Incomplete HTTP body ($bytesReceived/$declaredLength bytes)',
        );
      }

      if (append &&
          parsedRange != null &&
          !contentRangeBodyPermitsAppend(
            range: parsedRange,
            resumeOffset: resumeOffset,
            expectedBytes: job.request.expectedBytes,
            responseContentLength: _expectedResponseBodyBytes(
              response,
              parsedRange,
            ),
            bytesReceived: bytesReceived,
          )) {
        _partialFileIo.unlinkPartialEntry(partial.path);
        validatorStore.deleteSync();
        job.downloadedBytes = 0;
        continue;
      }

      await _partialFileIo.syncFile(partial.path);
      return;
    }
  }

  void _enforceSizeCap(int nextTotalBytes, _HttpDownloadJob job) {
    final cap = job.request.expectedBytes ?? _maxDownloadBytes;
    if (cap == null) {
      return;
    }
    if (nextTotalBytes > cap) {
      throw HttpException('Download exceeded allowed size ($cap bytes)');
    }
  }

  Future<void> _persistPartialProgress(_HttpDownloadJob job) async {
    final partialPath = '${job.request.destinationPath}.partial';
    final inspection = _partialFileIo.inspectPath(partialPath);
    if (!inspection.isSafeRegularFileOwnedByUs) return;
    if (job.downloadedBytes == 0) return;
    final validatorStore = ResumeValidatorStore(
      partialPath,
      partialFileIo: _partialFileIo,
    );
    await validatorStore.persistResumeByteOffset(
              job.downloadedBytes,
              request: job.request,
            );
    await _partialFileIo.syncFile(partialPath);
  }

  int? _normalizedContentLength(HttpClientResponse response) {
    final length = response.contentLength;
    if (length < 0) return null;
    return length;
  }

  /// Bytes expected for this response body (206 uses Content-Range segment).
  int? _expectedResponseBodyBytes(
    HttpClientResponse response,
    ContentRangeSpec? parsedRange,
  ) {
    if (response.statusCode == HttpStatus.partialContent &&
        parsedRange != null) {
      return parsedRange.segmentLength;
    }
    return _normalizedContentLength(response);
  }

  ContentRangeSpec? _syntheticContentRangeFor206({
    required HttpClientResponse response,
    required int resumeOffset,
    required int? expectedBytes,
  }) {
    if (response.statusCode != HttpStatus.partialContent) return null;
    if (resumeOffset <= 0 || expectedBytes == null) return null;
    final total = expectedBytes;
    final len = _normalizedContentLength(response);
    if (len != null && len > 0) {
      final segmentLen = len == total ? total - resumeOffset : len;
      if (segmentLen > 0 && resumeOffset + segmentLen == total) {
        return ContentRangeSpec(
          start: resumeOffset,
          end: total - 1,
          total: total,
        );
      }
    }
    return ContentRangeSpec(
      start: resumeOffset,
      end: total - 1,
      total: total,
    );
  }

  void _recordResumeCapability(_HttpDownloadJob job, HttpClientResponse response) {
    final acceptRanges = response.headers.value(HttpHeaders.acceptRangesHeader);
    final advertises =
        acceptRanges != null && acceptRanges.toLowerCase().contains('bytes');
    job.serverAdvertisedResume =
        advertises || response.statusCode == HttpStatus.partialContent;
  }

  void _applyTotalBytes(
    _HttpDownloadJob job,
    HttpClientResponse response, {
    required ContentRangeSpec? parsedRange,
    required bool append,
    required int resumeOffset,
  }) {
    if (parsedRange?.total != null) {
      job.totalBytes = parsedRange!.total!;
      return;
    }
    final contentLength = _normalizedContentLength(response);
    if (contentLength != null && contentLength > 0) {
      job.totalBytes = append
          ? resumeOffset + contentLength
          : contentLength;
    } else if (job.request.expectedBytes != null) {
      job.totalBytes = job.request.expectedBytes!;
    }
  }

  Future<void> _commitPartialFile(
    File partial,
    File destination,
    ResumeValidatorStore validatorStore,
  ) async {
    _pathGuard.requireSafeRegularPartialBeforeCommit(partial.path);
    _partialFileIo.prepareDestinationForCommit(destination.path);
    await _partialFileIo.syncFile(partial.path);
    await _partialFileIo.syncDirectory(destination.parent.path);
    await partial.rename(destination.path);
    if (Platform.isMacOS) {
      posixChmodPath(destination.path, 420); // 0644 under private download dirs
    }
    await _partialFileIo.syncDirectory(destination.parent.path);
    validatorStore.deleteSync();
    _partialFileIo.unlinkPartialEntry('${partial.path}.work');
  }

  Future<void> _discardPartial(
    File partial,
    ResumeValidatorStore validatorStore,
  ) async {
    _partialFileIo.unlinkPartialEntry(partial.path);
    validatorStore.deleteSync();
    _partialFileIo.unlinkPartialEntry('${partial.path}.work');
  }

  Future<void> _drainResponse(HttpClientResponse response) async {
    await for (final _ in response.timeout(_idleReadTimeout)) {}
  }

  bool _sha256HexMatches(List<int> bytes, String expectedHex) {
    final digest = sha256.convert(bytes).toString();
    return digest.toLowerCase() == expectedHex.trim().toLowerCase();
  }

  void _emit(DownloadProgress progress) {
    if (!_events.isClosed) {
      _events.add(progress);
    }
  }
}

class _HttpDownloadJob {
  _HttpDownloadJob({required this.request})
    : totalBytes = request.expectedBytes ?? 0;

  final DownloadArtifactRequest request;
  DownloadStatus status = DownloadStatus.queued;
  int downloadedBytes = 0;
  int totalBytes;
  double speedBytesPerSecond = 0;
  int retryCount = 0;
  DownloadFailure? failure;
  bool cancelRequested = false;
  HttpClient? client;
  bool serverAdvertisedResume = false;
  int partialOpenFailures = 0;
  List<int>? macosPartialShaBytes;
  Completer<void>? runCycle;

  DownloadProgress queued() => DownloadProgress(
    artifactId: request.artifactId,
    status: DownloadStatus.queued,
    downloadedBytes: 0,
    totalBytes: totalBytes,
    retryCount: retryCount,
    queuePosition: 0,
  );

  DownloadProgress snapshot() => DownloadProgress(
    artifactId: request.artifactId,
    status: status,
    downloadedBytes: downloadedBytes,
    totalBytes: totalBytes,
    speedBytesPerSecond: speedBytesPerSecond,
    retryCount: retryCount,
    failure: failure,
    resumeSupported: serverAdvertisedResume,
  );
}
