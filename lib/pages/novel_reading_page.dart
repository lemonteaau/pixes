import 'package:fluent_ui/fluent_ui.dart' hide TitleBar;
import 'package:pixes/appdata.dart';
import 'package:pixes/components/animated_image.dart';
import 'package:pixes/components/loading.dart';
import 'package:pixes/components/md.dart';
import 'package:pixes/components/page_route.dart';
import 'package:pixes/components/title_bar.dart';
import 'package:pixes/foundation/app.dart';
import 'package:pixes/foundation/image_provider.dart';
import 'package:pixes/foundation/log.dart';
import 'package:pixes/network/network.dart';
import 'package:pixes/network/translator.dart';
import 'package:pixes/pages/image_page.dart';
import 'package:pixes/pages/main_page.dart';
import 'package:pixes/utils/ext.dart';
import 'package:pixes/utils/translation.dart';

class NovelReadingPage extends StatefulWidget {
  const NovelReadingPage(this.novel, {super.key});

  final Novel novel;

  @override
  State<NovelReadingPage> createState() => _NovelReadingPageState();
}

class _NovelReadingPageState extends LoadingState<NovelReadingPage, String> {
  TitleBarAction? action;

  bool isShowingSettings = false;

  String? translatedContent;

  /// The novel currently shown. Changes when navigating between the
  /// chapters (episodes) of a series.
  late Novel novel;

  /// All episodes of the series this novel belongs to, in reading order.
  /// Null until loaded, or if the novel does not belong to a series.
  List<Novel>? seriesNovels;

  bool isLoadingSeries = false;

  @override
  void initState() {
    novel = widget.novel;
    action = TitleBarAction(MdIcons.tune, "Settings".tl, () {
      if (!isShowingSettings) {
        _NovelReadingSettings.show(
          context,
          () {
            setState(() {});
          },
          TranslationController(
            content: data!,
            isTranslated: translatedContent != null,
            onTranslated: (s) {
              setState(() {
                translatedContent = s;
              });
            },
            revert: () {
              setState(() {
                translatedContent = null;
              });
            },
          ),
        ).then(
          (value) {
            isShowingSettings = false;
          },
        );
        isShowingSettings = true;
      } else {
        Navigator.of(context).pop();
      }
    });
    Future.delayed(const Duration(milliseconds: 200), () {
      StateController.find<TitleBarController>().addAction(action!);
    });
    super.initState();
    if (novel.seriesId != null) {
      loadSeries();
    }
  }

  @override
  void dispose() {
    Future.delayed(const Duration(milliseconds: 200), () {
      StateController.find<TitleBarController>().removeAction(action!);
    });
    super.dispose();
  }

  /// Loads the full ordered list of episodes for the current series.
  void loadSeries() async {
    final seriesId = novel.seriesId;
    if (seriesId == null || isLoadingSeries) return;
    setState(() {
      isLoadingSeries = true;
    });
    final all = <Novel>[];
    String? nextUrl;
    // Series are paginated; load every page. The cap guards against an
    // unexpected pagination loop.
    for (var i = 0; i < 50; i++) {
      var res = await Network().getNovelSeries(seriesId.toString(), nextUrl);
      if (res.error) break;
      all.addAll(res.data);
      nextUrl = res.subData;
      if (nextUrl == null || nextUrl.isEmpty) break;
    }
    if (!mounted) return;
    setState(() {
      isLoadingSeries = false;
      if (all.isNotEmpty) {
        seriesNovels = all;
      }
    });
  }

  /// Switches the reader to [target] and reloads its content.
  void goToNovel(Novel target) {
    if (target.id == novel.id || isLoading) return;
    setState(() {
      novel = target;
      translatedContent = null;
      isLoading = true;
      error = null;
      data = null;
    });
    loadData().then((value) {
      if (!mounted) return;
      setState(() {
        isLoading = false;
        if (value.success) {
          data = value.data;
        } else {
          error = value.errorMessage!;
        }
      });
    });
  }

  void showChapterList() {
    final list = seriesNovels;
    if (list == null) return;
    Navigator.of(context).push(
      SideBarRoute(_NovelChapterList(
        novels: list,
        currentId: novel.id,
        onSelected: goToNovel,
      )),
    );
  }

  @override
  Widget buildContent(BuildContext context, String data) {
    var content = buildList(context).toList();
    content.add(buildChapterNav(context));
    return ScaffoldPage(
      padding: EdgeInsets.zero,
      content: SelectionArea(
          child: DefaultTextStyle.merge(
        style: const TextStyle(fontSize: 16.0, height: 1.6),
        child: ListView.builder(
          // A fresh key per chapter resets the scroll back to the top.
          key: ValueKey(novel.id),
          padding: const EdgeInsets.all(16.0),
          itemBuilder: (context, index) {
            return content[index];
          },
          itemCount: content.length,
        ),
      )),
    );
  }

