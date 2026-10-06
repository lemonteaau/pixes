import 'package:fluent_ui/fluent_ui.dart' hide TitleBar;
import 'package:pixes/components/animated_image.dart';
import 'package:pixes/components/md.dart';
import 'package:pixes/components/novel.dart';
import 'package:pixes/components/title_bar.dart';
import 'package:pixes/foundation/app.dart';
import 'package:pixes/foundation/image_provider.dart';
import 'package:pixes/foundation/novel_books.dart';
import 'package:pixes/foundation/novel_progress.dart';
import 'package:pixes/foundation/novel_replace_store.dart';
import 'package:pixes/network/network.dart';
import 'package:pixes/pages/novel_page.dart';
import 'package:pixes/pages/novel_reading_page.dart';
import 'package:pixes/pages/novel_replace_page.dart';
import 'package:pixes/pages/user_info_page.dart';
import 'package:pixes/utils/translation.dart';

/// A book the user made of separate novels: its chapters, which can be
/// reordered and removed, and where to continue reading.
class NovelBookPage extends StatefulWidget {
  const NovelBookPage(this.bookId, {super.key});

  final int bookId;

  @override
  State<NovelBookPage> createState() => _NovelBookPageState();
}

class _NovelBookPageState extends State<NovelBookPage> {
  final store = NovelBookStore.instance;

  @override
  void initState() {
    super.initState();
    store.addListener(_update);
    NovelReplaceStore.instance.addListener(_update);
  }

  @override
  void dispose() {
    store.removeListener(_update);
    NovelReplaceStore.instance.removeListener(_update);
    super.dispose();
  }

  void _update() {
    if (mounted) setState(() {});
  }

  /// Opens [page] and shows the progress made there once the user is back.
  void open(Widget page) {
    context.to(() => page).then((_) => _update());
  }

  /// The chapter to go on with: the one read last, or the next one if that
  /// was finished. Null if nothing was read yet.
  int? continueIndex(NovelCustomBook book) {
    final lastRead = book.lastReadId;
    if (lastRead == null) return null;
    final index = book.indexOf(lastRead);
    if (index < 0) return null;
    final finished =
        NovelProgressStore.instance.get(lastRead)?.isFinished ?? false;
    return finished && index + 1 < book.chapters.length ? index + 1 : index;
  }

