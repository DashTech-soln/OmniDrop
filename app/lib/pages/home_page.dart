import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/config/init.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/browser/browser_strings.dart';
import 'package:localsend_app/pages/browser/browser_surface.dart';
import 'package:localsend_app/pages/browser/browser_sort.dart';
import 'package:localsend_app/pages/browser/transfer_pill_notifier.dart';
import 'package:localsend_app/pages/copy_phone_page.dart';
import 'package:localsend_app/pages/home_page_controller.dart';
import 'package:localsend_app/pages/omnidrop_drawer.dart';
import 'package:localsend_app/pages/pairing/pairing_cards.dart';
import 'package:localsend_app/pages/pairing/pairing_controller_page.dart' show DeviceFromPairingInfo;
import 'package:localsend_app/pages/pairing/pairing_strings.dart';
import 'package:localsend_app/pages/tabs/omnidrop_tabs.dart';
import 'package:localsend_app/pages/tabs/send_tab.dart';
import 'package:localsend_app/pages/tabs/send_tab_vm.dart';
import 'package:localsend_app/pages/tabs/settings_tab.dart';
import 'package:localsend_app/pages/tabs/in_app_file_browser.dart';
import 'package:localsend_app/pages/transfer/transfer_progress_page.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/scan_facade.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/pairing/pairing_controller.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:localsend_app/widget/dialogs/add_file_dialog.dart';
import 'package:localsend_app/widget/dialogs/receive_pairing_dialog.dart';
import 'package:localsend_app/widget/glass/glass_card.dart';
import 'package:localsend_app/widget/list_tile/device_list_tile.dart';
import 'package:localsend_app/widget/omnidrop_logo.dart';
import 'package:localsend_app/widget/responsive_builder.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:localsend_isolates/rust/api/pairing.dart';
import 'package:refena_flutter/refena_flutter.dart';

enum HomeTab {
  webDrop(Icons.language),
  osPairs(Icons.devices),
  send(Icons.send),
  cloud(Icons.cloud_outlined),
  me(Icons.person_outline)
  ;

  const HomeTab(this.icon);

  final IconData icon;

  String get label {
    switch (this) {
      case HomeTab.webDrop:
        return 'WebDrop';
      case HomeTab.osPairs:
        return 'OS Pairs';
      case HomeTab.send:
        return 'Transfer';
      case HomeTab.cloud:
        return BrowserStrings.cloud;
      case HomeTab.me:
        return 'Me';
    }
  }
}

class HomePage extends StatefulWidget {
  final HomeTab initialTab;

  /// It is important for the initializing step
  /// because the first init clears the cache
  final bool appStart;

