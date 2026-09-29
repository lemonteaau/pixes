import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pixes/appdata.dart';
import 'package:pixes/components/md.dart';
import 'package:pixes/components/page_route.dart';
import 'package:pixes/components/ugoira.dart';
import 'package:pixes/foundation/app.dart';
import 'package:pixes/foundation/image_provider.dart';
import 'package:pixes/foundation/optimistic_toggle.dart';
import 'package:pixes/foundation/slideshow/original_image_load.dart';
import 'package:pixes/foundation/slideshow/slideshow_controller.dart';
import 'package:pixes/network/download.dart';
import 'package:pixes/network/network.dart';
import 'package:pixes/pages/comments_page.dart';
import 'package:pixes/pages/illust_page.dart';
import 'package:pixes/pages/user_info_page.dart';
import 'package:pixes/utils/screen_awake.dart';
import 'package:pixes/utils/translation.dart';
import 'package:share_plus/share_plus.dart';
import 'package:window_manager/window_manager.dart';

/// A full-screen, short-video style player for a feed of artworks: swipe up
/// and down between works, sideways between the pages of one work, tap to
/// pause, double tap to like, long press for more. While it plays, the
/// controls fade away so only the artwork is left on screen.
class SlideshowPage extends StatefulWidget {
  const SlideshowPage({
    super.key,
    required this.illusts,
    required this.nextUrl,
    required this.source,
    this.controller,
    this.setBookmark,
    this.resumeKey,
  });

  final List<Illust> illusts;
  final String? nextUrl;
  final String source;

  /// Optional dependencies for exercising the complete viewer without network.
  /// The page owns and disposes its playback controller.
  final SlideshowController<ui.Image>? controller;
  final Future<Res<bool>> Function(Illust illust, bool value)? setBookmark;

  /// Identifies the feed this slideshow plays; see [SlideshowButton].
  final Object? resumeKey;

  /// Where the last slideshow of each feed stopped. Kept in memory only, so
  /// a refreshed feed (a new key) or a restarted app starts from the top.
  static final _sessions = Expando<_Session>('slideshow sessions');

  @override
  State<SlideshowPage> createState() => _SlideshowPageState();
}

