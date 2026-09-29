import 'package:flutter/widgets.dart';

/// Tells a page kept alive by [LazyIndexedStack] whether it is on screen.
class PageVisibility extends InheritedWidget {
  const PageVisibility({
    super.key,
    required this.visible,
    required super.child,
  });

  final bool visible;

  /// Pages outside any [LazyIndexedStack], such as pushed routes, are visible.
  static bool of(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<PageVisibility>()
            ?.visible ??
        true;
  }

  @override
  bool updateShouldNotify(PageVisibility oldWidget) {
    return visible != oldWidget.visible;
  }
}

/// Shows the child for [current], building each child the first time it is
/// selected and keeping it alive afterwards, so switching back to it does not
/// reload its content or lose its scroll position.
class LazyIndexedStack<K extends Object> extends StatefulWidget {
  const LazyIndexedStack({
    super.key,
    required this.current,
    required this.builder,
  });

  final K current;

  final Widget Function(BuildContext context, K key) builder;

  @override
  State<LazyIndexedStack<K>> createState() => _LazyIndexedStackState<K>();
}

class _LazyIndexedStackState<K extends Object>
    extends State<LazyIndexedStack<K>> {
  final _keys = <K>[];

  final _scrollControllers = <K, ScrollController>{};

  @override
  void dispose() {
    for (final controller in _scrollControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_keys.contains(widget.current)) {
      _keys.add(widget.current);
    }
    final parentVisible = PageVisibility.of(context);
    return IndexedStack(
      index: _keys.indexOf(widget.current),
      sizing: StackFit.expand,
      children: [
        for (final key in _keys)
          PageVisibility(
            key: ValueKey(key),
            visible: parentVisible && key == widget.current,
            // A controller per child keeps hidden scroll views from sharing
            // the route's primary controller with the visible one.
            child: PrimaryScrollController(
              controller:
                  _scrollControllers.putIfAbsent(key, ScrollController.new),
              child: widget.builder(context, key),
            ),
          ),
      ],
    );
  }
}
