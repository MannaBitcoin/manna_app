import 'dart:async';
import 'dart:ui';

import 'package:breez_sdk_spark_flutter/breez_sdk_spark.dart' show BreezSdkSparkLib, initLogging;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:logger/logger.dart';
import 'package:manna/app_state.dart';
import 'package:manna/config.dart';
import 'package:manna/env.dart';
import 'package:manna/globals.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/menu_screen.dart';
import 'package:manna/screens/splash_screen.dart';
import 'package:manna/screens/unclaimed_deposits_screen.dart';
import 'package:manna/services/chat_service.dart';
import 'package:manna/services/connectivity_checker.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/db_service.dart';
import 'package:manna/services/deep_link_service.dart';
import 'package:manna/services/deposit_claim_service.dart';
import 'package:manna/services/jwt_service.dart';
import 'package:manna/services/nfc_service.dart';
import 'package:manna/services/notification_service.dart';
import 'package:manna/services/wallet_service.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/constants.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/util.dart';
import 'package:manna/widgets/bottom%20sheets/new_tx_notifier_bottom_sheet.dart';
import 'package:manna/widgets/restore_progress_bar.dart';
import 'package:manna/widgets/shimmer.dart';
import 'package:relative_time/relative_time.dart';
import 'package:manna_core/manna_core.dart';

import 'firebase_options.dart';
import 'services/log_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]));
  Config.init(Env.create());

  await LibMannaCore.init();
  await BreezSdkSparkLib.init();

  // Logging setup
  unawaited(
    Future(() async {
      await LogManager.cleanupOldLogs();
      await Future.wait([
        LogManager.rotateLogIfNeeded('flutter'),
        LogManager.rotateLogIfNeeded('android'),
        LogManager.rotateLogIfNeeded('ios'),
        LogManager.rotateLogIfNeeded('rust'),
      ]);
    }),
  );
  LogOutput? fileOutput;
  try {
    final logFolderPath = (await LogManager.getLogDirectory()).path;
    fileOutput = FileLogOutput(dirPath: logFolderPath);
    // rust logger
    await initLogger(logsDirPath: logFolderPath, target: 'Flutter');
  } catch (_) {}
  logger ??= Logger(
    level: Level.all,
    printer: CompactPrinter(maxMessageLength: 800),
    filter: ProductionFilter()..level = Level.all,
    output: MultiOutput([?fileOutput, if (kDebugMode) ConsoleOutput()]),
  );

  try {
    final output = FileLogOutput(dirPath: (await LogManager.getLogDirectory()).path, fileName: 'breez.jsonl');
    await output.init();

    final levelMap = Map.fromEntries(Level.values.map((e) => MapEntry(e.name.toUpperCase(), e)));
    initLogging().listen(
      (event) => output.output(
        OutputEvent(
          LogEvent(levelMap[event.level] ?? Level.trace, event.line, time: DateTime.now()),
          event.line.split('\n'),
        ),
      ),
      onError: (e, s) {
        logE(e, stackTrace: s);
      },
    );
  } catch (e, s) {
    logE(e, stackTrace: s);
  }

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  if (!kDebugMode) {
    await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(true);
    FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterError;
    PlatformDispatcher.instance.onError = (error, stack) {
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      return true;
    };
  }
  await AppState.init();
  runApp(const MannaApp());
}

// for obscure view when app is not in foreground
final ValueNotifier<bool> isVisible = ValueNotifier(true);

class MannaApp extends StatefulWidget {
  const MannaApp({super.key});

  @override
  State<MannaApp> createState() => MannaAppState();
}

class MannaAppState extends State<MannaApp> with WidgetsBindingObserver {
  AppLifecycleListener? listener;
  StreamSubscription<List<ConnectivityResult>>? connectivitySub;
  bool isMannaNetNoteExpanded = false;

