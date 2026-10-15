import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'background_downloads.dart';
import 'download_models.dart';
import 'http/partial_file_io.dart';
import 'http/resume_policy.dart';
import 'http/resume_validator_store.dart';
import 'processors/streaming_checksum.dart';

/// Progressive downloads for desktop hosts without a native WorkManager /
/// URLSession plugin (`platform_downloads` is Android/iOS only today).
class HttpBackgroundDownloads implements BackgroundDownloads {
  HttpBackgroundDownloads({
    HttpClient Function()? clientFactory,
    this._onBeforeCommitPartial,
    PartialFileIo? partialFileIo,
  }) : _clientFactory = clientFactory ?? HttpClient.new,
       _partialFileIo = partialFileIo ?? PartialFileIo();

  final HttpClient Function() _clientFactory;
  final PartialFileIo _partialFileIo;
  final Future<void> Function(File partial, File destination)?
  _onBeforeCommitPartial;
  final StreamController<DownloadProgress> _events =
      StreamController<DownloadProgress>.broadcast();
  final Map<String, _HttpDownloadJob> _jobs = {};

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

    final partial = File('${job.request.destinationPath}.partial');
    final destination = File(job.request.destinationPath);
    final validatorStore = ResumeValidatorStore(partial.path);
    final parent = destination.parent;
    if (!parent.existsSync()) {
      parent.createSync(recursive: true);
    }

    job.status = DownloadStatus.downloading;
    _emit(job.snapshot());

    final client = _clientFactory();
    client.userAgent = 'Airo/1.0 (platform_downloads; dart)';
    job.client = client;
    final startedAt = DateTime.now();

    try {
      await _downloadBody(
        job,
        client,
        partial,
        validatorStore,
        startedAt,
      );

      if (job.cancelRequested) return;

      final expected = job.request.expectedBytes;
      if (expected != null && partial.lengthSync() != expected) {
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
      if (expectedSha256 != null &&
          !await fileMatchesSha256Hex(partial, expectedSha256)) {
        await _discardPartial(partial, validatorStore);
        job.status = DownloadStatus.failed;
        job.failure = const DownloadFailure(
          code: DownloadFailureCode.integrityMismatch,
          message: 'SHA-256 checksum did not match expected value.',
        );
        _emit(job.snapshot());
        return;
      }

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
      if (job.cancelRequested) return;
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
    final workPartial = File('${partial.path}.work');

    while (true) {
      if (job.cancelRequested) return;

      var resumeOffset = _existingPartialBytes(partial);
      job.downloadedBytes = resumeOffset;

      final hasShaPin = job.request.expectedSha256 != null;
      final hasValidator = await validatorStore.hasValidator();
      final maySendRange =
          resumeOffset > 0 &&
          resumeIntegrityPinPresent(
            hasExpectedSha256: hasShaPin,
            hasStoredValidator: hasValidator,
          );

      if (resumeOffset > 0 && !maySendRange) {
        _partialFileIo.unlinkPartialEntry(partial.path);
        validatorStore.deleteSync();
        resumeOffset = 0;
        job.downloadedBytes = 0;
      }

      final outgoing = await client.getUrl(job.request.source);
      outgoing.followRedirects = true;
      outgoing.maxRedirects = 8;
      for (final entry in job.request.headers.entries) {
        outgoing.headers.set(entry.key, entry.value);
      }
      if (maySendRange) {
        outgoing.headers.set(HttpHeaders.rangeHeader, 'bytes=$resumeOffset-');
        await applyIfRangeFromStore(outgoing, validatorStore);
      }

      final response = await outgoing.close();
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
        if (workPartial.existsSync()) {
          workPartial.deleteSync();
        }
        job.downloadedBytes = 0;
        continue;
      }

      final parsedRange = parseContentRangeHeader(
        response.headers.value(HttpHeaders.contentRangeHeader),
      );

      var append =
          maySendRange &&
          resumeOffset > 0 &&
          response.statusCode == HttpStatus.partialContent &&
          parsedRange != null &&
          contentRangeHeadersPermitAppend(
            range: parsedRange,
            resumeOffset: resumeOffset,
            expectedBytes: job.request.expectedBytes,
            responseContentLength: _normalizedContentLength(response),
          );

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
          if (workPartial.existsSync()) {
            workPartial.deleteSync();
          }
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

      if (workPartial.existsSync()) {
        workPartial.deleteSync();
      }
      if (append && resumeOffset > 0 && partial.existsSync()) {
        await partial.copy(workPartial.path);
      }

      final sink = workPartial.openWrite(
        mode: append && resumeOffset > 0 ? FileMode.append : FileMode.write,
      );
      var bytesReceived = 0;
      try {
        await for (final chunk in response) {
          if (job.cancelRequested) {
            await sink.close();
            return;
          }
          sink.add(chunk);
          bytesReceived += chunk.length;
          job.downloadedBytes = resumeOffset + bytesReceived;
          final elapsed = DateTime.now().difference(startedAt).inMilliseconds;
          job.speedBytesPerSecond = elapsed <= 0
              ? 0
              : job.downloadedBytes * 1000 / elapsed;
          _emit(job.snapshot());
        }
      } finally {
        await sink.close();
      }

      if (append &&
          parsedRange != null &&
          !contentRangeBodyPermitsAppend(
            range: parsedRange,
            resumeOffset: resumeOffset,
            expectedBytes: job.request.expectedBytes,
            responseContentLength: _normalizedContentLength(response),
            bytesReceived: bytesReceived,
          )) {
        _partialFileIo.unlinkPartialEntry(partial.path);
        validatorStore.deleteSync();
        if (workPartial.existsSync()) {
          workPartial.deleteSync();
        }
        job.downloadedBytes = 0;
        continue;
      }

      await _partialFileIo.syncFile(workPartial.path);
      if (partial.existsSync()) {
        _partialFileIo.unlinkPartialEntry(partial.path);
      }
      await workPartial.rename(partial.path);
      await validatorStore.writeFromResponse(response);
      return;
    }
  }

  int _existingPartialBytes(File partial) {
    final safety = _partialFileIo.classifyPartialPath(partial.path);
    if (safety.shouldUnlinkEntry) {
      _partialFileIo.unlinkPartialEntry(partial.path);
      return 0;
    }
    if (!partial.existsSync()) {
      return 0;
    }
    return partial.lengthSync();
  }

  int? _normalizedContentLength(HttpClientResponse response) {
    final length = response.contentLength;
    if (length < 0) return null;
    return length;
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
    _partialFileIo.prepareDestinationForCommit(destination.path);
    await _partialFileIo.syncFile(partial.path);
    await partial.rename(destination.path);
    await _partialFileIo.syncDirectory(destination.parent.path);
    validatorStore.deleteSync();
    final work = File('${partial.path}.work');
    if (work.existsSync()) {
      work.deleteSync();
    }
  }

  Future<void> _discardPartial(
    File partial,
    ResumeValidatorStore validatorStore,
  ) async {
    _partialFileIo.unlinkPartialEntry(partial.path);
    validatorStore.deleteSync();
    final work = File('${partial.path}.work');
    if (work.existsSync()) {
      work.deleteSync();
    }
  }

  Future<void> _drainResponse(HttpClientResponse response) async {
    await for (final _ in response) {}
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
