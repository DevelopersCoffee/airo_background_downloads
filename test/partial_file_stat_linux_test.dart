import 'dart:io';

import 'package:airo_background_downloads/src/http/partial_file_stat.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('platformLstat reports nlink=2 for hardlinks on Linux', () async {
    if (!Platform.isLinux) return;
    final dir = await Directory.systemTemp.createTemp('stat-nlink-');
    addTearDown(() => dir.delete(recursive: true));
    final a = File('${dir.path}/a');
    final b = File('${dir.path}/b');
    await a.writeAsString('x');
    final ln = await Process.run('ln', [a.path, b.path]);
    expect(ln.exitCode, equals(0));
    final stat = platformLstat(a.path);
    expect(stat, isNotNull);
    expect(stat!.linkCount, equals(2));
  });
}
