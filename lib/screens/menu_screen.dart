import 'dart:async';
import 'dart:convert';

import 'package:build_info/build_info.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:manna/app_state.dart';
import 'package:manna/config.dart';
import 'package:manna/globals.dart';
import 'package:manna/main.dart';
import 'package:manna/models/account.dart';
import 'package:manna/models/country_model.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/attribution_screen.dart';
import 'package:manna/screens/calculators_screen.dart';
import 'package:manna/screens/data_recovery_screen.dart';
import 'package:manna/screens/log_screen.dart';
import 'package:manna/screens/splash_screen.dart';
import 'package:manna/screens/wallet_management_screen.dart';
import 'package:manna/services/biometric_services.dart';
import 'package:manna/services/chat_service.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/services/wallet_service.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/constants.dart';
import 'package:manna/utils/date_extension.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/widgets/bottom sheets/bug_report_bottom_sheet.dart';
import 'package:manna_core/manna_core.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:upgrader/upgrader.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'btc_map_screen.dart';

final upgrader = Upgrader(durationUntilAlertAgain: Duration.zero);

Future<void> updateNetwork(Network network) async {
  try {
    startLoader();
    await ChatService.stopListener();

    await AppState.prefs.setInt('network', network.index);
    await Future.wait(DB.currentWallets.map((w) async => WalletService.closeWallet(xpub: w.xpub)));
    DB.loadWallets();
    selectAccount();

    AppRouter.replaceAll(const SplashScreen());
  } catch (e, s) {
    logE(e, stackTrace: s);
  } finally {
    stopLoader();
    GlobalListener.update(stream: .account);
    GlobalListener.update(stream: .receivingTx);
  }
}

final Map<int, String> bitcoinSymbols = {0: '₿', 1: 'Sats', 2: 'BTC'};

class MenuScreen extends StatefulWidget {
  const MenuScreen({this.isFromUpdateDialog = false, super.key});

  final bool isFromUpdateDialog;

  @override
  MenuScreenState createState() => MenuScreenState();
}

class MenuScreenState extends State<MenuScreen> {
  final scrollController = ScrollController();
  bool isAdvanceSettingExpanded = false;
  bool showBiometric = true;
  PackageInfo? packageInfo;
  BuildInfoData? buildInfoData;

