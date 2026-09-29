import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixes/foundation/app.dart';
import 'package:pixes/foundation/cache_manager.dart';
import 'package:pixes/foundation/slideshow/original_image_load.dart';

void main() {
  testWidgets(
      'original cache bytes decode at full resolution and render safely',
      (tester) async {
    late Directory directory;
    const url = 'https://i.pximg.net/original/cache-test.png';
    late OriginalImageLoad load;
    late ui.Image decoded;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('pixes-slideshow-');
      App.dataPath = directory.path;
      App.cachePath = directory.path;
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawRect(const ui.Rect.fromLTWH(0, 0, 128, 256),
          ui.Paint()..color = const ui.Color(0xff123456));
      final picture = recorder.endRecording();
      final source = await picture.toImage(128, 256);
      final png = await source.toByteData(format: ui.ImageByteFormat.png);
      await CacheManager().writeCache(url, png!.buffer.asUint8List());
      source.dispose();
      picture.dispose();
      load = OriginalImageLoad(url);
      decoded = await load.ready;
    });
    expect(decoded.width, 128);
    expect(decoded.height, 256);
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: RawImage(image: decoded, fit: BoxFit.contain),
    ));
    expect(tester.takeException(), isNull);
    load.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
    await tester.runAsync(() => directory.delete(recursive: true));
  });
}
