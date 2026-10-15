import 'dart:convert';
import 'dart:io';

import 'package:airo_background_downloads/airo_background_downloads.dart';
import 'package:airo_background_downloads/src/http/partial_file_identity.dart';
import 'package:airo_background_downloads/src/http/partial_file_io.dart';
import 'package:airo_background_downloads/src/http/partial_file_writer_posix.dart';
import 'package:airo_background_downloads/src/http/partial_path_guard.dart';
import 'package:airo_background_downloads/src/http/partial_file_stat.dart';
import 'package:airo_background_downloads/src/http/resume_validator_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late SecurityContext serverContext;

  setUpAll(() async {
    final certDir = await Directory.systemTemp.createTemp('k2-certs-');
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

  test('K2 nlink>1 partial is not safe and is rejected for append', () {
    final io = _FakePartialFileIo(
      linkCount: 2,
      ownerUid: platformCurrentUserId(),
    );
    final inspection = io.inspectPath('/tmp/x.partial');
    expect(inspection.isSafeRegularFileOwnedByUs, isFalse);
    expect(
      PartialPathGuard(io).reusablePartialBytes('/tmp/x.partial'),
      equals(0),
    );
  });

  test('K2 foreign owner partial is not safe', () {
    final io = _FakePartialFileIo(
      linkCount: 1,
      ownerUid: platformCurrentUserId() + 1,
    );
    expect(
      io.inspectPath('/tmp/x.partial').isSafeRegularFileOwnedByUs,
      isFalse,
    );
  });

  test('K2 POSIX syncDirectory on missing directory throws', () async {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    final io = PartialFileIo();
    await expectLater(
      io.syncDirectory(
        '/tmp/airo-missing-dir-${DateTime.now().microsecondsSinceEpoch}',
      ),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('K2 download size cap rejects oversized body', () async {
    final url = await bindServer((request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = 32
        ..add(List<int>.filled(32, 1))
        ..close();
    });
    final dest = File(
      '${Directory.systemTemp.path}/cap-${DateTime.now().microsecondsSinceEpoch}.bin',
    );
    final downloads = HttpBackgroundDownloads(
      clientFactory: testClient,
      maxDownloadBytes: 16,
    );
    await downloads.enqueue(
      DownloadArtifactRequest(
        artifactId: 'cap-test',
        source: url,
        destinationPath: dest.path,
      ),
    );
    final terminal = await downloads.events.firstWhere(
      (e) => e.artifactId == 'cap-test' && e.status == DownloadStatus.failed,
    );
    expect(terminal.status, DownloadStatus.failed);
  });

  test('K2 mismatched meta identity blocks resume validator reuse', () async {
    final dir = await Directory.systemTemp.createTemp('meta-id-');
    addTearDown(() => dir.delete(recursive: true));
    final partialPath = '${dir.path}/f.partial';
    final partial = File(partialPath);
    await partial.writeAsBytes([1, 2, 3, 4]);
    final meta = File('$partialPath.meta');
    await meta.writeAsString(
      jsonEncode({
        'source': 'https://wrong.example/file',
        'expectedBytes': 100,
        'etag': '"good"',
      }),
    );
    final store = ResumeValidatorStore(partialPath);
    final hasValidator = await store.hasValidatorFor(
      DownloadArtifactRequest(
        artifactId: 'x',
        source: Uri.parse('https://correct.example/file'),
        destinationPath: '${dir.path}/dest',
        expectedBytes: 100,
      ),
    );
    expect(hasValidator, isFalse);
  });

  test('K2 exclusive partial create uses verified writer', () async {
    final dir = await Directory.systemTemp.createTemp('exclusive-');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/fresh.partial';
    final io = PartialFileIo();
    final guard = PartialPathGuard(io);
    await guard.createExclusiveEmptyFile(path);
    expect(File(path).existsSync(), isTrue);
    expect(
      FileSystemEntity.typeSync(path, followLinks: false),
      FileSystemEntityType.file,
    );
  });

  test('K2 O_NOFOLLOW exclusive open refuses symlink partial target', () async {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    final dir = await Directory.systemTemp.createTemp('excl-symlink-');
    addTearDown(() => dir.delete(recursive: true));
    final victim = File('${dir.path}/victim.txt');
    await victim.writeAsString('untouched');
    final partialPath = '${dir.path}/dl.partial';
    await Link(partialPath).create(victim.path);
    expect(
      () => PosixPartialFileWriter.open(
        partialPath,
        append: false,
        currentUid: platformCurrentUserId(),
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(await victim.readAsString(), equals('untouched'));
  });

  test('K2 pre-commit refuses symlink partial', () {
    final io = _FakePartialFileIo(
      linkCount: null,
      ownerUid: platformCurrentUserId(),
      symlink: true,
    );
    expect(
      () => PartialPathGuard(io).requireSafeRegularPartialBeforeCommit('/x'),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('K2 connection timeout fails unreachable host quickly', () async {
    final dest = File(
      '${Directory.systemTemp.path}/timeout-${DateTime.now().microsecondsSinceEpoch}.bin',
    );
    final downloads = HttpBackgroundDownloads(
      clientFactory: testClient,
      connectionTimeout: const Duration(milliseconds: 200),
    );
    await downloads.enqueue(
      DownloadArtifactRequest(
        artifactId: 'conn-timeout',
        source: Uri.parse('https://192.0.2.1:9/'),
        destinationPath: dest.path,
        expectedBytes: 8,
      ),
    );
    final terminal = await downloads.events.firstWhere(
      (e) =>
          e.artifactId == 'conn-timeout' &&
          (e.status == DownloadStatus.failed ||
              e.status == DownloadStatus.completed),
    );
    expect(terminal.status, DownloadStatus.failed);
  });

}

class _FakePartialFileIo implements PartialFileIo {
  _FakePartialFileIo({
    required this.linkCount,
    required this.ownerUid,
    this.symlink = false,
  });

  final int? linkCount;
  final int ownerUid;
  final bool symlink;

  @override
  PartialPathInspection inspectPath(String path) {
    if (symlink) {
      return const PartialPathInspection(
        isAbsent: false,
        isSymlink: true,
        isRegularFile: false,
        linkCount: null,
        ownedByUs: false,
      );
    }
    final identity = linkCount == null
        ? null
        : PartialFileIdentity(
            deviceId: 1,
            inode: 2,
            linkCount: linkCount!,
            ownerUid: ownerUid,
          );
    return PartialPathInspection(
      isAbsent: false,
      isSymlink: false,
      isRegularFile: true,
      linkCount: linkCount,
      ownedByUs: ownerUid == platformCurrentUserId(),
      identity: identity,
    );
  }

  @override
  PartialPathSafety classifyPartialPath(String path) {
    final i = inspectPath(path);
    if (i.isSafeRegularFileOwnedByUs) {
      return const PartialPathSafety(mayAppend: true, shouldUnlinkEntry: false);
    }
    return const PartialPathSafety(mayAppend: false, shouldUnlinkEntry: true);
  }

  @override
  void unlinkPartialEntry(String path) {}

  @override
  void prepareDestinationForCommit(String destinationPath) {}

  @override
  Future<void> syncFile(String path) async {}

  @override
  Future<void> syncDirectory(String directoryPath) async {}

  @override
  Future<PartialFileWriter> openVerifiedPartialWriter(
    String path, {
    required bool append,
    PartialFileIdentity? expectedIdentity,
  }) async {
    throw UnimplementedError();
  }
}
