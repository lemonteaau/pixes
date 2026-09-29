import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';
import 'package:pixes/foundation/image_provider.dart';
import 'package:pixes/network/app_dio.dart';

import 'slideshow_controller.dart';

/// Loads original bytes through the shared disk cache and decodes off the UI
/// thread. Owns the decoded frame, so long slideshows don't fill the image cache.
class OriginalImageLoad implements SlideLoad<ui.Image> {
  OriginalImageLoad(String url) {
    ready = _load(url).timeout(const Duration(seconds: 30), onTimeout: () {
      dispose();
      throw TimeoutException('Original image timed out');
    });
  }

  final _cancelToken = CancelToken();
  ui.Image? _image;
  bool _disposed = false;

  @override
  late final Future<ui.Image> ready;

  Future<ui.Image> _load(String url) async {
    final chunks = StreamController<ImageChunkEvent>()..stream.listen((_) {});
    try {
      final bytes = await CachedImageProvider(url, cancelToken: _cancelToken)
          .load(chunks);
      if (_disposed) throw StateError('Image load cancelled');
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        final frame = await codec.getNextFrame();
        if (_disposed) {
          frame.image.dispose();
          throw StateError('Image load cancelled');
        }
        return _image = frame.image;
      } finally {
        codec.dispose();
      }
    } finally {
      await chunks.close();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelToken.cancel('Slideshow image released');
    final image = _image;
    _image = null;
    if (image != null) {
      // RawImage can still refer to this image until its next build.
      SchedulerBinding.instance.addPostFrameCallback((_) => image.dispose());
      SchedulerBinding.instance.ensureVisualUpdate();
    }
  }
}
