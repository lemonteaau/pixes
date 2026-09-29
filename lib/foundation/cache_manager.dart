import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:pixes/appdata.dart';
import 'package:pixes/foundation/log.dart';
import 'package:pixes/utils/io.dart';
import 'package:sqlite3/sqlite3.dart';

import 'app.dart';

/// The cache size limits offered in the settings, in gigabytes.
const cacheSizeLimitOptions = [1, 2, 5, 10, 20];

const _defaultCacheSizeLimitGB = 5;

const _gb = 1024 * 1024 * 1024;

/// A disk cache for images and other downloads. When it grows past the
/// limit set in the settings, the files viewed least recently are removed
/// until it is back to 80% of the limit.
class CacheManager {
  static String get cachePath => '${App.cachePath}/cache';

  static CacheManager? instance;

  late Database _db;

  int? _currentSize;

  /// size in bytes, or 0 until it has been measured
  int get currentSize => _currentSize ?? 0;

  /// Whether the size of the cache has been measured yet.
  bool get isSizeKnown => _currentSize != null;

  int dir = 0;

  int? _limitOverride;

  late final Future<void> ready;

  /// The limit in bytes.
  int get limitSize {
    if (_limitOverride != null) return _limitOverride!;
    final gb = appdata.settings['cacheSizeLimitGB'];
    return ((gb is num ? gb : _defaultCacheSizeLimitGB) * _gb).round();
  }

