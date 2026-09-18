import 'dart:async';
import 'dart:io';

import 'package:branta/branta.dart' hide Platform;
import 'package:breez_sdk_spark_flutter/breez_sdk_spark.dart' show OnchainConfirmationSpeed;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:manna/app_state.dart';
import 'package:manna/config.dart';
import 'package:manna/globals.dart';
import 'package:manna/models/account.dart';
import 'package:manna/models/contact.dart';
import 'package:manna/models/enums.dart';
import 'package:manna/models/misc.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/contact_screen.dart';
import 'package:manna/screens/image_preview_screen.dart';
import 'package:manna/screens/qr_scanner_screen.dart';
import 'package:manna/services/clipboard_service.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/db_service.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/services/nfc_service.dart';
import 'package:manna/services/nostr_service.dart';
import 'package:manna/services/transaction_service.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/utils/constants.dart';
import 'package:manna/utils/de_bouncer.dart';
import 'package:manna/utils/sats_extension.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:manna/widgets/amount_text.dart';
import 'package:manna/widgets/bottom%20sheets/confirm_payment_bottom_sheet.dart';
import 'package:manna/widgets/bottom%20sheets/transaction_categories_bottom_sheet.dart';
import 'package:manna/widgets/fees_tile.dart';
import 'package:manna_core/manna_core.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:http/http.dart' as http;

class SendScreen extends StatefulWidget {
  const SendScreen({this.address, this.amount, this.contact, super.key});

