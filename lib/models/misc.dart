import 'package:breez_sdk_spark_flutter/breez_sdk_spark.dart' show InputType;
import 'package:manna/models/account.dart';
import 'package:manna/models/contact.dart';
import 'package:manna/models/enums.dart';
import 'package:manna/utils/parser.dart';
import 'package:manna/utils/sats_extension.dart';

class Nullable<T> {
  Nullable(this.value);

  final T? value;
}

class AddressData {
  AddressData({
    required this.addressType,
    required this.data,
    required this.address,
    this.amount = 0,
    this.lockAmount = false,
    this.comment,
    this.fallback,
  });

  final AddressType addressType;
  final InputType? data;
  final String address;
  final int amount;
  final bool lockAmount;
  final String? comment;

  /// Optional fallback data in URI like
  /// bolt11 invoice https://github.com/theDavidCoen/BIP21-URIs-with-Lightning-invoice-fallback-to-on-chain-support
  final AddressData? fallback;

  AddressData copyWith({
    AddressType? addressType,
    InputType? data,
    String? address,
    int? amount,
    bool? lockAmount,
    Nullable<String?>? comment,
    Nullable<AddressData?>? fallback,
  }) => AddressData(
    addressType: addressType ?? this.addressType,
    data: data ?? this.data,
    address: address ?? this.address,
    amount: amount ?? this.amount,
    lockAmount: lockAmount ?? this.lockAmount,
    comment: comment != null ? comment.value : this.comment,
    fallback: fallback != null ? fallback.value : this.fallback,
  );
}

class PayOutData {
  PayOutData({
    required this.account,
    required this.userEnteredAddress,
    required this.calculation,
    required this.addressData,
    this.note,
    this.category,
    this.receiverDetail,
    this.brantaData,
  });

  final Account account;
  final String userEnteredAddress; // used to show on confirm screen
  final AddressData addressData;
  final FeesAndAmounts calculation;
  final Contact? receiverDetail;
  final String? note;
  final Set<String>? category;
  final BrantaData? brantaData;

  PayOutData copyWith({
    Account? account,
    FeesAndAmounts? calculation,
    AddressData? addressData,
    Nullable<String?>? note,
    Nullable<Set<String>?>? category,
    Nullable<Contact?>? receiverDetail,
    Nullable<BrantaData?>? brantaData,
  }) {
    return PayOutData(
      account: account ?? this.account,
      userEnteredAddress: userEnteredAddress,
      calculation: calculation ?? this.calculation,
      addressData: addressData ?? this.addressData,
      note: note != null ? note.value : this.note,
      category: category != null ? category.value : this.category,
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
