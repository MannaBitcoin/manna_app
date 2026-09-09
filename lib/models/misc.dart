import 'dart:convert';

import 'package:manna/models/account.dart';
import 'package:manna/models/contact.dart';
import 'package:manna/models/wallet.dart';
import 'package:manna/utils/parser.dart';
import 'package:manna/utils/sats_extension.dart';
import 'package:manna_core/manna_core.dart' show Swap;

class Nullable<T> {
  Nullable(this.value);

  final T? value;
}

class AddressData {
  AddressData({
    required this.addressType,
    required this.address,
    this.amount = 0,
    this.lockAmount = false,
    this.memo,
    this.fallback,
    this.lnurlData,
    this.successAction,
  });

  final AddressType addressType;
  final String address;
  final int amount;
  final bool lockAmount;
  final String? memo;

  /// Optional fallback data in URI like
  /// bolt11 invoice https://github.com/theDavidCoen/BIP21-URIs-with-Lightning-invoice-fallback-to-on-chain-support
  final AddressData? fallback;
  final Map<String, dynamic>? lnurlData;
  final Map<String, dynamic>? successAction;

  AddressData copyWith({
    AddressType? addressType,
    String? address,
    int? amount,
    bool? lockAmount,
    Nullable<String?>? memo,
    Nullable<AddressData?>? fallback,
    Nullable<Map<String, dynamic>?>? successAction,
    Nullable<Map<String, dynamic>?>? lnurlData,
  }) => AddressData(
    addressType: addressType ?? this.addressType,
    address: address ?? this.address,
    amount: amount ?? this.amount,
    lockAmount: lockAmount ?? this.lockAmount,
    memo: memo != null ? memo.value : this.memo,
    fallback: fallback != null ? fallback.value : this.fallback,
    successAction: successAction != null ? successAction.value : this.successAction,
    lnurlData: lnurlData != null ? lnurlData.value : this.lnurlData,
  );

  Map<String, dynamic> _toMap() => {
    'addressType': addressType.name,
    'address': address,
    'amount': amount,
    'memo': memo,
    'fallback': fallback?._toMap(),
    'lnurlData': lnurlData,
    'successAction': successAction,
  };

  @override
  String toString() => jsonEncode(_toMap());
}

class PayOutData {
  PayOutData({
    required this.account,
    required this.liquidLockupAddress,
    required this.userEnteredAddress,
    required this.calculation,
    this.memo,
    this.note,
    this.category,
    this.swap,
    this.sendAll,
    this.receiverDetail,
    this.lnurlSuccessActionData,
    this.brantaData,
  });

  final Account account;
  final String liquidLockupAddress;
  final String userEnteredAddress;
  final FeesAndAmounts calculation;
  final Swap? swap;
  final bool? sendAll;
  final Contact? receiverDetail;
  final String? memo;
  final String? note;
  final Set<String>? category;

  // https://github.com/lnurl/luds/blob/luds/09.md
  final Map<String, dynamic>? lnurlSuccessActionData;
  final BrantaData? brantaData;

  PayOutData copyWith({
    Account? account,
    String? liquidLockupAddress,
    FeesAndAmounts? calculation,
    Nullable<String?>? memo,
    Nullable<String?>? note,
    Nullable<Set<String>?>? category,
    Nullable<Swap?>? swap,
    Nullable<Map<String, dynamic>?>? lnurlSuccessActionData,
    bool? sendAll,
    Nullable<Contact?>? receiverDetail,
    Nullable<BrantaData?>? brantaData,
  }) {
    return PayOutData(
      account: account ?? this.account,
      liquidLockupAddress: liquidLockupAddress ?? this.liquidLockupAddress,
      userEnteredAddress: userEnteredAddress,
      calculation: calculation ?? this.calculation,
      memo: memo != null ? memo.value : this.memo,
      note: note != null ? note.value : this.note,
      category: category != null ? category.value : this.category,
      swap: swap != null ? swap.value : this.swap,
      lnurlSuccessActionData: lnurlSuccessActionData != null
          ? lnurlSuccessActionData.value
          : this.lnurlSuccessActionData,
      sendAll: sendAll ?? this.sendAll,
      receiverDetail: receiverDetail != null ? receiverDetail.value : this.receiverDetail,
      brantaData: brantaData != null ? brantaData.value : this.brantaData,
    );
  }
}

class BrantaData {
  BrantaData({
    required this.verifyURL,
    required this.name,
    required this.logoLight,
    required this.logoDark,
    required this.desc,
  });

  factory BrantaData.fromMap(Map<String, dynamic> map) => BrantaData(
    verifyURL: parseString(map['verifyURL']),
    name: parseString(map['name']),
    logoLight: parseStringN(map['logoLight']),
    logoDark: parseStringN(map['logoDark']),
    desc: parseStringN(map['desc']),
  );

  final String verifyURL;
  final String name;
  final String? logoLight;
  final String? logoDark;
  final String? desc;

  Map<String, dynamic> toMap() => {
    'verifyURL': verifyURL,
    'name': name,
    'logoLight': logoLight,
    'logoDark': logoDark,
    'desc': desc,
  };
}

extension PrepareForToString on Map<String, dynamic> {
  Map<String, dynamic> toEncodeReady() => map((key, value) {
    dynamic newValue = value;
    if (newValue is DateTime) {
      newValue = newValue.toIso8601String();
    }
    if (newValue is BigInt) {
      newValue = newValue.toInt();
    }
    if (newValue is Map) {
      newValue = newValue.cast<String, dynamic>().toEncodeReady();
    }
    if (newValue is Set) {
      newValue = newValue.toList();
    }

    return MapEntry(key, newValue);
  });
}
