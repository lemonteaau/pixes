import 'package:fluent_ui/fluent_ui.dart' hide TitleBar;
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:pixes/appdata.dart';
import 'package:pixes/components/loading.dart';
import 'package:pixes/components/lazy_indexed_stack.dart';
import 'package:pixes/components/segmented_button.dart';
import 'package:pixes/components/title_bar.dart';
import 'package:pixes/foundation/app.dart';
import 'package:pixes/foundation/history.dart';
import 'package:pixes/network/network.dart';
import 'package:pixes/utils/translation.dart';
import 'package:pixes/pages/illust_viewer.dart';

import '../components/illust_widget.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  int page = 0;
  final localPageKey = GlobalKey<_LocalHistoryPageState>();
  final networkPageKey = GlobalKey<_NetworkHistoryPageState>();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TitleBar(
          title: "History".tl,
          onRefresh: () {
            if (page == 0) {
              localPageKey.currentState?.refresh();
            } else {
              networkPageKey.currentState?.refresh();
            }
          },
          action: SegmentedButton<int>(
            options: [
              SegmentedButtonOption(
                0,
                "Local".tl,
              ),
              SegmentedButtonOption(
                1,
                "Network".tl,
              ),
            ],
            value: page,
            onPressed: (key) {
              setState(() {
                page = key;
              });
            },
          ),
        ),
        Expanded(
          child: LazyIndexedStack<int>(
            current: page,
            builder: (context, page) => page == 0
                ? LocalHistoryPage(key: localPageKey)
                : NetworkHistoryPage(
                    key: networkPageKey,
                  ),
          ),
        ),
      ],
    );
  }
}

class LocalHistoryPage extends StatefulWidget {
  const LocalHistoryPage({super.key});

  @override
  State<LocalHistoryPage> createState() => _LocalHistoryPageState();
}

class _LocalHistoryPageState extends State<LocalHistoryPage> {
  int page = 1;

  var data = <IllustHistory>[];

  bool visible = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Kept alive while hidden; show artworks viewed meanwhile.
    final visible = PageVisibility.of(context);
    if (visible && !this.visible) {
      page = 1;
      data = [];
    }
    this.visible = visible;
  }

  Future<void> refresh() async {
    setState(() {
      page = 1;
      data = [];
    });
  }

  @override
  Widget build(BuildContext context) {
    return withRefresh(MasonryGridView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 8) +
            EdgeInsets.only(bottom: context.padding.bottom),
        physics: const AlwaysScrollableScrollPhysics(),
        gridDelegate: const SliverSimpleGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 240,
        ),
        itemCount: HistoryManager().length,
        itemBuilder: (context, index) {
          while (index >= data.length) {
            final more = HistoryManager().getHistories(page);
            if (more.isEmpty) break;
            data.addAll(more);
            page++;
          }
          if (index >= data.length) {
            return const SizedBox.shrink();
          }
          return IllustHistoryWidget(data[index]);
        },
      ));
  }

  Widget withRefresh(Widget child) {
    return buildRefreshWrapper(
      onRefresh: refresh,
      child: child,
    );
  }
}

class NetworkHistoryPage extends StatefulWidget {
  const NetworkHistoryPage({super.key});

  @override
  State<NetworkHistoryPage> createState() => _NetworkHistoryPageState();
}

class _NetworkHistoryPageState
    extends MultiPageLoadingState<NetworkHistoryPage, Illust> {
  @override
  Widget buildContent(BuildContext context, final List<Illust> data) {
    return withRefresh(MasonryGridView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 8) +
            EdgeInsets.only(bottom: context.padding.bottom),
        physics: const AlwaysScrollableScrollPhysics(),
        gridDelegate: const SliverSimpleGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 240,
        ),
        itemCount: data.length,
        itemBuilder: (context, index) {
          if (index == data.length - 1) {
            nextPage();
          }
          return IllustWidget(data[index], onTap: () {
            openIllustFeed(context,
                illusts: data,
                index: index,
                source: 'History'.tl);
          });
        },
      ));
  }

  @override
  Future<Res<List<Illust>>> loadData(page) {
    if (appdata.account?.user.isPremium != true) {
      return Future.value(Res.error("Premium Required".tl));
    }
    return Network().getHistory(page);
  }
}
