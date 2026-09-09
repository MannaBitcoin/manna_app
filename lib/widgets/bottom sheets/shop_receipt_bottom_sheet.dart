import 'package:flutter/material.dart';
import 'package:manna/models/shop_item.dart';
import 'package:manna/models/tax.dart';
import 'package:manna/screens/shop_screen.dart';
import 'package:manna/services/db.dart';
import 'package:manna/utils/sats_extension.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/widgets/amount_text.dart';

class ShopReceiptBottomSheet extends StatefulWidget {
  const ShopReceiptBottomSheet({required this.calculations, required this.items, super.key});

  final List<CalcData> calculations;
  final List<ShopItem> items;

  @override
  State<ShopReceiptBottomSheet> createState() => _ShopReceiptBottomSheetState();
}

class _ShopReceiptBottomSheetState extends State<ShopReceiptBottomSheet> {
  bool showSat = false;
  final taxMap = <Tax, double>{};

  @override
  void initState() {
    for (final t in DB.taxes.values) {
      for (final i in widget.items) {
        taxMap.update(t, (value) => value + i.particularTax(t), ifAbsent: () => i.particularTax(t));
      }
      for (final c in widget.calculations) {
        taxMap.update(t, (value) => value + c.particularTax(t), ifAbsent: () => c.particularTax(t));
      }
    }
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    final amount =
        (widget.calculations.fold(0.0, (a, b) => a + (b.totalPrice + b.totalTax)) +
                widget.items.fold(0.0, (p, e) => p + e.totalPrice + e.totalTax))
            .clamp(0.0, double.infinity);
    final catMap = getCateMap(widget.items);
    final soloItems = widget.items.where((e) => e.category.isEmpty);

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 22),
      child: GestureDetector(
        onTap: () => update(() => showSat = !showSat),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: .start,
          children: [
            const Center(
              child: Text('Receipt', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 8),
            Column(
              crossAxisAlignment: .start,
              children: [
                for (final category in catMap.entries) ...[
                  Text(category.key, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const Divider(),
                  for (final c in category.value) buildItem(c),
                  const SizedBox(height: 16),
                ],
                if (soloItems.isNotEmpty) ...[
                  const Text('Singles', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const Divider(),
                  for (final item in soloItems) buildItem(item),
                  const SizedBox(height: 16),
                ],
                if (widget.calculations.isNotEmpty) ...[
                  const Text('Calculations', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const Divider(),
                  for (final c in widget.calculations)
                    buildItem(ShopItem(id: -1, name: c.name, price: c.price, quantity: c.qty.toDouble())),
                ],
              ],
            ),
            const Divider(height: 32, thickness: 2),
            for (final tax in taxMap.entries.where((t) => t.value > 0))
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: Text(
                      '${tax.key.name} (${tax.key.tax}%)',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                    ),
                  ),
                  AmountText(
                    key: Key(showSat.toString()),
                    amountSat: tax.value.fiatToSats(),
                    showSat: showSat,
                    btcStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                    onUpdate: (val) => update(() => showSat = val),
                  ),
                ],
              ),
            Row(
              children: [
                const Expanded(
                  child: Text('Total', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                ),
                AmountText(
                  key: Key(showSat.toString()),
                  amountSat: amount.fiatToSats(),
                  showSat: showSat,
                  btcStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  onUpdate: (val) => update(() => showSat = val),
                ),
              ],
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget buildItem(ShopItem c) {
    return Row(
      spacing: 8,
      children: [
        const SizedBox(width: 8),
        Expanded(child: Text(c.name, style: const TextStyle(fontSize: 16))),
        Row(
          children: [
            AmountText(
              key: Key(showSat.toString()),
              amountSat: c.price.fiatToSats(),
              showSat: showSat,
              btcStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.normal),
              onUpdate: (val) => update(() => showSat = val),
            ),
            Text(' x ${c.quantity}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
          ],
        ),
        Expanded(
          child: Row(
            mainAxisAlignment: .end,
            children: [
              AmountText(
                key: Key(showSat.toString()),
                amountSat: c.totalPrice.fiatToSats(),
                showSat: showSat,
                btcStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                onUpdate: (val) => update(() => showSat = val),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
