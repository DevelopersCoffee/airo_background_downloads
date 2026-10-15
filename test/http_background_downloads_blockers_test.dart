import 'dart:convert';
import 'dart:io';

import 'package:airo_background_downloads/airo_background_downloads.dart';
import 'package:airo_background_downloads/src/http/partial_file_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

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
    expect(await destination.readAsBytes(), equals(fullB));
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
    expect(await destination.readAsBytes(), equals(payload));
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
    expect(await destination.readAsBytes(), equals(payload));
    expect(requestCount, equals(2));
  });

  test('B4 hardlinked partial does not mutate the linked victim file', () async {
    final victim = File('${tempDir.path}/victim.bin');
    await victim.writeAsBytes(utf8.encode('unchanged-victim-bytes'));
    final destination = File('${tempDir.path}/out.bin');
    final partial = File('${destination.path}.partial');

    if (Platform.isWindows) {
      final linkResult = await Process.run(
        'cmd',
        ['/c', 'mklink /H', partial.path, victim.path],
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
    expect(await victim.readAsString(), equals('unchanged-victim-bytes'));
    expect(await destination.readAsBytes(), equals(payload));
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

    final terminal = await waitForTerminal(downloads, 'b5-symlink');
    expect(terminal.status, DownloadStatus.completed);
    expect(await victim.readAsString(), equals('victim-original'));
    expect(
      FileSystemEntity.typeSync(destination.path, followLinks: false),
      FileSystemEntityType.file,
    );
    expect(await destination.readAsBytes(), equals(payload));
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
    expect(await foreignOld.readAsString(), equals('foreign-old-must-survive'));
    expect(await destination.readAsBytes(), equals(payload));
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
    expect(await destination.readAsString(), equals('keep-me'));
    expect(File('${destination.path}.partial').existsSync(), isTrue);
  });
}

class _ThrowingSyncPartialFileIo implements PartialFileIo {
  _ThrowingSyncPartialFileIo(this._delegate);

  final PartialFileIo _delegate;

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
    if (path.endsWith('.partial') && !path.endsWith('.partial.work')) {
      throw StateError('simulated fsync failure');
    }
    return _delegate.syncFile(path);
  }

  @override
  Future<void> syncDirectory(String directoryPath) =>
      _delegate.syncDirectory(directoryPath);
}
