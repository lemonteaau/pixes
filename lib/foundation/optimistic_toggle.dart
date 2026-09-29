import 'dart:async';

import 'package:pixes/components/message.dart';
import 'package:pixes/foundation/app.dart';
import 'package:pixes/network/network.dart';
import 'package:pixes/utils/translation.dart';

typedef ToggleSender = Future<bool> Function(bool value);

/// A yes/no state such as a bookmark or a follow that the UI changes at once
/// while the server catches up in the background.
///
/// Rapid toggles collapse into only the requests needed to reach the final
/// value. When one fails, the value goes back to what the server has and a
/// toast says so. Every change is broadcast on [changes], so all widgets that
/// show the same item stay in sync.
class OptimisticToggle {
  OptimisticToggle(this._failureMessage);

  final String Function(bool value) _failureMessage;

  final _server = <Object, bool>{};
  final _desired = <Object, bool>{};
  final _senders = <Object, ToggleSender>{};
  final _failureHandlers = <Object, void Function(String message)?>{};
  final _running = <Object>{};
  final _changes = StreamController<(Object, bool)>.broadcast(sync: true);

  /// Emits `(key, value)` whenever the shown value of [key] changes.
  Stream<(Object, bool)> get changes => _changes.stream;

  /// Shows [to] immediately and sends it with [send], which reports success.
  /// [from] is the value the UI showed before, assumed to match the server
  /// when nothing is in flight for [key]. A failure is reported through
  /// [onFailure] when given, otherwise as a toast.
  void set(
    Object key, {
    required bool from,
    required bool to,
    required ToggleSender send,
    void Function(String message)? onFailure,
  }) {
    if (from == to && !_desired.containsKey(key)) return;
    _server.putIfAbsent(key, () => from);
    _desired[key] = to;
    _senders[key] = send;
    _failureHandlers[key] = onFailure;
    _changes.add((key, to));
    unawaited(_sync(key));
  }

  Future<void> _sync(Object key) async {
    if (!_running.add(key)) return;
    try {
      while (_desired[key] != _server[key]) {
        final value = _desired[key]!;
        bool ok;
        try {
          ok = await _senders[key]!(value);
        } catch (_) {
          ok = false;
        }
        if (ok) {
          _server[key] = value;
          continue;
        }
        final actual = _server[key]!;
        _desired[key] = actual;
        _changes.add((key, actual));
        final message = _failureMessage(value);
        final onFailure = _failureHandlers[key];
        final context = App.rootNavigatorKey.currentContext;
        if (onFailure != null) {
          onFailure(message);
        } else if (context != null && context.mounted) {
          showToast(context, message: message);
        }
        break;
      }
    } finally {
      _running.remove(key);
      _server.remove(key);
      _desired.remove(key);
      _senders.remove(key);
      _failureHandlers.remove(key);
    }
  }
}

final illustBookmarks = OptimisticToggle(
    (value) => (value ? "Bookmark failed" : "Failed to remove bookmark").tl);

final novelBookmarks = OptimisticToggle(
    (value) => (value ? "Bookmark failed" : "Failed to remove bookmark").tl);

final userFollows = OptimisticToggle(
    (value) => (value ? "Follow failed" : "Unfollow failed").tl);

/// Bookmarks or unbookmarks [illust] at once; the request runs in background.
void setIllustBookmarked(
  Illust illust,
  bool value, {
  String restrict = "public",
  Future<Res<bool>> Function(Illust illust, bool value)? send,
  void Function(String message)? onFailure,
}) {
  final from = illust.isBookmarked;
  illust.isBookmarked = value;
  illustBookmarks.set(
    illust.id,
    from: from,
    to: value,
    onFailure: onFailure,
    send: (value) async {
      final res = send != null
          ? await send(illust, value)
          : await Network().addBookmark(
              illust.id.toString(), value ? "add" : "delete", restrict);
      return res.success;
    },
  );
}

void setNovelBookmarked(Novel novel, bool value, {bool public = true}) {
  final from = novel.isBookmarked;
  novel.isBookmarked = value;
  novelBookmarks.set(novel.id, from: from, to: value, send: (value) async {
    final res = value
        ? await Network().favoriteNovel(novel.id.toString(), public)
        : await Network().deleteFavoriteNovel(novel.id.toString());
    return res.success;
  });
}

void setAuthorFollowed(Author author, bool value,
    {void Function(String message)? onFailure}) {
  final from = author.isFollowed;
  author.isFollowed = value;
  userFollows.set(author.id, from: from, to: value, onFailure: onFailure,
      send: (value) async {
    final res =
        await Network().follow(author.id.toString(), value ? "add" : "delete");
    return res.success;
  });
}
