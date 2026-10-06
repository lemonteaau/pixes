import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:pixes/foundation/app.dart';
import 'package:pixes/foundation/log.dart';
import 'package:pixes/foundation/novel_replace_store.dart';
import 'package:pixes/network/network.dart';
import 'package:pixes/utils/novel_replace.dart';
import 'package:sqlite3/sqlite3.dart';

/// The book [novel] is read as part of: the book the user put it in, or else
/// its series, or else the novel on its own.
String novelBookKey(Novel novel) {
  final custom = NovelBookStore.instance.bookOf(novel.id);
  if (custom != null) return custom.key;
  final seriesId = novel.seriesId;
  return seriesId != null ? "series:$seriesId" : "novel:${novel.id}";
}

/// Novels the user put together to read as the chapters of one book, for
/// authors who post a story as separate novels instead of as a series.
class NovelCustomBook {
  const NovelCustomBook({
    required this.id,
    required this.title,
    required this.chapters,
    this.lastReadId,
  });

  final int id;

  final String title;

  /// The chapters in reading order, as they were when they were added.
  final List<Novel> chapters;

  /// The chapter that was read last.
  final int? lastReadId;

  /// The book in [NovelReplaceStore].
  String get key => "book:$id";

  /// Zero based position of the novel [novelId] in the book, or -1.
  int indexOf(int novelId) => chapters.indexWhere((n) => n.id == novelId);

  NovelCustomBook copyWith(
      {String? title, List<Novel>? chapters, int? Function()? lastReadId}) {
    return NovelCustomBook(
      id: id,
      title: title ?? this.title,
      chapters: chapters ?? this.chapters,
      lastReadId: lastReadId != null ? lastReadId() : this.lastReadId,
    );
  }
}

/// The books the user made. A novel is in one book at most.
class NovelBookStore extends ChangeNotifier {
  NovelBookStore._();

  static final instance = NovelBookStore._();

  Database? _db;

  bool _openFailed = false;

  Map<int, NovelCustomBook>? _books;

  /// The book of each novel that's in one.
  final _bookOfNovel = <int, int>{};

  /// Ids for books that only live in memory, because the database failed.
  var _memoryId = -1;

  Database? get _database {
    if (_db != null || _openFailed) return _db;
    try {
      final db = sqlite3.open("${App.dataPath}/novel_books.db");
      db.execute('''
        create table if not exists books (
          id integer primary key autoincrement,
          title text not null,
          last_read integer,
          time integer not null
        )
      ''');
      db.execute('''
        create table if not exists book_chapters (
          novel_id integer primary key not null,
          book_id integer not null,
          position integer not null,
          novel text not null
        )
      ''');
      _db = db;
    } catch (e) {
      // Books then only live for this session.
      _openFailed = true;
      Log.warning("Novel Books", "Failed to open database: $e");
    }
    return _db;
  }

  Map<int, NovelCustomBook> get _loaded {
    final loaded = _books;
    if (loaded != null) return loaded;
    final books = <int, NovelCustomBook>{};
    try {
      final db = _database;
      if (db != null) {
        final chapters = <int, List<Novel>>{};
        for (final row in db.select(
            "select book_id, novel from book_chapters order by book_id, position")) {
          try {
            chapters
                .putIfAbsent(row["book_id"] as int, () => [])
                .add(Novel.fromJson(jsonDecode(row["novel"] as String)));
          } catch (e) {
            Log.warning("Novel Books", "Failed to load a chapter: $e");
          }
        }
        for (final row in db.select("select id, title, last_read from books")) {
          final id = row["id"] as int;
          final list = chapters[id];
          if (list == null || list.isEmpty) continue;
          books[id] = NovelCustomBook(
            id: id,
            title: row["title"] as String,
            chapters: List.unmodifiable(list),
            lastReadId: row["last_read"] as int?,
          );
        }
      }
    } catch (e) {
      Log.warning("Novel Books", "Failed to load books: $e");
    }
    _books = books;
    _reindex();
    return books;
  }

  void _reindex() {
    _bookOfNovel.clear();
    for (final book in _books!.values) {
      for (final novel in book.chapters) {
        _bookOfNovel[novel.id] = book.id;
      }
    }
  }

  NovelCustomBook? get(int id) => _loaded[id];

  /// The book the novel [novelId] is in.
  NovelCustomBook? bookOf(int novelId) {
    final books = _loaded;
    final id = _bookOfNovel[novelId];
    return id == null ? null : books[id];
  }

