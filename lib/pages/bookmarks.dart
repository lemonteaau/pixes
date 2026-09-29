import 'package:fluent_ui/fluent_ui.dart' hide TitleBar;
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:pixes/components/batch_download.dart';
import 'package:pixes/components/segmented_button.dart';
import 'package:pixes/components/slideshow_button.dart';
import 'package:pixes/components/title_bar.dart';
import 'package:pixes/appdata.dart';
import 'package:pixes/foundation/app.dart';
import 'package:pixes/network/network.dart';
import 'package:pixes/pages/illust_page.dart';
import 'package:pixes/utils/translation.dart';

import '../components/illust_widget.dart';
import '../components/lazy_indexed_stack.dart';
import '../components/loading.dart';

class BookMarkedArtworkPage extends StatefulWidget {
  const BookMarkedArtworkPage({super.key});

  @override
  State<BookMarkedArtworkPage> createState() => _BookMarkedArtworkPageState();
}

class _BookMarkedArtworkPageState extends State<BookMarkedArtworkPage> {
  String restrict = "public";
  final pageKeys = <String, GlobalKey<_OneBookmarkedPageState>>{};

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        buildTab(),
        Expanded(
          child: LazyIndexedStack<String>(
            current: restrict,
            builder: (context, restrict) => _OneBookmarkedPage(
              restrict,
              key: pageKeys.putIfAbsent(restrict, GlobalKey.new),
            ),
          ),
        )
      ],
    );
  }

  Widget buildTab() {
    return TitleBar(
      wrapActions: true,
      title: "Bookmarks".tl,
      onRefresh: () => pageKeys[restrict]?.currentState?.refresh(),
      action: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SlideshowButton(
            source: 'Bookmarks'.tl,
            illusts: () => pageKeys[restrict]?.currentState?.loadedData ?? [],
            resumeKey: () =>
                pageKeys[restrict]?.currentState?.loadedDataIdentity,
            nextUrl: () =>
                pageKeys[restrict]?.currentState?.nextUrl ??
                '/v1/user/bookmarks/illust?user_id=${appdata.account?.user.id}&restrict=$restrict',
          ),
          const SizedBox(width: 8),
          BatchDownloadButton(
              request: () => Network().getBookmarkedIllusts(restrict)),
          const SizedBox(
            width: 8,
          ),
          SegmentedButton(
            options: [
              SegmentedButtonOption("public", "Public".tl),
              SegmentedButtonOption("private", "Private".tl),
            ],
            onPressed: (key) {
              if (key != restrict) {
                setState(() {
                  restrict = key;
                });
              }
            },
            value: restrict,
          )
        ],
      ),
    );
  }
}

class _OneBookmarkedPage extends StatefulWidget {
  const _OneBookmarkedPage(this.restrict, {super.key});

  final String restrict;

  @override
  State<_OneBookmarkedPage> createState() => _OneBookmarkedPageState();
}

class _OneBookmarkedPageState
    extends MultiPageLoadingState<_OneBookmarkedPage, Illust> {
  @override
  Future<void> refresh() {
    nextUrl = null;
    return super.refresh();
  }

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
        return IllustWidget(
          data[index],
          onTap: () {
            context.to(() => IllustGalleryPage(
                illusts: data, initialPage: index, nextUrl: nextUrl));
          },
        );
      },
    ));
  }

  String? nextUrl;

  @override
  Future<Res<List<Illust>>> loadData(page) async {
    if (nextUrl == "end") {
      return Res.error("No more data");
    }
    var res = await Network().getBookmarkedIllusts(widget.restrict, nextUrl);
    if (!res.error) {
      nextUrl = res.subData;
      nextUrl ??= "end";
    }
    return res;
  }
}
