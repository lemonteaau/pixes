import 'package:flutter/foundation.dart';
import 'package:pixes/network/network.dart';
import 'package:pixes/utils/novel_markup.dart';

/// A chapter of a book, with its text.
class NovelBookChapter {
  const NovelBookChapter(this.index, this.novel, this.blocks);

  /// Zero based position of the chapter in the book.
  final int index;

  final Novel novel;

  final List<NovelBlock> blocks;
}

/// Loads the text of every chapter of the book [novel] belongs to: its whole
/// series, or just the novel if it isn't part of one.
class NovelBookText extends ChangeNotifier {
  NovelBookText(this.novel);

  final Novel novel;

  /// Contents of the novels loaded lately by id, oldest first, so a book
  /// isn't downloaded again every time it's searched.
  static final _contentCache = <int, String>{};

  static var _cachedLength = 0;

  static const _maxCachedLength = 8 * 1024 * 1024;

  /// How many chapters are downloaded at the same time.
  static const _parallels = 3;

  List<Novel>? _novels;

  final _chapters = <int, NovelBookChapter>{};

  final _failed = <int>{};

  bool _loading = false;

  bool _disposed = false;

  /// Why the list of chapters couldn't be loaded.
  String? error;

  bool get isLoading => _loading;

  bool get isStarted => _loading || _novels != null || error != null;

  /// The number of chapters, once known.
  int get total => _novels?.length ?? 0;

  int get loadedCount => _chapters.length;

  int get failedCount => _failed.length;

  bool get isComplete => _novels != null && _chapters.length == _novels!.length;

  /// The chapters loaded so far, in order.
  Iterable<NovelBookChapter> get chapters sync* {
    for (var i = 0; i < total; i++) {
      final chapter = _chapters[i];
      if (chapter != null) yield chapter;
    }
  }

  /// Loads the chapters that aren't loaded yet.
  Future<void> load() async {
    if (_loading || _disposed || isComplete) return;
    _loading = true;
    error = null;
    _failed.clear();
    notifyListeners();
    if (_novels == null) {
      final seriesId = novel.seriesId;
      if (seriesId == null) {
        _novels = [novel];
      } else {
        final res = await Network().getAllNovelSeries(seriesId.toString());
        if (_disposed) return;
        if (res.error) {
          error = res.errorMessageWithoutNull;
          _loading = false;
          notifyListeners();
          return;
        }
        _novels = res.data.isEmpty ? [novel] : res.data;
      }
    }
    final novels = _novels!;
    final pending = [
      for (var i = 0; i < novels.length; i++)
        if (!_chapters.containsKey(i)) i,
    ];
    var next = 0;
    Future<void> worker() async {
      while (next < pending.length && !_disposed) {
        final index = pending[next++];
        final content = await _loadContent(novels[index].id);
        if (_disposed) return;
        if (content == null) {
          _failed.add(index);
        } else {
          _chapters[index] = NovelBookChapter(
              index, novels[index], parseNovelContent(content));
        }
        notifyListeners();
      }
    }

    await Future.wait([for (var i = 0; i < _parallels; i++) worker()]);
    if (_disposed) return;
    _loading = false;
    notifyListeners();
  }

  static Future<String?> _loadContent(int id) async {
    final cached = _contentCache.remove(id);
    if (cached != null) {
      // Move it to the end, as the most recently used.
      _contentCache[id] = cached;
      return cached;
    }
    final res = await Network().getNovelContent(id.toString());
    if (res.error) return null;
    final content = res.data;
    _contentCache[id] = content;
    _cachedLength += content.length;
    while (_cachedLength > _maxCachedLength && _contentCache.length > 1) {
      _cachedLength -= _contentCache.remove(_contentCache.keys.first)!.length;
    }
    return content;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
