import 'dart:io';

import 'package:dropdown_button2/dropdown_button2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:manna/app_state.dart';
import 'package:manna/globals.dart';
import 'package:manna/models/account.dart';
import 'package:manna/models/shop_item.dart';
import 'package:manna/models/tax.dart';
import 'package:manna/screens/shop_screen.dart';
import 'package:manna/services/clipboard_service.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/transaction_service.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/parser.dart';
import 'package:manna/utils/sats_extension.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/util.dart';
import 'package:manna/widgets/amount_text.dart';
import 'package:manna/widgets/fees_tile.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class ShopCheckoutBottomSheet extends StatefulWidget {
  const ShopCheckoutBottomSheet({
    required this.amount,
    required this.memo,
    required this.calculations,
    required this.items,
    super.key,
  });

  final List<CalcData> calculations;
  final List<ShopItem> items;
  final String memo;
  final int amount;

  @override
  State<ShopCheckoutBottomSheet> createState() => _ShopCheckoutBottomSheetState();
}

class _ShopCheckoutBottomSheetState extends State<ShopCheckoutBottomSheet> {
  // tip
  final maxPercentLimit = 50;
  final tipController = TextEditingController();
  double tipPercentage = 0;
  bool isSatsSelected = false;
  int tipAmount = 0;
  bool isTipped = !AppState.isShopTipsOn;

  void updateTipAmount() {
    tipAmount = (widget.amount * tipPercentage / 100).ceil();
    tipController.text = isSatsSelected ? tipAmount.toStringAsFixed(0) : tipAmount.satsToFiat().toStringAsFixed(2);
  }

  // payment
  String? qrData;
  TraType traType = TraType.lnToSpark;
  final taxExpansionController = ExpansibleController();
  final feeExpansionController = ExpansibleController();
  bool isTaxExpanded = false;
  bool isBreakdownExpanded = false;

  int get totalTax => taxMap.entries.fold(0.0, (p, e) => p + e.value).fiatToSats();
  int get totalAmount => widget.amount + tipAmount;

  String get memo =>
      '${widget.memo}\n'
      '${totalTax > 0 ? 'Tax : ${totalTax.satsToFiat().formatFiat()}' : ''}\n'
      '${tipAmount > 0 ? 'Tip : ${tipAmount.satsToFiat().formatFiat()}' : ''}\n';
  final Map<Tax, double> taxMap = {};

  @override
  void initState() {
    for (final t in DB.taxes.values) {
      for (final i in widget.items) {
        taxMap.update(t, (value) => value + i.particularTax(t), ifAbsent: () => i.particularTax(t));
      }
    }
    if (!AppState.isShopTipsOn) {
      refreshQr();
    }
    super.initState();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    super.dispose();
  }

