import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:pixes/appdata.dart';
import 'package:pixes/components/illust_widget.dart';
import 'package:pixes/foundation/app.dart';
import 'package:pixes/foundation/image_provider.dart';
import 'package:pixes/foundation/slideshow/original_image_load.dart';
import 'package:pixes/foundation/slideshow/slideshow_controller.dart';
import 'package:pixes/network/network.dart';
import 'package:pixes/utils/translation.dart';
import 'package:window_manager/window_manager.dart';

class SlideshowPage extends StatefulWidget {
  const SlideshowPage({
    super.key,
    required this.illusts,
    required this.nextUrl,
    required this.source,
    this.controller,
    this.addBookmark,
  });

  final List<Illust> illusts;
  final String? nextUrl;
  final String source;

  /// Optional dependencies for exercising the complete viewer without network.
  /// The page owns and disposes its playback controller.
  final SlideshowController<ui.Image>? controller;
  final Future<Res<bool>> Function(Illust)? addBookmark;

  @override
  State<SlideshowPage> createState() => _SlideshowPageState();
}

class _SlideshowPageState extends State<SlideshowPage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late final SlideshowController<ui.Image> _controller;
  late final AnimationController _countdown;
  final _vertical = PageController();
  final _workKeys = <int, GlobalKey<_ArtworkPagerState>>{};
  final _bookmarking = <int>{};
  Timer? _tapTimer;
  Timer? _messageTimer;
  Timer? _overlayTimer;
  String? _message;
  int _countdownRevision = -1;
  bool _touching = false;
  bool _scrolling = false;
  bool _didScroll = false;
  bool _syncing = false;
  bool _syncQueued = false;
  bool _overlayVisible = true;

  static const _overlayIdleDuration = Duration(seconds: 3);
  static const _overlayFadeDuration = Duration(milliseconds: 280);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _countdown = AnimationController(vsync: this);
    final saved = appdata.settings['slideshowInterval'];
    final seconds = saved is num ? saved.toInt().clamp(1, 60) : 5;
    _controller = widget.controller ??
        SlideshowController<ui.Image>(
          initialIllusts: widget.illusts,
          nextUrl: widget.nextUrl,
          loadPage: Network().getIllustsWithNextUrl,
          loadImage: OriginalImageLoad.new,
          interval: Duration(seconds: seconds),
          waitForImageLoad:
              appdata.settings['slideshowWaitForImageLoad'] != false,
        );
    _controller.addListener(_update);
    if (_controller.current == null) unawaited(_controller.next());
    _updateCountdown();
    _scheduleOverlayHide();
  }

  void _scheduleOverlayHide() {
    _overlayTimer?.cancel();
    if (!_overlayVisible || _touching || _scrolling) return;
    _overlayTimer = Timer(_overlayIdleDuration, () {
      if (mounted && !_touching && !_scrolling) {
        setState(() => _overlayVisible = false);
      }
    });
  }

  void _revealOverlay({bool autoHide = true}) {
    _overlayTimer?.cancel();
    if (!_overlayVisible && mounted) {
      setState(() => _overlayVisible = true);
    }
    if (autoHide) _scheduleOverlayHide();
  }

  void _updateCountdown() {
    if (_countdownRevision == _controller.countdownRevision) return;
    _countdownRevision = _controller.countdownRevision;
    _countdown.stop();
    _countdown.value = _controller.progress.clamp(0, 1);
    if (_controller.countdownRunning) {
      _countdown.animateTo(1,
          duration: _controller.remaining, curve: Curves.linear);
    }
  }

  void _update() {
    if (!mounted) return;
    _updateCountdown();
    setState(() {});
    _queuePagerSync();
  }

  void _queuePagerSync() {
    if (_syncQueued ||
        _syncing ||
        _scrolling ||
        _touching ||
        _controller.busy) {
      return;
    }
    _syncQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncQueued = false;
      if (mounted) unawaited(_syncPagers());
    });
  }

  Future<void> _syncPagers() async {
    final index = _controller.currentIndex;
    if (index < 0 ||
        !_vertical.hasClients ||
        _syncing ||
        _scrolling ||
        _touching ||
        _controller.busy) {
      return;
    }
    final work = _controller.workOf(index);
    final page = _controller.pagesOf(work).indexOf(index);
    final verticalMatches = (_vertical.page! - work).abs() < 0.001;
    final horizontalMatches =
        _workKeys[work]?.currentState?.isAt(page) ?? false;
    if (verticalMatches && horizontalMatches) return;
    _syncing = true;
    _controller.setInteracting(true);
    try {
      if (!verticalMatches) {
        await _vertical.animateToPage(work,
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic);
      }
      if (!mounted ||
          _touching ||
          _scrolling ||
          index != _controller.currentIndex) {
        return;
      }
      await _workKeys[work]?.currentState?.showPage(page);
    } finally {
      _syncing = false;
      if (mounted) {
        if (!_touching && !_scrolling) {
          _controller.setInteracting(false, resetCountdown: true);
        }
        _queuePagerSync();
      }
    }
  }

  void _pointerDown(PointerDownEvent _) {
    _tapTimer?.cancel();
    _touching = true;
    _didScroll = false;
    _revealOverlay(autoHide: false);
    _controller.setInteracting(true);
  }

  void _pointerUp(PointerEvent _) {
    _touching = false;
    // Keep the timer frozen while Flutter distinguishes a tap from a double tap.
    _tapTimer?.cancel();
    _tapTimer = Timer(
        kDoubleTapTimeout + const Duration(milliseconds: 30), _releaseTouch);
    _scheduleOverlayHide();
    if (_didScroll && !_scrolling) _releaseTouch();
  }

  void _releaseTouch() {
    _tapTimer?.cancel();
    if (!mounted || _touching || _scrolling || _syncing) return;
    _controller.setInteracting(false, resetCountdown: _didScroll);
    _didScroll = false;
    _queuePagerSync();
  }

  bool _scrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _scrolling = true;
      _didScroll = true;
      _revealOverlay(autoHide: false);
      _controller.setInteracting(true);
    } else if (notification is ScrollEndNotification && _scrolling) {
      _scrolling = false;
      // Scroll notifications arrive during layout; rebuild on the next frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _releaseTouch();
          _revealOverlay();
        }
      });
    }
    return false;
  }

  void _tap() {
    _revealOverlay();
    _controller.togglePlaying();
    _releaseTouch();
  }

  void _doubleTap() {
    _revealOverlay();
    unawaited(_bookmark());
    _releaseTouch();
  }

  void _showMessage(String value) {
    if (!mounted) return;
    _messageTimer?.cancel();
    setState(() => _message = value);
    _messageTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _message = null);
    });
  }

  Future<void> _bookmark() async {
    final illust = _controller.current?.illust;
    if (illust == null || _bookmarking.contains(illust.id)) return;
    if (illust.isBookmarked) {
      _showMessage('Bookmarked'.tl);
      return;
    }
    setState(() => _bookmarking.add(illust.id));
    try {
      final result = await (widget.addBookmark?.call(illust) ??
          Network().addBookmark(illust.id.toString(), 'add'));
      if (result.success) {
        illust.isBookmarked = true;
        IllustWidget.favoriteCallbacks[illust.id.toString()]?.call(true);
      }
      // A late response belongs to the artwork on which the gesture happened.
      if (mounted && _controller.current?.illust.id == illust.id) {
        _showMessage(
            (result.success ? 'Bookmarked' : 'Bookmark failed, try again').tl);
      }
    } catch (_) {
      if (mounted && _controller.current?.illust.id == illust.id) {
        _showMessage('Bookmark failed, try again'.tl);
      }
    } finally {
      _bookmarking.remove(illust.id);
      if (mounted) setState(() {});
    }
  }

  Future<void> _changeSpeed() async {
    _revealOverlay();
    _controller.setInteracting(true);
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(builder: (context, update) {
        return ContentDialog(
          title: Text('Speed'.tl),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('${_controller.interval.inSeconds} ${'seconds / image'.tl}'),
            const SizedBox(height: 16),
            Slider(
              min: 1,
              max: 60,
              divisions: 59,
              value: _controller.interval.inSeconds.toDouble(),
              label: '${_controller.interval.inSeconds}',
              onChanged: (value) {
                _controller.setInterval(Duration(seconds: value.round()));
                update(() {});
              },
            ),
            Checkbox(
              checked: _controller.waitForImageLoad,
              onChanged: (value) {
                if (value == null) return;
                _controller.setWaitForImageLoad(value);
                appdata.settings['slideshowWaitForImageLoad'] = value;
                appdata.writeSettings();
                update(() {});
              },
              content: Text('Wait for image loading'.tl),
            ),
            Checkbox(
              checked: appdata.settings['slideshowShowThumbnailWhileLoading'] !=
                  false,
              onChanged: (value) {
                if (value == null) return;
                appdata.settings['slideshowShowThumbnailWhileLoading'] = value;
                appdata.writeSettings();
                update(() {});
                if (mounted) setState(() {});
              },
              content: Text('Show thumbnail while loading'.tl),
            ),
          ]),
          actions: [
            Button(
                onPressed: () => Navigator.of(context).pop(),
                child: Text('Close'.tl))
          ],
        );
      }),
    );
    if (!mounted) return;
    _revealOverlay();
    appdata.settings['slideshowInterval'] = _controller.interval.inSeconds;
    appdata.writeSettings();
    _controller.setInteracting(false, resetCountdown: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _tapTimer?.cancel();
      _touching = false;
      _scrolling = false;
      _controller.setActive(false);
      _controller.setInteracting(false);
    } else {
      _controller.setActive(true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tapTimer?.cancel();
    _messageTimer?.cancel();
    _overlayTimer?.cancel();
    _controller.removeListener(_update);
    _controller.dispose();
    _vertical.dispose();
    _countdown.dispose();
    super.dispose();
  }

  void _horizontal(int offset) {
    final index = _controller.currentIndex;
    if (index < 0) return;
    final pages = _controller.pagesOf(_controller.workOf(index));
    final target = pages.indexOf(index) + offset;
    if (target >= 0 && target < pages.length) {
      unawaited(_controller.goTo(pages[target]));
    }
  }

  Widget _images() {
    return Listener(
      onPointerDown: _pointerDown,
      onPointerUp: _pointerUp,
      onPointerCancel: _pointerUp,
      child: GestureDetector(
        key: const ValueKey('slideshow-gestures'),
        behavior: HitTestBehavior.opaque,
        onTap: _tap,
        onDoubleTap: _doubleTap,
        child: NotificationListener<ScrollNotification>(
          onNotification: _scrollNotification,
          child: PageView.builder(
            key: const ValueKey('artwork-pager'),
            controller: _vertical,
            scrollDirection: Axis.vertical,
            allowImplicitScrolling: false,
            itemCount: _controller.workCount,
            onPageChanged: (work) {
              if (!_syncing || _touching || _scrolling) {
                unawaited(_controller.goTo(_controller.pagesOf(work).first));
              }
            },
            itemBuilder: (context, work) {
              final pages = _controller.pagesOf(work);
              return _ArtworkPager(
                key: _workKeys.putIfAbsent(
                    work, () => GlobalKey<_ArtworkPagerState>()),
                pages: pages,
                controller: _controller,
                onChanged: (index) {
                  if ((!_syncing || _touching || _scrolling) &&
                      _vertical.hasClients &&
                      _vertical.page!.round() == work) {
                    unawaited(_controller.goTo(index));
                  }
                },
              );
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final slide = _controller.current;
    final title = Text(
      '${widget.source} · ${'Slideshow'.tl}',
      overflow: TextOverflow.ellipsis,
    );
    final work =
        slide == null ? null : _controller.workOf(_controller.currentIndex);
    final pages = work == null ? <int>[] : _controller.pagesOf(work);
    return FluentTheme(
      data: FluentThemeData(brightness: Brightness.dark),
      child: DefaultTextStyle(
        style: const TextStyle(color: Colors.white, fontSize: 14),
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.space): () {
              _revealOverlay();
              _controller.togglePlaying();
            },
            const SingleActivator(LogicalKeyboardKey.arrowDown): () {
              _revealOverlay();
              unawaited(_controller.nextWork());
            },
            const SingleActivator(LogicalKeyboardKey.arrowUp): () {
              _revealOverlay();
              unawaited(_controller.previousWork());
            },
            const SingleActivator(LogicalKeyboardKey.arrowRight): () {
              _revealOverlay();
              _horizontal(1);
            },
            const SingleActivator(LogicalKeyboardKey.arrowLeft): () {
              _revealOverlay();
              _horizontal(-1);
            },
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                Navigator.of(context).pop(),
          },
          child: Focus(
            autofocus: true,
            child: ColoredBox(
              color: Colors.black,
              child: Stack(fit: StackFit.expand, children: [
                _images(),
                if (slide == null && !_controller.busy)
                  IgnorePointer(
                    ignoring: !_overlayVisible,
                    child: Center(
                      child: AnimatedOpacity(
                        opacity: _overlayVisible ? 1 : 0,
                        duration: _overlayFadeDuration,
                        child: Center(
                          child: Text(
                            (_controller.error ?? 'No playable images found')
                                .tl,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    ignoring: !_overlayVisible,
                    child: AnimatedOpacity(
                      opacity: _overlayVisible ? 1 : 0,
                      duration: _overlayFadeDuration,
                      child: DecoratedBox(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Color(0xB3000000), Color(0x00000000)],
                          ),
                        ),
                        child: SafeArea(
                          bottom: false,
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                                App.isMacOS ? 84 : 12, 8, 12, 20),
                            child: Row(children: [
                              IconButton(
                                icon: const Icon(FluentIcons.back),
                                onPressed: () => Navigator.of(context).pop(),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: App.isDesktop
                                    ? DragToMoveArea(child: title)
                                    : title,
                              ),
                              const SizedBox(width: 8),
                              Button(
                                onPressed: _changeSpeed,
                                child: Text(
                                    '${_controller.interval.inSeconds} ${'seconds / image'.tl}'),
                              ),
                            ]),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 80,
                  child: IgnorePointer(
                    ignoring: !_overlayVisible,
                    child: AnimatedOpacity(
                      opacity: _overlayVisible ? 1 : 0,
                      duration: _overlayFadeDuration,
                      child: IgnorePointer(
                        child: SafeArea(
                          top: false,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 16, 4, 24),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (slide != null) ...[
                                  Text(
                                    slide.illust.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      shadows: [Shadow(blurRadius: 6)],
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    slide.illust.author.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      shadows: [Shadow(blurRadius: 6)],
                                    ),
                                  ),
                                  if (pages.length > 1)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 10),
                                      child: Text(
                                        '${pages.indexOf(_controller.currentIndex) + 1} / ${pages.length}',
                                        key: const ValueKey(
                                            'image-page-indicator'),
                                      ),
                                    ),
                                ],
                                if (_message != null ||
                                    _controller.error != null ||
                                    _controller.ended)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: Text(
                                      _message ??
                                          (_controller.error ??
                                                  'Slideshow finished')
                                              .tl,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: 16,
                  bottom: 20,
                  child: IgnorePointer(
                    ignoring: !_overlayVisible,
                    child: AnimatedOpacity(
                      opacity: _overlayVisible ? 1 : 0,
                      duration: _overlayFadeDuration,
                      child: SafeArea(
                        top: false,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (slide != null) ...[
                              Tooltip(
                                message: 'Bookmarks'.tl,
                                child: IconButton(
                                  key: const ValueKey('slideshow-bookmark'),
                                  onPressed: () {
                                    _revealOverlay();
                                    unawaited(_bookmark());
                                  },
                                  icon: _bookmarking.contains(slide.illust.id)
                                      ? const SizedBox(
                                          width: 24,
                                          height: 24,
                                          child: ProgressRing(strokeWidth: 2),
                                        )
                                      : Icon(
                                          slide.illust.isBookmarked
                                              ? FluentIcons.heart_fill
                                              : FluentIcons.heart,
                                          color: slide.illust.isBookmarked
                                              ? Colors.red
                                              : Colors.white,
                                          size: 28,
                                        ),
                                ),
                              ),
                              const SizedBox(height: 20),
                            ],
                            Tooltip(
                              message:
                                  (_controller.playing ? 'Pause' : 'Play').tl,
                              child: AnimatedBuilder(
                                animation: _countdown,
                                builder: (context, _) => CustomPaint(
                                  key: const ValueKey('slideshow-countdown'),
                                  painter:
                                      SlideshowRingPainter(_countdown.value),
                                  child: SizedBox(
                                    width: 52,
                                    height: 52,
                                    child: IconButton(
                                      key: const ValueKey(
                                          'slideshow-play-pause'),
                                      onPressed: () {
                                        _revealOverlay();
                                        _controller.togglePlaying();
                                      },
                                      icon: _controller.busy
                                          ? const SizedBox(
                                              width: 20,
                                              height: 20,
                                              child:
                                                  ProgressRing(strokeWidth: 2),
                                            )
                                          : Icon(
                                              _controller.playing
                                                  ? FluentIcons.pause
                                                  : FluentIcons.play,
                                              size: 20,
                                            ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            if (_controller.error != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Button(
                                  onPressed: () {
                                    _revealOverlay();
                                    unawaited(_controller.next());
                                  },
                                  child: Text('Retry'.tl),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _ArtworkPager extends StatefulWidget {
  const _ArtworkPager(
      {super.key,
      required this.pages,
      required this.controller,
      required this.onChanged});
  final List<int> pages;
  final SlideshowController<ui.Image> controller;
  final ValueChanged<int> onChanged;

  @override
  State<_ArtworkPager> createState() => _ArtworkPagerState();
}

class _ArtworkPagerState extends State<_ArtworkPager> {
  late final _horizontal = PageController(
    initialPage:
        math.max(0, widget.pages.indexOf(widget.controller.currentIndex)),
    keepPage: false,
  );

  bool isAt(int page) =>
      _horizontal.hasClients && (_horizontal.page! - page).abs() < 0.001;

  Future<void> showPage(int page) async {
    if (_horizontal.hasClients && !isAt(page)) {
      await _horizontal.animateToPage(page,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic);
    }
  }

  @override
  void dispose() {
    _horizontal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PageView.builder(
      controller: _horizontal,
      itemCount: widget.pages.length,
      physics: widget.pages.length == 1
          ? const NeverScrollableScrollPhysics()
          : null,
      onPageChanged: (page) => widget.onChanged(widget.pages[page]),
      itemBuilder: (context, page) {
        final index = widget.pages[page];
        final slide = widget.controller.slideAt(index);
        final original = widget.controller.imageAt(index);
        final showThumbnail =
            appdata.settings['slideshowShowThumbnailWhileLoading'] != false;
        if (original == null && showThumbnail) {
          return Image(
            key: ValueKey('thumbnail:${slide.url}'),
            image: CachedImageProvider(slide.illust.images[slide.page].medium),
            fit: BoxFit.contain,
            gaplessPlayback: true,
          );
        }
        return RawImage(
          key: ValueKey(slide.url),
          image: original,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
        );
      },
    );
  }
}

class SlideshowRingPainter extends CustomPainter {
  const SlideshowRingPainter(this.progress);
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 2;
    canvas.drawCircle(center, radius, Paint()..color = const Color(0x80000000));
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, stroke..color = const Color(0x55FFFFFF));
    canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        2 * math.pi * progress,
        false,
        stroke..color = Colors.white);
  }

  @override
  bool shouldRepaint(SlideshowRingPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
