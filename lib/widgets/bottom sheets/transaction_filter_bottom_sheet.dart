import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:manna/router.dart';
import 'package:manna/screens/all_transaction_screen.dart';
import 'package:manna/services/db.dart';
import 'package:manna/utils/state_extension.dart';

class TransactionFilterBottomSheet extends StatefulWidget {
  const TransactionFilterBottomSheet({required this.accountId, required this.filterData, super.key});

  final FilterData filterData;
  final String accountId;

  @override
  State<TransactionFilterBottomSheet> createState() => _TransactionFilterBottomSheetState();
}

class _TransactionFilterBottomSheetState extends State<TransactionFilterBottomSheet> {
  late FilterData filterData = widget.filterData;

  double minAmount = 0;
  double maxAmount = 0;

  @override
  void initState() {
    final wallet = DB.accounts[widget.accountId]?.currentWallet;
    final amounts = DB.transactions.values
        .where((t) => t.walletId == wallet?.uuid)
        .toList()
        .map((e) => e.amount.abs().toDouble());
    minAmount = amounts.fold(0, math.min);
    maxAmount = amounts.fold(0, math.max);
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    final categories = DB.transactions.values
        .map((e) => e.categories)
        .nonNulls
        .fold(<String>{}, (previousValue, element) => {...previousValue, ...element});
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Theme(
        data: Theme.of(context).copyWith(
          listTileTheme: const ListTileThemeData(
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: .start,
          spacing: 8,
          children: [
            Row(
              spacing: 8,
              children: [
                const Expanded(
                  child: Text('Filters', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                ),
                IconButton(
                  onPressed: () => update(
                    () => filterData = (type: 3, direction: 3, amountRange: null, pickedRange: null, categories: {}),
                  ),
                  icon: const Icon(Icons.restart_alt),
                  tooltip: 'Reset filters',
                ),
              ],
            ),
            const Divider(height: 0),
            const Text('Filter by Category', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              scrollDirection: Axis.horizontal,
              child: Row(
                spacing: 8,
                children: [
                  FilterChip(
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    selected: filterData.categories.isEmpty,
                    label: const Text('All'),
                    onSelected: (value) => update(() => filterData.categories.clear()),
                  ),
                  for (final cat in categories)
                    FilterChip(
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      selected: filterData.categories.contains(cat),
                      label: Text(cat),
                      onSelected: (value) =>
                          update(() => value ? filterData.categories.add(cat) : filterData.categories.remove(cat)),
                    ),
                ],
              ),
            ),
            const Text('Filter by Date', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ListTile(
              onTap: () async {
                final pickedRange = await showDateRangePicker(
                  context: context,
                  firstDate: DateTime(2000),
                  lastDate: DateTime.now(),
                );
                update(() => filterData = filterData.copyWith(pickedRange: pickedRange));
              },
              contentPadding: EdgeInsets.zero,
              title: Text(
                filterData.pickedRange != null
                    ? '${DateFormat('MMM d, y').format(filterData.pickedRange!.start)} - ${DateFormat('MMM d, y').format(filterData.pickedRange!.end)}'
                    : 'Please select a date',
                style: const TextStyle(fontSize: 16),
              ),
              trailing: const Icon(Icons.calendar_month_outlined),
            ),
            const Text('Filter by Amount', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            RangeSlider(
              min: minAmount,
              max: maxAmount,
              values: RangeValues(filterData.amountRange?.start ?? minAmount, filterData.amountRange?.end ?? maxAmount),
              labels: RangeLabels(
                filterData.amountRange?.start.toStringAsFixed(0) ?? '',
                filterData.amountRange?.end.toStringAsFixed(0) ?? '',
              ),
              divisions: 50,
              onChanged: (value) => update(() => filterData = filterData.copyWith(amountRange: value)),
            ),
            Center(
              child: Text(
                '${filterData.amountRange?.start.toStringAsFixed(0) ?? minAmount} - ${filterData.amountRange?.end.toStringAsFixed(0) ?? maxAmount}',
              ),
            ),
            // Row(
            //   children: [
            //     Expanded(
            //       child: CheckboxListTile(
            //         value: filterData.type % 2 == 1,
            //         title: const Text('Liquid'),
            //         onChanged: (value) {
            //           filterData = filterData.copyWith(type: value! ? filterData.type | 1 : 2);
            //           update();
            //         },
            //       ),
            //     ),
            //     Expanded(
            //       child: CheckboxListTile(
            //         title: const Text('Lightning'),
            //         value: filterData.type >= 2,
            //         onChanged: (value) {
            //           filterData = filterData.copyWith(type: value! ? (filterData.type == 1 ? 3 : 2) : 1);
            //           update();
            //         },
            //       ),
            //     ),
            //   ],
            // ),
            Row(
              children: [
                Expanded(
                  child: CheckboxListTile(
                    title: const Text('Incoming'),
                    value: filterData.direction % 2 == 1,
                    onChanged: (value) => update(
                      () => filterData = filterData.copyWith(direction: value! ? filterData.direction | 1 : 2),
                    ),
                  ),
                ),
                Expanded(
                  child: CheckboxListTile(
                    title: const Text('Outgoing'),
                    value: filterData.direction >= 2,
                    onChanged: (value) => update(
                      () =>
                          filterData = filterData.copyWith(direction: value! ? (filterData.direction == 1 ? 3 : 2) : 1),
                    ),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(onPressed: () => AppRouter.pop(filterData), child: const Text('Apply')),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
