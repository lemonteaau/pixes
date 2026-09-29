import 'package:fluent_ui/fluent_ui.dart';
import 'package:pixes/components/page_route.dart';
import 'package:pixes/network/models.dart';
import 'package:pixes/pages/slideshow_page.dart';
import 'package:pixes/utils/translation.dart';

class SlideshowButton extends StatelessWidget {
  const SlideshowButton({
    super.key,
    required this.source,
    required this.illusts,
    required this.nextUrl,
  });

  final String source;
  final List<Illust> Function() illusts;
  final String? Function() nextUrl;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Slideshow'.tl,
      child: IconButton(
        icon: const Icon(FluentIcons.play, size: 18),
        onPressed: () {
          final initialIllusts = illusts();
          final continuation = nextUrl();
          Navigator.of(context, rootNavigator: true).push(AppPageRoute(
            builder: (_) => SlideshowPage(
              illusts: initialIllusts,
              nextUrl: continuation,
              source: source,
            ),
          ));
        },
      ),
    );
  }
}
