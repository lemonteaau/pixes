import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixes/components/lazy_indexed_stack.dart';
import 'package:pixes/components/loading.dart';
import 'package:pixes/network/res.dart';

final loads = <String, int>{};

class _ListPage extends StatefulWidget {
  const _ListPage(this.name, {super.key});

  final String name;

  @override
  State<_ListPage> createState() => _ListPageState();
}

class _ListPageState extends MultiPageLoadingState<_ListPage, String> {
  Completer<void>? gate;

  @override
  Future<Res<List<String>>> loadData(int page) async {
    final count = loads[widget.name] = (loads[widget.name] ?? 0) + 1;
    await gate?.future;
    return Res(['${widget.name} load $count page $page']);
  }

  @override
  Widget buildContent(BuildContext context, List<String> data) {
    return withRefresh(ListView(
      children: [for (final item in data) Text(item)],
    ));
  }
}

void main() {
  setUp(loads.clear);

  testWidgets('switching back to a page does not reload it', (tester) async {
    var current = 'a';
    late StateSetter setOuter;
    await tester.pumpWidget(FluentApp(
      home: StatefulBuilder(builder: (context, setState) {
        setOuter = setState;
        return LazyIndexedStack<String>(
          current: current,
          builder: (context, key) => _ListPage(key),
        );
      }),
    ));
    await tester.pumpAndSettle();
    expect(find.text('a load 1 page 1'), findsOneWidget);

    setOuter(() => current = 'b');
    await tester.pumpAndSettle();
    expect(find.text('b load 1 page 1'), findsOneWidget);

    setOuter(() => current = 'a');
    await tester.pumpAndSettle();
    expect(find.text('a load 1 page 1'), findsOneWidget);
    expect(loads, {'a': 1, 'b': 1});
  });

  testWidgets('hidden pages report themselves invisible', (tester) async {
    final seen = <String, bool>{};
    var current = 'a';
    late StateSetter setOuter;
    await tester.pumpWidget(FluentApp(
      home: StatefulBuilder(builder: (context, setState) {
        setOuter = setState;
        return LazyIndexedStack<String>(
          current: current,
          builder: (context, key) => Builder(builder: (context) {
            seen[key] = PageVisibility.of(context);
            return Text(key);
          }),
        );
      }),
    ));
    setOuter(() => current = 'b');
    await tester.pump();
    expect(seen, {'a': false, 'b': true});
  });

  testWidgets('refresh keeps the old content until new data arrives',
      (tester) async {
    final key = GlobalKey<_ListPageState>();
    await tester.pumpWidget(FluentApp(home: _ListPage('a', key: key)));
    await tester.pumpAndSettle();
    expect(find.text('a load 1 page 1'), findsOneWidget);

    final gate = key.currentState!.gate = Completer<void>();
    final done = key.currentState!.refresh();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('a load 1 page 1'), findsOneWidget);
    expect(find.byType(ProgressRing), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();
    await done;
    expect(find.text('a load 2 page 1'), findsOneWidget);
    expect(find.text('a load 1 page 1'), findsNothing);
  });
}
