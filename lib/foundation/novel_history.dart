import 'dart:convert';

import 'package:pixes/foundation/app.dart';
import 'package:pixes/foundation/log.dart';
import 'package:pixes/network/network.dart';
import 'package:sqlite3/sqlite3.dart';

/// A novel that was opened, as it was then.
class NovelHistoryEntry {
  const NovelHistoryEntry(this.novel, this.time);

  final Novel novel;

  final DateTime time;
}

/// The novels opened lately, on their detail page or in the reader.
///
/// Novels are added while pages are built, so this doesn't notify anyone;
/// the history page reads it again whenever it's shown.
class NovelHistoryStore {
  NovelHistoryStore._();

  static final instance = NovelHistoryStore._();

  /// The most novels that are remembered.
  static const maxEntries = 1000;

  Database? _db;

  bool _openFailed = false;

  List<NovelHistoryEntry>? _entries;

  Database? get _database {
    if (_db != null || _openFailed) return _db;
    try {
      final db = sqlite3.open("${App.dataPath}/novel_history.db");
      db.execute('''
        create table if not exists novel_history (
          id integer primary key not null,
          novel text not null,
          time integer not null
        )
      ''');
      _db = db;
    } catch (e) {
      // History then only lives for this session.
      _openFailed = true;
      Log.warning("Novel History", "Failed to open database: $e");
    }
    return _db;
  }

  /// Every novel in the history, the latest first.
  List<NovelHistoryEntry> get entries {
    return _entries ??= () {
      final entries = <NovelHistoryEntry>[];
      try {
        final rows = _database?.select(
            "select novel, time from novel_history order by time desc limit ?",
            [maxEntries]);
        for (final row in rows ?? const <Row>[]) {
          try {
            entries.add(NovelHistoryEntry(
              Novel.fromJson(jsonDecode(row["novel"] as String)),
              DateTime.fromMillisecondsSinceEpoch(row["time"] as int),
            ));
          } catch (e) {
            Log.warning("Novel History", "Failed to load an entry: $e");
          }
        }
      } catch (e) {
        Log.warning("Novel History", "Failed to load history: $e");
      }
      return entries;
    }();
  }

  /// Puts [novel] at the top of the history.
  void add(Novel novel) {
    final entries = this.entries;
    final time = DateTime.now();
    try {
      final db = _database;
      if (db != null) {
        db.execute(
          "insert or replace into novel_history (id, novel, time) values (?, ?, ?)",
          [novel.id, jsonEncode(novel.toJson()), time.millisecondsSinceEpoch],
        );
        if (entries.length >= maxEntries) {
          db.execute(
            "delete from novel_history where id not in (select id from novel_history order by time desc limit ?)",
            [maxEntries],
          );
        }
      }
    } catch (e) {
      Log.warning("Novel History", "Failed to save history: $e");
    }
    entries.removeWhere((entry) => entry.novel.id == novel.id);
    entries.insert(0, NovelHistoryEntry(novel, time));
    if (entries.length > maxEntries) {
      entries.removeRange(maxEntries, entries.length);
    }
  }

  void remove(Iterable<int> novelIds) {
    final ids = novelIds.toSet();
    try {
      final db = _database;
      if (db != null) {
        for (final id in ids) {
          db.execute("delete from novel_history where id = ?", [id]);
        }
      }
    } catch (e) {
      Log.warning("Novel History", "Failed to delete history: $e");
    }
    entries.removeWhere((entry) => ids.contains(entry.novel.id));
  }

  void clear() {
    try {
      _database?.execute("delete from novel_history");
    } catch (e) {
      Log.warning("Novel History", "Failed to clear history: $e");
    }
    entries.clear();
  }
}

/// [entries] with only the latest novel of each book, as [bookOf] tells
/// them apart, and the ids of all the novels of that book in [entries].
List<({NovelHistoryEntry entry, List<int> novelIds})> latestOfEachBook(
    List<NovelHistoryEntry> entries, String Function(Novel novel) bookOf) {
  final result = <({NovelHistoryEntry entry, List<int> novelIds})>[];
  final byBook = <String, List<int>>{};
  for (final entry in entries) {
    final key = bookOf(entry.novel);
    final ids = byBook[key];
    if (ids != null) {
      ids.add(entry.novel.id);
      continue;
    }
    final novelIds = [entry.novel.id];
    byBook[key] = novelIds;
    result.add((entry: entry, novelIds: novelIds));
  }
  return result;
}
