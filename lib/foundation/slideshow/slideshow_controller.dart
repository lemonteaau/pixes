import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pixes/network/models.dart';
import 'package:pixes/network/res.dart';
import 'package:pixes/utils/block.dart';

class Slide {
  const Slide(this.illust, this.page);

  final Illust illust;
  final int page;
  String get url => illust.images[page].original;
}

/// A cancellable load whose decoded resource remains valid until dispose.
abstract class SlideLoad<T> {
  Future<T> get ready;
  void dispose();
}

typedef SlidePageLoader = Future<Res<List<Illust>>> Function(String url);

class _BufferedSlide<T> {
  final ready = Completer<T?>();
  SlideLoad<T>? load;
  T? image;
  bool loading = false;

  void dispose() {
    load?.dispose();
    if (!ready.isCompleted) ready.complete(null);
  }
}

/// A flat playback sequence backed by groups for the two paging axes.
/// Owns a bounded original-image buffer with at most three concurrent loads.
class SlideshowController<T> extends ChangeNotifier {
  SlideshowController({
    required List<Illust> initialIllusts,
    required String? nextUrl,
    required this.loadPage,
    required this.loadImage,
    Duration interval = const Duration(seconds: 5),
    this.waitForImageLoad = true,
    DateTime Function()? now,
  })  : _nextUrl = nextUrl == 'end' ? null : nextUrl,
        _interval = interval,
        _remaining = interval,
        _now = now ?? DateTime.now {
    _append(initialIllusts);
  }

  final SlidePageLoader loadPage;
  final SlideLoad<T> Function(String url) loadImage;
  bool waitForImageLoad;
  final DateTime Function() _now;
  final _slides = <Slide>[];
  final _works = <List<int>>[];
  final _workIndices = <int>[];
  final _seen = <int>{};
  final _failed = <int>{};
  final _buffer = <int, _BufferedSlide<T>>{};
  String? _nextUrl;
  Future<bool>? _pageRequest;
  Timer? _timer;
  Duration _interval;
  Duration _remaining;
  DateTime? _startedAt;
  int _index = -1;
  int _navigation = 0;
  int _target = 0;
  bool _disposed = false;
  bool _active = true;
  bool _interacting = false;
  bool _automaticNavigation = false;
  bool playing = true;
  bool busy = false;
  bool ended = false;
  String? error;
  T? image;

  Slide? get current => _index < 0 ? null : _slides[_index];
  String? get nextUrl => _nextUrl;

  /// The playable works in order, including pages this controller fetched.
  List<Illust> get illusts =>
      [for (final pages in _works) _slides[pages.first].illust];
  int get currentIndex => _index;

  /// The slide being moved to while [busy], otherwise the current one.
  int get targetIndex => busy ? _target : _index;
  Duration get interval => _interval;
  int get position => _index + 1;
  int get workCount => _works.length;
  int get slideCount => _slides.length;
  int workOf(int index) => _workIndices[index];
  List<int> pagesOf(int work) => List.unmodifiable(_works[work]);
  Slide slideAt(int index) => _slides[index];
  T? imageAt(int index) => _buffer[index]?.image;
  bool get countdownRunning => _startedAt != null;
  int countdownRevision = 0;

  Duration get remaining {
    final elapsed =
        _startedAt == null ? Duration.zero : _now().difference(_startedAt!);
    final micros = (_remaining - elapsed).inMicroseconds;
    return Duration(microseconds: micros.clamp(0, _interval.inMicroseconds));
  }

  double get progress =>
      1 - remaining.inMicroseconds / _interval.inMicroseconds;

  void _append(List<Illust> illusts) {
    for (final illust in checkIllusts(List.of(illusts))) {
      if (!_seen.add(illust.id)) continue;
      final pages = <int>[];
      for (var page = 0; page < illust.images.length; page++) {
        if (Illust.isOriginalImageUrl(illust.images[page].original)) {
          pages.add(_slides.length);
          _workIndices.add(_works.length);
          _slides.add(Slide(illust, page));
        }
      }
      if (pages.isNotEmpty) _works.add(pages);
    }
  }

