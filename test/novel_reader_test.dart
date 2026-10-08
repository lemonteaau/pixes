import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixes/appdata.dart';
import 'package:pixes/foundation/app.dart';
import 'package:pixes/foundation/novel_progress.dart';
import 'package:pixes/network/network.dart';
import 'package:pixes/pages/main_page.dart';
import 'package:pixes/pages/novel_reading_page.dart';
import 'package:pixes/utils/translation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await Translation.init();
    App.dataPath = Directory.systemTemp.createTempSync('pixes_novel').path;
  });

  late TitleBarController titleBarController;

  setUp(() {
    appdata.settings["readingAutoScrollSpeed"] = 40.0;
    appdata.settings["readingKeepScreenOnDuringAutoScroll"] = false;
    titleBarController =
        StateController.put<TitleBarController>(TitleBarController());
  });

  tearDown(() {
    appdata.settings["readingKeepScreenOnDuringAutoScroll"] = true;
    Network.instance = null;
    StateController.remove<TitleBarController>();
  });

  Future<ScrollPosition> open(WidgetTester tester, Novel novel,
      {String? content, bool resume = false, List<Novel>? series}) async {
    Network().dio.httpClientAdapter = _NovelContentAdapter(
        content ?? _longNovelContent,
        series: series);
    await tester.pumpWidget(
      FluentApp(home: NovelReadingPage(novel, resume: resume)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return tester.state<ScrollableState>(find.byType(Scrollable).first).position;
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> pumpFor(WidgetTester tester, Duration duration) async {
    for (var t = Duration.zero; t < duration; t += _frame) {
      await tester.pump(_frame);
    }
  }

  /// Jumps to just before the end. The list only knows where it ends once
  /// its last items are built.
  Future<void> nearEnd(WidgetTester tester, ScrollPosition position) async {
    for (var i = 0; i < 20; i++) {
      final end = position.maxScrollExtent;
      position.jumpTo(end);
      await tester.pump();
      if (position.maxScrollExtent == end) break;
    }
    position.jumpTo(position.maxScrollExtent - 1);
  }

  testWidgets('dragging keeps auto scroll going, tapping pauses it',
      (tester) async {
    final position = await open(tester, _testNovel(10));
    _action(titleBarController, 'Auto Scroll').onPressed();
    await pumpFor(tester, const Duration(milliseconds: 500));
    expect(position.pixels, greaterThan(0));

    // Scrolling by hand doesn't stop auto scroll, and it doesn't fight the
    // finger while it's down.
    final center = tester.getCenter(find.byType(NovelReadingPage));
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(0, -200));
    await tester.pump(_frame);
    final held = position.pixels;
    await pumpFor(tester, const Duration(milliseconds: 500));
    expect(position.pixels, held);
    await gesture.up();
    await pumpFor(tester, const Duration(seconds: 2));
    expect(_hasAction(titleBarController, 'Pause'), isTrue);
    final afterDrag = position.pixels;
    await pumpFor(tester, const Duration(seconds: 1));
    expect(position.pixels - afterDrag, closeTo(40, 2));
    expect(find.byKey(const ValueKey('novel-auto-scroll-resume')),
        findsNothing);

    // A tap pauses and shows the controls.
    await tester.tapAt(center);
    await tester.pump();
    expect(_hasAction(titleBarController, 'Auto Scroll'), isTrue);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('novel-auto-scroll-resume')),
        findsOneWidget);
    final paused = position.pixels;
    await pumpFor(tester, const Duration(milliseconds: 500));
    expect(position.pixels, paused);

    await tester.tap(find.byKey(const ValueKey('novel-auto-scroll-faster')));
    await tester.pump();
    expect(appdata.settings["readingAutoScrollSpeed"], 50.0);

    await tester.tap(find.byKey(const ValueKey('novel-auto-scroll-resume')));
    await tester.pump();
    expect(_hasAction(titleBarController, 'Pause'), isTrue);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('novel-auto-scroll-resume')),
        findsNothing);
    final resumed = position.pixels;
    await pumpFor(tester, const Duration(seconds: 1));
    expect(position.pixels - resumed, closeTo(50, 2));

    // Tapping while paused just hides the controls again.
    await tester.tapAt(center);
    await pumpFor(tester, const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('novel-auto-scroll-resume')),
        findsOneWidget);
    await tester.tapAt(center);
    await pumpFor(tester, const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('novel-auto-scroll-resume')),
        findsNothing);
    expect(_hasAction(titleBarController, 'Auto Scroll'), isTrue);

    await close(tester);
  });

  testWidgets('a tap brings the auto scroll controls back until closed',
      (tester) async {
    final position = await open(tester, _testNovel(11));
    final resume = find.byKey(const ValueKey('novel-auto-scroll-resume'));
    final center = tester.getCenter(find.byType(NovelReadingPage));

    // Without auto scroll, a tap shows nothing.
    await tester.tapAt(center);
    await pumpFor(tester, const Duration(milliseconds: 300));
    expect(resume, findsNothing);

    _action(titleBarController, 'Auto Scroll').onPressed();
    await pumpFor(tester, const Duration(milliseconds: 500));
    await tester.tapAt(center);
    await pumpFor(tester, const Duration(milliseconds: 300));
    expect(resume, findsOneWidget);

    // Paused, taps keep showing and hiding the controls.
    for (final shown in [false, true, false, true]) {
      await tester.tapAt(center);
      await pumpFor(tester, const Duration(milliseconds: 300));
      expect(resume, shown ? findsOneWidget : findsNothing);
    }

    // Pausing from the title bar shows them too.
    await tester.tap(resume);
    await pumpFor(tester, const Duration(milliseconds: 300));
    expect(resume, findsNothing);
    _action(titleBarController, 'Pause').onPressed();
    await pumpFor(tester, const Duration(milliseconds: 300));
    expect(resume, findsOneWidget);

    // Closing them leaves auto scroll until it's started again.
    await tester.tap(find.byKey(const ValueKey('novel-auto-scroll-close')));
    await pumpFor(tester, const Duration(milliseconds: 300));
    expect(resume, findsNothing);
    final stopped = position.pixels;
    await tester.tapAt(center);
    await pumpFor(tester, const Duration(milliseconds: 500));
    expect(resume, findsNothing);
    expect(position.pixels, stopped);
    expect(_hasAction(titleBarController, 'Auto Scroll'), isTrue);

    await close(tester);
  });

  testWidgets('auto scroll moves on to the next chapter', (tester) async {
    appdata.settings["readingAutoNextChapterDelay"] = 2;
    addTearDown(() => appdata.settings["readingAutoNextChapterDelay"] = 5);
    final series = [
      _testNovel(41, seriesId: 4, title: 'Chapter One'),
      _testNovel(42, seriesId: 4, title: 'Chapter Two'),
    ];
    var position = await open(tester, series[0], series: series);
    final prompt = find.byKey(const ValueKey('next-chapter-prompt'));

    // Cancelling stays on the chapter.
    await nearEnd(tester, position);
    _action(titleBarController, 'Auto Scroll').onPressed();
    await pumpFor(tester, const Duration(milliseconds: 300));
    expect(prompt, findsOneWidget);
    expect(find.text('Next chapter in 2 s'), findsOneWidget);
    expect(find.text('Chapter Two'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('novel-next-chapter-cancel')));
    await pumpFor(tester, const Duration(seconds: 3));
    expect(prompt, findsNothing);
    expect(find.text('1 / 2'), findsOneWidget);
    expect(_hasAction(titleBarController, 'Auto Scroll'), isTrue);

    // Scrolling back up keeps auto scrolling from there.
    _action(titleBarController, 'Auto Scroll').onPressed();
    await pumpFor(tester, const Duration(milliseconds: 300));
    expect(prompt, findsOneWidget);
    final center = tester.getCenter(find.byType(NovelReadingPage));
    await tester.dragFrom(center, const Offset(0, 300));
    await pumpFor(tester, const Duration(seconds: 1));
    expect(prompt, findsNothing);
    expect(_hasAction(titleBarController, 'Pause'), isTrue);

    // Otherwise the countdown runs out and the next chapter scrolls on.
    await nearEnd(tester, position);
    await pumpFor(tester, const Duration(milliseconds: 300));
    expect(prompt, findsOneWidget);
    await pumpFor(tester, const Duration(seconds: 1));
    expect(find.text('Next chapter in 1 s'), findsOneWidget);
    await pumpFor(tester, const Duration(milliseconds: 1500));
    expect(find.text('Chapter Two'), findsOneWidget);
    expect(find.textContaining('Chapter 2 of 2'), findsOneWidget);
    position =
        tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    expect(_hasAction(titleBarController, 'Pause'), isTrue);
    expect(find.textContaining('Last read'), findsNothing);
    final start = position.pixels;
    expect(start, lessThan(100));
    await pumpFor(tester, const Duration(seconds: 1));
    expect(position.pixels - start, closeTo(40, 2));

    // The last chapter just stops.
    await nearEnd(tester, position);
    await pumpFor(tester, const Duration(milliseconds: 500));
    expect(prompt, findsNothing);
    expect(_hasAction(titleBarController, 'Auto Scroll'), isTrue);
    await pumpFor(tester, const Duration(seconds: 3));

    await close(tester);
  });

  test('uses the image URLs the novel page comes with', () async {
    final adapter = _NovelContentAdapter('[uploadedimage:7]', extra: {
      "images": {
        "7": {
          "novelImageId": "7",
          "sl": "0",
          "urls": {
            "480mw": "https://i.pximg.net/c/480x960/novel-cover/7.jpg",
            "original": "https://i.pximg.net/novel-cover-original/7.png",
          },
        },
      },
      "illusts": {
        "100": {
          "illust": {
            "images": {"original": "https://i.pximg.net/img-original/100.jpg"},
          },
        },
        "200-3": {
          "illust": {
            "images": {
              "medium": "https://i.pximg.net/c/540x540/img-master/200_p2.jpg",
            },
          },
        },
      },
    });
    Network().dio.httpClientAdapter = adapter;

    expect((await Network().getNovelImage('50', '7')).data,
        'https://i.pximg.net/novel-cover-original/7.png');
    expect(adapter.requests, 1);
    expect(Network().novelIllustUrl('50', '100', 0),
        'https://i.pximg.net/img-original/100.jpg');
    expect(Network().novelIllustUrl('50', '200', 2),
        'https://i.pximg.net/c/540x540/img-master/200_p2.jpg');
    expect(Network().novelIllustUrl('50', '200', 0), isNull);

    // Pages without images send `[]`.
    Network().dio.httpClientAdapter =
        _NovelContentAdapter('text', extra: {"images": [], "illusts": []});
    expect((await Network().getNovelContent('51')).data, 'text');
  });

  testWidgets('remembers the reading position', (tester) async {
    final novel = _testNovel(20);
    var position = await open(tester, novel);
    expect(NovelProgressStore.instance.get(20), isNull);

    // Opening without scrolling saves nothing.
    await close(tester);
    expect(NovelProgressStore.instance.get(20), isNull);

    position = await open(tester, novel);
    position.jumpTo(3000);
    await tester.pump();
    await close(tester);
    final saved = NovelProgressStore.instance.get(20);
    expect(saved, isNotNull);
    expect(saved!.item, greaterThan(1));
    expect(saved.progress, inExclusiveRange(0.0, 1.0));

    // Reopening offers to continue.
    position = await open(tester, novel);
    await tester.pump(const Duration(milliseconds: 300));
    expect(position.pixels, 0);
    expect(find.textContaining('Last read'), findsOneWidget);
    await tester.tap(find.text('Continue Reading'));
    await pumpFor(tester, const Duration(milliseconds: 500));
    expect(position.pixels, closeTo(3000, 1));
    expect(find.textContaining('Last read'), findsNothing);
    await close(tester);

    // Resuming goes straight there.
    position = await open(tester, novel, resume: true);
    await pumpFor(tester, const Duration(milliseconds: 500));
    expect(position.pixels, closeTo(3000, 1));
    expect(find.textContaining('Last read'), findsNothing);
    await close(tester);
  });

  testWidgets('renders pixiv markup instead of showing it', (tester) async {
    final content = [
      '[chapter:Opening]',
      'Some [[rb:漢字 > かんじ]] here.',
      '',
      '[newpage]',
      'Go back to [jump:1].',
    ].join('\n');
    await open(tester, _testNovel(30), content: content);

    expect(find.textContaining('[newpage]'), findsNothing);
    expect(find.textContaining('[[rb'), findsNothing);
    expect(find.textContaining('[chapter'), findsNothing);
    expect(find.text('Opening'), findsOneWidget);
    expect(find.text('かんじ'), findsOneWidget);
    expect(find.text('漢字'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.textContaining('Jump to page 1', findRichText: true),
        findsOneWidget);
    await close(tester);
  });
}