  Future<void> refreshQr() async {
    startLoader();
    qrData = await TransactionService.generateQrData(
      account: selectedAccount,
      amount: totalAmount,
      memo: memo,
      type: traType,
    );
    stopLoader();
    update();
    if (qrData != null) {
      await WakelockPlus.enable();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (isTipped) {
      try {
        postFrameCallBack(() => feeExpansionController.collapse());
      } catch (_) {}
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16) + context.keyboardPadding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [...(!isTipped ? tipView() : paymentView()), const SizedBox(height: 16)],
      ),
    );
  }

  List<Widget> tipView() {
    return [
      const Text(
        'Would you like to add a tip ?',
        style: TextStyle(fontSize: 22, color: AppColors.primaryColor, fontWeight: FontWeight.w500),
      ),
      const SizedBox(height: 16),
      FeesTile(amountSat: widget.amount, title: 'Sub total'),
      const SizedBox(height: 18),
      SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 8,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 12.0),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 18.0),
          valueIndicatorShape: const PaddleSliderValueIndicatorShape(),
          valueIndicatorTextStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
        ),
        child: Slider(
          value: tipPercentage,
          max: maxPercentLimit.toDouble(),
          divisions: maxPercentLimit,
          label: '${tipPercentage.toStringAsFixed(0)}%',
          activeColor: AppColors.primaryColor,
          onChanged: (value) {
            update(() {
              tipPercentage = value;
              updateTipAmount();
            });
          },
        ),
      ),
      const SizedBox(height: 16),
      TextFormField(
        controller: tipController,
        keyboardType: TextInputType.numberWithOptions(decimal: !isSatsSelected),
        decoration: InputDecoration(
          labelText: 'Tip',
          hintText: 'Enter tip value',
          suffixIcon: DropdownButtonHideUnderline(
            child: DropdownButton<bool>(
              value: isSatsSelected,
              items: [
                DropdownMenuItem(value: true, child: Text(getBitcoinDisplayStyle())),
                DropdownMenuItem(value: false, child: Text(AppState.selectedCurrency.currencyCode)),
              ],
              onChanged: (value) async {
                isSatsSelected = value ?? true;
                updateTipAmount();
                update();
              },
            ),
          ),
        ),
        validator: (value) {
          if (parseDouble(value) <= 0) {
            return 'Please enter valid value';
          }
          return null;
        },
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d{0,5}\.?\d{0,2}'))],
        onChanged: (value) {
          if (value.isNotEmpty) {
            final amt = double.tryParse(value) ?? 0;
            final amount = isSatsSelected ? amt : amt.fiatToSats();
            final tipLimitAmount = widget.amount * maxPercentLimit / 100;
            if (amount <= tipLimitAmount) {
              tipPercentage = (amount / widget.amount) * 100;
              tipAmount = (widget.amount * tipPercentage / 100).ceil();
            } else {
              tipPercentage = maxPercentLimit.toDouble();
              updateTipAmount();
            }
            update();
          } else {
            update(() {
              tipPercentage = 0.0;
              tipAmount = 0;
            });
          }
        },
      ),
      const SizedBox(height: 16),
      FeesTile(amountSat: totalAmount, title: 'Total with Tip'),
      const SizedBox(height: 16),
      Row(
        children: [
          Expanded(
            child: ElevatedButton(
              onPressed: () {
                tipAmount = 0;
                refreshQr();
                update(() => isTipped = true);
              },

              style: ElevatedButton.styleFrom(backgroundColor: Colors.grey, visualDensity: VisualDensity.standard),
              child: const Text('Continue without tip', textAlign: TextAlign.center),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: ElevatedButton(
              onPressed: () {
                refreshQr();
                update(() => isTipped = true);
              },
              style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
              child: const Text('Add tip', textAlign: TextAlign.center),
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> paymentView() {
    return [
      DropdownButton2(
        iconStyleData: const IconStyleData(iconSize: 35),
        underline: const SizedBox(),
        buttonStyleData: ButtonStyleData(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(10)),
        ),
        dropdownStyleData: DropdownStyleData(
          elevation: 0,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(10)),
        ),
        items: const [
          DropdownMenuItem(value: TraType.lnToSpark, child: Text('Lightning')),
          DropdownMenuItem(value: TraType.btcToSpark, child: Text('BTC')),
        ],
        onChanged: (value) async {
          traType = value ?? TraType.lnToSpark;
          await refreshQr();
        },
        value: traType,
        style: TextStyle(
          fontSize: 20,
          color: context.themedColor(bright: Colors.black, dark: Colors.white),
          fontWeight: FontWeight.w500,
        ),
      ),
      const SizedBox(height: 16),
      if (qrData != null) ...[
        GestureDetector(
          onTap: () => ClipboardService.setClipBoard(qrData!, 'Invoice copied'),
          child: Stack(
            children: [
              Container(
                padding: const EdgeInsets.only(bottom: 16, left: 4, top: 4, right: 4),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade400),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: PrettyQrView.data(data: qrData!, decoration: qrDecoration(qrData!)),
                ),
              ),
              Positioned(
                bottom: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 7),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade400),
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.copy, size: 12, color: Colors.black),
                      Text('copy', style: TextStyle(color: Colors.black)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        ListTileTheme(
          minVerticalPadding: 0,
          child: ExpansionTile(
            controller: feeExpansionController,
            maintainState: true,
            title: isBreakdownExpanded
                ? const Text('Fee Details', style: TextStyle(fontSize: 16))
                : FeesTile(amountSat: totalAmount, title: 'Total'),
            minTileHeight: 0,
            shape: const Border(),
            tilePadding: EdgeInsets.only(top: 8, bottom: !isBreakdownExpanded ? 8 : 0),
            onExpansionChanged: (value) => update(() => isBreakdownExpanded = value),
            children: [
              InkWell(
                onTap: () => feeExpansionController.collapse(),
                child: Column(
                  children: [
                    FeesTile(amountSat: widget.amount - totalTax, title: 'Amount'),
                    if (totalTax > 0) FeesTile(amountSat: totalTax, title: 'Taxes'),
                    if (tipAmount > 0) FeesTile(amountSat: tipAmount, title: 'Tip'),

                    const Divider(),
                    FeesTile(amountSat: totalAmount, title: 'Total'),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        ElevatedButton(
          onPressed: () async {
            startLoader();
            try {
              final qrImageBytes = await QrImage(
                QrCode.fromData(data: qrData!, errorCorrectLevel: QrErrorCorrectLevel.M),
              ).toImageAsBytes(size: 512, decoration: qrDecoration(qrData!));
              if (qrImageBytes != null) {
                final tempDir = await getTemporaryDirectory();
                final file = File('${tempDir.path}/payment_qr.png');
                await file.create();
                await file.writeAsBytes(qrImageBytes.buffer.asUint8List());
                if (mounted) {
                  await SharePlus.instance.share(
                    ShareParams(
                      files: [XFile(file.path)],
                      text: '$qrData\n\n$memo',
                      sharePositionOrigin: context.sharePlusRect,
                    ),
                  );
                }
              }
            } catch (_) {}
            stopLoader();
          },
          style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
          child: const Row(
            mainAxisAlignment: .center,
            children: [
              Icon(Icons.share),
              SizedBox(width: 16),
              Text('Share', style: TextStyle(fontSize: 18)),
            ],
          ),
        ),
      ] else ...[
        const SizedBox(width: double.infinity),
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        const Text('Generating QR...'),
      ],
    ];
  }
}
