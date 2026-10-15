import 'dart:convert';
import 'dart:io';

import 'package:airo_background_downloads/airo_background_downloads.dart';
import 'package:airo_background_downloads/src/http/partial_file_io.dart';
import 'package:airo_background_downloads/src/http/partial_file_io_posix.dart';
import 'package:airo_background_downloads/src/http/partial_file_stat.dart';
import 'package:airo_background_downloads/src/http/posix_file_read.dart';
import 'package:airo_background_downloads/src/http/posix_syscalls.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

Future<List<int>> _readFileBytes(String path) async {
  if (Platform.isMacOS) {
    return readRegularFileBytesPosix(path);
  }
  return File(path).readAsBytes();
}

Future<String> _readFileString(String path) async {
  return utf8.decode(await _readFileBytes(path));
}

Future<void> _dumpN2CancelDiagnostics(String destinationPath) async {
  if (Platform.environment['DEBUG_N2_CANCEL'] != '1') return;
  final partialPath = '$destinationPath.partial';
  final metaPath = '$partialPath.meta';
  // ignore: avoid_print
  print('N2 debug partialPath=$partialPath');
  // ignore: avoid_print
  print('N2 debug lstat st_size=${platformPathFileSize(partialPath)}');
  // ignore: avoid_print
  print('N2 debug fstat st_size=${platformPathFileSizeFstat(partialPath)}');
  try {
    final metaBytes = await readRegularFileBytesPosix(metaPath);
    final metaText = utf8.decode(metaBytes);
    // ignore: avoid_print
    print('N2 debug .meta contents: $metaText');
    final map = jsonDecode(metaText) as Map<String, dynamic>;
    // ignore: avoid_print
    print('N2 debug resumeByteOffset=${map['resumeByteOffset']}');
  } on Object catch (error) {
    // ignore: avoid_print
    print('N2 debug .meta read failed: $error');
  }
}

