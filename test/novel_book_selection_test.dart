import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixes/foundation/app.dart';
import 'package:pixes/foundation/novel_books.dart';
import 'package:pixes/foundation/novel_replace_store.dart';
import 'package:pixes/network/network.dart';
import 'package:pixes/pages/novel_book_page.dart';
import 'package:pixes/pages/user_info_page.dart';
import 'package:pixes/utils/translation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await Translation.init();
    App.dataPath = Directory.systemTemp.createTempSync('pixes_select').path;
  });

  setUp(() {
    Network().dio.httpClientAdapter = _UserAdapter([
      _novel(3, 'Journey 3', '2026-01-03T00:00:00Z'),
      _novel(2, 'Journey 2', '2026-01-02T00:00:00Z'),
      _novel(1, 'Journey 1', '2026-01-01T00:00:00Z'),
    ]);
  });

  tearDown(() {
    Network.instance = null;
  });

  final books = NovelBookStore.instance;

  testWidgets('novels selected on the author page are merged into a book',
      (tester) async {
    // The test font is wider than real ones.
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    NovelReplaceStore.instance.add('novel:1', 'old', 'new');
    // Pictures can't be loaded in tests, and the avatar reports it.
    final onError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.library != 'image resource service') onError?.call(details);
    };

    await tester.pumpWidget(const FluentApp(home: UserInfoPage('1')));
    await _settle(tester);
    await tester.tap(find.text('Novels'));
    await _settle(tester);
    expect(find.text('Journey 1'), findsOneWidget);

    // A long press starts selecting with that novel.
    await tester.longPress(find.text('Journey 3'));
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);
    await tester.tap(find.text('Journey 3'));
    await tester.pump();
    expect(find.text('Select novels to read as one book'), findsOneWidget);

    await tester.tap(find.text('Select All'));
    await tester.pump();
    expect(find.text('3 selected'), findsOneWidget);
    await tester.tap(find.text('Journey 2'));
    await tester.pump();
    expect(find.text('2 selected'), findsOneWidget);

    await tester.tap(find.text('Merge'));
    await tester.pumpAndSettle();
    expect(find.text('1. Journey 1'), findsOneWidget);
    expect(find.text('2. Journey 3'), findsOneWidget);
    expect(
        find.text('The 1 word replacements of these novels now apply to the '
            'whole book.'),
        findsOneWidget);
    await tester.tap(find.text('Merge').last);
    await _settle(tester);

    final book = books.bookOf(1)!;
    expect(book.title, 'Journey');
    expect(book.chapters.map((n) => n.id), [1, 3]);
    expect(books.bookOf(2), isNull);
    expect(NovelReplaceStore.instance.rules(book.key).single.to, 'new');
    expect(find.byType(NovelBookPage), findsOneWidget);
    expect(find.text('2 chapters · 200 chars'), findsOneWidget);

    // Adding a chapter later starts with the book's chapters selected.
    await tester.tap(find.text('Add Chapters'));
    await _settle(tester);
    expect(find.text('2 selected'), findsOneWidget);
    await tester.tap(find.text('Journey 2'));
    await tester.pump();
    await tester.tap(find.text('Merge'));
    await tester.pumpAndSettle();
    expect(find.text('Added to the book Journey'), findsOneWidget);
    await tester.tap(find.text('Merge').last);
    await _settle(tester);

    expect(books.get(book.id)!.chapters.map((n) => n.id), [1, 2, 3]);
    // Back on the book's page.
    expect(find.byType(UserInfoPage), findsNothing);
    expect(find.text('3 chapters · 300 chars'), findsOneWidget);
    FlutterError.onError = onError;
  });
}

/// Pumps long enough for the pictures, which can't be loaded in tests, to
/// give up retrying while they're on screen to handle the error.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
}

Map<String, dynamic> _novel(int id, String title, String date) => {
      "id": id,
      "title": title,
      "caption": "",
      "is_original": true,
      "image_urls": {"large": ""},
      "create_date": date,
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
      "series": null,
      "is_bookmarked": false,
      "total_bookmarks": 0,
      "total_view": 0,
      "total_comments": 0,
      "novel_ai_type": 0,
    };

/// Serves the details, related users and works of user 1.
class _UserAdapter implements HttpClientAdapter {
  _UserAdapter(this.novels);

  final List<Map<String, dynamic>> novels;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final Object body = switch (options.uri.path) {
      "/v1/user/detail" => {
          "user": {
            "id": 1,
            "name": "Author",
            "account": "author",
            "profile_image_urls": {"medium": ""},
            "comment": "",
            "is_followed": false,
            "is_access_blocking_user": false,
          },
          "profile": {
            "webpage": null,
            "gender": "",
            "birth": "",
            "region": "",
            "job": "",
            "total_follow_users": 0,
            "total_mypixiv_users": 0,
            "total_illusts": 0,
            "total_manga": 0,
            "total_novels": novels.length,
            "total_illust_bookmarks_public": 0,
            "background_image_url": null,
            "twitter_url": null,
            "is_premium": false,
            "pawoo_url": null,
          },
        },
      "/v1/user/novels" => {"novels": novels, "next_url": null},
      _ => {
          "illusts": <Object>[],
          "user_previews": <Object>[],
          "next_url": null
        },
    };
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
