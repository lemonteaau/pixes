import 'dart:collection';

import 'package:fluent_ui/fluent_ui.dart' hide TitleBar;
import 'package:flutter/gestures.dart';
import 'package:pixes/components/animated_image.dart';
import 'package:pixes/components/grid.dart';
import 'package:pixes/components/loading.dart';
import 'package:pixes/components/md.dart';
import 'package:pixes/components/novel.dart';
import 'package:pixes/components/title_bar.dart';
import 'package:pixes/foundation/app.dart';
import 'package:intl/intl.dart';
import 'package:pixes/foundation/image_provider.dart';
import 'package:pixes/foundation/novel_books.dart';
import 'package:pixes/foundation/novel_history.dart';
import 'package:pixes/foundation/novel_progress.dart';
import 'package:pixes/foundation/novel_replace_store.dart';
import 'package:pixes/foundation/optimistic_toggle.dart';
import 'package:pixes/network/network.dart';
import 'package:pixes/pages/comments_page.dart';
import 'package:pixes/pages/novel_book_page.dart';
import 'package:pixes/pages/novel_reading_page.dart';
import 'package:pixes/pages/novel_replace_page.dart';
import 'package:pixes/pages/search_page.dart';
import 'package:pixes/pages/user_info_page.dart';
import 'package:pixes/utils/app_links.dart';
import 'package:pixes/utils/block.dart';
import 'package:pixes/utils/translation.dart';
import 'package:url_launcher/url_launcher_string.dart';

const kFluentButtonPadding = 28.0;

class NovelPage extends StatefulWidget {
  const NovelPage(this.novel, {super.key});

  final Novel novel;

  @override
  State<NovelPage> createState() => _NovelPageState();
}

