import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixes/appdata.dart';
import 'package:pixes/foundation/slideshow/slideshow_controller.dart';
import 'package:pixes/network/models.dart';
import 'package:pixes/network/res.dart';
import 'package:pixes/utils/block.dart';

Illust artwork(int id,
    {bool visible = true,
    int restrict = 0,
    int pages = 1,
    String? original,
    bool muted = false}) {
  Map<String, String> urls(int page) => {
        'square_medium': 'https://i.pximg.net/thumb/$id-$page.jpg',
        'medium': 'https://i.pximg.net/medium/$id-$page.jpg',
        'large': 'https://i.pximg.net/large/$id-$page.jpg',
        'original': original ?? 'https://i.pximg.net/original/$id-$page.png',
      };
  return Illust.fromJson({
    'id': id,
    'title': 'Artwork $id',
    'type': 'illust',
    'image_urls': urls(0),
    'meta_pages':
        pages == 1 ? [] : List.generate(pages, (i) => {'image_urls': urls(i)}),
    'meta_single_page': {'original_image_url': urls(0)['original']},
    'caption': '',
    'restrict': restrict,
    'user': {
      'id': id,
      'name': 'Artist',
      'account': 'artist',
      'profile_image_urls': {'medium': ''},
    },
    'tags': [],
    'create_date': '2026-09-22T00:00:00Z',
    'page_count': pages,
    'width': 2000,
    'height': 3000,
    'total_view': 0,
    'total_bookmarks': 0,
    'is_bookmarked': false,
    'is_muted': muted,
    'visible': visible,
  });
}

class FakeLoad implements SlideLoad<String> {
  FakeLoad(this.url, {bool complete = true, bool fail = false}) {
    if (fail) {
      completer.completeError(StateError('403 private image'));
    } else if (complete) {
      completer.complete(url);
    }
  }

  final String url;
  final completer = Completer<String>();
  bool disposed = false;

  @override
  Future<String> get ready => completer.future;

  @override
  void dispose() {
    disposed = true;
    if (!completer.isCompleted) {
      completer.completeError(StateError('cancelled'));
    }
  }
}

