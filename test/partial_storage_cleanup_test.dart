import 'dart:convert';
import 'dart:io';

import 'package:airo_background_downloads/airo_background_downloads.dart';
import 'package:airo_background_downloads/src/http/download_directory_guard.dart';
import 'package:airo_background_downloads/src/http/partial_storage_cleanup.dart';
import 'package:airo_background_downloads/src/http/partial_storage_paths.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late SecurityContext serverContext;
  late Directory tempDir;

  setUpAll(() async {
    final certDir = await Directory.systemTemp.createTemp('airo-cleanup-certs-');
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
    tempDir = await Directory.systemTemp.createTemp('partial-cleanup-');
  });

  tearDown(() async {
    removeEmptyPartialStorageOverrideForTest = null;
    await tempDir.delete(recursive: true);
  });

  HttpClient testClient() =>
      HttpClient(context: SecurityContext())
        ..badCertificateCallback = (cert, host, port) => true;

  test('terminal failed event is emitted when empty-dir cleanup throws', () async {
    removeEmptyPartialStorageOverrideForTest = (_) {
      throw FileSystemException('simulated AV lock on rmdir');
    };

    final destination = File('${tempDir.path}/fail-cleanup.bin');
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      serverContext,
    );
    addTearDown(() async => server.close(force: true));
    server.listen((request) async {
      request.response
        ..statusCode = HttpStatus.found
        ..close();
    });

    final downloads = HttpBackgroundDownloads(clientFactory: testClient);
    await downloads.enqueue(
      DownloadArtifactRequest(
        artifactId: 'cleanup-on-fail',
        source: Uri.parse(
          'https://${server.address.host}:${server.port}/no-location',
        ),
        destinationPath: destination.path,
      ),
    );

    final terminal = await downloads.events.firstWhere(
      (e) =>
          e.artifactId == 'cleanup-on-fail' &&
          (e.status == DownloadStatus.completed ||
              e.status == DownloadStatus.failed),
    );
    expect(terminal.status, DownloadStatus.failed);
    expect(terminal.failure?.message, contains('redirect without Location'));
  });

  test('terminal completed event is emitted when empty-dir cleanup throws', () async {
    removeEmptyPartialStorageOverrideForTest = (_) {
      throw FileSystemException('simulated AV lock on rmdir');
    };

    final payload = utf8.encode('ok-payload');
    final destination = File('${tempDir.path}/ok-cleanup.bin');
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      serverContext,
    );
    addTearDown(() async => server.close(force: true));
    server.listen((request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = payload.length
        ..add(payload)
        ..close();
    });

    final downloads = HttpBackgroundDownloads(clientFactory: testClient);
    await downloads.enqueue(
      DownloadArtifactRequest(
        artifactId: 'cleanup-on-success',
        source: Uri.parse(
          'https://${server.address.host}:${server.port}/file',
        ),
        destinationPath: destination.path,
        expectedBytes: payload.length,
      ),
    );

    final terminal = await downloads.events.firstWhere(
      (e) =>
          e.artifactId == 'cleanup-on-success' &&
          (e.status == DownloadStatus.completed ||
              e.status == DownloadStatus.failed),
    );
    expect(terminal.status, DownloadStatus.completed);
    expect(await destination.readAsBytes(), equals(payload));
  });

  test('ensurePrivatePartialStorage tolerates empty-dir removal race', () {
    if (!Platform.isLinux && !Platform.isMacOS) return;

    final destPath = '${tempDir.path}/race/model.bin';
    ensurePrivatePartialStorage(destPath);
    final storage =
        PartialStoragePaths.forDestination(destPath).storageDirectory;

    tryRemoveEmptyPartialStorageDirectory(destPath);
    ensurePrivatePartialStorage(destPath);
    expect(Directory(storage).existsSync(), isTrue);

    tryRemoveEmptyPartialStorageDirectory(destPath);
    ensurePrivatePartialStorage('${tempDir.path}/race/other-model.bin');
    expect(Directory(storage).existsSync(), isTrue);
  });
}
