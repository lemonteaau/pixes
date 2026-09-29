import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:intl/intl.dart';
import 'package:pixes/components/animated_image.dart';
import 'package:pixes/components/md.dart';
import 'package:pixes/foundation/app.dart';
import 'package:pixes/foundation/image_provider.dart';
import 'package:pixes/network/network.dart';
import 'package:pixes/pages/novel_page.dart';
import 'package:pixes/utils/translation.dart';

String _numberLocale() {
  return Intl.verifiedLocale(
      App.locale.toString(), NumberFormat.localeExists,
      onFailure: (_) => "en")!;
}

/// Formats a count for display: grouped digits below 10,000, compact above
/// ("1.2万", "12K").
String formatCount(int count) {
  final locale = _numberLocale();
  if (count < 10000) {
    return NumberFormat.decimalPattern(locale).format(count);
  }
  return NumberFormat.compact(locale: locale).format(count);
}

/// The length of a novel with its estimated reading time,
/// such as "12,345 chars · About 25 min".
String novelLengthText(Novel novel) {
  final minutes = math.max(1, (novel.length / 500).round());
  final String time;
  if (minutes < 60) {
    time = "About @m min".tl.replaceAll("@m", "$minutes");
  } else if (minutes % 60 == 0) {
    time = "About @h h".tl.replaceAll("@h", "${minutes ~/ 60}");
  } else {
    time = "About @h h @m min"
        .tl
        .replaceAll("@h", "${minutes ~/ 60}")
        .replaceAll("@m", "${minutes % 60}");
  }
  final chars = "@n chars".tl.replaceAll("@n", formatCount(novel.length));
  return "$chars · $time";
}

class NovelBadge extends StatelessWidget {
  const NovelBadge(this.text, {this.color, super.key});

  final String text;

  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color ?? ColorScheme.of(context).secondaryContainer,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: ColorScheme.of(context).outlineVariant,
          width: 0.6,
        ),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 11, height: 1.3),
      ),
    );
  }
}

/// Badges for the AI generation and series of [novel].
List<Widget> buildNovelBadges(BuildContext context, Novel novel,
    {bool showSeries = true}) {
  return [
    if (novel.isAi)
      NovelBadge("AI", color: ColorScheme.of(context).tertiaryContainer),
    if (showSeries && novel.seriesId != null) NovelBadge("Series".tl),
  ];
}

class NovelWidget extends StatefulWidget {
  const NovelWidget(this.novel, {super.key});

  final Novel novel;

  @override
  State<NovelWidget> createState() => _NovelWidgetState();
}

class _NovelWidgetState extends State<NovelWidget> {
  @override
  Widget build(BuildContext context) {
    final novel = widget.novel;
    final badges = buildNovelBadges(context, novel);
    return HoverButton(
      cursor: SystemMouseCursors.click,
      onPressed: () {
        context.to(() => NovelPage(novel));
      },
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
                  image: CachedImageProvider(novel.image),
                ),
              ),
              const SizedBox(
                width: 12,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      novel.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(
                      height: 4,
                    ),
                    Expanded(
                      child: Text(
                        novel.caption.trim().replaceAll('<br />', '\n'),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(
                      height: 4,
                    ),
                    buildMeta(context, badges),
                    const SizedBox(
                      height: 2,
                    ),
                    buildAuthor(context),
                  ],
                ),
              )
            ],
          ),
        );
      },
    );
  }

  Widget buildMeta(BuildContext context, List<Widget> badges) {
    return Row(
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
    );
  }

  Widget buildAuthor(BuildContext context) {
    final outline = ColorScheme.of(context).outline;
    return Row(
      children: [
        Expanded(
          child: Text(
            widget.novel.author.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
        ),
        const SizedBox(width: 8),
        Icon(MdIcons.favorite_outline, size: 13, color: outline),
        const SizedBox(width: 2),
        Text(
          formatCount(widget.novel.totalBookmarks),
          style: TextStyle(fontSize: 12, color: outline),
        ),
      ],
    );
  }
}
