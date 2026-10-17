import 'dart:convert';
import 'dart:io';

import 'package:airo_background_downloads/airo_background_downloads.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'partial_test_paths.dart';

/// Pins the desktop [HttpBackgroundDownloads] behaviour for sources that
/// redirect to a CDN, such as Hugging Face `resolve/main` URLs. The README
/// section "Large files and resume" documents this behaviour.
void main() {
  late SecurityContext serverContext;
  late Directory tempDir;

  setUpAll(() async {
    final certDir = await Directory.systemTemp.createTemp(
      'airo-redirect-certs-',
    );
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
    tempDir = await Directory.systemTemp.createTemp('http-redirect-');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  HttpClient testClient() =>
      HttpClient(context: SecurityContext())
        ..badCertificateCallback = (cert, host, port) => true;

  test('fresh download follows a resolve -> CDN redirect', () async {
    final payload = utf8.encode('model-bytes-served-from-cdn');
    final destination = File('${tempDir.path}/model.gguf');
    final seen = <String>[];

    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      serverContext,
    );
    addTearDown(() async => server.close(force: true));
    final base = 'https://${server.address.host}:${server.port}';
    server.listen((request) async {
      seen.add(request.uri.path);
      if (request.uri.path == '/resolve/main/model.gguf') {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, '$base/cdn/model.gguf')
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
        artifactId: 'redirect-fresh',
        source: Uri.parse('$base/resolve/main/model.gguf'),
        destinationPath: destination.path,
        expectedBytes: payload.length,
        expectedSha256: sha256.convert(payload).toString(),
      ),
    );
    final terminal = await downloads.events.firstWhere(
      (e) =>
          e.artifactId == 'redirect-fresh' &&
          (e.status == DownloadStatus.completed ||
              e.status == DownloadStatus.failed),
    );

    expect(terminal.status, DownloadStatus.completed);
    expect(await destination.readAsBytes(), equals(payload));
    expect(seen, equals(['/resolve/main/model.gguf', '/cdn/model.gguf']));
  });

  test('resume through a redirect does not follow it with Range: '
      'partial is discarded and the download restarts from byte 0', () async {
    final payload = utf8.encode('model-bytes-served-from-cdn-on-resume');
    final destination = File('${tempDir.path}/model.gguf');
    preparePartialStorage(destination);
    await File(partialPathFor(destination)).writeAsBytes(payload.sublist(0, 7));

    final requests = <({String path, String? range})>[];
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      serverContext,
    );
    addTearDown(() async => server.close(force: true));
    final base = 'https://${server.address.host}:${server.port}';
    server.listen((request) async {
      requests.add((
        path: request.uri.path,
        range: request.headers.value(HttpHeaders.rangeHeader),
      ));
      if (request.uri.path == '/resolve/main/model.gguf') {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, '$base/cdn/model.gguf')
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
        artifactId: 'redirect-resume',
        source: Uri.parse('$base/resolve/main/model.gguf'),
        destinationPath: destination.path,
        expectedBytes: payload.length,
        expectedSha256: sha256.convert(payload).toString(),
      ),
    );
    final terminal = await downloads.events.firstWhere(
      (e) =>
          e.artifactId == 'redirect-resume' &&
          (e.status == DownloadStatus.completed ||
              e.status == DownloadStatus.failed),
    );

    expect(terminal.status, DownloadStatus.completed);
    expect(await destination.readAsBytes(), equals(payload));
    // First attempt sends Range to the resolve URL and gets 302, which the
    // desktop engine does not follow while resuming.
    expect(requests.first.path, '/resolve/main/model.gguf');
    expect(requests.first.range, 'bytes=7-');
    // The CDN is only reached without Range: the bytes already on disk
    // were thrown away and the whole file was fetched again.
    final cdn = requests.where((r) => r.path == '/cdn/model.gguf').toList();
    expect(cdn, hasLength(1));
    expect(cdn.single.range, isNull);
  });
}
