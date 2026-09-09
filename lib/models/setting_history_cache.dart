import 'dart:async';
import 'dart:convert';

import 'package:manna/models/misc.dart';
import 'package:manna/services/db.dart';
import 'package:manna/utils/parser.dart';
import 'package:manna_core/manna_core.dart';

class SettingHistoryCache {
  SettingHistoryCache({
    required this.id,
    required this.key,
    required this.network,
    required this.value,
    required this.effectiveAtUTC,
    this.previousValue,
  });

  factory SettingHistoryCache.fromMap(Map<String, dynamic> map, Network network) => SettingHistoryCache(
    id: parseInt(map['id']),
    key: parseString(map['key']),
    network: network,
    previousValue: parseStringN(map['previous_value']),
    value: parseString(map['new_value']),
    effectiveAtUTC: parseDateTime(map['effective_at']),
  );

  final int id;
  final String key;
  final Network network;
  final String? previousValue;
  final String value;
  final DateTime effectiveAtUTC;

  DateTime get effectiveAt => effectiveAtUTC.toLocal();

  Future<void> save() => DB.settingHistory.box.put(id, this);

  Future<void> delete() => DB.settingHistory.box.delete(id);

  @override
  String toString() => jsonEncode(
    {
      'id': id,
      'key': key,
      'network': network.name,
      'previous_value': previousValue,
      'new_value': value,
      'effective_at': effectiveAtUTC,
    }.toEncodeReady(),
  );
}
