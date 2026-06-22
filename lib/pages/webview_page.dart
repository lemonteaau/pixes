import 'package:fluent_ui/fluent_ui.dart';
import 'package:window_manager/window_manager.dart';
import 'package:zikzak_inappwebview/zikzak_inappwebview.dart';
import 'package:pixes/components/md.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../foundation/app.dart';

double get _appBarHeight => App.isDesktop ? 36.0 : 48.0;

class WebviewPage extends StatefulWidget {
  const WebviewPage(this.url, {this.onNavigation, super.key});

  final String url;

  final bool Function(String url)? onNavigation;

  @override
  State<WebviewPage> createState() => _WebviewPageState();
}

class _WebviewPageState extends State<WebviewPage> {
  NavigationActionPolicy handleNavigation(NavigationAction action) {
    if (widget.onNavigation != null) {
      final url = action.request.url?.toString();
      return widget.onNavigation!(url ?? '')
          ? NavigationActionPolicy.ALLOW
          : NavigationActionPolicy.CANCEL;
    }
    return NavigationActionPolicy.ALLOW;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: _appBarHeight,
          child: Row(
            children: [
              if (App.isMacOS) const SizedBox(width: 64),
              if (App.isDesktop)
                const Expanded(
                  child: DragToMoveArea(
                    child: Text("Webview"),
                  ),
                )
              else
                const Expanded(
                  child: Text("Webview"),
                ),
              IconButton(
                icon: const Icon(
                  MdIcons.open_in_new,
                  size: 20,
                ),
                onPressed: () {
                  launchUrlString(widget.url);
                  context.pop();
                },
              ),
              IconButton(
                icon: const Icon(
                  MdIcons.close,
                  size: 20,
                ),
                onPressed: () {
                  context.pop();
                },
              ),
            ],
          ).paddingHorizontal(16),
        ).paddingTop(MediaQuery.of(context).padding.top),
        Expanded(
          child: InAppWebView(
            initialUrlRequest: URLRequest(url: WebUri(widget.url)),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              transparentBackground: false,
              useShouldOverrideUrlLoading: true,
            ),
            shouldOverrideUrlLoading: (controller, navigationAction) async {
              return handleNavigation(navigationAction);
            },
          ),
        ),
      ],
    );
  }
}