  const HomePage({required this.initialTab, required this.appStart, super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with Refena, SingleTickerProviderStateMixin {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _transferTabKey = GlobalKey<_TransferTabState>();
  final _browserKey = GlobalKey<InAppFileBrowserState>();
  late final AnimationController _headerAnimationController;
  final _searchController = TextEditingController();
  final _transferPillNotifier = TransferPillNotifier();
  bool _searchExpanded = false;
  String _searchCategory = BrowserStrings.downloads;
  BrowserSortMode _sortMode = BrowserSortMode.date;
  bool _sortAscending = false;
  HomeTab? _lastHomeTab;
  bool _dragAndDropIndicator = false;
  bool _expiryNoticeShown = false;

  @override
  void initState() {
    super.initState();
    _headerAnimationController =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 200),
          value: 1,
        );

    ensureRef((ref) async {
      ref.redux(homePageControllerProvider).dispatch(ChangeTabAction(widget.initialTab));
      await postInit(context, ref, widget.appStart);
    });
  }

  void _setBrowserHeaderVisible(bool visible) {
    if (visible) {
      if (_headerAnimationController.value < 1 && _headerAnimationController.status != AnimationStatus.forward) {
        _headerAnimationController.forward();
      }
    } else if (_headerAnimationController.value > 0 && _headerAnimationController.status != AnimationStatus.reverse) {
      _headerAnimationController.reverse();
    }
  }

  void _openSearch() => setState(() => _searchExpanded = true);

  void _closeSearch() {
    _searchController.clear();
    setState(() => _searchExpanded = false);
  }

  @override
  void dispose() {
    _headerAnimationController.dispose();
    _searchController.dispose();
    _transferPillNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Translations.of(context); // rebuild on locale change
    final vm = context.watch(homePageControllerProvider);
    if (_lastHomeTab != vm.currentTab) {
      _lastHomeTab = vm.currentTab;
      if (vm.currentTab == HomeTab.send) {
        _transferPillNotifier.showForEntry();
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _setBrowserHeaderVisible(true),
        );
      }
    }

    return PopScope<void>(
      canPop: !_searchExpanded,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _searchExpanded) _closeSearch();
      },
      child: DropTarget(
        onDragEntered: (_) {
          setState(() {
            _dragAndDropIndicator = true;
          });
        },
        onDragExited: (_) {
          setState(() {
            _dragAndDropIndicator = false;
          });
        },
        onDragDone: (event) async {
          // the drop may contain a mix of files and directories
          final droppedDirectories = event.files.where((file) => Directory(file.path).existsSync()).toList();
          final droppedFiles = event.files.where((file) => !Directory(file.path).existsSync()).toList();

          for (final directory in droppedDirectories) {
            await ref.redux(selectedSendingFilesProvider).dispatchAsync(AddDirectoryAction(directory.path));
          }

          if (droppedFiles.isNotEmpty) {
            await ref
                .redux(selectedSendingFilesProvider)
                .dispatchAsync(
                  AddFilesAction(
                    files: droppedFiles,
                    converter: CrossFileConverters.convertXFile,
                  ),
                );
          }
          vm.changeTab(HomeTab.send);
        },
        child: ResponsiveBuilder(
          builder: (sizingInformation) {
            final colors = Theme.of(context).colorScheme;
            final light = Theme.of(context).brightness == Brightness.light;
            return Scaffold(
              key: _scaffoldKey,
              drawer: const OmniDropDrawer(),
              endDrawer: Drawer(
                backgroundColor: Colors.transparent,
                child: GlassCard(
                  margin: EdgeInsets.zero,
                  padding: EdgeInsets.zero,
                  radius: 0,
                  blur: true,
                  child: SafeArea(child: const SettingsTab()),
                ),
              ),
              appBar: _AnimatedHeaderAppBar(
                animation: _headerAnimationController,
                child: AppBar(
                      automaticallyImplyLeading: false,
                      backgroundColor: Colors.transparent,
                      flexibleSpace: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: [
                              colors.primary.withValues(
                                alpha: light ? 0.24 : 0.16,
                              ),
                              colors.secondary.withValues(
                                alpha: light ? 0.16 : 0.08,
                              ),
                            ],
                          ),
                        ),
                      ),
                      leading: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        transitionBuilder: (child, animation) => FadeTransition(
                          opacity: animation,
                          child: SlideTransition(
                            position: Tween<Offset>(begin: const Offset(-0.15, 0), end: Offset.zero).animate(animation),
                            child: child,
                          ),
                        ),
                        child: _searchExpanded
                            ? IconButton(
                                key: const ValueKey('search-back'),
                                tooltip: BrowserStrings.closeSearch,
                                onPressed: _closeSearch,
                                icon: const Icon(Icons.arrow_back),
                              )
                            : IconButton(
                                key: const ValueKey('navigation-drawer'),
                                tooltip: 'Open navigation drawer',
                                onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                                icon: const Icon(Icons.more_vert),
                              ),
                      ),
                      title: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        transitionBuilder: (child, animation) => FadeTransition(
                          opacity: animation,
                          child: SlideTransition(
                            position: Tween<Offset>(begin: const Offset(0.08, 0), end: Offset.zero).animate(animation),
                            child: child,
                          ),
                        ),
                        child: _searchExpanded
                            ? BrowserSurface(
                                key: const ValueKey('header-search'),
                                padding: EdgeInsets.zero,
                                borderRadius: BorderRadius.circular(glassRadiusInput),
                                child: TextField(
                                  controller: _searchController,
                                  autofocus: true,
                                  decoration: InputDecoration(
                                    border: InputBorder.none,
                                    hintText: BrowserStrings.searchHint(_searchCategory),
                                    prefixIcon: const Icon(Icons.search),
                                    suffixIcon: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        PopupMenuButton<BrowserSortMode>(
                                          tooltip: BrowserStrings.sortBy,
                                          initialValue: _sortMode,
                                          onSelected: (value) => setState(() => _sortMode = value),
                                          itemBuilder: (context) => [
                                            for (final mode in BrowserSortMode.values)
                                              PopupMenuItem(
                                                value: mode,
                                                child: Text(switch (mode) {
                                                  BrowserSortMode.name => BrowserStrings.sortName,
                                                  BrowserSortMode.date => BrowserStrings.sortDate,
                                                  BrowserSortMode.size => BrowserStrings.sortSize,
                                                }),
                                              ),
                                          ],
                                          child: Icon(Icons.sort, color: colors.onSurfaceVariant),
                                        ),
                                        IconButton(
                                          tooltip: _sortAscending ? BrowserStrings.sortAscending : BrowserStrings.sortDescending,
                                          onPressed: () => setState(() => _sortAscending = !_sortAscending),
                                          icon: Icon(_sortAscending ? Icons.arrow_upward : Icons.arrow_downward),
                                        ),
                                        IconButton(
                                          tooltip: BrowserStrings.closeSearch,
                                          onPressed: _closeSearch,
                                          icon: const Icon(Icons.close),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              )
                            : const Row(
                                key: ValueKey('app-title'),
                                children: [
                                  OmniDropLogo(size: 32),
                                  SizedBox(width: 8),
                                  Text('OmniDrop'),
                                ],
                              ),
                      ),
                      actions: [
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          transitionBuilder: (child, animation) => FadeTransition(
                            opacity: animation,
                            child: SlideTransition(
                              position: Tween<Offset>(begin: const Offset(0.1, 0), end: Offset.zero).animate(animation),
                              child: child,
                            ),
                          ),
                          child: _searchExpanded
                              ? const SizedBox(key: ValueKey('search-actions-hidden'))
                              : Row(
                                  key: const ValueKey('normal-header-actions'),
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      tooltip: BrowserStrings.search,
                                      onPressed: _openSearch,
                                      icon: const Icon(Icons.search),
                                    ),
                                    PopupMenuButton<String>(
                                      tooltip: 'More actions',
                                      icon: const Icon(Icons.menu),
                                      onSelected: (value) async {
                                        if (value == 'scan') {
                                          await showReceivePairingDialog(
                                            context,
                                            allowWebDropLinks: true,
                                          );
                                        } else if (value == 'share') {
                                          final shared = await android_channel.shareInstalledApkAndroid();
                                          if (!shared) await android_channel.shareTextInviteAndroid();
                                        } else {
                                          final started = await Navigator.of(context).push<bool>(
                                            MaterialPageRoute(
                                              builder: (_) => const CopyPhonePage(),
                                            ),
                                          );
                                          if (started == true && context.mounted) {
                                            vm.changeTab(HomeTab.send);
                                            final transferState = _transferTabKey.currentState;
                                            if (transferState != null) await transferState._startSend();
                                          }
                                        }
                                      },
                                      itemBuilder: (context) => const [
                                        PopupMenuItem(
                                          value: 'scan',
                                          child: Text('Scan Connect'),
                                        ),
                                        PopupMenuItem(
                                          value: 'share',
                                          child: Text('Share OmniDrop'),
                                        ),
                                        PopupMenuItem(
                                          value: 'copy',
                                          child: Text('Copy Phone'),
                                        ),
                                      ],
                                    ),
                                    IconButton(
                                      tooltip: 'Settings',
                                      onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
                                      icon: const Icon(Icons.settings_outlined),
                                    ),
                                  ],
                                ),
                        ),
                      ],
                    ),
              ),
              body: Stack(
                fit: StackFit.expand,
                children: [
                  _OmniDropBackground(colors: colors, light: light),
                  Row(
                    children: [
                      if (!sizingInformation.isMobile)
                        NavigationRail(
                          selectedIndex: vm.currentTab.index,
                          onDestinationSelected: (index) => vm.changeTab(HomeTab.values[index]),
                          extended: sizingInformation.isDesktop,
                          backgroundColor: Colors.transparent,
                          destinations: HomeTab.values.map((tab) {
                            return NavigationRailDestination(
                              icon: tab == HomeTab.send ? const OmniDropLogo(size: 24) : Icon(tab.icon),
                              label: Text(tab.label),
                            );
                          }).toList(),
                        ),
                      Expanded(
                        child: SafeArea(
                          left: sizingInformation.isMobile,
                          child: Stack(
                            children: [
                              PageView(
                                controller: vm.controller,
                                physics: const NeverScrollableScrollPhysics(),
                                children: [
                                  const WebDropTab(),
                                  const OsPairsTab(),
                                  _TransferTab(
                                    key: _transferTabKey,
                                    browserKey: _browserKey,
                                    onHeaderVisibilityChanged: _setBrowserHeaderVisible,
                                    searchController: _searchController,
                                    searchExpanded: _searchExpanded,
                                    searchCategory: _searchCategory,
                                    sortMode: _sortMode,
                                    sortAscending: _sortAscending,
                                    onCategoryChanged: (category) => setState(() => _searchCategory = category),
                                    onSortModeChanged: (mode) => setState(() => _sortMode = mode),
                                    onSortDirectionChanged: (ascending) => setState(() => _sortAscending = ascending),
                                    transferPillNotifier: _transferPillNotifier,
                                  ),
                                  const CloudTab(),
                                  const MeTab(),
                                ],
                              ),
                              if (_dragAndDropIndicator)
                                Container(
                                  width: double.infinity,
                                  decoration: BoxDecoration(
                                    color: Theme.of(
                                      context,
                                    ).scaffoldBackgroundColor,
                                  ),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      const Icon(Icons.file_download, size: 128),
                                      const SizedBox(height: 30),
                                      Text(
                                        t.sendTab.placeItems,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleLarge,
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              bottomNavigationBar: sizingInformation.isMobile
                  ? SafeArea(
                      top: false,
                      child: Consumer(
                        builder: (context, ref) {
                          final pairing = ref.watch(pairingControllerProvider);
                          final selectedFiles = ref.watch(
                            selectedSendingFilesProvider,
                          );
                          final showActivePairing = pairing.role == PairingRole.sender && pairing.sessionToken != null;
                          if (pairing.phase == PairingPhase.stopped &&
                              pairing.failureReason == PairingStrings.sessionExpired &&
                              !_expiryNoticeShown) {
                            _expiryNoticeShown = true;
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(PairingStrings.sessionExpired),
                                  ),
                                );
                              }
                            });
                          } else if (pairing.phase != PairingPhase.stopped) {
                            _expiryNoticeShown = false;
                          }
                          if (vm.currentTab == HomeTab.send && selectedFiles.isNotEmpty) {
                            return _BrowserSelectionToolbar(
                              count: selectedFiles.length,
                              onCancel: () => ref.redux(selectedSendingFilesProvider).dispatch(ClearSelectionAction()),
                              onSend: () => _transferTabKey.currentState?._openSendPairingCard(),
                              onDelete: () => _transferTabKey.currentState?._deleteSelected(),
                            );
                          }
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (showActivePairing)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(14, 4, 8, 4),
                                  child: pairing.peers.isEmpty
                                      ? _PendingPairingPill(
                                          onTap: () => _transferTabKey.currentState?._openSendPairingCard(),
                                        )
                                      : Row(
                                          children: [
                                            Icon(Icons.wifi_tethering, color: Theme.of(context).colorScheme.tertiary),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                '${PairingStrings.pairActive} - ${pairing.peers.length} ${PairingStrings.devicesCount}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: Theme.of(context).textTheme.labelMedium,
                                              ),
                                            ),
                                            TextButton(
                                              onPressed: () => ref.notifier(pairingControllerProvider).stop(),
                                              child: const Text(PairingStrings.disconnect),
                                            ),
                                          ],
                                        ),
                                ),
                              BrowserSurface(
                                margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                                padding: EdgeInsets.zero,
                                borderRadius: BorderRadius.circular(30),
                                child: SizedBox(
                                  height: 34,
                                  child: Stack(
                                    clipBehavior: Clip.none,
                                    alignment: Alignment.center,
                                    children: [
                                      Row(
                                        children: [
                                          _bottomBarTab(HomeTab.webDrop, vm.currentTab, vm.changeTab),
                                          _bottomBarTab(HomeTab.osPairs, vm.currentTab, vm.changeTab),
                                          const Expanded(child: SizedBox()),
                                          _bottomBarTab(HomeTab.cloud, vm.currentTab, vm.changeTab),
                                          _bottomBarTab(HomeTab.me, vm.currentTab, vm.changeTab),
                                        ],
                                      ),
                                      Positioned(
                                        top: -11,
                                        child: Container(
                                          padding: const EdgeInsets.all(2),
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            boxShadow: [
                                              BoxShadow(
                                                color: colors.primary.withValues(alpha: 0.5),
                                                blurRadius: 12,
                                              ),
                                            ],
                                          ),
                                          child: FloatingActionButton(
                                            heroTag: 'transfer-tab',
                                            mini: false,
                                            onPressed: () {
                                              if (vm.currentTab != HomeTab.send) {
                                                vm.changeTab(HomeTab.send);
                                              } else {
                                                _transferPillNotifier.toggle();
                                              }
                                            },
                                            child: const OmniDropLogo(size: 28),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    )
                  : null,
            );
          },
        ),
      ),
    );
  }

  Widget _bottomBarTab(HomeTab tab, HomeTab selectedTab, void Function(HomeTab) changeTab) {
    final selected = selectedTab == tab;
    return Expanded(
      child: InkWell(
        onTap: () => changeTab(tab),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(tab.icon, size: 18, color: selected ? Theme.of(context).colorScheme.primary : null),
            Text(tab.label, style: Theme.of(context).textTheme.labelSmall, maxLines: 1),
          ],
        ),
      ),
    );
  }
}

class _BrowserSelectionToolbar extends StatelessWidget {
  final int count;
  final VoidCallback onCancel;
  final VoidCallback onSend;
  final VoidCallback onDelete;

  const _BrowserSelectionToolbar({
    required this.count,
    required this.onCancel,
    required this.onSend,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = BrowserThemeTokens.of(context);
    return SafeArea(
      top: false,
      child: BrowserSurface(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        borderRadius: BorderRadius.circular(glassRadiusPill),
        child: Row(
          children: [
            IconButton(
              tooltip: BrowserStrings.clearSelection,
              onPressed: onCancel,
              icon: const Icon(Icons.close),
            ),
            Expanded(
              child: FilledButton.icon(
                onPressed: onSend,
                icon: const Icon(Icons.send),
                label: Text(
                  BrowserStrings.sendCountTemplate.replaceAll(
                    '{count}',
                    '$count',
                  ),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: tokens.primary,
                  foregroundColor: Theme.of(context).colorScheme.onPrimary,
                ),
              ),
            ),
            IconButton(
              tooltip: BrowserStrings.trash,
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }
}

const String? _darkBackgroundImage = null;
const String? _lightBackgroundImage = null;

class _PendingPairingPill extends StatefulWidget {
  final VoidCallback onTap;

  const _PendingPairingPill({required this.onTap});

  @override
  State<_PendingPairingPill> createState() => _PendingPairingPillState();
}

class _PendingPairingPillState extends State<_PendingPairingPill> with Refena {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final expiresAt = ref.watch(pairingControllerProvider).expiresAt;
    final remaining = expiresAt == null ? Duration.zero : expiresAt.difference(DateTime.now());
    final minutes = remaining.inMinutes.clamp(0, PairingController.sessionLifetime.inMinutes).toString().padLeft(2, '0');
    final seconds = (remaining.inSeconds % 60).clamp(0, 59).toString().padLeft(2, '0');
    return InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: widget.onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(
              Icons.wifi_tethering,
              color: Theme.of(context).colorScheme.tertiary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${PairingStrings.pairingActive} - $minutes:$seconds',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            const Icon(Icons.open_in_new, size: 18),
          ],
        ),
      ),
    );
  }
}

class _OmniDropBackground extends StatelessWidget {
  final ColorScheme colors;
  final bool light;

  const _OmniDropBackground({required this.colors, required this.light});

  @override
  Widget build(BuildContext context) {
    final image = light ? _lightBackgroundImage : _darkBackgroundImage;
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: light ? const Color(0xFFEAF5FA) : glassBackground,
          image: image == null ? null : DecorationImage(image: AssetImage(image), fit: BoxFit.cover),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-0.85, -0.8),
                  radius: 1.0,
                  colors: [
                    colors.primary.withValues(alpha: light ? 0.20 : 0.22),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0.9, 0.9),
                  radius: 1.0,
                  colors: [
                    colors.secondary.withValues(alpha: light ? 0.12 : 0.18),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TransferTab extends StatefulWidget {
  final GlobalKey<InAppFileBrowserState> browserKey;
  final ValueChanged<bool>? onHeaderVisibilityChanged;
  final TextEditingController searchController;
  final bool searchExpanded;
  final String searchCategory;
  final BrowserSortMode sortMode;
  final bool sortAscending;
  final ValueChanged<String> onCategoryChanged;
  final ValueChanged<BrowserSortMode> onSortModeChanged;
  final ValueChanged<bool> onSortDirectionChanged;
  final TransferPillNotifier transferPillNotifier;

  const _TransferTab({
    required this.browserKey,
    required this.searchController,
    required this.searchExpanded,
    required this.searchCategory,
    required this.sortMode,
    required this.sortAscending,
    required this.onCategoryChanged,
    required this.onSortModeChanged,
    required this.onSortDirectionChanged,
    required this.transferPillNotifier,
    this.onHeaderVisibilityChanged,
    super.key,
  });

  @override
  State<_TransferTab> createState() => _TransferTabState();
}

class _TransferTabState extends State<_TransferTab> with Refena, AutomaticKeepAliveClientMixin {
  Future<void> _deleteSelected() async {
    await widget.browserKey.currentState?.handleDeleteSelection();
  }

  @override
  bool get wantKeepAlive => true;
  Future<void> _openSendPairingCard() async {
    if (ref.read(pairingConnectionProvider).isConnected) {
      await _sendToConnectedPeers();
      return;
    }
    await showPairingSendCard(context, onSendOverLan: _startSend);
  }

  Future<void> _sendToConnectedPeers() async {
    final connection = ref.read(pairingConnectionProvider);
    var files = ref.read(selectedSendingFilesProvider);
    if (files.isEmpty || connection.peers.isEmpty) return;
    final expandedFiles = await widget.browserKey.currentState?.filesForSending(files);
    if (!mounted || expandedFiles == null || expandedFiles.isEmpty) return;
    files = expandedFiles;

    List<PairingDeviceInfo> targets;
    if (connection.peers.length == 1) {
      targets = pairingTargetsForSelection(connection.peers, const {});
    } else {
      final selected = await showPairingTargetPicker(
        context,
        peers: connection.peers,
        sessionToken: connection.sessionToken,
        initialSelection: connection.lastSelectedFingerprints,
      );
      if (!mounted || selected == null) return;
      final current = ref.read(pairingConnectionProvider);
      targets = pairingTargetsForSelection(current.peers, selected);
      ref.notifier(pairingConnectionProvider).rememberSelection(selected);
    }
    if (targets.isEmpty) return;

    unawaited(
      Navigator.of(context, rootNavigator: true).push<void>(
        MaterialPageRoute<void>(builder: (_) => const TransferProgressPage()),
      ),
    );
    unawaited(() async {
      try {
        await Future.wait<void>(
          targets.map(
            (peer) => ref
                .notifier(sendProvider)
                .startSession(
                  target: DeviceFromPairingInfo.convert(peer),
                  files: files,
                  background: true,
                  skipChecksums: true,
                  retainCompletedSession: true,
                ),
          ),
        );
      } catch (error) {
        if (mounted)
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }());
  }

  Future<void> _disconnect() async {
    final connection = ref.read(pairingConnectionProvider);
    final activeSendSessions = ref
        .read(sendProvider)
        .values
        .where(
          (session) => session.status == SessionStatus.waiting || session.status == SessionStatus.sending,
        )
        .toList();
    final receiving = ref.read(serverProvider)?.session?.status == SessionStatus.sending;
    if (connection.activeTransferCount > 0 || activeSendSessions.isNotEmpty || receiving) {
      final disconnectAnyway = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('A transfer is still in progress'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Disconnect anyway'),
            ),
          ],
        ),
      );
      if (disconnectAnyway != true || !mounted) return;
      for (final session in activeSendSessions) {
        ref.notifier(sendProvider).cancelSession(session.sessionId);
      }
      final receiveSession = ref.read(serverProvider)?.session;
      if (receiveSession?.status == SessionStatus.sending) ref.notifier(serverProvider).cancelSession();
    }
    await ref.notifier(pairingControllerProvider).stop();
  }

  Future<void> _startSend() async {
    var files = ref.read(selectedSendingFilesProvider);
    if (files.isEmpty) {
      await AddFileDialog.open(context: context, options: pickerOptions);
      files = ref.read(selectedSendingFilesProvider);
    }
    if (!mounted || files.isEmpty) return;
    final expandedFiles = await widget.browserKey.currentState?.filesForSending(files);
    if (!mounted || expandedFiles == null || expandedFiles.isEmpty) return;
    files = expandedFiles;
    await showDialog<void>(
      context: context,
      builder: (_) => Consumer(
        builder: (dialogContext, ref) {
          final vm = ref.watch(sendTabVmProvider);
          final nearbyState = ref.watch(nearbyDevicesProvider);
          final devices = vm.nearbyDevices.toList()
            ..sort(
              (a, b) => a.alias.toLowerCase().compareTo(b.alias.toLowerCase()),
            );
          final isScanning = nearbyState.runningFavoriteScan || nearbyState.runningIps.isNotEmpty;
          final dialogHeight = (MediaQuery.sizeOf(dialogContext).height * 0.72).clamp(180.0, 600.0).toDouble();

          return Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 500),
              child: SizedBox(
                height: dialogHeight,
                child: GlassCard(
                  margin: EdgeInsets.zero,
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Nearby devices',
                                    style: Theme.of(
                                      dialogContext,
                                    ).textTheme.titleLarge,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Choose a device on your local network to send the staged files.',
                                    style: Theme.of(
                                      dialogContext,
                                    ).textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                            if (isScanning)
                              const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              )
                            else
                              IconButton(
                                tooltip: 'Scan again',
                                onPressed: () async {
                                  dialogContext.redux(nearbyDevicesProvider).dispatch(ClearFoundDevicesAction());
                                  await dialogContext.global.dispatchAsync(
                                    StartSmartScan(),
                                  );
                                },
                                icon: const Icon(Icons.refresh),
                              ),
                            IconButton(
                              tooltip: 'Close',
                              onPressed: () => Navigator.of(dialogContext).pop(),
                              icon: const Icon(Icons.close),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: devices.isEmpty
                            ? Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        isScanning ? Icons.wifi_find : Icons.devices_other,
                                        size: 36,
                                        color: Theme.of(
                                          dialogContext,
                                        ).colorScheme.secondary,
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        isScanning ? 'Scanning for nearby devices...' : 'No nearby devices found.',
                                      ),
                                      const SizedBox(height: 8),
                                      TextButton(
                                        onPressed: () async {
                                          dialogContext
                                              .redux(nearbyDevicesProvider)
                                              .dispatch(
                                                ClearFoundDevicesAction(),
                                              );
                                          await dialogContext.global.dispatchAsync(StartSmartScan());
                                        },
                                        child: const Text('Scan again'),
                                      ),
                                      TextButton(
                                        onPressed: () async {
                                          Navigator.of(dialogContext).pop();
                                          await vm.onTapAddress(context);
                                        },
                                        child: const Text(
                                          'Enter device address',
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              )
                            : ListView.builder(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                itemCount: devices.length,
                                itemBuilder: (context, index) {
                                  final device = devices[index];
                                  return DeviceListTile(
                                    device: device,
                                    onTap: () async {
                                      Navigator.of(dialogContext).pop();
                                      await vm.onTapDevice(context, device);
                                    },
                                  );
                                },
                              ),
                      ),
                      if (devices.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                          child: SizedBox(
                            width: double.infinity,
                            child: TextButton(
                              onPressed: () async {
                                Navigator.of(dialogContext).pop();
                                await vm.onTapAddress(context);
                              },
                              child: const Text('Enter device address'),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final connection = ref.watch(pairingConnectionProvider);
    final selectedFiles = ref.watch(selectedSendingFilesProvider);
    return Stack(
      children: [
        Positioned.fill(
          child: SendTab(
            browserKey: widget.browserKey,
            onHeaderVisibilityChanged: widget.onHeaderVisibilityChanged,
            onSendMessage: _openSendPairingCard,
            searchController: widget.searchController,
            searchExpanded: widget.searchExpanded,
            sortMode: widget.sortMode,
            sortAscending: widget.sortAscending,
            onCategoryChanged: widget.onCategoryChanged,
            onSortModeChanged: widget.onSortModeChanged,
            onSortDirectionChanged: widget.onSortDirectionChanged,
            transferPillNotifier: widget.transferPillNotifier,
            onReceive: () => showPairingReceiveCard(context),
          ),
        ),
        if (connection.isConnected && selectedFiles.isEmpty)
          Positioned(
            bottom: 10,
            left: 16,
            right: 16,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: FilledButton.tonalIcon(
                  onPressed: _disconnect,
                  icon: const Icon(Icons.link_off),
                  label: Text(
                    connection.peers.length == 1
                        ? 'Disconnect · ${connection.peers.single.alias}'
                        : 'Disconnect · ${connection.peers.length} devices',
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
