import 'package:fluent_ui/fluent_ui.dart' hide TitleBar;
import 'package:pixes/components/md.dart';
import 'package:pixes/components/segmented_button.dart';
import 'package:pixes/components/title_bar.dart';
import 'package:pixes/foundation/app.dart';
import 'package:pixes/foundation/novel_book_text.dart';
import 'package:pixes/foundation/novel_replace_store.dart';
import 'package:pixes/network/network.dart';
import 'package:pixes/pages/novel_reading_page.dart';
import 'package:pixes/utils/novel_replace.dart';
import 'package:pixes/utils/translation.dart';

/// The most search results that are listed.
const _maxListedHits = 500;

/// Manages the word replacements of the book [novel] belongs to, and searches
/// through the text of the whole book.
class NovelReplacePage extends StatefulWidget {
  const NovelReplacePage(this.novel, {super.key});

  final Novel novel;

  @override
  State<NovelReplacePage> createState() => _NovelReplacePageState();
}

enum _Tab { rules, search }

class _NovelReplacePageState extends State<NovelReplacePage> {
  final store = NovelReplaceStore.instance;

  late final book = NovelReplaceStore.bookOf(widget.novel);

  late final text = NovelBookText(widget.novel);

  var tab = _Tab.rules;

  final searchController = TextEditingController();

  /// What was searched for.
  var query = "";

  /// Whether to search the text as it reads with the replacements applied.
  var searchReplaced = false;

  /// Search results of the chapters searched so far, by chapter index.
  final _searchResults = <int, List<_Hit>>{};

  NovelTextReplacer? _searchReplacer;

  /// How often each rule replaces text, by chapter index.
  final _counts = <int, Map<int, int>>{};

  NovelTextReplacer? _countsReplacer;

  @override
  void initState() {
    super.initState();
    store.addListener(_update);
    text.addListener(_update);
  }

  @override
  void dispose() {
    store.removeListener(_update);
    text.removeListener(_update);
    text.dispose();
    searchController.dispose();
    super.dispose();
  }

  void _update() {
    if (mounted) setState(() {});
  }

  /// How often each enabled rule replaces text in the chapters loaded so far,
  /// by rule id.
  Map<int, int> countMatches() {
    final replacer = store.replacer(book);
    if (!identical(replacer, _countsReplacer)) {
      _counts.clear();
      _countsReplacer = replacer;
    }
    final total = <int, int>{};
    for (final chapter in text.chapters) {
      final counts =
          _counts[chapter.index] ??= _countChapter(chapter, replacer);
      counts.forEach((id, n) => total[id] = (total[id] ?? 0) + n);
    }
    return total;
  }

  static Map<int, int> _countChapter(
      NovelBookChapter chapter, NovelTextReplacer replacer) {
    final result = <int, int>{};
    for (final block in chapter.blocks) {
      final inlines = novelBlockInlines(block);
      if (inlines == null) continue;
      for (final match in novelInlineMatches(inlines, replacer)) {
        result[match.rule.id] = (result[match.rule.id] ?? 0) + 1;
      }
    }
    return result;
  }

  List<_Hit> searchHits() {
    if (query.isEmpty) return const [];
    final replacer = searchReplaced ? store.replacer(book) : null;
    if (!identical(replacer, _searchReplacer)) {
      _searchResults.clear();
      _searchReplacer = replacer;
    }
    // Matched like replacements are, so what's found is what a replacement
    // of it would replace.
    final pattern = RegExp(RegExp.escape(query));
    return [
      for (final chapter in text.chapters)
        ...(_searchResults[chapter.index] ??=
            _searchChapter(chapter, pattern, replacer)),
    ];
  }

  static List<_Hit> _searchChapter(
      NovelBookChapter chapter, RegExp pattern, NovelTextReplacer? replacer) {
    final blocks = replacer == null
        ? chapter.blocks
        : replaceNovelBlocks(chapter.blocks, replacer);
    final hits = <_Hit>[];
    for (var i = 0; i < blocks.length; i++) {
      final inlines = novelBlockInlines(blocks[i]);
      if (inlines == null) continue;
      final line = novelInlinesText(inlines);
      for (final match in pattern.allMatches(line)) {
        hits.add(_Hit(chapter, i, line, match.start, match.end));
      }
    }
    return hits;
  }

  void search() {
    final value = searchController.text;
    setState(() {
      query = value;
      _searchResults.clear();
    });
    if (value.isNotEmpty) text.load();
  }