class _NovelPageState extends State<NovelPage> {
  final scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    NovelHistoryStore.instance.add(widget.novel);
    NovelBookStore.instance.addListener(_update);
  }

  @override
  void dispose() {
    NovelBookStore.instance.removeListener(_update);
    scrollController.dispose();
    super.dispose();
  }

  void _update() {
    if (mounted) setState(() {});
  }

  /// The book the user put this novel in.
  NovelCustomBook? get customBook =>
      NovelBookStore.instance.bookOf(widget.novel.id);

  @override
  Widget build(BuildContext context) {
    final custom = customBook;
    return Scrollbar(
        controller: scrollController,
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: CustomScrollView(
            controller: scrollController,
            slivers: [
              SliverToBoxAdapter(
                child: buildTop(),
              ),
              SliverToBoxAdapter(
                child: buildActions(),
              ),
              SliverToBoxAdapter(
                child: buildDescription(),
              ),
              if (custom != null) _NovelBookChapters(custom),
              if (widget.novel.seriesId != null)
                NovelSeriesWidget(
                    widget.novel.seriesId!, widget.novel.seriesTitle!),
              SliverPadding(
                  padding: EdgeInsets.only(
                      top: 16 + MediaQuery.of(context).padding.bottom)),
            ],
          ),
        ).padding(const EdgeInsets.symmetric(horizontal: 16)));
  }

  Widget buildTop() {
    final badges = buildNovelBadges(context, widget.novel,
        showSeries: false, showBook: false);
    final custom = customBook;
    return Card(
        child: SizedBox(
      height: 144,
      child: Row(
        children: [
          Container(
            width: 96,
            height: double.infinity,
            decoration: BoxDecoration(
              color: ColorScheme.of(context).secondaryContainer,
              borderRadius: BorderRadius.circular(4),
            ),
            clipBehavior: Clip.antiAlias,
            child: AnimatedImage(
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
                width: double.infinity,
                height: double.infinity,
                image: CachedImageProvider(widget.novel.image)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(widget.novel.title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      )),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    for (final badge in badges) badge.paddingRight(4),
                    Flexible(
                      child: Text(
                        novelLengthText(widget.novel),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: ColorScheme.of(context).outline,
                        ),
                      ),
                    ),
                  ],
                ),
                if (widget.novel.seriesId != null)
                  Text(
                    overflow: TextOverflow.ellipsis,
                    "${"Series".tl}: ${widget.novel.seriesTitle!}",
                    style: TextStyle(
                      color: ColorScheme.of(context).primary,
                      fontSize: 12,
                    ),
                  ).paddingVertical(4),
                if (custom != null)
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () => openReader(NovelBookPage(custom.id)),
                      child: Text(
                        overflow: TextOverflow.ellipsis,
                        "${"Book".tl}: ${custom.title}",
                        style: TextStyle(
                          color: ColorScheme.of(context).primary,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ).paddingVertical(4),
              ],
            ),
          ),
        ],
      ),
    )).paddingTop(12);
  }

  Widget buildStats() {
    return Container(
      height: 74,
      constraints: const BoxConstraints(maxWidth: 560),
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          const SizedBox(width: 2),
          Expanded(
            child: Container(
              height: 68,
              decoration: BoxDecoration(
                border: Border.all(
                  color: ColorScheme.of(context).outlineVariant,
                  width: 0.6,
                ),
                borderRadius: BorderRadius.circular(4),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        FluentIcons.view,
                        size: 20,
                      ),
                      Text(
                        "Views".tl,
                        style: const TextStyle(fontSize: 12),
                      )
                    ],
                  ),
                  const SizedBox(width: 8),
                  Text(
                    formatCount(widget.novel.totalViews),
                    style: TextStyle(
                      color: ColorScheme.of(context).primary,
                      fontWeight: FontWeight.w500,
                      fontSize: 18,
                    ),
                  )
                ],
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
              child: Container(
            height: 68,
            decoration: BoxDecoration(
              border: Border.all(
                color: ColorScheme.of(context).outlineVariant,
                width: 0.6,
              ),
              borderRadius: BorderRadius.circular(4),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      FluentIcons.six_point_star,
                      size: 20,
                    ),
                    Text(
                      "Favorites".tl,
                      style: const TextStyle(fontSize: 12),
                    )
                  ],
                ),
                const SizedBox(width: 8),
                Text(
                  formatCount(widget.novel.totalBookmarks),
                  style: TextStyle(
                    color: ColorScheme.of(context).primary,
                    fontWeight: FontWeight.w500,
                    fontSize: 18,
                  ),
                )
              ],
            ),
          )),
          const SizedBox(width: 2),
        ],
      ),
    );
  }

  Widget buildAuthor() {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Card(
        margin: const EdgeInsets.only(left: 2, right: 2, bottom: 12),
        borderColor: ColorScheme.of(context).outlineVariant.toOpacity(0.52),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            context.to(() => UserInfoPage(widget.novel.author.id.toString()));
          },
          child: SizedBox(
            height: 38,
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: ColorScheme.of(context).secondaryContainer,
                    borderRadius: BorderRadius.circular(36),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: AnimatedImage(
                    fit: BoxFit.cover,
                    width: 36,
                    height: 36,
                    filterQuality: FilterQuality.medium,
                    image: CachedImageProvider(widget.novel.author.avatar),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        widget.novel.author.name,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        DateFormat("yyyy-MM-dd")
                            .format(widget.novel.createDate.toLocal()),
                        style: TextStyle(
                          fontSize: 12,
                          color: ColorScheme.of(context).outline,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(MdIcons.chevron_right)
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Opens [page] and refreshes the reading progress shown here once the
  /// user comes back.
  void openReader(Widget page) {
    context.to(() => page).then((_) {
      if (mounted) setState(() {});
    });
  }

  /// Offers to go back to the chapter of the book or series that was read
  /// last, if it's not this one.
  Widget buildSeriesContinue() {
    final int novelId;
    final int? chapter;
    final String title;
    final Widget Function() reader;
    final custom = customBook;
    final seriesId = widget.novel.seriesId;
    if (custom != null) {
      final lastRead = custom.lastReadId;
      final index = lastRead == null ? -1 : custom.indexOf(lastRead);
      if (index < 0) return const SizedBox.shrink();
      final last = custom.chapters[index];
      novelId = last.id;
      chapter = index + 1;
      title = last.title;
      reader = () => NovelReadingPage(last, resume: true);
    } else if (seriesId != null) {
      final last = NovelProgressStore.instance.getSeries(seriesId);
      if (last == null) return const SizedBox.shrink();
      novelId = last.novelId;
      chapter = last.chapter;
      title = last.title;
      reader =
          () => NovelReadingPageWithId(last.novelId.toString(), resume: true);
    } else {
      return const SizedBox.shrink();
    }
    if (novelId == widget.novel.id) return const SizedBox.shrink();
    final label = chapter != null
        ? "Continue chapter @n".tl.replaceAll("@n", "$chapter")
        : "Continue Reading".tl;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Button(
        onPressed: () => openReader(reader()),
        child: Row(
          children: [
            const Icon(MdIcons.history, size: 18),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                "$label · $title",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(MdIcons.chevron_right, size: 18),
          ],
        ).fixHeight(32),
      ),
    ).paddingTop(8).paddingHorizontal(2);
  }

  var favoriteFlyout = FlyoutController();

  Widget buildActions() {
    void favorite() async {
      bool? public;
      if (!widget.novel.isBookmarked) {
        await favoriteFlyout.showFlyout(
          navigatorKey: App.rootNavigatorKey.currentState!,
          builder: (context) {
            return MenuFlyout(
              items: [
                MenuFlyoutItem(
                  text: Text("Public".tl),
                  onPressed: () {
                    public = true;
                  },
                ),
                MenuFlyoutItem(
                  text: Text("Private".tl),
                  onPressed: () {
                    public = false;
                  },
                ),
              ],
            );
          },
        );
        if (public == null) {
          return;
        }
      }
      setState(() {
        setNovelBookmarked(widget.novel, !widget.novel.isBookmarked,
            public: public ?? true);
      });
    }

    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      return Card(
        margin: const EdgeInsets.only(top: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (width < 560) buildAuthor().toAlign(Alignment.centerLeft),
            if (width < 560) buildStats().toAlign(Alignment.centerLeft),
            if (width >= 560)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1132),
                child: Row(
                  children: [
                    Expanded(child: buildAuthor()),
                    const SizedBox(width: 12),
                    Expanded(child: buildStats()),
                  ],
                ),
              ).toAlign(Alignment.centerLeft),
            LayoutBuilder(
              builder: (context, constrains) {
                var width = constrains.maxWidth;
                bool shouldFillSpace = width < 500;
                bool showLabels = constrains.maxWidth > 420;
                Widget sized(Widget child, double fillWidth) {
                  return (shouldFillSpace ? child.fixWidth(fillWidth) : child)
                      .fixHeight(32);
                }

                final progress =
                    NovelProgressStore.instance.get(widget.novel.id);
                final canContinue = progress != null && !progress.isFinished;
                final comments = widget.novel.commentsCount;
                return Row(
                  children: [
                    FilledButton(
                        child: Row(
                          children: [
                            const Icon(MdIcons.menu_book_outlined, size: 18),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                canContinue
                                    ? "Continue Reading".tl
                                    : "Read".tl,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const Icon(MdIcons.chevron_right, size: 18)
                                .paddingTop(2),
                          ],
                        )
                            .fixWidth(shouldFillSpace
                                ? width / 2 - 4 - kFluentButtonPadding
                                : 220)
                            .fixHeight(32),
                        onPressed: () {
                          openReader(NovelReadingPage(widget.novel,
                              resume: canContinue));
                        }),
                    const SizedBox(width: 16),
                    FlyoutTarget(
                      controller: favoriteFlyout,
                      child: Button(
                        onPressed: favorite,
                        child: sized(
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: showLabels
                                ? MainAxisAlignment.start
                                : MainAxisAlignment.center,
                            children: [
                              if (widget.novel.isBookmarked)
                                Icon(
                                  MdIcons.favorite,
                                  size: 18,
                                  color: ColorScheme.of(context).error,
                                )
                              else
                                const Icon(MdIcons.favorite_outline, size: 18),
                              if (showLabels) const SizedBox(width: 12),
                              if (showLabels)
                                Flexible(
                                  child: Text(
                                    "Favorite".tl,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                          ),
                          width / 4 - 4 - kFluentButtonPadding,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Button(
                        child: sized(
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: showLabels
                                ? MainAxisAlignment.start
                                : MainAxisAlignment.center,
                            children: [
                              const Icon(MdIcons.comment, size: 18),
                              if (showLabels) const SizedBox(width: 12),
                              if (showLabels)
                                Flexible(
                                  child: Text(
                                    "Comments".tl,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              if (comments > 0) ...[
                                SizedBox(width: showLabels ? 6 : 4),
                                Text(
                                  formatCount(comments),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: ColorScheme.of(context).outline,
                                  ),
                                ),
                              ],
                            ],
                          ),
                          width / 4 - 4 - kFluentButtonPadding,
                        ),
                        onPressed: () {
                          CommentsPage.show(context, widget.novel.id.toString(),
                              isNovel: true);
                        }),
                  ],
                );
              },
            ).paddingHorizontal(2),
            buildSeriesContinue(),
            SelectableText(
              "ID: ${widget.novel.id}",
              style: TextStyle(
                  fontSize: 13, color: ColorScheme.of(context).outline),
            ).paddingTop(8).paddingLeft(2),
          ],
        ),
      );
    });
  }

  Widget buildDescription() {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Description".tl,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          SelectableText.rich(
              TextSpan(children: buildDescriptionText().toList())),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.start,
              children: [
                for (final tag in widget.novel.tags)
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () {
                        context.to(() => SearchNovelResultPage(tag.name));
                      },
                      child: Container(
                        margin: const EdgeInsets.only(right: 8, bottom: 6),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: ColorScheme.of(context).primaryContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          tag.name,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Button(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(MdIcons.auto_awesome_outlined, size: 18),
                      const SizedBox(width: 12),
                      Text("Related".tl)
                    ],
                  ).fixHeight(32),
                  onPressed: () {
                    context.to(
                        () => _RelatedNovelsPage(widget.novel.id.toString()));
                  }),
              buildReplaceButton(),
            ],
          ),
        ],
      ),
    ).paddingTop(12);
  }

  /// Opens the word replacements of the book this novel belongs to.
  Widget buildReplaceButton() {
    final count = NovelReplaceStore.instance
        .rules(NovelReplaceStore.bookOf(widget.novel))
        .length;
    return Button(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(MdIcons.find_replace, size: 18),
            const SizedBox(width: 12),
            Text("Word Replacement".tl),
            if (count > 0) ...[
              const SizedBox(width: 6),
              Text(
                "$count",
                style: TextStyle(
                  fontSize: 12,
                  color: ColorScheme.of(context).outline,
                ),
              ),
            ],
          ],
        ).fixHeight(32),
        onPressed: () {
          context.to(() => NovelReplacePage(widget.novel)).then((_) {
            if (mounted) setState(() {});
          });
        });
  }

  Iterable<TextSpan> buildDescriptionText() sync* {
    var text = widget.novel.caption;
    text = text.replaceAll("<br />", "\n");
    text = text.replaceAll('\n\n', '\n');
    var labels = Queue<String>();
    var buffer = StringBuffer();
    var style = const TextStyle();
    String? link;
    Map<String, String> attributes = {};
    for (int i = 0; i < text.length; i++) {
      if (text[i] == '<' && text[i + 1] != '/') {
        var label =
            text.substring(i + 1, text.indexOf('>', i)).split(' ').first;
        labels.addLast(label);
        for (var part
            in text.substring(i + 1, text.indexOf('>', i)).split(' ')) {
          var kv = part.split('=');
          if (kv.length >= 2) {
            attributes[kv[0]] =
                kv.join('=').substring(kv[0].length + 2).replaceAll('"', '');
          }
        }
        i = text.indexOf('>', i);
      } else if (text[i] == '<' && text[i + 1] == '/') {
        var label = text.substring(i + 2, text.indexOf('>', i));
        if (label == labels.last) {
          switch (label) {
            case "strong":
              style = style.copyWith(fontWeight: FontWeight.bold);
            case "a":
              style = style.copyWith(color: ColorScheme.of(context).primary);
              link = attributes["href"];
          }
          labels.removeLast();
        }
        i = text.indexOf('>', i);
      } else {
        buffer.write(text[i]);
      }

      if (i + 1 >= text.length ||
          (labels.isEmpty &&
              (text[i + 1] == '<' || (i != 0 && text[i - 1] == '>')))) {
        var content = buffer.toString();
        var url = link;
        yield TextSpan(
            text: content,
            style: style,
            recognizer: url != null
                ? (TapGestureRecognizer()
                  ..onTap = () {
                    if (!handleLink(Uri.parse(url))) {
                      launchUrlString(url);
                    }
                  })
                : null);
        buffer.clear();
        link = null;
        attributes.clear();
        style = const TextStyle();
      }
    }
  }
}