void main() {
  setUp(() => appdata.settings['blockTags'] = []);

  test('unavailable, private, muted and placeholder images are filtered', () {
    final filtered = checkIllusts([
      artwork(1, visible: false),
      artwork(2, restrict: 1),
      artwork(3, muted: true),
      artwork(4, original: ''),
      artwork(5,
          original: 'https://s.pximg.net/common/images/limit_unknown_360.png'),
      artwork(6),
    ]);
    expect(filtered.map((e) => e.id), [6]);
  });

  test('only original URLs play, including every page of a multi-image work',
      () async {
    final controller = SlideshowController<String>(
      initialIllusts: [artwork(1, pages: 2), artwork(2)],
      nextUrl: null,
      loadPage: (_) async => const Res([]),
      loadImage: FakeLoad.new,
    );
    addTearDown(controller.dispose);
    await controller.next();
    expect(controller.image, 'https://i.pximg.net/original/1-0.png');
    await controller.next();
    expect(controller.current!.page, 1);
    expect(controller.image, 'https://i.pximg.net/original/1-1.png');
    await controller.next();
    expect(controller.current!.illust.id, 2);
    await controller.next();
    expect(controller.ended, isTrue);
    expect(controller.playing, isFalse);
  });

  test('three originals load concurrently within a bounded navigation buffer',
      () async {
    final loads = <FakeLoad>[];
    final controller = SlideshowController<String>(
      initialIllusts: List.generate(10, (i) => artwork(i)),
      nextUrl: null,
      loadPage: (_) async => const Res([]),
      loadImage: (url) {
        final load = FakeLoad(url, complete: false);
        loads.add(load);
        return load;
      },
    );
    final first = controller.next();
    expect(loads.length, 3);
    loads.first.completer.complete(loads.first.url);
    await first;
    expect(loads.length, 4); // current plus three upcoming frames
    final second = controller.next();
    expect(controller.image, loads.first.url); // keep current while buffering
    loads[1].completer.complete(loads[1].url);
    await second;
    expect(loads.first.disposed, isFalse); // retained for a backward swipe
    expect(loads.where((e) => !e.disposed).length, lessThanOrEqualTo(6));
    expect(loads.where((e) => !e.disposed && !e.completer.isCompleted).length,
        lessThanOrEqualTo(3));
    controller.dispose();
    expect(loads.every((e) => e.disposed), isTrue);
    await Future<void>.delayed(Duration.zero);
  });

  test('failed original is skipped without displaying it', () async {
    final controller = SlideshowController<String>(
      initialIllusts: [artwork(1), artwork(2), artwork(3)],
      nextUrl: null,
      loadPage: (_) async => const Res([]),
      loadImage: (url) => FakeLoad(url, fail: url.contains('/2-')),
    );
    addTearDown(controller.dispose);
    await controller.next();
    await controller.next();
    expect(controller.current!.illust.id, 3);
  });

  test(
      'empty/private pages are traversed and duplicate artwork is not replayed',
      () async {
    final requested = <String>[];
    final controller = SlideshowController<String>(
      initialIllusts: [artwork(1)],
      nextUrl: 'page2',
      loadPage: (url) async {
        requested.add(url);
        return url == 'page2'
            ? Res([artwork(2, visible: false)], subData: 'page3')
            : Res([artwork(1), artwork(3)]);
      },
      loadImage: FakeLoad.new,
    );
    addTearDown(controller.dispose);
    await controller.next();
    await controller.next();
    expect(controller.current!.illust.id, 3);
    expect(requested, ['page2', 'page3']);
  });

  test('pagination failure keeps the current image and can be retried',
      () async {
    var fail = true;
    final controller = SlideshowController<String>(
      initialIllusts: [artwork(1)],
      nextUrl: 'page2',
      loadPage: (_) async => fail ? Res.error('offline') : Res([artwork(2)]),
      loadImage: FakeLoad.new,
    );
    addTearDown(controller.dispose);
    await controller.next();
    await controller.next();
    expect(controller.error, isNotNull);
    expect(controller.current!.illust.id, 1);
    fail = false;
    await controller.next();
    expect(controller.current!.illust.id, 2);
    expect(controller.error, isNull);
  });

  test('an endlessly filtered feed pauses after a bounded number of requests',
      () async {
    var requests = 0;
    final controller = SlideshowController<String>(
      initialIllusts: [],
      nextUrl: 'page0',
      loadPage: (_) async {
        requests++;
        return Res([artwork(requests, visible: false)],
            subData: 'page$requests');
      },
      loadImage: FakeLoad.new,
    );
    addTearDown(controller.dispose);
    await controller.next();
    expect(requests, 30);
    expect(controller.playing, isFalse);
    expect(controller.error, isNotNull);
  });

  testWidgets('display interval starts after decoding; speed and pause work',
      (tester) async {
    final loads = <FakeLoad>[];
    final controller = SlideshowController<String>(
      initialIllusts: List.generate(8, (i) => artwork(i)),
      nextUrl: null,
      loadPage: (_) async => const Res([]),
      loadImage: (url) {
        final load = FakeLoad(url, complete: loads.isNotEmpty);
        loads.add(load);
        return load;
      },
    );
    unawaited(controller.next());
    await tester.pump(const Duration(seconds: 20));
    expect(controller.image, isNull);
    loads.first.completer.complete(loads.first.url);
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(controller.current!.illust.id, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(controller.current!.illust.id, 1);
    controller.setInterval(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    expect(controller.current!.illust.id, 2);
    controller.togglePlaying();
    await tester.pump(const Duration(seconds: 20));
    expect(controller.current!.illust.id, 2);
    controller.togglePlaying();
    await tester.pump(const Duration(seconds: 2));
    expect(controller.current!.illust.id, 3);
    controller.dispose();
  });

  testWidgets('pausing during buffering prevents an automatic transition',
      (tester) async {
    final loads = <FakeLoad>[];
    final controller = SlideshowController<String>(
      initialIllusts: [artwork(1), artwork(2)],
      nextUrl: null,
      loadPage: (_) async => const Res([]),
      loadImage: (url) {
        final load = FakeLoad(url, complete: loads.isEmpty);
        loads.add(load);
        return load;
      },
    );
    unawaited(controller.next());
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(controller.busy, isTrue);
    controller.togglePlaying();
    loads[1].completer.complete(loads[1].url);
    await tester.pump();
    expect(controller.current!.illust.id, 1);
    controller.togglePlaying();
    await tester.pump(const Duration(seconds: 5));
    expect(controller.current!.illust.id, 2);
    controller.dispose();
  });

  testWidgets('backgrounding suspends playback and disposal cancels the timer',
      (tester) async {
    final controller = SlideshowController<String>(
      initialIllusts: [artwork(1), artwork(2), artwork(3)],
      nextUrl: null,
      loadPage: (_) async => const Res([]),
      loadImage: FakeLoad.new,
    );
    unawaited(controller.next());
    await tester.pump();
    controller.setActive(false);
    await tester.pump(const Duration(minutes: 1));
    expect(controller.current!.illust.id, 1);
    controller.setActive(true);
    await tester.pump(const Duration(seconds: 5));
    expect(controller.current!.illust.id, 2);
    controller.dispose();
    await tester.pump(const Duration(minutes: 1));
    expect(controller.current!.illust.id, 2);
  });

  test('disposing during the first load ignores late completion', () async {
    final controller = SlideshowController<String>(
      initialIllusts: [artwork(1)],
      nextUrl: null,
      loadPage: (_) async => const Res([]),
      loadImage: (url) => FakeLoad(url, complete: false),
    );
    final pending = controller.next();
    controller.dispose();
    await pending;
    expect(controller.image, isNull);
  });
  test('autoplay follows A, B1, B2, C while vertical moves use artwork groups',
      () async {
    final controller = SlideshowController<String>(
      initialIllusts: [artwork(1), artwork(2, pages: 2), artwork(3)],
      nextUrl: null,
      loadPage: (_) async => const Res([]),
      loadImage: FakeLoad.new,
    );
    addTearDown(controller.dispose);
    final sequence = <String>[];
    for (var i = 0; i < 4; i++) {
      await controller.next();
      sequence
          .add('${controller.current!.illust.id}:${controller.current!.page}');
    }
    expect(sequence, ['1:0', '2:0', '2:1', '3:0']);
    await controller.previousWork();
    expect(controller.current!.illust.id, 2);
    expect(controller.current!.page, 0);
    await controller.goTo(controller.pagesOf(1)[1]);
    expect(controller.current!.page, 1);
    await controller.nextWork();
    expect(controller.current!.illust.id, 3);
  });

  test('autoplay can either wait for a loading original or skip it', () async {
    final loads = <FakeLoad>[];
    final waiting = SlideshowController<String>(
      initialIllusts: [artwork(1), artwork(2), artwork(3)],
      nextUrl: null,
      loadPage: (_) async => const Res([]),
      loadImage: (url) {
        final load = FakeLoad(url, complete: !url.contains('/2-'));
        loads.add(load);
        return load;
      },
      waitForImageLoad: true,
    );
    await waiting.next();
    final pending = waiting.next(automatic: true);
    expect(waiting.current!.illust.id, 1);
    expect(waiting.busy, isTrue);
    loads.firstWhere((load) => load.url.contains('/2-')).completer.complete(
        'https://i.pximg.net/original/2-0.png');
    await pending;
    expect(waiting.current!.illust.id, 2);
    waiting.dispose();

    final skipping = SlideshowController<String>(
      initialIllusts: [artwork(1), artwork(2), artwork(3)],
      nextUrl: null,
      loadPage: (_) async => const Res([]),
      loadImage: (url) => FakeLoad(url, complete: !url.contains('/2-')),
      waitForImageLoad: false,
    );
    await skipping.next();
    await skipping.next(automatic: true);
    expect(skipping.current!.illust.id, 3);
    expect(skipping.current!.page, 0);
    skipping.dispose();
  });

  testWidgets(
      'a swipe holds the clock until settling then restarts the full interval',
      (tester) async {
    final controller = SlideshowController<String>(
      initialIllusts: [artwork(1), artwork(2, pages: 2), artwork(3)],
      nextUrl: null,
      loadPage: (_) async => const Res([]),
      loadImage: FakeLoad.new,
      now: tester.binding.clock.now,
    );
    unawaited(controller.next());
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(controller.progress, closeTo(0.8, 0.01));
    controller.setInteracting(true);
    await tester.pump(const Duration(seconds: 10));
    expect(controller.current!.illust.id, 1);
    unawaited(controller.goTo(1));
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(controller.currentIndex, 1);
    controller.setInteracting(false, resetCountdown: true);
    expect(controller.progress, 0);
    await tester.pump(const Duration(seconds: 4));
    expect(controller.currentIndex, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(controller.currentIndex, 2);
    controller.dispose();
  });

  testWidgets('pause freezes the ring and resume uses its remaining duration',
      (tester) async {
    final controller = SlideshowController<String>(
      initialIllusts: [artwork(1), artwork(2)],
      nextUrl: null,
      loadPage: (_) async => const Res([]),
      loadImage: FakeLoad.new,
      now: tester.binding.clock.now,
    );
    unawaited(controller.next());
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    controller.togglePlaying();
    expect(controller.remaining, const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 30));
    expect(controller.progress, closeTo(0.4, 0.01));
    controller.togglePlaying();
    await tester.pump(const Duration(seconds: 2));
    expect(controller.currentIndex, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(controller.currentIndex, 1);
    controller.dispose();
  });

  testWidgets('manual selection supersedes an automatic image still loading',
      (tester) async {
    final loads = <String, FakeLoad>{};
    final controller = SlideshowController<String>(
      initialIllusts: List.generate(6, (i) => artwork(i)),
      nextUrl: null,
      loadPage: (_) async => const Res([]),
      loadImage: (url) =>
          loads[url] = FakeLoad(url, complete: !url.contains('/1-')),
      now: tester.binding.clock.now,
    );
    unawaited(controller.next());
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(controller.busy, isTrue);
    controller.setInteracting(true);
    unawaited(controller.goTo(3));
    await tester.pump();
    expect(controller.currentIndex, 3);
    final stale = loads['https://i.pximg.net/original/1-0.png']!;
    if (!stale.completer.isCompleted) stale.completer.complete(stale.url);
    controller.setInteracting(false, resetCountdown: true);
    await tester.pump();
    expect(controller.currentIndex, 3);
    expect(controller.remaining, const Duration(seconds: 5));
    controller.dispose();
  });

  test('rapid manual navigation keeps only the last requested image', () async {
    final loads = <String, FakeLoad>{};
    final controller = SlideshowController<String>(
      initialIllusts: List.generate(8, (i) => artwork(i)),
      nextUrl: null,
      loadPage: (_) async => const Res([]),
      loadImage: (url) => loads[url] = FakeLoad(url, complete: false),
    );
    final first = controller.goTo(0);
    final second = controller.goTo(6);
    final last = controller.goTo(3);
    final selected = loads['https://i.pximg.net/original/3-0.png']!;
    selected.completer.complete(selected.url);
    await last;
    expect(controller.currentIndex, 3);
    expect(loads.values.where((load) => !load.disposed).length,
        lessThanOrEqualTo(6));
    controller.dispose();
    await Future.wait([first, second]);
  });
}
