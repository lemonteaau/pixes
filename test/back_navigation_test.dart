import 'dart:async';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart'
    show PredictiveBackPageTransitionsBuilder;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixes/appdata.dart';
import 'package:pixes/components/keyboard.dart';
import 'package:pixes/components/page_route.dart';
import 'package:pixes/foundation/app.dart';
import 'package:pixes/network/models.dart';
import 'package:pixes/pages/illust_viewer.dart';
import 'package:pixes/pages/main_page.dart';
import 'package:pixes/pages/novel_history_page.dart';
import 'package:pixes/utils/translation.dart';

/// A page route with the transition routes get on Android, whichever
/// platform runs the tests.
class _AndroidRoute<T> extends AppPageRoute<T> {
  _AndroidRoute(Widget page) : super(builder: (_) => page);

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation,
          Animation<double> secondaryAnimation, Widget child) =>
      const PredictiveBackPageTransitionsBuilder().buildTransitions(
          this, context, animation, secondaryAnimation, child);
}

void main() {
  var leftApp = false;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await Translation.init();
    App.dataPath = Directory.systemTemp.createTempSync('pixes-back').path;
    App.cachePath = Directory.systemTemp.createTempSync('pixes-back-c').path;
  });

  setUp(() {
    appdata.account = Account('token', '',
        User('', '0', 'Tester', 'tester', 'tester@invalid', false));
    final initialPage = appdata.settings['initialPage'];
    // The novel history is read from the device, not from pixiv.
    appdata.settings['initialPage'] = 13;
    addTearDown(() {
      appdata.account = null;
      appdata.settings['initialPage'] = initialPage;
    });
  });

  /// The navigator of the whole window, which the player is opened in.
  NavigatorState window() => App.rootNavigatorKey.currentState!;

  /// The navigator under the main page's title bar.
  NavigatorState main() => App.mainNavigatorKey!.currentState!;

  Future<void> pumpApp(WidgetTester tester) async {
    leftApp = false;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') leftApp = true;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(FluentApp(
      navigatorKey: App.rootNavigatorKey,
      builder: (context, child) => KeyEventListener(child: child!),
      home: const MainPage(),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(NovelHistoryPage), findsOneWidget);
  }

  Future<void> push(
      WidgetTester tester, NavigatorState navigator, Widget page) async {
    unawaited(navigator.push(_AndroidRoute<void>(page)));
    await tester.pumpAndSettle();
  }

  Widget page(String text) => Center(child: Text(text));

  Future<void> send(WidgetTester tester, String method, [Object? arguments]) =>
      tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        SystemChannels.backGesture.name,
        SystemChannels.backGesture.codec
            .encodeMethodCall(MethodCall(method, arguments)),
        (_) {},
      );

  Map<String, Object?> backEvent(double progress, {bool button = false}) => {
        'touchOffset': button ? null : <double>[5, 300],
        'progress': progress,
        'swipeEdge': 0,
      };

  /// Swipes back from the edge of the screen, as with gesture navigation.
  Future<void> swipeBack(WidgetTester tester) async {
    await send(tester, 'startBackGesture', backEvent(0));
    await tester.pump();
    await send(tester, 'updateBackGestureProgress', backEvent(0.5));
    await tester.pump();
    await send(tester, 'commitBackGesture');
    await tester.pumpAndSettle();
  }

  /// Presses the back button of the three-button navigation bar.
  Future<void> pressBack(WidgetTester tester) async {
    await send(tester, 'startBackGesture', backEvent(0, button: true));
    await send(tester, 'commitBackGesture');
    await tester.pumpAndSettle();
  }

  Future<void> pressEscape(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  }

  testWidgets('swiping back closes only the route on screen', (tester) async {
    await pumpApp(tester);
    await push(tester, main(), page('user'));
    await push(tester, window(), page('player'));

    await swipeBack(tester);
    expect(find.text('player'), findsNothing);
    expect(find.text('user'), findsOneWidget);

    await swipeBack(tester);
    expect(find.text('user'), findsNothing);
    expect(find.byType(NovelHistoryPage), findsOneWidget);
    expect(leftApp, isFalse);
  });

  testWidgets('swiping back closes a dialog, not the page under it',
      (tester) async {
    await pumpApp(tester);
    await push(tester, main(), page('user'));
    unawaited(showDialog<void>(
      context: window().context,
      builder: (_) => const ContentDialog(content: Text('dialog')),
    ));
    await tester.pumpAndSettle();

    await swipeBack(tester);
    expect(find.text('dialog'), findsNothing);
    expect(find.text('user'), findsOneWidget);
  });

  testWidgets('the back button goes back a page instead of leaving the app',
      (tester) async {
    await pumpApp(tester);
    await push(tester, main(), page('user'));
    await push(tester, main(), page('artwork'));

    await pressBack(tester);
    expect(find.text('artwork'), findsNothing);
    expect(find.text('user'), findsOneWidget);
    await pressBack(tester);
    expect(find.byType(NovelHistoryPage), findsOneWidget);
    expect(leftApp, isFalse);

    await pressBack(tester);
    expect(leftApp, isTrue);
  });

  for (final (name, back) in [
    ('swiping back', swipeBack),
    ('the back button', pressBack),
    ('Escape', pressEscape),
  ]) {
    testWidgets('$name goes through the pages opened from the player',
        (tester) async {
      await pumpApp(tester);
      await push(tester, main(), page('user'));
      await push(tester, window(), page('player'));
      final details = GlobalKey();
      await push(
          tester,
          window(),
          ViewerSubpageFrame(
              child: KeyedSubtree(key: details, child: page('details'))));
      await push(tester, Navigator.of(details.currentContext!), page('author'));

      await back(tester);
      expect(find.text('author'), findsNothing);
      expect(find.text('details'), findsOneWidget);
      await back(tester);
      expect(find.text('details'), findsNothing);
      expect(find.text('player'), findsOneWidget);
      await back(tester);
      expect(find.text('player'), findsNothing);
      expect(find.text('user'), findsOneWidget);
      await back(tester);
      expect(find.byType(NovelHistoryPage), findsOneWidget);
      expect(leftApp, isFalse);
    });
  }
}
