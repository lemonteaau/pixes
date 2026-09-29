import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixes/appdata.dart';
import 'package:pixes/foundation/app.dart';
import 'package:pixes/foundation/cache_manager.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('pixes-cache-test');
    App.dataPath = '${root.path}/data';
    App.cachePath = '${root.path}/cache';
    Directory(App.dataPath).createSync(recursive: true);
    CacheManager.instance = null;
  });

  tearDown(() {
    CacheManager.instance = null;
    appdata.settings.remove('cacheSizeLimitGB');
    root.deleteSync(recursive: true);
  });

  Future<void> put(CacheManager cache, String key, int bytes) async {
    final file = await cache.openWrite(key);
    await file.writeBytes(List.filled(bytes, 1));
    await file.close();
  }

  test('removes the least recently viewed files once over the limit',
      () async {
    final cache = CacheManager();
    await cache.ready;
    cache.setLimitSize(1000);
    await put(cache, 'a', 300);
    await put(cache, 'b', 300);
    await put(cache, 'c', 300);
    expect(cache.currentSize, 900);

    // Viewing "a" again makes "b" the one not seen for the longest.
    await Future.delayed(const Duration(milliseconds: 5));
    expect(await cache.findCache('a'), isNotNull);
    await put(cache, 'd', 300);
    // Going over the limit starts trimming on its own.
    await Future.delayed(const Duration(milliseconds: 100));

    // Trimmed to 80% of the limit.
    expect(cache.currentSize, lessThanOrEqualTo(800));
    expect(await cache.findCache('b'), isNull);
    expect(await cache.findCache('a'), isNotNull);
    expect(await cache.findCache('d'), isNotNull);
  });

  test('the limit follows the setting, 5 GB by default', () async {
    final cache = CacheManager();
    expect(cache.limitSize, 5 * 1024 * 1024 * 1024);
    appdata.settings['cacheSizeLimitGB'] = 10;
    expect(cache.limitSize, 10 * 1024 * 1024 * 1024);
  });

  test('measures on startup and drops old files missing from the index',
      () async {
    final first = CacheManager();
    await first.ready;
    await put(first, 'kept', 100);
    final orphan = File('${CacheManager.cachePath}/7/orphan')
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(50, 1))
      ..setLastModifiedSync(DateTime.now().subtract(const Duration(days: 1)));
    final fresh = File('${CacheManager.cachePath}/7/being-written')
      ..writeAsBytesSync(List.filled(20, 1));

    CacheManager.instance = null;
    final second = CacheManager();
    await second.ready;
    expect(orphan.existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue);
    expect(second.currentSize, 120);
    expect(await second.findCache('kept'), isNotNull);
  });

  test('writing a key again replaces its old file', () async {
    final cache = CacheManager();
    await cache.ready;
    await put(cache, 'a', 100);
    final old = await cache.findCache('a');
    await put(cache, 'a', 40);
    expect(File(old!).existsSync(), isFalse);
    expect(cache.currentSize, 40);
  });

  test('upgrades an old index; its files are the first to go', () async {
    final db = sqlite3.open('${App.dataPath}/cache.db');
    db.execute('''
      CREATE TABLE cache (
        key TEXT PRIMARY KEY NOT NULL,
        dir TEXT NOT NULL,
        name TEXT NOT NULL,
        expires INTEGER NOT NULL
      )
    ''');
    db.execute("INSERT INTO cache VALUES ('old', '3', 'f', 0)");
    db.dispose();
    File('${CacheManager.cachePath}/3/f')
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(500, 1));

    final cache = CacheManager();
    await cache.ready;
    expect(cache.currentSize, 500);
    expect(await cache.findCache('old'), isNotNull);
    cache.setLimitSize(1000);
    await put(cache, 'new', 600);
    await Future.delayed(const Duration(milliseconds: 100));
    expect(await cache.findCache('new'), isNotNull);
    expect(cache.currentSize, 600);
  });

  test('clear empties the cache', () async {
    final cache = CacheManager();
    await cache.ready;
    await put(cache, 'a', 100);
    await cache.clear();
    expect(cache.currentSize, 0);
    expect(await cache.findCache('a'), isNull);
  });
}
