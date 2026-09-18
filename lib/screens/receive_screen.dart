import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:manna/app_state.dart';
import 'package:manna/config.dart';
import 'package:manna/globals.dart';
import 'package:manna/models/account.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/account_detail_screen.dart';
import 'package:manna/services/clipboard_service.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/db_service.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/services/transaction_service.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/constants.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/utils/sats_extension.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/util.dart';
import 'package:manna/widgets/amount_text.dart';
import 'package:manna_core/manna_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

enum TabType { lightning, bitcoin }

class ReceiveScreen extends StatefulWidget {
  const ReceiveScreen({super.key});

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> with SingleTickerProviderStateMixin {
  TraType traType = TraType.lnToSpark;
  String? userName;
  bool isCustomizing = false;
  ({String address, int amount, String memo})? lastLightningQrConfig, lastBtcQrConfig;
  final fiatAmountController = TextEditingController(),
      satAmountController = TextEditingController(),
      memoController = TextEditingController();
  int amount = 0;

  bool isTabSelectionVisible = false;
  TabType selectedTab = TabType.lightning;
  final pageController = PageController();
  bool isAnimatingPage = false;

  @override
  void initState() {
    final wallet = selectedWallet;
    userName ??= wallet.metaData?.userName;

    Future(() async {
      // to ensure we have username
      if (DB.activeAccounts.map((acc) => acc.currentWallet).nonNulls.any((w) => w.metaData == null)) {
        await DbService.syncWalletData(network: Config.network);
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
    super.initState();
  }

  @override
  void dispose() {
    FocusManager.instance.primaryFocus?.unfocus();
    WakelockPlus.disable();
    GlobalListener.removeListener(stream: .account, listenerName: runtimeType.toString());
    fiatAmountController.dispose();
    satAmountController.dispose();
    memoController.dispose();
    pageController.dispose();
    super.dispose();
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
                icon: Icon(switch (selectedTab) {
                  TabType.lightning => Icons.bolt,
                  TabType.bitcoin => Icons.currency_bitcoin,
                }, color: context.themedColor(bright: Colors.black, dark: Colors.white)),
                label: Text(
                  switch (selectedTab) {
                    TabType.lightning => 'Lightning',
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
                  TabType.bitcoin: buildSegment(icon: Icons.currency_bitcoin, text: 'BTC'),
                },
                padding: const EdgeInsets.all(8),
              ),
            ),
          Expanded(
            child: PageView(
              controller: pageController,
              onPageChanged: (value) => selectTab(switch (value) {
                1 => TabType.bitcoin,
                _ => TabType.lightning,
              }),
              children: [
                Center(child: lightningPage()),
                if (isTabSelectionVisible) Center(child: btcPage()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void selectTab(TabType tab) async {
    if (isAnimatingPage) return;

    selectedTab = tab;
    traType = switch (tab) {
      TabType.lightning => TraType.lnToSpark,
      TabType.bitcoin => TraType.btcToSpark,
    };

    await generateInvoice();

    final expectedPageIndex = switch (selectedTab) {
      TabType.lightning => 0,
      TabType.bitcoin => 1,
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
        type: TraType.lnToSpark,
        amount: lastLightningQrConfig!.amount,
        memo: lastLightningQrConfig!.memo,
      );
    } else if (userName != null && Config.network != Network.testnet) {
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
              if (userName != null)
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
            ] else
              ...amountNoteWidget(lastLightningQrConfig!.amount, lastLightningQrConfig!.memo),
            if (qrData != null) buttons(qrData),
            ...customizingWidgets(),
          ],
        ),
      ),
    );
  }

  Widget btcPage() {
    String? qrData;
    if (lastBtcQrConfig != null) {
      if (lastBtcQrConfig!.amount > 0 || lastBtcQrConfig!.memo.isNotEmpty) {
        qrData = TransactionService.createBIP21Address(
          address: lastBtcQrConfig!.address,
          type: TraType.btcToSpark,
          amount: lastBtcQrConfig!.amount,
          memo: lastBtcQrConfig!.memo,
        );
      } else {
        qrData = lastBtcQrConfig!.address;
      }
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
      enabled: shouldBlurQr,
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
    final isPaymentFeasible = amount > 0;

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
            update();
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
            update();
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
    TraType.lnToSpark =>
      (amount != 0 && lastLightningQrConfig?.amount != amount) ||
          (memoController.text.trim().isNotEmpty && lastLightningQrConfig?.memo != memoController.text.trim()),
    TraType.btcToSpark =>
      lastBtcQrConfig == null ||
          (lastBtcQrConfig!.amount != amount || lastBtcQrConfig!.memo != memoController.text.trim()),
    TraType.sparkToSpark || TraType.sparkToLN || TraType.sparkToBTC => false,
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
    if (amount <= 0 && traType == TraType.lnToSpark) return;

    FocusScope.of(context).unfocus();
    final memo = memoController.text.trim();
    if (traType == TraType.lnToSpark &&
        lastLightningQrConfig != null &&
        lastLightningQrConfig!.amount == amount &&
        lastLightningQrConfig!.memo == memo) {
      isCustomizing = false;
      return update();
    }
    if (traType == TraType.btcToSpark && lastBtcQrConfig != null && lastBtcQrConfig!.amount == amount) {
      lastBtcQrConfig = (address: lastBtcQrConfig!.address, amount: amount, memo: memo);
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
      );

      if (addressData != null) {
        isCustomizing = false;
        if (traType == TraType.lnToSpark) {
          lastLightningQrConfig = (address: addressData, amount: amount, memo: memo);
        } else if (traType == TraType.btcToSpark) {
          lastBtcQrConfig = (address: addressData, amount: amount, memo: memo);
        }

        // enable wake lock so screen stays on until we leave this screen
        await WakelockPlus.enable();
      }

      update();
    } catch (e, s) {
      logE(e, stackTrace: s, showToast: true);
    } finally {
      stopLoader();
    }
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