/// The chapters of the book the user put a novel in.
class _NovelBookChapters extends StatelessWidget {
  const _NovelBookChapters(this.book);

  final NovelCustomBook book;

  @override
  Widget build(BuildContext context) {
    return DecoratedSliver(
      decoration: BoxDecoration(
          color: FluentTheme.of(context).cardColor,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: ColorScheme.of(context).outlineVariant.toOpacity(0.6),
            width: 0.5,
          )),
      sliver: SliverMainAxisGroup(slivers: [
        SliverToBoxAdapter(
          child: Row(
            children: [
              Expanded(
                child: Text(book.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    )),
              ),
              const SizedBox(width: 8),
              Button(
                onPressed: () => context.to(() => NovelBookPage(book.id)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text("@n chapters"
                        .tl
                        .replaceAll("@n", "${book.chapters.length}")),
                    const SizedBox(width: 4),
                    const Icon(MdIcons.chevron_right, size: 16),
                  ],
                ),
              ),
            ],
          ).paddingTop(16).paddingLeft(12).paddingRight(12),
        ),
        const SliverPadding(padding: EdgeInsets.only(top: 8)),
        SliverGridViewWithFixedItemHeight(
          itemHeight: 164,
          minCrossAxisExtent: 400,
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final chapter = book.chapters[index];
              return NovelWidget(
                chapter,
                // The chapters are saved as they were when added, so load
                // them again for their page.
                onTap: () =>
                    context.to(() => NovelPageWithId(chapter.id.toString())),
              );
            },
            childCount: book.chapters.length,
          ),
        ).sliverPadding(const EdgeInsets.symmetric(horizontal: 8)),
      ]),
    ).sliverPadding(const EdgeInsets.only(top: 16));
  }
}

