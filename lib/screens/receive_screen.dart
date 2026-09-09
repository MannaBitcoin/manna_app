import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:battery_optimization_helper/battery_optimization_helper.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:manna/app_state.dart';
import 'package:manna/config.dart';
import 'package:manna/globals.dart';
import 'package:manna/models/account.dart';
import 'package:manna/models/bolt12_offer.dart';
import 'package:manna/models/boltz_fees.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/account_detail_screen.dart';
import 'package:manna/services/boltz_service.dart';
import 'package:manna/services/clipboard_service.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/db_service.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/services/notification_service.dart';
import 'package:manna/services/transaction_service.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/constants.dart';
import 'package:manna/utils/de_bouncer.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/utils/sats_extension.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/util.dart';
import 'package:manna/widgets/amount_text.dart';
import 'package:manna/widgets/fees_tile.dart';
import 'package:manna_core/manna_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

enum TabType { lightning, bolt12, liquid, bitcoin }

class ReceiveScreen extends StatefulWidget {
  const ReceiveScreen({super.key});

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> with SingleTickerProviderStateMixin {
  AppLifecycleListener? lifecycleListener;
  TraType traType = TraType.lnToLbtc;
  String? userName;
  bool isCustomizing = false;
  ({String address, int amount, String memo, bool senderPayFee})? lastLightningQrConfig,
      lastLiquidQrConfig,
      lastBtcQrConfig;
  final fiatAmountController = TextEditingController(),
      satAmountController = TextEditingController(),
      memoController = TextEditingController();
  int amount = 0;

  final feeExpansionController = ExpansibleController();
  FeesAndAmounts? calculations;
  final feeBuildingDeBouncer = DeBouncer(const Duration(milliseconds: 200));
  bool isSenderPayFee = false;

  bool showNotificationError = false;
  Timer? updateDevicesTimer;

  bool isTabSelectionVisible = false;
  bool isBTCWarningShown = false;
  TabType selectedTab = TabType.lightning;
  final pageController = PageController();
  bool isAnimatingPage = false;

  bool isBolt12SetupCompleted = false;

  @override
  void initState() {
    final wallet = selectedWallet;
    userName ??= wallet.metaData?.userName;
    lifecycleListener = AppLifecycleListener(onResume: () => refreshBatteryOptimizationStatus(fromResume: true));

    Future(() async {
      // fetch liquid address
      final address = await selectedAccount.currentWallet.getConfidentialAddress();
      if (address != null) {
        lastLiquidQrConfig = (address: address, amount: 0, memo: '', senderPayFee: isSenderPayFee);
      }

      // to ensure we have username
      if (DB.activeAccounts.map((acc) => acc.currentWallet).nonNulls.any((w) => w.metaData == null)) {
        await DbService.syncWalletData(network: Config.network);
      }

      if (wallet.type == WalletType.watchOnly) {
        await DbService.upsertWallets({wallet: {}});
        updateDevicesTimer = Timer.periodic(const Duration(minutes: 2), (timer) {
          DbService.upsertWallets({wallet: {}});
        });
      }
    });
    GlobalListener.addListener(
      stream: .account,
      listenerName: runtimeType.toString(),
      callback: (data) {
        update(() => userName ??= selectedWallet.metaData?.userName);
        return true;
      },
    );
    refreshBatteryOptimizationStatus();
    super.initState();
  }

  @override
  void dispose() {
    FocusManager.instance.primaryFocus?.unfocus();
    WakelockPlus.disable();
    lifecycleListener?.dispose();
    GlobalListener.removeListener(stream: .account, listenerName: runtimeType.toString());
    fiatAmountController.dispose();
    satAmountController.dispose();
    memoController.dispose();
    pageController.dispose();
    super.dispose();
  }

  void refreshBatteryOptimizationStatus({bool fromResume = false}) async {
    if (AppState.trustMinimizedLNURLAccounts.contains(selectedAccountId) ||
        AppState.trustMinimizedBolt12Accounts.contains(selectedAccountId)) {
      showNotificationError = !await NotificationService.isPermissionGranted();
      showNotificationError = (await NotificationService.getFCMToken() ?? '').isEmpty;
      if (!showNotificationError && Platform.isAndroid) {
        showNotificationError = fromResume
            ? await BatteryOptimizationHelper.isBatteryOptimizationEnabled()
            : !await BatteryOptimizationHelper.ensureOptimizationDisabled();
      }
      postFrameCallBack(() => update());
    }
  }

  Widget buildSegment({required IconData icon, required String text, String? svgImageName}) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [
        if (svgImageName != null)
          SvgPicture.asset(
            'assets/images/$svgImageName.svg',
            height: 20,
            colorFilter: ColorFilter.mode(
              context.themedColor(bright: Colors.black, dark: Colors.white),
              BlendMode.srcATop,
            ),
          )
        else
          Icon(icon, size: 20),
        Flexible(
          child: FittedBox(fit: BoxFit.scaleDown, child: Text(text)),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (calculations == null || calculations!.receiveAmount <= 0) {
      postFrameCallBack(() => feeExpansionController.collapse());
    }
    final w = selectedWallet;
    final isBolt12Supported = Config.isBolt12ReceiveEnabled;
    final bolt12Offer = DB.bolt12Offers.values
        .where((bo) => bo.walletType == w.type && bo.walletId == w.uuid)
        .firstOrNull;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Receive'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Tooltip(
              message: 'Change protocol',
              child: TextButton.icon(
                onPressed: () => update(() => isTabSelectionVisible = true),
                style: TextButton.styleFrom(
                  // pulled from CupertinoSlidingSegmentedControl
                  backgroundColor: context.themedColor(
                    bright: const Color.fromARGB(30, 118, 118, 128),
                    dark: const Color(0xFF636366),
                  ),
                  visualDensity: VisualDensity.compact,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadiusGeometry.circular(8)),
                ),
                iconAlignment: IconAlignment.end,
                icon: selectedTab == TabType.liquid
                    ? SvgPicture.asset(
                        'assets/images/liquid.svg',
                        fit: BoxFit.fitHeight,
                        height: 20,
                        colorFilter: ColorFilter.mode(
                          context.themedColor(bright: Colors.black, dark: Colors.white),
                          BlendMode.srcATop,
                        ),
                      )
                    : Icon(switch (selectedTab) {
                        TabType.lightning => Icons.bolt,
                        TabType.bolt12 => Icons.offline_bolt_outlined,
                        TabType.liquid => Icons.liquor,
                        TabType.bitcoin => Icons.currency_bitcoin,
                      }, color: context.themedColor(bright: Colors.black, dark: Colors.white)),
                label: Text(
                  switch (selectedTab) {
                    TabType.lightning => 'Lightning',
                    TabType.bolt12 => 'Bolt12',
                    TabType.liquid => 'Liquid',
                    TabType.bitcoin => 'BTC',
                  },
                  style: TextStyle(
                    color: context.themedColor(bright: Colors.black, dark: Colors.white),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (isTabSelectionVisible)
            Padding(
              padding: const EdgeInsets.all(16),
              child: CupertinoSlidingSegmentedControl(
                groupValue: selectedTab,
                onValueChanged: (val) => selectTab(val ?? TabType.lightning),
                children: {
                  TabType.lightning: buildSegment(icon: Icons.bolt, text: 'Lightning'),
                  if (isBolt12Supported)
                    TabType.bolt12: buildSegment(icon: Icons.offline_bolt_outlined, text: 'Bolt12'),
                  TabType.liquid: buildSegment(icon: Icons.liquor, text: 'Liquid', svgImageName: 'liquid'),
                  TabType.bitcoin: buildSegment(icon: Icons.currency_bitcoin, text: 'BTC'),
                },
                padding: const EdgeInsets.all(8),
              ),
            ),
          Expanded(
            child: PageView(
              controller: pageController,
              onPageChanged: (value) => selectTab(
                isBolt12Supported && value == 1
                    ? TabType.bolt12
                    : switch (value) {
                        1 => TabType.liquid,
                        2 => TabType.bitcoin,
                        _ => TabType.lightning,
                      },
              ),
              children: [
                Center(child: lightningPage()),
                if (isTabSelectionVisible) ...[
                  if (isBolt12Supported) Center(child: bolt12Page(bolt12Offer)),
                  Center(child: liquidPage()),
                  Center(child: btcPage()),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  void selectTab(TabType tab) async {
    if (isAnimatingPage) return;

    if (tab == TabType.bitcoin) {
      if (!isBTCWarningShown && mounted) {
        final chainPair = BoltzFees.getChainFeesAndLimits();
        final minimum = chainPair.btcLimits.minimal;
        final maximum = chainPair.btcLimits.maximal;

        final res = await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Advanced Layer-1 Transaction:'),
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              spacing: 12,
              children: [
                const Text('Please review before you proceed:', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox.shrink(),
                const Text.rich(
                  TextSpan(
                    text: 'Single-use address\n',
                    children: [
                      TextSpan(
                        text: 'This address can only be used once. Additional payments to this address may be lost.',
                        style: TextStyle(fontWeight: FontWeight.normal),
                      ),
                    ],
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox.shrink(),
                const Text.rich(
                  TextSpan(
                    text: 'Pay within 24 hours\n',
                    children: [
                      TextSpan(
                        text: 'After 24 hours, a refund will require a transaction fee.',
                        style: TextStyle(fontWeight: FontWeight.normal),
                      ),
                    ],
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox.shrink(),
                Text(
                  'Send between '
                  '${getSatInBitcoinStyle(minimum)} (${minimum.satsToFiat().formatFiat()})'
                  ' and '
                  '${getSatInBitcoinStyle(maximum)} (${maximum.satsToFiat().formatFiat()})'
                  ' or additional steps may be required.',
                ),
                const SizedBox.shrink(),
                Text.rich(
                  TextSpan(
                    text: 'For simple transactions, we recommend using Lightning ',
                    children: [
                      TextSpan(
                        text: '[switch to Lightning]',
                        style: TextStyle(color: Colors.blue.shade600),
                        recognizer: TapGestureRecognizer()
                          ..onTap = () {
                            traType = TraType.lnToLbtc;
                            isCustomizing = false;
                            fiatAmountController.clear();
                            satAmountController.clear();
                            memoController.clear();
                            amount = 0;
                            rebuildFees();
                            AppRouter.pop(1);
                          },
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => AppRouter.pop(0), child: const Text('Cancel')),
              TextButton(onPressed: () => AppRouter.pop(2), child: const Text('I understand')),
            ],
          ),
        );
        if (res is! int) return;
        if (res == 0) {
          // ignore: parameter_assignments
          tab = tab == TabType.bitcoin ? TabType.liquid : tab;
        } else if (res == 1) {
          // ignore: parameter_assignments
          tab = TabType.lightning;
        } else if (res == 2) {
          isBTCWarningShown = true;
          update(
            () => isCustomizing =
                lastBtcQrConfig == null ||
                lastBtcQrConfig!.amount != amount ||
                lastBtcQrConfig!.memo != memoController.text.trim(),
          );
        }
      }
    }
    final w = selectedWallet;
    if (tab == TabType.bolt12 &&
        DB.bolt12Offers.values.where((bo) => bo.walletType == w.type && bo.walletId == w.uuid).isEmpty) {
      unawaited(
        BoltzService.setupBolt12(w).then(
          (value) => update(() => isBolt12SetupCompleted = true),
          onError: (e, s) {
            update(() => isBolt12SetupCompleted = true);
            logE(e, stackTrace: s);
          },
        ),
      );
    }
    selectedTab = tab;
    traType = switch (tab) {
      TabType.lightning => TraType.lnToLbtc,
      TabType.bolt12 => TraType.lnToLbtc,
      TabType.liquid => TraType.lbtcToLbtcReceive,
      TabType.bitcoin => TraType.btcToLbtc,
    };
    if (traType == TraType.lbtcToLbtcReceive && lastLiquidQrConfig != null) {
      lastLiquidQrConfig = (
        address: lastLiquidQrConfig!.address,
        amount: amount,
        memo: memoController.text.trim(),
        senderPayFee: false,
      );
    }

    final expectedPageIndex = Config.isBolt12ReceiveEnabled
        ? selectedTab.index
        : switch (selectedTab) {
            TabType.lightning => 0,
            TabType.bolt12 => 0,
            TabType.liquid => 1,
            TabType.bitcoin => 2,
          };
    if (expectedPageIndex != (pageController.page?.toInt() ?? 0)) {
      isAnimatingPage = true;
      unawaited(
        pageController
            .animateToPage(expectedPageIndex, duration: const Duration(milliseconds: 300), curve: Curves.fastOutSlowIn)
            .then((value) => isAnimatingPage = false),
      );
    }
    isCustomizing = shouldBlurQr;
    update();
  }

  Widget lightningPage() {
    String? qrData;
    if (lastLightningQrConfig != null) {
      qrData = TransactionService.createBIP21Address(
        address: lastLightningQrConfig!.address,
        type: TraType.lnToLbtc,
        amount: lastLightningQrConfig!.amount,
        memo: lastLightningQrConfig!.memo,
      );
    } else if (!showNotificationError && userName != null && Config.network != Network.testnet) {
      qrData = userName!.toMannaLNURL();
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 600),
      child: SingleChildScrollView(
        reverse: true,
        padding: const EdgeInsets.all(16),
        child: Column(
          spacing: 8,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (qrData != null) qrWidget(qrData),
            if (lastLightningQrConfig == null) ...[
              if (showNotificationError)
                Builder(
                  builder: (context) {
                    final service = AppState.trustMinimizedLNURLAccounts.contains(selectedAccountId)
                        ? 'LNURL'
                        : 'Bolt12';
                    return Text(
                      "When the trust minimisation for $service is enabled,\nManna uses notifications extensively. Without notification permission you can't receive via $service!\nPlease provide notification permission manually!${Platform.isAndroid ? '\nYou also have to disable battery optimisation and any manufacture specific optimisation along with enabling auto start.' : ''}",
                      style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w500),
                      textAlign: TextAlign.center,
                    );
                  },
                )
              else if (userName != null)
                PopupMenuButton(
                  tooltip: 'Change username',
                  position: PopupMenuPosition.under,
                  onSelected: (value) {
                    if (value == 1) {
                      AppRouter.push(AccountDetailScreen(accountId: selectedAccountId));
                    }
                  },
                  itemBuilder: (BuildContext context) => [
                    const PopupMenuItem(value: 1, child: Text('Change username')),
                  ],
                  child: Padding(
                    padding: const EdgeInsetsGeometry.symmetric(vertical: 4),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        userName!.toMannaLNURL(),
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                )
              else if (Config.network == Network.testnet)
                Text(
                  'LNURL is not supported on ${Config.network.name} network',
                  style: const TextStyle(color: Colors.red, fontSize: 16),
                  textAlign: TextAlign.center,
                )
              else
                const Center(child: CircularProgressIndicator()),
            ],
            if (qrData != null) buttons(qrData),
            ...customizingWidgets(),
          ],
        ),
      ),
    );
  }

  Widget bolt12Page(Bolt12Offer? offer) {
    if (offer == null) {
      if (isBolt12SetupCompleted) {
        return const Text('Bolt12 not supported!');
      } else {
        return const CircularProgressIndicator();
      }
    }
    final qrData = offer.offer;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 600),
      child: SingleChildScrollView(
        reverse: true,
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            qrWidget(qrData),
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 16, left: 16, right: 16),
              child: Text(
                'bitcoin:?lno=${offer.offer.shortenAddress()}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.grey, fontSize: 15),
              ),
            ),
            buttons(qrData),
          ],
        ),
      ),
    );
  }

  Widget liquidPage() {
    if (lastLiquidQrConfig == null) {
      return const Column(
        spacing: 8,
        children: [CircularProgressIndicator(), Text('Failed to generate liquid address!')],
      );
    }
    final qrData = lastLiquidQrConfig!.amount > 0 || lastLiquidQrConfig!.memo.isNotEmpty
        ? TransactionService.createBIP21Address(
            address: lastLiquidQrConfig!.address,
            type: TraType.lbtcToLbtcReceive,
            amount: lastLiquidQrConfig!.amount,
            memo: lastLiquidQrConfig!.memo,
          )
        : lastLiquidQrConfig!.address;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 600),
      child: SingleChildScrollView(
        reverse: true,
        padding: const EdgeInsets.all(16),
        child: Column(
          spacing: 8,
          mainAxisSize: MainAxisSize.min,
          children: [
            qrWidget(qrData),
            if (lastLiquidQrConfig != null) ...amountNoteWidget(lastLiquidQrConfig!.amount, lastLiquidQrConfig!.memo),
            buttons(qrData),
            ...customizingWidgets(),
          ],
        ),
      ),
    );
  }

  Widget btcPage() {
    String? qrData;
    if (lastBtcQrConfig != null) {
      qrData = TransactionService.createBIP21Address(
        address: lastBtcQrConfig!.address,
        type: TraType.btcToLbtc,
        amount: lastBtcQrConfig!.amount,
        memo: lastBtcQrConfig!.memo,
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 600),
      child: SingleChildScrollView(
        reverse: true,
        padding: const EdgeInsets.all(16),
        child: Column(
          spacing: 8,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (qrData != null)
              qrWidget(qrData)
            else
              const Text(
                'Please enter amount first to create address for Layer-1 BTC',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.primaryColor),
                textAlign: TextAlign.center,
              ),
            if (lastBtcQrConfig != null) ...amountNoteWidget(lastBtcQrConfig!.amount, lastBtcQrConfig!.memo),
            if (qrData != null) buttons(qrData),
            ...customizingWidgets(),
          ],
        ),
      ),
    );
  }

  Widget qrWidget(String qrData) => SizedBox(
    width: (context.screenWidth * .85).clamp(300, 500),
    child: ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: 4, sigmaY: 4),
      enabled: shouldBlurQr && selectedTab != TabType.bolt12,
      child: Tooltip(
        message: 'copied',
        triggerMode: TooltipTriggerMode.tap,
        onTriggered: () => copyCurrentAddress(data: qrData),
        showDuration: const Duration(seconds: 2),
        child: Container(
          padding: EdgeInsets.zero,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade400),
            borderRadius: BorderRadius.circular(16),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: PrettyQrView.data(
              data: qrData,
              decoration: qrDecoration(qrData),
              errorCorrectLevel: qrData.length < 100 ? QrErrorCorrectLevel.M : QrErrorCorrectLevel.L,
            ),
          ),
        ),
      ),
    ),
  );

  List<Widget> customizingWidgets() {
    final isPaymentFeasible = (calculations?.receiveAmount ?? 0) > 0;
    return [
      const SizedBox.shrink(),
      if (!isCustomizing)
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => update(() => isCustomizing = true),
            icon: const Icon(Icons.edit),
            label: const Text('Customize'),
          ),
        )
      else ...[
        TextFormField(
          controller: fiatAmountController,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            hintText: '0.0',
            labelText: 'Amount',
            suffixIcon: Row(
              mainAxisSize: .min,
              mainAxisAlignment: .center,
              children: [Text(AppState.selectedCurrency.currencyCode)],
            ),
          ),
          onChanged: (value) async {
            amount = double.tryParse(value)?.fiatToSats() ?? 0;
            satAmountController.text = amount.toStringAsFixed(0);
            feeBuildingDeBouncer.call(() => rebuildFees());
          },
          maxLength: 8,
          inputFormatters: [FilteringTextInputFormatter.allow(Regexes.decimalFilter)],
          buildCounter: (context, {required currentLength, required isFocused, required maxLength}) => null,
        ),
        TextFormField(
          controller: satAmountController,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            hintText: '0',
            labelText: 'Amount',
            suffixIcon: Row(mainAxisSize: .min, mainAxisAlignment: .center, children: [Text(getBitcoinDisplayStyle())]),
          ),
          onChanged: (value) async {
            amount = int.tryParse(value) ?? 0;
            fiatAmountController.text = amount.satsToFiat().toStringAsFixed(2);
            feeBuildingDeBouncer.call(() => rebuildFees());
          },
          maxLength: 8,
          inputFormatters: [
            AppState.bitcoinDisplayStyle == 2
                ? FilteringTextInputFormatter.allow(Regexes.btcInputFilter)
                : FilteringTextInputFormatter.digitsOnly,
          ],
          buildCounter: (context, {required currentLength, required isFocused, required maxLength}) => null,
        ),
        TextFormField(
          controller: memoController,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(labelText: 'Memo'),
          keyboardType: TextInputType.multiline,
          textCapitalization: TextCapitalization.sentences,
          maxLines: 3,
          minLines: 1,
          maxLength: 500,
          buildCounter: (context, {required currentLength, required isFocused, required maxLength}) => null,
        ),
        if (traType != TraType.lbtcToLbtcReceive)
          CheckboxListTile(
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            value: isSenderPayFee,
            onChanged: (value) {
              isSenderPayFee = value!;
              rebuildFees();
            },
            title: const Text('Charge fees to sender'),
          ),
        ListTileTheme(
          minVerticalPadding: 0,
          child: ExpansionTile(
            controller: feeExpansionController,
            title: feeExpansionController.isExpanded
                ? const Text('Fee Details', style: TextStyle(fontSize: 16))
                : FeesTile(
                    amountSat: !isPaymentFeasible
                        ? 0
                        : isSenderPayFee
                        ? calculations!.sendAmount
                        : calculations!.receiveAmount,
                    title: isSenderPayFee ? 'Sender pays' : 'You will receive',
                  ),
            minTileHeight: 0,
            shape: const Border(),
            tilePadding: EdgeInsets.only(top: 8, bottom: !feeExpansionController.isExpanded ? 8 : 0),
            enabled: isPaymentFeasible,
            children: [
              InkWell(
                onTap: () => feeExpansionController.collapse(),
                child: Column(
                  children: [
                    if (calculations != null) ...[
                      FeesTile(amountSat: calculations!.receiveAmount, title: 'Amount'),
                      if (calculations!.mannaFee > 0) FeesTile(amountSat: calculations!.mannaFee, title: 'Manna fee'),
                      if (calculations!.boltzFee > 0) FeesTile(amountSat: calculations!.boltzFee, title: 'Boltz fee'),
                      if (calculations!.boltzNetworkFee > 0)
                        FeesTile(amountSat: calculations!.boltzNetworkFee, title: 'Boltz network fee'),
                      if (calculations!.liquidNetworkFee > 0)
                        FeesTile(amountSat: calculations!.liquidNetworkFee, title: 'Network fee'),
                    ],
                    const Divider(),
                    FeesTile(
                      amountSat: !isPaymentFeasible
                          ? 0
                          : isSenderPayFee
                          ? calculations!.sendAmount
                          : calculations!.receiveAmount,
                      title: isSenderPayFee ? 'Sender pays' : 'You will receive',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: isPaymentFeasible && shouldBlurQr ? AppColors.primaryColor : Colors.white12,
              visualDensity: VisualDensity.standard,
            ),
            onPressed: shouldBlurQr ? () => generateInvoice() : null,
            icon: const Icon(Icons.qr_code, color: Colors.white),
            label: const Text('Generate', style: TextStyle(fontSize: 16, color: Colors.white)),
          ),
        ),
        const SizedBox(height: 8),
      ],
    ];
  }

  Widget buttons(String data) {
    if (!shouldBlurQr && !isCustomizing) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          spacing: 8,
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => copyCurrentAddress(data: data),
                icon: const Icon(Icons.copy),
                label: const Text('Copy'),
              ),
            ),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => shareCurrentAddress(data: data),
                icon: const Icon(Icons.share),
                label: const Text('Share'),
              ),
            ),
          ],
        ),
      );
    }
    return const SizedBox.shrink();
  }

  List<Widget> amountNoteWidget(int amount, String note) {
    return [
      if (!isCustomizing)
        Column(
          spacing: 4,
          children: [
            if (amount > 0)
              Text(
                '${amount.satsToFiat().formatFiat()} (${getSatInBitcoinStyle(amount)})',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            if (note.isNotEmpty) Text(note, style: const TextStyle(fontSize: 16)),
          ],
        ),
    ];
  }

  bool get shouldBlurQr => switch (traType) {
    TraType.lnToLbtc =>
      (amount != 0 && lastLightningQrConfig?.amount != amount) ||
          (memoController.text.trim().isNotEmpty && lastLightningQrConfig?.memo != memoController.text.trim()) ||
          (lastLightningQrConfig != null && lastLightningQrConfig!.senderPayFee != isSenderPayFee),
    TraType.lbtcToLbtcReceive =>
      lastLiquidQrConfig == null ||
          (lastLiquidQrConfig!.amount != amount || lastLiquidQrConfig!.memo != memoController.text.trim()),
    TraType.btcToLbtc =>
      lastBtcQrConfig == null ||
          (lastBtcQrConfig!.amount != amount ||
              lastBtcQrConfig!.memo != memoController.text.trim() ||
              (lastBtcQrConfig!.senderPayFee != isSenderPayFee)),
    TraType.lbtcToLbtcSend || TraType.lbtcToBtc || TraType.lbtcToLN => false,
  };

  Future<void> copyCurrentAddress({required String data}) async {
    await ClipboardService.setClipBoard(data, 'Copied');
    if (mounted) {
      FocusScope.of(context).unfocus();
    }
  }

  Future<void> shareCurrentAddress({required String data}) async {
    try {
      final qrImageBytes = await QrImage(
        QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M),
      ).toImageAsBytes(size: 512, decoration: qrDecoration(data));

      if (qrImageBytes != null) {
        final tempDir = await getTemporaryDirectory();
        final file = File('${tempDir.path}/qr_image.png');
        await file.create();
        await file.writeAsBytes(qrImageBytes.buffer.asUint8List());
        if (mounted) {
          await SharePlus.instance.share(
            ShareParams(files: [XFile(file.path)], text: data, sharePositionOrigin: context.sharePlusRect),
          );
        }
      }
    } catch (e, s) {
      logE(e, stackTrace: s, showToast: true);
    }
  }

  Future<void> generateInvoice() async {
    FocusScope.of(context).unfocus();
    final memo = memoController.text.trim();
    if (traType == TraType.lnToLbtc &&
        lastLightningQrConfig != null &&
        lastLightningQrConfig!.amount == amount &&
        lastLightningQrConfig!.memo == memo &&
        lastLightningQrConfig!.senderPayFee == isSenderPayFee) {
      isCustomizing = false;
      return update();
    }
    if (traType == TraType.btcToLbtc &&
        lastBtcQrConfig != null &&
        lastBtcQrConfig!.amount == amount &&
        lastBtcQrConfig!.senderPayFee == isSenderPayFee) {
      lastBtcQrConfig = (address: lastBtcQrConfig!.address, amount: amount, memo: memo, senderPayFee: isSenderPayFee);
      isCustomizing = false;
      return update();
    }
    if (traType == TraType.lbtcToLbtcReceive && lastLiquidQrConfig != null) {
      lastLiquidQrConfig = (address: lastLiquidQrConfig!.address, amount: amount, memo: memo, senderPayFee: false);
      isCustomizing = false;
      return update();
    }

    try {
      startLoader();
      final addressData = await TransactionService.generateQrData(
        account: selectedAccount,
        amount: amount,
        type: traType,
        memo: memo,
        asBIP21: false,
        doesSenderPayFee: isSenderPayFee,
      );

      if (addressData != null) {
        isCustomizing = false;
        if (traType == TraType.lnToLbtc) {
          lastLightningQrConfig = (address: addressData, amount: amount, memo: memo, senderPayFee: isSenderPayFee);
        } else if (traType == TraType.btcToLbtc) {
          lastBtcQrConfig = (address: addressData, amount: amount, memo: memo, senderPayFee: isSenderPayFee);
        } else if (traType == TraType.lbtcToLbtcReceive) {
          lastLiquidQrConfig = (address: addressData, amount: amount, memo: memo, senderPayFee: isSenderPayFee);
        }
      }

      update();

      // enable wake lock so screen stays on until we leave this screen
      if (addressData != null) {
        await WakelockPlus.enable();
      }
    } catch (e, s) {
      logE(e, stackTrace: s, showToast: true);
    } finally {
      stopLoader();
    }
  }

  Future<void> rebuildFees() async {
    calculations = await calculateFeeAndAmounts(
      wallet: selectedWallet,
      amount: amount,
      type: traType,
      isAmountTarget: isSenderPayFee,
    );
    update();
  }
}