class _SlideshowPageState extends State<SlideshowPage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late final SlideshowController<ui.Image> _controller;
  late final AnimationController _countdown;
  late final PageController _vertical;
  final _workKeys = <int, GlobalKey<_ArtworkPagerState>>{};
  final _bursts = <_Burst>[];
  final _bookmarkedWhenShown = <int, bool>{};
  StreamSubscription<(Object, bool)>? _bookmarkChanges;
  StreamSubscription<(Object, bool)>? _followChanges;
  Timer? _tapTimer;
  Timer? _messageTimer;
  Timer? _hideTimer;
  String? _message;
  Offset? _doubleTapPosition;
  int _burstId = 0;
  int _countdownRevision = -1;
  bool _touching = false;
  bool _scrolling = false;
  bool _didScroll = false;
  bool _syncing = false;
  bool _syncQueued = false;
  bool _controlsVisible = true;
  bool _wasPlaying = true;
  bool _sheetOpen = false;

  static const _overlayFadeDuration = Duration(milliseconds: 250);
  static const _controlsIdleDuration = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _countdown = AnimationController(vsync: this);
    final saved = appdata.settings['slideshowInterval'];
    final seconds = saved is num ? saved.toInt().clamp(1, 60) : 5;
    final key = widget.resumeKey;
    final session = key == null ? null : SlideshowPage._sessions[key];
    _controller = widget.controller ??
        SlideshowController<ui.Image>(
          initialIllusts: session?.illusts ?? widget.illusts,
          nextUrl: session != null ? session.nextUrl : widget.nextUrl,
          loadPage: Network().getIllustsWithNextUrl,
          loadImage: OriginalImageLoad.new,
          interval: Duration(seconds: seconds),
          waitForImageLoad:
              appdata.settings['slideshowWaitForImageLoad'] != false,
        );
    _controller.addListener(_update);
    _bookmarkChanges = illustBookmarks.changes.listen((change) {
      for (final illust in _illusts()) {
        if (illust.id == change.$1) illust.isBookmarked = change.$2;
      }
      if (mounted) setState(() {});
    });
    _followChanges = userFollows.changes.listen((change) {
      for (final illust in _illusts()) {
        if (illust.author.id == change.$1) illust.author.isFollowed = change.$2;
      }
      if (mounted) setState(() {});
    });
    final resumeAt = session != null && session.index < _controller.slideCount
        ? session.index
        : null;
    _vertical = PageController(
        initialPage: resumeAt == null ? 0 : _controller.workOf(resumeAt));
    if (_controller.current == null) {
      unawaited(
          resumeAt == null ? _controller.next() : _controller.goTo(resumeAt));
    }
    _setImmersive(true);
    // Paused or not, the screen stays on while the slideshow is open.
    unawaited(ScreenAwake.setEnabled(true));
    _updateCountdown();
    _wasPlaying = _controller.playing;
    _showControls();
  }

  /// Shows the controls, which fade out again after [delay] so the artwork
  /// is left on its own, whether playing or paused.
  void _showControls({Duration delay = _controlsIdleDuration}) {
    _hideTimer?.cancel();
    if (!_controlsVisible && mounted) setState(() => _controlsVisible = true);
    _hideTimer = Timer(delay, () {
      if (mounted && !_touching && !_scrolling && !_sheetOpen) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  /// Every work in the feed, so bookmark and follow changes made anywhere
  /// (including a failed request reverting after a swipe) reach all copies.
  Iterable<Illust> _illusts() sync* {
    for (var work = 0; work < _controller.workCount; work++) {
      yield _controller.slideAt(_controller.pagesOf(work).first).illust;
    }
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
    if (_controller.playing != _wasPlaying) {
      _wasPlaying = _controller.playing;
      // Pausing or resuming shows the controls, then leaves just the artwork.
      _showControls(delay: const Duration(milliseconds: 1500));
    }
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
            duration: const Duration(milliseconds: 320),
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
    _controller.setInteracting(true);
  }

  void _pointerUp(PointerEvent _) {
    _touching = false;
    // Keep the timer frozen while Flutter distinguishes a tap from a double tap.
    _tapTimer?.cancel();
    _tapTimer = Timer(
        kDoubleTapTimeout + const Duration(milliseconds: 30), _releaseTouch);
    if (_didScroll && !_scrolling) _releaseTouch();
  }

  void _releaseTouch() {
    _tapTimer?.cancel();
    if (!mounted || _touching || _scrolling || _syncing || _sheetOpen) return;
    _controller.setInteracting(false, resetCountdown: _didScroll);
    _didScroll = false;
    _queuePagerSync();
  }

  bool _scrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _scrolling = true;
      _didScroll = true;
      _controller.setInteracting(true);
      _hideTimer?.cancel();
    } else if (notification is ScrollEndNotification && _scrolling) {
      _scrolling = false;
      // Scroll notifications arrive during layout; rebuild on the next frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _releaseTouch();
        // A manual swipe shows who made the new work, then gets out of the way.
        _showControls();
      });
    }
    return false;
  }

  /// The middle of the screen pauses and resumes; anywhere else shows or
  /// hides the controls.
  static Rect _pauseZone(Size size) {
    final side = (size.shortestSide * 0.36).clamp(120.0, 200.0);
    return Rect.fromCenter(
        center: size.center(Offset.zero), width: side, height: side);
  }

  void _tapUp(TapUpDetails details) {
    final size = context.size;
    if (size != null && _pauseZone(size).contains(details.localPosition)) {
      _controller.togglePlaying();
    } else if (_controlsVisible) {
      _hideControls();
    } else {
      _showControls();
    }
    _releaseTouch();
  }

  void _hideControls() {
    _hideTimer?.cancel();
    if (_controlsVisible && mounted) setState(() => _controlsVisible = false);
  }

  /// Full screen while playing: hides the status and navigation bars.
  void _setImmersive(bool value) {
    if (!App.isMobile) return;
    unawaited(SystemChrome.setEnabledSystemUIMode(
        value ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge));
  }

  void _saveSession() {
    final key = widget.resumeKey;
    if (key == null) return;
    final index = _controller.currentIndex;
    SlideshowPage._sessions[key] = index < 0 || _controller.ended
        ? null
        : _Session(_controller.illusts, _controller.nextUrl, index);
  }

  void _doubleTap() {
    final position = _doubleTapPosition;
    if (position != null) {
      setState(() => _bursts.add(_Burst(_burstId++, position)));
    }
    final illust = _controller.current?.illust;
    // Like a short video: double tap only ever likes, it never un-likes.
    if (illust != null && !illust.isBookmarked) _setBookmarked(illust, true);
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

  void _setBookmarked(Illust illust, bool value, {String restrict = 'public'}) {
    _bookmarkedWhenShown.putIfAbsent(illust.id, () => illust.isBookmarked);
    setIllustBookmarked(
      illust,
      value,
      restrict: restrict,
      send: widget.setBookmark,
      onFailure: _showMessage,
    );
    setState(() {});
  }

  void _follow(Author author) {
    setAuthorFollowed(author, true, onFailure: _showMessage);
    setState(() {});
  }

  /// Opens another page on top, pausing playback until it is closed.
  Future<void> _open(Route<void> route) async {
    _controller.setActive(false);
    _setImmersive(false);
    unawaited(ScreenAwake.setEnabled(false));
    await Navigator.of(context).push(route);
    if (!mounted) return;
    _setImmersive(true);
    unawaited(ScreenAwake.setEnabled(true));
    _controller.setActive(true);
  }

  void _openDetails(Illust illust) =>
      _open(AppPageRoute(builder: (_) => IllustPage(illust)));

  void _openAuthor(Author author) =>
      _open(AppPageRoute(builder: (_) => UserInfoPage(author.id.toString())));

  void _openComments(Illust illust) =>
      _open(SideBarRoute(CommentsPage(illust.id.toString())));

  void _download(Illust illust) {
    DownloadManager().addDownloadingTask(illust);
    _showMessage('Added to downloads'.tl);
  }

  void _setInterval(int seconds) {
    _controller.setInterval(Duration(seconds: seconds));
    appdata.settings['slideshowInterval'] = seconds;
    appdata.writeSettings();
  }

  Future<void> _openMore() async {
    if (_sheetOpen) return;
    _sheetOpen = true;
    _hideTimer?.cancel();
    _controller.setInteracting(true);
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close'.tl,
      barrierColor: const Color(0x66000000),
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (context, _, __) => _MoreSheet(
        controller: _controller,
        illust: _controller.current?.illust,
        onPrivateBookmark: (illust) =>
            _setBookmarked(illust, true, restrict: 'private'),
        onDownload: _download,
        onDetails: _openDetails,
        onInterval: _setInterval,
        onChanged: () {
          if (mounted) setState(() {});
        },
      ),
      transitionBuilder: (context, animation, _, child) => SlideTransition(
        position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
        child: child,
      ),
    );
    if (!mounted) return;
    _sheetOpen = false;
    _controller.setInteracting(false);
    _showControls();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _tapTimer?.cancel();
      _touching = false;
      _scrolling = false;
      _controller.setActive(false);
      _controller.setInteracting(false);
    } else if (ModalRoute.of(context)?.isCurrent ?? true) {
      // The system may bring the bars back while the app was away.
      _setImmersive(true);
      _controller.setActive(true);
    }
  }

  @override
  void dispose() {
    _saveSession();
    _setImmersive(false);
    unawaited(ScreenAwake.setEnabled(false));
    WidgetsBinding.instance.removeObserver(this);
    _tapTimer?.cancel();
    _messageTimer?.cancel();
    _hideTimer?.cancel();
    _bookmarkChanges?.cancel();
    _followChanges?.cancel();
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
        onTapUp: _tapUp,
        onDoubleTapDown: (details) =>
            _doubleTapPosition = details.localPosition,
        onDoubleTap: _doubleTap,
        onLongPress: () => unawaited(_openMore()),
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

  Widget _fade(Widget child) {
    return IgnorePointer(
      ignoring: !_controlsVisible,
      child: AnimatedOpacity(
        opacity: _controlsVisible ? 1 : 0,
        duration: _overlayFadeDuration,
        // Dropping the semantics at zero opacity and restoring them after the
        // slide changed trips a framework assertion; hidden controls stay
        // reachable for screen readers anyway.
        alwaysIncludeSemantics: true,
        child: child,
      ),
    );
  }

  Widget _topBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: _fade(DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x80000000), Color(0x00000000)],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(App.isMacOS ? 80 : 4, 4, 4, 24),
            child: Row(children: [
              _GlassIconButton(
                icon: FluentIcons.back,
                tooltip: 'Back'.tl,
                onPressed: () => Navigator.of(context).pop(),
              ),
              Expanded(
                child: _draggable(Center(
                  child: Text(
                    '${widget.source} · ${'Slideshow'.tl}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      shadows: _textShadow,
                    ),
                  ),
                )),
              ),
              _GlassIconButton(
                icon: FluentIcons.more,
                tooltip: 'More'.tl,
                onPressed: () => unawaited(_openMore()),
              ),
            ]),
          ),
        ),
      )),
    );
  }

  Widget _draggable(Widget child) =>
      App.isDesktop ? DragToMoveArea(child: child) : child;

  Widget _info(Slide slide, List<int> pages) {
    final illust = slide.illust;
    final tags = illust.tags
        .take(4)
        .map((tag) => '#${tag.translatedName ?? tag.name}')
        .join('  ');
    return Positioned(
      left: 0,
      right: 84,
      bottom: 0,
      child: _fade(SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (pages.length > 1)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _Pill(
                    child: Text(
                      '${pages.indexOf(_controller.currentIndex) + 1} / ${pages.length}',
                      key: const ValueKey('image-page-indicator'),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              GestureDetector(
                onTap: () => _openAuthor(illust.author),
                child: Text(
                  '@${illust.author.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    shadows: _textShadow,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              GestureDetector(
                onTap: () => _openDetails(illust),
                child: Text(
                  illust.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15, shadows: _textShadow),
                ),
              ),
              if (tags.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  tags,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xDDFFFFFF),
                    shadows: _textShadow,
                  ),
                ),
              ],
            ],
          ),
        ),
      )),
    );
  }

  Widget _actions(Illust illust) {
    // Pixiv counts the viewer's own bookmark; follow our optimistic state.
    final shownBookmarked =
        _bookmarkedWhenShown[illust.id] ?? illust.isBookmarked;
    final likes = illust.totalBookmarks +
        (illust.isBookmarked ? 1 : 0) -
        (shownBookmarked ? 1 : 0);
    return Positioned(
      right: 8,
      top: MediaQuery.paddingOf(context).top + 56,
      bottom: 0,
      child: _fade(SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 28),
          // Shrinks the column on short screens such as a phone in landscape.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.bottomRight,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _AuthorAvatar(
                  author: illust.author,
                  onOpen: () => _openAuthor(illust.author),
                  onFollow: () => _follow(illust.author),
                ),
                const SizedBox(height: 22),
                _ActionButton(
                  key: const ValueKey('slideshow-bookmark'),
                  label: _compactCount(math.max(0, likes)),
                  onPressed: () => _setBookmarked(illust, !illust.isBookmarked),
                  icon: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    switchInCurve: Curves.elasticOut,
                    transitionBuilder: (child, animation) =>
                        ScaleTransition(scale: animation, child: child),
                    child: Icon(
                      illust.isBookmarked
                          ? MdIcons.favorite
                          : MdIcons.favorite_border,
                      key: ValueKey(illust.isBookmarked),
                      color: illust.isBookmarked
                          ? const Color(0xFFFE2C55)
                          : Colors.white,
                      size: 36,
                      shadows: _iconShadow,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _ActionButton(
                  label: 'Comments'.tl,
                  onPressed: () => _openComments(illust),
                  icon: const Icon(MdIcons.chat_bubble_rounded,
                      size: 32, shadows: _iconShadow),
                ),
                const SizedBox(height: 16),
                _ActionButton(
                  label: 'Download'.tl,
                  onPressed: () => _download(illust),
                  icon: const Icon(MdIcons.download_rounded,
                      size: 34, shadows: _iconShadow),
                ),
                const SizedBox(height: 16),
                _ActionButton(
                  label: 'Details'.tl,
                  onPressed: () => _openDetails(illust),
                  icon: const Icon(MdIcons.open_in_full_rounded,
                      size: 28, shadows: _iconShadow),
                ),
              ],
            ),
          ),
        ),
      )),
    );
  }

  Widget _progress() {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Positioned(
      left: 0,
      right: 0,
      bottom: bottom,
      height: 3,
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: _controller.playing || _controlsVisible ? 1 : 0,
          duration: _overlayFadeDuration,
          child: _controller.busy
              ? const _LoadingLine()
              : AnimatedBuilder(
                  animation: _countdown,
                  builder: (context, _) => CustomPaint(
                    key: const ValueKey('slideshow-progress'),
                    painter: SlideshowProgressPainter(
                      _countdown.value,
                      paused: !_controller.playing,
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final slide = _controller.current;
    final work =
        slide == null ? null : _controller.workOf(_controller.currentIndex);
    final pages = work == null ? <int>[] : _controller.pagesOf(work);
    final status = _message ??
        (_controller.ended ? 'Slideshow finished'.tl : _controller.error?.tl);
    return FluentTheme(
      data: FluentThemeData(brightness: Brightness.dark),
      child: DefaultTextStyle(
        style: const TextStyle(color: Colors.white, fontSize: 14),
        child: IconTheme(
          data: const IconThemeData(color: Colors.white),
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.space):
                  _controller.togglePlaying,
              const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                  unawaited(_controller.nextWork()),
              const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                  unawaited(_controller.previousWork()),
              const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                  _horizontal(1),
              const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                  _horizontal(-1),
              const SingleActivator(LogicalKeyboardKey.keyL): () {
                final illust = _controller.current?.illust;
                if (illust != null) {
                  _setBookmarked(illust, !illust.isBookmarked);
                }
              },
              const SingleActivator(LogicalKeyboardKey.escape): () =>
                  Navigator.of(context).pop(),
            },
            child: Focus(
              autofocus: true,
              child: MouseRegion(
                onHover: (_) => _showControls(),
                child: ColoredBox(
                  color: Colors.black,
                  child: Stack(fit: StackFit.expand, children: [
                    _images(),
                    for (final burst in _bursts)
                      _HeartBurst(
                        key: ValueKey(burst.id),
                        position: burst.position,
                        onDone: () => setState(() => _bursts.remove(burst)),
                      ),
                    // Marks the pause zone: a play icon while paused, and a
                    // pause icon while playing with the controls shown.
                    if (slide != null)
                      IgnorePointer(
                        child: Center(
                          child: AnimatedOpacity(
                            opacity: !_controlsVisible
                                ? 0
                                : _controller.playing
                                    ? 0.7
                                    : 1,
                            duration: _overlayFadeDuration,
                            child: Container(
                              width: 88,
                              height: 88,
                              decoration: const BoxDecoration(
                                color: Color(0x40000000),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                _controller.playing
                                    ? MdIcons.pause_rounded
                                    : MdIcons.play_arrow_rounded,
                                key: ValueKey(_controller.playing
                                    ? 'slideshow-playing'
                                    : 'slideshow-paused'),
                                size: 60,
                                color: const Color(0xCCFFFFFF),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (slide == null && _controller.busy)
                      const Center(child: ProgressRing()),
                    if (slide == null && !_controller.busy)
                      Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              (_controller.error ?? 'No playable images found')
                                  .tl,
                              textAlign: TextAlign.center,
                            ),
                            if (_controller.error != null) ...[
                              const SizedBox(height: 12),
                              Button(
                                onPressed: () => unawaited(_controller.next()),
                                child: Text('Retry'.tl),
                              ),
                            ],
                          ],
                        ),
                      ),
                    _topBar(),
                    if (slide != null) _info(slide, pages),
                    if (slide != null) _actions(slide.illust),
                    _progress(),
                    if (status != null)
                      Positioned(
                        left: 24,
                        right: 24,
                        bottom: MediaQuery.paddingOf(context).bottom + 160,
                        child: Center(
                          child: GestureDetector(
                            onTap: _controller.error != null && slide != null
                                ? () => unawaited(_controller.next())
                                : null,
                            child: _Pill(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 8),
                              child: Text(
                                _controller.error != null &&
                                        slide != null &&
                                        _message == null
                                    ? '$status · ${'Retry'.tl}'
                                    : status,
                                textAlign: TextAlign.center,
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
        ),
      ),
    );
  }
}

const _textShadow = [Shadow(blurRadius: 6, color: Color(0x99000000))];
const _iconShadow = [Shadow(blurRadius: 8, color: Color(0x66000000))];

String _compactCount(int value) {
  try {
    return NumberFormat.compact(locale: App.locale.toString()).format(value);
  } catch (_) {
    return value.toString();
  }
}

class _Session {
  const _Session(this.illusts, this.nextUrl, this.index);
  final List<Illust> illusts;
  final String? nextUrl;
  final int index;
}

class _Burst {
  _Burst(this.id, this.position);
  final int id;
  final Offset position;
}

/// The heart that pops out where a double tap landed.
class _HeartBurst extends StatefulWidget {
  const _HeartBurst({super.key, required this.position, required this.onDone});

  final Offset position;
  final VoidCallback onDone;

  @override
  State<_HeartBurst> createState() => _HeartBurstState();
}

class _HeartBurstState extends State<_HeartBurst>
    with SingleTickerProviderStateMixin {
  static const _size = 96.0;
  late final _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  )..forward().whenComplete(() {
      if (mounted) widget.onDone();
    });
  final _tilt = (math.Random().nextDouble() - 0.5) * 0.6;

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: widget.position.dx - _size / 2,
      top: widget.position.dy - _size / 2,
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _animation,
          builder: (context, child) {
            final t = _animation.value;
            final scale = t < 0.25
                ? Curves.easeOutBack.transform(t / 0.25) * 1.15
                : 1.15 -
                    0.15 * ((t - 0.25) / 0.2).clamp(0, 1) +
                    0.6 * ((t - 0.55) / 0.45).clamp(0, 1);
            final opacity = t < 0.55 ? 1.0 : 1 - (t - 0.55) / 0.45;
            return Transform.translate(
              offset: Offset(0, -40 * ((t - 0.55) / 0.45).clamp(0, 1)),
              child: Transform.rotate(
                angle: _tilt,
                child: Transform.scale(
                  scale: scale,
                  child: Opacity(opacity: opacity.clamp(0, 1), child: child),
                ),
              ),
            );
          },
          child: const Icon(
            MdIcons.favorite,
            size: _size,
            color: Color(0xFFFE2C55),
            shadows: _iconShadow,
          ),
        ),
      ),
    );
  }
}

class _AuthorAvatar extends StatelessWidget {
  const _AuthorAvatar({
    required this.author,
    required this.onOpen,
    required this.onFollow,
  });

  final Author author;
  final VoidCallback onOpen;
  final VoidCallback onFollow;

  @override
  Widget build(BuildContext context) {
    const size = 50.0;
    return SizedBox(
      width: size,
      height: size + 10,
      child: Stack(clipBehavior: Clip.none, children: [
        GestureDetector(
          onTap: onOpen,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 1.5),
              color: const Color(0xFF333333),
            ),
            clipBehavior: Clip.antiAlias,
            child: author.avatar.isEmpty
                ? const Icon(MdIcons.person, size: 30)
                : Image(
                    image: CachedImageProvider(author.avatar),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        const Icon(MdIcons.person, size: 30),
                  ),
          ),
        ),
        Positioned(
          left: (size - 22) / 2,
          top: size - 11,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            transitionBuilder: (child, animation) =>
                ScaleTransition(scale: animation, child: child),
            child: author.isFollowed
                ? const SizedBox(key: ValueKey('followed'), width: 22)
                : GestureDetector(
                    key: const ValueKey('follow'),
                    onTap: onFollow,
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(0xFFFE2C55),
                      ),
                      child: const Icon(MdIcons.add, size: 16),
                    ),
                  ),
          ),
        ),
      ]),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final Widget icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: SizedBox(
          width: 64,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(height: 40, child: Center(child: icon)),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                shadows: _textShadow,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _GlassIconButton extends StatelessWidget {
  const _GlassIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        icon: Icon(icon, size: 18, shadows: _iconShadow),
        onPressed: onPressed,
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
  });

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0x80000000),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

/// A thin sweep along the bottom while the next image loads.
class _LoadingLine extends StatefulWidget {
  const _LoadingLine();

  @override
  State<_LoadingLine> createState() => _LoadingLineState();
}

class _LoadingLineState extends State<_LoadingLine>
    with SingleTickerProviderStateMixin {
  late final _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, _) => CustomPaint(
        key: const ValueKey('slideshow-loading'),
        painter: _LoadingLinePainter(_animation.value),
      ),
    );
  }
}