  @override
  Widget build(BuildContext context) {
    final book = store.get(widget.bookId);
    if (book == null) {
      return Column(
        children: [
          TitleBar(title: "Book".tl),
          Expanded(
            child: Center(child: Text("This book was split".tl)),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TitleBar(
          title: "Book".tl,
          action: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Tooltip(
                message: "Rename".tl,
                child: IconButton(
                  icon: const Icon(MdIcons.edit_outlined, size: 18),
                  onPressed: () => rename(book),
                ),
              ),
              Tooltip(
                message: "Split the book".tl,
                child: IconButton(
                  icon: const Icon(MdIcons.call_split, size: 18),
                  onPressed: () => split(book),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: buildSummary(book)),
              SliverToBoxAdapter(child: buildChaptersHeader(book)),
              SliverReorderableList(
                itemCount: book.chapters.length,
                itemBuilder: (context, index) => buildChapter(book, index),
                onReorderItem: (from, to) => reorder(book, from, to),
              ),
              SliverPadding(
                padding: EdgeInsets.only(
                    bottom: 16 + MediaQuery.paddingOf(context).bottom),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget buildSummary(NovelCustomBook book) {
    final first = book.chapters.first;
    final chars = book.chapters.fold<int>(0, (sum, n) => sum + n.length);
    final outline = ColorScheme.of(context).outline;
    final next = continueIndex(book);
    final rules = NovelReplaceStore.instance.rules(book.key).length;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 108,
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
                    image: CachedImageProvider(first.image),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        book.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        first.author.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                      const Spacer(),
                      Text(
                        "${"@n chapters".tl.replaceAll("@n", "${book.chapters.length}")}"
                        " · ${"@n chars".tl.replaceAll("@n", formatCount(chars))}",
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: outline),
                      ),
                    ],
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
              FilledButton(
                onPressed: () {
                  open(next == null
                      ? NovelReadingPage(first)
                      : NovelReadingPage(book.chapters[next], resume: true));
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(MdIcons.menu_book_outlined, size: 18),
                    const SizedBox(width: 8),
                    Text(next == null
                        ? "Read".tl
                        : "Continue chapter @n"
                            .tl
                            .replaceAll("@n", "${next + 1}")),
                  ],
                ).fixHeight(24),
              ),
              Button(
                onPressed: () => open(NovelReplacePage(first)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(MdIcons.find_replace, size: 18),
                    const SizedBox(width: 8),
                    Text("Word Replacement".tl),
                    if (rules > 0) ...[
                      const SizedBox(width: 6),
                      Text(
                        "$rules",
                        style: TextStyle(fontSize: 12, color: outline),
                      ),
                    ],
                  ],
                ).fixHeight(24),
              ),
            ],
          ),
        ],
      ),
    ).paddingTop(4);
  }

  Widget buildChaptersHeader(NovelCustomBook book) {
    return Row(
      children: [
        Expanded(
          child: Text(
            "Chapters".tl,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ),
        Button(
          onPressed: () {
            open(UserInfoPage(book.chapters.first.author.id.toString(),
                selectBookId: book.id));
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(MdIcons.add, size: 16),
              const SizedBox(width: 6),
              Text("Add Chapters".tl),
            ],
          ),
        ),
      ],
    ).paddingHorizontal(20).paddingTop(16).paddingBottom(8);
  }

  Widget buildChapter(NovelCustomBook book, int index) {
    final chapter = book.chapters[index];
    final progress = NovelProgressStore.instance.get(chapter.id);
    final status = [
      if (progress != null && progress.isFinished)
        "Finished".tl
      else if (progress != null && progress.progress >= 0.01)
        "@p read".tl.replaceAll("@p", "${(progress.progress * 100).floor()}%"),
      if (chapter.id == book.lastReadId) "Last read".tl,
    ].join(" · ");
    return Card(
      key: ValueKey(chapter.id),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
      padding: EdgeInsets.zero,
      child: ListTile(
        onPressed: () => open(NovelReadingPage(chapter)),
        leading: SizedBox(
          width: 28,
          child: Text(
            "${index + 1}",
            textAlign: TextAlign.center,
            style: TextStyle(
              color: ColorScheme.of(context).primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        title: Text(
          chapter.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: status.isEmpty ? null : Text(status),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message: "Details".tl,
              child: IconButton(
                icon: const Icon(MdIcons.info_outline, size: 18),
                onPressed: () {
                  open(NovelPageWithId(chapter.id.toString()));
                },
              ),
            ),
            Tooltip(
              message: "Remove from the book".tl,
              child: IconButton(
                icon: const Icon(MdIcons.remove_circle_outline, size: 18),
                onPressed: () => remove(book, chapter),
              ),
            ),
            ReorderableDragStartListener(
              index: index,
              child: const MouseRegion(
                cursor: SystemMouseCursors.grab,
                child: Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(MdIcons.drag_handle, size: 20),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void reorder(NovelCustomBook book, int from, int to) {
    if (to == from) return;
    final chapters = [...book.chapters];
    chapters.insert(to, chapters.removeAt(from));
    store.update(book.id, chapters: chapters);
  }

  void remove(NovelCustomBook book, Novel chapter) {
    if (book.chapters.length == 1) {
      split(book);
      return;
    }
    store.update(book.id, chapters: [
      for (final novel in book.chapters)
        if (novel.id != chapter.id) novel,
    ]);
  }

  Future<void> rename(NovelCustomBook book) async {
    final title = await showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (context) => _RenameDialog(book.title),
    );
    if (title != null) {
      store.update(book.id, title: title);
    }
  }

  Future<void> split(NovelCustomBook book) async {
    final rules = NovelReplaceStore.instance.rules(book.key).length;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (context) => ContentDialog(
        title: Text("Split the book".tl),
        content: Text([
          "The chapters become separate novels again.".tl,
          if (rules > 0)
            "The @n word replacements of the book are deleted."
                .tl
                .replaceAll("@n", "$rules"),
        ].join("\n")),
        actions: [
          Button(
            onPressed: () => context.pop(false),
            child: Text("Cancel".tl),
          ),
          FilledButton(
            onPressed: () => context.pop(true),
            child: Text("Split".tl),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      store.delete(book.id);
      if (mounted) context.pop();
    }
  }
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog(this.title);

  final String title;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final controller = TextEditingController(text: widget.title);

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void submit() {
    final title = controller.text.trim();
    if (title.isEmpty) return;
    context.pop(title);
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: Text("Rename".tl),
      content: TextBox(
        controller: controller,
        autofocus: true,
        onSubmitted: (_) => submit(),
      ),
      actions: [
        Button(onPressed: () => context.pop(), child: Text("Cancel".tl)),
        FilledButton(onPressed: submit, child: Text("Save".tl)),
      ],
    );
  }
}

/// Asks for the title of the book [merge] makes and merges the novels.
/// Returns the book, or null if the user cancelled.
Future<NovelCustomBook?> showNovelBookMergeDialog(
    BuildContext context, NovelBookMerge merge) {
  return showDialog<NovelCustomBook>(
    context: context,
    barrierDismissible: true,
    builder: (context) => _MergeDialog(merge),
  );
}

class _MergeDialog extends StatefulWidget {
  const _MergeDialog(this.merge);

  final NovelBookMerge merge;

  @override
  State<_MergeDialog> createState() => _MergeDialogState();
}

class _MergeDialogState extends State<_MergeDialog> {
  late final controller =
      TextEditingController(text: widget.merge.suggestedTitle);

  String? error;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void submit() {
    final title = controller.text.trim();
    if (title.isEmpty) {
      setState(() {
        error = "Enter a title".tl;
      });
      return;
    }
    context.pop(widget.merge.apply(title));
  }

  @override
  Widget build(BuildContext context) {
    final merge = widget.merge;
    final target = merge.target;
    final existing = {
      for (final novel in target?.chapters ?? const <Novel>[]) novel.id,
    };
    final outline = ColorScheme.of(context).outline;
    final primary = ColorScheme.of(context).primary;
    final notes = [
      if (target != null)
        "Added to the book @s".tl.replaceAll("@s", target.title)
      else
        "Ordered by publish date. You can reorder them on the book's page.".tl,
      if (merge.rules.isNotEmpty)
        "The @n word replacements of these novels now apply to the whole book."
            .tl
            .replaceAll("@n", "${merge.rules.length}")
      else
        "Word replacements then apply to every chapter.".tl,
    ];
    return ContentDialog(
      title: Text("Merge into a Book".tl),
      constraints: const BoxConstraints(maxWidth: 480),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InfoLabel(
            label: "Title".tl,
            child: TextBox(
              controller: controller,
              onSubmitted: (_) => submit(),
            ),
          ),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: ColorScheme.of(context).error),
            ).paddingTop(8),
          const SizedBox(height: 12),
          Text(
            "@n chapters".tl.replaceAll("@n", "${merge.chapters.length}"),
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: merge.chapters.length,
              itemBuilder: (context, index) {
                final novel = merge.chapters[index];
                final added = target != null && !existing.contains(novel.id);
                return Text(
                  "${index + 1}. ${novel.title}",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: added
                      ? TextStyle(color: primary, fontWeight: FontWeight.bold)
                      : null,
                ).paddingVertical(2);
              },
            ),
          ),
          const SizedBox(height: 12),
          for (final note in notes)
            Text(note, style: TextStyle(fontSize: 13, color: outline))
                .paddingBottom(4),
        ],
      ),
      actions: [
        Button(onPressed: () => context.pop(), child: Text("Cancel".tl)),
        FilledButton(onPressed: submit, child: Text("Merge".tl)),
      ],
    );
  }
}
