import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:localsend_app/config/crash_report.dart';
import 'package:localsend_app/config/init.dart';
import 'package:localsend_app/config/init_error.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/color_mode.dart';
import 'package:localsend_app/pages/home_page.dart';
import 'package:localsend_app/pages/pairing/pairing_strings.dart';
import 'package:localsend_app/pages/transfer/transfer_dock_overlay.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/pairing/pairing_controller.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/ui/dynamic_colors.dart';
import 'package:localsend_app/widget/launch_splash_overlay.dart';
import 'package:localsend_app/widget/watcher/life_cycle_watcher.dart';
import 'package:localsend_app/widget/watcher/shortcut_watcher.dart';
import 'package:localsend_app/widget/watcher/tray_watcher.dart';
import 'package:localsend_app/widget/watcher/window_watcher.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:refena_flutter/addons.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

void main(List<String> args) {
  final mainStartedAt = DateTime.now();
  var appStarted = false;

  void handleError(Object error, StackTrace stackTrace) {
    if (appStarted) {
      unawaited(writeLastCrashReport(error: error, stackTrace: stackTrace));
      return;
    }

    showInitErrorApp(error: error, stackTrace: stackTrace);
    appStarted = true;
  }

  unawaited(
    runZonedGuarded(() async {
      WidgetsFlutterBinding.ensureInitialized();
      recordPairingStartupTiming('main_start', mainStartedAt);
      FlutterError.onError = (details) {
        handleError(details.exception, details.stack ?? StackTrace.current);
      };
      PlatformDispatcher.instance.onError = (error, stackTrace) {
        handleError(error, stackTrace);
        return true;
      };

      recordPairingStartupTiming('before_runApp', DateTime.now());
      runApp(
        _StartupApp(
          args: args,
          onError: handleError,
          onStarted: () => appStarted = true,
        ),
      );
    }, handleError),
  );
}

class _StartupApp extends StatefulWidget {
  final List<String> args;
  final void Function(Object error, StackTrace stackTrace) onError;
  final VoidCallback onStarted;

  const _StartupApp({
    required this.args,
    required this.onError,
    required this.onStarted,
  });

  @override
  State<_StartupApp> createState() => _StartupAppState();
}

class _StartupAppState extends State<_StartupApp> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      recordPairingStartupTiming('first_frame', DateTime.now());
      unawaited(_initialize());
    });
  }

  Future<void> _initialize() async {
    try {
      final container = await preInit(widget.args);
      recordPairingStartupTiming('preInit_complete', DateTime.now());
      runApp(
        RefenaScope.withContainer(
          container: container,
          child: TranslationProvider(child: const LocalSendApp()),
        ),
      );
      widget.onStarted();
    } catch (error, stackTrace) {
      widget.onError(error, stackTrace);
    }
  }

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.send_rounded, size: 48),
              SizedBox(height: 12),
              Text(PairingStrings.starting),
            ],
          ),
        ),
      ),
    );
  }
}

class LocalSendApp extends StatelessWidget {
  const LocalSendApp();

  @override
  Widget build(BuildContext context) {
    final ref = context.ref;
    final (themeMode, colorMode, customColor) = ref.watch(
      settingsProvider.select(
        (settings) => (settings.theme, settings.colorMode, settings.customColor),
      ),
    );
    final dynamicColors = ref.watch(dynamicColorsProvider);
    return TrayWatcher(
      child: WindowWatcher(
        child: LifeCycleWatcher(
          onChangedState: (AppLifecycleState state) {
            switch (state) {
              case AppLifecycleState.resumed:
                ref.redux(localIpProvider).dispatch(InitLocalIpAction());
                if (checkPlatform([
                  TargetPlatform.iOS,
                  TargetPlatform.android,
                ])) {
                  // The OS may have invalidated the sockets of the suspended app without any error ever reaching the accept loop.
                  // ignore: discarded_futures
                  ref.notifier(serverProvider).ensureRunning();
                }
                if (checkPlatform([TargetPlatform.iOS])) {
                  // The multicast sockets die the same silent way but cannot be probed, so always rebind them.
                  ref.redux(parentIsolateProvider).dispatch(IsolateDiscoveryRestartAction());
                }
                break;
              case AppLifecycleState.detached:
                // The main isolate is only exited when all child isolates are exited.
                // https://github.com/localsend/localsend/issues/1568
                ref.redux(parentIsolateProvider).dispatch(IsolateDisposeAction());
                break;
              default:
                break;
            }
          },
          child: ShortcutWatcher(
            child: MaterialApp(
              title: t.appName,
              locale: TranslationProvider.of(context).flutterLocale,
              supportedLocales: AppLocaleUtils.supportedLocales,
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              debugShowCheckedModeBanner: false,
              builder: (context, child) => Stack(
                fit: StackFit.expand,
                children: [
                  LaunchSplashOverlay(child: child ?? const SizedBox.shrink()),
                  const TransferDockOverlay(),
                ],
              ),
              theme: getTheme(
                colorMode,
                customColor,
                Brightness.light,
                dynamicColors,
              ),
              darkTheme: getTheme(
                colorMode,
                customColor,
                Brightness.dark,
                dynamicColors,
              ),
              themeMode: colorMode == ColorMode.oled ? ThemeMode.dark : themeMode,
              navigatorKey: context.read(navigationProvider).key,
              home: RouterinoHome(
                builder: () => const HomePage(initialTab: HomeTab.send, appStart: true),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
