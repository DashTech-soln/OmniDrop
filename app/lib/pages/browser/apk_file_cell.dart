import 'package:flutter/material.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/model/persistence/browser_surface_style.dart';
import 'package:localsend_app/pages/browser/browser_strings.dart';
import 'package:localsend_app/pages/browser/browser_surface.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' as android_channel;

String? apkInstallActionLabel(android_channel.ApkInstallState? state) => switch (state) {
  android_channel.ApkInstallState.notInstalled => BrowserStrings.install,
  android_channel.ApkInstallState.update => BrowserStrings.update,
  android_channel.ApkInstallState.installed || null => null,
};

bool shouldRequestInstallPermission(android_channel.AndroidStorageException error) =>
    error.code == android_channel.AndroidStorageErrorCode.installNotAllowed;

class ApkFileCell extends StatelessWidget {
  final android_channel.ApkFile file;
  final Future<android_channel.ApkInfo?> info;
  final bool selected;
  final BrowserSurfaceStyle? surfaceStyle;
  final VoidCallback onSelect;
  final ValueChanged<String> onInstall;

  const ApkFileCell({
    required this.file,
    required this.info,
    required this.selected,
    this.surfaceStyle,
    required this.onSelect,
    required this.onInstall,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = BrowserThemeTokens.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(glassRadiusSmall),
      onTap: onSelect,
      child: BrowserSurface(
        style: surfaceStyle,
        padding: EdgeInsets.zero,
        borderRadius: BorderRadius.circular(glassRadiusSmall),
        color: selected ? tokens.selection : null,
        child: FutureBuilder<android_channel.ApkInfo?>(
          future: info,
          builder: (context, snapshot) {
            final apkInfo = snapshot.data;
            final label = apkInfo?.label.trim();
            final displayName = label == null || label.isEmpty ? file.name : label;
            final icon = apkInfo?.icon;
            final state = apkInfo?.state;
            return Stack(
              children: [
                Column(
                  children: [
                    SizedBox(
                      height: 58,
                      child: Center(
                        child: SizedBox.square(
                          dimension: 48,
                          child: icon == null || icon.isEmpty
                              ? Icon(Icons.android, size: 42, color: tokens.icon)
                              : Image.memory(icon, fit: BoxFit.contain, cacheWidth: 144, cacheHeight: 144),
                        ),
                      ),
                    ),
                    SizedBox(
                      height: 13,
                      width: double.infinity,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(displayName, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
                      ),
                    ),
                    SizedBox(
                      height: 14,
                      child: switch (state) {
                        android_channel.ApkInstallState.installed => Text(
                          BrowserStrings.installed,
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: tokens.textSecondary),
                        ),
                        android_channel.ApkInstallState.notInstalled || android_channel.ApkInstallState.update => TextButton(
                          onPressed: () => onInstall(file.path),
                          style: TextButton.styleFrom(
                            foregroundColor: tokens.primary,
                            backgroundColor: tokens.primary.withValues(alpha: 0.12),
                            shape: const StadiumBorder(),
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: Text(apkInstallActionLabel(state)!, style: Theme.of(context).textTheme.labelSmall),
                        ),
                        null => const SizedBox.shrink(),
                      },
                    ),
                  ],
                ),
                if (selected) Positioned(top: 1, right: 1, child: Icon(Icons.check_circle, size: 18, color: tokens.primary)),
              ],
            );
          },
        ),
      ),
    );
  }
}