class _LoadingLinePainter extends CustomPainter {
  const _LoadingLinePainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.width / 2;
    final half = size.width / 2 * Curves.easeOut.transform(t);
    canvas.drawRect(
      Rect.fromLTRB(center - half, 0, center + half, size.height),
      Paint()..color = Color.fromRGBO(255, 255, 255, 0.8 * (1 - t)),
    );
  }

  @override
  bool shouldRepaint(_LoadingLinePainter oldDelegate) => oldDelegate.t != t;
}

class SlideshowProgressPainter extends CustomPainter {
  const SlideshowProgressPainter(this.progress, {this.paused = false});
  final double progress;
  final bool paused;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
        Offset.zero & size, Paint()..color = const Color(0x33FFFFFF));
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width * progress.clamp(0, 1), size.height),
      Paint()
        ..color = paused ? const Color(0xFFFFFFFF) : const Color(0xB3FFFFFF),
    );
  }

  @override
  bool shouldRepaint(SlideshowProgressPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.paused != paused;
}

/// The long-press panel: quick actions and playback settings.
class _MoreSheet extends StatefulWidget {
  const _MoreSheet({
    required this.controller,
    required this.illust,
    required this.onPrivateBookmark,
    required this.onDownload,
    required this.onDetails,
    required this.onInterval,
    required this.onChanged,
  });

