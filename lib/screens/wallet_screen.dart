import 'dart:async';

import 'package:breez_sdk_spark_flutter/breez_sdk_spark.dart' show GetSparkStatusRequest, getSparkStatus, ServiceStatus;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lottie/lottie.dart';
import 'package:manna/app_state.dart';
import 'package:manna/globals.dart';
import 'package:manna/models/account.dart';
import 'package:manna/models/chat_message.dart';
import 'package:manna/models/transaction.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/all_transaction_screen.dart';
import 'package:manna/screens/backup_reminder_screen.dart';
import 'package:manna/screens/contact_screen.dart';
import 'package:manna/screens/liquid_wallet_screen.dart';
import 'package:manna/screens/menu_screen.dart';
import 'package:manna/screens/receive_screen.dart';
import 'package:manna/screens/send_screen.dart';
import 'package:manna/screens/shop_screen.dart';
import 'package:manna/screens/trade_screen.dart';
import 'package:manna/screens/unclaimed_deposits_screen.dart';
import 'package:manna/screens/wallet_management_screen.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/deep_link_service.dart';
import 'package:manna/services/hints_service.dart';
import 'package:manna/services/lnurl_service.dart';
import 'package:manna/services/notification_service.dart';
import 'package:manna/services/wallet_service.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/constants.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/util.dart';
import 'package:manna/widgets/amount_text.dart';
import 'package:manna/widgets/shimmer.dart';
import 'package:manna/widgets/text_scramble.dart';
import 'package:manna/widgets/transaction_card.dart';
import 'package:manna_core/manna_core.dart';

class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});

  @override
  WalletScreenState createState() => WalletScreenState();
}

class WalletScreenState extends State<WalletScreen> {
  final dragController = DraggableScrollableController();
  bool shouldHandleScrollEvent = false;
  final FocusNode dropDownFocusNode = FocusNode();
  List<Transaction> txItems = []; // transaction or exchange order
  StreamSubscription? conversationSubscription;
  final pageController = PageController();
  int pageIndex = 0;
  ValueNotifier<String?> scrambledHint = ValueNotifier(null);
  bool isTradePageChartPanning = false;

  bool canPop = true;

  ServiceStatus? sparkStatus;

  void refreshData({bool updateFrame = true}) {
    final txs = DB.transactions.values.where((t) => t.walletId == selectedWallet.uuid).toList();
    txs.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    txItems = txs.take(25).toList();
    if (updateFrame) update();
  }

  @override
  void initState() {
    NotificationService.setChatActiveUUID(null);
    NotificationService.handleInitialNotification();

    DeepLinkService.startListening();
    DeepLinkService.handleInitialData();

    refreshData(updateFrame: false);
    processLNURLSuccessActionAllTransactions();

    GlobalListener.addListener(
      stream: .account,
      listenerName: runtimeType.toString(),
      callback: (data) {
        if (data is String) {
          if (data == selectedAccountId) {
            refreshData();
          }
        } else {
          refreshData();
        }
        return true;
      },
    );

    conversationSubscription = DB.conversationsBox.watch().listen((_) => update());

    walletBackupReminder();

    dragController.addListener(() {
      final prevCanPop = canPop;
      canPop = !dragController.isAttached || dragController.size < 0.8;
      if (prevCanPop != canPop) update();
    });

    Future(() async {
      sparkStatus = (await getSparkStatus(request: const GetSparkStatusRequest())).status;
    });

    Future(() {
      if (!AppState.prefs.containsKey('didUserKnowLiquidWalletIsMoved') && AppState.prefs.containsKey('isFirstBoot')) {
        postFrameCallBack(() {
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Manna is now Spark Wallet'),
              content: Text.rich(
                TextSpan(
                  text:
                      "Spark is a Layer 2 protocol that makes Lightning payments hassle-free while maintaining self-custody of your funds. Don't worry—your old wallet is still accessible ",
                  children: [
                    TextSpan(
                      text: '[here]',
                      style: TextStyle(
                        decoration: TextDecoration.underline,
                        color: Colors.blue.shade600,
                        decorationColor: Colors.blue.shade600,
                      ),
                      recognizer: TapGestureRecognizer()
                        ..onTap = () => AppRouter.push(LiquidWalletScreen(wallet: selectedWallet)),
                    ),
                    const TextSpan(
                      text:
                          ".\nIf you want to spend your old L-BTC, you can import your wallet's seed phrase into any Liquid-compatible app (such as Blockstream Green or Bull Bitcoin).",
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  child: const Text('Acknowledge'),
                  onPressed: () {
                    AppRouter.pop();
                    AppState.prefs.setBool('didUserKnowLiquidWalletIsMoved', true);
                  },
                ),
              ],
            ),
          );
        });
      }

      if (!AppState.prefs.containsKey('isFirstBoot')) {
        AppState.prefs.setBool('isFirstBoot', true);
      } else {
        AppState.prefs.setBool('isFirstBoot', false);
      }
    });

    super.initState();
  }

