import 'package:fluent_ui/fluent_ui.dart' hide TitleBar;
import 'package:intl/intl.dart';
import 'package:pixes/components/animated_image.dart';
import 'package:pixes/components/grid.dart';
import 'package:pixes/components/lazy_indexed_stack.dart';
import 'package:pixes/components/md.dart';
import 'package:pixes/components/title_bar.dart';
import 'package:pixes/foundation/app.dart';
import 'package:pixes/foundation/image_provider.dart';
import 'package:pixes/foundation/novel_books.dart';
import 'package:pixes/foundation/novel_history.dart';
import 'package:pixes/foundation/novel_progress.dart';
import 'package:pixes/network/network.dart';
import 'package:pixes/pages/novel_page.dart';
import 'package:pixes/utils/translation.dart';

/// The novels opened lately, one for each series or book.
class NovelHistoryPage extends StatefulWidget {
  const NovelHistoryPage({super.key});

  @override
  State<NovelHistoryPage> createState() => _NovelHistoryPageState();
}

class _NovelHistoryPageState extends State<NovelHistoryPage> {
  final store = NovelHistoryStore.instance;

  void open(Novel novel) {
    // The history keeps the novel as it was, so load it again.
    context.to(() => NovelPageWithId(novel.id.toString())).then((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (context) => ContentDialog(
        title: Text("Clear History".tl),
        content: Text("Remove every novel from the history?".tl),
        actions: [
          Button(
            onPressed: () => context.pop(false),
            child: Text("Cancel".tl),
          ),
          FilledButton(
            onPressed: () => context.pop(true),
            child: Text("Clear All".tl),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      setState(store.clear);
    }
  }

  @override
  Widget build(BuildContext context) {
    // The page stays alive while hidden. Depending on its visibility builds
    // it again once shown, with the novels opened meanwhile.
    PageVisibility.of(context);
    final items = latestOfEachBook(store.entries, novelBookKey);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TitleBar(
          title: "History".tl,
          action: items.isEmpty
              ? null
              : Button(
                  onPressed: clear,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(MdIcons.delete_sweep_outlined, size: 18),
                      const SizedBox(width: 6),
                      Text("Clear All".tl),
                    ],
                  ),
                ),
        ),
        Expanded(
          child: items.isEmpty
              ? buildEmpty()
              : GridViewWithFixedItemHeight(
                  itemCount: items.length,
                  itemHeight: 136,
                  minCrossAxisExtent: 400,
                  builder: (context, index) {
                    final item = items[index];
                    return _NovelHistoryTile(
                      item.entry,
                      onTap: () => open(item.entry.novel),
                      onRemove: () {
                        setState(() => store.remove(item.novelIds));
                      },
                    );
                  },
                ).paddingHorizontal(8),
        ),
      ],
    );
  }

  Widget buildEmpty() {
    final outline = ColorScheme.of(context).outline;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(MdIcons.history, size: 48, color: outline),
          const SizedBox(height: 12),
          Text(
            "No history yet".tl,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            "Novels you open show up here".tl,
            textAlign: TextAlign.center,
            style: TextStyle(color: outline),
          ),
        ],
      ).paddingAll(16),
    );
  }
}

class _NovelHistoryTile extends StatelessWidget {
  const _NovelHistoryTile(this.entry,
      {required this.onTap, required this.onRemove});

  final NovelHistoryEntry entry;

  final VoidCallback onTap;

  final VoidCallback onRemove;

  /// The book or series the novel is part of, and which chapter it is.
  String? bookText(Novel novel) {
    final custom = NovelBookStore.instance.bookOf(novel.id);
    if (custom != null) {
      final chapter =
          "Chapter @n".tl.replaceAll("@n", "${custom.indexOf(novel.id) + 1}");
      return "${"Book".tl} · ${custom.title} · $chapter";
    }
    final seriesId = novel.seriesId;
    if (seriesId == null) return null;
    final parts = ["Series".tl, novel.seriesTitle?.trim() ?? ""];
    final last = NovelProgressStore.instance.getSeries(seriesId);
    if (last != null && last.novelId == novel.id && last.chapter != null) {
      parts.add("Chapter @n".tl.replaceAll("@n", "${last.chapter}"));
    }
    return parts.join(" · ");
  }

  /// How much of the novel was read, and when it was opened.
  String statusText(Novel novel) {
    final progress = NovelProgressStore.instance.get(novel.id);
    final now = DateTime.now();
    final time = entry.time;
    final String when;
    if (time.year == now.year &&
        time.month == now.month &&
        time.day == now.day) {
      when = DateFormat("HH:mm").format(time);
    } else if (time.year == now.year) {
      when = DateFormat("MM-dd HH:mm").format(time);
    } else {
      when = DateFormat("yyyy-MM-dd").format(time);
    }
    return [
      if (progress != null && progress.isFinished)
        "Finished".tl
      else if (progress != null && progress.progress >= 0.01)
        "@p read".tl.replaceAll("@p", "${(progress.progress * 100).floor()}%"),
      when,
    ].join(" · ");
  }

  @override
  Widget build(BuildContext context) {
    final novel = entry.novel;
    final book = bookText(novel);
    final outline = ColorScheme.of(context).outline;
    return HoverButton(
      cursor: SystemMouseCursors.click,
      onPressed: onTap,
      builder: (context, states) {
        final theme = FluentTheme.of(context);
        final overlay = states.isPressed
            ? theme.resources.subtleFillColorTertiary
            : states.isHovered
                ? theme.resources.subtleFillColorSecondary
                : Colors.transparent;
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          backgroundColor: Color.alphaBlend(overlay, theme.cardColor),
          child: Row(
            children: [
              Container(
                width: 72,
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
                  image: CachedImageProvider(novel.image),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      novel.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.bold),
                    ),
                    if (book != null)
                      Text(
                        book,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: ColorScheme.of(context).primary,
                        ),
                      ).paddingTop(2),
                    Text(
                      novel.author.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ).paddingTop(2),
                    const Spacer(),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            statusText(novel),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: outline),
                          ),
                        ),
                        Tooltip(
                          message: "Remove from history".tl,
                          child: IconButton(
                            icon: const Icon(MdIcons.close, size: 16),
                            onPressed: onRemove,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
