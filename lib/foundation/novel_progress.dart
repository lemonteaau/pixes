import 'package:pixes/foundation/app.dart';
import 'package:pixes/foundation/log.dart';
import 'package:sqlite3/sqlite3.dart';

/// Where the reader stopped in a novel.
class NovelReadingProgress {
  const NovelReadingProgress({
    required this.novelId,
    required this.item,
    required this.offset,
    required this.progress,
  });

  final int novelId;

  /// Index of the reader item at the top of the screen.
  final int item;

  /// How far into [item] the top of the screen was, in pixels.
  final double offset;

  /// How much of the novel has been read, from 0 to 1.
  final double progress;

  bool get isFinished => progress >= 0.99;
}

/// The chapter of a series the user read last.
class NovelSeriesProgress {
  const NovelSeriesProgress({
    required this.seriesId,
    required this.novelId,
    required this.chapter,
    required this.title,
  });

  final int seriesId;

  final int novelId;

  /// One based chapter number, if the chapter list was loaded.
  final int? chapter;

  final String title;
}

class NovelProgressStore {
  NovelProgressStore._();

  static final instance = NovelProgressStore._();

  Database? _db;

  bool _openFailed = false;

  final _novels = <int, NovelReadingProgress?>{};

  final _series = <int, NovelSeriesProgress?>{};

  Database? get _database {
    if (_db != null || _openFailed) return _db;
    try {
      final db = sqlite3.open("${App.dataPath}/novel_progress.db");
      db.execute('''
        create table if not exists novel_progress (
          id integer primary key not null,
          item integer not null,
          offset real not null,
          progress real not null,
          time integer not null
        )
      ''');
      db.execute('''
        create table if not exists series_progress (
          id integer primary key not null,
          novel_id integer not null,
          chapter integer,
          title text not null,
          time integer not null
        )
      ''');
      _db = db;
    } catch (e) {
      // Progress then only lives for this session.
      _openFailed = true;
      Log.warning("Novel Progress", "Failed to open database: $e");
    }
    return _db;
  }

  NovelReadingProgress? get(int novelId) {
    return _novels.putIfAbsent(novelId, () {
      final rows = _database?.select(
          "select item, offset, progress from novel_progress where id = ?",
          [novelId]);
      if (rows == null || rows.isEmpty) return null;
      final row = rows.first;
      return NovelReadingProgress(
        novelId: novelId,
        item: row["item"] as int,
        offset: (row["offset"] as num).toDouble(),
        progress: (row["progress"] as num).toDouble(),
      );
    });
  }

  void save(NovelReadingProgress progress) {
    _novels[progress.novelId] = progress;
    try {
      _database?.execute(
        "insert or replace into novel_progress (id, item, offset, progress, time) values (?, ?, ?, ?, ?)",
        [
          progress.novelId,
          progress.item,
          progress.offset,
          progress.progress,
          DateTime.now().millisecondsSinceEpoch,
        ],
      );
    } catch (e) {
      Log.warning("Novel Progress", "Failed to save progress: $e");
    }
  }

  NovelSeriesProgress? getSeries(int seriesId) {
    return _series.putIfAbsent(seriesId, () {
      final rows = _database?.select(
          "select novel_id, chapter, title from series_progress where id = ?",
          [seriesId]);
      if (rows == null || rows.isEmpty) return null;
      final row = rows.first;
      return NovelSeriesProgress(
        seriesId: seriesId,
        novelId: row["novel_id"] as int,
        chapter: row["chapter"] as int?,
        title: row["title"] as String,
      );
    });
  }

  void saveSeries(NovelSeriesProgress progress) {
    _series[progress.seriesId] = progress;
    try {
      _database?.execute(
        "insert or replace into series_progress (id, novel_id, chapter, title, time) values (?, ?, ?, ?, ?)",
        [
          progress.seriesId,
          progress.novelId,
          progress.chapter,
          progress.title,
          DateTime.now().millisecondsSinceEpoch,
        ],
      );
    } catch (e) {
      Log.warning("Novel Progress", "Failed to save series progress: $e");
    }
  }
}
