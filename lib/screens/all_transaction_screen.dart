import 'package:breez_sdk_spark_flutter/breez_sdk_spark.dart';
import 'package:flutter/material.dart';
import 'package:manna/globals.dart';
import 'package:manna/models/transaction.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/transaction_service.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/widgets/transaction_card.dart';
import 'package:manna/widgets/bottom sheets/transaction_filter_bottom_sheet.dart';

// direction: 1 incoming 2 outgoing 3 all
// type: 3 bit int
//    1st bit : lightning
//    2nd bit : bitcoin
//    3rd bit : spark
typedef FilterData = ({
  DateTimeRange? pickedRange,
  RangeValues? amountRange,
  int direction,
  int type,
  Set<String> categories,
});

extension FilterDataExtension on FilterData {
  FilterData copyWith({int? type, int? direction, RangeValues? amountRange, DateTimeRange? pickedRange}) {
    return (
      type: type ?? this.type,
      direction: direction ?? this.direction,
      amountRange: amountRange ?? this.amountRange,
      pickedRange: pickedRange ?? this.pickedRange,
      categories: categories,
    );
  }
}

class AllTransactionScreen extends StatefulWidget {
  const AllTransactionScreen({required this.accountId, super.key});

  final String accountId;

  @override
  State<AllTransactionScreen> createState() => _AllTransactionScreenState();
}

class _AllTransactionScreenState extends State<AllTransactionScreen> {
  FilterData filterData = (type: 7, direction: 3, amountRange: null, pickedRange: null, categories: <String>{});
  List<Transaction> sortedTransactions = [];

  @override
  void initState() {
    refreshData();
    GlobalListener.addListener(
      stream: .account,
      listenerName: runtimeType.toString(),
      callback: (data) {
        if (data is String && data == widget.accountId) {
          refreshData();
          return true;
        }
        return false;
      },
    );
    super.initState();
  }

  @override
  void dispose() {
    GlobalListener.removeListener(stream: .account, listenerName: runtimeType.toString());
    super.dispose();
  }

  void refreshData() {
    sortedTransactions = getFilteredTransactions().toList();
    sortedTransactions.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    update();
  }

  List<Transaction> getFilteredTransactions() {
    final walletId = DB.accounts[widget.accountId]?.currentWallet.uuid;
    if (walletId == null) return [];

    return DB.transactions.values
        .where(
          (e) =>
              e.walletId == walletId &&
              (filterData.categories.isEmpty || filterData.categories.any((c) => e.categories.contains(c))) &&
              (filterData.pickedRange == null ||
                  ((e.timestamp.isAfter(filterData.pickedRange!.start)) &&
                      (e.timestamp.isBefore(filterData.pickedRange!.end)))) &&
              (filterData.amountRange == null ||
                  (e.inner.amount.i.abs() >= filterData.amountRange!.start &&
                      e.inner.amount.i.abs() <= filterData.amountRange!.end)) &&
              (filterData.type == 0 ||
                  filterData.type == 7 ||
                  (filterData.type & 4 != 0 && e.inner.details is PaymentDetails_Lightning) ||
                  (filterData.type & 2 != 0 && e.inner.details is PaymentDetails_Deposit ||
                      e.inner.details is PaymentDetails_Withdraw) ||
                  (filterData.type & 1 != 0 && e.inner.details is PaymentDetails_Spark)) &&
              (filterData.direction == 3 ||
                  (filterData.direction == 1 && e.inner.paymentType == PaymentType.receive) ||
                  (filterData.direction == 2 && e.inner.paymentType == PaymentType.send)),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Transactions'),
        actions: [
          IconButton(
            onPressed: () async {
              final res = await showModalBottomSheet(
                context: context,
                showDragHandle: true,
                isScrollControlled: true,
                useSafeArea: true,
                shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
                routeSettings: const RouteSettings(name: 'TransactionFilterBottomSheet'),
                builder: (context) => TransactionFilterBottomSheet(accountId: widget.accountId, filterData: filterData),
              );
              if (res is FilterData) {
                filterData = res;
                refreshData();
              }
            },
            icon: const Icon(Icons.filter_alt_outlined),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              final wallet = DB.currentWallets.where((w) => w.accountId == widget.accountId).firstOrNull;
              if (wallet != null) {
                TransactionService.exportTransactions(transactions: getFilteredTransactions());
              }
            },
            icon: const Icon(Icons.more_vert),
            itemBuilder: (BuildContext context) => [
              const PopupMenuItem(
                value: 'export',
                padding: EdgeInsets.only(left: 12),
                child: Text('Export transaction', style: TextStyle(fontSize: 16)),
              ),
            ],
          ),
        ],
      ),
      body: sortedTransactions.isNotEmpty
          ? ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: sortedTransactions.length,
              itemBuilder: (context, index) =>
                  TransactionCard(tx: sortedTransactions[index], hideAmount: false, shouldShowCategory: true),
            )
          : const Center(child: Text('No transaction found!')),
    );
  }
}
