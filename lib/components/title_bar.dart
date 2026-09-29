import 'package:fluent_ui/fluent_ui.dart';
import 'package:pixes/foundation/app.dart';
import 'package:pixes/utils/translation.dart';

class TitleBar extends StatelessWidget {
  const TitleBar(
      {required this.title,
      this.action,
      this.onRefresh,
      this.wrapActions = false,
      super.key});

  final String title;

  final Widget? action;

  final VoidCallback? onRefresh;

  final bool wrapActions;

  @override
  Widget build(BuildContext context) {
    if (wrapActions) {
      return LayoutBuilder(builder: (context, constraints) {
        if (constraints.maxWidth < 600) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TitleBar(title: title, onRefresh: onRefresh),
              if (action != null)
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: action!,
                ),
            ],
          );
        }
        return TitleBar(title: title, action: action, onRefresh: onRefresh);
      });
    }
    return SizedBox(
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                ),
                if (onRefresh != null) ...[
                  const SizedBox(width: 4),
                  _RefreshButton(onRefresh!),
                ],
              ],
            ),
          ),
          if (action != null) ...[
            const SizedBox(width: 8),
            action!,
          ],
        ],
      ).paddingHorizontal(16).paddingVertical(8),
    );
  }
}

class SliverTitleBar extends StatelessWidget {
  const SliverTitleBar(
      {required this.title, this.action, this.onRefresh, super.key});

  final String title;

  final Widget? action;

  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: TitleBar(title: title, action: action, onRefresh: onRefresh),
    );
  }
}

class _RefreshButton extends StatelessWidget {
  const _RefreshButton(this.onRefresh);

  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: "Refresh".tl,
      child: IconButton(
        icon: const Icon(FluentIcons.refresh, size: 16),
        onPressed: onRefresh,
      ),
    );
  }
}
