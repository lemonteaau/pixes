import 'dart:async';
import 'dart:ui' as ui;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixes/appdata.dart';
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
  });

  Future<SlideshowController<ui.Image>> showViewer(WidgetTester tester,
      {bool playing = true,
      Future<Res<bool>> Function(Illust)? bookmark}) async {
    final controller = SlideshowController<ui.Image>(
      initialIllusts: [artwork(1), artwork(2, pages: 2), artwork(3)],
      nextUrl: null,
      loadPage: (_) async => const Res([]),
      loadImage: (_) => _ImageLoad(source),
      now: tester.binding.clock.now,
    )..playing = playing;
    await tester.pumpWidget(FluentApp(
      home: SlideshowPage(
        illusts: const [],
        nextUrl: null,
        source: '推荐',
        controller: controller,
        addBookmark: bookmark,
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

  testWidgets('manual swipe near the deadline restarts the ring after settling',
      (tester) async {
    final controller = await showViewer(tester);
    await tester.pump(const Duration(seconds: 4));
    final gesture = await tester.startGesture(const Offset(400, 300));
    await tester.pump(const Duration(seconds: 3));
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

  testWidgets('single tap pauses and resumes; indicator stays in the corner',
      (tester) async {
    final controller = await showViewer(tester);
    await tester.pump(const Duration(seconds: 2));
    await tester.tapAt(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.playing, isFalse);
    final frozen = controller.remaining;
    final ringFinder = find.byKey(const ValueKey('slideshow-countdown'));
    final ring =
        tester.widget<CustomPaint>(ringFinder).painter! as SlideshowRingPainter;
    expect(ring.progress, closeTo(0.4, 0.03));
    expect(tester.getCenter(ringFinder).dx, greaterThan(700));
    expect(tester.getCenter(ringFinder).dy, greaterThan(500));
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
    final controller = await showViewer(tester, bookmark: (_) {
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
        playing: false, bookmark: (_) => response.future);
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
        await showViewer(tester, playing: false, bookmark: (_) async {
      calls++;
      return calls == 1 ? Res.error('offline') : const Res(true);
    });
    final heart = find.byKey(const ValueKey('slideshow-bookmark'));
    await tester.tap(heart);
    await tester.pump();
    expect(controller.current!.illust.isBookmarked, isFalse);
    expect(find.text('收藏失败，请重试'), findsOneWidget);
    await tester.tap(heart);
    await tester.pump();
    expect(controller.current!.illust.isBookmarked, isTrue);
    expect(calls, 2);
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