const _frame = Duration(milliseconds: 16);

bool _hasAction(TitleBarController controller, String title) {
  return controller.actions.any((action) => action.title == title.tl);
}

TitleBarAction _action(TitleBarController controller, String title) {
  return controller.actions.singleWhere((action) => action.title == title.tl);
}

Novel _testNovel(int id, {int? seriesId, String title = "Test Novel"}) {
  return Novel.fromJson(_novelJson(id, seriesId: seriesId, title: title));
}

Map<String, dynamic> _novelJson(int id,
    {int? seriesId, String title = "Test Novel"}) {
  return {
    "id": id,
    "title": title,
    "caption": "",
    "is_original": true,
    "image_urls": {"large": ""},
    "create_date": "2026-01-01T00:00:00+00:00",
    "tags": <Object>[],
    "page_count": 1,
    "text_length": _longNovelContent.length,
    "user": {
      "id": 1,
      "name": "Author",
      "account": "author",
      "profile_image_urls": {"medium": ""},
      "is_followed": false,
    },
    "series":
        seriesId == null ? null : {"id": seriesId, "title": "Test Series"},
    "is_bookmarked": false,
    "total_bookmarks": 0,
    "total_view": 0,
    "total_comments": 0,
    "novel_ai_type": 0,
  };
}

final String _longNovelContent = List.generate(
  200,
  (index) => 'Paragraph $index with enough text to keep the reader scrolling.',
).join('\n');

class _NovelContentAdapter implements HttpClientAdapter {
  _NovelContentAdapter(this.content, {this.series, this.extra = const {}});

  final String content;

  /// More fields of the novel page.
  final Map<String, dynamic> extra;

  int requests = 0;

  /// The episodes of the series the novel belongs to.
  final List<Novel>? series;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path.endsWith('/novel/series')) {
      return ResponseBody.fromString(
        jsonEncode({
          "novels": [
            for (final novel in series ?? const <Novel>[])
              _novelJson(novel.id,
                  seriesId: novel.seriesId, title: novel.title),
          ],
          "next_url": null,
        }),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    requests++;
    final novel = jsonEncode({"text": content, ...extra});
    final body = '<script>novel: $novel</script>';
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