class NovelSeriesWidget extends StatefulWidget {
  const NovelSeriesWidget(this.seriesId, this.title, {super.key});

  final int seriesId;

  final String title;

  @override
  State<NovelSeriesWidget> createState() => _NovelSeriesWidgetState();
}

class _NovelSeriesWidgetState
    extends MultiPageLoadingState<NovelSeriesWidget, Novel> {
  @override
  Widget? buildFrame(BuildContext context, Widget child) {
    return DecoratedSliver(
      decoration: BoxDecoration(
          color: FluentTheme.of(context).cardColor,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: ColorScheme.of(context).outlineVariant.toOpacity(0.6),
            width: 0.5,
          )),
      sliver: SliverMainAxisGroup(slivers: [
        SliverToBoxAdapter(
          child: Text(widget.title.trim(),
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              )).paddingTop(16).paddingLeft(12).paddingRight(12),
        ),
        const SliverPadding(padding: EdgeInsets.only(top: 8)),
        child
      ]),
    ).sliverPadding(const EdgeInsets.only(top: 16));
  }

  @override
  Widget buildLoading(BuildContext context) {
    return SliverToBoxAdapter(
      child: const Center(
        child: ProgressRing(),
      ).fixHeight(124),
    );
  }

  @override
  Widget buildError(BuildContext context, String error) {
    return SliverToBoxAdapter(
      child: Center(
        child: Text(error),
      ).fixHeight(124),
    );
  }

  @override
  Widget buildContent(BuildContext context, final List<Novel> data) {
    return SliverGridViewWithFixedItemHeight(
      itemHeight: 164,
      minCrossAxisExtent: 400,
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          if (index == data.length - 1) {
            nextPage();
          }
          return NovelWidget(data[index]);
        },
        childCount: data.length,
      ),
    ).sliverPadding(const EdgeInsets.symmetric(horizontal: 8));
  }

  String? nextUrl;

  @override
  Future<Res<List<Novel>>> loadData(page) async {
    if (nextUrl == "end") {
      return Res.error("No more data");
    }
    var res =
        await Network().getNovelSeries(widget.seriesId.toString(), nextUrl);
    if (!res.error) {
      nextUrl = res.subData;
      nextUrl ??= "end";
    }
    return res;
  }
}

