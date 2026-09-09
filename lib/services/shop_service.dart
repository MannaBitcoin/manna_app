import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:manna/app_state.dart';
import 'package:manna/models/shop_item.dart';
import 'package:manna/models/tax.dart';
import 'package:manna/models/wallet.dart';
import 'package:manna/router.dart';
import 'package:manna/services/biometric_services.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/log_service.dart';
import 'package:manna/services/wallet_service.dart';
import 'package:manna/utils/parser.dart';
import 'package:manna/utils/state_extension.dart';
import 'package:manna/utils/toast_service.dart';
import 'package:share_plus/share_plus.dart';

class ShopService {
  static String get shopName => AppState.prefs.getString('shopName')?.trim() ?? 'Shop';
  static set shopName(String name) => AppState.prefs.setString('shopName', name.trim());

  static Future<void> importShopData() async {
    if (!(await BiometricService.authenticateBiometricsIfExists(message: 'Please authenticate to import!'))) {
      return;
    }
    try {
      final FilePickerResult? result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['txt']);
      if (result != null) {
        final jsonData = await File(result.files.single.path!).readAsString();
        final data = jsonDecode(jsonData);
        if (data['items'] is List) {
          for (final d in data['items']) {
            await ShopItem.fromMap(d).save();
          }
          if (data['category_images'] is Map) {
            for (final d in (data['category_images'] as Map).cast<String, String>().entries) {
              await DB.categoryImages.box.put(d.key, base64Decode(d.value));
            }
          }
          if (data['isTipsEnabled'] is bool) {
            AppState.isShopTipsOn = parseBool(data['isTipsEnabled']);
          }
          if (data['taxes'] is List) {
            for (final t in data['taxes']) {
              await Tax.fromMap(t).save();
            }
          }
          if (data['wallet_descriptor'] is String) {
            await WalletService.importWatchOnlyWallet(
              accountName: 'Shop wallet',
              walletDescriptor: parseString(data['wallet_descriptor']),
            );
          }
          final name = parseString(data['shopName']).trim();
          if (name.isNotEmpty) {
            shopName = name;
          }
          return ToastService.show('Shop data imported successfully');
        } else {
          return ToastService.show('Invalid data format');
        }
      }
    } catch (e) {
      logE(e);
    }
    return ToastService.show('Failed to import item data');
  }

  static Map<String, dynamic> _prepareExportData(Wallet wallet) {
    return {
      'shopName': shopName,
      'items': DB.shopItemBox.values.map((e) => e.toMap()).toList(),
      'category_images': DB.categoryImages.values.map((e) => base64Encode(e)).toList(),
      'isTipsEnabled': AppState.isShopTipsOn,
      'taxes': DB.taxes.values.map((e) => e.toMap()).toList(),
      'wallet_descriptor': wallet.descriptor,
    };
  }

  static Future<void> exportShopData(Wallet wallet) async {
    if (!(await BiometricService.authenticateBiometricsIfExists(message: 'Please authenticate to export!'))) {
      return;
    }
    try {
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile.fromData(utf8.encode(jsonEncode(_prepareExportData(wallet))), mimeType: 'text/plain')],
          fileNameOverrides: ['shop_data.txt'],
          sharePositionOrigin: AppRouter.navigatorContext.sharePlusRect,
        ),
      );
      if (result.status == ShareResultStatus.success) {
        return ToastService.show('Shop data exported successfully');
      }
    } catch (e) {
      logE(e);
    }
    return ToastService.show('Failed to export item data');
  }

  static Future<void> downloadShopData(Wallet wallet) async {
    if (!(await BiometricService.authenticateBiometricsIfExists(message: 'Please authenticate to download!'))) {
      return;
    }
    try {
      final now = DateTime.now();
      final selectedDirectory = await FileSaver.instance.saveAs(
        name: 'ItemData_${now.year}_${now.month}_${now.day}_${now.hour}_${now.minute}',
        bytes: utf8.encode(jsonEncode(_prepareExportData(wallet))),
        fileExtension: 'txt',
        mimeType: MimeType.text,
      );

      if (selectedDirectory?.isNotEmpty ?? false) {
        return ToastService.show('File saved at: $selectedDirectory');
      }
    } catch (e) {
      logE(e);
    }
    return ToastService.show('No directory selected.');
  }
}
