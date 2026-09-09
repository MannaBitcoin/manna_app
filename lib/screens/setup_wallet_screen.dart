import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:manna/config.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/restore_wallet_screen.dart';
import 'package:manna/screens/splash_screen.dart';
import 'package:manna/screens/wallet_screen.dart';
import 'package:manna/services/db.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/constants.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:manna/widgets/bottom sheets/account_bottom_sheet.dart';
import 'package:manna/widgets/shimmer.dart';
import 'package:url_launcher/url_launcher_string.dart';

class SetupWalletScreen extends StatefulWidget {
  const SetupWalletScreen({super.key});

  @override
  State<SetupWalletScreen> createState() => _SetupWalletScreenState();
}

class _SetupWalletScreenState extends State<SetupWalletScreen> {
  bool isAgreed = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          const Spacer(flex: 2),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Column(
              spacing: 8,
              children: [
                ShimmerWidget.fromColors(
                  baseColor: AppColors.primaryColor,
                  highlightColor: Colors.grey.shade100,
                  child: SvgPicture.asset(AppImages.logoWhiteAssetSVG, width: 180, fit: BoxFit.cover),
                ),
                Text(
                  'secure. fast. simple.',
                  style: TextStyle(
                    fontSize: 24,
                    color: AppColors.primaryColor.withValues(alpha: context.isDarkMode ? 1 : 0.7),
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                Text(
                  'Store, send, and manage your bitcoin without permission from a 3rd party. No personal data is required - not even an email.',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.grey.shade500),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          const Spacer(),
          Column(
            spacing: 8,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ElevatedButton(
                  onPressed: () async {
                    if (!isAgreed) {
                      return ToastService.show('Please agree to the Terms of Service and Privacy Policy');
                    }
                    final res = await showModalBottomSheet(
                      context: context,
                      showDragHandle: true,
                      isScrollControlled: true,
                      useSafeArea: true,
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                      ),
                      routeSettings: const RouteSettings(name: 'AccountBottomSheet'),
                      builder: (context) => const AccountBottomSheet(),
                    );
                    if (res is bool && res) {
                      AppRouter.replaceAll(const WalletScreen());
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                    visualDensity: VisualDensity.standard,
                  ),
                  child: const Text(
                    'Continue with a new wallet',
                    style: TextStyle(fontWeight: FontWeight.w500, fontSize: 16),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text('or'),
              PopupMenuButton(
                position: PopupMenuPosition.under,
                offset: const Offset(0, -280),
                constraints: const BoxConstraints(),
                menuPadding: const EdgeInsets.all(8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadiusGeometry.circular(16)),
                itemBuilder: (context) => [
                  PopupMenuItem(
                    padding: EdgeInsets.zero,
                    child: const Tooltip(
                      message: 'Create a new wallet account',
                      child: WalletOptionCard(
                        title: 'Restore Wallet',
                        description: 'Recover an existing wallet with a recovery seed phrase or wallet descriptor',
                        iconData: Icons.lock_open,
                        gradientColors: [Colors.greenAccent, Colors.teal],
                      ),
                    ),
                    onTap: () async {
                      if (!isAgreed) {
                        return ToastService.show('Please agree to the Terms of Service and Privacy Policy');
                      }
                      unawaited(AppRouter.push(const RestoreWalletScreen()));
                    },
                  ),
                  PopupMenuItem(
                    padding: EdgeInsets.zero,
                    child: const Tooltip(
                      message: 'Restore existing wallet account',
                      child: WalletOptionCard(
                        title: 'Import app data',
                        description: 'Recover wallets and settings from exported zip',
                        iconData: Icons.install_mobile,
                        gradientColors: [Colors.blueAccent, Colors.purpleAccent],
                      ),
                    ),
                    onTap: () async {
                      if (!isAgreed) {
                        return ToastService.show('Please agree to the Terms of Service and Privacy Policy');
                      }
                      if (await DB.importAppData()) {
                        AppRouter.replaceAll(const SplashScreen());
                      }
                    },
                  ),
                ],
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text('Recover existing wallet', style: TextStyle(color: AppColors.primaryColor)),
                ),
              ),
              const SizedBox(height: 4),
              CheckboxListTile(
                value: isAgreed,
                onChanged: (value) => update(() => isAgreed = value ?? false),
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
                title: Text.rich(
                  TextSpan(
                    text: 'By continuing, you agree to our ',
                    children: [
                      TextSpan(
                        text: 'Terms of Service',
                        style: const TextStyle(
                          color: AppColors.primaryColor,
                          fontWeight: FontWeight.bold,
                          decoration: TextDecoration.underline,
                        ),
                        recognizer: TapGestureRecognizer()
                          ..onTap = () => launchUrlString(Config.current.getServerEndpoint('terms')),
                      ),
                      const TextSpan(text: ' and '),
                      TextSpan(
                        text: 'Privacy Policy',
                        style: const TextStyle(
                          color: AppColors.primaryColor,
                          fontWeight: FontWeight.bold,
                          decoration: TextDecoration.underline,
                        ),
                        recognizer: TapGestureRecognizer()
                          ..onTap = () => launchUrlString(Config.current.getServerEndpoint('privacy')),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const Spacer(),
        ],
      ),
    );
  }
}

class WalletOptionCard extends StatelessWidget {
  const WalletOptionCard({
    required this.title,
    required this.description,
    required this.iconData,
    required this.gradientColors,
    super.key,
  });

  final String title;
  final String description;
  final IconData iconData;
  final List<Color> gradientColors;

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            ShaderMask(
              blendMode: BlendMode.srcIn,
              shaderCallback: (Rect bounds) {
                return LinearGradient(
                  colors: gradientColors,
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ).createShader(bounds);
              },
              child: Icon(iconData, size: 40, color: Colors.white),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: .start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  Text(
                    description,
                    style: TextStyle(
                      color: context.themedColor(bright: Colors.black87, dark: Colors.white70),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