  @override
  void initState() {
    scheduleMicrotask(() async {
      showBiometric = await BiometricService.auth.canCheckBiometrics && await BiometricService.auth.isDeviceSupported();
      try {
        packageInfo = await PackageInfo.fromPlatform();
      } catch (e, s) {
        logE(e, stackTrace: s);
      }
      update();
    });
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Menu')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: SingleChildScrollView(
            controller: scrollController,
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: .start,
              children: [
                UpgradeCard(upgrader: upgrader, showIgnore: false, showLater: false),
                _buildListTile(
                  title: 'Wallets',
                  subtitle: 'Manage, add and remove wallet accounts',
                  icon: Icons.wallet_outlined,
                  onTap: () => AppRouter.push(const WalletManagementScreen()),
                ),
                // if (!isDesktop)
                _buildListTile(
                  title: 'BTC Map',
                  subtitle: 'Find places to spend bitcoin wherever you are.',
                  icon: Icons.map_outlined,
                  onTap: () => AppRouter.push(const BtcMapScreen()),
                ),
                _buildListTile(
                  title: 'Converters',
                  icon: Icons.currency_exchange,
                  onTap: () => AppRouter.push(const ConvertersScreen()),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8.0),
                  child: Text('General Settings', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                ),
                _buildListTile(
                  title: AppState.selectedCurrency.currencyName,
                  subtitle: '${AppState.selectedCurrency.currencyCode} (${AppState.selectedCurrency.name})',
                  icon: Icons.attach_money,
                  trailing: Text(AppState.selectedCurrency.currencySymbol, style: const TextStyle(fontSize: 18)),
                  onTap: () async {
                    final res = await showModalBottomSheet(
                      context: context,
                      showDragHandle: true,
                      isScrollControlled: true,
                      useSafeArea: true,
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                      ),
                      routeSettings: const RouteSettings(name: 'CountrySelectionBottomSheet'),
                      builder: (context) => const CountrySelectionBottomSheet(),
                    );
                    if (res is CountryModel) {
                      AppState.selectedCurrency = res;
                      GlobalListener.update(stream: .account);
                      update();
                    }
                  },
                ),
                if (showBiometric)
                  Card(
                    child: SwitchListTile(
                      title: const Text('Biometric Authentication'),
                      value: BiometricService.isBiometricOn,
                      secondary: const Icon(Icons.fingerprint),
                      onChanged: (bool value) async {
                        if (value) {
                          await BiometricService.enableBiometric();
                        } else {
                          await BiometricService.disableBiometric();
                        }
                        update();
                      },
                    ),
                  ),
                Card(
                  child: SizedBox(
                    height: 72,
                    child: DropdownButton(
                      value: AppState.theme,
                      items: ThemeMode.values.map((e) => DropdownMenuItem(value: e, child: Text(e.name))).toList(),
                      selectedItemBuilder: (context) => ThemeMode.values
                          .map(
                            (e) => ListTile(
                              leading: const Icon(Icons.color_lens_outlined),
                              title: const Text('Theme'),
                              subtitle: Text(e.name),
                            ),
                          )
                          .toList(),
                      onChanged: (val) async {
                        final theme = val ?? ThemeMode.system;
                        AppState.theme = theme;
                        context.findAncestorStateOfType<MannaAppState>()?.update();
                        update();
                      },
                      underline: Container(),
                      isExpanded: true,
                      padding: const EdgeInsets.only(right: 16),
                      icon: const Align(
                        alignment: Alignment.bottomCenter,
                        heightFactor: 2,
                        child: Icon(Icons.arrow_drop_down),
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                Card(
                  child: SizedBox(
                    height: 72,
                    child: DropdownButton(
                      value: AppState.bitcoinDisplayStyle,
                      items: bitcoinSymbols.entries
                          .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                          .toList(),
                      selectedItemBuilder: (context) => bitcoinSymbols.entries
                          .map(
                            (e) => ListTile(
                              leading: const Icon(Icons.currency_bitcoin),
                              title: const Text('Bitcoin symbol'),
                              subtitle: Text(e.value),
                            ),
                          )
                          .toList(),
                      onChanged: (val) async {
                        AppState.bitcoinDisplayStyle = val ?? 0;
                        update();
                        GlobalListener.update(stream: .account, data: selectedAccountId);
                      },
                      underline: Container(),
                      isExpanded: true,
                      padding: const EdgeInsets.only(right: 16),
                      icon: const Align(
                        alignment: Alignment.bottomCenter,
                        heightFactor: 2,
                        child: Icon(Icons.arrow_drop_down),
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                Card(
                  color: isAdvanceSettingExpanded
                      ? context.themedColor(bright: Colors.white, dark: AppColors.darkCardColor)
                      : null,
                  elevation: isAdvanceSettingExpanded ? 0 : null,
                  child: ExpansionTile(
                    shape: InputBorder.none,
                    collapsedShape: RoundedRectangleBorder(borderRadius: BorderRadiusGeometry.circular(16)),
                    title: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8.0),
                      child: Text('Advanced Settings', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                    ),
                    onExpansionChanged: (value) => update(() => isAdvanceSettingExpanded = value),
                    children: [
                      Card(
                        child: SizedBox(
                          height: 72,
                          child: DropdownButton(
                            isExpanded: true,
                            padding: const EdgeInsets.only(right: 16),
                            icon: const Align(
                              alignment: Alignment.bottomCenter,
                              heightFactor: 2,
                              child: Icon(Icons.arrow_drop_down),
                            ),
                            borderRadius: BorderRadius.circular(12),
                            items: AppState.blockExplorers.entries
                                .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                                .toList(),
                            selectedItemBuilder: (context) => AppState.blockExplorers.entries
                                .map(
                                  (e) => ListTile(
                                    leading: const Icon(Icons.travel_explore_outlined),
                                    title: const Text('Block explorer'),
                                    subtitle: Text(e.value),
                                  ),
                                )
                                .toList(),
                            underline: Container(),
                            value: AppState.blockExplorer,
                            onChanged: (val) async {
                              if (val != null) {
                                AppState.blockExplorer = val;
                                update();
                              }
                            },
                          ),
                        ),
                      ),
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.receipt_long),
                          title: const Text('Data recovery'),
                          subtitle: const Text('Import-export shop data, full app backups.'),
                          onTap: () => AppRouter.push(const DataRecoveryScreen()),
                        ),
                      ),
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.list),
                          title: const Text('Logs'),
                          onTap: () => AppRouter.push(const LogScreen()),
                        ),
                      ),
                      Card(
                        child: SwitchListTile(
                          title: const Text('Sound effects'),
                          value: AppState.isSoundEffectsOn,
                          secondary: const Icon(Icons.music_note_outlined),
                          onChanged: (bool value) => update(() => AppState.isSoundEffectsOn = value),
                        ),
                      ),
                      if (Config.apiConfig.regtest.supabase.projectRef.isNotEmpty)
                        Card(
                          child: SwitchListTile(
                            title: const Text('Switch to MannaNet'),
                            subtitle: Text.rich(
                              TextSpan(
                                text:
                                    'Mannanet is a Regtest network on the Manna server for testing and education only. Bitcoin here have no value. visit ',
                                children: [
                                  TextSpan(
                                    text: 'https://wallets.${Config.apiConfig.regtest.serverUrl}',
                                    style: TextStyle(color: Colors.blue.shade600),
                                    recognizer: TapGestureRecognizer()
                                      ..onTap = () =>
                                          launchUrlString('https://wallets.${Config.apiConfig.regtest.serverUrl}'),
                                  ),
                                  const TextSpan(text: ' to test.'),
                                ],
                              ),
                            ),
                            value: Config.network == Network.regtest,
                            secondary: const Icon(Icons.change_circle_outlined),
                            onChanged: (value) async {
                              await updateNetwork(value ? Network.regtest : Network.mainnet);
                            },
                          ),
                        ),
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.bug_report),
                          title: const Text('Report an issue'),
                          onTap: () async {
                            await showModalBottomSheet(
                              context: context,
                              showDragHandle: true,
                              isScrollControlled: true,
                              useSafeArea: true,
                              isDismissible: false,
                              shape: const RoundedRectangleBorder(
                                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                              ),
                              routeSettings: const RouteSettings(name: 'BugReportBottomSheet'),
                              builder: (context) => const BugReportBottomSheet(),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          const SizedBox(height: 16),
                          Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              color: AppColors.primaryColor,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            padding: const EdgeInsets.all(8),
                            child: SvgPicture.asset('assets/images/manna_white.svg'),
                          ),
                          const SizedBox(height: 8),
                          if (packageInfo != null) ...[
                            Text(packageInfo!.appName),
                            GestureDetector(
                              onTap: () async {
                                try {
                                  buildInfoData = await BuildInfo.fromPlatform();
                                  update();
                                } catch (e, s) {
                                  logE(e, stackTrace: s);
                                }
                              },
                              child: Text(
                                'Version ${packageInfo!.version}+${packageInfo!.buildNumber}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.grey),
                              ),
                            ),
                            if (buildInfoData?.buildDate != null)
                              Text(
                                'Build timestamp: ${buildInfoData!.buildDate!.toLocal().format()}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.grey, fontSize: 12),
                              ),
                            if (buildInfoData?.installDate != null)
                              Text(
                                'Install timestamp: ${buildInfoData!.installDate!.toLocal().format()}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.grey, fontSize: 12),
                              ),
                          ],
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            alignment: WrapAlignment.center,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            runAlignment: WrapAlignment.center,
                            children: [
                              ActionChip(
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                tooltip: 'Github',
                                label: const Text('Github'),
                                avatar: const Icon(Icons.gite),
                                onPressed: () => launchUrlString('https://github.com/MannaBitcoin/manna-app'),
                              ),
                              ActionChip(
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                tooltip: 'Share',
                                label: const Text('Share'),
                                avatar: const Icon(Icons.share),
                                onPressed: () => SharePlus.instance.share(
                                  ShareParams(
                                    uri: Uri.parse(Config.current.getServerEndpoint('')),
                                    title: 'Manna-Self Custodial Bitcoin Wallet',
                                    subject: 'Manna',
                                    sharePositionOrigin: context.sharePlusRect,
                                  ),
                                ),
                              ),
                              ActionChip(
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                tooltip: 'Website',
                                label: const Text('Website'),
                                avatar: const Icon(CupertinoIcons.globe),
                                onPressed: () => launchUrlString(Config.current.getServerEndpoint('')),
                              ),
                              ActionChip(
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                tooltip: 'Telegram',
                                label: const Text('Telegram'),
                                avatar: const Icon(Icons.telegram_outlined),
                                onPressed: () => launchUrlString('https://t.me/MannaBitcoin'),
                              ),
                              ActionChip(
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                tooltip: 'https://x.com/MannaBitcoin',
                                label: const Text('X'),
                                avatar: Image.asset(
                                  AppImages.x,
                                  height: 16,
                                  width: 16,
                                  fit: BoxFit.contain,
                                  color: context.isDarkMode ? Colors.white : null,
                                ),
                                onPressed: () => launchUrlString('https://x.com/MannaBitcoin'),
                              ),
                              ActionChip(
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                tooltip: 'support@mannabitcoin.com',
                                label: const Text('Email'),
                                avatar: const Icon(Icons.email_outlined),
                                onPressed: () => launchUrlString('mailto:support@mannabitcoin.com'),
                              ),
                              ActionChip(
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                tooltip: 'svrnsociety',
                                label: const Text('Merch'),
                                avatar: const Icon(Icons.shopping_bag_outlined),
                                onPressed: () => launchUrlString('https://svrnsociety.com/collections/manna-merch'),
                              ),
                              ActionChip(
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                tooltip: 'Attribution',
                                label: const Text('Attribution'),
                                avatar: const Icon(Icons.attribution_outlined),
                                onPressed: () => AppRouter.push(const AttributionScreen()),
                              ),
                              ActionChip(
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                tooltip: 'Third party library licenses',
                                label: const Text('Licenses'),
                                avatar: const Icon(Icons.book_outlined),
                                onPressed: () {
                                  AppRouter.push(
                                    LicensePage(
                                      applicationIcon: Container(
                                        width: 64,
                                        height: 64,
                                        decoration: BoxDecoration(
                                          color: AppColors.primaryColor,
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        padding: const EdgeInsets.all(8),
                                        child: SvgPicture.asset('assets/images/manna_white.svg'),
                                      ),
                                      applicationName: packageInfo!.appName,
                                      applicationVersion: '${packageInfo!.version}+${packageInfo!.buildNumber}',
                                    ),
                                  );
                                },
                              ),
                              ActionChip(
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                tooltip: 'Terms of service',
                                label: const Text('ToS'),
                                avatar: const Icon(Icons.description_outlined),
                                onPressed: () => launchUrlString(Config.current.getServerEndpoint('terms')),
                              ),
                              ActionChip(
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                tooltip: 'Privacy Policy',
                                label: const Text('Privacy Policy'),
                                avatar: const Icon(Icons.policy_outlined),
                                onPressed: () => launchUrlString(Config.current.getServerEndpoint('privacy')),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildListTile({
    required String title,
    required IconData icon,
    required VoidCallback onTap,
    String? subtitle,
    Widget? trailing,
  }) {
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: subtitle != null ? Text(subtitle) : null,
        trailing: trailing,
        onTap: onTap,
      ),
    );
  }
}

class CountrySelectionBottomSheet extends StatefulWidget {
  const CountrySelectionBottomSheet({super.key});

  @override
  State<CountrySelectionBottomSheet> createState() => _CountrySelectionBottomSheetState();
}

class _CountrySelectionBottomSheetState extends State<CountrySelectionBottomSheet> {
  List<CountryModel> countries = [];
  List<CountryModel> filteredCountries = [];
  final searchController = TextEditingController();
  bool isLoading = true;

  // currency code: order
  final Map<String, int> priority = {
    'United States': 0,
    'Canada': 1,
    'United Kingdom': 2,
    'Japan': 3,
    'Germany': 4,
    'China': 5,
    'Australia': 6,
    'India': 7,
  };

  @override
  void initState() {
    initData();
    super.initState();
  }

  Future<void> initData() async {
    final json = await rootBundle.loadString('assets/data/country.json');
    countries = (jsonDecode(json) as List).map((e) => CountryModel.fromMap(e)).toList();
    filteredCountries = countries.toList();
    sortCountries();
    isLoading = false;
    update();
  }

  void sortCountries() => filteredCountries.sort((a, b) {
    final priorityA = priority[a.name];
    final priorityB = priority[b.name];
    if (priorityA != null && priorityB != null) {
      return priorityA.compareTo(priorityB);
    }
    if (priorityA != null) {
      return -1;
    }
    if (priorityB != null) {
      return 1;
    }
    return a.name.compareTo(b.name);
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: context.keyboardPadding,
      child: SizedBox(
        height: 450,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: TextFormField(
                controller: searchController,
                onChanged: (String value) {
                  filteredCountries.clear();
                  if (value.isEmpty) {
                    filteredCountries = countries.toList();
                  } else {
                    final lowerCaseValue = value.toLowerCase();
                    filteredCountries = countries.where((e) {
                      return e.name.toLowerCase().contains(lowerCaseValue) ||
                          e.nameOfficial.toLowerCase().contains(lowerCaseValue) ||
                          e.currencyName.toLowerCase().contains(lowerCaseValue) ||
                          e.currencyCode.toLowerCase().contains(lowerCaseValue);
                    }).toList();
                  }
                  sortCountries();
                  update();
                },
                decoration: const InputDecoration(hintText: 'Search Country or Currency'),
              ),
            ),
            Expanded(
              child: isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : filteredCountries.isEmpty
                  ? const Center(child: Text('No countries found'))
                  : ListView.builder(
                      itemCount: filteredCountries.length,
                      itemBuilder: (context, index) {
                        final country = filteredCountries[index];
                        return ListTile(
                          onTap: () => AppRouter.pop(country),
                          title: Text(country.name),
                          trailing: Text(
                            country.currencySymbol,
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text(country.currencyName),
                          leading: SvgPicture.asset(
                            'assets/flags/${country.countryFlag}',
                            fit: BoxFit.fitWidth,
                            width: 36,
                            placeholderBuilder: (BuildContext context) => const CircularProgressIndicator(),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }
}
