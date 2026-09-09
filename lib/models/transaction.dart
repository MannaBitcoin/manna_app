import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:manna/config.dart';
import 'package:manna/models/swap.dart';
import 'package:manna/services/transaction_service.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna/utils/sats_extension.dart';
import 'package:manna_core/manna_core.dart' hide Wallet;
import 'misc.dart';
import 'package:manna/services/db.dart';
import 'package:manna/utils/parser.dart';

class Transaction {
  Transaction({
    required this.txId,
    required this.network,
    required this.walletId,
    required this.amount,
    required this.timestamp,
    required this.isIncoming,
    this.memo = '',
    this.note = '',
    this.liquidTx,
    this.isMemoSynced = false,
    this.senderUUID,
    this.receiverUserNameOrUUID,
    Set<String>? categories,
    Map<String, dynamic>? extraMetadata,
  }) {
    this.categories = categories ?? {};
    this.extraMetadata = extraMetadata ?? {};
  }

  factory Transaction.fromMap(Map<String, dynamic> map) {
    return Transaction(
      txId: parseString(map['txId']),
      network: Network.values[parseIntN(map['network']) ?? 0],
      walletId: parseString(map['walletId']),
      amount: parseInt(map['amount']),
      timestamp: parseDateTime(map['timestamp']),
      isIncoming: parseBool(map['isIncoming']),
      memo: parseString(map['memo']),
      note: parseString(map['note']),
      isMemoSynced: parseBool(map['isNoteSynced']),
      senderUUID: parseStringN(map['senderUUID']),
      receiverUserNameOrUUID: parseStringN(map['receiverUserNameOrUUID']),
      categories: parseSet(map['categories'], (e) => parseString(e)),
      extraMetadata: parseMap(map['extraMetadata'], (k, v) => MapEntry(parseString(k), v)),
    );
  }

  final String txId;
  final Network network;
  final String walletId;
  int amount;
  final DateTime timestamp;
  final bool isIncoming;
  String memo;
  String note;
  Tx? liquidTx;
  bool isMemoSynced;
  String? senderUUID;
  String? receiverUserNameOrUUID;
  Set<String> categories = {};

  Map<String, dynamic> extraMetadata = {};

  Future<void> update({
    int? amount,
    String? memo,
    String? note,
    Nullable<Tx?>? liquidTx,
    bool? isMemoSynced,
    Nullable<String?>? senderUUID,
    Nullable<String?>? receiverUserNameOrUUID,
    Set<String>? categories,
    Map<String, dynamic>? extraMetadata,
  }) {
    this.amount = amount ?? this.amount;
    this.memo = memo ?? this.memo;
    this.note = note ?? this.note;
    this.liquidTx = liquidTx != null ? liquidTx.value : this.liquidTx;
    this.isMemoSynced = isMemoSynced ?? this.isMemoSynced;
    this.senderUUID = senderUUID != null ? senderUUID.value : this.senderUUID;
    this.receiverUserNameOrUUID = receiverUserNameOrUUID != null
        ? receiverUserNameOrUUID.value
        : this.receiverUserNameOrUUID;
    this.categories = categories ?? this.categories;
    this.extraMetadata = extraMetadata ?? this.extraMetadata;
    return save();
  }

  IdWithWallet get metaId => IdWithWallet(walletId: walletId, id: txId);

  Future<void> save() async {
    final id = metaId;
    await DB.transactionBox.put(id.toString(), this);
    final t = DB.transactionBox.get(id.toString());
    if (t != null) {
      DB.allTransactions[id] = t;
      if (t.network == Config.network) DB.transactions[id] = t;
    }
  }

  Future<void> delete() async {
    await DB.transactionBox.delete(metaId.toString());
    DB.allTransactions.remove(metaId);
    if (network == Config.network) DB.transactions.remove(metaId);
  }

  DateTime? get confirmationTimestamp =>
      liquidTx?.height != null ? DateTime.fromMillisecondsSinceEpoch((liquidTx?.timestamp ?? 0) * 1000) : null;

  DateTime get txTimestamp => confirmationTimestamp ?? timestamp; // i am out of idea for the name of this getter

  Swap? get linkedSwap => DB.swaps.values.where((s) => s.transactions.map((e) => e.txId).contains(txId)).firstOrNull;

  bool get isCompleted => (linkedSwap?.isClosed ?? true) && liquidTx?.height != null;

  int mannaFees() {
    final swap = linkedSwap;
    final traType = swap?.getTransactionType ?? (isIncoming ? TraType.lbtcToLbtcReceive : TraType.lbtcToLbtcSend);

    return max(
      getTemporaryMannaFee((swap?.sendAmount.i ?? amount.abs()) - (liquidTx?.fee.i ?? 0), traType, txTimestamp),
      getMannaFees(
        receiveAmount: swap?.receiveAmount.i ?? (amount.abs() - (liquidTx?.fee.i ?? 0)),
        isSendAll: liquidTx?.outputs.isEmpty ?? false,
        type: traType,
        dateTime: txTimestamp,
      ),
    );
  }

  Map<String, dynamic> toMap() => {
    'txId': txId,
    'network': network.index,
    'walletId': walletId,
    'amount': amount,
    'timestamp': timestamp,
    'isIncoming': isIncoming,
    'memo': memo,
    'note': note,
    'liquidTx': liquidTx?.toJsonString(),
    'isNoteSynced': isMemoSynced,
    'senderUUID': senderUUID,
    'receiverUserNameOrUUID': receiverUserNameOrUUID,
    'categories': categories,
    'extraMetadata': extraMetadata,
  }.toEncodeReady();

  @override
  String toString() => jsonEncode(toMap());
}
