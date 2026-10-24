import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:airo_background_downloads/airo_background_downloads.dart';
import 'package:airo_background_downloads/src/http/download_directory_guard.dart';
import 'package:airo_background_downloads/src/http/partial_storage_cleanup.dart';
import 'package:airo_background_downloads/src/http/partial_storage_lease.dart';
import 'package:airo_background_downloads/src/http/partial_storage_paths.dart';
import 'package:airo_background_downloads/src/http/posix_variadic.dart';
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
    resetPartialStorageLeasesForTest();
    posixMkdirOverrideForTest = null;
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

  test('ensurePrivatePartialStorage retries mkdir after a lost create race', () {
    if (!Platform.isLinux && !Platform.isMacOS) return;

    final destPath = '${tempDir.path}/mkdir-race/model.bin';
    final storage =
        PartialStoragePaths.forDestination(destPath).storageDirectory;
    var mkdirCalls = 0;
    posixMkdirOverrideForTest = (path, mode) {
      mkdirCalls++;
      if (mkdirCalls == 1) {
        return 1;
      }
      posixMkdirOverrideForTest = null;
      return posixMkdir(path, mode);
    };

    ensurePrivatePartialStorage(destPath);
    expect(mkdirCalls, greaterThanOrEqualTo(2));
    expect(Directory(storage).existsSync(), isTrue);
  });

  test(
    'failed sibling keeps shared partial storage while another job is mid-request',
    () async {
      final payload = utf8.encode('sibling-b-payload');
      final destB = File('${tempDir.path}/sibling-dir/b.bin');
      final destA = File('${tempDir.path}/sibling-dir/a.bin');
      final storage =
          PartialStoragePaths.forDestination(destB.path).storageDirectory;

      final bBlockedBeforeOpen = Completer<void>();
      final bReachedPreOpen = Completer<void>();

      final serverB = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        serverContext,
      );
      addTearDown(() async => serverB.close(force: true));
      serverB.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..contentLength = payload.length
          ..add(payload)
          ..close();
      });

      final serverA = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        serverContext,
      );
      addTearDown(() async => serverA.close(force: true));
      serverA.listen((request) async {
        request.response
          ..statusCode = HttpStatus.found
          ..close();
      });

      final downloads = HttpBackgroundDownloads(clientFactory: testClient)
        ..beforeOpenPartialWriterForTest = (artifactId) async {
          if (artifactId != 'job-b') return;
          bReachedPreOpen.complete();
          await bBlockedBeforeOpen.future;
        };

      await downloads.enqueue(
        DownloadArtifactRequest(
          artifactId: 'job-b',
          source: Uri.parse(
            'https://${serverB.address.host}:${serverB.port}/b',
          ),
          destinationPath: destB.path,
          expectedBytes: payload.length,
        ),
      );

      await bReachedPreOpen.future;
      expect(partialStorageLeaseCountForDestination(destB.path), 1);

      await downloads.enqueue(
        DownloadArtifactRequest(
          artifactId: 'job-a',
          source: Uri.parse(
            'https://${serverA.address.host}:${serverA.port}/a',
          ),
          destinationPath: destA.path,
        ),
      );

      final aTerminal = await downloads.events.firstWhere(
        (e) =>
            e.artifactId == 'job-a' &&
            (e.status == DownloadStatus.completed ||
                e.status == DownloadStatus.failed),
      );
      expect(aTerminal.status, DownloadStatus.failed);
      expect(Directory(storage).existsSync(), isTrue);

      if (!bBlockedBeforeOpen.isCompleted) {
        bBlockedBeforeOpen.complete();
      }

      final bTerminal = await downloads.events.firstWhere(
        (e) =>
            e.artifactId == 'job-b' &&
            (e.status == DownloadStatus.completed ||
                e.status == DownloadStatus.failed),
      );
      expect(bTerminal.status, DownloadStatus.completed);
      expect(await destB.readAsBytes(), equals(payload));
    },
  );

  test(
    'sibling completes after shared partial storage removed mid-request',
    () async {
      final payload = utf8.encode('sibling-recover-payload');
      final destB = File('${tempDir.path}/recover-dir/b.bin');
      final storage =
          PartialStoragePaths.forDestination(destB.path).storageDirectory;

      final bBlockedBeforeOpen = Completer<void>();
      final bReachedPreOpen = Completer<void>();

      final serverB = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        serverContext,
      );
      addTearDown(() async => serverB.close(force: true));
      serverB.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..contentLength = payload.length
          ..add(payload)
          ..close();
      });

      final downloads = HttpBackgroundDownloads(clientFactory: testClient)
        ..beforeOpenPartialWriterForTest = (artifactId) async {
          if (artifactId != 'job-b') return;
          bReachedPreOpen.complete();
          await bBlockedBeforeOpen.future;
        };

      await downloads.enqueue(
        DownloadArtifactRequest(
          artifactId: 'job-b',
          source: Uri.parse(
            'https://${serverB.address.host}:${serverB.port}/b',
          ),
          destinationPath: destB.path,
          expectedBytes: payload.length,
        ),
      );

      await bReachedPreOpen.future;
      tryRemoveEmptyPartialStorageDirectory(destB.path);
      expect(Directory(storage).existsSync(), isFalse);

      bBlockedBeforeOpen.complete();

      final bTerminal = await downloads.events.firstWhere(
        (e) =>
            e.artifactId == 'job-b' &&
            (e.status == DownloadStatus.completed ||
                e.status == DownloadStatus.failed),
      );
      expect(bTerminal.status, DownloadStatus.completed);
      expect(await destB.readAsBytes(), equals(payload));
    },
  );
}
