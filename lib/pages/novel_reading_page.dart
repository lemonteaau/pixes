import 'dart:async';
import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart' hide TitleBar;
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:pixes/appdata.dart';
import 'package:pixes/components/animated_image.dart';
import 'package:pixes/components/loading.dart';
import 'package:pixes/components/md.dart';
import 'package:pixes/components/page_route.dart';
import 'package:pixes/components/title_bar.dart';
import 'package:pixes/foundation/app.dart';
import 'package:pixes/foundation/image_provider.dart';
import 'package:pixes/foundation/log.dart';
import 'package:pixes/foundation/novel_books.dart';
import 'package:pixes/foundation/novel_history.dart';
import 'package:pixes/foundation/novel_progress.dart';
import 'package:pixes/foundation/novel_replace_store.dart';
import 'package:pixes/network/network.dart';
import 'package:pixes/network/translator.dart';
import 'package:pixes/pages/image_page.dart';
import 'package:pixes/pages/main_page.dart';
import 'package:pixes/utils/app_links.dart';
import 'package:pixes/utils/novel_markup.dart';
import 'package:pixes/utils/novel_replace.dart';
import 'package:pixes/utils/screen_awake.dart';
import 'package:pixes/utils/translation.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:pixes/pages/illust_viewer.dart';

const double _minAutoScrollSpeed = 10.0;
const double _maxAutoScrollSpeed = 100.0;
const double _defaultAutoScrollSpeed = 40.0;

/// The widest the text gets, so lines stay readable on wide windows.
const double _maxContentWidth = 720.0;

double _getAutoScrollSpeed() {
  final value = appdata.settings["readingAutoScrollSpeed"];
  if (value is! num) return _defaultAutoScrollSpeed;
  return value
      .toDouble()
      .clamp(_minAutoScrollSpeed, _maxAutoScrollSpeed)
      .toDouble();
}

/// Where a reader item is: [offset] pixels into the item at [index], which
/// is [height] pixels tall.
typedef _ItemPosition = ({int index, double offset, double height});

typedef _ItemLayout = ({int index, double top, double height});

class NovelReadingPage extends StatefulWidget {
  const NovelReadingPage(this.novel,
      {this.resume = false, this.initialBlock, super.key});

  final Novel novel;

  /// Whether to go straight back to where the user stopped reading, instead
  /// of offering to.
  final bool resume;

  /// The index of the block of text to open the novel at, instead of where
  /// the user stopped reading.
  final int? initialBlock;

  @override
  State<NovelReadingPage> createState() => _NovelReadingPageState();
}

/// Opens the reader for the novel with [id], loading its details first.
class NovelReadingPageWithId extends StatefulWidget {
  const NovelReadingPageWithId(this.id, {this.resume = false, super.key});

  final String id;

  final bool resume;

  @override
  State<NovelReadingPageWithId> createState() =>
      _NovelReadingPageWithIdState();
}

class _NovelReadingPageWithIdState
    extends LoadingState<NovelReadingPageWithId, Novel> {
  @override
  Future<Res<Novel>> loadData() {
    return Network().getNovelDetail(widget.id);
  }

  @override
  Widget buildContent(BuildContext context, Novel data) {
    return NovelReadingPage(data, resume: widget.resume);
  }
}