  Future<bool> _fetchPage() {
    if (_pageRequest != null) return _pageRequest!;
    final url = _nextUrl;
    if (url == null || _disposed) return Future.value(false);
    final request = () async {
      try {
        final result = await loadPage(url);
        if (_disposed) return false;
        if (result.error) {
          error = 'Unable to load more images';
          return false;
        }
        _append(result.data);
        final next = result.subData as String?;
        _nextUrl = next == url || next == 'end' ? null : next;
        notifyListeners();
        return true;
      } catch (_) {
        if (!_disposed) error = 'Unable to load more images';
        return false;
      }
    }();
    _pageRequest = request;
    request.whenComplete(() => _pageRequest = null);
    return request;
  }

  void _fillBuffer(int target, {bool fetchMore = true}) {
    if (_disposed || target < 0 || target >= _slides.length) return;
    final work = workOf(target);
    // Prioritize the target, sequential playback and the next vertical page.
    // Six retained originals maximum, including the old visible frame while
    // another loads. All other originals remain reusable in the disk cache.
    final wanted = <int>{
      target,
      if (_index >= 0) _index,
      if (target + 1 < _slides.length) target + 1,
      if (work + 1 < _works.length) _works[work + 1].first,
      if (target + 2 < _slides.length) target + 2,
      if (target > 0) target - 1,
      if (work > 0) _works[work - 1].first,
      if (target + 3 < _slides.length) target + 3,
    }.take(6).toSet();
    for (final index in _buffer.keys.toList()) {
      if (!wanted.contains(index) || _failed.contains(index)) {
        _buffer.remove(index)!.dispose();
      }
    }
    // Reinsert in priority order so a newly selected page jumps the queue.
    final ordered = <int, _BufferedSlide<T>>{};
    for (final index in wanted) {
      if (!_failed.contains(index)) {
        ordered[index] = _buffer[index] ?? _BufferedSlide<T>();
      }
    }
    _buffer
      ..clear()
      ..addAll(ordered);
    _pumpLoads();
    if (fetchMore && _slides.length - target <= 4 && error == null && _active) {
      unawaited(_fetchPage().then((loaded) {
        if (loaded && !_disposed) {
          // Do not recursively request pages when an entire page was filtered.
          _fillBuffer(busy ? _target : _index, fetchMore: false);
        }
      }));
    }
  }

  void _pumpLoads() {
    if (_disposed || !_active) return;
    var running = _buffer.values.where((entry) => entry.loading).length;
    for (final item in _buffer.entries.toList()) {
      if (running >= 3) break;
      final entry = item.value;
      if (entry.load != null || entry.ready.isCompleted) continue;
      running++;
      entry.loading = true;
      try {
        entry.load = loadImage(_slides[item.key].url);
        entry.load!.ready.then(
          (value) => _loaded(item.key, entry, value),
          onError: (_) => _loaded(item.key, entry, null),
        );
      } catch (_) {
        scheduleMicrotask(() => _loaded(item.key, entry, null));
      }
    }
  }

  void _loaded(int index, _BufferedSlide<T> entry, T? value) {
    if (_disposed || _buffer[index] != entry) return;
    entry.loading = false;
    entry.image = value;
    if (value == null) _failed.add(index);
    entry.ready.complete(value);
    _pumpLoads();
    notifyListeners();
  }

  Future<void> next({bool automatic = false}) {
    if (ended) return Future.value();
    return _moveTo(_index + 1, automatic: automatic);
  }

  Future<void> goTo(int index) => _moveTo(index);

  Future<void> previousWork() {
    if (_index < 0 || workOf(_index) == 0) return Future.value();
    return goTo(_works[workOf(_index) - 1].first);
  }

  Future<void> nextWork() {
    if (_index < 0) return next();
    final work = workOf(_index);
    return goTo(work + 1 < workCount ? _works[work + 1].first : _slides.length);
  }

