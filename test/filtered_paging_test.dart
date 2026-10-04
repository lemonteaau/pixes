import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixes/components/loading.dart';
import 'package:pixes/network/res.dart';

/// Pages served by [_FilteredPageState], one list per page. Items starting
/// with "hidden" are dropped in [MultiPageLoadingState.buildContent], the way
/// blocked works are.
var pages = <List<String>>[];
var requested = <int>[];

class _FilteredPage extends StatefulWidget {
  const _FilteredPage();

  @override
  State<_FilteredPage> createState() => _FilteredPageState();
}

class _FilteredPageState extends MultiPageLoadingState<_FilteredPage, String> {
  @override
  Future<Res<List<String>>> loadData(int page) async {
    requested.add(page);
    if (page > pages.length) return Res.error('No more data');
    return Res(pages[page - 1]);
  }

  @override
  Widget buildContent(BuildContext context, List<String> data) {
    data.removeWhere((e) => e.startsWith('hidden'));
    return ListView.builder(
      itemCount: data.length,
      itemBuilder: (context, index) {
        if (index == data.length - 1) nextPage();
        return Text(data[index]);
      },
    );
  }
}

Future<void> pumpPage(WidgetTester tester) async {
  await tester.pumpWidget(const FluentApp(home: _FilteredPage()));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => requested = []);

  testWidgets('keeps loading while every loaded page is filtered out',
      (tester) async {
    pages = [
      ['hidden 1', 'hidden 2'],
      ['hidden 3'],
      ['shown'],
    ];
    await pumpPage(tester);

    expect(find.text('shown'), findsOneWidget);
    expect(requested, [1, 2, 3, 4]);
  });

  testWidgets('stops once the source runs out', (tester) async {
    pages = [
      ['hidden 1'],
      ['hidden 2'],
    ];
    await pumpPage(tester);

    expect(find.byType(Text), findsNothing);
    expect(requested, [1, 2, 3]);
  });

  testWidgets('does not load more for an empty source', (tester) async {
    pages = [[]];
    await pumpPage(tester);

    expect(requested, [1]);
  });

  testWidgets('gives up after ten filtered pages in a row', (tester) async {
    pages = [for (var i = 0; i < 30; i++) ['hidden $i']];
    await pumpPage(tester);

    expect(requested.length, 11);
  });
}
