import 'dart:io';

import 'package:airo_background_downloads/airo_background_downloads.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late SecurityContext serverContext;
  late Directory tempDir;

  setUpAll(() async {
    final certDir = await Directory.systemTemp.createTemp('airo-stall-certs-');
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
    tempDir = await Directory.systemTemp.createTemp('http-stall-');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('stalled server fails with idle read timeout', () async {
    final destination = File('${tempDir.path}/stall.bin');
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      serverContext,
    );
    addTearDown(() async => server.close(force: true));
    server.listen((request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = 1000
        ..headers.set(HttpHeaders.etagHeader, '"stall"')
        ..add([0x01]);
      await request.response.flush();
      await Future<void>.delayed(const Duration(hours: 1));
      await request.response.close();
    });
    final url = Uri.parse(
      'https://${server.address.host}:${server.port}/stall',
    );

    final downloads = HttpBackgroundDownloads(
      clientFactory: () =>
          HttpClient(context: SecurityContext())
            ..badCertificateCallback = (_, _, _) => true,
      idleReadTimeout: const Duration(milliseconds: 300),
    );

    await downloads.enqueue(
      DownloadArtifactRequest(
        artifactId: 'stall',
        source: url,
        destinationPath: destination.path,
        expectedBytes: 1000,
      ),
    );

    final terminal = await downloads.events
        .where(
          (event) =>
              event.artifactId == 'stall' &&
              event.status == DownloadStatus.failed,
        )
        .first
        .timeout(const Duration(seconds: 5));

    final message = terminal.failure?.message ?? '';
    expect(
      message.contains('idle read timeout') ||
          message.contains('Incomplete HTTP body'),
      isTrue,
      reason: 'expected stall failure, got: $message',
    );
  });
}
