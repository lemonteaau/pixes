import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pixes/appdata.dart';
import 'package:pixes/components/message.dart';
import 'package:pixes/foundation/app.dart';
import 'package:pixes/foundation/fork_build.dart';
import 'package:pixes/foundation/log.dart';
import 'package:pixes/utils/translation.dart';
import 'package:url_launcher/url_launcher_string.dart';

const _apkInstaller = MethodChannel('pixes/apk_installer');

const _releasesUrl = 'https://github.com/${ForkBuild.repository}/releases';

/// A fork release is newer when it was built from a different commit: every
/// build of this fork is published, so the latest one is always the target.
Future<Map<String, dynamic>?> _latestRelease() async {
  final res = await Dio().get<Map<String, dynamic>>(
    'https://api.github.com/repos/${ForkBuild.repository}/releases/latest',
    options: Options(headers: {'Accept': 'application/vnd.github+json'}),
  );
  return res.data;
}

/// Checks the fork's releases; [manual] reports "up to date" and errors.
Future<void> checkUpdate({bool manual = false}) async {
  if (!manual &&
      (appdata.account == null || appdata.settings['checkUpdate'] == false)) {
    return;
  }
  if (!ForkBuild.isRelease) {
    if (manual) _toast('This build was not published by the fork'.tl);
    return;
  }
  try {
    final release = await _latestRelease();
    final commit = release?['target_commitish'];
    if (release == null || commit is! String || commit.isEmpty) {
      if (manual) _toast('Failed to check for updates'.tl);
      return;
    }
    if (commit == ForkBuild.commit) {
      if (manual) _toast('Already up to date'.tl);
      return;
    }
    _showUpdateDialog(release, manual: manual);
  } catch (e) {
    Log.error('Update', 'Failed to check for updates: $e');
    if (manual) _toast('Failed to check for updates'.tl);
  }
}

void _toast(String message) {
  final context = App.rootNavigatorKey.currentContext;
  if (context != null && context.mounted) {
    showToast(context, message: message);
  }
}

void _showUpdateDialog(Map<String, dynamic> release, {required bool manual}) {
  final context = App.rootNavigatorKey.currentContext;
  if (context == null || !context.mounted) return;
  final name = (release['name'] as String?)?.isNotEmpty == true
      ? release['name'] as String
      : '${release['tag_name']}';
  showDialog(
    context: context,
    builder: (context) => ContentDialog(
      title: Text('New version available'.tl),
      constraints: const BoxConstraints(maxWidth: 480),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name, style: const TextStyle(fontSize: 18)),
          if (ForkBuild.version.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('${'Current version'.tl}: ${ForkBuild.version}'),
          ],
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: SingleChildScrollView(
              child: SelectableText('${release['body'] ?? ''}'),
            ),
          ),
        ],
      ),
      actions: [
        if (!manual)
          Button(
            child: Text('Do not remind'.tl),
            onPressed: () {
              appdata.settings['checkUpdate'] = false;
              appdata.writeSettings();
              Navigator.of(context).pop();
            },
          ),
        Button(
          child: Text('Cancel'.tl),
          onPressed: () => Navigator.of(context).pop(),
        ),
        FilledButton(
          child: Text('Update'.tl),
          onPressed: () {
            Navigator.of(context).pop();
            _update(release);
          },
        ),
      ],
    ),
  );
}

Future<void> _update(Map<String, dynamic> release) async {
  final releaseUrl = release['html_url'] as String? ?? '$_releasesUrl/latest';
  if (!App.isAndroid) {
    await launchUrlString(releaseUrl, mode: LaunchMode.externalApplication);
    return;
  }
  final assets = (release['assets'] as List? ?? const [])
      .cast<Map<String, dynamic>>()
      .where((asset) => (asset['name'] as String).endsWith('.apk'))
      .toList();
  final abis = (await DeviceInfoPlugin().androidInfo).supportedAbis;
  Map<String, dynamic>? asset;
  for (final abi in abis) {
    asset = assets
        .where((a) => (a['name'] as String).endsWith('-$abi.apk'))
        .firstOrNull;
    if (asset != null) break;
  }
  // The universal APK carries no ABI suffix.
  asset ??= assets
      .where((a) => !RegExp(r'-(arm64-v8a|armeabi-v7a|x86_64)\.apk$')
          .hasMatch(a['name'] as String))
      .firstOrNull;
  if (asset == null) {
    await launchUrlString(releaseUrl, mode: LaunchMode.externalApplication);
    return;
  }
  await _downloadAndInstall(asset['browser_download_url'] as String);
}

/// Downloads into the app cache, which the installer reads through a
/// FileProvider; the native side deletes the APK once the update is in.
Future<void> _downloadAndInstall(String url) async {
  final context = App.rootNavigatorKey.currentContext;
  if (context == null || !context.mounted) return;
  final directory =
      Directory('${(await getTemporaryDirectory()).path}/apk_updates');
  if (await directory.exists()) await directory.delete(recursive: true);
  await directory.create(recursive: true);
  final file = File('${directory.path}/update.apk');
  final progress = ValueNotifier<double?>(null);
  final cancel = CancelToken();
  if (!context.mounted) return;
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => ContentDialog(
      title: Text('Downloading update'.tl),
      content: ValueListenableBuilder<double?>(
        valueListenable: progress,
        builder: (context, value, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: double.infinity,
              child: ProgressBar(value: value == null ? null : value * 100),
            ),
            const SizedBox(height: 8),
            Text(value == null ? '' : '${(value * 100).toStringAsFixed(0)}%'),
          ],
        ),
      ),
      actions: [
        Button(
          child: Text('Cancel'.tl),
          onPressed: () {
            cancel.cancel();
            Navigator.of(context).pop();
          },
        ),
      ],
    ),
  );
  try {
    await Dio().download(
      url,
      file.path,
      cancelToken: cancel,
      deleteOnError: true,
      onReceiveProgress: (received, total) {
        if (total > 0) progress.value = received / total;
      },
    );
    if (App.rootNavigatorKey.currentState?.canPop() == true) {
      App.rootNavigatorKey.currentState!.pop();
    }
    await _apkInstaller.invokeMethod<void>('installApk', {'path': file.path});
  } catch (e) {
    if (await file.exists()) await file.delete();
    if (cancel.isCancelled) return;
    if (App.rootNavigatorKey.currentState?.canPop() == true) {
      App.rootNavigatorKey.currentState!.pop();
    }
    Log.error('Update', 'Failed to download or install the update: $e');
    _toast('Update failed'.tl);
  } finally {
    progress.dispose();
  }
}