  @override
  Widget build(BuildContext context) {
    final seriesTitle = widget.novel.seriesTitle?.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TitleBar(
          title: "Word Replacement".tl,
          action: FilledButton(
            onPressed: () => showNovelReplaceRuleDialog(context, book),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(MdIcons.add, size: 18),
                const SizedBox(width: 6),
                Text("Add".tl),
              ],
            ),
          ),
        ),
        Text(
          widget.novel.seriesId != null
              ? "Applies to every chapter of the series @s"
                  .tl
                  .replaceAll("@s", seriesTitle ?? "")
              : "Applies to this novel only".tl,
          style: TextStyle(
            fontSize: 13,
            color: ColorScheme.of(context).outline,
          ),
        ).paddingHorizontal(16),
        const SizedBox(height: 12),
        SegmentedButton<_Tab>(
          options: [
            SegmentedButtonOption(_Tab.rules, "Replacements".tl),
            SegmentedButtonOption(_Tab.search, "Full-text Search".tl),
          ],
          value: tab,
          onPressed: (value) {
            setState(() {
              tab = value;
            });
          },
        ).paddingHorizontal(16),
        const SizedBox(height: 8),
        Expanded(
          child: tab == _Tab.rules ? buildRules() : buildSearch(),
        ),
      ],
    );
  }

  Widget buildRules() {
    final rules = store.rules(book);
    if (rules.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              MdIcons.find_replace,
              size: 48,
              color: ColorScheme.of(context).outline,
            ),
            const SizedBox(height: 12),
            Text(
              "No replacements yet".tl,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              "Added words are replaced in the text while reading".tl,
              textAlign: TextAlign.center,
              style: TextStyle(color: ColorScheme.of(context).outline),
            ),
          ],
        ).paddingAll(16),
      );
    }
    final counts = text.loadedCount > 0 ? countMatches() : null;
    return ListView(
      padding: EdgeInsets.only(
        top: 4,
        bottom: 16 + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        if (!text.isStarted)
          Align(
            alignment: Alignment.centerLeft,
            child: HyperlinkButton(
              onPressed: text.load,
              child: Text("Count the occurrences in the whole book".tl),
            ),
          ).paddingHorizontal(12),
        _LoadStatus(text),
        for (final rule in rules) buildRule(rule, counts),
      ],
    );
  }

  Widget buildRule(NovelReplaceRule rule, Map<int, int>? counts) {
    String? status;
    if (!rule.enabled) {
      status = "Disabled".tl;
    } else if (counts != null) {
      final count = counts[rule.id] ?? 0;
      status = count == 0
          ? (text.isLoading ? null : "Not found".tl)
          : "@n places".tl.replaceAll("@n", "$count");
    }
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: EdgeInsets.zero,
      child: ListTile(
        onPressed: () {
          context.to(() => _NovelReplaceDetailsPage(
                book: book,
                ruleId: rule.id,
                text: text,
              ));
        },
        leading: Checkbox(
          checked: rule.enabled,
          onChanged: (value) {
            store.update(book, rule.copyWith(enabled: value ?? false));
          },
        ),
        title: _RuleText(rule),
        subtitle: status != null ? Text(status) : null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message: "Edit".tl,
              child: IconButton(
                icon: const Icon(MdIcons.edit_outlined, size: 18),
                onPressed: () {
                  showNovelReplaceRuleDialog(context, book, rule: rule);
                },
              ),
            ),
            Tooltip(
              message: "Delete".tl,
              child: IconButton(
                icon: const Icon(MdIcons.delete_outline, size: 18),
                onPressed: () => store.remove(book, rule),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildSearch() {
    final hits = searchHits();
    final existing =
        store.rules(book).where((rule) => rule.from == query).firstOrNull;
    String? summary;
    if (query.isNotEmpty) {
      if (hits.isNotEmpty) {
        summary = "@n results".tl.replaceAll("@n", "${hits.length}");
        if (hits.length > _maxListedHits) {
          summary += " · ${"Showing the first @n".tl.replaceAll(
                "@n",
                "$_maxListedHits",
              )}";
        }
      } else if (!text.isLoading) {
        summary = "No results found".tl;
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextBox(
                controller: searchController,
                placeholder: "Search the full text".tl,
                prefix: const Icon(MdIcons.search, size: 18).paddingLeft(8),
                onSubmitted: (_) => search(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: search, child: Text("Search".tl)),
          ],
        ).paddingHorizontal(16),
        Checkbox(
          checked: searchReplaced,
          content: Text("Search the replaced text".tl),
          onChanged: (value) {
            setState(() {
              searchReplaced = value ?? false;
            });
          },
        ).toAlign(Alignment.centerLeft).paddingHorizontal(16).paddingTop(8),
        _LoadStatus(text),
        if (query.isNotEmpty)
          Row(
            children: [
              Expanded(
                child: Text(
                  summary ?? "",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: ColorScheme.of(context).outline),
                ),
              ),
              Button(
                onPressed: () {
                  showNovelReplaceRuleDialog(context, book,
                      rule: existing, from: query);
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(MdIcons.find_replace, size: 16),
                    const SizedBox(width: 6),
                    Text(existing != null
                        ? "Edit Replacement".tl
                        : "Replace...".tl),
                  ],
                ),
              ),
            ],
          ).paddingHorizontal(16).paddingTop(8),
        const SizedBox(height: 4),
        Expanded(
          child: _HitList(
            hits: hits.length > _maxListedHits
                ? hits.sublist(0, _maxListedHits)
                : hits,
            showChapters: text.total > 1,
            buildMatch: (context, hit) => [
              TextSpan(
                text: hit.text.substring(hit.start, hit.end),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  backgroundColor:
                      ColorScheme.of(context).primaryContainer.toOpacity(0.8),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Where a search or a replacement matched text: [start] to [end] in [text],
/// the text of [block] in [chapter].
class _Hit {
  const _Hit(this.chapter, this.block, this.text, this.start, this.end);

  final NovelBookChapter chapter;

  final int block;

  final String text;

  final int start;

  final int end;
}

/// Shows how far loading the book got, and what failed.
class _LoadStatus extends StatelessWidget {
  const _LoadStatus(this.text);

  final NovelBookText text;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: 13,
      color: ColorScheme.of(context).outline,
    );
    Widget retry(String message) {
      return Row(
        children: [
          Icon(MdIcons.error_outline,
              size: 18, color: ColorScheme.of(context).error),
          const SizedBox(width: 8),
          Expanded(child: Text(message, style: style)),
          Button(onPressed: text.load, child: Text("Retry".tl)),
        ],
      ).paddingHorizontal(16).paddingVertical(4);
    }

    if (text.error != null) {
      return retry("Failed to load chapters".tl);
    }
    if (text.isLoading) {
      final total = text.total;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ProgressBar(
            value: total == 0 ? null : text.loadedCount / total * 100,
          ),
          const SizedBox(height: 4),
          Text(
            "Loading chapters @a/@b"
                .tl
                .replaceAll("@a", "${text.loadedCount}")
                .replaceAll("@b", total == 0 ? "?" : "$total"),
            style: style,
          ),
        ],
      ).paddingHorizontal(16).paddingVertical(4);
    }
    if (text.failedCount > 0) {
      return retry("@n chapters failed to load"
          .tl
          .replaceAll("@n", "${text.failedCount}"));
    }
    return const SizedBox.shrink();
  }
}

/// A replacement as "from → to".
class _RuleText extends StatelessWidget {
  const _RuleText(this.rule, {this.style});

  final NovelReplaceRule rule;

  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final outline = ColorScheme.of(context).outline;
    return Text.rich(
      TextSpan(children: [
        TextSpan(text: rule.from),
        TextSpan(text: "  →  ", style: TextStyle(color: outline)),
        if (rule.to.isEmpty)
          TextSpan(
            text: "(Removed)".tl,
            style: TextStyle(color: outline, fontStyle: FontStyle.italic),
          )
        else
          TextSpan(
            text: rule.to,
            style: TextStyle(color: ColorScheme.of(context).primary),
          ),
      ]),
      style: style,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// Lists [hits] with the text around them, under the chapters they're in.
/// Tapping one opens the reader there.
class _HitList extends StatelessWidget {
  const _HitList({
    required this.hits,
    required this.showChapters,
    required this.buildMatch,
  });

  final List<_Hit> hits;

  final bool showChapters;

  /// The spans shown in place of the matched text.
  final List<InlineSpan> Function(BuildContext context, _Hit hit) buildMatch;

  @override
  Widget build(BuildContext context) {
    final rows = <Object>[];
    final perChapter = <int, int>{};
    for (final hit in hits) {
      if (showChapters &&
          (rows.isEmpty || (rows.last as _Hit).chapter != hit.chapter)) {
        rows.add(hit.chapter);
      }
      rows.add(hit);
      perChapter[hit.chapter.index] = (perChapter[hit.chapter.index] ?? 0) + 1;
    }
    return ListView.builder(
      padding: EdgeInsets.only(
        bottom: 16 + MediaQuery.paddingOf(context).bottom,
      ),
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final row = rows[index];
        if (row is NovelBookChapter) {
          return buildChapter(context, row, perChapter[row.index] ?? 0);
        }
        return buildHit(context, row as _Hit);
      },
    );
  }

  Widget buildChapter(
      BuildContext context, NovelBookChapter chapter, int count) {
    return Row(
      children: [
        Expanded(
          child: Text(
            "${"Chapter @n".tl.replaceAll("@n", "${chapter.index + 1}")} · ${chapter.novel.title}",
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: ColorScheme.of(context).primary,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          "$count",
          style: TextStyle(
            fontSize: 12,
            color: ColorScheme.of(context).outline,
          ),
        ),
      ],
    ).paddingHorizontal(20).paddingTop(12).paddingBottom(4);
  }

  Widget buildHit(BuildContext context, _Hit hit) {
    final excerpt = novelTextExcerpt(hit.text, hit.start, hit.end);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
      padding: EdgeInsets.zero,
      child: ListTile(
        onPressed: () {
          context.to(() =>
              NovelReadingPage(hit.chapter.novel, initialBlock: hit.block));
        },
        title: Text.rich(
          TextSpan(children: [
            TextSpan(text: excerpt.before),
            ...buildMatch(context, hit),
            TextSpan(text: excerpt.after),
          ]),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, height: 1.5),
        ),
      ),
    );
  }
}

/// Where a replacement replaces text in the book, with the text around it.
class _NovelReplaceDetailsPage extends StatefulWidget {
  const _NovelReplaceDetailsPage({
    required this.book,
    required this.ruleId,
    required this.text,
  });

  final String book;

  final int ruleId;

  final NovelBookText text;

  @override
  State<_NovelReplaceDetailsPage> createState() =>
      _NovelReplaceDetailsPageState();
}

class _NovelReplaceDetailsPageState extends State<_NovelReplaceDetailsPage> {
  final store = NovelReplaceStore.instance;

  List<NovelReplaceRule>? _rules;

  NovelTextReplacer? _replacer;

  /// The matches of the rule by chapter index, for the chapters loaded so far.
  final _hits = <int, List<_Hit>>{};

  @override
  void initState() {
    super.initState();
    store.addListener(_update);
    widget.text.addListener(_update);
    widget.text.load();
  }

  @override
  void dispose() {
    store.removeListener(_update);
    widget.text.removeListener(_update);
    super.dispose();
  }

  void _update() {
    if (mounted) setState(() {});
  }

  List<_Hit> findHits(NovelReplaceRule rule) {
    final rules = store.rules(widget.book);
    if (!identical(rules, _rules)) {
      _rules = rules;
      _hits.clear();
      // A disabled rule shows what it would replace if it were enabled.
      _replacer = rule.enabled
          ? store.replacer(widget.book)
          : NovelTextReplacer([
              for (final r in rules)
                r.id == rule.id ? r.copyWith(enabled: true) : r,
            ]);
    }
    final replacer = _replacer!;
    return [
      for (final chapter in widget.text.chapters)
        ...(_hits[chapter.index] ??= [
          for (var i = 0; i < chapter.blocks.length; i++)
            if (novelBlockInlines(chapter.blocks[i]) case final inlines?)
              for (final match in novelInlineMatches(inlines, replacer))
                if (match.rule.id == rule.id)
                  _Hit(chapter, i, novelInlinesText(inlines), match.start,
                      match.end),
        ]),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final rule = store
        .rules(widget.book)
        .where((r) => r.id == widget.ruleId)
        .firstOrNull;
    if (rule == null) {
      return Column(
        children: [
          TitleBar(title: "Replacement Details".tl),
          Expanded(
            child: Center(child: Text("This replacement was deleted".tl)),
          ),
        ],
      );
    }
    final hits = findHits(rule);
    final text = widget.text;
    final chapters = hits.map((hit) => hit.chapter.index).toSet().length;
    final outline = ColorScheme.of(context).outline;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TitleBar(
          title: "Replacement Details".tl,
          action: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Button(
                onPressed: () {
                  showNovelReplaceRuleDialog(context, widget.book, rule: rule);
                },
                child: Text("Edit".tl),
              ),
              const SizedBox(width: 8),
              Button(
                onPressed: () {
                  store.remove(widget.book, rule);
                  context.pop();
                },
                child: Text("Delete".tl),
              ),
            ],
          ),
        ),
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _RuleText(
                rule,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Checkbox(
                    checked: rule.enabled,
                    content: Text("Enabled".tl),
                    onChanged: (value) {
                      store.update(
                          widget.book, rule.copyWith(enabled: value ?? false));
                    },
                  ),
                  const SizedBox(width: 16),
                  if (text.isComplete || hits.isNotEmpty)
                    Flexible(
                      child: Text(
                        "@n places in @c chapters"
                            .tl
                            .replaceAll("@n", "${hits.length}")
                            .replaceAll("@c", "$chapters"),
                        style: TextStyle(color: outline),
                      ),
                    ),
                ],
              ),
              if (!rule.enabled)
                Text(
                  "This replacement is disabled. These are the places it would replace."
                      .tl,
                  style: TextStyle(fontSize: 13, color: outline),
                ).paddingTop(8),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _LoadStatus(text),
        Expanded(
          child: hits.isEmpty && !text.isLoading && text.error == null
              ? Center(child: Text("Not found".tl))
              : _HitList(
                  hits: hits,
                  showChapters: text.total > 1,
                  buildMatch: (context, hit) => [
                    TextSpan(
                      text: rule.from,
                      style: TextStyle(
                        color: ColorScheme.of(context).error,
                        decoration: TextDecoration.lineThrough,
                      ),
                    ),
                    if (rule.to.isNotEmpty)
                      TextSpan(
                        text: rule.to,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: ColorScheme.of(context).primary,
                          backgroundColor: ColorScheme.of(context)
                              .primaryContainer
                              .toOpacity(0.8),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// Asks for the words of a replacement in [book] and saves it. Edits [rule]
/// if it's given, otherwise adds one replacing [from].
Future<void> showNovelReplaceRuleDialog(BuildContext context, String book,
    {NovelReplaceRule? rule, String? from}) {
  return showDialog(
    context: context,
    barrierDismissible: true,
    builder: (context) => _RuleDialog(book: book, rule: rule, from: from),
  );
}

class _RuleDialog extends StatefulWidget {
  const _RuleDialog({required this.book, this.rule, this.from});

  final String book;

  final NovelReplaceRule? rule;

  final String? from;

  @override
  State<_RuleDialog> createState() => _RuleDialogState();
}

class _RuleDialogState extends State<_RuleDialog> {
  late final fromController =
      TextEditingController(text: widget.rule?.from ?? widget.from ?? "");

  late final toController = TextEditingController(text: widget.rule?.to ?? "");

  /// Whether the text to replace is filled in already, so the replacement is
  /// what to type.
  late final _hasFrom = fromController.text.isNotEmpty;

  final toFocus = FocusNode();

  String? error;

  @override
  void dispose() {
    fromController.dispose();
    toController.dispose();
    toFocus.dispose();
    super.dispose();
  }

  void submit() {
    final from = fromController.text;
    final to = toController.text;
    if (from.isEmpty) {
      setState(() {
        error = "Enter the text to replace".tl;
      });
      return;
    }
    final store = NovelReplaceStore.instance;
    final rule = widget.rule;
    final taken =
        store.rules(widget.book).any((r) => r.from == from && r.id != rule?.id);
    if (taken) {
      setState(() {
        error = "This text already has a replacement".tl;
      });
      return;
    }
    if (rule == null) {
      store.add(widget.book, from, to);
    } else {
      store.update(widget.book, rule.copyWith(from: from, to: to));
    }
    context.pop();
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: Text(
          widget.rule == null ? "Add Replacement".tl : "Edit Replacement".tl),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InfoLabel(
            label: "Text to replace".tl,
            child: TextBox(
              controller: fromController,
              autofocus: !_hasFrom,
              textInputAction: TextInputAction.next,
              // An empty replacement removes the text, so don't save until
              // it has been looked at.
              onSubmitted: (_) => toFocus.requestFocus(),
            ),
          ),
          const SizedBox(height: 12),
          InfoLabel(
            label: "Replace with".tl,
            child: TextBox(
              controller: toController,
              focusNode: toFocus,
              autofocus: _hasFrom,
              placeholder: "Leave empty to remove the text".tl,
              onSubmitted: (_) => submit(),
            ),
          ),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: ColorScheme.of(context).error),
            ).paddingTop(8),
        ],
      ),
      actions: [
        Button(onPressed: () => context.pop(), child: Text("Cancel".tl)),
        FilledButton(onPressed: submit, child: Text("Save".tl)),
      ],
    );
  }
}
