import 'dart:convert';

import 'package:breez_sdk_spark_flutter/breez_sdk_spark.dart'
    show Payment, serializePaymentToJson, deserializePaymentFromJson;
import 'package:manna/config.dart';
import 'package:manna/utils/extensions.dart';
import 'package:manna_core/manna_core.dart' hide Wallet;
import 'misc.dart';
import 'package:manna/services/db.dart';
import 'package:manna/utils/parser.dart';

class Transaction {
  Transaction({
    required this.txId,
    required this.network,
    required this.walletId,
    required this.inner,
    this.memo = '',
    this.note = '',
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
      inner: deserializePaymentFromJson(jsonStr: map['inner']),
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
  Payment inner;
  String memo;
  String note;
  bool isMemoSynced;
  String? senderUUID;
  String? receiverUserNameOrUUID;
  Set<String> categories = {};

  Map<String, dynamic> extraMetadata = {};

  IdWithWallet get metaId => IdWithWallet(walletId: walletId, id: txId);

  DateTime get timestamp => DateTime.fromMillisecondsSinceEpoch(inner.timestamp.i * 1000);

  Future<void> update({
    Payment? inner,
    String? memo,
    String? note,
    bool? isMemoSynced,
    Nullable<String?>? senderUUID,
    Nullable<String?>? receiverUserNameOrUUID,
    Set<String>? categories,
    Map<String, dynamic>? extraMetadata,
  }) {
    this.inner = inner ?? this.inner;
    this.memo = memo ?? this.memo;
    this.note = note ?? this.note;
    this.isMemoSynced = isMemoSynced ?? this.isMemoSynced;
    this.senderUUID = senderUUID != null ? senderUUID.value : this.senderUUID;
    this.receiverUserNameOrUUID = receiverUserNameOrUUID != null
        ? receiverUserNameOrUUID.value
        : this.receiverUserNameOrUUID;
    this.categories = categories ?? this.categories;
    this.extraMetadata = extraMetadata ?? this.extraMetadata;
    return save();
  }

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

  Map<String, dynamic> toMap() => {
    'txId': txId,
    'network': network.index,
    'walletId': walletId,
    'inner': serializePaymentToJson(payment: inner),
    'memo': memo,
    'note': note,
    'isNoteSynced': isMemoSynced,
    'senderUUID': senderUUID,
    'receiverUserNameOrUUID': receiverUserNameOrUUID,
    'categories': categories,
    'extraMetadata': extraMetadata,
  }.toEncodeReady();

  @override
  String toString() => jsonEncode(toMap());
}