  void walletBackupReminder() async {
    if (!AppState.isAuthenticated) return;
    final nonBackedUpAccounts = DB.activeAccounts.where(
      (acc) => !acc.isBackedUp && DB.allWallets.where((w) => w.accountId == acc.id && w.balance > 0).isNotEmpty,
    );
    if (nonBackedUpAccounts.isEmpty) return;

    if (DateTime.now()
            .difference(DateTime.fromMillisecondsSinceEpoch(AppState.prefs.getInt('lastWalletBackUpReminder') ?? 0))
            .inDays >
        1) {
      await Future.delayed(const Duration(seconds: 2));
      for (final acc in nonBackedUpAccounts) {
        unawaited(AppRouter.push(BackupReminderScreen(account: acc)));
      }
      await AppState.prefs.setInt('lastWalletBackUpReminder', DateTime.now().millisecondsSinceEpoch);
    }
  }

  @override
  void dispose() {
    // don't remove listener from globalListener, we will override new one,
    // cause most of the time, init state is called first for new page and then old page is disposed,
    // removing the listener
    conversationSubscription?.cancel();
    dragController.dispose();
    pageController.dispose();
    scrambledHint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentWallet = selectedWallet;
    final currentAccount = selectedAccount;
    final shouldShowUnreadMessagesBadge = DB.conversationsBox.values
        .where((e) => e.unreadCount > 0 && e.myUUID == currentAccount.currentWallet.uuid)
        .isNotEmpty;

    // bottomSheetHeight + 48 (extra margin to container on top to make send and receive button clickable)
    // The parsing and precision pruning is the only way to stop constant rebuilds of this page.
    final screenHeight = context.screenHeight - MediaQuery.paddingOf(context).vertical;
    final minBottomSheetHeight = (screenHeight / 3).clamp(100.0, 300.0) + 48.0;
    final baseMinSize = minBottomSheetHeight / screenHeight;

    final double baseMaxSize = dragController.isAttached
        ? dragController.pixelsToSize(140 + (txItems.length < 2 ? 140 : txItems.length * 64.0))
        : baseMinSize;

    final double stableMinChildSize = baseMinSize.clamp(0.0, 1.0);
    final double stableMaxChildSize = baseMaxSize.clamp(stableMinChildSize, 1.0);
    final maxSizeTillConstPadding = dragController.isAttached ? 1.0 - dragController.pixelsToSize(48) : 1.0;

    final dropdownAccounts = [
      ...DB.activeAccounts.where((w) => w.isMainAccount),
      ...DB.activeAccounts.where((w) => !w.isDisabled && !w.isMainAccount).toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder)),
    ];
    return PopScope(
      canPop: canPop,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          if (dragController.isAttached && dragController.size >= 0.8) {
            dragController.reset();
          }
        }
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          title: GestureDetector(
            onTap: () async {
              if (pageIndex == 1) {
                await pageController.animateToPage(
                  0,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                );
              } else if (dragController.isAttached && dragController.size >= 0.8) {
                dragController.reset();
              } else {
                update(() => scrambledHint.value = HintsService.getRandomHint());
              }
            },
            child: SvgPicture.asset(AppImages.logoWhiteAssetSVG, width: 70),
          ),
          actions: [
            Badge(
              isLabelVisible: shouldShowUnreadMessagesBadge,
              backgroundColor: Colors.white30,
              child: IconButton(
                onPressed: () async {
                  await AppRouter.push(ContactScreen(showMessagePage: shouldShowUnreadMessagesBadge));
                  await updateConversation();
                  update();
                },
                icon: const Icon(Icons.contacts_outlined, color: Colors.white),
                tooltip: 'Contacts/Messages',
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: () => AppRouter.push(const ShopScreen()),
              icon: SvgPicture.string(
                AppImages.storeSVG,
                colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
              ),
              tooltip: 'Shop',
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: () => AppRouter.push(const MenuScreen()),
              icon: const Icon(Icons.menu, color: Colors.white),
              tooltip: 'Menu',
            ),
            const SizedBox(width: 12),
          ],
          elevation: 0,
          backgroundColor: context.themedColor(bright: AppColors.primaryColor, dark: Colors.black),
        ),
        backgroundColor: context.themedColor(bright: AppColors.primaryColor, dark: Colors.black),
        body: PageView(
          controller: pageController,
          onPageChanged: (value) => update(() => pageIndex = value),
          physics: isTradePageChartPanning ? const NeverScrollableScrollPhysics() : null,
          children: [
            RefreshIndicator(
              onRefresh: () async {
                DB.loadAllData();
                await Future.any([
                  WalletService.sync(xpub: currentWallet.xpub),
                  Future.delayed(const Duration(seconds: 15)),
                ]);
                processLNURLSuccessActionAllTransactions();
                refreshData();
              },
              child: Stack(
                children: [
                  const Positioned.fill(child: SingleChildScrollView(physics: AlwaysScrollableScrollPhysics())),
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    bottom: minBottomSheetHeight,
                    child: Column(
                      children: [
                        Expanded(
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                DropdownButtonHideUnderline(
                                  child: DropdownButton<String>(
                                    focusNode: dropDownFocusNode,
                                    value: DB.activeAccounts.isNotEmpty ? selectedAccountId : null,
                                    onChanged: (value) {
                                      if (value?.isEmpty == true) {
                                        dropDownFocusNode.unfocus();
                                        AppRouter.push(const WalletManagementScreen());
                                      } else {
                                        if (value != selectedAccountId) {
                                          dragController.reset();
                                        }
                                        selectAccount(value);
                                        refreshData();
                                      }
                                    },
                                    focusColor: Colors.transparent,
                                    dropdownColor: context.themedColor(
                                      bright: AppColors.primaryColor,
                                      dark: AppColors.darkCardColor,
                                    ),
                                    iconEnabledColor: Colors.white,
                                    style: const TextStyle(
                                      fontSize: 18,
                                      letterSpacing: 1.1,
                                      fontWeight: FontWeight.w500,
                                    ),
                                    borderRadius: BorderRadius.circular(16),
                                    alignment: Alignment.center,
                                    icon: const SizedBox(),
                                    items: [
                                      ...dropdownAccounts.map(
                                        (acc) => DropdownMenuItem<String>(
                                          value: acc.id,
                                          enabled: acc.currentWallet.spark != null,
                                          child: Row(
                                            spacing: 12,
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(acc.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                                              Badge(
                                                isLabelVisible: DB.conversationsBox.values
                                                    .where(
                                                      (e) =>
                                                          e.unreadCount > 0 &&
                                                          e.myUUID == acc.currentWallet.uuid &&
                                                          acc.currentWallet.type == WalletType.full,
                                                    )
                                                    .isNotEmpty,
                                                backgroundColor: Colors.white38,
                                                smallSize: 8,
                                              ),
                                              if (acc.currentWallet.spark == null) ...[
                                                const Spacer(),
                                                const CircularProgressIndicator(color: Colors.white),
                                              ],
                                            ],
                                          ),
                                        ),
                                      ),
                                      DropdownMenuItem(
                                        value: '',
                                        child: Column(
                                          spacing: 8,
                                          crossAxisAlignment: .start,
                                          children: [
                                            Divider(color: AppColors.accentColor.withValues(alpha: 1)),
                                            const Row(
                                              spacing: 8,
                                              children: [
                                                Icon(Icons.settings_outlined, size: 15, color: Colors.white),
                                                Expanded(
                                                  child: Text(
                                                    'Manage wallets',
                                                    style: TextStyle(fontWeight: FontWeight.w400),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                    selectedItemBuilder: (context) => [
                                      ...dropdownAccounts.map(
                                        (acc) => SizedBox(
                                          width: 250,
                                          child: Row(
                                            mainAxisAlignment: .center,
                                            spacing: 8,
                                            children: [
                                              Flexible(
                                                child: Text(
                                                  acc.name,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontSize: 24,
                                                    fontWeight: FontWeight.w500,
                                                    color: Colors.white,
                                                    letterSpacing: 1.1,
                                                  ),
                                                ),
                                              ),
                                              Badge(
                                                isLabelVisible: shouldShowUnreadMessagesBadge,
                                                backgroundColor: Colors.white38,
                                                smallSize: 8,
                                              ),
                                              const Icon(Icons.arrow_drop_down_outlined, color: Colors.white),
                                            ],
                                          ),
                                        ),
                                      ),
                                      const SizedBox.shrink(),
                                    ],
                                  ),
                                ),
                                GestureDetector(
                                  onTap: () => update(() => AppState.isPrivacyModeOn = !AppState.isPrivacyModeOn),
                                  child: !AppState.isPrivacyModeOn
                                      ? AmountText(
                                          amountSat: currentWallet.balance,
                                          showFiat: true,
                                          btcStyle: TextStyle(
                                            fontSize: 48,
                                            color: context.themedColor(
                                              bright: Colors.white,
                                              dark: AppColors.primaryColor,
                                            ),
                                            fontWeight: FontWeight.bold,
                                          ),
                                          fiatStyle: const TextStyle(
                                            fontSize: 18,
                                            color: Colors.white70,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        )
                                      : Text(
                                          '*****',
                                          style: TextStyle(
                                            fontSize: 46,
                                            color: context.themedColor(
                                              bright: Colors.white,
                                              dark: AppColors.primaryColor,
                                            ),
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                ),

                                if (sparkStatus != null &&
                                    !{ServiceStatus.operational, ServiceStatus.unknown}.contains(sparkStatus))
                                  Text(switch (sparkStatus!) {
                                    ServiceStatus.degraded => 'Spark is experiencing degraded performance',
                                    ServiceStatus.partial => 'Spark is partially unavailable',
                                    ServiceStatus.major => 'Spark is experiencing a major outage',
                                    ServiceStatus.operational => throw UnimplementedError(),
                                    ServiceStatus.unknown => throw UnimplementedError(),
                                  }),
                                SizedBox(
                                  width: double.infinity,
                                  child: UnclaimedDepositsBanner(xpub: currentWallet.xpub, lightOnDark: true),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (!AppState.prefs.containsKey('didUserKnowAboutTradePage'))
                          Lottie.asset(AppLottie.swipeRight, height: 80, repeat: true),
                      ],
                    ),
                  ),
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: minBottomSheetHeight + 24,
                    child: ValueListenableBuilder(
                      valueListenable: scrambledHint,
                      builder: (context, value, child) {
                        if (value == null) return const SizedBox.shrink();
                        return TextScramble(
                          text: value,
                          onComplete: () => scrambledHint.value = null,
                          builder: (context, scrambledText) {
                            return Text(
                              scrambledText,
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 16, color: Colors.white60),
                            );
                          },
                        );
                      },
                    ),
                  ),
                  DraggableScrollableSheet(
                    controller: dragController,
                    minChildSize: stableMinChildSize,
                    initialChildSize: stableMinChildSize,
                    maxChildSize: stableMaxChildSize,
                    builder: (context, scrollController) {
                      return Stack(
                        children: [
                          AnimatedBuilder(
                            animation: dragController,
                            builder: (context, child) {
                              final currentSize = dragController.isAttached ? dragController.size : stableMinChildSize;
                              final padding = currentSize < maxSizeTillConstPadding
                                  ? 48.0
                                  : mapRange(
                                      currentSize,
                                      maxSizeTillConstPadding,
                                      stableMaxChildSize,
                                      48,
                                      0.0,
                                    ).clamp(0.0, 48.0);

                              return Padding(
                                padding: EdgeInsetsGeometry.only(top: padding),
                                child: child,
                              );
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              constraints: BoxConstraints(minHeight: minBottomSheetHeight - 48),
                              decoration: BoxDecoration(
                                color: context.themedColor(bright: Colors.white, dark: AppColors.darkCardColor),
                                borderRadius: const BorderRadius.only(
                                  topLeft: Radius.circular(16),
                                  topRight: Radius.circular(16),
                                ),
                              ),
                              child: NotificationListener<ScrollNotification>(
                                onNotification: (notification) {
                                  if (!isDesktop) {
                                    return false;
                                  }
                                  if (notification is ScrollStartNotification) {
                                    shouldHandleScrollEvent = notification.dragDetails?.kind != PointerDeviceKind.mouse;
                                    return true;
                                  }
                                  if (notification is ScrollEndNotification) {
                                    shouldHandleScrollEvent = false;
                                    return true;
                                  }
                                  if (shouldHandleScrollEvent && notification is ScrollUpdateNotification) {
                                    final pixels = notification.metrics.pixels + minBottomSheetHeight;
                                    dragController.jumpTo(dragController.pixelsToSize(pixels).clamp(0, 1));
                                    return true;
                                  }
                                  return false;
                                },
                                child: SingleChildScrollView(
                                  controller: scrollController,
                                  child: Column(
                                    children: [
                                      const SizedBox(height: 48 + 4),
                                      ShimmerWidget.fromColors(
                                        baseColor: context.themedColor(
                                          bright: AppColors.primaryColor,
                                          dark: Colors.white,
                                        ),
                                        highlightColor: context.themedColor(
                                          bright: Colors.grey.shade100,
                                          dark: AppColors.primaryColor,
                                        ),
                                        shimmerState: (WalletService.syncingState[currentWallet.xpub] ?? false)
                                            ? ShimmerState.running
                                            : ShimmerState.stopped,
                                        child: Row(
                                          children: [
                                            const Expanded(
                                              child: Text(
                                                'Transactions',
                                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                                              ),
                                            ),
                                            GestureDetector(
                                              onTap: () =>
                                                  AppRouter.push(AllTransactionScreen(accountId: selectedAccountId)),
                                              child: const Text(
                                                'view all',
                                                style: TextStyle(fontWeight: FontWeight.w500),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      if (txItems.isNotEmpty) ...[
                                        for (final e in txItems)
                                          // if (e is Transaction)
                                          TransactionCard(tx: e, hideAmount: AppState.isPrivacyModeOn),
                                        // else if (e is ExchangeOrder)
                                        //   TransactionCard(
                                        //     tx: Transaction.fromMap({}),
                                        //     exchangeOrder: e,
                                        //     hideAmount: AppState.isPrivacyModeOn,
                                        //   ),
                                        const SizedBox(height: 16),
                                      ] else
                                        const SizedBox(height: 100, child: Center(child: Text('No transactions yet!'))),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          AnimatedBuilder(
                            animation: dragController,
                            builder: (context, child) {
                              final currentSize = dragController.isAttached ? dragController.size : stableMinChildSize;
                              final opacity = mapRange(currentSize, stableMinChildSize, 0.8, 1.0, 0.0).clamp(0.0, 1.0);

                              if (opacity == 0) return const SizedBox.shrink();

                              return Positioned(
                                top: 0,
                                right: 32,
                                left: 32,
                                child: Opacity(opacity: opacity, child: child),
                              );
                            },
                            child: Row(
                              children: [
                                Expanded(
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: context.themedColor(bright: Colors.white, dark: AppColors.darkCardColor),
                                      borderRadius: BorderRadius.circular(12),
                                      boxShadow: [
                                        BoxShadow(
                                          color: context.themedColor(bright: Colors.black12, dark: Colors.black45),
                                          spreadRadius: 1,
                                          offset: const Offset(0, 2),
                                          blurRadius: 3,
                                        ),
                                      ],
                                    ),
                                    child: TextButton(
                                      style: ButtonStyle(
                                        shape: WidgetStateProperty.all(
                                          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                        ),
                                      ),
                                      onPressed: () => AppRouter.push(const ReceiveScreen()),
                                      child: Column(
                                        spacing: 6,
                                        children: [
                                          const SizedBox(height: 2),
                                          Image.asset(
                                            AppImages.receiveBitcoin,
                                            height: 28,
                                            width: 28,
                                            color: context.themedColor(
                                              bright: AppColors.primaryColor,
                                              dark: Colors.white,
                                            ),
                                          ),
                                          Text(
                                            'Receive',
                                            style: TextStyle(
                                              color: context.themedColor(
                                                bright: AppColors.primaryColor,
                                                dark: Colors.white,
                                              ),
                                              fontSize: 16,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: context.themedColor(bright: Colors.white, dark: AppColors.darkCardColor),
                                      borderRadius: BorderRadius.circular(12),
                                      boxShadow: [
                                        BoxShadow(
                                          color: context.themedColor(bright: Colors.black12, dark: Colors.black45),
                                          spreadRadius: 1,
                                          offset: const Offset(2, 2),
                                          blurRadius: 3,
                                        ),
                                      ],
                                    ),
                                    child: TextButton(
                                      style: ButtonStyle(
                                        shape: WidgetStateProperty.all(
                                          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                        ),
                                      ),
                                      onPressed: () => AppRouter.push(const SendScreen()),
                                      child: Column(
                                        spacing: 6,
                                        children: [
                                          const SizedBox(height: 2),
                                          Image.asset(
                                            AppImages.sendBitcoin,
                                            height: 28,
                                            width: 28,
                                            color: context.themedColor(
                                              bright: AppColors.primaryColor,
                                              dark: Colors.white,
                                            ),
                                          ),
                                          Text(
                                            'Send',
                                            style: TextStyle(
                                              color: context.themedColor(
                                                bright: AppColors.primaryColor,
                                                dark: Colors.white,
                                              ),
                                              fontSize: 16,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
            TradeScreen(
              onBack: () =>
                  pageController.animateToPage(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut),
              onPanning: (isPanning) {
                if (isTradePageChartPanning != isPanning) {
                  update(() => isTradePageChartPanning = isPanning);
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}
