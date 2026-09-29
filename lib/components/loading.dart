import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' as material;
import 'package:pixes/foundation/app.dart';
import 'package:pixes/network/res.dart';
import 'package:pixes/utils/translation.dart';

Widget buildRefreshWrapper({
  Key? key,
  required Widget child,
  required Future<void> Function() onRefresh,
}) {
  return material.RefreshIndicator(
    key: key,
    onRefresh: onRefresh,
    child: child,
  );
}

abstract class LoadingState<T extends StatefulWidget, S extends Object> extends State<T>{
  bool isLoading = false;

  S? data;

  String? error;

  int _generation = 0;

  final _refreshIndicatorKey =
      GlobalKey<material.RefreshIndicatorState>();

  bool _refreshFromIndicator = false;

  Future<Res<S>> loadData();

  Widget buildContent(BuildContext context, S data);

  Widget? buildFrame(BuildContext context, Widget child) => null;

  Widget buildLoading() {
    return const Center(
      child: ProgressRing(),
    );
  }

  Future<void> _load({required bool keepData}) async {
    final generation = ++_generation;
    if (!keepData || data == null) {
      setState(() {
        isLoading = true;
        error = null;
        data = null;
      });
    }
    final value = await loadData();
    if (!mounted || generation != _generation) return;
    setState(() {
      isLoading = false;
      if (value.success) {
        data = value.data;
        error = null;
      } else {
        data = null;
        error = value.errorMessage!;
      }
    });
  }

  Future<void> retry() => _load(keepData: false);

  /// Reloads while keeping the current content on screen.
  Future<void> refresh() {
    final indicator = _refreshIndicatorKey.currentState;
    if (!_refreshFromIndicator && indicator != null && data != null) {
      // Let the indicator drive the reload so the user sees progress.
      return indicator.show();
    }
    _refreshFromIndicator = false;
    return _load(keepData: true);
  }

  Widget withRefresh(Widget child) {
    return buildRefreshWrapper(
      key: _refreshIndicatorKey,
      onRefresh: () {
        _refreshFromIndicator = true;
        return refresh();
      },
      child: KeyedSubtree(
        key: ValueKey(_generation),
        child: child,
      ),
    );
  }

  Widget buildError() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(error!),
          const SizedBox(height: 12),
          Button(
            onPressed: retry,
            child: Text("Retry".tl),
          )
        ],
      ),
    ).paddingHorizontal(16);
  }

  @override
  @mustCallSuper
  void initState() {
    super.initState();
    isLoading = true;
    _load(keepData: false);
  }

  @override
  Widget build(BuildContext context) {
    Widget child;

    if(isLoading){
      child = buildLoading();
    } else if (error != null){
      child = buildError();
    } else {
      child = buildContent(context, data!);
    }

    return buildFrame(context, child) ?? child;
  }
}

abstract class MultiPageLoadingState<T extends StatefulWidget, S extends Object> extends State<T>{
  bool _isFirstLoading = true;

  bool _isLoading = false;

  List<S>? _data;

  List<S> get loadedData => List.unmodifiable(_data ?? <S>[]);

  String? _error;

  int _page = 1;

  /// Bumped whenever the list restarts, so responses of older requests are dropped.
  int _generation = 0;

  bool _keepDataOnReset = false;

  bool _refreshFromIndicator = false;

  final _refreshIndicatorKey =
      GlobalKey<material.RefreshIndicatorState>();

  Future<Res<List<S>>> loadData(int page);

  Widget? buildFrame(BuildContext context, Widget child) => null;

  Widget buildContent(BuildContext context, List<S> data);

  bool get isLoading => _isLoading || _isFirstLoading;

  bool get isFirstLoading => _isFirstLoading;

  void nextPage() {
    if(_isLoading || _isFirstLoading || _data == null) return;
    _isLoading = true;
    final generation = _generation;
    loadData(_page).then((value) {
      if (!mounted || generation != _generation) return;
      _isLoading = false;
      if(value.success) {
        _page++;
        setState(() {
          _data!.addAll(value.data);
        });
      } else {
        var message = value.errorMessage ?? "Network Error";
        if(message == "No more data") {
          return;
        }
        if(message.length > 20) {
          message = "${message.substring(0, 20)}...";
        }
        context.showToast(message: message);
      }
    });
  }

  /// Restarts from the first page. Subclasses override this to clear their own
  /// paging state, so [refresh] goes through it as well.
  void reset() {
    final keepData = _keepDataOnReset && _data != null && _error == null;
    _generation++;
    setState(() {
      _isFirstLoading = !keepData;
      _isLoading = keepData;
      if (!keepData) {
        _data = null;
      }
      _error = null;
      _page = 1;
    });
    firstLoad();
  }

  Completer<void>? _refreshCompleter;

  /// Reloads the first page while keeping the current content on screen.
  Future<void> refresh() {
    final indicator = _refreshIndicatorKey.currentState;
    if (!_refreshFromIndicator &&
        indicator != null &&
        _data != null &&
        _error == null) {
      // Let the indicator drive the reload so the user sees progress; paging
      // state is already cleared, so hold off loading more until it starts.
      _isLoading = true;
      return indicator.show();
    }
    _refreshFromIndicator = false;
    _refreshCompleter?.complete();
    final completer = Completer<void>();
    _refreshCompleter = completer;
    _keepDataOnReset = true;
    try {
      reset();
    } finally {
      _keepDataOnReset = false;
    }
    return completer.future;
  }

  Widget withRefresh(Widget child) {
    return buildRefreshWrapper(
      key: _refreshIndicatorKey,
      onRefresh: () {
        _refreshFromIndicator = true;
        return refresh();
      },
      child: KeyedSubtree(
        key: ValueKey(_generation),
        child: child,
      ),
    );
  }

  void firstLoad() {
    final generation = _generation;
    loadData(_page).then((value) {
      if (!mounted || generation != _generation) return;
      if(value.success) {
        _page++;
        setState(() {
          _isFirstLoading = false;
          _isLoading = false;
          _data = value.data;
        });
      } else {
        setState(() {
          _isFirstLoading = false;
          _isLoading = false;
          _data = null;
          _error = value.errorMessage!;
        });
      }
      _refreshCompleter?.complete();
      _refreshCompleter = null;
    });
  }

  @override
  void initState() {
    super.initState();
    firstLoad();
  }

  @override
  void dispose() {
    _refreshCompleter?.complete();
    _refreshCompleter = null;
    super.dispose();
  }

  Widget buildLoading(BuildContext context) {
    return const Center(
      child: ProgressRing(),
    );
  }

  Widget buildError(BuildContext context, String error) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(error),
          const SizedBox(height: 12),
          Button(
            onPressed: () {
              reset();
            },
            child: Text("Retry".tl),
          )
        ],
      ),
    ).paddingHorizontal(16);
  }

  @override
  Widget build(BuildContext context) {
    Widget child;

    if(_isFirstLoading){
      child = buildLoading(context);
    } else if (_error != null){
      child = buildError(context, _error!);
    } else {
      child = buildContent(context, _data!);
    }

    return buildFrame(context, child) ?? child;
  }
}