  CacheManager._create() {
    Directory(cachePath).createSync(recursive: true);
    _db = sqlite3.open('${App.dataPath}/cache.db');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS cache (
        key TEXT PRIMARY KEY NOT NULL,
        dir TEXT NOT NULL,
        name TEXT NOT NULL,
        expires INTEGER NOT NULL
      )
    ''');
    // Added later: the size of each file and when it was last used.
    final columns = _db
        .select('PRAGMA table_info(cache)')
        .map((row) => row['name'] as String)
        .toSet();
    if (!columns.contains('size')) {
      _db.execute('ALTER TABLE cache ADD COLUMN size INTEGER');
    }
    if (!columns.contains('accessed')) {
      _db.execute('ALTER TABLE cache ADD COLUMN accessed INTEGER');
    }
    ready = _measure();
  }

  factory CacheManager() => instance ??= CacheManager._create();

  /// Measures the cache, removing files that aren't in the index, then
  /// trims it if it is over the limit.
  Future<void> _measure() async {
    final known = {
      for (final row in _db.select('SELECT dir, name FROM cache'))
        '${row['dir']}/${row['name']}',
    };
    try {
      _currentSize = await compute(_measureCache, (cachePath, known));
    } catch (e) {
      Log.error('Cache', 'Failed to measure the cache: $e');
      return;
    }
    await checkCache();
  }

  /// Overrides the limit set in the settings, in bytes.
  void setLimitSize(int size) {
    _limitOverride = size;
  }

  int get _now => DateTime.now().millisecondsSinceEpoch;

  void _added(int bytes) {
    if (_currentSize == null) return;
    _currentSize = _currentSize! + bytes;
    if (_currentSize! > limitSize) {
      checkCache();
    }
  }

  Future<void> writeCache(String key, Uint8List data,
      [int duration = 7 * 24 * 60 * 60 * 1000]) async {
    this.dir++;
    this.dir %= 100;
    var dir = this.dir;
    var name = md5.convert(Uint8List.fromList(key.codeUnits)).toString();
    var file = File('$cachePath/$dir/$name');
    while (await file.exists()) {
      name = md5.convert(Uint8List.fromList(name.codeUnits)).toString();
      file = File('$cachePath/$dir/$name');
    }
    await file.create(recursive: true);
    await file.writeAsBytes(data);
    _insert(key, dir.toString(), name, data.length);
  }

  void _insert(String key, String dir, String name, int size) {
    final replaced = _db.select(
        'SELECT dir, name, size FROM cache WHERE key = ?', [key]).firstOrNull;
    _db.execute('''
      INSERT OR REPLACE INTO cache (key, dir, name, expires, size, accessed)
      VALUES (?, ?, ?, ?, ?, ?)
    ''', [key, dir, name, _now + 7 * 24 * 60 * 60 * 1000, size, _now]);
    // A key written again leaves its old file behind; remove it.
    if (replaced != null &&
        ('${replaced['dir']}' != dir || replaced['name'] != name)) {
      final old = File('$cachePath/${replaced['dir']}/${replaced['name']}');
      if (old.existsSync()) {
        final oldSize = old.lengthSync();
        old.deleteSync();
        _added(-oldSize);
      }
    }
    _added(size);
  }

  Future<CachingFile> openWrite(String key) async {
    this.dir++;
    this.dir %= 100;
    var dir = this.dir;
    var name = md5.convert(Uint8List.fromList(key.codeUnits)).toString();
    var file = File('$cachePath/$dir/$name');
    while (await file.exists()) {
      name = md5.convert(Uint8List.fromList(name.codeUnits)).toString();
      file = File('$cachePath/$dir/$name');
    }
    await file.create(recursive: true);
    return CachingFile._(key, dir.toString(), name, file);
  }

  Future<String?> findCache(String key) async {
    var res = _db.select('''
      SELECT * FROM cache
      WHERE key = ?
    ''', [key]);
    if (res.isEmpty) {
      return null;
    }
    var row = res.first;
    var file = File('$cachePath/${row['dir']}/${row['name']}');
    if (await file.exists()) {
      _db.execute(
          'UPDATE cache SET accessed = ? WHERE key = ?', [_now, key]);
      return file.path;
    }
    return null;
  }

  bool _isChecking = false;

  /// Removes the files used least recently until the cache is back to 80%
  /// of its limit, if it is over the limit.
  Future<void> checkCache() async {
    if (_isChecking || _currentSize == null || _currentSize! <= limitSize) {
      return;
    }
    _isChecking = true;
    try {
      final target = limitSize * 8 ~/ 10;
      while (_currentSize! > target) {
        // Files from before access times were recorded count as the oldest.
        final rows = _db.select('''
          SELECT key, dir, name FROM cache
          ORDER BY COALESCE(accessed, 0) ASC
          LIMIT 50
        ''');
        if (rows.isEmpty) {
          // Only files outside the index are left; measure again.
          _currentSize = await compute(
              (String path) => Directory(path).size, cachePath);
          break;
        }
        for (final row in rows) {
          final file = File('$cachePath/${row['dir']}/${row['name']}');
          if (await file.exists()) {
            final size = await file.length();
            await file.delete();
            _currentSize = _currentSize! - size;
          }
          _db.execute('DELETE FROM cache WHERE key = ?', [row['key']]);
          if (_currentSize! <= target) break;
        }
      }
    } catch (e) {
      Log.error('Cache', 'Failed to trim the cache: $e');
    } finally {
      _isChecking = false;
    }
  }

  Future<void> delete(String key) async {
    var res = _db.select('''
      SELECT * FROM cache
      WHERE key = ?
    ''', [key]);
    if (res.isEmpty) {
      return;
    }
    var row = res.first;
    var file = File('$cachePath/${row['dir']}/${row['name']}');
    var fileSize = 0;
    if (await file.exists()) {
      fileSize = await file.length();
      await file.delete();
    }
    _db.execute('''
      DELETE FROM cache
      WHERE key = ?
    ''', [key]);
    _added(-fileSize);
  }

  Future<void> clear() async {
    await Directory(cachePath).delete(recursive: true);
    Directory(cachePath).createSync(recursive: true);
    _db.execute('''
      DELETE FROM cache
    ''');
    _currentSize = 0;
  }

  Future<void> deleteKeyword(String keyword) async {
    var res = _db.select('''
      SELECT * FROM cache
      WHERE key LIKE ?
    ''', ['%$keyword%']);
    for (var row in res) {
      var file = File('$cachePath/${row['dir']}/${row['name']}');
      var fileSize = 0;
      if (await file.exists()) {
        fileSize = await file.length();
        await file.delete();
      }
      _db.execute('''
        DELETE FROM cache
        WHERE key = ?
      ''', [row['key']]);
      _added(-fileSize);
    }
  }
}

/// Sums the size of the cache, deleting files that aren't in the index and
/// were last written over an hour ago, so writes in progress are kept.
int _measureCache((String, Set<String>) args) {
  final (path, known) = args;
  final root = Directory(path);
  if (!root.existsSync()) return 0;
  final cutoff = DateTime.now().subtract(const Duration(hours: 1));
  var size = 0;
  for (final entity in root.listSync(recursive: true)) {
    if (entity is! File) continue;
    final relative =
        entity.path.substring(path.length + 1).replaceAll('\\', '/');
    final stat = entity.statSync();
    if (!known.contains(relative) && stat.modified.isBefore(cutoff)) {
      try {
        entity.deleteSync();
        continue;
      } catch (_) {}
    }
    size += stat.size;
  }
  return size;
}

class CachingFile {
  CachingFile._(this.key, this.dir, this.name, this.file);

  final String key;

  final String dir;

  final String name;

  final File file;

  final List<int> _buffer = [];

  int _written = 0;

  Future<void> writeBytes(List<int> data) async {
    _buffer.addAll(data);
    _written += data.length;
    if (_buffer.length > 1024 * 1024) {
      await file.writeAsBytes(_buffer, mode: FileMode.append);
      _buffer.clear();
    }
  }

  Future<void> close() async {
    if (_buffer.isNotEmpty) {
      await file.writeAsBytes(_buffer, mode: FileMode.append);
      _buffer.clear();
    }
    CacheManager()._insert(key, dir, name, _written);
  }

  Future<void> cancel() async {
    await file.deleteIfExists();
  }
}
