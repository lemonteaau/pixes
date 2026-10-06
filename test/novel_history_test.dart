import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixes/components/md.dart';
import 'package:pixes/foundation/app.dart';
import 'package:pixes/foundation/novel_books.dart';
import 'package:pixes/foundation/novel_history.dart';
import 'package:pixes/foundation/novel_progress.dart';
import 'package:pixes/network/network.dart';
import 'package:pixes/pages/novel_book_page.dart';
import 'package:pixes/pages/novel_history_page.dart';
import 'package:pixes/utils/translation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await Translation.init();
    App.dataPath = Directory.systemTemp.createTempSync('pixes_history').path;
  });

  final history = NovelHistoryStore.instance;

  setUp(history.clear);

  test('keeps each novel once, the latest first', () {
    history.add(_novel(1));
    history.add(_novel(2));
    history.add(_novel(1, title: 'Renamed'));
    expect(history.entries.map((e) => e.novel.id), [1, 2]);
    expect(history.entries.first.novel.title, 'Renamed');

    history.remove([1]);
    expect(history.entries.map((e) => e.novel.id), [2]);
    history.clear();
    expect(history.entries, isEmpty);
  });

  test('shows the latest novel of each series or book', () {
    final entries = [
      for (final novel in [
        _novel(5, series: 9),
        _novel(4),
        _novel(3, series: 9),
        _novel(2),
        _novel(1, series: 8),
      ])
        NovelHistoryEntry(novel, DateTime(2026)),
    ];
    final items = latestOfEachBook(entries, novelBookKey);
    expect(items.map((i) => i.entry.novel.id), [5, 4, 2, 1]);
    expect(items.first.novelIds, [5, 3]);

    final book = NovelBookStore.instance.create('Book', [_novel(4), _novel(2)]);
    addTearDown(() => NovelBookStore.instance.delete(book.id));
    final merged = latestOfEachBook(entries, novelBookKey);
    expect(merged.map((i) => i.entry.novel.id), [5, 4, 1]);
    expect(merged[1].novelIds, [4, 2]);
  });

  testWidgets('the history page lists, removes and clears novels',
      (tester) async {
    history.add(_novel(11, title: 'Lonely'));
    history.add(_novel(12, series: 30, title: 'Episode 1'));
    history.add(_novel(13, series: 30, title: 'Episode 2'));
    NovelProgressStore.instance.save(const NovelReadingProgress(
        novelId: 13, item: 4, offset: 0, progress: 0.42));

    await tester.pumpWidget(const FluentApp(home: NovelHistoryPage()));
    await _settleCovers(tester);
    expect(find.text('Episode 2'), findsOneWidget);
    expect(find.text('Episode 1'), findsNothing);
    expect(find.text('Series · Series 30'), findsOneWidget);
    expect(find.textContaining('42% read'), findsOneWidget);
    expect(find.text('Lonely'), findsOneWidget);

    // Removing the series takes all of its chapters out.
    await tester.tap(find.byIcon(MdIcons.close).first);
    await tester.pump();
    expect(find.text('Episode 2'), findsNothing);
    expect(history.entries.map((e) => e.novel.id), [11]);

    await tester.tap(find.text('Clear All'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear All').last);
    await tester.pumpAndSettle();
    expect(history.entries, isEmpty);
    expect(find.text('No history yet'), findsOneWidget);
  });

  testWidgets('the book page removes chapters and splits the book',
      (tester) async {
    final books = NovelBookStore.instance;
    final book = books.create('Saga', [
      _novel(21, title: 'Part 1'),
      _novel(22, title: 'Part 2'),
      _novel(23, title: 'Part 3'),
    ]);

    await tester.pumpWidget(FluentApp(home: NovelBookPage(book.id)));
    await _settleCovers(tester);
    expect(find.text('Saga'), findsOneWidget);
    expect(find.text('3 chapters · 300 chars'), findsOneWidget);
    expect(find.text('Part 2'), findsOneWidget);

    await tester.tap(find.byIcon(MdIcons.remove_circle_outline).at(1));
    await tester.pump();
    expect(find.text('Part 2'), findsNothing);
    expect(books.get(book.id)!.chapters.map((n) => n.id), [21, 23]);
    expect(books.bookOf(22), isNull);

    await tester.tap(find.byIcon(MdIcons.call_split));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Split'));
    await tester.pumpAndSettle();
    expect(books.get(book.id), isNull);
    expect(books.bookOf(21), isNull);
  });
}

/// Lets the covers, which can't be loaded in tests, give up retrying while
/// they're on screen to handle the error.
Future<void> _settleCovers(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
}

Novel _novel(int id, {String? title, int? series}) {
  return Novel.fromJson({
    "id": id,
    "title": title ?? "Novel $id",
    "caption": "",
    "is_original": true,
    "image_urls": {"large": ""},
    "create_date": "2026-01-01T00:00:00+00:00",
    "tags": <Object>[],
    "page_count": 1,
    "text_length": 100,
    "user": {
      "id": 1,
      "name": "Author",
      "account": "author",
      "profile_image_urls": {"medium": ""},
      "is_followed": false,
    },
    "series": series == null ? null : {"id": series, "title": "Series $series"},
    "is_bookmarked": false,
    "total_bookmarks": 0,
    "total_view": 0,
    "total_comments": 0,
    "novel_ai_type": 0,
  });
}
