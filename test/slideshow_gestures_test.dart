import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixes/appdata.dart';
import 'package:pixes/foundation/app.dart';
import 'package:pixes/foundation/slideshow/slideshow_controller.dart';
import 'package:pixes/network/models.dart';
import 'package:pixes/network/res.dart';
import 'package:pixes/pages/slideshow_page.dart';
import 'package:pixes/utils/translation.dart';

import 'slideshow_test.dart' show artwork;

class _ImageLoad implements SlideLoad<ui.Image> {
  _ImageLoad(ui.Image source) : image = source.clone();
  final ui.Image image;
  @override
  Future<ui.Image> get ready => Future.value(image);
  @override
  void dispose() {
    WidgetsBinding.instance.addPostFrameCallback((_) => image.dispose());
  }
}

Future<void> settlePaging(WidgetTester tester) async {
  var settledFrames = 0;
  for (var i = 0; i < 100; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    final moving = tester
        .stateList<ScrollableState>(find.byType(Scrollable))
        .any((state) => state.position.isScrollingNotifier.value);
    settledFrames = moving ? 0 : settledFrames + 1;
    if (settledFrames >= 4) return;
  }
  fail('The pagers did not settle');
}

void main() {
  late ui.Image source;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await Translation.init();
    // Changing playback settings saves them.
    App.dataPath = Directory.systemTemp.createTempSync('pixes-test').path;
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(const ui.Rect.fromLTWH(0, 0, 64, 96),
        ui.Paint()..color = const ui.Color(0xff335577));
    final picture = recorder.endRecording();
    source = await picture.toImage(64, 96);
    picture.dispose();
  });
  tearDownAll(() => source.dispose());
  setUp(() {
    appdata.settings['language'] = '简体中文';
    appdata.settings['blockTags'] = [];
    // Gesture tests supply decoded originals and must not fetch thumbnails.
    final thumbnails = appdata.settings['slideshowShowThumbnailWhileLoading'];
    appdata.settings['slideshowShowThumbnailWhileLoading'] = false;
    addTearDown(() {
      appdata.settings['slideshowShowThumbnailWhileLoading'] = thumbnails;
    });
  });

  SlideshowController<ui.Image> newController(WidgetTester tester) =>
      SlideshowController<ui.Image>(
        initialIllusts: [artwork(1), artwork(2, pages: 2), artwork(3)],
        nextUrl: null,
        loadPage: (_) async => const Res([]),
        loadImage: (_) => _ImageLoad(source),
        now: tester.binding.clock.now,
      );

  Future<SlideshowController<ui.Image>> showViewer(WidgetTester tester,
      {bool playing = true,
      Object? resumeKey,
      Future<Res<bool>> Function(Illust, bool)? bookmark}) async {
    final controller = newController(tester)..playing = playing;
    await tester.pumpWidget(FluentApp(
      home: SlideshowPage(
        illusts: const [],
        nextUrl: null,
        source: '推荐',
        controller: controller,
        setBookmark: bookmark,
        resumeKey: resumeKey,
      ),
    ));
    await tester.pump();
    await tester.pump();
    return controller;
  }

  testWidgets(
      'vertical swipes change works; horizontal swipes change only their images',
      (tester) async {
    final controller = await showViewer(tester, playing: false);
    final surface = find.byKey(const ValueKey('slideshow-gestures'));
    await tester.drag(surface, const Offset(0, -400));
    await settlePaging(tester);
    expect(controller.current!.illust.id, 2);
    expect(controller.current!.page, 0);
    expect(find.text('1 / 2'), findsOneWidget);
    await tester.drag(surface, const Offset(-500, 0));
    await settlePaging(tester);
    expect(controller.current!.illust.id, 2);
    expect(controller.current!.page, 1);
    expect(find.text('2 / 2'), findsOneWidget);
    await tester.drag(surface, const Offset(0, -400));
    await settlePaging(tester);
    expect(controller.current!.illust.id, 3);
    await tester.drag(surface, const Offset(0, 400));
    await settlePaging(tester);
    expect(controller.current!.illust.id, 2);
    expect(controller.current!.page, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets(
      'manual swipe near the deadline restarts the clock after settling',
      (tester) async {
    final controller = await showViewer(tester);
    await tester.pump(const Duration(milliseconds: 4700));
    final gesture = await tester.startGesture(const Offset(400, 300));
    // Hold past the deadline but shorter than a long press, which opens the
    // more-actions sheet instead.
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.current!.illust.id, 1);
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(0, -320));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.up();
    await settlePaging(tester);
    expect(controller.currentIndex, 1);
    expect(controller.remaining.inMilliseconds, greaterThan(4100));
    expect(controller.playing, isTrue);
    expect(controller.countdownRunning, isTrue,
        reason: "clock should resume after settling");
    await tester.pump(const Duration(seconds: 3));
    expect(controller.currentIndex, 1);
    await tester.pump(const Duration(seconds: 2));
    await settlePaging(tester);
    expect(controller.currentIndex, 2);
    expect(find.text('2 / 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('single tap pauses and resumes; progress runs along the bottom',
      (tester) async {
    final controller = await showViewer(tester);
    await tester.pump(const Duration(seconds: 2));
    await tester.tapAt(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.playing, isFalse);
    expect(find.byKey(const ValueKey('slideshow-paused')), findsOneWidget);
    final frozen = controller.remaining;
    final barFinder = find.byKey(const ValueKey('slideshow-progress'));
    final bar = tester.widget<CustomPaint>(barFinder).painter!
        as SlideshowProgressPainter;
    expect(bar.progress, closeTo(0.4, 0.03));
    expect(bar.paused, isTrue);
    expect(tester.getSize(barFinder).width, 800);
    expect(tester.getCenter(barFinder).dy, greaterThan(590));
    await tester.pump(const Duration(seconds: 10));
    expect(controller.remaining, frozen);
    expect(controller.currentIndex, 0);
    await tester.tapAt(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.playing, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('double tap bookmarks once without pausing or unbookmarking',
      (tester) async {
    var calls = 0;
    final response = Completer<Res<bool>>();
    final controller = await showViewer(tester, bookmark: (_, __) {
      calls++;
      return response.future;
    });
    Future<void> doubleTap() async {
      await tester.tapAt(const Offset(400, 300));
      await tester.pump(const Duration(milliseconds: 70));
      await tester.tapAt(const Offset(400, 300));
      await tester.pump(const Duration(milliseconds: 400));
    }

    await doubleTap();
    expect(controller.playing, isTrue);
    expect(calls, 1);
    // The heart turns red at once, before the server answers.
    expect(controller.current!.illust.isBookmarked, isTrue);
    await doubleTap();
    expect(calls, 1);
    response.complete(const Res(true));
    await tester.pump();
    expect(controller.current!.illust.isBookmarked, isTrue);
    await doubleTap();
    expect(calls, 1);
    expect(controller.current!.illust.isBookmarked, isTrue);
    expect(controller.playing, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('a late bookmark response updates the touched work after a swipe',
      (tester) async {
    final response = Completer<Res<bool>>();
    final controller = await showViewer(tester,
        playing: false, bookmark: (_, __) => response.future);
    final original = controller.current!.illust;
    await tester.tapAt(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 70));
    await tester.tapAt(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.drag(find.byKey(const ValueKey('slideshow-gestures')),
        const Offset(0, -400));
    await settlePaging(tester);
    expect(controller.current!.illust.id, 2);
    response.complete(const Res(true));
    await tester.pump();
    expect(original.isBookmarked, isTrue);
    expect(controller.current!.illust.isBookmarked, isFalse);
    expect(find.text('已收藏'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('bookmark failure leaves the heart unselected and supports retry',
      (tester) async {
    var calls = 0;
    final controller =
        await showViewer(tester, playing: false, bookmark: (_, __) async {
      calls++;
      return calls == 1 ? Res.error('offline') : const Res(true);
    });
    final heart = find.byKey(const ValueKey('slideshow-bookmark'));
    await tester.tap(heart);
    await tester.pump();
    expect(controller.current!.illust.isBookmarked, isFalse);
    expect(find.text('收藏失败'), findsOneWidget);
    await tester.tap(heart);
    await tester.pump();
    expect(controller.current!.illust.isBookmarked, isTrue);
    expect(calls, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 200));
  });
  testWidgets('controls fit a phone in landscape', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(640, 320);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await showViewer(tester, playing: false);
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    final heart =
        tester.getRect(find.byKey(const ValueKey('slideshow-bookmark')));
    expect(heart.top, greaterThanOrEqualTo(0));
    expect(heart.bottom, lessThanOrEqualTo(320));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('long press opens the more-actions sheet and holds the clock',
      (tester) async {
    final controller = await showViewer(tester);
    await tester.pump(const Duration(seconds: 1));
    await tester.longPressAt(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('3s'), findsOneWidget);
    final held = controller.remaining;
    await tester.pump(const Duration(seconds: 10));
    expect(controller.currentIndex, 0);
    expect(controller.remaining, held);
    await tester.tap(find.text('3s'));
    await tester.pump();
    expect(controller.interval, const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('tapping outside the middle toggles the controls, not playback',
      (tester) async {
    final controller = await showViewer(tester);
    double authorOpacity() => tester
        .widget<AnimatedOpacity>(find
            .ancestor(
                of: find.text('@Artist'),
                matching: find.byType(AnimatedOpacity))
            .first)
        .opacity;
    expect(authorOpacity(), 1);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.playing, isTrue);
    expect(authorOpacity(), 0);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.playing, isTrue);
    expect(authorOpacity(), 1);
    await tester.tapAt(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.playing, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('reopening the same feed resumes where playback stopped',
      (tester) async {
    final feed = Object();
    final first = await showViewer(tester, playing: false, resumeKey: feed);
    await first.goTo(2);
    await settlePaging(tester);
    expect(first.current!.illust.id, 2);
    expect(first.current!.page, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 200));

    final resumed = await showViewer(tester, playing: false, resumeKey: feed);
    await settlePaging(tester);
    expect(resumed.current!.illust.id, 2);
    expect(resumed.current!.page, 1);
    expect(find.text('2 / 2'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 200));

    // A refreshed feed is a different list, so it starts from the top.
    final fresh = await showViewer(tester, playing: false, resumeKey: Object());
    expect(fresh.current!.illust.id, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('controls fade out while playing and come back on pause',
      (tester) async {
    final controller = await showViewer(tester);
    double authorOpacity() => tester
        .widget<AnimatedOpacity>(find
            .ancestor(
                of: find.text('@Artist'),
                matching: find.byType(AnimatedOpacity))
            .first)
        .opacity;
    expect(authorOpacity(), 1);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.playing, isTrue);
    expect(authorOpacity(), 0);
    await tester.tapAt(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.playing, isFalse);
    expect(authorOpacity(), 1);
    // After a moment a paused slideshow leaves just the artwork on screen.
    await tester.pump(const Duration(seconds: 2));
    expect(authorOpacity(), 0);
    expect(controller.playing, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('automatic playback animates both paging axes in A B1 B2 C order',
      (tester) async {
    final controller = await showViewer(tester);
    expect(controller.currentIndex, 0);
    await tester.pump(const Duration(seconds: 5));
    await settlePaging(tester);
    expect(controller.currentIndex, 1);
    expect(find.text('1 / 2'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await settlePaging(tester);
    expect(controller.currentIndex, 2);
    expect(find.text('2 / 2'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await settlePaging(tester);
    expect(controller.currentIndex, 3);
    expect(find.text('Artwork 3'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 200));
  });
}
