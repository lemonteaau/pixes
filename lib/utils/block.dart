import 'package:pixes/appdata.dart';
import 'package:pixes/network/models.dart';

bool get _blockAiWorks => appdata.settings["blockAiWorks"] == true;

List<Illust> checkIllusts(List<Illust> illusts) {
  illusts.removeWhere((illust) {
    if (illust.isBlocked || !illust.isAvailable) {
      return true;
    }
    if (_blockAiWorks && illust.isAi) {
      return true;
    }
    if (appdata.settings["blockTags"] == null) {
      return false;
    }
    if (appdata.settings["blockTags"].contains("user:${illust.author.id}")) {
      return true;
    }
    for (var tag in illust.tags) {
      if ((appdata.settings["blockTags"] as List).contains(tag.name)) {
        return true;
      }
    }
    return false;
  });
  return illusts;
}

List<Novel> checkNovels(List<Novel> novels) {
  if (_blockAiWorks) {
    novels.removeWhere((novel) => novel.isAi);
  }
  return novels;
}