  Future<void> _moveTo(int index, {bool automatic = false}) async {
    if (_disposed || !_active || index < 0) return;
    if (automatic && (!playing || _interacting || busy)) return;
    final navigation = ++_navigation;
    final direction = index < _index ? -1 : 1;
    _automaticNavigation = automatic;
    _stopClock();
    busy = true;
    ended = false;
    error = null;
    _target = index;
    notifyListeners();
    var skipped = 0;
    try {
      while (!_disposed && navigation == _navigation && _active) {
        if (skipped >= 30) {
          error = 'No playable images found';
          playing = false;
          break;
        }
        if (index < 0) break;
        if (index >= _slides.length) {
          if (_nextUrl == null) {
            ended = true;
            playing = false;
            break;
          }
          if (!await _fetchPage()) {
            playing = false;
            break;
          }
          skipped++;
          continue;
        }
        _target = index;
        _fillBuffer(index);
        if (automatic &&
            !waitForImageLoad &&
            !_buffer[index]!.ready.isCompleted) {
          index += direction;
          skipped++;
          continue;
        }
        final decoded =
            _failed.contains(index) ? null : await _buffer[index]!.ready.future;
        if (_disposed || navigation != _navigation || !_active) return;
        if (decoded == null) {
          index += direction;
          skipped++;
          continue;
        }
        _index = index;
        image = decoded;
        _remaining = _interval;
        _fillBuffer(index);
        break;
      }
    } finally {
      if (!_disposed && navigation == _navigation) {
        busy = false;
        _automaticNavigation = false;
        _startClock();
        notifyListeners();
      }
    }
  }

  void _stopClock() {
    _remaining = remaining;
    _startedAt = null;
    _timer?.cancel();
    countdownRevision++;
  }

  void _startClock() {
    _timer?.cancel();
    if (!_disposed &&
        _active &&
        playing &&
        !busy &&
        !ended &&
        !_interacting &&
        image != null) {
      _startedAt = _now();
      _timer = Timer(_remaining, () {
        _startedAt = null;
        _remaining = Duration.zero;
        unawaited(next(automatic: true));
      });
    }
    countdownRevision++;
  }

  void _cancelAutomaticNavigation() {
    if (!_automaticNavigation) return;
    _navigation++;
    _automaticNavigation = false;
    busy = false;
    _target = _index;
    if (_index >= 0) _fillBuffer(_index);
  }

  /// Hold the timer from pointer-down through drag settling. A completed swipe
  /// resets it, whereas a pause tap freezes the existing remaining duration.
  void setInteracting(bool value, {bool resetCountdown = false}) {
    if (_disposed) return;
    _stopClock();
    _interacting = value;
    if (value) _cancelAutomaticNavigation();
    if (resetCountdown) _remaining = _interval;
    _startClock();
    notifyListeners();
  }

  void togglePlaying() {
    if (_disposed) return;
    _stopClock();
    playing = !playing;
    if (!playing) _cancelAutomaticNavigation();
    if (playing && (image == null || error != null || ended)) {
      ended = false;
      unawaited(next());
    } else {
      _startClock();
      notifyListeners();
    }
  }

  void setInterval(Duration value) {
    if (value < const Duration(seconds: 1) ||
        value > const Duration(seconds: 60) ||
        _disposed) {
      return;
    }
    _stopClock();
    _interval = value;
    _remaining = value;
    _startClock();
    notifyListeners();
  }

  void setWaitForImageLoad(bool value) {
    if (_disposed || waitForImageLoad == value) return;
    waitForImageLoad = value;
    notifyListeners();
  }

  void setActive(bool value) {
    if (_active == value || _disposed) return;
    _stopClock();
    _active = value;
    if (!value) {
      _navigation++;
      busy = false;
      _automaticNavigation = false;
    } else {
      _pumpLoads();
      if (image == null || _target != _index) {
        unawaited(goTo(_target));
      } else {
        _startClock();
      }
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _navigation++;
    _timer?.cancel();
    for (final entry in _buffer.values) {
      entry.dispose();
    }
    _buffer.clear();
    super.dispose();
  }
}
