import 'dart:convert';
import 'dart:io';

import 'package:airo_background_downloads/airo_background_downloads.dart';
import 'package:airo_background_downloads/src/http/partial_file_identity.dart';
import 'package:airo_background_downloads/src/http/partial_file_stat.dart';
import 'package:airo_background_downloads/src/http/posix_variadic.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late SecurityContext serverContext;
  late Directory tempDir;

  setUpAll(() async {
    final certDir = await Directory.systemTemp.createTemp('airo-sec-certs-');
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
    tempDir = await Directory.systemTemp.createTemp('http-sec-');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  HttpClient testClient() =>
      HttpClient(context: SecurityContext())
        ..badCertificateCallback = (cert, host, port) => true;

  Future<DownloadProgress> waitTerminal(
    HttpBackgroundDownloads downloads,
    String artifactId,
  ) {
    return downloads.events.firstWhere(
      (e) =>
          e.artifactId == artifactId &&
          (e.status == DownloadStatus.completed ||
              e.status == DownloadStatus.failed),
    );
  }

  test('K2 HTTPS to HTTP redirect is refused and destination is not committed',
      () async {
    final plaintext = utf8.encode('downgrade-body-must-not-land');
    final destination = File('${tempDir.path}/downgrade.bin');

    final httpsServer = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      serverContext,
    );
    addTearDown(() async => httpsServer.close(force: true));

    final httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async => httpServer.close(force: true));

    httpServer.listen((request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = plaintext.length
        ..add(plaintext)
        ..close();
    });

    final httpTarget =
        'http://${httpServer.address.host}:${httpServer.port}/cdn';
    httpsServer.listen((request) async {
      request.response
        ..statusCode = HttpStatus.found
        ..headers.set(HttpHeaders.locationHeader, httpTarget)
        ..close();
    });

    final source = Uri.parse(
      'https://${httpsServer.address.host}:${httpsServer.port}/entry',
    );

    final downloads = HttpBackgroundDownloads(clientFactory: testClient);
    await downloads.enqueue(
      DownloadArtifactRequest(
        artifactId: 'https-downgrade',
        source: source,
        destinationPath: destination.path,
        expectedBytes: plaintext.length,
      ),
    );

    final terminal = await waitTerminal(downloads, 'https-downgrade');
    expect(terminal.status, DownloadStatus.failed);
    expect(destination.existsSync(), isFalse);
  });

  test('K2 cross-host HTTPS redirect never sends X-Api-Key to CDN', () async {
    final payload = utf8.encode('cdn-payload-for-header-test');
    final destination = File('${tempDir.path}/cdn.bin');
    String? cdnApiKey;

    final originServer = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      serverContext,
    );
    addTearDown(() async => originServer.close(force: true));

    final cdnServer = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      serverContext,
    );
    addTearDown(() async => cdnServer.close(force: true));

    final cdnBase = 'https://${cdnServer.address.host}:${cdnServer.port}';
    cdnServer.listen((request) async {
      cdnApiKey = request.headers.value('X-Api-Key');
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = payload.length
        ..add(payload)
        ..close();
    });

    final originBase =
        'https://${originServer.address.host}:${originServer.port}';
    originServer.listen((request) async {
      if (request.uri.path == '/resolve/file.bin') {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, '$cdnBase/file.bin')
          ..close();
        return;
      }
      request.response
        ..statusCode = HttpStatus.ok
        ..add(payload)
        ..close();
    });

    final downloads = HttpBackgroundDownloads(clientFactory: testClient);
    await downloads.enqueue(
      DownloadArtifactRequest(
        artifactId: 'header-leak',
        source: Uri.parse('$originBase/resolve/file.bin'),
        destinationPath: destination.path,
        expectedBytes: payload.length,
        expectedSha256: sha256.convert(payload).toString(),
        headers: const {'X-Api-Key': 'secret-token'},
      ),
    );

    final terminal = await waitTerminal(downloads, 'header-leak');
    expect(terminal.status, DownloadStatus.completed);
    expect(cdnApiKey, isNull);
    expect(await destination.readAsBytes(), equals(payload));
  });

  test('K2 swap before commit refuses attacker bytes despite SHA pin', () async {
    if (!Platform.isLinux && !Platform.isMacOS) return;

    final good = utf8.encode('verified-good-payload-for-commit');
    final bad = utf8.encode('attacker-replaced-after-verify');
    final destination = File('${tempDir.path}/swap-target.bin');
    final attackerFile = File('${tempDir.path}/attacker-swap.bin');
    await attackerFile.writeAsBytes(bad);

    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      serverContext,
    );
    addTearDown(() async => server.close(force: true));
    server.listen((request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = good.length
        ..add(good)
        ..close();
    });

    final source = Uri.parse(
      'https://${server.address.host}:${server.port}/good',
    );

    final downloads = HttpBackgroundDownloads(
      clientFactory: testClient,
      onBeforeCommitPartial: (partial, _) async {
        partial.deleteSync();
        await attackerFile.rename(partial.path);
      },
    );

    await downloads.enqueue(
      DownloadArtifactRequest(
        artifactId: 'swap-before-commit',
        source: source,
        destinationPath: destination.path,
        expectedBytes: good.length,
        expectedSha256: sha256.convert(good).toString(),
      ),
    );

    final terminal = await waitTerminal(downloads, 'swap-before-commit');
    expect(terminal.status, DownloadStatus.failed);
    expect(destination.existsSync(), isFalse);
    if (destination.existsSync()) {
      expect(await destination.readAsBytes(), isNot(equals(bad)));
    }
  });

  test('checked close keeps action error when close fails', () {
    if (!Platform.isLinux && !Platform.isMacOS) return;

    posixCloseOverrideForTest = (_) => -1;
    addTearDown(() => posixCloseOverrideForTest = null);

    final dir = Directory.systemTemp.createTempSync('close-err-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/t.bin')..writeAsBytesSync([1]);

    if (Platform.isMacOS) {
      darwinFullFsyncOverrideForTest = (_) => -1;
      addTearDown(() => darwinFullFsyncOverrideForTest = null);
      expect(
        () => posixSyncRegularFileViaFd(file.path),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.message,
            'message',
            'F_FULLFSYNC failed',
          ),
        ),
      );
      return;
    }

    final wrong = PartialFileIdentity(
      deviceId: 0,
      inode: 0,
      linkCount: 1,
      ownerUid: platformCurrentUserId(),
    );
    expect(
      () => posixSyncRegularFileViaFd(
        file.path,
        expectedIdentity: wrong,
      ),
      throwsA(
        isA<FileSystemException>().having(
          (e) => e.message,
          'message',
          'Partial file identity changed after reopen',
        ),
      ),
    );
  });

  test('checked close surfaces close failure when action succeeds', () {
    if (!Platform.isMacOS) return;

    posixCloseOverrideForTest = (_) => -1;
    addTearDown(() => posixCloseOverrideForTest = null);

    final dir = Directory.systemTemp.createTempSync('close-only-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/t.bin')..writeAsBytesSync([2]);

    expect(
      () => posixSyncRegularFileViaFd(file.path),
      throwsA(
        isA<FileSystemException>().having(
          (e) => e.message,
          'message',
          'close failed',
        ),
      ),
    );
  });

  test('posixCurrentUmask uses exclusive-create probe on macOS', () {
    if (!Platform.isMacOS) return;

    resetPosixUmaskCacheForTest();
    final read = posixCurrentUmask();
    expect(read, inInclusiveRange(0, 511));
    expect(posixUmaskLastReadUsedExclusiveProbe, isTrue);
  });
}
