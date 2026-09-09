import 'package:flutter/material.dart';
import 'package:manna/services/db.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/widgets/bottom sheets/tax_item_bottom_sheet.dart';

class ShopTaxScreen extends StatefulWidget {
  const ShopTaxScreen({super.key});

  @override
  State<ShopTaxScreen> createState() => _ShopTaxScreenState();
}

class _ShopTaxScreenState extends State<ShopTaxScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        child: const Icon(Icons.add),
        onPressed: () async {
          FocusManager.instance.primaryFocus?.unfocus();
          await showModalBottomSheet(
            context: context,
            showDragHandle: true,
            isScrollControlled: true,
            useSafeArea: true,
            isDismissible: false,
            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
            routeSettings: const RouteSettings(name: 'TaxItemBottomSheet'),
            builder: (context) => const TaxItemBottomSheet(),
          );
          update();
        },
      ),
      appBar: AppBar(title: const Text('Taxes')),
      body: Column(
        children: [
          Expanded(
            child: DB.taxes.isEmpty
                ? const Center(child: Text('Taxes Not Found', style: TextStyle(fontSize: 16)))
                : ListView(
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                    children: [
                      for (final tax in DB.taxes.values)
                        Card(
                          child: ListTile(
                            title: Text(tax.name, style: const TextStyle(fontSize: 18)),
                            subtitle: Text(
                              'categories: ${tax.categories.isEmpty ? 'All' : tax.categories.join(', ')}',
                              style: const TextStyle(fontSize: 16),
                            ),
                            trailing: Text(
                              '${tax.tax}%',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                            ),
                            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
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
                                routeSettings: const RouteSettings(name: 'TaxItemBottomSheet'),
                                builder: (context) => TaxItemBottomSheet(texItem: tax),
                              );
                              update();
                            },
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