  /// The previous / chapter-list / next bar shown at the end of a chapter.
  Widget buildChapterNav(BuildContext context) {
    if (novel.seriesId == null) {
      return const SizedBox.shrink();
    }
    if (seriesNovels == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: isLoadingSeries
              ? const SizedBox.square(
                  dimension: 24,
                  child: ProgressRing(strokeWidth: 2),
                )
              : Button(
                  onPressed: loadSeries,
                  child: Text("Load chapters".tl),
                ),
        ),
      );
    }
    final list = seriesNovels!;
    final index = list.indexWhere((n) => n.id == novel.id);
    final hasPrev = index > 0;
    final hasNext = index >= 0 && index < list.length - 1;
    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 8),
      child: Column(
        children: [
          const Divider(
            style: DividerThemeData(horizontalMargin: EdgeInsets.all(0)),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Button(
                  onPressed: hasPrev ? () => goToNovel(list[index - 1]) : null,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(MdIcons.chevron_left, size: 18),
                      const SizedBox(width: 4),
                      Text("Previous".tl,
                          style: const TextStyle(
                              height: 1.0,
                              leadingDistribution:
                                  TextLeadingDistribution.even)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: showChapterList,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(MdIcons.format_list_bulleted, size: 18),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          index >= 0
                              ? "${index + 1} / ${list.length}"
                              : "Chapters".tl,
                          style: const TextStyle(
                              height: 1.0,
                              leadingDistribution:
                                  TextLeadingDistribution.even),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Button(
                  onPressed: hasNext ? () => goToNovel(list[index + 1]) : null,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text("Next".tl,
                          style: const TextStyle(
                              height: 1.0,
                              leadingDistribution:
                                  TextLeadingDistribution.even)),
                      const SizedBox(width: 4),
                      const Icon(MdIcons.chevron_right, size: 18),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Future<Res<String>> loadData() {
    return Network().getNovelContent(novel.id.toString());
  }

  Iterable<Widget> buildList(BuildContext context) sync* {
    double fontSizeAdd = appdata.settings["readingFontSize"] - 16.0;
    double fontHeight = appdata.settings["readingLineHeight"];

    yield Text(novel.title,
        style: TextStyle(
            fontSize: 24.0 + fontSizeAdd, fontWeight: FontWeight.bold));
    yield const SizedBox(height: 12.0);
    yield const Divider(
      style: DividerThemeData(horizontalMargin: EdgeInsets.all(0)),
    );
    yield const SizedBox(height: 12.0);

    var novelContent = (translatedContent ?? data!).split('\n');
    for (var content in novelContent) {
      if (content.isEmpty) continue;
      if (content.startsWith('[uploadedimage:')) {
        var imageId = content.nums;
        yield GestureDetector(
          onTap: () {
            ImagePage.show(["novel:${novel.id.toString()}/$imageId"]);
          },
          child: SizedBox(
            height: 300,
            width: double.infinity,
            child: AnimatedImage(
              image: CachedNovelImageProvider(novel.id.toString(), imageId),
              filterQuality: FilterQuality.medium,
              fit: BoxFit.contain,
              height: 300,
              width: double.infinity,
            ),
          ),
        );
      } else if (content.startsWith('[chapter:')) {
        var title = content.replaceLast(']', '').split(':')[1];
        yield Text(title,
                style: TextStyle(
                    fontSize: 20.0 + fontSizeAdd,
                    fontWeight: FontWeight.bold,
                    height: fontHeight))
            .paddingBottom(8);
      } else {
        yield Text(content,
                style:
                    TextStyle(fontSize: 16.0 + fontSizeAdd, height: fontHeight))
            .paddingBottom(appdata.settings["readingParagraphSpacing"]);
      }
    }
  }
}

/// A side panel listing every chapter (episode) of a series, used to jump
/// directly to a specific chapter from the reader.
class _NovelChapterList extends StatelessWidget {
  const _NovelChapterList({
    required this.novels,
    required this.currentId,
    required this.onSelected,
  });

  final List<Novel> novels;

  final int currentId;

  final void Function(Novel novel) onSelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TitleBar(title: "Chapters".tl),
        Expanded(
          child: ListView.builder(
            itemCount: novels.length,
            itemBuilder: (context, index) {
              final n = novels[index];
              final isCurrent = n.id == currentId;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  Navigator.of(context).pop();
                  if (!isCurrent) {
                    onSelected(n);
                  }
                },
                child: Container(
                  color: isCurrent
                      ? ColorScheme.of(context).primaryContainer.toOpacity(0.4)
                      : null,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 32,
                        child: Text(
                          "${index + 1}",
                          style: TextStyle(
                            color: ColorScheme.of(context).primary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          n.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isCurrent)
                        Icon(
                          MdIcons.check,
                          size: 18,
                          color: ColorScheme.of(context).primary,
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class TranslationController {
  final String content;

  final bool isTranslated;

  final void Function(String translated) onTranslated;

  final void Function() revert;

  const TranslationController({
    required this.content,
    required this.isTranslated,
    required this.onTranslated,
    required this.revert,
  });
}

class _NovelReadingSettings extends StatefulWidget {
  const _NovelReadingSettings(this.callback, this.controller);

  final void Function() callback;

  final TranslationController controller;

  static Future show(
    BuildContext context,
    void Function() callback,
    TranslationController controller,
  ) {
    return Navigator.of(context).push(
      SideBarRoute(_NovelReadingSettings(callback, controller)),
    );
  }

  @override
  State<_NovelReadingSettings> createState() => __NovelReadingSettingsState();
}

class __NovelReadingSettingsState extends State<_NovelReadingSettings> {
  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        children: [
          TitleBar(title: "Reading Settings".tl),
          const SizedBox(height: 8),
          Card(
            padding: EdgeInsets.zero,
            child: ListTile(
              title: Text("Font Size".tl),
              subtitle: Slider(
                value: appdata.settings["readingFontSize"],
                onChanged: (value) {
                  setState(() {
                    appdata.settings["readingFontSize"] = value;
                  });
                  appdata.writeSettings();
                  widget.callback();
                },
                min: 12.0,
                max: 24.0,
                divisions: 12,
                label: appdata.settings["readingFontSize"].toString(),
              ),
              trailing: Text(appdata.settings["readingFontSize"].toString()),
            ),
          ).paddingHorizontal(8).paddingBottom(8),
          Card(
            padding: EdgeInsets.zero,
            child: ListTile(
              title: Text("Line Height".tl),
              subtitle: Slider(
                value: appdata.settings["readingLineHeight"],
                onChanged: (value) {
                  setState(() {
                    appdata.settings["readingLineHeight"] = value;
                  });
                  appdata.writeSettings();
                  widget.callback();
                },
                min: 1.0,
                max: 2.0,
                divisions: 10,
                label: appdata.settings["readingLineHeight"].toString(),
              ),
              trailing: Text(appdata.settings["readingLineHeight"].toString()),
            ),
          ).paddingHorizontal(8).paddingBottom(8),
          Card(
            padding: EdgeInsets.zero,
            child: ListTile(
              title: Text("Paragraph Spacing".tl),
              subtitle: Slider(
                value: appdata.settings["readingParagraphSpacing"],
                onChanged: (value) {
                  setState(() {
                    appdata.settings["readingParagraphSpacing"] = value;
                  });
                  appdata.writeSettings();
                  widget.callback();
                },
                min: 0.0,
                max: 16.0,
                divisions: 8,
                label: appdata.settings["readingParagraphSpacing"].toString(),
              ),
              trailing:
                  Text(appdata.settings["readingParagraphSpacing"].toString()),
            ),
          ).paddingHorizontal(8).paddingBottom(8),
          // 深色模式
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 8),
            padding: EdgeInsets.zero,
            child: ListTile(
              title: Text("Theme".tl),
              trailing: DropDownButton(
                  title: Text(appdata.settings["theme"] ?? "System".tl),
                  items: [
                    MenuFlyoutItem(
                        text: Text("System".tl),
                        onPressed: () {
                          setState(() {
                            appdata.settings["theme"] = "System";
                          });
                          appdata.writeData();
                          StateController.findOrNull(tag: "MyApp")?.update();
                        }),
                    MenuFlyoutItem(
                        text: Text("light".tl),
                        onPressed: () {
                          setState(() {
                            appdata.settings["theme"] = "Light";
                          });
                          appdata.writeData();
                          StateController.findOrNull(tag: "MyApp")?.update();
                        }),
                    MenuFlyoutItem(
                        text: Text("dark".tl),
                        onPressed: () {
                          setState(() {
                            appdata.settings["theme"] = "Dark";
                          });
                          appdata.writeData();
                          StateController.findOrNull(tag: "MyApp")?.update();
                        }),
                  ]),
            ),
          ).paddingBottom(8),
          Card(
            padding: EdgeInsets.zero,
            child: ListTile(
              title: Text("Translate Novel".tl),
              trailing: widget.controller.isTranslated
                  ? Button(
                      onPressed: () {
                        widget.controller.revert();
                        context.pop();
                      },
                      child: Text("Revert".tl),
                    )
                  : Button(
                      onPressed: translate,
                      child: isTranslating
                          ? const SizedBox(
                              width: 42,
                              height: 18,
                              child: Center(
                                child: SizedBox.square(
                                  dimension: 18,
                                  child: ProgressRing(
                                    strokeWidth: 2,
                                  ),
                                ),
                              ),
                            )
                          : Text("Translate".tl),
                    ),
            ),
          ).paddingHorizontal(8).paddingBottom(8),
        ],
      ),
    );
  }

  bool isTranslating = false;

  void translate() async {
    setState(() {
      isTranslating = true;
    });
    try {
      var translated = await Translator.instance
          .translate(widget.controller.content, "zh-CN");
      widget.controller.onTranslated(translated);
      if (mounted) {
        context.pop();
      }
    } catch (e) {
      setState(() {
        isTranslating = false;
      });
      if (mounted) {
        context.showToast(message: "Failed to translate".tl);
      }
      Log.error("Translate", e.toString());
    }
  }
}