  /// Makes a book of [chapters], in this order, taking them out of the books
  /// they were in.
  NovelCustomBook create(String title, List<Novel> chapters) {
    assert(chapters.isNotEmpty);
    final emptied = _emptiedBy(null, chapters);
    var id = 0;
    final saved = _write((db) {
      db.execute(
        "insert into books (title, time) values (?, ?)",
        [title, DateTime.now().millisecondsSinceEpoch],
      );
      id = db.lastInsertRowId;
      _writeChapters(db, id, chapters, emptied);
    });
    if (!saved) id = _memoryId--;
    return _put(
      NovelCustomBook(
          id: id, title: title, chapters: List.unmodifiable(chapters)),
      emptied,
    );
  }

  /// Renames the book [id] or changes its chapters, taking the chapters out
  /// of the books they were in. Books left without chapters are deleted,
  /// with their word replacements.
  NovelCustomBook update(int id, {String? title, List<Novel>? chapters}) {
    final book = _loaded[id]!;
    if (chapters != null && chapters.isEmpty) {
      delete(id);
      return book.copyWith(chapters: const []);
    }
    final emptied = chapters == null ? const <int>[] : _emptiedBy(id, chapters);
    _write((db) {
      if (title != null) {
        db.execute("update books set title = ? where id = ?", [title, id]);
      }
      if (chapters != null) {
        _writeChapters(db, id, chapters, emptied);
      }
    });
    final lastRead = book.lastReadId;
    return _put(
      book.copyWith(
        title: title,
        chapters: chapters != null ? List.unmodifiable(chapters) : null,
        lastReadId: () =>
            chapters == null || chapters.any((n) => n.id == lastRead)
                ? lastRead
                : null,
      ),
      emptied,
    );
  }

  /// Splits the book [id] back into the novels it was made of, and deletes
  /// its word replacements.
  void delete(int id) {
    if (_loaded[id] == null) return;
    _write((db) => _deleteBook(db, id));
    _removeAndNotify([id]);
  }

  /// Remembers that the chapter [novelId] of the book [id] was read last.
  ///
  /// This is saved while the reader closes, when the widget tree is locked,
  /// so it doesn't notify listeners. Pages showing it refresh once the reader
  /// is closed.
  void setLastRead(int id, int novelId) {
    final book = _loaded[id];
    if (book == null || book.lastReadId == novelId) return;
    _write((db) {
      db.execute("update books set last_read = ? where id = ?", [novelId, id]);
    });
    _books![id] = book.copyWith(lastReadId: () => novelId);
  }

  /// The books other than [id] that are left without chapters once
  /// [chapters] are taken out of them.
  List<int> _emptiedBy(int? id, List<Novel> chapters) {
    final ids = {for (final novel in chapters) novel.id};
    return [
      for (final book in _loaded.values)
        if (book.id != id && book.chapters.every((n) => ids.contains(n.id)))
          book.id,
    ];
  }

  void _writeChapters(
      Database db, int id, List<Novel> chapters, List<int> emptied) {
    db.execute("delete from book_chapters where book_id = ?", [id]);
    for (var i = 0; i < chapters.length; i++) {
      // Replacing the row takes the novel out of the book it was in.
      db.execute(
        "insert or replace into book_chapters (novel_id, book_id, position, novel) values (?, ?, ?, ?)",
        [chapters[i].id, id, i, jsonEncode(chapters[i].toJson())],
      );
    }
    for (final other in emptied) {
      _deleteBook(db, other);
    }
  }

  void _deleteBook(Database db, int id) {
    db.execute("delete from books where id = ?", [id]);
    db.execute("delete from book_chapters where book_id = ?", [id]);
  }

  /// Saves [book] in memory, taking its chapters out of the other books.
  NovelCustomBook _put(NovelCustomBook book, List<int> emptied) {
    final books = _books!;
    final ids = {for (final novel in book.chapters) novel.id};
    for (final other in books.values.toList()) {
      if (other.id == book.id ||
          !other.chapters.any((n) => ids.contains(n.id))) {
        continue;
      }
      final rest = [
        for (final novel in other.chapters)
          if (!ids.contains(novel.id)) novel,
      ];
      books[other.id] = other.copyWith(chapters: List.unmodifiable(rest));
    }
    books[book.id] = book;
    _removeAndNotify(emptied);
    return book;
  }

  /// Forgets the books [ids] with their word replacements, and tells the
  /// listeners about the changes.
  void _removeAndNotify(List<int> ids) {
    final removed = [
      for (final id in ids)
        if (_books!.remove(id) case final book?) book,
    ];
    _reindex();
    for (final book in removed) {
      NovelReplaceStore.instance.removeBook(book.key);
    }
    notifyListeners();
  }

  /// Runs [action] in a transaction. Returns whether it was saved.
  bool _write(void Function(Database db) action) {
    final db = _database;
    if (db == null) return false;
    try {
      db.execute("begin");
      try {
        action(db);
        db.execute("commit");
        return true;
      } catch (e) {
        db.execute("rollback");
        rethrow;
      }
    } catch (e) {
      Log.warning("Novel Books", "Failed to save books: $e");
      return false;
    }
  }
}

