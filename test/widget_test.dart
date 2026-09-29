import 'package:fluent_ui/fluent_ui.dart' hide TitleBar;
import 'package:flutter_test/flutter_test.dart';
import 'package:pixes/appdata.dart';
import 'package:pixes/components/slideshow_button.dart';
import 'package:pixes/components/title_bar.dart';
import 'package:pixes/pages/slideshow_page.dart';
import 'package:pixes/utils/translation.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await Translation.init();
    appdata.settings['language'] = '简体中文';
  });

  testWidgets('feed action opens slideshow and closes back to the feed',
      (tester) async {
    await tester.pumpWidget(FluentApp(
      home: Center(
        child: SlideshowButton(
          source: '关注',
          illusts: () => [],
          nextUrl: () => null,
        ),
      ),
    ));
    await tester.tap(find.byIcon(FluentIcons.play));
    await tester.pumpAndSettle();
    expect(find.byType(SlideshowPage), findsOneWidget);
    expect(find.text('关注 · 自动播放'), findsOneWidget);
    expect(find.text('没有可播放的公开图片'), findsOneWidget);
    // Playback speed now lives in the more-actions sheet.
    expect(find.byIcon(FluentIcons.more), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byIcon(FluentIcons.back));
    await tester.pumpAndSettle();
    expect(find.byType(SlideshowPage), findsNothing);
    expect(find.byIcon(FluentIcons.play), findsOneWidget);
  });

  testWidgets('slideshow controls fit a narrow phone in portrait and landscape',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    for (final size in [const Size(320, 640), const Size(640, 320)]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(const FluentApp(
        home: SlideshowPage(illusts: [], nextUrl: null, source: '推荐'),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('slideshow-progress')), findsOneWidget);
    }
  });

  testWidgets('feed title and playback action stay visible on narrow screens',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(FluentApp(
      home: Column(
        children: [
          TitleBar(
            title: '关注',
            wrapActions: true,
            onRefresh: () {},
            action: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SlideshowButton(
                  source: '关注',
                  illusts: () => [],
                  nextUrl: () => null,
                ),
                const SizedBox(width: 300, child: Text('全部 公开 私人')),
              ],
            ),
          ),
        ],
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byIcon(FluentIcons.play).hitTestable(), findsOneWidget);
  });
}
