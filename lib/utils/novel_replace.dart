/// Words the user replaces in the text of a novel while reading it.
///
/// Replacements only touch the text of the novel: plain text, the base text of
/// ruby and the text of links. Markup, link targets and ruby readings are left
/// alone.
library;

import 'package:pixes/utils/novel_markup.dart';

class NovelReplaceRule {
  const NovelReplaceRule({
    required this.id,
    required this.from,
    required this.to,
    this.enabled = true,
  });

  final int id;

  /// The text to replace.
  final String from;

  /// What [from] is replaced with. Empty removes it.
  final String to;

  final bool enabled;

  NovelReplaceRule copyWith({String? from, String? to, bool? enabled}) {
    return NovelReplaceRule(
      id: id,
      from: from ?? this.from,
      to: to ?? this.to,
      enabled: enabled ?? this.enabled,
    );
  }
}

/// Text that [rule] replaces, from [start] to [end].
class NovelReplaceMatch {
  const NovelReplaceMatch(this.rule, this.start, this.end);

  final NovelReplaceRule rule;

  final int start;

  final int end;
}

/// Replaces the words of a set of rules in one pass. Where words overlap the
/// longest one wins, and text that was put in by a rule isn't replaced again,
/// so the order of the rules doesn't matter.
class NovelTextReplacer {
  NovelTextReplacer._(this._rules, this._pattern);

  factory NovelTextReplacer(Iterable<NovelReplaceRule> rules) {
    final byWord = <String, NovelReplaceRule>{};
    for (final rule in rules) {
      if (rule.enabled && rule.from.isNotEmpty) {
        byWord.putIfAbsent(rule.from, () => rule);
      }
    }
    if (byWord.isEmpty) return empty;
    // Alternatives are tried in order, so the longest word has to come first.
    final words = byWord.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    return NovelTextReplacer._(
        byWord, RegExp(words.map(RegExp.escape).join('|')));
  }

  static final empty = NovelTextReplacer._(const {}, null);

  final Map<String, NovelReplaceRule> _rules;

  final RegExp? _pattern;

  bool get isEmpty => _pattern == null;

  Iterable<NovelReplaceMatch> matches(String text) sync* {
    final pattern = _pattern;
    if (pattern == null) return;
    for (final match in pattern.allMatches(text)) {
      yield NovelReplaceMatch(_rules[match[0]]!, match.start, match.end);
    }
  }

  String apply(String text) {
    final pattern = _pattern;
    if (pattern == null) return text;
    return text.replaceAllMapped(pattern, (match) => _rules[match[0]]!.to);
  }
}

/// [blocks] with the replacements of [replacer] applied. Every block stays at
/// its index, so positions in the novel stay valid.
List<NovelBlock> replaceNovelBlocks(
    List<NovelBlock> blocks, NovelTextReplacer replacer) {
  if (replacer.isEmpty) return blocks;
  return [
    for (final block in blocks)
      switch (block) {
        NovelParagraphBlock(:final inlines) =>
          NovelParagraphBlock(_replaceInlines(inlines, replacer)),
        NovelChapterBlock(:final inlines) =>
          NovelChapterBlock(_replaceInlines(inlines, replacer)),
        _ => block,
      },
  ];
}

List<NovelInline> _replaceInlines(
    List<NovelInline> inlines, NovelTextReplacer replacer) {
  return [
    for (final inline in inlines)
      switch (inline) {
        NovelPlainText(:final text) => NovelPlainText(replacer.apply(text)),
        NovelRuby(:final base, :final ruby) =>
          NovelRuby(replacer.apply(base), ruby),
        NovelLink(:final text, :final url) =>
          NovelLink(replacer.apply(text), url),
        NovelPageJump() => inline,
      },
  ];
}

/// The inlines of a block of text, or null if [block] has no text.
List<NovelInline>? novelBlockInlines(NovelBlock block) {
  return switch (block) {
    NovelParagraphBlock(:final inlines) ||
    NovelChapterBlock(:final inlines) =>
      inlines,
    _ => null,
  };
}

/// The text of [inlines] as it reads, without markup.
String novelInlinesText(List<NovelInline> inlines) {
  if (inlines.length == 1) return inlines.first.plainText;
  return inlines.map((e) => e.plainText).join();
}

/// What [replacer] replaces in [inlines], with offsets into
/// [novelInlinesText]. A word split across inlines isn't replaced.
Iterable<NovelReplaceMatch> novelInlineMatches(
    List<NovelInline> inlines, NovelTextReplacer replacer) sync* {
  var offset = 0;
  for (final inline in inlines) {
    final text = inline.plainText;
    for (final match in replacer.matches(text)) {
      yield NovelReplaceMatch(
          match.rule, match.start + offset, match.end + offset);
    }
    offset += text.length;
  }
}

/// A line of text cut down to the part around [start]..[end].
typedef NovelTextExcerpt = ({String before, String match, String after});

NovelTextExcerpt novelTextExcerpt(String text, int start, int end,
    {int before = 24, int after = 48}) {
  final from = start - before;
  final to = end + after;
  return (
    before:
        from > 0 ? "…${text.substring(from, start)}" : text.substring(0, start),
    match: text.substring(start, end),
    after:
        to < text.length ? "${text.substring(end, to)}…" : text.substring(end),
  );
}
