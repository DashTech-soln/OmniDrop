import 'package:flutter/material.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/pages/browser/browser_strings.dart';
import 'package:localsend_app/pages/web_share_page.dart';
import 'package:localsend_app/pages/receive_history_page.dart';
import 'package:localsend_app/widget/animated_press.dart';
import 'package:localsend_app/widget/dialogs/receive_pairing_dialog.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/receive_history_provider.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/native/file_picker.dart';
import 'package:localsend_app/widget/dialogs/add_file_dialog.dart';
import 'package:localsend_app/widget/glass/glass_card.dart';
import 'package:localsend_isolates/util/file_size_helper.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

class WebDropTab extends StatelessWidget {
  const WebDropTab({super.key});

  @override
  Widget build(BuildContext context) {
    final files = context.watch(selectedSendingFilesProvider);
    final ref = context.ref;
    final colors = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 76),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                GlassCard(
                  margin: EdgeInsets.zero,
                  padding: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: double.infinity,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Column(
                                children: [
                                  Text('Staged Files', style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
                                  const SizedBox(height: 3),
                                  Text(
                                    'Files shared with connected browsers',
                                    style: Theme.of(context).textTheme.bodySmall,
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                              ),
                              Positioned(
                                left: 0,
                                top: 0,
                                child: Container(
                                  constraints: const BoxConstraints(minWidth: 38, minHeight: 38),
                                  alignment: Alignment.center,
                                  padding: const EdgeInsets.symmetric(horizontal: 8),
                                  decoration: BoxDecoration(
                                    color: colors.primary.withValues(alpha: 0.14),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text('${files.length}', style: Theme.of(context).textTheme.labelLarge?.copyWith(color: colors.primary)),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (files.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 24),
                            child: Center(
                              child: Text('No files staged. WebDrop can still receive files from a browser.', textAlign: TextAlign.center),
                            ),
                          )
                        else ...[
                          const SizedBox(height: 12),
                          ...files.map(
                            (file) => Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Column(
                                children: [
                                  const Icon(Icons.insert_drive_file_outlined),
                                  const SizedBox(height: 4),
                                  Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
                                  Text(file.size.asReadableFileSize, textAlign: TextAlign.center),
                                ],
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: SizedBox(
                                height: 48,
                                child: FilledButton.icon(
                                  onPressed: () async {
                                    final options = FilePickerOption.getOptionsForPlatform();
                                    if (options.length == 1) {
                                      await ref.global.dispatchAsync(PickFileAction(option: options.first, context: context));
                                    } else {
                                      await AddFileDialog.open(context: context, options: options);
                                    }
                                  },
                                  icon: const Icon(Icons.add),
                                  label: const FittedBox(fit: BoxFit.scaleDown, child: Text('Add Files')),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: SizedBox(
                                height: 48,
                                child: OutlinedButton.icon(
                                  onPressed: files.isEmpty ? null : () => ref.redux(selectedSendingFilesProvider).dispatch(ClearSelectionAction()),
                                  icon: const Icon(Icons.delete_outline),
                                  label: const FittedBox(fit: BoxFit.scaleDown, child: Text('Clear staged files')),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          bottom: 10,
          left: 0,
          right: 0,
          child: Center(
            child: AnimatedPress(
              child: FilledButton.icon(
                onPressed: () async => await context.push(() => WebSharePage(files: files)),
                icon: const Icon(Icons.language),
                label: const Text('Start WebDrop'),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

enum _Platform {
  android('Android', Icons.android),
  ios('iOS', Icons.phone_iphone),
  macos('macOS', Icons.laptop_mac),
  windows('Windows', Icons.desktop_windows),
  linux('Linux', Icons.computer)
  ;

  const _Platform(this.label, this.icon);

  final String label;
  final IconData icon;
}

class OsPairsTab extends StatelessWidget {
  const OsPairsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final pairs = [
      for (var left = 0; left < _Platform.values.length; left++)
        for (var right = left + 1; right < _Platform.values.length; right++) (_Platform.values[left], _Platform.values[right]),
    ];
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        GlassCard(
          margin: EdgeInsets.zero,
          padding: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Cross-Platform Pairing Hub', style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 6),
                      const Text('Choose a device pair for direct transfers or browser-based WebDrop.'),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                _PairCountBadge(count: pairs.length),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        ...pairs.indexed.map((entry) {
          final index = entry.$1;
          final pair = entry.$2;
          return GlassCard(
            margin: const EdgeInsets.only(bottom: 10),
            padding: EdgeInsets.zero,
            child: ExpansionTile(
              initiallyExpanded: index == 0,
              tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              leading: _PairNumberBadge(number: index + 1),
              title: Row(
                children: [
                  Icon(pair.$1.icon, size: 21),
                  const SizedBox(width: 8),
                  const Icon(Icons.sync_alt, size: 18),
                  const SizedBox(width: 8),
                  Icon(pair.$2.icon, size: 21),
                  const SizedBox(width: 10),
                  Expanded(child: Text('${pair.$1.label} ↔ ${pair.$2.label}')),
                ],
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Text(_pairDescription(pair)),
              ),
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _InfoBadge(icon: Icons.speed, label: 'LAN speed'),
                    _InfoBadge(icon: Icons.lock_outline, label: 'TLS follows device settings'),
                  ],
                ),
                const SizedBox(height: 16),
                Text('HOW TO PAIR & TRANSFER', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 8),
                const _PairStep(number: 1, text: 'Connect both devices to the same local network.'),
                const _PairStep(number: 2, text: 'Open OmniDrop on both devices. On the sender, choose files in Transfer.'),
                const _PairStep(number: 3, text: 'Select the receiving device from Nearby devices. Confirm the incoming request if prompted.'),
                const _PairStep(number: 4, text: 'For browser sharing, start WebDrop and open its displayed link or QR code on the other device.'),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: AnimatedPress(
                    child: OutlinedButton.icon(
                      onPressed: () => showReceivePairingDialog(context),
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text('Open pairing'),
                    ),
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }
}

class CloudTab extends StatelessWidget {
  const CloudTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_outlined, size: 48, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 12),
            Text(BrowserStrings.cloudSyncComingSoon, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _PairCountBadge extends StatelessWidget {
  final int count;

  const _PairCountBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(color: colors.primary.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(14)),
      child: Text('$count pairs', style: Theme.of(context).textTheme.labelLarge?.copyWith(color: colors.primary)),
    );
  }
}

class _PairNumberBadge extends StatelessWidget {
  final int number;

  const _PairNumberBadge({required this.number});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return CircleAvatar(
      radius: 17,
      backgroundColor: colors.primary.withValues(alpha: 0.14),
      child: Text(number.toString().padLeft(2, '0'), style: Theme.of(context).textTheme.labelSmall?.copyWith(color: colors.primary)),
    );
  }
}

class _InfoBadge extends StatelessWidget {
  final IconData icon;
  final String label;

  const _InfoBadge({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Chip(
      avatar: Icon(icon, size: 16, color: colors.secondary),
      label: Text(label),
      side: BorderSide(color: colors.secondary.withValues(alpha: 0.3)),
    );
  }
}

class _PairStep extends StatelessWidget {
  final int number;
  final String text;

  const _PairStep({required this.number, required this.text});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$number.',
            style: TextStyle(color: colors.primary, fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

String _pairDescription((_Platform, _Platform) pair) {
  final pairPlatforms = {pair.$1, pair.$2};
  if (pairPlatforms.contains(_Platform.android) && pairPlatforms.contains(_Platform.ios)) {
    return 'Share directly between phones over local Wi-Fi, or use WebDrop in a browser.';
  }
  if (pairPlatforms.any((platform) => platform == _Platform.android || platform == _Platform.ios)) {
    return 'Move files between mobile and desktop over local Wi-Fi, or use WebDrop in a browser.';
  }
  return 'Transfer directly between desktop devices over local Wi-Fi, or use WebDrop in a browser.';
}

const _profileAvatars = [Icons.person, Icons.face, Icons.account_circle, Icons.pets, Icons.rocket_launch, Icons.bolt];

class MeTab extends StatefulWidget {
  const MeTab({super.key});

  @override
  State<MeTab> createState() => _MeTabState();
}

class _MeTabState extends State<MeTab> with Refena {
  late int _avatarIndex = ref.read(persistenceProvider).getProfileAvatar() % _profileAvatars.length;

  Future<void> _editAvatar() async {
    final selected = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Choose avatar'),
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8,
              children: [
                for (var i = 0; i < _profileAvatars.length; i++)
                  IconButton(onPressed: () => Navigator.pop(context, i), icon: Icon(_profileAvatars[i], size: 32)),
              ],
            ),
          ),
        ],
      ),
    );
    if (selected == null) return;
    await ref.read(persistenceProvider).setProfileAvatar(selected);
    if (mounted) setState(() => _avatarIndex = selected);
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch(settingsProvider);
    final history = context.watch(receiveHistoryProvider);
    final totalReceived = history.fold<int>(0, (total, entry) => total + entry.fileSize);
    final uniqueSenders = history.map((entry) => entry.senderAlias).toSet().length;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Center(child: Text('Me', style: Theme.of(context).textTheme.headlineSmall)),
        const SizedBox(height: 20),
        Center(
          child: InkWell(
            onTap: _editAvatar,
            borderRadius: BorderRadius.circular(60),
            child: CircleAvatar(radius: 44, child: Icon(_profileAvatars[_avatarIndex], size: 42)),
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          initialValue: settings.alias,
          textAlign: TextAlign.center,
          decoration: const InputDecoration(labelText: 'Device name'),
          onChanged: (value) async => await ref.notifier(settingsProvider).setAlias(value),
        ),
        const SizedBox(height: 24),
        GlassCard(
          margin: EdgeInsets.zero,
          child: Column(
            children: [
              _ProfileMetric(label: 'Total sent', value: 'Not tracked'),
              const Divider(),
              _ProfileMetric(label: 'Total received', value: totalReceived.asReadableFileSize),
              const Divider(),
              _ProfileMetric(label: 'Unique senders (by name)', value: '$uniqueSenders recorded'),
              const Divider(),
              _ProfileMetric(label: 'Total data transferred', value: '${totalReceived.asReadableFileSize} received'),
            ],
          ),
        ),
        const SizedBox(height: 20),
        GlassCard(
          margin: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text('Transfer history', style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              if (history.isEmpty)
                const Text('No transfers yet.', textAlign: TextAlign.center)
              else
                for (final entry in history) ...[
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.insert_drive_file_outlined),
                    title: Text(entry.fileName),
                    subtitle: Text('${entry.timestampString} · ${entry.senderAlias}'),
                    trailing: Text(entry.fileSize.asReadableFileSize),
                  ),
                  if (entry != history.last) const Divider(height: 1),
                ],
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: () => context.push(() => const ReceiveHistoryPage()),
                icon: const Icon(Icons.history),
                label: const Text('View history'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ProfileMetric extends StatelessWidget {
  final String label;
  final String value;

  const _ProfileMetric({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(label, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 4),
        Text(value, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleSmall),
      ],
    ),
  );
}