/// What merging novels into one book does: which book they go into, in which
/// order the chapters end up and which word replacements come with them.
class NovelBookMerge {
  NovelBookMerge._(this.target, this.absorbed, this.chapters, this.rules);

  /// Plans merging [novels] into one book. If some of them are in books
  /// already, those books are merged as a whole.
  factory NovelBookMerge(Iterable<Novel> novels) {
    final store = NovelBookStore.instance;
    final books = <int, NovelCustomBook>{};
    for (final novel in novels) {
      final book = store.bookOf(novel.id);
      if (book != null) books[book.id] = book;
    }
    // The biggest book takes in the others, so the least order is redone.
    final sorted = books.values.toList()
      ..sort((a, b) {
        final bySize = b.chapters.length.compareTo(a.chapters.length);
        return bySize != 0 ? bySize : a.id.compareTo(b.id);
      });
    final target = sorted.firstOrNull;
    final absorbed = sorted.skip(1).toList();
    final latest = {for (final novel in novels) novel.id: novel};
    final chapters = [
      for (final novel in mergeNovelChapters(target?.chapters ?? const [], [
        for (final book in absorbed) ...book.chapters,
        ...novels,
      ]))
        latest[novel.id] ?? novel,
    ];

    // The chapters keep the word replacements they have now. Where two
    // replace the same text, the one of the earlier chapter wins.
    final replace = NovelReplaceStore.instance;
    final targetKey = target?.key;
    final taken = <String>{
      if (targetKey != null)
        for (final rule in replace.rules(targetKey)) rule.from,
    };
    final sources = <String>{};
    final rules = <NovelReplaceRule>[];
    for (final novel in chapters) {
      final key = NovelReplaceStore.bookOf(novel);
      if (key == targetKey || !sources.add(key)) continue;
      for (final rule in replace.rules(key)) {
        if (taken.add(rule.from)) rules.add(rule);
      }
    }
    return NovelBookMerge._(target, absorbed, chapters, rules);
  }

  /// The book the novels go into. Null if a new one is made.
  final NovelCustomBook? target;

  /// The other books, whose chapters move into the merged book.
  final List<NovelCustomBook> absorbed;

  /// The chapters of the merged book, in reading order.
  final List<Novel> chapters;

  /// The word replacements the merged book takes over from its chapters.
  final List<NovelReplaceRule> rules;

  String get suggestedTitle =>
      target?.title ??
      suggestNovelBookTitle([for (final novel in chapters) novel.title]);

  NovelCustomBook apply(String title) {
    final store = NovelBookStore.instance;
    final current = target;
    final book = current == null
        ? store.create(title, chapters)
        : store.update(current.id, title: title, chapters: chapters);
    NovelReplaceStore.instance.addAll(book.key, rules);
    return book;
  }
}

/// [existing] chapters with the novels of [added] that aren't among them,
/// each put after the last chapter published before it. The order of
/// [existing] is kept, so a book that was reordered by hand stays so.
List<Novel> mergeNovelChapters(List<Novel> existing, Iterable<Novel> added) {
  final result = [...existing];
  final ids = {for (final novel in existing) novel.id};
  final sorted = [
    for (final novel in added)
      if (ids.add(novel.id)) novel,
  ]..sort((a, b) {
      final byDate = a.createDate.compareTo(b.createDate);
      return byDate != 0 ? byDate : a.id.compareTo(b.id);
    });
  for (final novel in sorted) {
    var i = result.length;
    while (i > 0 && result[i - 1].createDate.isAfter(novel.createDate)) {
      i--;
    }
    result.insert(i, novel);
  }
  return result;
}

/// Characters left over at the end of what chapter titles share, such as
/// the "第" of "第1話".
final _titleTail = RegExp(r'[\s\-–—_:：・·.,，、。~～|｜/／#＃(（\[［【「『<＜第]+$');

/// A title for a book of chapters titled [titles]: what the titles start
/// with, if they share enough, or else the first title.
String suggestNovelBookTitle(List<String> titles) {
  if (titles.isEmpty) return "";
  var prefix = titles.first.runes.toList();
  for (final title in titles.skip(1)) {
    final runes = title.runes.toList();
    var i = 0;
    while (i < prefix.length && i < runes.length && prefix[i] == runes[i]) {
      i++;
    }
    prefix = prefix.sublist(0, i);
  }
  final shared =
      String.fromCharCodes(prefix).replaceFirst(_titleTail, "").trim();
  return shared.runes.length >= 2 ? shared : titles.first.trim();
}
