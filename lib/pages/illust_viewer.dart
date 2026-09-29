import 'package:fluent_ui/fluent_ui.dart';
import 'package:pixes/appdata.dart';
import 'package:pixes/components/loading.dart';
import 'package:pixes/components/page_route.dart';
import 'package:pixes/foundation/app.dart';
import 'package:pixes/network/network.dart';
import 'package:pixes/pages/illust_page.dart';
import 'package:pixes/pages/main_page.dart';
import 'package:pixes/pages/slideshow_page.dart';
import 'package:pixes/utils/block.dart';
import 'package:pixes/utils/translation.dart';
import 'package:window_manager/window_manager.dart';

/// Whether artworks open in the classic detail pages instead of the
/// full-screen player.
bool get useLegacyIllustViewer =>
    appdata.settings["useLegacyIllustViewer"] == true;

/// Whether the full-screen player can show [illust]. Blocked works and works
/// pixiv doesn't serve the images of fall back to the detail page, which
/// explains why they can't be shown.
bool canPlayIllust(Illust illust) => checkIllusts([illust]).isNotEmpty;

/// Opens the artwork at [index] of a feed, letting the viewer continue
/// through the rest of it and, with [nextUrl], the pages after it.
void openIllustFeed(
  BuildContext context, {
  required List<Illust> illusts,
  required int index,
  String? nextUrl,
  required String source,
}) {
  final illust = illusts[index];
  if (useLegacyIllustViewer) {
    context.to(() => IllustGalleryPage(
        illusts: illusts, initialPage: index, nextUrl: nextUrl));
    return;
  }
  if (!canPlayIllust(illust)) {
    context.to(() => IllustPage(illust));
    return;
  }
  Navigator.of(context, rootNavigator: true).push(AppPageRoute(
    builder: (_) => SlideshowPage(
      illusts: List.of(illusts),
      nextUrl: nextUrl,
      source: source,
      initialIllustId: illust.id,
      autoPlay: false,
    ),
  ));
}

/// Opens a single artwork.
void openIllust(BuildContext context, Illust illust, {String source = ""}) {
  if (useLegacyIllustViewer) {
    context.to(() => IllustPage(illust));
    return;
  }
  openIllustFeed(context, illusts: [illust], index: 0, source: source);
}

/// Opens the artwork with [id], loading it first.
void openIllustById(BuildContext context, String id) {
  if (useLegacyIllustViewer) {
    context.to(() => IllustPageWithId(id));
    return;
  }
  Navigator.of(context, rootNavigator: true)
      .push(AppPageRoute(builder: (_) => IllustViewerWithId(id)));
}

/// Loads an artwork, then shows it in the full-screen player.
class IllustViewerWithId extends StatefulWidget {
  const IllustViewerWithId(this.id, {super.key});

  final String id;

  @override
  State<IllustViewerWithId> createState() => _IllustViewerWithIdState();
}

class _IllustViewerWithIdState extends LoadingState<IllustViewerWithId, Illust> {
  @override
  Future<Res<Illust>> loadData() => Network().getIllustByID(widget.id);

  @override
  Widget buildContent(BuildContext context, Illust data) {
    if (!canPlayIllust(data)) {
      return ViewerSubpageFrame(child: IllustPage(data));
    }
    return SlideshowPage(
      illusts: [data],
      nextUrl: null,
      source: "",
      autoPlay: false,
    );
  }

  @override
  Widget? buildFrame(BuildContext context, Widget child) {
    if (!isLoading && error == null) return null;
    // Loading and errors are shown on the player's black background.
    return FluentTheme(
      data: FluentThemeData(brightness: Brightness.dark),
      child: ColoredBox(
        color: Colors.black,
        child: DefaultTextStyle(
          style: const TextStyle(color: Colors.white, fontSize: 14),
          child: Stack(children: [
            Positioned.fill(child: child),
            Positioned(
              top: 0,
              left: 0,
              child: SafeArea(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(App.isMacOS ? 80 : 4, 4, 4, 4),
                  child: Tooltip(
                    message: "Back".tl,
                    child: IconButton(
                      icon: const Icon(FluentIcons.back, size: 18),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Hosts pages opened from the full-screen player. The player covers the
/// app's own title bar, so this gives them a back button and a navigator of
/// their own, which keeps the pages they open in here as well.
class ViewerSubpageFrame extends StatefulWidget {
  const ViewerSubpageFrame({required this.child, super.key});

  final Widget child;

  @override
  State<ViewerSubpageFrame> createState() => _ViewerSubpageFrameState();
}

class _ViewerSubpageFrameState extends State<ViewerSubpageFrame> {
  final _navigator = GlobalKey<NavigatorState>();

  void _back() {
    final navigator = _navigator.currentState;
    if (navigator != null && navigator.canPop()) {
      navigator.pop();
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return NavigatorPopHandler(
      onPopWithResult: (_) => _navigator.currentState?.maybePop(),
      child: ColoredBox(
        color: theme.micaBackgroundColor,
        child: Column(
          children: [
            SafeArea(
              bottom: false,
              child: SizedBox(
                height: App.isDesktop ? 36 : 48,
                child: Row(
                  children: [
                    if (App.isMacOS) const SizedBox(width: 72),
                    Tooltip(
                      message: "Back".tl,
                      child: IconButton(
                        key: const ValueKey("viewer-subpage-back"),
                        icon: const Icon(FluentIcons.back, size: 16),
                        onPressed: _back,
                      ),
                    ).paddingHorizontal(4),
                    Expanded(
                      child: App.isDesktop
                          ? const DragToMoveArea(child: SizedBox.expand())
                          : const SizedBox.expand(),
                    ),
                    if (App.isDesktop && !App.isMacOS) const WindowButtons(),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Navigator(
                key: _navigator,
                onGenerateInitialRoutes: (_, __) => [
                  AppPageRoute(builder: (_) => widget.child, isRoot: true),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
