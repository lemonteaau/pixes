/// Parses the text of a pixiv novel into blocks that the reader can render.
///
/// pixiv novels use a small markup language on top of plain text:
///
/// * `[newpage]` starts a new page.
/// * `[chapter:title]` is a chapter heading.
/// * `[uploadedimage:id]` is an image uploaded with the novel.
/// * `[pixivimage:id]` / `[pixivimage:id-page]` embeds an illustration.
/// * `[[rb:base > ruby]]` is ruby (furigana) text.
/// * `[[jumpuri:text > url]]` is a link.
/// * `[jump:n]` is a link to page `n` of the novel.
library;

sealed class NovelInline {
  const NovelInline();

  /// The text this inline contributes to the reading progress.
  String get plainText;
}

class NovelPlainText extends NovelInline {
  const NovelPlainText(this.text);

  final String text;

  @override
  String get plainText => text;
}

class NovelRuby extends NovelInline {
  const NovelRuby(this.base, this.ruby);

  final String base;

  final String ruby;

  @override
  String get plainText => base;
}

class NovelLink extends NovelInline {
  const NovelLink(this.text, this.url);

  final String text;

  final String url;

  @override
  String get plainText => text;
}

class NovelPageJump extends NovelInline {
  const NovelPageJump(this.page);

  final int page;

  @override
  String get plainText => "";
}

sealed class NovelBlock {
  const NovelBlock();

  /// How much of the novel this block represents, used to turn a position in
  /// the reader into a reading progress that doesn't depend on layout.
  int get weight;
}

class NovelParagraphBlock extends NovelBlock {
  const NovelParagraphBlock(this.inlines);

  final List<NovelInline> inlines;

  @override
  int get weight => inlines.fold(0, (sum, e) => sum + e.plainText.length);
}

class NovelChapterBlock extends NovelBlock {
  const NovelChapterBlock(this.inlines);

  final List<NovelInline> inlines;

  @override
  int get weight => inlines.fold(0, (sum, e) => sum + e.plainText.length);
}

/// One or more consecutive empty lines.
class NovelBlankBlock extends NovelBlock {
  const NovelBlankBlock(this.lines);

  final int lines;

  @override
  int get weight => 0;
}

/// The start of page [page] (the first page has no break).
class NovelPageBreakBlock extends NovelBlock {
  const NovelPageBreakBlock(this.page);

  final int page;

  @override
  int get weight => 0;
}

const _imageWeight = 50;

class NovelUploadedImageBlock extends NovelBlock {
  const NovelUploadedImageBlock(this.imageId);

  final String imageId;

  @override
  int get weight => _imageWeight;
}

class NovelIllustBlock extends NovelBlock {
  const NovelIllustBlock(this.illustId, this.page);

  final String illustId;

  /// Zero based index of the page of the illustration.
  final int page;

  @override
  int get weight => _imageWeight;
}

final _chapterLine = RegExp(r'^\s*\[chapter:(.*)\]\s*$');

final _blockTag = RegExp(
    r'\[newpage\]|\[uploadedimage:(\d+)\]|\[pixivimage:(\d+)(?:-(\d+))?\]');

final _inlineTag = RegExp(
    r'\[\[rb:(.+?)>(.+?)\]\]|\[\[jumpuri:(.+?)>(.+?)\]\]|\[jump:(\d+)\]');

List<NovelBlock> parseNovelContent(String content) {
  final blocks = <NovelBlock>[];
  var page = 1;
  var blankLines = 0;

  void add(NovelBlock block) {
    // Blank lines only matter between content; drop them at the edges of
    // the novel and around page breaks, which already have their own spacing.
    if (blankLines > 0 &&
        blocks.isNotEmpty &&
        blocks.last is! NovelPageBreakBlock &&
        block is! NovelPageBreakBlock) {
      blocks.add(NovelBlankBlock(blankLines));
    }
    blankLines = 0;
    blocks.add(block);
  }

  void addText(String text) {
    if (text.trim().isEmpty) return;
    add(NovelParagraphBlock(parseNovelInlines(text)));
  }

  for (final line in content.replaceAll('\r\n', '\n').split('\n')) {
    if (line.trim().isEmpty) {
      blankLines++;
      continue;
    }
    final chapter = _chapterLine.firstMatch(line);
    if (chapter != null) {
      add(NovelChapterBlock(parseNovelInlines(chapter[1]!.trim())));
      continue;
    }
    var start = 0;
    for (final match in _blockTag.allMatches(line)) {
      addText(line.substring(start, match.start));
      start = match.end;
      if (match[1] != null) {
        add(NovelUploadedImageBlock(match[1]!));
      } else if (match[2] != null) {
        final illustPage = int.tryParse(match[3] ?? "") ?? 1;
        add(NovelIllustBlock(match[2]!, illustPage > 0 ? illustPage - 1 : 0));
      } else {
        page++;
        add(NovelPageBreakBlock(page));
      }
    }
    addText(line.substring(start));
  }
  return blocks;
}

List<NovelInline> parseNovelInlines(String text) {
  final result = <NovelInline>[];
  var start = 0;
  for (final match in _inlineTag.allMatches(text)) {
    if (match.start > start) {
      result.add(NovelPlainText(text.substring(start, match.start)));
    }
    start = match.end;
    if (match[1] != null) {
      result.add(NovelRuby(match[1]!.trim(), match[2]!.trim()));
    } else if (match[3] != null) {
      result.add(NovelLink(match[3]!.trim(), match[4]!.trim()));
    } else {
      result.add(NovelPageJump(int.parse(match[5]!)));
    }
  }
  if (start < text.length) {
    result.add(NovelPlainText(text.substring(start)));
  }
  return result;
}
