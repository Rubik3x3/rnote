import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rnote_mobile/sync/sync_service.dart';
import 'package:rnote_mobile/sync/webdav_client.dart';

void main() {
  late Directory tmp, local, remote;
  late Process server;
  late String url;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('rnote_sync');
    local = await Directory('${tmp.path}/local').create();
    remote = await Directory('${tmp.path}/remote').create();
    final port = 18000 + DateTime.now().millisecond;
    server = await Process.start('python3', ['-u',
      'tools/rnote_sync_server.py', remote.path, '--port', '$port', '--bind', '127.0.0.1',
      '--user', 'yo', '--password', 'clave ñ',
    ]);
    final ready = Completer<void>();
    server.stdout.transform(utf8.decoder).listen((l) {
      if (l.contains('URL') && !ready.isCompleted) ready.complete();
    });
    server.stderr.listen((_) {});
    await ready.future.timeout(const Duration(seconds: 10));
    url = 'http://127.0.0.1:$port/Notas';
  });

  tearDownAll(() async {
    server.kill();
    await tmp.delete(recursive: true);
  });

  SyncService service({String password = 'clave ñ'}) => SyncService(
        localDir: local,
        stateFile: File('${tmp.path}/state.json'),
        client: WebDavClient(url, user: 'yo', password: password),
      );

  Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));
  Set<String> names(Directory d) => d
      .listSync()
      .whereType<File>()
      .map((f) => f.uri.pathSegments.last)
      .where((n) => n.endsWith('.rnote'))
      .toSet();

  test('wrong password is reported', () async {
    expect(() => service(password: 'mal').sync(), throwsA(isA<WebDavException>()));
  });

  test('two way sync', () async {
    final remoteNotes = Directory('${remote.path}/Notas');
    File('${local.path}/a.rnote').writeAsBytesSync(bytes('local a'));
    // first sync creates the remote folder and uploads
    var r = await service().sync();
    expect(r.uploaded, 1, reason: r.errors.join());
    expect(names(remoteNotes), {'a.rnote'});

    // a file created on the PC is downloaded
    File('${remoteNotes.path}/b.rnote').writeAsBytesSync(bytes('pc b'));
    r = await service().sync();
    expect(r.downloaded, 1);
    expect(File('${local.path}/b.rnote').readAsStringSync(), 'pc b');

    // nothing changed
    r = await service().sync();
    expect(r.changedAnything, isFalse, reason: r.toString());

    // local change is uploaded
    await Future<void>.delayed(const Duration(milliseconds: 20));
    File('${local.path}/a.rnote').writeAsBytesSync(bytes('local a v2'));
    r = await service().sync();
    expect(r.uploaded, 1);
    expect(File('${remoteNotes.path}/a.rnote').readAsStringSync(), 'local a v2');

    // remote change is downloaded
    await Future<void>.delayed(const Duration(milliseconds: 20));
    File('${remoteNotes.path}/b.rnote').writeAsBytesSync(bytes('pc b v2!'));
    r = await service().sync();
    expect(r.downloaded, 1);
    expect(File('${local.path}/b.rnote').readAsStringSync(), 'pc b v2!');

    // conflict: both versions are kept
    await Future<void>.delayed(const Duration(milliseconds: 20));
    File('${local.path}/a.rnote').writeAsBytesSync(bytes('local a v3'));
    File('${remoteNotes.path}/a.rnote').writeAsBytesSync(bytes('pc a v3 !!'));
    r = await service().sync();
    expect(r.conflicts, 1);
    expect(File('${local.path}/a.rnote').readAsStringSync(), 'pc a v3 !!');
    expect(names(local).length, 3);
    expect(names(remoteNotes).length, 3);

    // deletions propagate
    File('${local.path}/b.rnote').deleteSync();
    r = await service().sync();
    expect(r.deletedRemote, 1);
    expect(names(remoteNotes).contains('b.rnote'), isFalse);
    File('${remoteNotes.path}/a.rnote').deleteSync();
    r = await service().sync();
    expect(r.deletedLocal, 1);
    expect(names(local).contains('a.rnote'), isFalse);

    r = await service().sync();
    expect(r.changedAnything, isFalse, reason: r.toString());
  });
}
