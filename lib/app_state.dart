import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:manna/config.dart';
import 'package:manna/models/country_model.dart';
import 'package:manna/services/secure_storage.dart';
import 'package:manna_core/manna_core.dart';
import 'package:shared_preference_app_group/shared_preference_app_group.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppState {
  static late SharedPreferences prefs;

  static bool isAuthenticated = false;
  static double btcPrice = 0;

  static Map<int, String> get blockExplorers =>
      Config.network == Network.regtest ? {0: 'Manna'} : {0: 'BlockStream', 1: 'Mempool.space', 2: 'BullBitcoin'};

  static bool get isPrivacyModeOn => prefs.getBool('isPrivacyModeOn') ?? false;
  static bool get isShopTipsOn => prefs.getBool('isStoreTipsOn') ?? false;
  static int get blockExplorer => prefs.getInt('blockExplorer') ?? 0;
  static int get bitcoinDisplayStyle => prefs.getInt('bitcoinDisplayStyle') ?? 0;
  static ThemeMode get theme => ThemeMode.values[prefs.getInt('theme') ?? 0];
  static bool get isSoundEffectsOn => prefs.getBool('isSoundEffectsOn') ?? false;
  static bool get openShopOnBoot => prefs.getBool('openShopOnBoot') ?? false;

  static set isPrivacyModeOn(bool value) => prefs.setBool('isPrivacyModeOn', value);
  static set isShopTipsOn(bool value) => prefs.setBool('isStoreTipsOn', value);
  static set blockExplorer(int value) => prefs.setInt('blockExplorer', value);
  static set bitcoinDisplayStyle(int value) {
    prefs.setInt('bitcoinDisplayStyle', value);
    if (Platform.isIOS) SharedPreferenceAppGroup.setInt('bitcoinDisplayStyle', value);
  }

  static set theme(ThemeMode value) => prefs.setInt('theme', value.index);
  static set isSoundEffectsOn(bool value) => prefs.setBool('isSoundEffectsOn', value);
  static set openShopOnBoot(bool value) => prefs.setBool('openShopOnBoot', value);

  static CountryModel get selectedCurrency => CountryModel.fromPrefs(prefs.getString('selectedCurrency') ?? '{}');
  static set selectedCurrency(CountryModel model) => prefs.setString('selectedCurrency', jsonEncode(model.toJson()));

  // currency code: currency Symbol
  static final Map<String, String> currencySymbols = {};

  static Future<void> init({bool minimal = false}) async {
    prefs = await SharedPreferences.getInstance();
    await SecureStorage.init(iOSAccessGroup: 'group.com.lightning.manna');
    if (minimal) return;

    if (Platform.isIOS) {
      await SharedPreferenceAppGroup.setAppGroup('group.com.lightning.manna');
    }
    if (Platform.isIOS && !prefs.containsKey('isIpad')) {
      final info = await DeviceInfoPlugin().iosInfo;
      if (info.name.toLowerCase().contains('ipad')) {
        await prefs.setBool('isIpad', true);
      }
    }
    if (!prefs.containsKey('isSoundEffectsOn')) {
      await prefs.setBool('isSoundEffectsOn', true);
    }

    if (!blockExplorers.containsKey(blockExplorer)) {
      blockExplorer = blockExplorers.keys.first;
    }

    unawaited(
      rootBundle.loadString('assets/data/country.json').then((json) {
        final countryCode = WidgetsBinding.instance.platformDispatcher.locale.countryCode?.toLowerCase() ?? 'us';

        for (final m in (jsonDecode(json) as List).map((e) => CountryModel.fromMap(e))) {
          currencySymbols[m.currencyCode.toLowerCase()] = m.currencySymbol;

          if (selectedCurrency.languageCode.isEmpty && m.countryCode.toLowerCase() == countryCode) {
            selectedCurrency = m;
          }
        }
      }),
    );
  }
}
