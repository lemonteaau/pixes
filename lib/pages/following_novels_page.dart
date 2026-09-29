import 'package:fluent_ui/fluent_ui.dart' hide TitleBar;
import 'package:pixes/components/grid.dart';
import 'package:pixes/components/lazy_indexed_stack.dart';
import 'package:pixes/components/loading.dart';
import 'package:pixes/components/novel.dart';
import 'package:pixes/components/segmented_button.dart';
import 'package:pixes/components/title_bar.dart';
import 'package:pixes/foundation/widget_utils.dart';
import 'package:pixes/network/network.dart';
import 'package:pixes/utils/translation.dart';

class FollowingNovelsPage extends StatefulWidget {
  const FollowingNovelsPage({super.key});

  @override
  State<FollowingNovelsPage> createState() => _FollowingNovelsPageState();
}

class _FollowingNovelsPageState extends State<FollowingNovelsPage> {
  bool public = true;
  final pageKeys = <bool, GlobalKey<_OneFollowingNovelsPageState>>{};

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TitleBar(
          title: "Following".tl,
          onRefresh: () => pageKeys[public]?.currentState?.refresh(),
          action: SegmentedButton(
            options: [
              SegmentedButtonOption("public", "Public".tl),
              SegmentedButtonOption("private", "Private".tl),
            ],
            onPressed: (key) {
              var newPublic = key == "public";
              if (newPublic != public) {
                setState(() {
                  public = newPublic;
                });
              }
            },
            value: public ? "public" : "private",
          ),
        ),
        Expanded(
          child: LazyIndexedStack<bool>(
            current: public,
            builder: (context, public) => _OneFollowingNovelsPage(
              public,
              key: pageKeys.putIfAbsent(public, GlobalKey.new),
            ),
          ),
        )
      ],
    );
  }
}

class _OneFollowingNovelsPage extends StatefulWidget {
  const _OneFollowingNovelsPage(this.public, {super.key});

  final bool public;

  @override
  State<_OneFollowingNovelsPage> createState() =>
      _OneFollowingNovelsPageState();
}

class _OneFollowingNovelsPageState
    extends MultiPageLoadingState<_OneFollowingNovelsPage, Novel> {
  @override
  Widget buildContent(BuildContext context, List<Novel> data) {
    return withRefresh(GridViewWithFixedItemHeight(
      itemCount: data.length,
      itemHeight: 164,
      minCrossAxisExtent: 400,
      builder: (context, index) {
        if (index == data.length - 1) {
          nextPage();
        }
        return NovelWidget(data[index]);
      },
    ).paddingHorizontal(8));
  }

  String? nextUrl;

  @override
  Future<void> refresh() {
    nextUrl = null;
    return super.refresh();
  }

  @override
  Future<Res<List<Novel>>> loadData(int page) async {
    if (nextUrl == "end") return Res.error("No more data");
    var res = nextUrl == null
        ? await Network()
            .getFollowingNovels(widget.public ? "public" : "private")
        : await Network().getNovelsWithNextUrl(nextUrl!);
    if (!res.error) {
      nextUrl = res.subData ?? "end";
    }
    return res;
  }
}
