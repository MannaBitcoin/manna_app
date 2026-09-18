import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dio/dio.dart';
import 'package:manna/config.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna_core/manna_core.dart';
import 'package:breez_sdk_spark_flutter/breez_sdk_spark.dart' as spark;

import 'constants.dart';

extension IntToBigInt on num {
  BigInt get bigInt => BigInt.from(this);
}

extension BigIntToIng on BigInt {
  int get i => toInt();
}

extension StringExtensions on String {
  String get capitalize => isNotEmpty ? this[0].toUpperCase() + substring(1) : '';

  String get shortName => split(' ').map((e) => e.isNotEmpty ? e[0].toUpperCase() : '').take(2).join();

  String shortenAddress({int charCount = 8}) =>
      length < 12 ? this : substring(0, charCount) + '.' * charCount + substring(length - charCount, length);

  Uint8List get hexStringToBytes => Uint8List.fromList(hex.decode(this));

  Uint8List? get byteaToUint8List {
    if (startsWith(r'\x')) {
      try {
        return Uint8List.fromList(hex.decode(substring(2)));
      } catch (e, s) {
        logE(e, stackTrace: s);
      }
    }
    return null;
  }

  bool get isUserName => Regexes.internetAddress.hasMatch(trim());

  bool get isMannaUserName => isUserName && trim().endsWith(Config.current.serverUrl);

  String? get getUserName => Regexes.internetAddress.firstMatch(trim())?.group(1);

  String toMannaLNURL({bool withWrap = false}) => '${trim()}${withWrap ? '\u200b' : ''}@${Config.current.serverUrl}';

  bool get isUUID => RegExp(
    r'^(?:[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}|00000000-0000-0000-0000-000000000000)$',
  ).hasMatch(this);
}

extension Uint8ListExtension on Uint8List {
  String get toHexString => hex.encode(this);

  String get toBytea => r'\x' + hex.encode(this);
}

extension DioResExtension on Response {
  bool get isSuccess => (statusCode ?? 0) >= 200 && (statusCode ?? 0) < 300;
}

extension CaseInsesitiveQueryExtension on Uri {
  String? getQueryParam(String key) => queryParameters[key.toUpperCase()] ?? queryParameters[key.toLowerCase()];
}

extension SparkNetworkExtension on Network {
  spark.Network get to => switch (this) {
    Network.mainnet => spark.Network.mainnet,
    Network.regtest => spark.Network.regtest,
    Network.testnet => throw UnimplementedError(),
  };

  spark.BitcoinNetwork get toBTC => switch (this) {
    Network.mainnet => spark.BitcoinNetwork.bitcoin,
    Network.regtest => spark.BitcoinNetwork.regtest,
    Network.testnet => spark.BitcoinNetwork.testnet4,
  };
}