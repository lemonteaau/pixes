import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:pixes/appdata.dart';
import 'package:pixes/components/batch_download.dart';
import 'package:pixes/components/grid.dart';
import 'package:pixes/components/loading.dart';
import 'package:pixes/components/md.dart';
import 'package:pixes/components/novel.dart';
import 'package:pixes/components/segmented_button.dart';
import 'package:pixes/components/user_preview.dart';
import 'package:pixes/foundation/app.dart';
import 'package:pixes/foundation/image_provider.dart';
import 'package:pixes/foundation/novel_books.dart';
import 'package:pixes/network/network.dart';
import 'package:pixes/pages/following_users_page.dart';
import 'package:pixes/pages/novel_book_page.dart';
import 'package:pixes/utils/block.dart';
import 'package:pixes/utils/translation.dart';
import 'package:pixes/pages/illust_viewer.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../components/illust_widget.dart';
import 'illust_page.dart';

class UserInfoPage extends StatefulWidget {
  const UserInfoPage(this.id, {this.selectBookId, super.key});

  final String id;

  /// Opens the user's novels with the chapters of this book selected, so
  /// more can be added to it.
  final int? selectBookId;

  static Map<String, UpdateFollowCallback> followCallbacks = {};

  @override
  State<UserInfoPage> createState() => _UserInfoPageState();
}

class _UserInfoPageState extends LoadingState<UserInfoPage, UserDetails> {
  /// The novels selected to be read as one book.
  final novelSelection = _NovelSelection();

  @override
  void initState() {
    UserInfoPage.followCallbacks[widget.id] = (v) {
      if (data == null) return;
      setState(() {
        data!.isFollowed = v;
      });
    };
    final bookId = widget.selectBookId;
    final book = bookId == null ? null : NovelBookStore.instance.get(bookId);
    if (book != null) {
      page = 4;
      novelSelection.start(book.chapters);
    }
    novelSelection.addListener(_handleSelectionChanged);
    super.initState();
  }

  @override
  void dispose() {
    UserInfoPage.followCallbacks.remove(widget.id);
    novelSelection.dispose();
    super.dispose();
  }

  void _handleSelectionChanged() {
    if (mounted) setState(() {});
  }

  int page = 0;

