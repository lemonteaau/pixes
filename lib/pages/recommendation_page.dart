import 'package:flutter/widgets.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:pixes/components/illust_widget.dart';
import 'package:pixes/components/lazy_indexed_stack.dart';
import 'package:pixes/components/loading.dart';
import 'package:pixes/components/title_bar.dart';
import 'package:pixes/foundation/app.dart';
import 'package:pixes/network/network.dart';
import 'package:pixes/pages/illust_page.dart';
import 'package:pixes/utils/block.dart';
import 'package:pixes/utils/translation.dart';

import '../components/grid.dart';
import '../components/slideshow_button.dart';
import '../components/segmented_button.dart';
import '../components/user_preview.dart';

class RecommendationPage extends StatefulWidget {
  const RecommendationPage({super.key});

  @override
  State<RecommendationPage> createState() => _RecommendationPageState();
}

class _RecommendationPageState extends State<RecommendationPage> {
  var type = 0;
  final artworkPageKeys = [
    GlobalKey<_RecommendationArtworksPageState>(),
    GlobalKey<_RecommendationArtworksPageState>(),
  ];
  final userPageKey = GlobalKey<_RecommendationUsersPageState>();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        buildTab(),
        Expanded(
          child: LazyIndexedStack<int>(
            current: type,
            builder: (context, type) => type != 2
                ? _RecommendationArtworksPage(
                    type,
                    key: artworkPageKeys[type],
                  )
                : _RecommendationUsersPage(
                    key: userPageKey,
                  ),
          ),
        )
      ],
    );
  }

  Widget buildTab() {
    return TitleBar(
      wrapActions: true,
      title: "Explore".tl,
      onRefresh: () {
        if (type != 2) {
          artworkPageKeys[type].currentState?.refresh();
        } else {
          userPageKey.currentState?.refresh();
        }
      },
      action: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (type != 2) ...[
            SlideshowButton(
              source: 'Explore'.tl,
              illusts: () =>
                  artworkPageKeys[type].currentState?.loadedData ?? [],
              resumeKey: () =>
                  artworkPageKeys[type].currentState?.loadedDataIdentity,
              nextUrl: () =>
                  artworkPageKeys[type].currentState?.nextUrl ??
                  (type == 0
                      ? Network.recommendationUrl
                      : '/v1/manga/recommended?filter=for_android&include_ranking_illusts=true&include_privacy_policy=true'),
            ),
            const SizedBox(width: 8),
          ],
          SegmentedButton<int>(
            options: [
              SegmentedButtonOption(0, "Illustrations".tl),
              SegmentedButtonOption(1, "Mangas".tl),
              SegmentedButtonOption(2, "Users".tl),
            ],
            onPressed: (key) {
              if (key != type) {
                setState(() {
                  type = key;
                });
              }
            },
            value: type,
          ),
        ],
      ),
    );
  }
}

class _RecommendationArtworksPage extends StatefulWidget {
  const _RecommendationArtworksPage(this.type, {super.key});

  final int type;

  @override
  State<_RecommendationArtworksPage> createState() =>
      _RecommendationArtworksPageState();
}

class _RecommendationArtworksPageState
    extends MultiPageLoadingState<_RecommendationArtworksPage, Illust> {
  @override
  void didUpdateWidget(covariant _RecommendationArtworksPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.type != widget.type) {
      nextUrl = null;
      reset();
    }
  }

  @override
  Widget buildContent(BuildContext context, final List<Illust> data) {
    checkIllusts(data);
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
                  illusts: data,
                  initialPage: index,
                  nextUrl: nextUrl,
                ));
          },
        );
      },
    ));
  }

  String? nextUrl;

  @override
  Future<void> refresh() {
    nextUrl = null;
    return super.refresh();
  }

  @override
  Future<Res<List<Illust>>> loadData(page) async {
    if (nextUrl == 'end') return Res.error('No more data');
    final result = nextUrl != null
        ? await Network().getIllustsWithNextUrl(nextUrl!)
        : widget.type == 0
            ? await Network().getRecommendedIllusts()
            : await Network().getRecommendedMangas();
    if (result.success) nextUrl = result.subData ?? 'end';
    return result;
  }
}

class _RecommendationUsersPage extends StatefulWidget {
  const _RecommendationUsersPage({super.key});

  @override
  State<_RecommendationUsersPage> createState() =>
      _RecommendationUsersPageState();
}

class _RecommendationUsersPageState
    extends MultiPageLoadingState<_RecommendationUsersPage, UserPreview> {
  @override
  Widget buildContent(BuildContext context, List<UserPreview> data) {
    return withRefresh(CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverGridViewWithFixedItemHeight(
          delegate: SliverChildBuilderDelegate((context, index) {
            if (index == data.length - 1) {
              nextPage();
            }
            return UserPreviewWidget(data[index]);
          }, childCount: data.length),
          minCrossAxisExtent: 440,
          itemHeight: 136,
        ).sliverPaddingHorizontal(8)
      ],
    ));
  }

  @override
  Future<Res<List<UserPreview>>> loadData(page) async {
    var res = await Network().getRecommendationUsers();
    return res;
  }
}
