import 'package:flutter/material.dart';
import 'package:manna/app_state.dart';
import 'package:manna/globals.dart';
import 'package:manna/models/account.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/sats_extension.dart';
import 'package:manna/utils/state_extension.dart';

class AmountText extends StatefulWidget {
  const AmountText({
    required this.amountSat,
    this.isIncoming,
    this.btcStyle,
    this.showSat = true,
    this.showFiat = false,
    this.scale = 1,
    this.fiatStyle,
    this.isTapDisable = true,
    this.isLongTapDisable = false,
    this.onUpdate,
    this.atTime,
    super.key,
  });

  final num amountSat;
  final bool? isIncoming;
  final TextStyle? btcStyle;
  final TextStyle? fiatStyle;
  final bool showSat;
  final bool showFiat;
  final double scale;
  final bool isTapDisable;
  final bool isLongTapDisable;
  final void Function(bool val)? onUpdate;
  final DateTime? atTime;

  @override
  State<AmountText> createState() => _AmountTextState();
}

class _AmountTextState extends State<AmountText> {
  late bool showBTC = widget.showSat;
  bool showCurrentFiatValue = false;

  @override
  Widget build(BuildContext context) {
    final fiatAmount = widget.amountSat.ceil().satsToFiat(at: widget.atTime);
    final fiatAmountNow = widget.amountSat.ceil().satsToFiat(at: DateTime.now());
    final formattedFiatAmount = fiatAmount.formatFiat();

    return MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(widget.scale)),
      child: GestureDetector(
        onTap: widget.isTapDisable
            ? null
            : () {
                showBTC = !showBTC;
                widget.onUpdate?.call(showBTC);
                update();
              },
        onLongPress: widget.isLongTapDisable
            ? null
            : () {
                AppState.bitcoinDisplayStyle = (AppState.bitcoinDisplayStyle + 1) % 3;
                GlobalListener.update(stream: .account, data: selectedAccountId);
              },
        child: Column(
          crossAxisAlignment: .end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text.rich(
              TextSpan(
                text: showBTC
                    ? switch (AppState.bitcoinDisplayStyle) {
                        1 => widget.amountSat.formatSats,
                        2 => widget.amountSat.toBtc.formatBTC,
                        _ => '₿ ${widget.amountSat.formatSats}',
                      }
                    : formattedFiatAmount,
                children: [
                  if (showBTC)
                    TextSpan(
                      text: switch (AppState.bitcoinDisplayStyle) {
                        1 => ' Sats',
                        2 => ' BTC',
                        _ => '',
                      },
                      style: const TextStyle(fontSize: 14),
                    ),
                ],
              ),
              style: widget.btcStyle?.copyWith(
                color: widget.isIncoming != null
                    ? widget.isIncoming!
                          ? Colors.green
                          : Colors.red
                    : null,
              ),
              textAlign: TextAlign.end,
            ),
            if (widget.showFiat && fiatAmount != 0)
              GestureDetector(
                onTap: () => update(() => showCurrentFiatValue = !showCurrentFiatValue),
                child: Builder(
                  builder: (context) {
                    final difference = fiatAmountNow.abs() - fiatAmount.abs();
                    final isPositive = difference >= 0;
                    return Text.rich(
                      TextSpan(
                        text: showCurrentFiatValue ? '≈ ${fiatAmountNow.formatFiat()}' : '≈ $formattedFiatAmount',
                        children: [
                          if (showCurrentFiatValue)
                            TextSpan(
                              text: ' (${isPositive ? '+' : '-'}${difference.abs().formatFiat()})',
                              style: TextStyle(color: isPositive ? Colors.green : Colors.red),
                            ),
                        ],
                      ),
                      style:
                          widget.fiatStyle?.copyWith(
                            color: widget.isIncoming != null
                                ? widget.isIncoming!
                                      ? Colors.green
                                      : Colors.red
                                : null,
                          ) ??
                          const TextStyle(color: AppColors.accentColor),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String getSatInBitcoinStyle(int amount, {int? style}) {
  return switch (style ?? AppState.bitcoinDisplayStyle) {
    1 => '${amount.ceilToDouble().formatSats} sats',
    2 => '${amount.toBtc.formatBTC} BTC',
    _ => '₿ ${amount.ceilToDouble().formatSats}',
  };
}

String getBitcoinDisplayStyle() => switch (AppState.bitcoinDisplayStyle) {
  1 => 'sats',
  2 => 'BTC',
  _ => '₿',
};