  @override
  Widget buildContent(BuildContext context, UserDetails data) {
    final selecting = page == 4 && novelSelection.active;
    return ScaffoldPage(
      content: Stack(
        children: [
          Positioned.fill(
            child: CustomScrollView(
              slivers: [
                buildUser(),
                SliverToBoxAdapter(
                  child: buildHeader("Related users".tl),
                ),
                _RelatedUsers(widget.id),
                buildInformation(),
                buildArtworkHeader(),
                if (page == 4)
                  _UserNovels(widget.id, selection: novelSelection)
                else
                  _UserArtworks(
                    data.id.toString(),
                    page,
                    userName: data.name,
                    key: ValueKey(data.id + page),
                  ),
                SliverPadding(
                    padding: EdgeInsets.only(
                        bottom: context.padding.bottom + (selecting ? 72 : 0))),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 16 + context.padding.bottom,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: selecting ? buildSelectionBar() : const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );
  }

  Widget buildSelectionBar() {
    final count = novelSelection.selected.length;
    return Center(
      key: const ValueKey("novel-selection-bar"),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 560),
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: FluentTheme.of(context).menuColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: ColorScheme.of(context).outlineVariant,
            width: 0.6,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.toOpacity(0.16),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Tooltip(
              message: "Cancel".tl,
              child: IconButton(
                icon: const Icon(MdIcons.close, size: 18),
                onPressed: novelSelection.end,
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                count == 0
                    ? "Select novels to read as one book".tl
                    : "@n selected".tl.replaceAll("@n", "$count"),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Button(
              onPressed: novelSelection.selectAll,
              child: Text("Select All".tl),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: count > 0 ? mergeNovels : null,
              child: Text("Merge".tl),
            ),
          ],
        ),
      ),
    );
  }

  /// Makes a book of the selected novels.
  Future<void> mergeNovels() async {
    final merge = NovelBookMerge(novelSelection.selected.values);
    if (merge.chapters.length < 2) {
      context.showToast(message: "Select at least two novels".tl);
      return;
    }
    final book = await showNovelBookMergeDialog(context, merge);
    if (book == null || !mounted) return;
    novelSelection.end();
    if (book.id == widget.selectBookId) {
      // Opened from that book's page to add chapters to it.
      context.pop();
    } else {
      context.to(() => NovelBookPage(book.id));
    }
  }

  bool isFollowing = false;

  void follow() async {
    if (isFollowing) return;
    String type = "";
    if (!data!.isFollowed) {
      await flyoutController.showFlyout(
          navigatorKey: App.rootNavigatorKey.currentState,
          builder: (context) => MenuFlyout(
                items: [
                  MenuFlyoutItem(
                      text: Text("Public".tl),
                      onPressed: () => type = "public"),
                  MenuFlyoutItem(
                      text: Text("Private".tl),
                      onPressed: () => type = "private"),
                ],
              ));
    }
    if (type.isEmpty && !data!.isFollowed) {
      return;
    }
    setState(() {
      isFollowing = true;
    });
    var method = data!.isFollowed ? "delete" : "add";
    var res = await Network().follow(data!.id.toString(), method, type);
    if (res.error) {
      if (mounted) {
        context.showToast(message: "Network Error");
      }
    } else {
      data!.isFollowed = !data!.isFollowed;
      UserPreviewWidget.followCallbacks[data!.id.toString()]
          ?.call(data!.isFollowed);
      IllustPage.updateFollow(data!.id.toString(), data!.isFollowed);
    }
    setState(() {
      isFollowing = false;
    });
  }

  var flyoutController = FlyoutController();

  Widget buildUser() {
    return SliverToBoxAdapter(
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(64),
                border: Border.all(
                    color: ColorScheme.of(context).outlineVariant, width: 0.6)),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(64),
              child: Image(
                image: CachedImageProvider(data!.avatar),
                width: 64,
                height: 64,
                fit: BoxFit.cover,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(data!.name,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: 'Follows: '.tl),
                TextSpan(
                    text: '${data!.totalFollowUsers}',
                    recognizer: TapGestureRecognizer()
                      ..onTap = (() =>
                          context.to(() => FollowingUsersPage(widget.id))),
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: FluentTheme.of(context).accentColor)),
              ],
            ),
            style: const TextStyle(fontSize: 14),
          ),
          if (widget.id != appdata.account?.user.id)
            const SizedBox(
              height: 8,
            ),
          if (widget.id != appdata.account?.user.id)
            if (isFollowing)
              Button(
                  onPressed: follow,
                  child: const SizedBox(
                    width: 42,
                    height: 24,
                    child: Center(
                      child: SizedBox.square(
                        dimension: 18,
                        child: ProgressRing(
                          strokeWidth: 2,
                        ),
                      ),
                    ),
                  ))
            else if (!data!.isFollowed)
              FlyoutTarget(
                  controller: flyoutController,
                  child: Button(onPressed: follow, child: Text("Follow".tl)))
            else
              Button(
                onPressed: follow,
                child: Text(
                  "Unfollow".tl,
                  style: TextStyle(color: ColorScheme.of(context).error),
                ),
              ),
        ],
      ),
    );
  }

  Widget buildHeader(String title, {Widget? action}) {
    return SizedBox(
            width: double.infinity,
            height: 38,
            child: Row(
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ).toAlign(Alignment.centerLeft),
                const Spacer(),
                if (action != null) action.toAlign(Alignment.centerRight)
              ],
            ).paddingHorizontal(16))
        .paddingTop(8);
  }

  Widget buildArtworkHeader() {
    return SliverToBoxAdapter(
      child: SizedBox(
              width: double.infinity,
              height: 38,
              child: Row(
                children: [
                  SegmentedButton<int>(
                    options: [
                      SegmentedButtonOption(0, "Artworks".tl),
                      SegmentedButtonOption(1, "Illustrations".tl),
                      SegmentedButtonOption(2, "Mangas".tl),
                      SegmentedButtonOption(3, "Bookmarks".tl),
                      SegmentedButtonOption(4, "Novels".tl),
                    ],
                    value: page,
                    onPressed: (value) {
                      setState(() {
                        page = value;
                      });
                      if (value != 4) novelSelection.end();
                    },
                  ),
                  const Spacer(),
                  // Only an icon, like the download button of the other
                  // tabs, so the row still fits narrow screens.
                  if (page == 4 && !novelSelection.active)
                    Tooltip(
                      message: "Select novels to read as one book".tl,
                      child: Button(
                        onPressed: novelSelection.start,
                        child: const Icon(MdIcons.checklist, size: 18),
                      ),
                    ),
                  if (page != 4)
                    BatchDownloadButton(
                      request: () {
                        switch (page) {
                          case 0:
                            return Network()
                                .getUserIllusts(data!.id.toString(), null);
                          case 1:
                            return Network()
                                .getUserIllusts(data!.id.toString(), "illust");
                          case 2:
                            return Network()
                                .getUserIllusts(data!.id.toString(), "manga");
                          case 3:
                            return Network()
                                .getUserBookmarks(data!.id.toString());
                        }
                        throw "Invalid page";
                      },
                    ),
                ],
              ).paddingHorizontal(16))
          .paddingTop(12),
    );
  }

  Widget buildInformation() {
    Widget buildItem(
        {IconData? icon,
        required String title,
        required String? content,
        Widget? trailing}) {
      if (content == null || content.isEmpty) {
        return const SizedBox.shrink();
      }
      return Card(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        padding: EdgeInsets.zero,
        child: ListTile(
          title: Row(
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 8),
              Text(title)
            ],
          ),
          subtitle: SelectableText(content).paddingLeft(icon == null ? 0 : 28),
          trailing: trailing,
        ),
      );
    }

    return SliverToBoxAdapter(
      child: Column(
        children: [
          buildHeader("Information".tl),
          buildItem(
              icon: MdIcons.comment_outlined,
              title: "Introduction".tl,
              content: data!.comment),
          buildItem(
              icon: MdIcons.cake_outlined,
              title: "Birthday".tl,
              content: data!.birth),
          buildItem(
              icon: MdIcons.location_city_outlined,
              title: "Region",
              content: data!.region),
          buildItem(
              icon: MdIcons.work_outline, title: "Job".tl, content: data!.job),
          buildItem(
              icon: MdIcons.person_2_outlined,
              title: "Gender".tl,
              content: data!.gender),
          buildHeader("Social Network".tl),
          buildItem(
              title: "Webpage",
              content: data!.webpage,
              trailing: IconButton(
                  icon: const Icon(MdIcons.open_in_new, size: 18),
                  onPressed: () => launchUrlString(data!.twitterUrl!))),
          buildItem(
              title: "Twitter",
              content: data!.twitterUrl,
              trailing: IconButton(
                  icon: const Icon(MdIcons.open_in_new, size: 18),
                  onPressed: () => launchUrlString(data!.twitterUrl!))),
          buildItem(
              title: "pawoo",
              content: data!.pawooUrl,
              trailing: IconButton(
                  icon: const Icon(
                    MdIcons.open_in_new,
                    size: 18,
                  ),
                  onPressed: () => launchUrlString(data!.pawooUrl!))),
        ],
      ),
    );
  }

  @override
  Future<Res<UserDetails>> loadData() {
    return Network().getUserDetails(widget.id);
  }
}