  final String? address;
  final int? amount;
  final Contact? contact;

  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen> {
  AppLifecycleListener? lifecycleListener;
  final addressController = UserNameStylingTextEditingController();
  final fiatAmountController = TextEditingController();
  final satAmountController = TextEditingController();

  final commentController = TextEditingController();
  final noteController = TextEditingController();
  Set<String> selectedCategory = {};
  bool isExtraNoteExpanded = false;

  AddressData addressData = AddressData(addressType: AddressType.unknown, data: null, address: '');
  final addressFocusNode = FocusNode();
  int originalAmount = 0;
  int amount = 0;
  bool lockAmount = true;
  bool lockComment = false;
  bool sendAll = false;
  final feeDeBouncer = DeBouncer(const Duration(milliseconds: 300));
  final addressDeBouncer = DeBouncer(const Duration(milliseconds: 350));
  String clipboardAddress = '';

  late Contact? receiverDetail = widget.contact;
  bool isFeeExpanded = false;
  final feeExpansionController = ExpansibleController();
  bool isChainFeeSelectionExpanded = false;
  final feeRateExpansionController = ExpansibleController();

  PayOutData? paymentData;
  FeesAndAmounts? calculations;
  bool isBuildingFees = false;
  bool isProcessingAddress = false;
  final addressProcessor = MutexRun();

  BrantaData? brantaData;
  String? bolt12Issuer;
  NfcAvailability? nfcStatus;

  final activeWalletIds = DB.activeAccounts.map((acc) => acc.currentWallet).nonNulls.map((e) => e.uuid).toSet();

  @override
  void initState() {
    lifecycleListener = AppLifecycleListener(
      onResume: () async {
        nfcStatus = await NfcService.getNFCState();
        update();
        await getClipboardData();
      },
    );
    NfcService.start().then((value) => NfcService.getNFCState().then((value) => update(() => nfcStatus = value)));

    if (widget.address != null) {
      processAddress(widget.address!, defaultAmount: widget.amount);
    } else {
      getClipboardData();
    }
    super.initState();
  }

  @override
  void dispose() {
    NfcService.stop();
    lifecycleListener?.dispose();
    addressController.dispose();
    satAmountController.dispose();
    fiatAmountController.dispose();
    commentController.dispose();
    noteController.dispose();
    feeExpansionController.dispose();
    feeRateExpansionController.dispose();
    super.dispose();
  }

  Future<void> getClipboardData() async {
    if (isProcessingAddress) return;
    clipboardAddress = '';
    final clipData = await ClipboardService.read('text/plain');
    if (clipData?.trim().isEmpty ?? true) return;

    try {
      final res = await TransactionService.processAddress(
        rawAddress: clipData!,
        network: Config.network,
        validateOnly: true,
      );
      if (res.addressType != AddressType.unknown) {
        clipboardAddress = clipData.trim();
        update();
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final isPaymentFeasible =
        addressData.address.isNotEmpty &&
        addressData.addressType != AddressType.unknown &&
        (calculations?.sendAmount ?? 0) > 0 &&
        (calculations?.sendAmount ?? 0) <= selectedWallet.balance;
    if (!isPaymentFeasible || calculations == null) {
      try {
        postFrameCallBack(() {
          feeExpansionController.collapse();
          feeRateExpansionController.collapse();
        });
      } catch (_) {}
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Send'),
        actions: [
          IconButton(onPressed: () => AppRouter.push(const ContactScreen()), icon: const Icon(Icons.contacts_outlined)),
          if (Platform.isAndroid && nfcStatus != NfcAvailability.unsupported)
            IconButton(
              onPressed: () async {
                await NfcService.start(force: true);
                nfcStatus = await NfcService.getNFCState();
                ToastService.show('NFC ready');
                update();
              },
              icon: Icon(Icons.nfc, color: nfcStatus == NfcAvailability.enabled ? AppColors.primaryColor : null),
            ),
        ],
        actionsPadding: const EdgeInsets.symmetric(horizontal: 12),
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(vertical: 24.0),
                    reverse: true,
                    child: Column(
                      mainAxisAlignment: .center,
                      crossAxisAlignment: .start,
                      spacing: 16,
                      children: [
                        if (bolt12Issuer?.isNotEmpty ?? false)
                          ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                            leading: SizedBox.square(
                              dimension: 45,
                              child: Container(
                                clipBehavior: Clip.antiAlias,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: AppColors.primaryColor.withValues(alpha: 0.5),
                                ),
                                child: Center(
                                  child: Text(
                                    bolt12Issuer!.characters.take(2).string,
                                    style: const TextStyle(fontSize: 16, color: Colors.white),
                                  ),
                                ),
                              ),
                            ),
                            title: Text(
                              bolt12Issuer!,
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                            ),
                          ),
                        if (brantaData != null) BrantaCard(data: brantaData!),
                        if (receiverDetail != null) ContactCard(contact: receiverDetail!),
                        if (clipboardAddress.isNotEmpty && addressController.text.isEmpty)
                          GestureDetector(
                            onTap: () async {
                              await processAddress(clipboardAddress);
                              clipboardAddress = '';
                              update();
                            },
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                border: Border.all(color: AppColors.accentColor.withValues(alpha: 0.2)),
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: [
                                  BoxShadow(
                                    color: context.themedColor(bright: Colors.grey.shade100, dark: Colors.white12),
                                    blurRadius: 1,
                                  ),
                                ],
                              ),
                              child: Column(
                                crossAxisAlignment: .start,
                                children: [
                                  const Text(
                                    'Paste from clipboard: ',
                                    style: TextStyle(color: Colors.grey, fontSize: 13),
                                  ),
                                  Text(
                                    clipboardAddress,
                                    style: const TextStyle(color: Colors.grey, fontSize: 13),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            RawAutocomplete<String>(
                              focusNode: addressFocusNode,
                              textEditingController: addressController,
                              optionsBuilder: (textEditingValue) {
                                final val = textEditingValue.text.trim().toLowerCase();
                                if (val.isEmpty) return [];
                                if (addressData.addressType != AddressType.unknown || val.length > 100) return [];
                                return {
                                  ...DB.contacts.values
                                      .where(
                                        (c) =>
                                            activeWalletIds.contains(c.walletId) &&
                                            c.lnurl().toLowerCase().startsWith(val),
                                      )
                                      .map((e) => e.lnurl()),
                                  if (!val.contains('@')) val.toMannaLNURL(),
                                };
                              },
                              optionsViewBuilder: (context, onSelected, options) {
                                return Align(
                                  alignment: AlignmentDirectional.topStart,
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(maxHeight: 150),
                                    child: Material(
                                      elevation: 4,
                                      child: ListView(
                                        shrinkWrap: true,
                                        children: [
                                          for (final option in options)
                                            ListTile(title: Text(option), onTap: () => onSelected(option)),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                              fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                                return TextFormField(
                                  focusNode: focusNode,
                                  controller: controller,
                                  maxLines: 3,
                                  minLines: 2,
                                  decoration: InputDecoration(
                                    filled: true,
                                    fillColor: switch (addressData.addressType) {
                                      AddressType.bitcoin || AddressType.silentPayment => const Color.fromARGB(
                                        255,
                                        239,
                                        142,
                                        29,
                                      ).withValues(alpha: 0.2),
                                      AddressType.bolt11Invoice ||
                                      AddressType.bolt12Invoice ||
                                      AddressType.lnurl ||
                                      AddressType.bolt12Offer => Colors.green.withValues(alpha: 0.2),
                                      AddressType.spark ||
                                      AddressType.sparkInvoice => AppColors.primaryColor.withValues(alpha: 0.2),
                                      AddressType.unknown => Colors.transparent,
                                    },
                                    labelText: 'Input address or scan QR code',
                                    alignLabelWithHint: true,
                                  ),
                                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                                  keyboardType: TextInputType.text,
                                  textInputAction: TextInputAction.done,
                                  onChanged: (value) => addressDeBouncer.call(() => processAddress(controller.text)),
                                );
                              },
                              onSelected: (String selection) => processAddress(selection),
                            ),
                            Positioned(
                              bottom: -4,
                              right: -1,
                              child: ElevatedButton.icon(
                                style: IconButton.styleFrom(
                                  backgroundColor: AppColors.primaryColor,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99)),
                                  padding: const EdgeInsets.symmetric(horizontal: 12),
                                ),
                                onPressed: () async {
                                  final res = await AppRouter.push(
                                    QRScannerScreen(
                                      validateQr: (qrData) async {
                                        try {
                                          await TransactionService.processAddress(
                                            rawAddress: qrData,
                                            network: Config.network,
                                            validateOnly: true,
                                          );
                                          return true;
                                        } catch (_) {}
                                        return false;
                                      },
                                    ),
                                  );

                                  if (res is String) {
                                    await processAddress(res);
                                  }
                                },
                                label: const Text('Scan', style: TextStyle(color: Colors.white)),
                                icon: const Icon(Icons.qr_code_scanner, color: Colors.white),
                              ),
                            ),
                            if (isProcessingAddress)
                              const Positioned(
                                top: 6,
                                right: 6,
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(),
                              ),
                          ],
                        ),

                        if (addressData.addressType != AddressType.unknown) ...[
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
                              feeDeBouncer.call(() => rebuildFees());
                            },
                            enabled: !(sendAll || lockAmount),
                            maxLength: 8,
                            inputFormatters: [FilteringTextInputFormatter.allow(Regexes.decimalFilter)],
                            buildCounter: (context, {required currentLength, required isFocused, required maxLength}) =>
                                null,
                          ),
                          TextFormField(
                            controller: satAmountController,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              hintText: '0',
                              labelText: 'Amount',
                              suffixIcon: Row(
                                mainAxisSize: .min,
                                mainAxisAlignment: .center,
                                children: [Text(getBitcoinDisplayStyle())],
                              ),
                            ),
                            onChanged: (value) async {
                              amount = int.tryParse(value) ?? 0;
                              fiatAmountController.text = amount.satsToFiat().toStringAsFixed(2);
                              feeDeBouncer.call(() => rebuildFees());
                            },
                            enabled: !(sendAll || lockAmount),
                            maxLength: 8,
                            inputFormatters: [
                              AppState.bitcoinDisplayStyle == 2
                                  ? FilteringTextInputFormatter.allow(Regexes.btcInputFilter)
                                  : FilteringTextInputFormatter.digitsOnly,
                            ],
                            buildCounter: (context, {required currentLength, required isFocused, required maxLength}) =>
                                null,
                          ),
                          if (!lockAmount)
                            SwitchListTile(
                              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                              value: sendAll,
                              onChanged: (value) async {
                                void updateSendAll() {
                                  sendAll = value;
                                  if (sendAll) {
                                    amount = selectedWallet.balance;
                                  } else {
                                    amount = originalAmount;
                                  }
                                  satAmountController.text = amount.toStringAsFixed(0);
                                  fiatAmountController.text = amount.satsToFiat().toStringAsFixed(2);
                                  rebuildFees();
                                }

                                if (value) {
                                  FocusManager.instance.primaryFocus?.unfocus();
                                  final res = await showDialog<bool>(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      title: const Text('Send All'),
                                      content: const Text(
                                        'You are about to send all of your bitcoin. Are you sure you want to continue?',
                                      ),
                                      actions: [
                                        TextButton(
                                          child: const Text('Cancel ❌'),
                                          onPressed: () => AppRouter.pop(false),
                                        ),
                                        TextButton(
                                          child: const Text("Yes. I'm aware ✔️", textAlign: TextAlign.center),
                                          onPressed: () => AppRouter.pop(true),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (res ?? false) {
                                    updateSendAll();
                                  }
                                } else {
                                  updateSendAll();
                                }
                              },
                              title: const Text('Send All'),
                            ),
                        ],

                        if ({AddressType.spark, AddressType.lnurl}.contains(addressData.addressType) ||
                            commentController.text.isNotEmpty) ...[
                          Theme(
                            data: Theme.of(context).copyWith(focusColor: Colors.transparent),
                            child: ExpansionTile(
                              onExpansionChanged: (value) => update(() => isExtraNoteExpanded = value),
                              tilePadding: EdgeInsets.zero,
                              shape: const RoundedRectangleBorder(),
                              expandedCrossAxisAlignment: .start,
                              title: TextFormField(
                                controller: commentController,
                                decoration: InputDecoration(
                                  labelText: 'Comment',
                                  suffixIcon: isExtraNoteExpanded
                                      ? const Tooltip(
                                          triggerMode: TooltipTriggerMode.tap,
                                          showDuration: Duration(seconds: 3),
                                          message: 'This comment will be visible to you and the receiver.',
                                          child: Icon(Icons.info_outline, color: AppColors.accentColor),
                                        )
                                      : null,
                                ),
                                textInputAction: TextInputAction.next,
                                keyboardType: TextInputType.multiline,
                                textCapitalization: TextCapitalization.sentences,
                                maxLines: 3,
                                minLines: 1,
                                enabled: !lockComment,
                              ),
                              children: [
                                const SizedBox(height: 4),
                                TextFormField(
                                  controller: noteController,
                                  textInputAction: TextInputAction.next,
                                  decoration: const InputDecoration(
                                    labelText: 'Note',
                                    suffixIcon: Tooltip(
                                      triggerMode: TooltipTriggerMode.tap,
                                      showDuration: Duration(seconds: 3),
                                      message: 'This note is only visible to you.',
                                      child: Icon(Icons.info_outline, color: AppColors.accentColor),
                                    ),
                                  ),
                                  keyboardType: TextInputType.multiline,
                                  textCapitalization: TextCapitalization.sentences,
                                  maxLines: 3,
                                  minLines: 1,
                                ),
                                const SizedBox(height: 8),
                                InkWell(
                                  onTap: () async {
                                    final res = await showModalBottomSheet(
                                      context: context,
                                      showDragHandle: true,
                                      isScrollControlled: true,
                                      useSafeArea: true,
                                      shape: const RoundedRectangleBorder(
                                        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                                      ),
                                      routeSettings: const RouteSettings(name: 'TransactionCategoriesBottomSheet'),
                                      builder: (context) =>
                                          TransactionCategoriesBottomSheet(selectedCategories: selectedCategory),
                                    );
                                    if (res is Set<String>) {
                                      selectedCategory = res;
                                    }
                                    update();
                                  },
                                  child: Container(
                                    decoration: BoxDecoration(
                                      border: Border.all(color: Colors.grey),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    padding: const EdgeInsets.only(left: 16, right: 8, top: 12, bottom: 12),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            'Category : ${selectedCategory.isEmpty ? 'None' : selectedCategory.join(', ')}',
                                          ),
                                        ),
                                        const Tooltip(
                                          triggerMode: TooltipTriggerMode.tap,
                                          showDuration: Duration(seconds: 3),
                                          message: 'Categories are only visible to you.',
                                          child: Icon(Icons.info_outline, color: AppColors.accentColor),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        // Fees distribution
                        ListTileTheme(
                          minVerticalPadding: 0,
                          child: ExpansionTile(
                            controller: feeExpansionController,
                            enabled: isPaymentFeasible,
                            onExpansionChanged: (value) => update(() => isFeeExpanded = value),
                            minTileHeight: 0,
                            shape: const Border(),
                            tilePadding: EdgeInsets.only(top: 8, bottom: !isFeeExpanded ? 8 : 0),
                            title: isFeeExpanded
                                ? const Text('Fee Details', style: TextStyle(fontSize: 16))
                                : FeesTile(title: 'Total', amountSat: isPaymentFeasible ? calculations!.sendAmount : 0),
                            children: [
                              InkWell(
                                onTap: () => feeExpansionController.collapse(),
                                child: Column(
                                  children: [
                                    if (calculations != null) ...[
                                      FeesTile(amountSat: calculations!.receiveAmount, title: 'Amount'),
                                      if (calculations!.sparkFee > 0)
                                        FeesTile(amountSat: calculations!.sparkFee, title: 'Spark fee'),
                                      if (calculations!.lightningFee > 0)
                                        FeesTile(amountSat: calculations!.lightningFee, title: 'Lightning fee'),
                                      if (calculations!.networkFee > 0)
                                        FeesTile(amountSat: calculations!.networkFee, title: 'Network fee'),
                                    ],
                                    const Divider(),
                                    FeesTile(
                                      title: 'Total',
                                      amountSat: isPaymentFeasible ? calculations!.sendAmount : 0,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),

                        // onchain Fee speed selection
                        if (calculations?.onchainFeeQuote != null)
                          Builder(
                            builder: (context) {
                              (int, int) getQuote(OnchainConfirmationSpeed feeRate) => switch (feeRate) {
                                OnchainConfirmationSpeed.fast => (
                                  calculations!.onchainFeeQuote!.speedFast.userFeeSat.i,
                                  calculations!.onchainFeeQuote!.speedFast.l1BroadcastFeeSat.i,
                                ),
                                OnchainConfirmationSpeed.medium => (
                                  calculations!.onchainFeeQuote!.speedMedium.userFeeSat.i,
                                  calculations!.onchainFeeQuote!.speedMedium.l1BroadcastFeeSat.i,
                                ),
                                OnchainConfirmationSpeed.slow => (
                                  calculations!.onchainFeeQuote!.speedSlow.userFeeSat.i,
                                  calculations!.onchainFeeQuote!.speedSlow.l1BroadcastFeeSat.i,
                                ),
                              };
                              final selectedQuoteFees = getQuote(calculations!.btcFeeRate);
                              return ListTileTheme(
                                minVerticalPadding: 0,
                                child: RadioGroup(
                                  groupValue: calculations!.btcFeeRate,
                                  onChanged: (value) {
                                    if (value != null) {
                                      final quote = getQuote(value);
                                      update(
                                        () => calculations = calculations!.copyWith(
                                          btcFeeRate: value,
                                          sparkFee: quote.$1,
                                          networkFee: quote.$2,
                                          sendAmount: calculations!.receiveAmount + quote.$1 + quote.$2,
                                        ),
                                      );
                                    }
                                  },
                                  child: ListTileTheme(
                                    contentPadding: EdgeInsets.zero,
                                    child: ExpansionTile(
                                      controller: feeRateExpansionController,
                                      onExpansionChanged: (value) => update(() => isChainFeeSelectionExpanded = value),
                                      minTileHeight: 0,
                                      shape: const Border(),
                                      tilePadding: EdgeInsets.only(
                                        top: 8,
                                        bottom: !isChainFeeSelectionExpanded ? 8 : 0,
                                      ),
                                      title: isChainFeeSelectionExpanded
                                          ? const Text('Transaction speed', style: TextStyle(fontSize: 16))
                                          : FeesTile(
                                              title:
                                                  'Transaction speed : ${switch (calculations!.btcFeeRate) {
                                                    OnchainConfirmationSpeed.fast => 'Fast',
                                                    OnchainConfirmationSpeed.medium => 'Medium',
                                                    OnchainConfirmationSpeed.slow => 'Slow',
                                                  }}',
                                              amountSat: isPaymentFeasible
                                                  ? selectedQuoteFees.$1 + selectedQuoteFees.$2
                                                  : 0,
                                            ),
                                      children: [
                                        RadioListTile(
                                          value: OnchainConfirmationSpeed.fast,
                                          title: const Text('Fast'),
                                          subtitle: Text(
                                            'Spark fee: ${getSatInBitcoinStyle(calculations!.onchainFeeQuote!.speedFast.userFeeSat.i)}',
                                          ),
                                          secondary: AmountText(
                                            amountSat: calculations!.onchainFeeQuote!.speedFast.l1BroadcastFeeSat.i,
                                            showFiat: true,
                                          ),
                                        ),
                                        RadioListTile(
                                          value: OnchainConfirmationSpeed.medium,
                                          title: const Text('Medium'),
                                          subtitle: Text(
                                            'Spark fee: ${getSatInBitcoinStyle(calculations!.onchainFeeQuote!.speedMedium.userFeeSat.i)}',
                                          ),
                                          secondary: AmountText(
                                            amountSat: calculations!.onchainFeeQuote!.speedMedium.l1BroadcastFeeSat.i,
                                            showFiat: true,
                                          ),
                                        ),
                                        RadioListTile(
                                          value: OnchainConfirmationSpeed.slow,
                                          title: const Text('Slow'),
                                          subtitle: Text(
                                            'Spark fee: ${getSatInBitcoinStyle(calculations!.onchainFeeQuote!.speedSlow.userFeeSat.i)}',
                                          ),
                                          secondary: AmountText(
                                            amountSat: calculations!.onchainFeeQuote!.speedSlow.l1BroadcastFeeSat.i,
                                            showFiat: true,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                ),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
                    onPressed: !isPaymentFeasible
                        ? null
                        : () async {
                            final wallet = selectedAccount.currentWallet;

                            await rebuildFees();
                            if (calculations == null) {
                              return ToastService.show('Failed to calculate fees and swap amount.');
                            }
                            if (calculations!.sendAmount > wallet.balance) {
                              return ToastService.show('Insufficient balance!');
                            }

                            final addressText = addressController.text.trim();
                            if (addressText.isUserName &&
                                addressText.contains('manna') &&
                                !addressText.isMannaUserName) {
                              return ToastService.show('You are trying to send to username on another network!');
                            }

                            FocusManager.instance.primaryFocus?.unfocus();
                            try {
                              startLoader();
                              // reset the last swap of payment data if amount or address is changed
                              if (paymentData?.calculation.sendAmount != amount ||
                                  paymentData?.addressData.address != addressData.address) {
                                paymentData = null;
                              }
                              final comment = commentController.text.trim();
                              paymentData ??= await TransactionService.createPayOut(
                                account: selectedAccount,
                                calculation: calculations!,
                                addressData: addressData,
                                sendAll: sendAll,
                                receiverContact: receiverDetail,
                                comment: comment.isNotEmpty && !lockComment ? comment : null,
                                note: noteController.text.trim(),
                                categories: selectedCategory,
                                brantaData: brantaData,
                              );
                              if (paymentData != null) {
                                if (context.mounted) {
                                  unawaited(
                                    showModalBottomSheet(
                                      context: context,
                                      showDragHandle: true,
                                      isScrollControlled: true,
                                      useSafeArea: true,
                                      isDismissible: false,
                                      shape: const RoundedRectangleBorder(
                                        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                                      ),
                                      routeSettings: const RouteSettings(name: 'ConfirmPaymentBottomSheet'),
                                      builder: (context) => ConfirmPaymentBottomSheet(paymentData: paymentData!),
                                    ),
                                  );
                                }
                              }
                            } finally {
                              stopLoader();
                            }
                          },
                    child: isBuildingFees
                        ? const Center(
                            child: SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(color: Colors.white),
                            ),
                          )
                        : const Text('Continue', style: TextStyle(color: Colors.white)),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> processAddress(String address, {int? defaultAmount, bool isRecursive = false}) async {
    await addressProcessor
        .run(() async {
          brantaData = null;
          update(() => isProcessingAddress = true);
          lockAmount = false;
          amount = 0;
          originalAmount = 0;
          commentController.text = '';
          satAmountController.text = '';
          fiatAmountController.text = '';
          receiverDetail = widget.contact;
          addressController.value = addressController.value.copyWith(text: address);

          try {
            addressData = await TransactionService.processAddress(rawAddress: address, network: Config.network);
            if (addressData.amount == 0) {
              addressData = addressData.copyWith(amount: defaultAmount);
            }

            if (addressData.addressType == AddressType.bolt12Offer) {
              final res = await Crypto.decodeBolt12Offer(offer: addressData.address);
              bolt12Issuer = res.issuer ?? res.description;
            } else if (addressData.addressType == AddressType.bolt12Invoice) {
              final res = Crypto.decodeBolt12Invoice(invoice: addressData.address);
              if (res.issuer != null) {
                bolt12Issuer = res.issuer;
              }
            } else if (addressData.addressType == AddressType.spark) {
              final (identityKey, network) = Crypto.decodeSparkAddress(addr: addressData.address);
              if (network == Config.network) {
                receiverDetail ??= await DbService.getContact(identityKey: identityKey);
              }
            }

            if (addressData.addressType != AddressType.unknown) {
              sendAll = false;
              addressController.value = addressController.value.copyWith(text: addressData.address);
              if (mounted) {
                FocusScope.of(context).unfocus();
              }

              if (addressData.amount > 0) {
                originalAmount = amount = addressData.amount;
                satAmountController.text = amount.toStringAsFixed(0);
                fiatAmountController.text = amount.satsToFiat().toStringAsFixed(2);
                commentController.text = addressData.comment?.trim() ?? '';
                lockAmount = addressData.lockAmount;
                lockComment = lockAmount && commentController.text.trim().isNotEmpty;
              }

              if (addressData.addressType == AddressType.lnurl) {
                if (addressData.address.isMannaUserName && (addressData.address.getUserName?.isNotEmpty ?? false)) {
                  receiverDetail ??= await DbService.getContact(userName: addressData.address.getUserName!);
                } else {
                  receiverDetail ??= await NostrService.fetchUserData(addressData.address, selectedWallet);
                }
              }

              // Branta
              if ({AddressType.bolt11Invoice, AddressType.bitcoin}.contains(addressData.addressType)) {
                const options = BrantaClientOptions(baseUrl: BrantaServerBaseUrl.production);
                final service = BrantaService(
                  client: BrantaClient(httpClient: http.Client(), defaultOptions: options),
                  aesEncryption: AesEncryptionService(),
                  defaultOptions: options,
                );
                unawaited(
                  service.getPaymentsByQrCodeAsync(address).then((value) {
                    if (value.payments.isNotEmpty) {
                      final p = value.payments.first;
                      if (p.platform?.isNotEmpty ?? false) {
                        brantaData = BrantaData(
                          verifyURL: value.verifyUrl,
                          name: p.platform!,
                          logoLight: p.platformLogoLightUrl,
                          logoDark: p.platformLogoUrl,
                          desc: p.description,
                        );
                        update();
                      }
                    }
                  }, onError: (e, s) => logE(e, stackTrace: s)),
                );
              }
            }
          } on AddressParsingException catch (e) {
            ToastService.show(e.message);
          }

          update(() => isProcessingAddress = false);
        })
        .then((_) {
          // This is to handle case where user typed username but the processed username is not same,
          // and we failed to validate address
          final currentInput = addressController.text.trim();
          if (!isRecursive &&
              addressData.addressType == AddressType.unknown &&
              currentInput.isUserName &&
              address != currentInput) {
            processAddress(currentInput, isRecursive: true);
          }
        });

    await rebuildFees();
  }

  ({String mannaUsername, String address})? mannaUserLiquidAddressCache;

  Timer? onChainFeeQuoteTimer;
  Future<void> rebuildFees({bool isRecursive = false}) async {
    if (addressData.addressType == AddressType.unknown) {
      calculations = null;
      return;
    }

    onChainFeeQuoteTimer?.cancel();
    onChainFeeQuoteTimer = null;

    final address = addressController.text.trim();
    if (addressData.addressType == AddressType.lnurl && address.isMannaUserName) {
      final userName = address.getUserName;
      if (userName != null && mannaUserLiquidAddressCache?.mannaUsername != userName) {
        final liquidAddress = await DbService.getSparkAddress(userName);
        if (liquidAddress != null) {
          mannaUserLiquidAddressCache = (mannaUsername: userName, address: liquidAddress);
        }
      }
    }

    final wallet = selectedWallet;
    if (!lockAmount && amount >= wallet.balance && wallet.balance > 0) {
      if (!sendAll) {
        ToastService.show('Sending all, because the amount exceeds wallet balance.');
      }
      sendAll = true;
      amount = selectedWallet.balance;
      satAmountController.text = amount.toStringAsFixed(0);
      fiatAmountController.text = amount.satsToFiat().toStringAsFixed(2);
      update();
    }

    final comment = commentController.text.trim();
    update(() => isBuildingFees = true);
    calculations = await calculateFeeAndAmounts(
      wallet: wallet,
      amount: amount,
      addressData: addressData.copyWith(
        address: addressData.addressType == AddressType.lnurl
            ? mannaUserLiquidAddressCache?.address ?? address
            : address,
        comment: Nullable(comment.isNotEmpty && !lockComment ? comment : null),
      ),

      amountExcludesFee: !sendAll,
      alreadySelectedSpeed: calculations?.btcFeeRate,
    );
    update(() => isBuildingFees = false);

    if ((calculations?.onchainFeeQuote?.expiresAt.i ?? 0) > 0) {
      final duration = DateTime.fromMillisecondsSinceEpoch(
        calculations!.onchainFeeQuote!.expiresAt.i * 1000,
      ).difference(DateTime.now()).abs();
      onChainFeeQuoteTimer = Timer(duration, () {
        rebuildFees();
      });
    }

    if (!lockAmount && (calculations?.sendAmount ?? 0) >= wallet.balance && wallet.balance > 0 && !isRecursive) {
      if (!sendAll) {
        ToastService.show('Sending all, because the amount exceeds wallet balance.');
      }
      sendAll = true;
      amount = selectedWallet.balance;
      satAmountController.text = amount.toStringAsFixed(0);
      fiatAmountController.text = amount.satsToFiat().toStringAsFixed(2);
      await rebuildFees(isRecursive: true);
    }
  }
}

class UserNameStylingTextEditingController extends TextEditingController {
  @override
  TextSpan buildTextSpan({required BuildContext context, required bool withComposing, TextStyle? style}) {
    final match = Regexes.internetAddress.firstMatch(text);
    if (match != null) {
      final userName = match.group(1);
      final domain = match.group(2);
      if (userName != null && domain != null) {
        return TextSpan(
          children: [
            TextSpan(
              text: userName,
              style: style?.copyWith(color: AppColors.primaryColor),
            ),
            TextSpan(
              text: '@$domain',
              style: style?.copyWith(color: Colors.grey),
            ),
          ],
        );
      }
    }

    return super.buildTextSpan(context: context, withComposing: withComposing, style: style);
  }
}

class BrantaCard extends StatelessWidget {
  const BrantaCard({required this.data, super.key});

  final BrantaData data;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: () => launchUrlString(data.verifyURL),
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      leading: SizedBox(
        height: 45,
        child: ClipRRect(
          borderRadius: BorderRadiusGeometry.circular(8),
          child: Builder(
            builder: (context) {
              final provider = getImageProvider(
                context.isDarkMode
                    ? data.logoDark ?? data.logoLight ?? AppImages.brantaDark
                    : data.logoLight ?? data.logoDark ?? AppImages.brantaBright,
              );
              if (provider != null) {
                return Image(
                  image: provider,
                  fit: BoxFit.cover,
                  alignment: Alignment.centerLeft,
                  loadingBuilder: imageLoadingBuilder,
                );
              }
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
      title: Text(data.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (data.desc != null) Text(data.desc!, maxLines: 1, overflow: TextOverflow.ellipsis),
          const Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Text('Address verified by Branta', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
      isThreeLine: true,
    );
  }
}