// class WriteNFCTagDialog extends StatefulWidget {
//   const WriteNFCTagDialog({required this.data, super.key});
//
//   final String data;
//
//   @override
//   State<WriteNFCTagDialog> createState() => _WriteNFCTagDialogState();
// }

// class _WriteNFCTagDialogState extends State<WriteNFCTagDialog> {
//   bool isScanning = false;
//   String status = '';
//
//   @override
//   void initState() {
//     startNFCWrite(widget.data);
//     super.initState();
//   }
//
//   Future<void> startNFCWrite(String data) async {
//     try {
//       isScanning = true;
//       status = Platform.isIOS
//           ? 'Hold a writable NFC card near the top of your iPhone...'
//           : 'Hold a writable NFC card near the back of your device...';
//       update();
//
//       await NfcService.writeNFCTag(data, ({isScanning, status}) {
//         this.isScanning = isScanning ?? this.isScanning;
//         this.status = status ?? this.status;
//         update();
//       });
//     } catch (e) {
//       isScanning = false;
//       status = 'Error starting NFC write: $e';
//       update();
//     }
//   }
//
//   @override
//   Widget build(BuildContext context) {
//     return AlertDialog(
//       title: const Text('Write to NFC tag'),
//       content: Column(
//         spacing: 16,
//         mainAxisSize: MainAxisSize.min,
//         children: [if (isScanning) const CircularProgressIndicator(), Text(status)],
//       ),
//       actions: [TextButton(onPressed: () => AppRouter.pop(), child: const Text('close'))],
//     );
//   }
// }