class _NovelReadingPageState extends LoadingState<NovelReadingPage, String>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  TitleBarAction? settingsAction;

  TitleBarAction? autoScrollAction;

  TitleBarAction? chaptersAction;

  late final ScrollController _scrollController;

  late final Ticker _autoScrollTicker;

  Duration? _lastAutoScrollTick;

  bool _isAutoScrolling = false;

  bool _isScreenAwake = false;

  /// Shown after the user taps the page to pause auto scrolling.
  bool _showAutoScrollBar = false;

  int _activePointers = 0;

  /// Where the current pointer went down, while it may still be a tap.
  Offset? _tapDownPosition;

  Duration? _tapDownTime;

  bool isShowingSettings = false;

  bool isShowingChapters = false;

  String? translatedContent;

  /// The novel currently shown. Changes when navigating between the
  /// chapters (episodes) of a series or book.
  late Novel novel;

  /// All episodes of the series this novel belongs to, in reading order.
  /// Null until loaded, or if the novel does not belong to a series.
  List<Novel>? seriesNovels;

  /// The book the user put the novel in. Its chapters are read in its order
  /// instead of the series'.
  NovelCustomBook? get customBook => NovelBookStore.instance.bookOf(novel.id);

  /// The chapters of the book or series the novel is part of, in reading
  /// order. Null until the series is loaded, or if it's part of neither.
  List<Novel>? get chapters => customBook?.chapters ?? seriesNovels;

  bool get hasChapters => customBook != null || novel.seriesId != null;

  bool isLoadingSeries = false;

  Future<void>? _seriesLoading;

  String? _parsedSource;

  NovelTextReplacer? _parsedReplacer;

  List<NovelBlock> _blocks = const [];

  /// The total weight of the blocks before each block.
  List<int> _weightBefore = const [];

  int _totalWeight = 0;

  /// The reader items that are currently built, by index.
  final _mountedItems = <int, BuildContext>{};

  final _progress = ValueNotifier<double>(0);

  /// The item at the top of the screen, as of the last update.
  _ItemPosition? _lastAnchor;

  /// Whether the position changed since the novel was opened. Until it does,
  /// the saved position is left alone.
  bool _positionTouched = false;

  DateTime _lastSave = DateTime(0);

  bool _positionUpdateScheduled = false;

  bool _saveScheduled = false;

  /// Bumped to cancel a running [_scrollToItem].
  int _scrollGeneration = 0;

  bool _checkSavedPosition = true;

  late bool _resumeOnOpen;

  int? _initialBlock;

  NovelReadingProgress? _resumePrompt;

  Timer? _resumePromptTimer;

  @override
  void initState() {
    novel = widget.novel;
    _resumeOnOpen = widget.resume;
    _initialBlock = widget.initialBlock;
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NovelReplaceStore.instance.addListener(_handleStoresChanged);
    NovelBookStore.instance.addListener(_handleStoresChanged);
    NovelHistoryStore.instance.add(novel);
    _scrollController = ScrollController(keepScrollOffset: false);
    _autoScrollTicker = createTicker(_handleAutoScrollTick);
    autoScrollAction = _createAutoScrollAction();
    if (hasChapters) {
      chaptersAction = TitleBarAction(
        MdIcons.format_list_bulleted,
        "Chapters".tl,
        showChapterList,
        compactOnMobile: true,
      );
    }
    settingsAction = TitleBarAction(MdIcons.tune, "Settings".tl, () {
      if (!mounted || isLoading || data == null) return;
      _stopAutoScroll();
      _hideFloatingBars();
      if (isShowingChapters) {
        Navigator.of(context).pop();
      }
      if (!isShowingSettings) {
        _NovelReadingSettings.show(
          context,
          () {
            setState(() {});
            _syncScreenAwake();
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
      if (!mounted) return;
      final controller = StateController.findOrNull<TitleBarController>();
      if (controller == null) return;
      if (chaptersAction != null) {
        controller.addAction(chaptersAction!);
      }
      controller.addAction(autoScrollAction!);
      controller.addAction(settingsAction!);
    });
    if (customBook == null && novel.seriesId != null) {
      loadSeries();
    }
  }

  @override
  void dispose() {
    NovelReplaceStore.instance.removeListener(_handleStoresChanged);
    NovelBookStore.instance.removeListener(_handleStoresChanged);
    _saveProgress();
    WidgetsBinding.instance.removeObserver(this);
    _resumePromptTimer?.cancel();
    _scrollGeneration++;
    _stopAutoScroll(updateAction: false);
    _autoScrollTicker.dispose();
    _scrollController.dispose();
    _progress.dispose();
    final actions = [chaptersAction, autoScrollAction, settingsAction];
    Future.delayed(const Duration(milliseconds: 200), () {
      final controller = StateController.findOrNull<TitleBarController>();
      if (controller == null) return;
      for (final action in actions) {
        if (action != null) {
          controller.removeAction(action);
        }
      }
    });
    super.dispose();
  }

  void _handleStoresChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _saveProgress();
    }
  }

  TitleBarAction _createAutoScrollAction() {
    return TitleBarAction(
      _isAutoScrolling ? MdIcons.pause : MdIcons.play_arrow,
      _isAutoScrolling ? "Pause".tl : "Auto Scroll".tl,
      _toggleAutoScroll,
      compactOnMobile: true,
    );
  }

  void _refreshAutoScrollAction() {
    final current = autoScrollAction;
    final replacement = _createAutoScrollAction();
    autoScrollAction = replacement;
    if (current == null) return;
    StateController.findOrNull<TitleBarController>()
        ?.replaceAction(current, replacement);
  }

  void _toggleAutoScroll() {
    if (!mounted) return;
    if (_isAutoScrolling) {
      _stopAutoScroll();
      return;
    }
    if (ModalRoute.of(context)?.isCurrent != true) return;
    _startAutoScroll();
  }

  void _startAutoScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (!position.hasContentDimensions ||
        position.pixels >= position.maxScrollExtent - 0.5) {
      return;
    }
    _hideFloatingBars();
    _scrollGeneration++;
    _isAutoScrolling = true;
    _syncScreenAwake();
    _lastAutoScrollTick = null;
    _autoScrollTicker.start();
    _refreshAutoScrollAction();
  }

  void _stopAutoScroll({bool updateAction = true}) {
    if (!_isAutoScrolling && !_isScreenAwake) return;
    _isAutoScrolling = false;
    _syncScreenAwake();
    _lastAutoScrollTick = null;
    _autoScrollTicker.stop();
    if (updateAction) {
      _refreshAutoScrollAction();
    }
  }

  bool get _keepScreenOnDuringAutoScroll =>
      appdata.settings["readingKeepScreenOnDuringAutoScroll"] != false;

  void _syncScreenAwake() {
    final shouldKeepAwake = _isAutoScrolling && _keepScreenOnDuringAutoScroll;
    if (_isScreenAwake == shouldKeepAwake) return;
    _isScreenAwake = shouldKeepAwake;
    ScreenAwake.setEnabled(shouldKeepAwake);
  }

  void _handleAutoScrollTick(Duration elapsed) {
    if (!_isAutoScrolling) return;
    if (!_scrollController.hasClients) {
      _stopAutoScroll();
      return;
    }

    final position = _scrollController.position;
    if (!position.hasContentDimensions) {
      _lastAutoScrollTick = elapsed;
      return;
    }
    if (_activePointers > 0 || position.isScrollingNotifier.value) {
      // The user is scrolling by hand; carry on from wherever they stop.
      _lastAutoScrollTick = null;
      return;
    }
    if (position.pixels >= position.maxScrollExtent - 0.5) {
      _stopAutoScroll();
      return;
    }

    final previousTick = _lastAutoScrollTick;
    _lastAutoScrollTick = elapsed;
    if (previousTick == null) return;

    final elapsedSeconds = ((elapsed - previousTick).inMicroseconds / 1000000)
        .clamp(0.0, 0.1)
        .toDouble();
    final nextOffset =
        (position.pixels + _getAutoScrollSpeed() * elapsedSeconds)
            .clamp(position.minScrollExtent, position.maxScrollExtent)
            .toDouble();
    position.jumpTo(nextOffset);
    if (nextOffset >= position.maxScrollExtent - 0.5) {
      _stopAutoScroll();
    }
  }

  void _changeAutoScrollSpeed(double delta) {
    setState(() {
      appdata.settings["readingAutoScrollSpeed"] =
          (_getAutoScrollSpeed() + delta)
              .clamp(_minAutoScrollSpeed, _maxAutoScrollSpeed);
    });
    appdata.writeSettings();
  }

  void _hideFloatingBars() {
    _resumePromptTimer?.cancel();
    if (!mounted || (!_showAutoScrollBar && _resumePrompt == null)) return;
    setState(() {
      _showAutoScrollBar = false;
      _resumePrompt = null;
    });
  }

  void _handlePointerDown(PointerDownEvent event) {
    _activePointers++;
    // Touching the page takes over from a running jump.
    _scrollGeneration++;
    if (_activePointers == 1 && event.buttons == kPrimaryButton) {
      _tapDownPosition = event.position;
      _tapDownTime = event.timeStamp;
    } else {
      _tapDownPosition = null;
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    final start = _tapDownPosition;
    if (start != null && (event.position - start).distance > kTouchSlop) {
      _tapDownPosition = null;
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    _activePointers = math.max(0, _activePointers - 1);
    final start = _tapDownPosition;
    final startTime = _tapDownTime;
    _tapDownPosition = null;
    if (start == null || startTime == null) return;
    if (event.timeStamp - startTime > kLongPressTimeout) return;
    _handleTap();
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    _activePointers = math.max(0, _activePointers - 1);
    _tapDownPosition = null;
  }

  /// A tap pauses auto scrolling and shows its controls; another tap hides
  /// them. Scrolling by hand doesn't count as a tap.
  void _handleTap() {
    if (_isAutoScrolling) {
      _stopAutoScroll();
      setState(() {
        _showAutoScrollBar = true;
      });
    } else if (_showAutoScrollBar) {
      setState(() {
        _showAutoScrollBar = false;
      });
    }
  }

  /// Loads the full ordered list of episodes for the current series.
  Future<void> loadSeries() {
    return _seriesLoading ??=
        _loadSeries().whenComplete(() => _seriesLoading = null);
  }

  Future<void> _loadSeries() async {
    final seriesId = novel.seriesId;
    if (seriesId == null) return;
    setState(() {
      isLoadingSeries = true;
    });
    final res = await Network().getAllNovelSeries(seriesId.toString());
    if (!mounted) return;
    setState(() {
      isLoadingSeries = false;
      if (res.success && res.data.isNotEmpty) {
        seriesNovels = res.data;
      }
    });
  }

  /// Switches the reader to [target] and reloads its content.
  void goToNovel(Novel target) {
    if (target.id == novel.id || isLoading) return;
    _saveProgress();
    _stopAutoScroll();
    _scrollGeneration++;
    _resumePromptTimer?.cancel();
    NovelHistoryStore.instance.add(target);
    setState(() {
      novel = target;
      translatedContent = null;
      isLoading = true;
      error = null;
      data = null;
      _showAutoScrollBar = false;
      _resumePrompt = null;
    });
    _positionTouched = false;
    _lastAnchor = null;
    _progress.value = 0;
    _checkSavedPosition = true;
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

  Future<void> showChapterList() async {
    if (!mounted) return;
    _stopAutoScroll();
    _hideFloatingBars();
    if (isShowingChapters) {
      Navigator.of(context).pop();
      return;
    }
    if (chapters == null) {
      await loadSeries();
      if (!mounted) return;
    }
    final list = chapters;
    if (list == null) {
      context.showToast(message: "Failed to load chapters".tl);
      return;
    }
    if (isShowingChapters) return;
    if (isShowingSettings) {
      Navigator.of(context).pop();
    }
    isShowingChapters = true;
    Navigator.of(context)
        .push(
      SideBarRoute(_NovelChapterList(
        novels: list,
        currentId: novel.id,
        onSelected: goToNovel,
      )),
    )
        .then((_) {
      isShowingChapters = false;
    });
  }

  void _ensureParsed(String source) {
    final replacer =
        NovelReplaceStore.instance.replacer(NovelReplaceStore.bookOf(novel));
    if (identical(source, _parsedSource) &&
        identical(replacer, _parsedReplacer)) {
      return;
    }
    _parsedSource = source;
    _parsedReplacer = replacer;
    _blocks = replaceNovelBlocks(parseNovelContent(source), replacer);
    var total = 0;
    _weightBefore = [
      for (final block in _blocks) (total += block.weight) - block.weight,
    ];
    _totalWeight = total;
  }

  /// Layout of the reader items that are built, sorted by index.
  List<_ItemLayout> _itemLayouts() {
    final result = <_ItemLayout>[];
    for (final entry in _mountedItems.entries) {
      final box = entry.value.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final viewport = RenderAbstractViewport.maybeOf(box);
      if (viewport == null) continue;
      result.add((
        index: entry.key,
        top: viewport.getOffsetToReveal(box, 0.0).offset,
        height: box.size.height,
      ));
    }
    result.sort((a, b) => a.index.compareTo(b.index));
    return result;
  }

  /// The item at [scrollOffset] in the list.
  _ItemPosition? _itemAt(List<_ItemLayout> layouts, double scrollOffset) {
    if (layouts.isEmpty) return null;
    var item = layouts.first;
    for (final layout in layouts) {
      if (layout.top > scrollOffset) break;
      item = layout;
    }
    return (
      index: item.index,
      offset: (scrollOffset - item.top).clamp(0.0, item.height).toDouble(),
      height: item.height,
    );
  }

  double _progressAt(_ItemPosition position) {
    final blockIndex = position.index - 1;
    if (blockIndex < 0 || _totalWeight == 0) return 0;
    if (blockIndex >= _blocks.length) return 1;
    final fraction =
        position.height > 0 ? position.offset / position.height : 1.0;
    return ((_weightBefore[blockIndex] + _blocks[blockIndex].weight * fraction) /
            _totalWeight)
        .clamp(0.0, 1.0)
        .toDouble();
  }

  void _updateReadingPosition() {
    if (!_scrollController.hasClients || _blocks.isEmpty) return;
    final position = _scrollController.position;
    if (!position.hasContentDimensions || !position.hasViewportDimension) {
      return;
    }
    final layouts = _itemLayouts();
    final top = _itemAt(layouts, position.pixels);
    if (top != null) {
      _lastAnchor = top;
    }
    // The progress is what has been on screen, so measure at the bottom.
    if (position.pixels >= position.maxScrollExtent - 1) {
      _progress.value = 1;
      return;
    }
    final bottom =
        _itemAt(layouts, position.pixels + position.viewportDimension);
    if (bottom != null) {
      _progress.value = _progressAt(bottom);
    }
  }

  void _saveProgress() {
    if (!_positionTouched || _blocks.isEmpty) return;
    _updateReadingPosition();
    final anchor = _lastAnchor;
    if (anchor == null) return;
    _lastSave = DateTime.now();
    NovelProgressStore.instance.save(NovelReadingProgress(
      novelId: novel.id,
      item: anchor.index,
      offset: anchor.offset,
      progress: _progress.value,
    ));
    final custom = customBook;
    final seriesId = novel.seriesId;
    if (custom != null) {
      NovelBookStore.instance.setLastRead(custom.id, novel.id);
    } else if (seriesId != null) {
      final index = seriesNovels?.indexWhere((n) => n.id == novel.id) ?? -1;
      NovelProgressStore.instance.saveSeries(NovelSeriesProgress(
        seriesId: seriesId,
        novelId: novel.id,
        chapter: index >= 0 ? index + 1 : null,
        title: novel.title,
      ));
    }
  }

  /// Updates the reading position once the next frame is laid out. Scroll
  /// notifications arrive before the list catches up with the new offset,
  /// so the items on screen aren't known yet when they do.
  void _schedulePositionUpdate({bool save = false}) {
    _saveScheduled |= save;
    if (_positionUpdateScheduled) return;
    _positionUpdateScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _positionUpdateScheduled = false;
      if (!mounted) return;
      if (_saveScheduled) {
        _saveScheduled = false;
        _saveProgress();
      } else {
        _updateReadingPosition();
      }
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollUpdateNotification) {
      _positionTouched = true;
      final now = DateTime.now();
      final save = now.difference(_lastSave) >= const Duration(seconds: 3);
      if (save) {
        _lastSave = now;
      }
      _schedulePositionUpdate(save: save);
    } else if (notification is ScrollEndNotification) {
      _schedulePositionUpdate();
    }
    return false;
  }

  /// Scrolls so that the top of the screen is [offset] pixels into item
  /// [index]. Items are built lazily, so this estimates where the item is
  /// and corrects over a few frames.
  Future<void> _scrollToItem(int index, double offset) async {
    final generation = ++_scrollGeneration;
    for (var attempt = 0; attempt < 30; attempt++) {
      if (!mounted ||
          generation != _scrollGeneration ||
          !_scrollController.hasClients) {
        return;
      }
      final position = _scrollController.position;
      final layouts = _itemLayouts();
      if (layouts.isNotEmpty && position.hasContentDimensions) {
        final target = layouts.where((l) => l.index == index).firstOrNull;
        double to;
        if (target != null) {
          to = target.top + offset.clamp(0.0, target.height);
        } else {
          final first = layouts.first;
          final last = layouts.last;
          final averageHeight = (last.top + last.height - first.top) /
              (last.index - first.index + 1);
          to = index < first.index
              ? first.top - (first.index - index) * averageHeight
              : last.top + last.height + (index - last.index - 1) * averageHeight;
        }
        to = to
            .clamp(position.minScrollExtent, position.maxScrollExtent)
            .toDouble();
        if (target != null && (position.pixels - to).abs() < 1) break;
        position.jumpTo(to);
      }
      await WidgetsBinding.instance.endOfFrame;
    }
    if (mounted && generation == _scrollGeneration) {
      _updateReadingPosition();
    }
  }

  void _jumpToPage(int page) {
    if (page <= 1) {
      _scrollToItem(0, 0);
      return;
    }
    final index =
        _blocks.indexWhere((b) => b is NovelPageBreakBlock && b.page == page);
    if (index >= 0) {
      _scrollToItem(index + 1, 0);
    }
  }

  void _handleInitialPosition() {
    _updateReadingPosition();
    final resume = _resumeOnOpen;
    _resumeOnOpen = false;
    final initialBlock = _initialBlock;
    _initialBlock = null;
    if (initialBlock != null) {
      _scrollToItem(initialBlock + 1, 0);
      return;
    }
    final saved = NovelProgressStore.instance.get(novel.id);
    if (saved == null ||
        saved.isFinished ||
        (saved.item <= 1 && saved.progress < 0.01)) {
      return;
    }
    if (resume) {
      _scrollToItem(saved.item, saved.offset);
      return;
    }
    setState(() {
      _resumePrompt = saved;
    });
    _resumePromptTimer?.cancel();
    _resumePromptTimer = Timer(const Duration(seconds: 10), _hideFloatingBars);
  }

  @override
  Widget buildContent(BuildContext context, String data) {
    _ensureParsed(translatedContent ?? data);
    if (_checkSavedPosition) {
      _checkSavedPosition = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _handleInitialPosition();
      });
    }
    final fontSizeAdd = appdata.settings["readingFontSize"] - 16.0;
    final double lineHeight = appdata.settings["readingLineHeight"];
    final double paragraphSpacing =
        appdata.settings["readingParagraphSpacing"];
    final style = _ReadingStyle(
      text: TextStyle(fontSize: 16.0 + fontSizeAdd, height: lineHeight),
      chapter: TextStyle(
          fontSize: 20.0 + fontSizeAdd,
          fontWeight: FontWeight.bold,
          height: lineHeight),
      lineHeight: (16.0 + fontSizeAdd) * lineHeight,
      paragraphSpacing: paragraphSpacing,
    );
    final bottomPadding = MediaQuery.paddingOf(context).bottom;
    final itemCount = _blocks.length + 2;
    return ScaffoldPage(
      padding: EdgeInsets.zero,
      content: Stack(
        children: [
          Positioned.fill(
            child: Listener(
              onPointerDown: _handlePointerDown,
              onPointerMove: _handlePointerMove,
              onPointerUp: _handlePointerUp,
              onPointerCancel: _handlePointerCancel,
              child: NotificationListener<ScrollNotification>(
                onNotification: _handleScrollNotification,
                child: SelectionArea(
                  child: DefaultTextStyle.merge(
                    style: const TextStyle(fontSize: 16.0, height: 1.6),
                    child: LayoutBuilder(builder: (context, constraints) {
                      final horizontal = math.max(
                          16.0, (constraints.maxWidth - _maxContentWidth) / 2);
                      return ListView.builder(
                        key: ValueKey(novel.id),
                        controller: _scrollController,
                        padding: EdgeInsets.fromLTRB(
                            horizontal, 16, horizontal, 16 + bottomPadding),
                        itemCount: itemCount,
                        itemBuilder: (context, index) {
                          final Widget child;
                          if (index == 0) {
                            child = buildHeader(context, fontSizeAdd);
                          } else if (index == itemCount - 1) {
                            child = buildChapterNav(context);
                          } else {
                            child = buildBlock(_blocks[index - 1], style);
                          }
                          return _TrackedItem(
                            index: index,
                            registry: _mountedItems,
                            child: child,
                          );
                        },
                      );
                    }),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _ReadingProgressBar(_progress),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 16 + bottomPadding,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: _resumePrompt != null
                  ? buildResumePrompt(_resumePrompt!)
                  : _showAutoScrollBar
                      ? buildAutoScrollBar()
                      : const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );
  }

  Widget buildResumePrompt(NovelReadingProgress saved) {
    return Center(
      key: const ValueKey("resume-prompt"),
      child: _FloatingBar(
        children: [
          const Icon(MdIcons.history, size: 18),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              "Last read: @p"
                  .tl
                  .replaceAll("@p", "${(saved.progress * 100).floor()}%"),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 12),
          FilledButton(
            onPressed: () {
              _hideFloatingBars();
              _scrollToItem(saved.item, saved.offset);
            },
            child: Text("Continue Reading".tl),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(MdIcons.close, size: 16),
            onPressed: _hideFloatingBars,
          ),
        ],
      ),
    );
  }

  Widget buildAutoScrollBar() {
    final speed = (_getAutoScrollSpeed() / 10).round();
    return Center(
      key: const ValueKey("auto-scroll-bar"),
      child: _FloatingBar(
        children: [
          FilledButton(
            key: const ValueKey("novel-auto-scroll-resume"),
            onPressed: () {
              setState(() {
                _showAutoScrollBar = false;
              });
              _startAutoScroll();
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(MdIcons.play_arrow, size: 18),
                const SizedBox(width: 4),
                Text("Continue".tl),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text("Speed".tl),
          const SizedBox(width: 4),
          IconButton(
            key: const ValueKey("novel-auto-scroll-slower"),
            icon: const Icon(MdIcons.remove, size: 16),
            onPressed: speed > 1 ? () => _changeAutoScrollSpeed(-10) : null,
          ),
          SizedBox(
            width: 24,
            child: Text("$speed", textAlign: TextAlign.center),
          ),
          IconButton(
            key: const ValueKey("novel-auto-scroll-faster"),
            icon: const Icon(MdIcons.add, size: 16),
            onPressed: speed < 10 ? () => _changeAutoScrollSpeed(10) : null,
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(MdIcons.close, size: 16),
            onPressed: () {
              setState(() {
                _showAutoScrollBar = false;
              });
            },
          ),
        ],
      ),
    );
  }

  /// The series or book and chapter, title and a divider above the text.
  Widget buildHeader(BuildContext context, double fontSizeAdd) {
    final parts = <String>[];
    final bookTitle = (customBook?.title ?? novel.seriesTitle)?.trim();
    if (bookTitle != null && bookTitle.isNotEmpty) {
      parts.add(bookTitle);
    }
    final list = chapters;
    final index = list?.indexWhere((n) => n.id == novel.id) ?? -1;
    if (index >= 0) {
      parts.add("Chapter @n of @total"
          .tl
          .replaceAll("@n", "${index + 1}")
          .replaceAll("@total", "${list!.length}"));
    }
    final primary = ColorScheme.of(context).primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasChapters)
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: showChapterList,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(MdIcons.format_list_bulleted, size: 14, color: primary),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      parts.isEmpty ? "Chapters".tl : parts.join(" · "),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: primary),
                    ),
                  ),
                ],
              ),
            ),
          ).paddingBottom(8),
        Text(novel.title,
            style: TextStyle(
                fontSize: 24.0 + fontSizeAdd, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12.0),
        const Divider(
          style: DividerThemeData(horizontalMargin: EdgeInsets.all(0)),
        ),
        const SizedBox(height: 12.0),
      ],
    );
  }

  Widget buildBlock(NovelBlock block, _ReadingStyle style) {
    return switch (block) {
      NovelParagraphBlock(:final inlines) =>
        _NovelText(inlines, style.text, onJump: _jumpToPage)
            .paddingBottom(style.paragraphSpacing),
      NovelChapterBlock(:final inlines) =>
        _NovelText(inlines, style.chapter, onJump: _jumpToPage)
            .paddingBottom(8),
      NovelBlankBlock(:final lines) => SizedBox(
          height: math.max(
              0.0, lines * style.lineHeight - style.paragraphSpacing)),
      NovelPageBreakBlock(:final page) => _PageBreak(page),
      NovelUploadedImageBlock(:final imageId) => _NovelImage(
          image: CachedNovelImageProvider(novel.id.toString(), imageId),
          cacheKey: "novel:${novel.id}/$imageId",
          onTap: () {
            ImagePage.show(["novel:${novel.id}/$imageId"]);
          },
        ).paddingVertical(8),
      NovelIllustBlock(:final illustId, :final page) =>
        _NovelIllust(illustId, page).paddingVertical(8),
    };
  }

  /// The previous / chapter-list / next bar shown at the end of a chapter.
  Widget buildChapterNav(BuildContext context) {
    if (!hasChapters) {
      return const SizedBox.shrink();
    }
    final list = chapters;
    if (list == null) {
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
}

class _ReadingStyle {
  const _ReadingStyle({
    required this.text,
    required this.chapter,
    required this.lineHeight,
    required this.paragraphSpacing,
  });

  final TextStyle text;

  final TextStyle chapter;

  /// The height of one line of text, in pixels.
  final double lineHeight;

  final double paragraphSpacing;
}

/// Registers the context of a reader item in [registry] while it is built,
/// so the reader can tell which item is on screen.
class _TrackedItem extends StatefulWidget {
  const _TrackedItem({
    required this.index,
    required this.registry,
    required this.child,
  });

  final int index;

  final Map<int, BuildContext> registry;

  final Widget child;

  @override
  State<_TrackedItem> createState() => _TrackedItemState();
}

class _TrackedItemState extends State<_TrackedItem> {
  @override
  void initState() {
    super.initState();
    widget.registry[widget.index] = context;
  }

  @override
  void didUpdateWidget(covariant _TrackedItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index ||
        oldWidget.registry != widget.registry) {
      _unregister(oldWidget);
      widget.registry[widget.index] = context;
    }
  }

  @override
  void dispose() {
    _unregister(widget);
    super.dispose();
  }

  void _unregister(_TrackedItem item) {
    if (item.registry[item.index] == context) {
      item.registry.remove(item.index);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _ReadingProgressBar extends StatelessWidget {
  const _ReadingProgressBar(this.progress);

  final ValueNotifier<double> progress;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox(
        height: 2,
        child: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (context, value, child) {
            return Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: value.clamp(0.0, 1.0),
                child: ColoredBox(
                  color: ColorScheme.of(context).primary,
                  child: const SizedBox.expand(),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _FloatingBar extends StatelessWidget {
  const _FloatingBar({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }
}

void _openLink(String url) {
  final uri = Uri.tryParse(url);
  if (uri != null && handleLink(uri)) return;
  launchUrlString(url);
}

/// A line of novel text, with ruby, links and page jumps.
class _NovelText extends StatefulWidget {
  const _NovelText(this.inlines, this.style, {required this.onJump});

  final List<NovelInline> inlines;

  final TextStyle style;

  final void Function(int page) onJump;

  @override
  State<_NovelText> createState() => _NovelTextState();
}

class _NovelTextState extends State<_NovelText> {
  final _recognizers = <int, TapGestureRecognizer>{};

  @override
  void didUpdateWidget(covariant _NovelText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.inlines, widget.inlines)) {
      _disposeRecognizers();
    }
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers.values) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  TapGestureRecognizer _recognizer(int index, VoidCallback onTap) {
    return (_recognizers[index] ??= TapGestureRecognizer())..onTap = onTap;
  }

  @override
  Widget build(BuildContext context) {
    final inlines = widget.inlines;
    if (inlines.length == 1 && inlines.first is NovelPlainText) {
      return Text((inlines.first as NovelPlainText).text, style: widget.style);
    }
    final linkStyle = TextStyle(color: ColorScheme.of(context).primary);
    final spans = <InlineSpan>[
      for (var i = 0; i < inlines.length; i++)
        switch (inlines[i]) {
          NovelPlainText(:final text) => TextSpan(text: text),
          NovelRuby(:final base, :final ruby) => WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: _Ruby(base, ruby, widget.style),
            ),
          NovelLink(:final text, :final url) => TextSpan(
              text: text,
              style: linkStyle,
              mouseCursor: SystemMouseCursors.click,
              recognizer: _recognizer(i, () => _openLink(url)),
            ),
          NovelPageJump(:final page) => TextSpan(
              text: "Jump to page @n".tl.replaceAll("@n", "$page"),
              style: linkStyle,
              mouseCursor: SystemMouseCursors.click,
              recognizer: _recognizer(i, () => widget.onJump(page)),
            ),
        },
    ];
    return Text.rich(TextSpan(children: spans), style: widget.style);
  }
}

/// Text with its reading (furigana) shown above it.
class _Ruby extends StatelessWidget {
  const _Ruby(this.base, this.ruby, this.style);

  final String base;

  final String ruby;

  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final baseStyle = DefaultTextStyle.of(context).style.merge(style);
    final fontSize = baseStyle.fontSize ?? 16.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The column lines up with the surrounding text by its first
        // baseline, which has to be the base text's.
        _NoBaseline(
          child: SelectionContainer.disabled(
            child: Text(
              ruby,
              maxLines: 1,
              softWrap: false,
              style: baseStyle.copyWith(fontSize: fontSize * 0.5, height: 1.2),
            ),
          ),
        ),
        Text(
          base,
          maxLines: 1,
          softWrap: false,
          style: baseStyle.copyWith(height: 1.0),
        ),
      ],
    );
  }
}

class _NoBaseline extends SingleChildRenderObjectWidget {
  const _NoBaseline({required Widget super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderNoBaseline();
}

class _RenderNoBaseline extends RenderProxyBox {
  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) => null;

  @override
  double? computeDryBaseline(
          covariant BoxConstraints constraints, TextBaseline baseline) =>
      null;
}

class _PageBreak extends StatelessWidget {
  const _PageBreak(this.page);

  final int page;

  @override
  Widget build(BuildContext context) {
    const divider = Divider(
      style: DividerThemeData(horizontalMargin: EdgeInsets.zero),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Row(
        children: [
          const Expanded(child: divider),
          Text(
            "$page",
            style: TextStyle(
              fontSize: 13,
              color: ColorScheme.of(context).outline,
            ),
          ).paddingHorizontal(12),
          const Expanded(child: divider),
        ],
      ),
    );
  }
}

/// An image in the novel, shown at its own aspect ratio.
class _NovelImage extends StatefulWidget {
  const _NovelImage({required this.image, required this.cacheKey, this.onTap});

  final ImageProvider image;

  final String cacheKey;

  final VoidCallback? onTap;

  @override
  State<_NovelImage> createState() => _NovelImageState();
}

class _NovelImageState extends State<_NovelImage> {
  /// Aspect ratios of loaded images, so they are laid out at their final
  /// size straight away when built again.
  static final _aspectRatios = <String, double>{};

  ImageStream? _stream;

  ImageStreamListener? _listener;

  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (!_aspectRatios.containsKey(widget.cacheKey)) {
      _resolve();
    }
  }

  @override
  void dispose() {
    _stopListening();
    super.dispose();
  }

  void _resolve() {
    _stream = widget.image.resolve(ImageConfiguration.empty);
    _listener = ImageStreamListener(
      (info, _) {
        final image = info.image;
        if (image.width > 0 && image.height > 0) {
          _aspectRatios[widget.cacheKey] = image.width / image.height;
        }
        info.dispose();
        _stopListening();
        if (mounted) setState(() {});
      },
      onError: (error, stackTrace) {
        _stopListening();
        if (mounted) {
          setState(() {
            _failed = true;
          });
        }
      },
    );
    _stream!.addListener(_listener!);
  }

  void _stopListening() {
    final listener = _listener;
    if (listener != null) {
      _stream?.removeListener(listener);
    }
    _listener = null;
    _stream = null;
  }

  @override
  Widget build(BuildContext context) {
    final ratio = _aspectRatios[widget.cacheKey];
    final maxHeight = math.min(640.0, MediaQuery.sizeOf(context).height * 0.8);
    return LayoutBuilder(builder: (context, constraints) {
      final height = ratio == null
          ? 240.0
          : math.min(maxHeight, constraints.maxWidth / ratio);
      final Widget child;
      if (ratio != null) {
        child = AnimatedImage(
          image: widget.image,
          filterQuality: FilterQuality.medium,
          fit: BoxFit.contain,
          width: double.infinity,
          height: height,
        );
      } else if (_failed) {
        child = const Center(child: Icon(MdIcons.broken_image_outlined));
      } else {
        child = const Center(
          child: SizedBox.square(
            dimension: 24,
            child: ProgressRing(strokeWidth: 2),
          ),
        );
      }
      return MouseRegion(
        cursor: widget.onTap != null
            ? SystemMouseCursors.click
            : MouseCursor.defer,
        child: GestureDetector(
          onTap: widget.onTap,
          child: SizedBox(
            width: double.infinity,
            height: height,
            child: child,
          ),
        ),
      );
    });
  }
}

/// A pixiv illustration embedded with `[pixivimage:id]`.
class _NovelIllust extends StatefulWidget {
  const _NovelIllust(this.illustId, this.page);

  final String illustId;

  final int page;

  @override
  State<_NovelIllust> createState() => _NovelIllustState();
}

class _NovelIllustState extends State<_NovelIllust> {
  static final _cache = <String, Future<Res<Illust>>>{};

  late final Future<Res<Illust>> _future;

  @override
  void initState() {
    super.initState();
    final id = widget.illustId;
    _future = _cache.putIfAbsent(id, () {
      return Network().getIllustByID(id).then((res) {
        // Try again next time instead of remembering the failure.
        if (res.error) _cache.remove(id);
        return res;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Res<Illust>>(
      future: _future,
      builder: (context, snapshot) {
        final res = snapshot.data;
        if (res == null) {
          return const SizedBox(
            height: 240,
            child: Center(
              child: SizedBox.square(
                dimension: 24,
                child: ProgressRing(strokeWidth: 2),
              ),
            ),
          );
        }
        if (res.error || res.data.images.isEmpty) {
          return Center(
            child: Button(
              onPressed: () {
                openIllustById(context, widget.illustId);
              },
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(MdIcons.image_outlined, size: 18),
                  const SizedBox(width: 8),
                  Text("${"Illustration".tl} #${widget.illustId}"),
                ],
              ),
            ),
          );
        }
        final illust = res.data;
        final image = illust.images[
            widget.page.clamp(0, illust.images.length - 1).toInt()];
        return _NovelImage(
          image: CachedImageProvider(image.large),
          cacheKey: image.large,
          onTap: () {
            openIllust(context, illust);
          },
        );
      },
    );
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
              return ListTile(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                tileColor: isCurrent
                    ? WidgetStateColor.resolveWith((states) =>
                        ColorScheme.of(context).primaryContainer.toOpacity(0.6))
                    : null,
                onPressed: () {
                  Navigator.of(context).pop();
                  if (!isCurrent) {
                    onSelected(n);
                  }
                },
                leading: Text(
                  "${index + 1}",
                  style: TextStyle(
                    color: ColorScheme.of(context).primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                trailing: isCurrent
                    ? Icon(
                        MdIcons.check,
                        size: 18,
                        color: ColorScheme.of(context).primary,
                      )
                    : const SizedBox(
                        width: 18,
                        height: 18,
                      ),
                title: Text(
                  n.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
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
          Card(
            padding: EdgeInsets.zero,
            child: ListTile(
              title: Text("Auto Scroll Speed".tl),
              subtitle: Slider(
                key: const ValueKey("novel-auto-scroll-speed"),
                value: _getAutoScrollSpeed(),
                onChanged: (value) {
                  setState(() {
                    appdata.settings["readingAutoScrollSpeed"] = value;
                  });
                },
                onChangeEnd: (_) => appdata.writeSettings(),
                min: _minAutoScrollSpeed,
                max: _maxAutoScrollSpeed,
                divisions: 9,
                label: "${(_getAutoScrollSpeed() / 10).round()}",
              ),
              trailing: Text("${(_getAutoScrollSpeed() / 10).round()} / 10"),
            ),
          ).paddingHorizontal(8).paddingBottom(8),
          Card(
            padding: EdgeInsets.zero,
            child: ListTile(
              title: Text("Keep Screen On During Auto Scroll".tl),
              trailing: Checkbox(
                key: const ValueKey("novel-keep-screen-on-auto-scroll"),
                checked:
                    appdata.settings["readingKeepScreenOnDuringAutoScroll"] !=
                        false,
                onChanged: (value) {
                  setState(() {
                    appdata.settings["readingKeepScreenOnDuringAutoScroll"] =
                        value ?? true;
                  });
                  appdata.writeSettings();
                  widget.callback();
                },
              ),
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