class _UserArtworks extends StatefulWidget {
  const _UserArtworks(this.uid, this.type,
      {required this.userName, super.key});

  final String uid;

  final int type;

  /// Shown as the title of the artwork viewer.
  final String userName;

  @override
  State<_UserArtworks> createState() => _UserArtworksState();
}

class _UserArtworksState extends MultiPageLoadingState<_UserArtworks, Illust> {
  @override
  Widget buildLoading(BuildContext context) {
    return const SliverToBoxAdapter(
      child: SizedBox(
        child: Center(
          child: ProgressRing(),
        ),
      ),
    );
  }

  @override
  Widget buildError(context, error) {
    return SliverToBoxAdapter(
      child: SizedBox(
        child: Center(
          child: Row(
            children: [
              const Icon(FluentIcons.info),
              const SizedBox(
                width: 4,
              ),
              Text(error)
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget buildContent(BuildContext context, List<Illust> data) {
    checkIllusts(data);
    return SliverMasonryGrid(
      gridDelegate: const SliverSimpleGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 240,
      ),
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          if (index == data.length - 1) {
            nextPage();
          }
          return IllustWidget(data[index], onTap: () {
            openIllustFeed(context,
                illusts: data,
                index: index,
                nextUrl: nextUrl,
                source: widget.userName);
          });
        },
        childCount: data.length,
      ),
    ).sliverPaddingHorizontal(8);
  }

  String? nextUrl;

  @override
  Future<Res<List<Illust>>> loadData(page) async {
    if (nextUrl == "end") {
      return Res.error("No more data");
    }
    var res = nextUrl == null
        ? (widget.type != 3
            ? await Network().getUserIllusts(
                widget.uid, [null, "illust", "manga"][widget.type])
            : await Network().getUserBookmarks(widget.uid))
        : await Network().getIllustsWithNextUrl(nextUrl!);
    if (!res.error) {
      nextUrl = res.subData;
      nextUrl ??= "end";
    }
    return res;
  }
}

class _UserNovels extends StatefulWidget {
  const _UserNovels(this.uid, {required this.selection});

  final String uid;

  final _NovelSelection selection;

  @override
  State<_UserNovels> createState() => _UserNovelsState();
}

class _UserNovelsState extends MultiPageLoadingState<_UserNovels, Novel> {
  @override
  Widget buildLoading(BuildContext context) {
    return const SliverToBoxAdapter(
      child: SizedBox(
        child: Center(
          child: ProgressRing(),
        ),
      ),
    );
  }

  @override
  Widget buildError(context, error) {
    return SliverToBoxAdapter(
      child: SizedBox(
        child: Center(
          child: Row(
            children: [
              const Icon(FluentIcons.info),
              const SizedBox(
                width: 4,
              ),
              Text(error)
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget buildContent(BuildContext context, List<Novel> data) {
    checkNovels(data);
    final selection = widget.selection;
    selection.listed = data;
    return SliverGridViewWithFixedItemHeight(
      itemHeight: 164,
      minCrossAxisExtent: 400,
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          if (index == data.length - 1) {
            nextPage();
          }
          final novel = data[index];
          return NovelWidget(
            novel,
            selected: selection.active
                ? selection.selected.containsKey(novel.id)
                : null,
            onTap: selection.active ? () => selection.toggle(novel) : null,
            onLongPress: () {
              if (selection.active) {
                selection.toggle(novel);
              } else {
                selection.start([novel]);
              }
            },
          );
        },
        childCount: data.length,
      ),
    ).sliverPaddingHorizontal(8);
  }

  String? nextUrl;

  @override
  Future<Res<List<Novel>>> loadData(page) async {
    if (nextUrl == "end") {
      return Res.error("No more data");
    }
    var res = nextUrl == null
        ? await Network().getUserNovels(widget.uid)
        : await Network().getNovelsWithNextUrl(nextUrl!);
    if (!res.error) {
      nextUrl = res.subData;
      nextUrl ??= "end";
    }
    return res;
  }
}

class _RelatedUsers extends StatefulWidget {
  const _RelatedUsers(this.uid);

  final String uid;

  @override
  State<_RelatedUsers> createState() => _RelatedUsersState();
}

class _RelatedUsersState
    extends LoadingState<_RelatedUsers, List<UserPreview>> {
  @override
  Widget buildFrame(BuildContext context, Widget child) {
    return SliverToBoxAdapter(
      child: SizedBox(
        height: 146,
        width: double.infinity,
        child: child,
      ),
    );
  }

  final ScrollController _controller = ScrollController();

  @override
  Widget buildContent(BuildContext context, List<UserPreview> data) {
    Widget content = Scrollbar(
        controller: _controller,
        child: ListView.builder(
          controller: _controller,
          padding: const EdgeInsets.only(bottom: 8, left: 8),
          primary: false,
          scrollDirection: Axis.horizontal,
          itemCount: data.length,
          itemBuilder: (context, index) {
            return UserPreviewWidget(data[index]).fixWidth(342);
          },
        ));
    if (App.isDesktop) {
      content = ScrollbarTheme.merge(
          data: const ScrollbarThemeData(
              thickness: 6,
              hoveringThickness: 6,
              mainAxisMargin: 4,
              hoveringPadding: EdgeInsets.zero,
              padding: EdgeInsets.zero,
              hoveringMainAxisMargin: 4,
              crossAxisMargin: 0,
              hoveringCrossAxisMargin: 0),
          child: content);
    } else {
      content = ScrollbarTheme.merge(
          data: const ScrollbarThemeData(
              thickness: 4,
              hoveringThickness: 4,
              mainAxisMargin: 4,
              hoveringPadding: EdgeInsets.zero,
              padding: EdgeInsets.zero,
              hoveringMainAxisMargin: 4,
              crossAxisMargin: 0,
              hoveringCrossAxisMargin: 0),
          child: content);
    }
    return MediaQuery.removePadding(
        context: context, removeBottom: true, child: content);
  }

  @override
  Future<Res<List<UserPreview>>> loadData() {
    return Network().relatedUsers(widget.uid);
  }
}

/// The novels selected on a user's page, to be read as one book.
class _NovelSelection extends ChangeNotifier {
  bool active = false;

  /// The selected novels by id, in the order they were selected.
  final selected = <int, Novel>{};

  /// The novels listed so far, which "Select All" selects.
  List<Novel> listed = const [];

  void start([Iterable<Novel> novels = const []]) {
    active = true;
    for (final novel in novels) {
      selected[novel.id] = novel;
    }
    notifyListeners();
  }

  void toggle(Novel novel) {
    if (selected.remove(novel.id) == null) {
      selected[novel.id] = novel;
    }
    notifyListeners();
  }

  void selectAll() {
    for (final novel in listed) {
      selected[novel.id] = novel;
    }
    notifyListeners();
  }

  void end() {
    if (!active) return;
    active = false;
    selected.clear();
    notifyListeners();
  }
}