  Future<void> init() async {
    await DB.tinyInit();
    await NotificationService.initialize();
    await NotificationService.storeInitialNotification();
    await DeepLinkService.storeInitialData();
    NfcService.storeInitialNFCAppOpen();

    await AppState.prefs.setInt('backgroundDateTime', DateTime.now().millisecondsSinceEpoch);
    connectivitySub = Connectivity().onConnectivityChanged.listen((List<ConnectivityResult> result) {
      ConnectivityChecker.checkConnection(force: true);
    });
  }

  @override
  void initState() {
    WidgetsBinding.instance.addObserver(this);

    init();
    globalState.update(
      isForeground: {
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      }.contains(WidgetsBinding.instance.lifecycleState),
    );
    listener = AppLifecycleListener(
      onHide: () {
        DbService.stopBtcPriceListening();
        ChatService.stopListener();
        connectivitySub?.pause();
        globalState.update(isForeground: false);
        AppState.prefs.setInt('backgroundDateTime', DateTime.now().millisecondsSinceEpoch);
      },
      onShow: () async {
        try {
          globalState.update(isForeground: true);
          connectivitySub?.resume();

          final backgroundTs = AppState.prefs.getInt('backgroundDateTime');
          await AppState.prefs.remove('backgroundDateTime');

          await NotificationService.storeInitialNotification();
          await DeepLinkService.storeInitialData();
          NfcService.storeInitialNFCAppOpen();

          // First launch or no background recorded: do nothing special
          if (backgroundTs == null) {
            return;
          }

          final backgroundTime = DateTime.fromMillisecondsSinceEpoch(backgroundTs);
          final diffMinutes = DateTime.now().difference(backgroundTime).abs().inMinutes;

          if (diffMinutes > 3) {
            // Long time away: full restart
            AppRouter.replaceAll(const SplashScreen());
          } else {
            NotificationService.handleInitialNotification();
            DeepLinkService.handleInitialData();

            if (diffMinutes > 1) {
              // Short absence: → defibrillation
              await ChatService.sendPendingLogs();
              await ChatService.sync();

              await WalletService.syncAllWallets();
            }

            await JWTService.getToken();

            DbService.startBtcPriceListening();
            await ChatService.startListener();
          }
        } catch (e, s) {
          logE(e, stackTrace: s);
        }
      },
      onStateChange: (value) {
        isVisible.value = (value == AppLifecycleState.resumed);
      },
    );
    GlobalListener.addListener(
      stream: .receivedTx,
      listenerName: 'main',
      callback: (data) {
        if (mounted) setState(() {});
        return true;
      },
    );
    GlobalListener.addListener(
      stream: .deposits,
      listenerName: 'main-deposits',
      callback: (data) {
        if (data is List<TrackedDeposit>) {
          promptUnclaimedDeposits(data);
        }
        return true;
      },
    );
    super.initState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    GlobalListener.removeListener(stream: .receivedTx, listenerName: 'main');
    GlobalListener.removeListener(stream: .deposits, listenerName: 'main-deposits');
    listener?.dispose();
    connectivitySub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ValueListenableBuilder(
        valueListenable: globalState,
        builder: (context, state, child) {
          return ValueListenableBuilder(
            valueListenable: isVisible,
            builder: (context, isVisible, child) {
              return MaterialApp(
                scrollBehavior: const ScrollBehavior().copyWith(
                  dragDevices: {
                    PointerDeviceKind.touch,
                    PointerDeviceKind.mouse,
                    PointerDeviceKind.stylus,
                    PointerDeviceKind.invertedStylus,
                    PointerDeviceKind.trackpad,
                    PointerDeviceKind.unknown,
                  },
                ),
                navigatorKey: AppRouter.navigatorKey,
                navigatorObservers: [AppRouter.navigatorObserver],
                title: 'Manna',
                debugShowCheckedModeBanner: false,
                localizationsDelegates: const <LocalizationsDelegate<dynamic>>[RelativeTimeLocalizations.delegate],
                theme: brightTheme,
                darkTheme: darkTheme,
                themeMode: AppState.theme,
                home: const SplashScreen(),
                builder: (context, child) {
                  final widget = SafeArea(
                    top: false,
                    child: Scaffold(
                      bottomSheet: newReceivedTxBottomSheet(context),
                      body: Stack(
                        children: [
                          Column(
                            children: [
                              Expanded(child: FToastBuilder()(context, child ?? const SizedBox.shrink())),
                              if (Config.network == Network.regtest)
                                GestureDetector(
                                  onTap: () {
                                    update(() => isMannaNetNoteExpanded = !isMannaNetNoteExpanded);
                                    if (isMannaNetNoteExpanded) {
                                      Timer(
                                        const Duration(seconds: 7),
                                        () => update(() => isMannaNetNoteExpanded = false),
                                      );
                                    }
                                  },
                                  child: Container(
                                    color: context
                                        .themedColor(bright: AppColors.primaryColor, dark: AppColors.darkCardColor)
                                        .withValues(alpha: 0.5),
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(4),
                                    alignment: Alignment.center,
                                    child: AnimatedCrossFade(
                                      duration: const Duration(milliseconds: 200),
                                      sizeCurve: Curves.fastOutSlowIn,
                                      crossFadeState: isMannaNetNoteExpanded
                                          ? CrossFadeState.showFirst
                                          : CrossFadeState.showSecond,
                                      firstChild: Text.rich(
                                        TextSpan(
                                          text: 'You are currently testing in the MannaNet environment. ',
                                          children: [
                                            TextSpan(
                                              text: '[Switch to Mainnet]',
                                              style: const TextStyle(
                                                fontWeight: FontWeight.bold,
                                                decoration: TextDecoration.underline,
                                                decorationColor: Colors.white60,
                                              ),
                                              recognizer: TapGestureRecognizer()
                                                ..onTap = () => updateNetwork(Network.mainnet),
                                            ),
                                          ],
                                        ),
                                        style: const TextStyle(color: Colors.white),
                                        textAlign: TextAlign.center,
                                      ),
                                      secondChild: const Text('Mannanet', style: TextStyle(color: Colors.white)),
                                    ),
                                  ),
                                ),
                              if (!state.isInternetConnected)
                                Container(
                                  width: double.infinity,
                                  decoration: BoxDecoration(
                                    color: context
                                        .themedColor(bright: AppColors.primaryColor, dark: AppColors.darkCardColor)
                                        .withValues(alpha: 0.5),
                                  ),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                  child: const Center(
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      spacing: 8,
                                      children: [
                                        Icon(Icons.wifi_off),
                                        Text(
                                          'No Internet Connection!',
                                          style: TextStyle(color: Colors.white),
                                          textAlign: TextAlign.center,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          if (state.isLoading)
                            SizedBox.expand(
                              child: ColoredBox(
                                color: Colors.grey.withValues(alpha: 0.4),
                                child: Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    spacing: 8,
                                    children: [
                                      SizedBox(
                                        height: 100,
                                        child: ShimmerWidget.fromColors(
                                          baseColor: AppColors.primaryColor,
                                          highlightColor: Colors.grey.shade100,
                                          child: SvgPicture.asset(AppImages.logoWhiteAssetSVG, width: 180),
                                        ),
                                      ),
                                      if (state.restoreSyncProgress > 0)
                                        const Padding(
                                          padding: EdgeInsets.symmetric(horizontal: 32),
                                          child: RestoreProgressBar(),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          if (!isVisible && !kDebugMode)
                            BackdropFilter(
                              filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                              child: const SizedBox.expand(),
                            ),
                        ],
                      ),
                    ),
                  );
                  if (!isDesktop) {
                    return widget;
                  }
                  return Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: (PointerDownEvent event) {
                      // Detect back button press (button 8)
                      if (event.buttons == 8) {
                        if (AppRouter.canPop()) {
                          AppRouter.pop();
                        }
                      }
                    },
                    child: Focus(
                      autofocus: true,
                      onKeyEvent: (node, event) {
                        if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
                          // Try to pop the top-most route
                          if (AppRouter.canPop()) {
                            AppRouter.pop();
                            return KeyEventResult.handled;
                          }
                        }
                        return KeyEventResult.ignored;
                      },
                      child: widget,
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}
