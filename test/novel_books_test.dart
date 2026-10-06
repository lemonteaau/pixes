import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixes/foundation/app.dart';
import 'package:pixes/foundation/novel_books.dart';
import 'package:pixes/foundation/novel_history.dart';
import 'package:pixes/foundation/novel_replace_store.dart';
import 'package:pixes/network/network.dart';
import 'package:pixes/pages/main_page.dart';
import 'package:pixes/pages/novel_book_page.dart';
import 'package:pixes/pages/novel_reading_page.dart';
import 'package:pixes/utils/translation.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await Translation.init();
    App.dataPath = Directory.systemTemp.createTempSync('pixes_books').path;
  });

  // Each test uses novels of its own ids, so the books don't get mixed up.
  final books = NovelBookStore.instance;
  final replace = NovelReplaceStore.instance;

  test('a novel survives being saved as JSON', () {
    final novel = _novel(1, series: 7, date: '2026-03-04T05:06:07+09:00');
    final copy = Novel.fromJson(jsonDecode(jsonEncode(novel.toJson())));
    expect(copy.id, 1);
    expect(copy.title, novel.title);
    expect(copy.createDate, novel.createDate);
    expect(copy.seriesId, 7);
    expect(copy.seriesTitle, 'Series 7');
    expect(copy.author.name, 'Author');
    expect(copy.tags.single.translatedName, 'tag');
    expect(copy.isAi, isFalse);
    expect(_novel(2).toJson()['series'], isNull);
  });

  group('mergeNovelChapters', () {
    test('orders new chapters by date', () {
      final result = mergeNovelChapters([], [
        _novel(3, date: '2026-01-03T00:00:00Z'),
        _novel(1, date: '2026-01-01T00:00:00Z'),
        _novel(2, date: '2026-01-02T00:00:00Z'),
      ]);
      expect(result.map((n) => n.id), [1, 2, 3]);
    });

    test('keeps the order of existing chapters and skips them', () {
      // Reordered by hand: 3 before 1.
      final existing = [
        _novel(3, date: '2026-01-03T00:00:00Z'),
        _novel(1, date: '2026-01-01T00:00:00Z'),
      ];
      final result = mergeNovelChapters(existing, [
        _novel(1, date: '2026-01-01T00:00:00Z'),
        _novel(4, date: '2026-01-04T00:00:00Z'),
        _novel(0, date: '2025-12-31T00:00:00Z'),
      ]);
      expect(result.map((n) => n.id), [0, 3, 1, 4]);
    });
  });

  test('suggests what the chapter titles share as the title', () {
    expect(suggestNovelBookTitle(['魔法少女の日常 1', '魔法少女の日常 2']), '魔法少女の日常');
    expect(suggestNovelBookTitle(['物語 第1話', '物語 第2話', '物語 第10話']), '物語');
    expect(suggestNovelBookTitle(['Story (1)', 'Story (2)']), 'Story');
    expect(suggestNovelBookTitle(['Alpha', 'Beta']), 'Alpha');
    expect(suggestNovelBookTitle(['Only']), 'Only');
  });

  test('merging novels makes a book their replacements apply to', () {
    final a = _novel(11, date: '2026-01-01T00:00:00Z');
    final b = _novel(12, date: '2026-01-02T00:00:00Z');
    final c = _novel(13, date: '2026-01-03T00:00:00Z');
    replace.add('novel:11', 'アリス', 'Alice');
    replace.add('novel:12', 'ボブ', 'Bob');
    // The same word in a later chapter loses.
    replace.add('novel:12', 'アリス', 'Arisu');

    final merge = NovelBookMerge([c, a, b]);
    expect(merge.target, isNull);
    expect(merge.chapters.map((n) => n.id), [11, 12, 13]);
    expect(
        merge.rules.map((r) => '${r.from}>${r.to}'), ['アリス>Alice', 'ボブ>Bob']);
    final book = merge.apply('Book');

    for (final novel in [a, b, c]) {
      expect(NovelReplaceStore.bookOf(novel), book.key);
    }
    expect(books.bookOf(12)?.title, 'Book');
    expect(replace.replacer(book.key).apply('アリスとボブ'), 'AliceとBob');

    // Splitting the book brings back the novels' own replacements.
    books.delete(book.id);
    expect(books.bookOf(11), isNull);
    expect(NovelReplaceStore.bookOf(a), 'novel:11');
    expect(replace.rules('novel:11').single.to, 'Alice');
    expect(replace.rules(book.key), isEmpty);
  });

  test('merging with a novel of a book adds to that book', () {
    final first = books.create('Saga', [
      _novel(21, date: '2026-01-01T00:00:00Z'),
      _novel(22, date: '2026-01-02T00:00:00Z'),
    ]);
    replace.add(first.key, 'x', 'y');
    final other =
        books.create('Side', [_novel(24, date: '2026-01-04T00:00:00Z')]);
    replace.add(other.key, 'p', 'q');
    final latest = _novel(23, date: '2026-01-03T00:00:00Z');

    final merge = NovelBookMerge(
        [books.bookOf(22)!.chapters[1], latest, other.chapters.single]);
    expect(merge.target?.id, first.id);
    expect(merge.absorbed.map((b) => b.id), [other.id]);
    expect(merge.suggestedTitle, 'Saga');
    final book = merge.apply('Saga');

    expect(book.id, first.id);
    expect(book.chapters.map((n) => n.id), [21, 22, 23, 24]);
    expect(books.get(other.id), isNull);
    expect(replace.rules(book.key).map((r) => r.from), ['x', 'p']);
    expect(replace.rules(other.key), isEmpty);

    // Saved to disk too.
    final db = sqlite3.open('${App.dataPath}/novel_books.db');
    addTearDown(db.dispose);
    expect(
      db.select(
          'select novel_id from book_chapters where book_id = ? order by position',
          [book.id]).map((row) => row['novel_id']),
      [21, 22, 23, 24],
    );
    expect(db.select('select id from books where id = ?', [other.id]), isEmpty);
  });

  test('changing chapters keeps the last read one only while it is there', () {
    final book = books.create('Book', [_novel(31), _novel(32), _novel(33)]);
    books.setLastRead(book.id, 32);
    expect(books.get(book.id)!.lastReadId, 32);

    final reordered =
        books.update(book.id, chapters: [_novel(33), _novel(32), _novel(31)]);
    expect(reordered.chapters.map((n) => n.id), [33, 32, 31]);
    expect(reordered.lastReadId, 32);

    final removed = books.update(book.id, chapters: [_novel(33), _novel(31)]);
    expect(removed.lastReadId, isNull);
    expect(books.bookOf(32), isNull);

    books.update(book.id, title: 'Renamed');
    expect(books.get(book.id)!.title, 'Renamed');

    // Taking every chapter out splits the book.
    books.update(book.id, chapters: const []);
    expect(books.get(book.id), isNull);
  });

  group('reader', () {
    late TitleBarController titleBarController;

    setUp(() {
      titleBarController =
          StateController.put<TitleBarController>(TitleBarController());
    });

    tearDown(() {
      Network.instance = null;
      StateController.remove<TitleBarController>();
    });

    testWidgets('reads the novels of a book as its chapters', (tester) async {
      final first = _novel(41, title: 'Part one');
      final second = _novel(42, title: 'Part two');
      final book = books.create('My Book', [first, second]);
      replace.add(book.key, 'Alice', 'Bob');
      Network().dio.httpClientAdapter = _ContentAdapter({
        41: _longText('Alice in part one.'),
        42: _longText('Alice in part two.'),
      });

      await tester.pumpWidget(FluentApp(home: NovelReadingPage(first)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('My Book · Chapter 1 of 2'), findsOneWidget);
      expect(
          find.text('Bob in part one. 0', findRichText: true), findsOneWidget);
      expect(
        titleBarController.actions.any((a) => a.title == 'Chapters'.tl),
        isTrue,
      );

      final position =
          tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      // The list is built lazily, so its end moves while getting there.
      for (var i = 0; i < 10 && find.text('Next').evaluate().isEmpty; i++) {
        position.jumpTo(position.maxScrollExtent);
        await tester.pump();
      }
      await tester.tap(find.text('Next'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('My Book · Chapter 2 of 2'), findsOneWidget);
      // The replacement applies to the whole book.
      expect(
          find.text('Bob in part two. 0', findRichText: true), findsOneWidget);

      final next =
          tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      next.jumpTo(400);
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));

      expect(books.get(book.id)!.lastReadId, 42);
      expect(
        NovelHistoryStore.instance.entries.take(2).map((e) => e.novel.id),
        [42, 41],
      );
    });
  });

  testWidgets('the merge dialog makes the book', (tester) async {
    final merge = NovelBookMerge([
      _novel(52, title: 'Tale 2', date: '2026-01-02T00:00:00Z'),
      _novel(51, title: 'Tale 1', date: '2026-01-01T00:00:00Z'),
    ]);
    NovelCustomBook? result;
    await tester.pumpWidget(FluentApp(
      home: Builder(
        builder: (context) => Button(
          onPressed: () async {
            result = await showNovelBookMergeDialog(context, merge);
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('1. Tale 1'), findsOneWidget);
    expect(find.text('2. Tale 2'), findsOneWidget);
    expect(
        tester.widget<TextBox>(find.byType(TextBox)).controller!.text, 'Tale');

    await tester.enterText(find.byType(TextBox), '  ');
    await tester.tap(find.text('Merge'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a title'), findsOneWidget);
    expect(result, isNull);

    await tester.enterText(find.byType(TextBox), 'Tales');
    await tester.tap(find.text('Merge'));
    await tester.pumpAndSettle();
    expect(result?.title, 'Tales');
    expect(books.bookOf(51)?.id, result!.id);
  });
}

Novel _novel(int id,
    {String? title, int? series, String date = '2026-01-01T00:00:00+00:00'}) {
  return Novel.fromJson({
    "id": id,
    "title": title ?? "Novel $id",
    "caption": "",
    "is_original": true,
    "image_urls": {"large": ""},
    "create_date": date,
    "tags": [
      {"name": "タグ", "translated_name": "tag"},
    ],
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

String _longText(String line) =>
    List.generate(80, (index) => '$line $index').join('\n');

/// Serves the content of each novel by its id.
class _ContentAdapter implements HttpClientAdapter {
  _ContentAdapter(this.contents);

  final Map<int, String> contents;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final id = int.parse(options.uri.queryParameters['id']!);
    final body =
        '<script>novel: ${jsonEncode({"text": contents[id]})}</script>';
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