void main() {
  late SecurityContext serverContext;
  late Directory tempDir;

  setUpAll(() async {
    final certDir = await Directory.systemTemp.createTemp('airo-bg-dl-certs-');
    final certPath = '${certDir.path}/server.crt';
    final keyPath = '${certDir.path}/server.key';
    final result = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-keyout',
      keyPath,
      '-out',
      certPath,
      '-days',
      '1',
      '-subj',
      '/CN=localhost',
    ]);
    expect(result.exitCode, equals(0), reason: result.stderr.toString());

    serverContext = SecurityContext()
      ..useCertificateChain(certPath)
      ..usePrivateKey(keyPath);
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('http-dl-blockers-');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  HttpClient testClient() {
    return HttpClient(context: SecurityContext())
      ..badCertificateCallback = (cert, host, port) => true;
  }

  Future<Uri> bindServer(
    Future<void> Function(HttpRequest request) handler,
  ) async {
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      serverContext,
    );
    addTearDown(() async => server.close(force: true));
    server.listen(handler);
    return Uri.parse('https://${server.address.host}:${server.port}/file');
  }

  Future<DownloadProgress> waitForTerminal(
    HttpBackgroundDownloads downloads,
    String artifactId,
  ) async {
    return downloads.events.firstWhere(
      (event) =>
          event.artifactId == artifactId &&
          (event.status == DownloadStatus.completed ||
              event.status == DownloadStatus.failed),
    );
  }

  String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

  test('B1 resume without validator restarts instead of splicing bytes', () async {
    final stale = List<int>.filled(40, 'A'.codeUnitAt(0));
    final fullB = List<int>.filled(100, 'B'.codeUnitAt(0));
    final destination = File('${tempDir.path}/mixed.bin');
    final partial = File('${destination.path}.partial');
    await partial.writeAsBytes(stale);

    final url = await bindServer((request) async {
      if (request.headers.value(HttpHeaders.rangeHeader) != null) {
        request.response
          ..statusCode = HttpStatus.partialContent
          ..headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 40-99/100',
          )
          ..contentLength = 60
          ..add(fullB.sublist(40))
          ..close();
        return;
      }
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = fullB.length
        ..add(fullB)
        ..close();
    });

    final downloads = HttpBackgroundDownloads(clientFactory: testClient);
    await downloads.enqueue(
      DownloadArtifactRequest(
        artifactId: 'b1-no-validator',
        source: url,
        destinationPath: destination.path,
        expectedBytes: fullB.length,
      ),
    );

    final terminal = await waitForTerminal(downloads, 'b1-no-validator');
    expect(terminal.status, DownloadStatus.completed);
    expect(await _readFileBytes(destination.path), equals(fullB));
  });

  test('B2 star total Content-Range triggers clean restart', () async {
    final payload = utf8.encode('star-total-restart-payload!!');
    final destination = File('${tempDir.path}/star.bin');
    final partial = File('${destination.path}.partial');
    await partial.writeAsBytes(payload.sublist(0, 10));

    var requestCount = 0;
    final url = await bindServer((request) async {
      requestCount += 1;
      if (requestCount == 1) {
        request.response
          ..statusCode = HttpStatus.partialContent
          ..headers.set(HttpHeaders.contentRangeHeader, 'bytes 10-19/*')
          ..contentLength = 10
          ..add(payload.sublist(10, 20))
          ..close();
        return;
      }
      expect(request.headers.value(HttpHeaders.rangeHeader), isNull);
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = payload.length
        ..add(payload)
        ..close();
    });

    final downloads = HttpBackgroundDownloads(clientFactory: testClient);
    await downloads.enqueue(
      DownloadArtifactRequest(
        artifactId: 'b2-star-total',
        source: url,
        destinationPath: destination.path,
        expectedBytes: payload.length,
        expectedSha256: sha256Hex(payload),
      ),
    );

    final terminal = await waitForTerminal(downloads, 'b2-star-total');
    expect(terminal.status, DownloadStatus.completed);
    expect(await _readFileBytes(destination.path), equals(payload));
    expect(requestCount, equals(2));
  });

  test('B3 fresh download rejects 206 without Range request', () async {
    final payload = List<int>.generate(100, (index) => 0x61 + (index % 26));
    final destination = File('${tempDir.path}/fresh.bin');

    var requestCount = 0;
    final url = await bindServer((request) async {
      requestCount += 1;
      expect(request.headers.value(HttpHeaders.rangeHeader), isNull);
      if (requestCount == 1) {
        request.response
          ..statusCode = HttpStatus.partialContent
          ..headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 50-99/${payload.length}',
          )
          ..contentLength = 50
          ..add(payload.sublist(50))
          ..close();
        return;
      }
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = payload.length
        ..add(payload)
        ..close();
    });

    final downloads = HttpBackgroundDownloads(clientFactory: testClient);
    await downloads.enqueue(
      DownloadArtifactRequest(
        artifactId: 'b3-no-range-206',
        source: url,
        destinationPath: destination.path,
        expectedBytes: payload.length,
      ),
    );

    final terminal = await waitForTerminal(downloads, 'b3-no-range-206');
    expect(terminal.status, DownloadStatus.completed);
    expect(await _readFileBytes(destination.path), equals(payload));
    expect(requestCount, equals(2));
  });

  test('K1 hardlinked partial with validator must not grow victim on resume', () async {
    const totalSize = 100000;
    final victim = File('${tempDir.path}/k1-victim.bin');
    final victimBytes = List<int>.filled(40, 'V'.codeUnitAt(0));
    await victim.writeAsBytes(victimBytes);

    final destination = File('${tempDir.path}/k1-dest.bin');
    final partial = File('${destination.path}.partial');
    if (Platform.isWindows) {
      final linkResult = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-Command',
          "New-Item -ItemType HardLink -Path '${partial.path.replaceAll("'", "''")}' "
              "-Target '${victim.path.replaceAll("'", "''")}' | Out-Null",
        ],
      );
      expect(linkResult.exitCode, equals(0), reason: linkResult.stderr.toString());
    } else {
      final linkResult = await Process.run('ln', [victim.path, partial.path]);
      expect(linkResult.exitCode, equals(0), reason: linkResult.stderr.toString());
    }

    final payload = List<int>.generate(totalSize, (i) => i % 251);
    final requestLog = <String?>[];
    final boundUrl = await bindServer((request) async {
      requestLog.add(request.headers.value(HttpHeaders.rangeHeader));
      request.response.headers.set(HttpHeaders.etagHeader, '"k1-strong"');
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range == 'bytes=40-') {
        request.response
          ..statusCode = HttpStatus.partialContent
          ..headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 40-${totalSize - 1}/$totalSize',
          )
          ..contentLength = totalSize - 40
          ..add(payload.sublist(40))
          ..close();
        return;
      }
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = totalSize
        ..add(payload)
        ..close();
    });

    final meta = File('${partial.path}.meta');
    await meta.writeAsString(
      jsonEncode({
        'source': boundUrl.toString(),
        'expectedBytes': totalSize,
        'etag': '"k1-strong"',
      }),
    );

    final downloads = HttpBackgroundDownloads(clientFactory: testClient);
    await downloads.enqueue(
      DownloadArtifactRequest(
        artifactId: 'k1-hardlink-resume',
        source: boundUrl,
        destinationPath: destination.path,
        expectedBytes: totalSize,
      ),
    );

    final terminal = await waitForTerminal(downloads, 'k1-hardlink-resume');
    expect(terminal.status, DownloadStatus.completed);
    expect(await _readFileBytes(victim.path), equals(victimBytes));
    expect(await _readFileBytes(destination.path), equals(payload));
    expect(
      requestLog.any((header) => header == 'bytes=40-'),
      isFalse,
      reason: 'must not resume-append into a hardlinked partial inode',
    );
  });

  test('B4 hardlinked partial does not mutate the linked victim file', () async {
    final victim = File('${tempDir.path}/victim.bin');
    await victim.writeAsBytes(utf8.encode('unchanged-victim-bytes'));
    final destination = File('${tempDir.path}/out.bin');
    final partial = File('${destination.path}.partial');

    if (Platform.isWindows) {
      final linkResult = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-Command',
          "New-Item -ItemType HardLink -Path '${partial.path.replaceAll("'", "''")}' "
              "-Target '${victim.path.replaceAll("'", "''")}' | Out-Null",
        ],
      );
      expect(linkResult.exitCode, equals(0), reason: linkResult.stderr.toString());
    } else {
      final linkResult = await Process.run('ln', [victim.path, partial.path]);
      expect(linkResult.exitCode, equals(0), reason: linkResult.stderr.toString());
    }

    final payload = utf8.encode('brand-new-download-payload-for-b4-test');
    final url = await bindServer((request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = payload.length
        ..add(payload)
        ..close();
    });

    final downloads = HttpBackgroundDownloads(clientFactory: testClient);
    await downloads.enqueue(
      DownloadArtifactRequest(
        artifactId: 'b4-hardlink',
        source: url,
        destinationPath: destination.path,
        expectedBytes: payload.length,
      ),
    );

    final terminal = await waitForTerminal(downloads, 'b4-hardlink');
    expect(terminal.status, DownloadStatus.completed);
    expect(await _readFileString(victim.path), equals('unchanged-victim-bytes'));
    expect(await _readFileBytes(destination.path), equals(payload));
  });

  test('N1 dangling partial.work symlink is not followed during download', () async {
    final payload = utf8.encode('n1-exclusive-partial-write-test-payload');
    final destination = File('${tempDir.path}/n1.bin');
    final outsideDir = await Directory.systemTemp.createTemp('n1-outside-');
    final outsideTarget = '${outsideDir.path}/outside_target';
    final workLinkPath = '${destination.path}.partial.work';
    await Link(workLinkPath).create(outsideTarget);

    final url = await bindServer((request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = payload.length
        ..add(payload)
        ..close();
    });

    final downloads = HttpBackgroundDownloads(clientFactory: testClient);
    await downloads.enqueue(
      DownloadArtifactRequest(
        artifactId: 'n1-work-symlink',
        source: url,
        destinationPath: destination.path,
        expectedBytes: payload.length,
      ),
    );

    await downloads.events.firstWhere(
      (event) =>
          event.artifactId == 'n1-work-symlink' &&
          event.status == DownloadStatus.downloading,
    );
    expect(
      FileSystemEntity.typeSync(workLinkPath, followLinks: false),
      isNot(FileSystemEntityType.link),
    );

    final terminal = await waitForTerminal(downloads, 'n1-work-symlink');
    expect(terminal.status, DownloadStatus.completed);
    expect(
      FileSystemEntity.typeSync(destination.path, followLinks: false),
      FileSystemEntityType.file,
    );
    expect(await _readFileBytes(destination.path), equals(payload));
    expect(File(outsideTarget).existsSync(), isFalse);
    await outsideDir.delete(recursive: true);
  });

  test('N2 cancel mid-stream resumes with Range on re-enqueue', () async {
    final totalSize = 100000;
    final payload = List<int>.generate(totalSize, (index) => index % 251);
    final destination = File('${tempDir.path}/resume-interrupted.bin');
    final requestLog = <String?>[];

    var requestCount = 0;
    final url = await bindServer((request) async {
      requestCount += 1;
      requestLog.add(request.headers.value(HttpHeaders.rangeHeader));
      request.response.headers.set(HttpHeaders.etagHeader, '"stream-v1"');
      if (requestCount == 1) {
        expect(request.headers.value(HttpHeaders.rangeHeader), isNull);
        request.response
          ..statusCode = HttpStatus.ok
          ..contentLength = totalSize
          ..add(payload.sublist(0, 60000));
        await request.response.flush();
        return;
      }
      expect(
        request.headers.value(HttpHeaders.rangeHeader),
        equals('bytes=60000-'),
      );
      expect(
        request.headers.value(HttpHeaders.ifRangeHeader),
        equals('"stream-v1"'),
      );
      final remainder = payload.sublist(60000);
      request.response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 60000-${totalSize - 1}/$totalSize',
        )
        ..contentLength = remainder.length
        ..add(remainder)
        ..close();
    });

    final downloads = HttpBackgroundDownloads(clientFactory: testClient);
    await downloads.enqueue(
      DownloadArtifactRequest(
        artifactId: 'n2-interrupted',
        source: url,
        destinationPath: destination.path,
        expectedBytes: totalSize,
        expectedSha256: sha256Hex(payload),
      ),
    );

    await downloads.events.firstWhere(
      (event) =>
          event.artifactId == 'n2-interrupted' &&
          event.downloadedBytes >= 60000,
    );
    await downloads.cancel('n2-interrupted');
    await _dumpN2CancelDiagnostics(destination.path);

    await downloads.enqueue(
      DownloadArtifactRequest(
        artifactId: 'n2-interrupted',
        source: url,
        destinationPath: destination.path,
        expectedBytes: totalSize,
        expectedSha256: sha256Hex(payload),
      ),
    );

    final terminal = await waitForTerminal(downloads, 'n2-interrupted');
    expect(terminal.status, DownloadStatus.completed);
    expect(await _readFileBytes(destination.path), equals(payload));
    expect(requestCount, equals(2));
    expect(requestLog[1], equals('bytes=60000-'));
  });

  test('N3 directory fsync failure fails closed and keeps destination', () async {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    final payload = utf8.encode('n3-dir-fsync-payload');
    final destination = File('${tempDir.path}/dest-n3b.bin');
    await destination.writeAsString('prior');

    final url = await bindServer((request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = payload.length
        ..add(payload)
        ..close();
    });

    final downloads = HttpBackgroundDownloads(
      clientFactory: testClient,
      partialFileIo: PosixPartialFileIo(syscalls: _FsyncFailSyscalls()),
    );

    await downloads.enqueue(
      DownloadArtifactRequest(
        artifactId: 'n3-dir-fsync',
        source: url,
        destinationPath: destination.path,
        expectedBytes: payload.length,
      ),
    );

    final terminal = await waitForTerminal(downloads, 'n3-dir-fsync');
    expect(terminal.status, DownloadStatus.failed);
    expect(await _readFileString(destination.path), equals('prior'));
  });

  test('N4 symlinked partial entry is unlinked before streaming', () async {
    final victim = File('${tempDir.path}/victim-prefix.bin');
    await victim.writeAsBytes(List<int>.filled(32, 7));
    final destination = File('${tempDir.path}/dest-n4.bin');
    final partial = File('${destination.path}.partial');
    await Link(partial.path).create(victim.path);

    final payload = utf8.encode('n4-full-payload-not-prefix-bytes');
    final url = await bindServer((request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = payload.length
        ..add(payload)
        ..close();
    });

    final downloads = HttpBackgroundDownloads(clientFactory: testClient);
    await downloads.enqueue(
      DownloadArtifactRequest(
        artifactId: 'n4-symlink-unlink',
        source: url,
        destinationPath: destination.path,
        expectedBytes: payload.length,
      ),
    );

    await downloads.events.firstWhere(
      (event) =>
          event.artifactId == 'n4-symlink-unlink' &&
          event.downloadedBytes > 0,
    );
    expect(
      FileSystemEntity.typeSync(partial.path, followLinks: false),
      isNot(FileSystemEntityType.link),
    );
    expect(await victim.length(), equals(32));

    final terminal = await waitForTerminal(downloads, 'n4-symlink-unlink');
    expect(terminal.status, DownloadStatus.completed);
    expect(await victim.length(), equals(32));
    expect(await _readFileBytes(destination.path), equals(payload));
  });

  test('B5 symlinked partial does not append through to victim', () async {
    final victim = File('${tempDir.path}/victim4.bin');
    await victim.writeAsBytes(utf8.encode('victim-original'));
    final destination = File('${tempDir.path}/dest5.bin');
    final partial = File('${destination.path}.partial');
    await Link(partial.path).create(victim.path);

    final payload = utf8.encode('symlink-safe-download-payload-b5');
    final url = await bindServer((request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = payload.length
        ..add(payload)
        ..close();
    });

    final downloads = HttpBackgroundDownloads(clientFactory: testClient);
    await downloads.enqueue(
      DownloadArtifactRequest(
        artifactId: 'b5-symlink',
        source: url,
        destinationPath: destination.path,
        expectedBytes: payload.length,
      ),
    );

    final firstProgress = await downloads.events
        .firstWhere(
          (event) =>
              event.artifactId == 'b5-symlink' &&
              (event.downloadedBytes > 0 ||
                  event.status == DownloadStatus.completed ||
                  event.status == DownloadStatus.failed),
        )
        .timeout(
          Platform.isMacOS
              ? const Duration(minutes: 2)
              : const Duration(seconds: 30),
        );
    expect(firstProgress.status, isNot(DownloadStatus.failed));
    expect(
      FileSystemEntity.typeSync(partial.path, followLinks: false),
      isNot(FileSystemEntityType.link),
    );
    expect(await _readFileString(victim.path), equals('victim-original'));

    final terminal = await waitForTerminal(downloads, 'b5-symlink');
    expect(terminal.status, DownloadStatus.completed);
    expect(await _readFileString(victim.path), equals('victim-original'));
    expect(
      FileSystemEntity.typeSync(destination.path, followLinks: false),
      FileSystemEntityType.file,
    );
    expect(await _readFileBytes(destination.path), equals(payload));
  });

  test('B6 commit leaves foreign destination.old untouched', () async {
    final payload = utf8.encode('replacement-payload-b6');
    final destination = File('${tempDir.path}/model.bin');
    await destination.writeAsString('previous-version');
    final foreignOld = File('${destination.path}.old');
    await foreignOld.writeAsString('foreign-old-must-survive');

    final url = await bindServer((request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = payload.length
        ..add(payload)
        ..close();
    });

    final downloads = HttpBackgroundDownloads(clientFactory: testClient);
    await downloads.enqueue(
      DownloadArtifactRequest(
        artifactId: 'b6-old-file',
        source: url,
        destinationPath: destination.path,
        expectedBytes: payload.length,
      ),
    );

    final terminal = await waitForTerminal(downloads, 'b6-old-file');
    expect(terminal.status, DownloadStatus.completed);
    expect(await _readFileString(foreignOld.path), equals('foreign-old-must-survive'));
    expect(await _readFileBytes(destination.path), equals(payload));
  });

  test('B7 sync failure before rename keeps prior destination', () async {
    final payload = utf8.encode('fsync-guard-payload-b7');
    final destination = File('${tempDir.path}/model.bin');
    await destination.writeAsString('keep-me');

    final url = await bindServer((request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = payload.length
        ..add(payload)
        ..close();
    });

    final downloads = HttpBackgroundDownloads(
      clientFactory: testClient,
      partialFileIo: _ThrowingSyncPartialFileIo(PartialFileIo()),
    );

    await downloads.enqueue(
      DownloadArtifactRequest(
        artifactId: 'b7-fsync',
        source: url,
        destinationPath: destination.path,
        expectedBytes: payload.length,
      ),
    );

    final terminal = await waitForTerminal(downloads, 'b7-fsync');
    expect(terminal.status, DownloadStatus.failed);
    expect(await _readFileString(destination.path), equals('keep-me'));
    expect(File('${destination.path}.partial').existsSync(), isTrue);
  });
}

