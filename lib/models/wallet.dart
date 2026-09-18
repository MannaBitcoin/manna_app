import 'dart:async';
import 'dart:convert';
import 'package:breez_sdk_spark_flutter/breez_sdk_spark.dart'
    show BreezSdk, ReceivePaymentRequest, ReceivePaymentMethod;
import 'package:manna/models/account.dart';
import 'package:manna/services/wallet_service.dart';
import 'package:manna/utils/parser.dart';
import 'package:manna_core/manna_core.dart';
import 'package:manna/services/db.dart';
import 'package:uuid/v5.dart';

export 'enums.dart';
import 'misc.dart';

// Data from supabase database
class WalletMetaData {
  WalletMetaData({
    required this.uuid,
    required this.userName,
    required this.bolt11ShortDesc,
    required this.about,
    required this.picture,
    required this.banner,
  });

  factory WalletMetaData.fromMap(Map<String, dynamic> map) => WalletMetaData(
    uuid: parseString(map['uuid']),
    userName: parseString(map['user_name']),
    bolt11ShortDesc: parseString(map['bolt11_short_desc']),
    about: parseStringN(map['about']),
    picture: parseStringN(map['picture']),
    banner: parseStringN(map['banner']),
  );

  factory WalletMetaData.fromMapWO(Map<String, dynamic> map) => WalletMetaData(
    uuid: parseString(map['uuid']),
    userName: parseString(map['user_name']),
    bolt11ShortDesc: parseString(map['bolt11_short_desc']),
    about: parseStringN(map['about']),
    picture: parseStringN(map['picture']),
    banner: parseStringN(map['banner']),
  );

  final String uuid;
  final String userName;
  final String bolt11ShortDesc;
  final String? about;
  final String? picture;
  final String? banner;

  Map<String, dynamic> toMap() => {
    'uuid': uuid,
    'userName': userName,
    'bolt11ShortDesc': bolt11ShortDesc,
    'about': about,
    'picture': picture,
    'banner': banner,
  };
}

/// String(UUID_walletType): [WalletMetaData]
final Map<String, WalletMetaData> walletDataMap = {};

class Wallet {
  Wallet({required this.accountId, required this.xpub, required this.network, required this.type, this.balance = 0})
    : uuid = Wallet.generateUuid(xpub: xpub);

  factory Wallet.fromMap(Map<String, dynamic> map) {
    return Wallet(
      accountId: parseString(map['accountId']),
      xpub: parseString(map['xpub']),
      network: Network.values[parseInt(map['network'])],
      type: WalletType.values[parseInt(map['walletType'])],
      balance: parseIntN(map['balance']) ?? 0,
    );
  }

  final String accountId;
  final String uuid;
  final String xpub;
  final Network network;
  final WalletType type;
  int balance;

  Account get account {
    final account = DB.accounts[accountId];
    if (account != null) return account;

    throw Exception('How did we get here?');
  }

  WalletMetaData? get metaData => walletDataMap['${uuid}_${type.name}'];

  BreezSdk? get spark => WalletService.sparkNodes[xpub]?.$1;

  Future<String?> getSparkAddress() async {
    return (await spark?.receivePayment(
      request: const ReceivePaymentRequest(paymentMethod: ReceivePaymentMethod.sparkAddress()),
    ))?.paymentRequest;
  }

  Future<void> update({int? balance}) {
    this.balance = balance ?? this.balance;
    return save();
  }

  Future<void> save() async {
    if (type == WalletType.full) {
      await DB.walletBox.put(uuid, this);
    }
    DB.loadWallets();
  }

  Future<void> delete() async {
    if (type == WalletType.full) {
      await DB.walletBox.delete(uuid);
    }
    DB.loadWallets();
  }

  String get contactWalletId => Wallet.generateContactWalletId(xpub: xpub, type: type);

  Map<String, dynamic> toMap() => {
    'accountId': accountId,
    'uuid': uuid,
    'xpub': xpub,
    'network': network.index,
    'walletType': type.index,
    'balance': balance,
  }.toEncodeReady();

  @override
  String toString() => jsonEncode(toMap());

  static String generateUuid({required String xpub}) =>
      const UuidV5().generate('d8a36b29-21dc-4caa-a004-163606cdfe70', xpub);

  static String generateContactWalletId({required String xpub, required WalletType type}) =>
      const UuidV5().generate('d8a36b29-21dc-4caa-a004-163606cdfe70', '${xpub}_$type');

  @override
  bool operator ==(Object other) => other is Wallet && other.uuid == uuid && other.type == type;

  @override
  int get hashCode => Object.hash(uuid, type);
}
