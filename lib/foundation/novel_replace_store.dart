import 'package:flutter/foundation.dart';
import 'package:pixes/foundation/app.dart';
import 'package:pixes/foundation/log.dart';
import 'package:pixes/foundation/novel_books.dart';
import 'package:pixes/network/network.dart';
import 'package:pixes/utils/novel_replace.dart';
import 'package:sqlite3/sqlite3.dart';

/// The word replacements of each book, as [novelBookKey] tells them apart.
class NovelReplaceStore extends ChangeNotifier {
  NovelReplaceStore._();

  static final instance = NovelReplaceStore._();

  /// The book whose replacements apply to [novel].
  static String bookOf(Novel novel) => novelBookKey(novel);

  Database? _db;

  bool _openFailed = false;

  final _rules = <String, List<NovelReplaceRule>>{};

  final _replacers = <String, NovelTextReplacer>{};

  /// Ids for rules that only live in memory, because the database failed.
  var _memoryId = -1;

  Database? get _database {
    if (_db != null || _openFailed) return _db;
    try {
      final db = sqlite3.open("${App.dataPath}/novel_replace.db");
      db.execute('''
        create table if not exists replace_rules (
          id integer primary key autoincrement,
          book text not null,
          from_text text not null,
          to_text text not null,
          enabled integer not null,
          time integer not null
        )
      ''');
      db.execute(
          "create index if not exists replace_rules_book on replace_rules (book)");
      _db = db;
    } catch (e) {
      // Replacements then only live for this session.
      _openFailed = true;
      Log.warning("Novel Replace", "Failed to open database: $e");
    }
    return _db;
  }

  /// The replacements of [book], oldest first.
  List<NovelReplaceRule> rules(String book) {
    return _rules.putIfAbsent(book, () {
      try {
        final rows = _database?.select(
            "select id, from_text, to_text, enabled from replace_rules where book = ? order by id",
            [book]);
        return List.unmodifiable([
          for (final row in rows ?? const <Row>[])
            NovelReplaceRule(
              id: row["id"] as int,
              from: row["from_text"] as String,
              to: row["to_text"] as String,
              enabled: row["enabled"] != 0,
            ),
        ]);
      } catch (e) {
        Log.warning("Novel Replace", "Failed to load replacements: $e");
        return const [];
      }
    });
  }

  /// Applies the enabled replacements of [book]. The same replacer is returned
  /// until the replacements change.
  NovelTextReplacer replacer(String book) {
    return _replacers.putIfAbsent(book, () => NovelTextReplacer(rules(book)));
  }

  NovelReplaceRule add(String book, String from, String to) {
    // Load the saved ones first, or the new one would be loaded with them.
    final current = rules(book);
    final rule = _insert(book, from, to, true);
    _set(book, [...current, rule]);
    return rule;
  }

  /// Adds copies of [rules] to [book], leaving out those replacing text that
  /// [book] already replaces.
  void addAll(String book, Iterable<NovelReplaceRule> rules) {
    final current = this.rules(book);
    final taken = {for (final rule in current) rule.from};
    final added = [
      for (final rule in rules)
        if (taken.add(rule.from))
          _insert(book, rule.from, rule.to, rule.enabled),
    ];
    if (added.isNotEmpty) _set(book, [...current, ...added]);
  }

  NovelReplaceRule _insert(String book, String from, String to, bool enabled) {
    int? id;
    try {
      final db = _database;
      if (db != null) {
        db.execute(
          "insert into replace_rules (book, from_text, to_text, enabled, time) values (?, ?, ?, ?, ?)",
          [
            book,
            from,
            to,
            enabled ? 1 : 0,
            DateTime.now().millisecondsSinceEpoch
          ],
        );
        id = db.lastInsertRowId;
      }
    } catch (e) {
      Log.warning("Novel Replace", "Failed to save replacement: $e");
    }
    return NovelReplaceRule(
        id: id ?? _memoryId--, from: from, to: to, enabled: enabled);
  }

  void update(String book, NovelReplaceRule rule) {
    try {
      _database?.execute(
        "update replace_rules set from_text = ?, to_text = ?, enabled = ?, time = ? where id = ?",
        [
          rule.from,
          rule.to,
          rule.enabled ? 1 : 0,
          DateTime.now().millisecondsSinceEpoch,
          rule.id,
        ],
      );
    } catch (e) {
      Log.warning("Novel Replace", "Failed to save replacement: $e");
    }
    _set(book, [
      for (final r in rules(book)) r.id == rule.id ? rule : r,
    ]);
  }

  void remove(String book, NovelReplaceRule rule) {
    try {
      _database?.execute("delete from replace_rules where id = ?", [rule.id]);
    } catch (e) {
      Log.warning("Novel Replace", "Failed to delete replacement: $e");
    }
    _set(book, [
      for (final r in rules(book))
        if (r.id != rule.id) r,
    ]);
  }

  /// Deletes every replacement of [book].
  void removeBook(String book) {
    try {
      _database?.execute("delete from replace_rules where book = ?", [book]);
    } catch (e) {
      Log.warning("Novel Replace", "Failed to delete replacements: $e");
    }
    _set(book, const []);
  }

  void _set(String book, List<NovelReplaceRule> rules) {
    _rules[book] = List.unmodifiable(rules);
    _replacers.remove(book);
    notifyListeners();
  }
}