class NovelPageWithId extends StatefulWidget {
  const NovelPageWithId(this.id, {super.key});

  final String id;

  @override
  State<NovelPageWithId> createState() => _NovelPageWithIdState();
}

class _NovelPageWithIdState extends LoadingState<NovelPageWithId, Novel> {
  @override
  Future<Res<Novel>> loadData() async {
    return Network().getNovelDetail(widget.id);
  }

  @override
  Widget buildContent(BuildContext context, Novel data) {
    return NovelPage(data);
  }
}

class _RelatedNovelsPage extends StatefulWidget {
  const _RelatedNovelsPage(this.id);

  final String id;

  @override
  State<_RelatedNovelsPage> createState() => __RelatedNovelsPageState();
}

class __RelatedNovelsPageState
    extends LoadingState<_RelatedNovelsPage, List<Novel>> {
  @override
  Widget buildContent(BuildContext context, List<Novel> data) {
    checkNovels(data);
    return Column(
      children: [
        TitleBar(title: "Related Novels".tl),
        Expanded(
            child: GridViewWithFixedItemHeight(
          itemHeight: 164,
          itemCount: data.length,
          minCrossAxisExtent: 400,
          builder: (context, index) {
            return NovelWidget(data[index]);
          },
        )),
      ],
    );
  }

  @override
  Future<Res<List<Novel>>> loadData() async {
    return Network().relatedNovels(widget.id);
  }
}
