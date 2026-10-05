import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixes/foundation/app.dart';
import 'package:pixes/foundation/novel_replace_store.dart';
import 'package:pixes/network/network.dart';
import 'package:pixes/pages/main_page.dart';
import 'package:pixes/pages/novel_reading_page.dart';
import 'package:pixes/pages/novel_replace_page.dart';
import 'package:pixes/utils/novel_markup.dart';
import 'package:pixes/utils/novel_replace.dart';
import 'package:pixes/utils/translation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NovelTextReplacer', () {
    NovelReplaceRule rule(int id, String from, String to,
        {bool enabled = true}) {
      return NovelReplaceRule(id: id, from: from, to: to, enabled: enabled);
    }

    test('replaces every rule in one pass', () {
      final replacer = NovelTextReplacer([
        rule(1, 'アリス', 'Alice'),
        rule(2, 'Alice', 'Bob'),
        rule(3, 'ボブ', ''),
      ]);
      // Text put in by a rule isn't replaced again, whatever the order.
      expect(replacer.apply('アリスとボブとAlice'), 'AliceととBob');
    });

    test('prefers the longest word', () {
      final replacer = NovelTextReplacer([
        rule(1, 'アリス', 'A'),
        rule(2, 'アリスさん', 'Ms. A'),
      ]);
      expect(replacer.apply('アリスさんとアリス'), 'Ms. AとA');
      expect(
        replacer.matches('アリスさんとアリス').map((m) => m.rule.id),
        [2, 1],
      );
    });

    test('skips disabled and empty rules and escapes the words', () {
      final replacer = NovelTextReplacer([
        rule(1, 'a', 'x', enabled: false),
        rule(2, '', 'y'),
        rule(3, '(.*)', 'z'),
      ]);
      expect(replacer.apply('a (.*) b'), 'a z b');
      expect(NovelTextReplacer([rule(1, 'a', 'b', enabled: false)]).isEmpty,
          isTrue);
    });
  });

  test('replaces the text of blocks but leaves markup alone', () {
    final blocks = parseNovelContent([
      '[chapter:アリスの話]',
      'アリスは[[rb:アリス > ありす]]で[[jumpuri:アリス > https://example.com/アリス]]',
      '[uploadedimage:1]',
    ].join('\n'));
    final replacer = NovelTextReplacer(
        const [NovelReplaceRule(id: 1, from: 'アリス', to: 'Alice')]);
    final replaced = replaceNovelBlocks(blocks, replacer);

    expect(replaced, hasLength(blocks.length));
    expect(novelInlinesText(novelBlockInlines(replaced[0])!), 'Aliceの話');
    final inlines = novelBlockInlines(replaced[1])!;
    expect(novelInlinesText(inlines), 'AliceはAliceでAlice');
    expect((inlines[1] as NovelRuby).ruby, 'ありす');
    expect((inlines[3] as NovelLink).url, 'https://example.com/アリス');
    expect(identical(replaced[2], blocks[2]), isTrue);

    final matches =
        novelInlineMatches(novelBlockInlines(blocks[1])!, replacer).toList();
    expect(
        [for (final m in matches) (m.start, m.end)], [(0, 3), (4, 7), (8, 11)]);
    expect(
        identical(replaceNovelBlocks(blocks, NovelTextReplacer.empty), blocks),
        isTrue);
  });

  test('cuts the text around a match', () {
    final text = '${'a' * 30}MATCH${'b' * 60}';
    final excerpt = novelTextExcerpt(text, 30, 35, before: 5, after: 5);
    expect(excerpt.before, '…aaaaa');
    expect(excerpt.match, 'MATCH');
    expect(excerpt.after, 'bbbbb…');
    final whole = novelTextExcerpt('xMy', 1, 2);
    expect((whole.before, whole.after), ('x', 'y'));
  });

  group('pages', () {
    setUpAll(() async {
      await Translation.init();
      App.dataPath =
          Directory.systemTemp.createTempSync('pixes_novel_replace').path;
    });

    setUp(() {
      StateController.put<TitleBarController>(TitleBarController());
    });

    tearDown(() {
      Network.instance = null;
      StateController.remove<TitleBarController>();
      final store = NovelReplaceStore.instance;
      for (final book in ['novel:40', 'novel:41', 'series:7']) {
        for (final rule in store.rules(book)) {
          store.remove(book, rule);
        }
      }
    });

    Future<void> pumpFor(WidgetTester tester, Duration duration) async {
      for (var t = Duration.zero; t < duration; t += _frame) {
        await tester.pump(_frame);
      }
    }

    Future<void> close(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('the reader shows the replaced text', (tester) async {
      final store = NovelReplaceStore.instance;
      final rule = store.add('novel:40', 'Alice', 'アリス');
      expect(store.rules('novel:40'), [rule]);
      Network().dio.httpClientAdapter =
          _NovelAdapter({40: 'Alice met Bob.\nBob left.'});
      await tester.pumpWidget(FluentApp(home: NovelReadingPage(_novel(40))));
      await pumpFor(tester, const Duration(milliseconds: 300));

      expect(find.text('アリス met Bob.'), findsOneWidget);
      expect(find.textContaining('Alice'), findsNothing);

      // Changes show up straight away.
      store.update('novel:40', rule.copyWith(enabled: false));
      await tester.pump();
      expect(find.text('Alice met Bob.'), findsOneWidget);
      store.add('novel:40', 'Bob', '');
      await tester.pump();
      expect(find.text('Alice met .'), findsOneWidget);
      expect(find.text(' left.'), findsOneWidget);
      await close(tester);
    });

    testWidgets('the reader opens at the given block', (tester) async {
      final content = List.generate(200, (i) => 'Line $i').join('\n');
      Network().dio.httpClientAdapter = _NovelAdapter({41: content});
      await tester.pumpWidget(
          FluentApp(home: NovelReadingPage(_novel(41), initialBlock: 150)));
      await pumpFor(tester, const Duration(milliseconds: 600));

      final position =
          tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      expect(position.pixels, greaterThan(0));
      final scrollable = tester.getRect(find.byType(Scrollable).first);
      final line = tester.getRect(find.text('Line 150'));
      expect(line.top, closeTo(scrollable.top, 1));
      expect(find.textContaining('Last read'), findsNothing);
      await close(tester);
    });

    testWidgets('manages, searches and details the replacements of a series',
        (tester) async {
      Network().dio.httpClientAdapter = _NovelAdapter({
        1: 'アリスは森へ行った。\nそこでアリスさんに会った。',
        2: 'ボブとアリス。',
      }, series: [
        _novel(1, seriesId: 7),
        _novel(2, seriesId: 7)
      ]);
      await tester.pumpWidget(
          FluentApp(home: NovelReplacePage(_novel(1, seriesId: 7))));
      await tester.pump();
      expect(find.text('No replacements yet'), findsOneWidget);

      // Add one.
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextBox);
      await tester.enterText(fields.at(0), 'アリス');
      // Enter moves on to the replacement instead of removing the word.
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pump();
      expect(NovelReplaceStore.instance.rules('series:7'), isEmpty);
      await tester.enterText(fields.at(1), 'Alice');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final rules = NovelReplaceStore.instance.rules('series:7');
      expect(rules.map((r) => (r.from, r.to)), [('アリス', 'Alice')]);
      expect(find.text('アリス  →  Alice', findRichText: true), findsOneWidget);

      // The same word can't be added twice.
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextBox).at(0), 'アリス');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('This text already has a replacement'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // Count it in every chapter.
      await tester.tap(find.text('Count the occurrences in the whole book'));
      await tester.pumpAndSettle();
      expect(find.text('3 places'), findsOneWidget);

      // Search the whole book, before and after replacing.
      await tester.tap(find.text('Full-text Search'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextBox), 'アリス');
      await tester.tap(find.text('Search'));
      await tester.pumpAndSettle();
      expect(find.text('3 results'), findsOneWidget);
      expect(find.textContaining('Chapter 2 · Novel 2'), findsOneWidget);
      expect(find.text('Edit Replacement'), findsOneWidget);
      await tester.tap(find.text('Search the replaced text'));
      await tester.pumpAndSettle();
      expect(find.text('No results found'), findsOneWidget);

      // The details list where it's replaced.
      await tester.tap(find.text('Replacements'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('3 places'));
      await tester.pumpAndSettle();
      expect(find.text('Replacement Details'), findsOneWidget);
      expect(find.text('3 places in 2 chapters'), findsOneWidget);
      expect(find.textContaining('Chapter 1 · Novel 1'), findsOneWidget);

      // Disabling it keeps showing what it would replace.
      await tester.tap(find.text('Enabled'));
      await tester.pumpAndSettle();
      expect(
          NovelReplaceStore.instance.rules('series:7').single.enabled, isFalse);
      expect(
          find.textContaining('This replacement is disabled'), findsOneWidget);
      expect(find.text('3 places in 2 chapters'), findsOneWidget);

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(NovelReplaceStore.instance.rules('series:7'), isEmpty);
      expect(find.text('No replacements yet'), findsOneWidget);
      await close(tester);
    });
  });
}

const _frame = Duration(milliseconds: 16);

Novel _novel(int id, {int? seriesId}) {
  return Novel.fromJson({
    "id": id,
    "title": "Novel $id",
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
    "series": seriesId == null ? null : {"id": seriesId, "title": "Series"},
    "is_bookmarked": false,
    "total_bookmarks": 0,
    "total_view": 0,
    "total_comments": 0,
    "novel_ai_type": 0,
  });
}

/// Serves the contents of novels by id, and a series made of [series].
class _NovelAdapter implements HttpClientAdapter {
  _NovelAdapter(this.contents, {this.series = const []});

  final Map<int, String> contents;

  final List<Novel> series;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    if (uri.path == '/v2/novel/series') {
      return ResponseBody.fromString(
        jsonEncode({
          "novels": [
            for (final novel in series)
              {
                "id": novel.id,
                "title": novel.title,
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
                "series": {"id": novel.seriesId, "title": "Series"},
                "is_bookmarked": false,
                "total_bookmarks": 0,
                "total_view": 0,
                "total_comments": 0,
                "novel_ai_type": 0,
              },
          ],
          "next_url": null,
        }),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    final id = int.parse(uri.queryParameters["id"]!);
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
