import 'package:flutter_test/flutter_test.dart';
import 'package:pixes/utils/novel_markup.dart';

void main() {
  test('parses block tags, pages and blank lines', () {
    final blocks = parseNovelContent([
      '',
      '[chapter:第一章 [[rb:始 > はじ]]まり]',
      '本文1',
      '',
      '',
      '本文2',
      '[uploadedimage:123]',
      '',
      '[newpage]',
      '',
      '前[pixivimage:456-2]後',
      '[jump:1]',
      '',
    ].join('\n'));

    expect(blocks, hasLength(10));

    final chapter = blocks[0] as NovelChapterBlock;
    expect(chapter.inlines, hasLength(3));
    expect((chapter.inlines[0] as NovelPlainText).text, '第一章 ');
    final ruby = chapter.inlines[1] as NovelRuby;
    expect(ruby.base, '始');
    expect(ruby.ruby, 'はじ');

    expect(blocks[1], isA<NovelParagraphBlock>());
    expect((blocks[2] as NovelBlankBlock).lines, 2);
    expect(blocks[3], isA<NovelParagraphBlock>());
    expect((blocks[4] as NovelUploadedImageBlock).imageId, '123');
    // Blank lines around a page break are dropped.
    expect((blocks[5] as NovelPageBreakBlock).page, 2);
    expect(
        ((blocks[6] as NovelParagraphBlock).inlines.single as NovelPlainText)
            .text,
        '前');
    final illust = blocks[7] as NovelIllustBlock;
    expect(illust.illustId, '456');
    expect(illust.page, 1);
    final rest = blocks[8] as NovelParagraphBlock;
    expect((rest.inlines.single as NovelPlainText).text, '後');
    final jump = blocks[9] as NovelParagraphBlock;
    expect((jump.inlines.single as NovelPageJump).page, 1);
  });

  test('parses links and page jumps inline', () {
    final inlines = parseNovelInlines(
        'see [[jumpuri:pixiv > https://www.pixiv.net]] or [jump:3]!');
    expect(inlines, hasLength(5));
    final link = inlines[1] as NovelLink;
    expect(link.text, 'pixiv');
    expect(link.url, 'https://www.pixiv.net');
    expect((inlines[3] as NovelPageJump).page, 3);
    expect((inlines[4] as NovelPlainText).text, '!');
  });

  test('a line that is only a page jump is its own paragraph', () {
    final blocks = parseNovelContent('a\n[jump:2]\n[newpage]\nb');
    expect(blocks, hasLength(4));
    final jump = (blocks[1] as NovelParagraphBlock).inlines.single;
    expect((jump as NovelPageJump).page, 2);
    expect((blocks[2] as NovelPageBreakBlock).page, 2);
  });

  test('weights count the visible text', () {
    final blocks = parseNovelContent('[[rb:漢字 > かんじ]]です\n\n[newpage]');
    expect(blocks.first.weight, 4);
    expect(blocks.last.weight, 0);
  });
}