class _FsyncFailSyscalls implements PosixSyscalls {
  @override
  int openDirectory(String path, int flags) => 42;

  @override
  int fsync(int fd) => -1;

  @override
  int close(int fd) => 0;
}

class _ThrowingSyncPartialFileIo implements PartialFileIo {
  _ThrowingSyncPartialFileIo(this._delegate);

  final PartialFileIo _delegate;
  var _partialSyncCount = 0;

  @override
  PartialPathInspection inspectPath(String path) =>
      _delegate.inspectPath(path);

  @override
  PartialPathSafety classifyPartialPath(String path) =>
      _delegate.classifyPartialPath(path);

  @override
  void unlinkPartialEntry(String path) => _delegate.unlinkPartialEntry(path);

  @override
  void prepareDestinationForCommit(String destinationPath) =>
      _delegate.prepareDestinationForCommit(destinationPath);

  @override
  Future<void> syncFile(String path) async {
    if (path.endsWith('.partial')) {
      _partialSyncCount += 1;
      if (_partialSyncCount >= 2) {
        throw StateError('simulated fsync failure');
      }
    }
    return _delegate.syncFile(path);
  }

  @override
  Future<void> syncDirectory(String directoryPath) =>
      _delegate.syncDirectory(directoryPath);

  @override
  Future<PartialFileWriter> openVerifiedPartialWriter(
    String path, {
    required bool append,
    expectedIdentity,
  }) =>
      _delegate.openVerifiedPartialWriter(
        path,
        append: append,
        expectedIdentity: expectedIdentity,
      );
}
