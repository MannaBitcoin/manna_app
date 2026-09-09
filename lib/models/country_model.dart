import 'dart:convert';

import 'package:manna/utils/parser.dart';

class CountryModel {
  CountryModel({
    required this.name,
    required this.nameOfficial,
    required this.flag,
    required this.languageCode,
    required this.languageName,
    required this.currencyCode,
    required this.currencyName,
    required this.currencySymbol,
  });

  factory CountryModel.fromMap(Map<String, dynamic> d) {
    final currencyCode = parseString((d['currencies'] as Map).keys.first ?? '');
    final languageCode = parseString((d['languages'] as Map).keys.first);
    return CountryModel(
      name: parseString(d['name']['common']),
      nameOfficial: parseString(d['name']['official']),
      flag: parseString(d['flags']['svg'] ?? d['flags']['png']),
      currencyCode: currencyCode,
      currencyName: parseString(d['currencies'][currencyCode]['name']),
      currencySymbol: parseString(d['currencies'][currencyCode]['symbol']),
      languageCode: languageCode,
      languageName: parseString(d['languages'][languageCode]),
    );
  }

  factory CountryModel.fromPrefs(String data) {
    final json = jsonDecode(data);
    return CountryModel(
      name: parseString(json['name']),
      nameOfficial: parseString(json['nameOfficial']),
      flag: parseString(json['flag']),
      languageCode: parseString(json['languageCode']),
      languageName: parseString(json['languageName']),
      currencyCode: parseString(json['currencyCode']),
      currencyName: parseString(json['currencyName']),
      currencySymbol: parseString(json['currencySymbol']),
    );
  }

  final String name;
  final String nameOfficial;
  final String flag;
  final String languageCode;
  final String languageName;
  final String currencyCode;
  final String currencyName;
  final String currencySymbol;

  String get countryCode => flag.split('/').last.split('.').first;

  String get countryFlag => flag.split('/').last;

  Map<String, dynamic> toJson() => {
    'name': name,
    'nameOfficial': nameOfficial,
    'flag': flag,
    'languageCode': languageCode,
    'languageName': languageName,
    'currencyCode': currencyCode,
    'currencyName': currencyName,
    'currencySymbol': currencySymbol,
  };

  @override
  int get hashCode =>
      Object.hash(name, nameOfficial, flag, languageCode, languageName, currencyCode, currencyName, currencySymbol);

  @override
  bool operator ==(Object other) =>
      other is CountryModel &&
      name == other.name &&
      nameOfficial == other.nameOfficial &&
      flag == other.flag &&
      languageCode == other.languageCode &&
      languageName == other.languageName &&
      currencyCode == other.currencyCode &&
      currencyName == other.currencyName &&
      currencySymbol == other.currencySymbol;
}
