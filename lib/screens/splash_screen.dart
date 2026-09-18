import 'dart:async';

import 'package:file_saver/file_saver.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:intl/intl.dart';
import 'package:manna/app_state.dart';
import 'package:manna/globals.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/data_recovery_screen.dart';
import 'package:manna/screens/setup_wallet_screen.dart';
import 'package:manna/screens/shop_screen.dart';
import 'package:manna/screens/wallet_screen.dart';
import 'package:manna/services/biometric_services.dart';
import 'package:manna/services/chat_service.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/db_service.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/services/notification_service.dart';
import 'package:manna/services/wallet_service.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/constants.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:manna/widgets/shimmer.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  SplashScreenState createState() => SplashScreenState();
}

class SplashScreenState extends State<SplashScreen> with TickerProviderStateMixin {
  int animationStage = 0;
  bool isWalletLoading = false;
  Timer? animationTimer;

  @override
  void initState() {
    animationTimer = Timer(const Duration(milliseconds: 500), () {
      if (animationStage == 0) {
        update(() => animationStage = 1);
      }
    });

    init();
    super.initState();
  }

  @override
  void dispose() {
    animationTimer?.cancel();
    super.dispose();
  }

  Future<void> init() async {
    final migrationResult = await migrateDB();
    if (migrationResult == false) {
      update(() => animationStage = 4);
      return;
    } else if (migrationResult == true) {
      // Restart the entire app
      if (AppRouter.navigatorContext.mounted) {
        await Navigator.pushNamedAndRemoveUntil(AppRouter.navigatorContext, '/', (_) => false);
        return;
      }
    }

    if (isWalletLoading) return;

    try {
      GlobalListener.removeListener(stream: .account, listenerName: 'WalletScreenState');

      update(() => isWalletLoading = true);
      await DB.init(force: true);
      await FirebaseCrashlytics.instance.setUserIdentifier(DB.currentWallets.map((e) => e.uuid).toSet().toString());

      await DbService.init();
      unawaited(ChatService.init());
      unawaited(AppGroupSharedService.startSync());

      if (await BiometricService.authenticateBiometricsIfExists(message: 'Please authenticate to access the app')) {
        AppState.isAuthenticated = true;
        if (DB.activeAccounts.isEmpty) {
          AppRouter.replaceAll(const SetupWalletScreen());
        } else {
          if (await WalletService.initAllWallets()) {
            AppRouter.replaceAll(const WalletScreen());
            if (AppState.openShopOnBoot) {
              unawaited(AppRouter.push(const ShopScreen()));
            }
          } else {
            update(() => animationStage = 3);
          }
        }
      } else {
        update(() => animationStage = 2);
      }
    } catch (e, s) {
      logE(e, stackTrace: s);
    } finally {
      update(() => isWalletLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = (animationStage > 0 ? context.screenWidth / 2 : 0.0).clamp(0.0, 300.0);
    return Scaffold(
      backgroundColor: context.isDarkMode ? null : AppColors.primaryColor,
      body: Stack(
        alignment: Alignment.center,
        children: [
          if (animationStage < 2)
            AnimatedPositioned(
              bottom: animationStage > 0 ? 16 : context.screenHeight / 2,
              duration: const Duration(milliseconds: 2000),
              curve: Curves.fastLinearToSlowEaseIn,
              child: const Text(
                'MANNA',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 28),
              ),
            ),
          Center(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 2500),
              curve: Curves.fastLinearToSlowEaseIn,
              opacity: 1,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 1500),
                curve: Curves.easeOutQuad,
                width: size,
                height: size,
                child: ShimmerWidget.fromColors(
                  baseColor: AppColors.primaryColor,
                  highlightColor: Colors.grey.shade100,
                  shimmerState: animationStage < 2 ? ShimmerState.running : ShimmerState.stopped,
                  child: SvgPicture.asset(AppImages.logoWhiteAssetSVG),
                ),
              ),
            ),
          ),
          if (animationStage >= 2)
            Positioned(
              bottom: 32,
              left: 32,
              right: 32,
              child: ElevatedButtonTheme(
                data: ElevatedButtonThemeData(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: context.isDarkMode ? null : Colors.white24,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99)),
                    shadowColor: Colors.transparent,
                    foregroundColor: Colors.white,
                  ),
                ),
                child: Column(
                  spacing: 16,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: .center,
                      spacing: 24,
                      children: [
                        if (animationStage == 2)
                          Expanded(
                            child: ElevatedButton(
                              onPressed: isWalletLoading ? null : () => init(),
                              style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
                              child: const Text('Open Wallet', textAlign: TextAlign.center),
                            ),
                          ),
                        if (animationStage == 3)
                          Expanded(
                            child: ElevatedButton(
                              onPressed: () async {
                                if (await BiometricService.authenticateBiometricsIfExists()) {
                                  AppState.isAuthenticated = true;
                                  unawaited(AppRouter.push(const DataRecoveryScreen()));
                                }
                              },
                              style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
                              child: const Text('Recover data', textAlign: TextAlign.center),
                            ),
                          ),
                      ],
                    ),
                    if (animationStage == 4) ...[
                      const Text('Database migration failed!', style: TextStyle(color: Colors.red, fontSize: 16)),
                      ElevatedButton(
                        onPressed: () async {
                          if (await BiometricService.authenticateBiometricsIfExists()) {
                            try {
                              await DB.exportAppData();

                              try {
                                final zipData = await LogManager.exportLogs();
                                if (zipData != null) {
                                  final savedPath = await FileSaver.instance.saveAs(
                                    name: 'manna_logs_${DateFormat('yyyy_MM_dd_hh_mm').format(DateTime.now())}',
                                    bytes: zipData,
                                    mimeType: MimeType.zip,
                                    fileExtension: 'zip',
                                  );
                                  if (savedPath?.isNotEmpty ?? false) ToastService.show('Logs exported successfully.');
                                }
                              } catch (e, s) {
                                logE(e, stackTrace: s, showToast: true);
                              }
                            } catch (e, s) {
                              logE(e, stackTrace: s, showToast: true);
                            }
                          }
                        },
                        style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
                        child: const Text('Export data', textAlign: TextAlign.center),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
