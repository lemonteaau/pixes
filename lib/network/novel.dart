part of "network.dart";

/// Image URLs from the novel pages loaded so far, by `novelId/imageId`.
final _novelImageUrls = <String, String>{};

/// Illustration URLs from the novel pages loaded so far, by
/// `novelId/illustId` or `novelId/illustId-page`.
final _novelIllustUrls = <String, String>{};

extension NovelExt on Network {
  Future<Res<List<Novel>>> getRecommendNovels() {
    return getNovelsWithNextUrl("/v1/novel/recommended");
  }

  Future<Res<List<Novel>>> getNovelsWithNextUrl(String nextUrl) async {
    var res = await apiGet(nextUrl);
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    return Res(
        (res.data["novels"] as List).map((e) => Novel.fromJson(e)).toList(),
        subData: res.data["next_url"]);
  }

  Future<Res<List<Novel>>> searchNovels(String keyword, SearchOptions options) {
    final aiType = _searchAiType(options);
    var url = "/v1/search/novel?"
        "include_translated_tag_results=true&"
        "merge_plain_keyword_results=true&"
        "word=${Uri.encodeComponent(keyword)}&"
        "sort=${options.sort.toParam()}&"
        "search_target=${options.matchType.toParam()}&"
        "search_ai_type=$aiType";
    return getNovelsWithNextUrl(url);
  }

  /// mode: day, day_male, day_female, week_rookie, week, week_ai
  Future<Res<List<Novel>>> getNovelRanking(String mode, DateTime? date) {
    var url = "/v1/novel/ranking?mode=$mode";
    if (date != null) {
      url += "&date=${date.year}-${date.month}-${date.day}";
    }
    return getNovelsWithNextUrl(url);
  }

  Future<Res<List<Novel>>> getBookmarkedNovels(String uid, bool public) {
    return getNovelsWithNextUrl(
        "/v1/user/bookmarks/novel?user_id=$uid&restrict=${public ? "public" : "private"}");
  }

  Future<Res<bool>> favoriteNovel(String id, bool public) async {
    var res = await apiPost("/v2/novel/bookmark/add", data: {
      "novel_id": id,
      "restrict": public ? "public" : "private",
    });
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    return const Res(true);
  }

  Future<Res<bool>> deleteFavoriteNovel(String id) async {
    var res = await apiPost("/v1/novel/bookmark/delete", data: {
      "novel_id": id,
    });
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    return const Res(true);
  }

  Future<Res<String>> getNovelContent(String id) async {
    var res = await apiGetPlain(
        "/webview/v2/novel?id=$id&font=default&font_size=16.0px&line_height=1.75&color=%23101010&background_color=%23EFEFEF&margin_top=56px&margin_bottom=48px&theme=light&use_block=true&viewer_version=20221031_ai");
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    try {
      var html = res.data;
      int start = html.indexOf("novel:");
      while (html[start] != '{') {
        start++;
      }
      int leftCount = 0;
      int end = start;
      for (end = start; end < html.length; end++) {
        if (html[end] == '{') {
          leftCount++;
        } else if (html[end] == '}') {
          leftCount--;
        }
        if (leftCount == 0) {
          end++;
          break;
        }
      }
      var json = jsonDecode(html.substring(start, end));
      _rememberNovelImages(id, json);
      return Res(json['text']);
    } catch (e, s) {
      Log.error(
          "Data Convert", "Failed to analyze html novel content: \n$e\n$s");
      return Res.error(e);
    }
  }

  /// Remembers the image URLs the novel page comes with. `images` holds the
  /// `[uploadedimage:id]` images by id, `illusts` the `[pixivimage:...]`
  /// illustrations by what is inside the tag. Both are `[]` when empty.
  void _rememberNovelImages(String novelId, dynamic json) {
    final images = json['images'];
    if (images is Map) {
      for (final entry in images.entries) {
        final urls = entry.value is Map ? entry.value['urls'] : null;
        if (urls is! Map) continue;
        final url = urls['original'] ?? urls['1200x1200'] ?? urls['480mw'];
        if (url is String && url.isNotEmpty) {
          _novelImageUrls["$novelId/${entry.key}"] = url;
        }
      }
    }
    final illusts = json['illusts'];
    if (illusts is Map) {
      for (final entry in illusts.entries) {
        final illust = entry.value is Map ? entry.value['illust'] : null;
        final urls = illust is Map ? illust['images'] : null;
        if (urls is! Map) continue;
        final url = urls['original'] ?? urls['medium'] ?? urls['small'];
        if (url is String && url.isNotEmpty) {
          _novelIllustUrls["$novelId/${entry.key}"] = url;
        }
      }
    }
  }

  /// The URL of `[pixivimage:illustId]` or `[pixivimage:illustId-page]`
  /// in the novel, if its page had one. [page] is zero based.
  String? novelIllustUrl(String novelId, String illustId, int page) {
    return _novelIllustUrls["$novelId/$illustId-${page + 1}"] ??
        (page == 0 ? _novelIllustUrls["$novelId/$illustId"] : null);
  }

  Future<Res<List<Novel>>> relatedNovels(String id) async {
    var res = await apiPost("/v1/novel/related", data: {
      "novel_id": id,
    });
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    return Res(
        (res.data["novels"] as List).map((e) => Novel.fromJson(e)).toList());
  }

  Future<Res<List<Novel>>> getUserNovels(String uid) {
    return getNovelsWithNextUrl("/v1/user/novels?user_id=$uid");
  }

  Future<Res<List<Novel>>> getNovelSeries(String id, [String? nextUrl]) async {
    var res = await apiGet(nextUrl ?? "/v2/novel/series?series_id=$id");
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    return Res(
        (res.data["novels"] as List).map((e) => Novel.fromJson(e)).toList(),
        subData: res.data["next_url"]);
  }

  /// Every chapter of the series [id], in reading order. If a later page
  /// fails, the chapters loaded until then are returned.
  Future<Res<List<Novel>>> getAllNovelSeries(String id) async {
    final all = <Novel>[];
    String? nextUrl;
    // The cap guards against an unexpected pagination loop.
    for (var i = 0; i < 50; i++) {
      final res = await getNovelSeries(id, nextUrl);
      if (res.error) {
        if (all.isEmpty) return res;
        break;
      }
      all.addAll(res.data);
      nextUrl = res.subData;
      if (nextUrl == null || nextUrl.isEmpty) break;
    }
    return Res(all);
  }

  Future<Res<List<Comment>>> getNovelComments(String id,
      [String? nextUrl]) async {
    var res = await apiGet(nextUrl ?? "/v1/novel/comments?novel_id=$id");
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    return Res(
        (res.data["comments"] as List).map((e) => Comment.fromJson(e)).toList(),
        subData: res.data["next_url"]);
  }

  Future<Res<bool>> commentNovel(String id, String content) async {
    var res = await apiPost("/v1/novel/comment/add", data: {
      "novel_id": id,
      "content": content,
    });
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    return const Res(true);
  }

  Future<Res<Novel>> getNovelDetail(String id) async {
    var res = await apiGet("/v2/novel/detail?novel_id=$id");
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    return Res(Novel.fromJson(res.data["novel"]));
  }

  Future<Res<List<Novel>>> getFollowingNovels(String restrict,
      [String? nextUrl]) async {
    var res = await apiGet(nextUrl ?? "/v1/novel/follow?restrict=$restrict");
    if (res.success) {
      return Res(
        (res.data["novels"] as List).map((e) => Novel.fromJson(e)).toList(),
        subData: res.data["next_url"],
      );
    } else {
      return Res.error(res.errorMessage);
    }
  }
}
