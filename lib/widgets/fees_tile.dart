import 'package:flutter/material.dart';
import 'package:manna/utils/sats_extension.dart';
import 'package:manna/widgets/amount_text.dart';

class FeesTile extends StatelessWidget {
  const FeesTile({required this.amountSat, required this.title, super.key});

  final String title;
  final int amountSat;

  @override
  Widget build(BuildContext context) {
    return Row(
      spacing: 8,
      crossAxisAlignment: .start,
      children: [
        Expanded(child: Text(title)),
        AmountText(amountSat: amountSat, showFiat: true),
      ],
    );
  }
}

class FeesTileFiat extends StatelessWidget {
  const FeesTileFiat({required this.amount, required this.title, super.key});

  final String title;
  final double amount;

  @override
  Widget build(BuildContext context) {
    return Row(
      spacing: 8,
      crossAxisAlignment: .start,
      children: [
        Expanded(child: Text(title)),
        Text(amount.formatFiat()),
      ],
    );
  }
}
