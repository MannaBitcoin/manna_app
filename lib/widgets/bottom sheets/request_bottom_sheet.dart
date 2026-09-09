import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:manna/app_state.dart';
import 'package:manna/globals.dart';
import 'package:manna/models/account.dart';
import 'package:manna/models/chat_message.dart';
import 'package:manna/router.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/utils/constants.dart';
import 'package:manna/utils/parser.dart';
import 'package:manna/utils/sats_extension.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/widgets/amount_text.dart';

class RequestBottomSheet extends StatefulWidget {
  const RequestBottomSheet({this.initialData, super.key});

  final PayReqMessageData? initialData;

  @override
  State<RequestBottomSheet> createState() => _RequestBottomSheetState();
}

class _RequestBottomSheetState extends State<RequestBottomSheet> {
  final fiatAmountController = TextEditingController(),
      satAmountController = TextEditingController(),
      noteController = TextEditingController();
  bool isSatLastEdited = false;

  @override
  void initState() {
    if (widget.initialData != null) {
      final initialAmount = widget.initialData!.amount;
      if (widget.initialData!.isSat) {
        satAmountController.text = initialAmount.toInt().toStringAsFixed(0);
        fiatAmountController.text = initialAmount.toInt().satsToFiat(targetCurrencyCode: 'usd').toStringAsFixed(2);
        isSatLastEdited = true;
      } else {
        satAmountController.text = initialAmount.fiatToSats(sourceCurrencyCode: 'usd').toStringAsFixed(0);
        fiatAmountController.text = initialAmount.toStringAsFixed(2);
        isSatLastEdited = false;
      }

      noteController.text = widget.initialData!.memo ?? '';
    }
    super.initState();
  }

  @override
  void dispose() {
    noteController.dispose();
    satAmountController.dispose();
    fiatAmountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(left: 16.0, right: 16.0, bottom: 16) + context.keyboardPadding,
      child: Column(
        spacing: 16,
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: .start,
        children: [
          const Text('Request', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          TextFormField(
            controller: fiatAmountController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              hintText: '0.0',
              labelText: 'Amount',
              suffixIcon: Row(mainAxisSize: .min, mainAxisAlignment: .center, children: [Text('USD')]),
            ),
            onChanged: (value) async {
              final amount = double.tryParse(value)?.fiatToSats(sourceCurrencyCode: 'usd') ?? 0;
              satAmountController.text = amount.toStringAsFixed(0);
              isSatLastEdited = false;
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
              suffixIcon: Row(
                mainAxisSize: .min,
                mainAxisAlignment: .center,
                children: [Text(getBitcoinDisplayStyle())],
              ),
            ),
            onChanged: (value) async {
              final amount = int.tryParse(value) ?? 0;
              fiatAmountController.text = amount.satsToFiat().toStringAsFixed(2);
              isSatLastEdited = true;
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
            controller: noteController,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(labelText: 'Memo'),
            keyboardType: TextInputType.multiline,
            textCapitalization: TextCapitalization.sentences,
            maxLines: 3,
            minLines: 1,
            onChanged: (value) => update(),
          ),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () async {
                startLoader();
                try {
                  final address = widget.initialData?.address ?? await selectedWallet.getConfidentialAddress();
                  final amount = parseDouble(
                    isSatLastEdited ? satAmountController.text.trim() : fiatAmountController.text.trim(),
                  );
                  final note = noteController.text.trim();
                  if (address != null && amount > 0) {
                    AppRouter.pop(
                      PayReqMessageData(
                        address: address,
                        amount: amount,
                        isSat: isSatLastEdited,
                        memo: note.isEmpty ? null : note,
                      ),
                    );
                  }
                } catch (e, s) {
                  logE(e, stackTrace: s);
                }
                stopLoader();
              },
              style: ElevatedButton.styleFrom(visualDensity: VisualDensity.standard),
              child: const Text('Send Request', textAlign: TextAlign.center),
            ),
          ),
        ],
      ),
    );
  }
}
