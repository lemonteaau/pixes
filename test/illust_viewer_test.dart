import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixes/appdata.dart';
import 'package:pixes/components/animated_image.dart';
import 'package:pixes/components/keyboard.dart';
import 'package:pixes/components/page_route.dart';
import 'package:pixes/foundation/app.dart';
import 'package:pixes/foundation/history.dart';
import 'package:pixes/foundation/slideshow/slideshow_controller.dart';
import 'package:pixes/network/network.dart';
import 'package:pixes/pages/comments_page.dart';
import 'package:pixes/pages/illust_page.dart';
import 'package:pixes/pages/illust_viewer.dart';
import 'package:pixes/pages/slideshow_page.dart';
import 'package:pixes/pages/user_info_page.dart';
import 'package:pixes/utils/translation.dart';

import 'slideshow_gestures_test.dart' show settlePaging;
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

void main() {
  late ui.Image source;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await Translation.init();
    App.dataPath = Directory.systemTemp.createTempSync('pixes-viewer').path;
    App.cachePath = Directory.systemTemp.createTempSync('pixes-cache').path;
    HistoryManager().init();
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
    appdata.settings.remove('useLegacyIllustViewer');
    final thumbnails = appdata.settings['slideshowShowThumbnailWhileLoading'];
    appdata.settings['slideshowShowThumbnailWhileLoading'] = false;
    addTearDown(() {
      appdata.settings['slideshowShowThumbnailWhileLoading'] = thumbnails;
      appdata.settings.remove('useLegacyIllustViewer');
    });
  });

  SlideshowController<ui.Image> newController(WidgetTester tester) =>
      SlideshowController<ui.Image>(
        initialIllusts: [artwork(1), artwork(2, pages: 2), artwork(3)],
        nextUrl: null,
        loadPage: (_) async => const Res([]),
        loadImage: (_) => _ImageLoad(source),
        now: tester.binding.clock.now,
      )..playing = false;

  Future<SlideshowController<ui.Image>> showViewer(WidgetTester tester,
      {int? initialIllustId,
      bool playing = false,
      Future<Res<bool>> Function(Illust, bool)? bookmark}) async {
    final controller = newController(tester)..playing = playing;
    await tester.pumpWidget(FluentApp(
      home: SlideshowPage(
        illusts: const [],
        nextUrl: null,
        source: '推荐',
        controller: controller,
        initialIllustId: initialIllustId,
        autoPlay: false,
        setBookmark: bookmark,
      ),
    ));
    await settlePaging(tester);
    return controller;
  }

  testWidgets('starts at the tapped work, paused, titled with its feed',
      (tester) async {
    final controller = await showViewer(tester, initialIllustId: 3);
    expect(controller.current!.illust.id, 3);
    expect(controller.playing, isFalse);
    expect(find.text('推荐'), findsOneWidget);
    expect(find.text('推荐 · 自动播放'), findsNothing);

    // Earlier works are still one swipe away.
    await tester.drag(find.byKey(const ValueKey('slideshow-gestures')),
        const Offset(0, 400));
    await settlePaging(tester);
    expect(controller.current!.illust.id, 2);
  });

  testWidgets('records viewed works in the history', (tester) async {
    final controller = await showViewer(tester, initialIllustId: 2);
    expect(controller.current!.illust.id, 2);
    expect(HistoryManager().getHistories(1).map((e) => e.id), contains(2));
  });

  testWidgets('the mouse wheel moves between works', (tester) async {
    final controller = await showViewer(tester);
    final center = tester.getCenter(find.byType(SlideshowPage));
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(center));

    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 120)));
    // Momentum scrolling sends a burst of events; it moves only once.
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 120)));
    await settlePaging(tester);
    expect(controller.current!.illust.id, 2);

    // A new burst after a pause moves again.
    await tester.runAsync(
        () => Future.delayed(const Duration(milliseconds: 300)));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -120)));
    await settlePaging(tester);
    expect(controller.current!.illust.id, 1);
  });

  testWidgets('arrow keys go through the pages, then on to the next work',
      (tester) async {
    final controller = await showViewer(tester);
    Future<(int, int)> right() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await settlePaging(tester);
      return (controller.current!.illust.id, controller.current!.page);
    }

    expect(await right(), (2, 0));
    expect(await right(), (2, 1));
    expect(await right(), (3, 0));
  });

  testWidgets('shortcuts from the settings work in the player',
      (tester) async {
    final liked = <int>[];
    final controller =
        await showViewer(tester, bookmark: (illust, value) async {
      liked.add(illust.id);
      return const Res(true);
    });
    // "Add to favorites" is Enter by default.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(controller.current!.illust.isBookmarked, isTrue);
    expect(liked, [1]);
  });

  testWidgets('Escape closes only the player', (tester) async {
    await tester.pumpWidget(FluentApp(
      navigatorKey: App.rootNavigatorKey,
      builder: (context, child) => KeyEventListener(child: child!),
      home: const Text('feed'),
    ));
    final navigator = App.rootNavigatorKey.currentState!;
    unawaited(navigator.push(PageRouteBuilder(
        pageBuilder: (_, __, ___) => const ColoredBox(
            color: Color(0xFFFFFFFF), child: Center(child: Text('user'))))));
    await tester.pumpAndSettle();
    final controller = newController(tester);
    unawaited(navigator.push(PageRouteBuilder(
      pageBuilder: (_, __, ___) => SlideshowPage(
        illusts: const [],
        nextUrl: null,
        source: '',
        controller: controller,
      ),
    )));
    await settlePaging(tester);
    expect(find.byType(SlideshowPage), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(SlideshowPage), findsNothing);
    expect(find.text('user'), findsOneWidget);
  });

  testWidgets('pages opened from the player get a back button of their own',
      (tester) async {
    await tester.pumpWidget(FluentApp(
      home: Builder(
        builder: (context) => Button(
          onPressed: () => Navigator.of(context).push(PageRouteBuilder(
            pageBuilder: (_, __, ___) => ViewerSubpageFrame(
              child: Builder(
                builder: (context) => Button(
                  onPressed: () => context.to(() => const Text('author')),
                  child: const Text('details'),
                ),
              ),
            ),
          )),
          child: const Text('player'),
        ),
      ),
    ));
    await tester.tap(find.text('player'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('details'));
    await tester.pumpAndSettle();
    expect(find.text('author'), findsOneWidget);

    final back = find.byKey(const ValueKey('viewer-subpage-back'));
    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(find.text('details'), findsOneWidget);
    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(find.text('player'), findsOneWidget);
  });

  testWidgets('a commenter opened from the player gets a back button too',
      (tester) async {
    Network().dio.httpClientAdapter = _CommentsAdapter();
    addTearDown(() => Network.instance = null);
    // Pictures can't be loaded in tests, and the avatars report it.
    final onError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.library != 'image resource service') onError?.call(details);
    };

    final controller = await showViewer(tester, playing: true);
    await tester.tap(find.text('评论'));
    await tester.pumpAndSettle();
    expect(find.text('Nice work'), findsOneWidget);
    expect(controller.countdownRunning, isFalse);

    await tester.tap(find.descendant(
        of: find.byType(CommentsPage), matching: find.byType(AnimatedImage)));
    await tester.pumpAndSettle();
    final user = find.byType(UserInfoPage);
    // The commenter, not the user whose id happens to be the comment's.
    expect(tester.widget<UserInfoPage>(user).id, '77');
    expect(find.ancestor(of: user, matching: find.byType(ViewerSubpageFrame)),
        findsOneWidget);

    // Back to the comments, which still keep the player waiting.
    await tester.tap(find.byKey(const ValueKey('viewer-subpage-back')));
    await tester.pumpAndSettle();
    expect(user, findsNothing);
    expect(find.text('Nice work'), findsOneWidget);
    expect(controller.countdownRunning, isFalse);
    expect(controller.currentIndex, 0);

    // Closing them lets it play on. It keeps drawing frames while it plays,
    // so this can't wait for them to settle.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(CommentsPage), findsNothing);
    expect(controller.currentIndex, 0);
    expect(controller.countdownRunning, isTrue);
    FlutterError.onError = onError;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 31));
  });

  testWidgets('opening from a feed uses the player unless the classic one is on',
      (tester) async {
    appdata.account = Account(
        '', '', User('', '0', 'Tester', 'tester', 'tester@invalid', false));
    addTearDown(() => appdata.account = null);
    final feed = [artwork(1), artwork(2), artwork(3)];
    await tester.pumpWidget(FluentApp(
      home: Builder(
        builder: (context) => Button(
          onPressed: () => openIllustFeed(context,
              illusts: feed, index: 1, nextUrl: 'next', source: '关注'),
          child: const Text('open'),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final player = tester.widget<SlideshowPage>(find.byType(SlideshowPage));
    expect(player.initialIllustId, 2);
    expect(player.autoPlay, isFalse);
    expect(player.source, '关注');
    expect(player.nextUrl, 'next');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 31));

    appdata.settings['useLegacyIllustViewer'] = true;
    final pushed = <Route>[];
    await tester.pumpWidget(FluentApp(
      navigatorObservers: [_Observer(pushed)],
      home: Builder(
        builder: (context) => Button(
          onPressed: () => openIllustFeed(context,
              illusts: feed, index: 1, nextUrl: 'next', source: '关注'),
          child: const Text('open'),
        ),
      ),
    ));
    pushed.clear();
    await tester.tap(find.text('open'));
    // Checks what was pushed without building the network-bound detail page.
    final route = pushed.single as AppPageRoute;
    final page = route.builder(tester.element(find.text('open')));
    expect(page, isA<IllustGalleryPage>());
    expect((page as IllustGalleryPage).initialPage, 1);
    expect(page.nextUrl, 'next');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 31));
  });
}

class _Observer extends NavigatorObserver {
  _Observer(this.pushed);
  final List<Route> pushed;
  @override
  void didPush(Route route, Route? previousRoute) => pushed.add(route);
}

/// Serves one comment by user 77 and fails everything else, so the pages
/// opened from it stop at their error message.
class _CommentsAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final found = options.uri.path == '/v3/illust/comments';
    return ResponseBody.fromString(
      jsonEncode(found
          ? {
              'comments': [
                {
                  'id': 900,
                  'comment': 'Nice work',
                  'date': '2026-09-22T00:00:00Z',
                  'user': {
                    'id': 77,
                    'name': 'Commenter',
                    'profile_image_urls': {'medium': ''},
                  },
                },
              ],
              'next_url': null,
            }
          : {
              'error': {'message': 'Not found'},
            }),
      found ? 200 : 404,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
