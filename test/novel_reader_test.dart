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
      {String? content, bool resume = false}) async {
    Network().dio.httpClientAdapter =
        _NovelContentAdapter(content ?? _longNovelContent);
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

Novel _testNovel(int id) {
  return Novel.fromJson({
    "id": id,
    "title": "Test Novel",
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
    "series": null,
    "is_bookmarked": false,
    "total_bookmarks": 0,
    "total_view": 0,
    "total_comments": 0,
    "novel_ai_type": 0,
  });
}

final String _longNovelContent = List.generate(
  200,
  (index) => 'Paragraph $index with enough text to keep the reader scrolling.',
).join('\n');

class _NovelContentAdapter implements HttpClientAdapter {
  _NovelContentAdapter(this.content);

  final String content;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = '<script>novel: ${jsonEncode({"text": content})}</script>';
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