  final SlideshowController<ui.Image> controller;
  final Illust? illust;
  final ValueChanged<Illust> onPrivateBookmark;
  final ValueChanged<Illust> onDownload;
  final ValueChanged<Illust> onDetails;
  final ValueChanged<int> onInterval;
  final VoidCallback onChanged;

  @override
  State<_MoreSheet> createState() => _MoreSheetState();
}

class _MoreSheetState extends State<_MoreSheet> {
  static const _presets = [3, 5, 8, 10, 15, 30];

  void _close([VoidCallback? then]) {
    Navigator.of(context).pop();
    then?.call();
  }

  @override
  Widget build(BuildContext context) {
    final illust = widget.illust;
    final seconds = widget.controller.interval.inSeconds;
    final waitForLoad = widget.controller.waitForImageLoad;
    final thumbnails =
        appdata.settings['slideshowShowThumbnailWhileLoading'] != false;
    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Container(
          width: double.infinity,
          decoration: const BoxDecoration(
            color: Color(0xF2161616),
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
              child: DefaultTextStyle(
                style: const TextStyle(color: Colors.white, fontSize: 14),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: const Color(0x55FFFFFF),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        if (illust != null)
                          _SheetAction(
                            icon: MdIcons.lock_outline,
                            label: 'Private Favorite'.tl,
                            onTap: () =>
                                _close(() => widget.onPrivateBookmark(illust)),
                          ),
                        if (illust != null)
                          _SheetAction(
                            icon: MdIcons.download_rounded,
                            label: 'Download'.tl,
                            onTap: () =>
                                _close(() => widget.onDownload(illust)),
                          ),
                        if (illust != null)
                          _SheetAction(
                            icon: MdIcons.share_outlined,
                            label: 'Share'.tl,
                            onTap: () => _close(() => Share.share(
                                "${illust.title}\nhttps://pixiv.net/artworks/${illust.id}")),
                          ),
                        if (illust != null)
                          _SheetAction(
                            icon: MdIcons.open_in_full_rounded,
                            label: 'Details'.tl,
                            onTap: () => _close(() => widget.onDetails(illust)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Text(
                      '${'Speed'.tl} · $seconds ${'seconds / image'.tl}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final preset in _presets)
                          _SpeedChip(
                            label: '${preset}s',
                            selected: preset == seconds,
                            onTap: () {
                              widget.onInterval(preset);
                              setState(() {});
                            },
                          ),
                      ],
                    ),
                    Slider(
                      min: 1,
                      max: 60,
                      divisions: 59,
                      value: seconds.toDouble(),
                      label: '${seconds}s',
                      onChanged: (value) {
                        widget.onInterval(value.round());
                        setState(() {});
                      },
                    ),
                    const SizedBox(height: 4),
                    _SheetSwitch(
                      label: 'Wait for image loading'.tl,
                      value: waitForLoad,
                      onChanged: (value) {
                        widget.controller.setWaitForImageLoad(value);
                        appdata.settings['slideshowWaitForImageLoad'] = value;
                        appdata.writeSettings();
                        setState(() {});
                      },
                    ),
                    _SheetSwitch(
                      label: 'Show thumbnail while loading'.tl,
                      value: thumbnails,
                      onChanged: (value) {
                        appdata.settings['slideshowShowThumbnailWhileLoading'] =
                            value;
                        appdata.writeSettings();
                        setState(() {});
                        widget.onChanged();
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SheetAction extends StatelessWidget {
  const _SheetAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: 64,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 48,
              height: 48,
              decoration: const BoxDecoration(
                color: Color(0x1FFFFFFF),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 22, color: Colors.white),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12),
            ),
          ]),
        ),
      ),
    );
  }
}

class _SpeedChip extends StatelessWidget {
  const _SpeedChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFFE2C55) : const Color(0x1FFFFFFF),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _SheetSwitch extends StatelessWidget {
  const _SheetSwitch({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Expanded(child: Text(label)),
        ToggleSwitch(checked: value, onChanged: onChanged),
      ]),
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
        final still = RawImage(
          key: ValueKey(slide.url),
          image: original,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
        );
        if (!slide.illust.isUgoira) return still;
        // The original is only the first frame; play the animation over it.
        return Stack(fit: StackFit.expand, children: [
          still,
          LayoutBuilder(builder: (context, constraints) {
            final size = applyBoxFit(
              BoxFit.contain,
              Size(slide.illust.width.toDouble(),
                  slide.illust.height.toDouble()),
              constraints.biggest,
            ).destination;
            return Center(
              child: UgoiraWidget(
                key: ValueKey('ugoira:${slide.illust.id}'),
                id: slide.illust.id.toString(),
                previewImage:
                    CachedImageProvider(slide.illust.images[slide.page].large),
                width: size.width,
                height: size.height,
                autoPlay: true,
              ),
            );
          }),
        ]);
      },
    );
  }
}
