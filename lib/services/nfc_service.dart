import 'dart:convert';
import 'dart:io';

import 'package:app_settings/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:manna/router.dart';
import 'package:manna/services/db.dart';
import 'package:manna/services/deep_link_service.dart';
import 'package:manna/services/log_service.dart';
import 'package:nfc_manager/ndef_record.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager_ndef/nfc_manager_ndef.dart';

class NfcService {
  static const androidChannel = MethodChannel('com.lightning.manna/nfc');

  static void storeInitialNFCAppOpen() async {
    if (!Platform.isAndroid) return;

    final initialNfcData = await androidChannel.invokeMethod<String?>('getInitialNFCData');
    if (initialNfcData?.isNotEmpty ?? false) {
      await DB.setInitialDeepLinkURI(initialNfcData.toString());
    }
  }

  static Future<NfcAvailability> getNFCState() async {
    if (Platform.isIOS) return NfcAvailability.unsupported;
    if (!(Platform.isAndroid || Platform.isIOS)) return NfcAvailability.unsupported;
    return NfcManager.instance.checkAvailability();
  }

  /// asks user to turn on NFC on android
  static Future<void> turnOnNFCIfOff() async {
    if (Platform.isIOS) return;
    if (Platform.isAndroid && await getNFCState() == NfcAvailability.disabled && AppRouter.navigatorContext.mounted) {
      await showDialog(
        context: AppRouter.navigatorContext,
        builder: (context) => AlertDialog(
          title: const Text('Turn on NFC'),
          actions: [
            TextButton(onPressed: () => AppRouter.pop(), child: const Text('Cancel')),
            TextButton(
              onPressed: () {
                AppRouter.pop();
                AppSettings.openAppSettings(type: AppSettingsType.nfc);
              },
              child: const Text('Turn on NFC', textAlign: TextAlign.center),
            ),
          ],
        ),
      );
    }
  }

  static Future<void> start({bool force = false}) async {
    if (Platform.isIOS) return;
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    if (!force && Platform.isIOS) {
      return;
    }
    if (force) await turnOnNFCIfOff();
    if (await getNFCState() != NfcAvailability.enabled) return;

    await NfcManager.instance.startSession(
      pollingOptions: {NfcPollingOption.iso14443},
      invalidateAfterFirstReadIos: false,
      onDiscovered: (tag) async {
        try {
          final ndef = Ndef.from(tag);
          if (ndef != null) {
            final message = await ndef.read();
            if (message != null) {
              for (final record in message.records) {
                if (record.typeNameFormat == TypeNameFormat.wellKnown) {
                  final text = extractText(record.payload);
                  if (text != null && await DeepLinkService.processUri(Uri.parse(text))) {
                    stop();
                    break;
                  }
                }
              }
            }
          }
        } catch (e, s) {
          logE(e, stackTrace: s);
        }
      },
    );
  }

  static void stop() async {
    if (Platform.isIOS) return;
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    if ((await getNFCState()) == NfcAvailability.unsupported) return;
    try {
      await NfcManager.instance.stopSession();
    } catch (e, s) {
      logE(e, stackTrace: s);
    }
  }

  // static Future<bool> broadcastAddress(String address) async {
  //   if (!Platform.isAndroid) return false;
  //
  //   await turnOnNFCIfOff();
  //   if (await getNFCState() != NfcAvailability.enabled) return false;
  //
  //   try {
  //     return await androidPlatform.invokeMethod<bool>('startNFC_HCE', {'uri': address}) ?? false;
  //   } catch (e, s) {
  //     logE(e, stackTrace: s);
  //   }
  //   return false;
  // }

  //   static Future<bool> stopBroadCasting() async {
  //     if (!Platform.isAndroid) return false;
  //     try {
  //       return await androidPlatform.invokeMethod<bool>('stopNFC_HCE') ?? false;
  //     } catch (e, s) {
  //       logE(e, stackTrace: s);
  //     }
  //     return false;
  //   }
  //
  //   static Future<void> writeNFCTag(String data, Function({String? status, bool? isScanning}) callback) async {
  //     if (!(Platform.isAndroid || Platform.isIOS)) return;
  //
  //     await turnOnNFCIfOff();
  //     if (await getNFCState() != NfcAvailability.enabled) return;
  //
  //     await NfcManager.instance.startSession(
  //       pollingOptions: {NfcPollingOption.iso14443},
  //       onDiscovered: (NfcTag tag) async {
  //         try {
  //           final ndef = Ndef.from(tag);
  //           if (ndef == null) {
  //             callback(status: 'This tag does not support NDEF');
  //             return;
  //           }
  //           if (!ndef.isWritable) {
  //             callback(status: 'This tag is not writable');
  //             return;
  //           }
  //
  //           Uint8List type, payload;
  //           if (Uri.tryParse(data)?.scheme != null) {
  //             payload = Uint8List.fromList([0, ...utf8.encode(data)]);
  //             type = Uint8List.fromList('U'.codeUnits);
  //           } else {
  //             const languageCode = 'en';
  //             final langBytes = utf8.encode(languageCode);
  //             final textBytes = utf8.encode(data);
  //             final statusByte = langBytes.length & 0x3F; // bit7=0 (UTF-8), lower 6 = lang length
  //             payload = Uint8List.fromList([statusByte, ...langBytes, ...textBytes]);
  //             type = Uint8List.fromList('T'.codeUnits);
  //           }
  //           if (payload.length - 16 > ndef.maxSize) {
  //             callback(
  //               status:
  //                   'Failed to write Tag!\nThis tag can only hold ${ndef.maxSize} bytes while the address you want to store is ${payload.length} bytes.',
  //             );
  //             return;
  //           }
  //
  //           final record = NdefRecord(
  //             typeNameFormat: TypeNameFormat.wellKnown,
  //             type: type,
  //             identifier: Uint8List(0),
  //             payload: payload,
  //           );
  //
  //           await ndef.write(message: NdefMessage(records: [record]));
  //
  //           await hapticFeedback();
  //           callback(status: 'Data written successfully to NFC card!');
  //         } catch (e, s) {
  //           callback(status: 'Error writing to card');
  //           logE(e, stackTrace: s);
  //         } finally {
  //           await NfcManager.instance.stopSession();
  //           callback(isScanning: false);
  //         }
  //       },
  //     );
  //   }
}

String? extractText(Uint8List payload) {
  // Payload structure
  // Offset (bytes)   Length(bytes)  Content
  // 0                1              Status byte
  // 1                <n>            ISO/IANA language code. Examples: “fi”, “en-US”, “frCA”, “jp”. The encoding is US-ASCII.
  // n+1              <m>            The actual text. Encoding is either UTF-8 or UTF-16, depending on the status bit.

  // status byte structure
  // Bit number (0is LSB)  Content
  // 7                     0: The text is encoded in UTF-8, 1: The text is encoded in UTF16
  // 6                     Reserved for future (MUST be set to zero)
  // 5..0                  The length of the IANA language code.

  final status = payload[0];
  final isUtf16 = (status & 0x80) != 0;
  final langCodeLen = status & 0x3F;

  if (payload.length < 1 + langCodeLen) return null;

  // final languageCode = String.fromCharCodes(payload.sublist(1, 1 + langCodeLen));
  final textBytes = payload.sublist(1 + langCodeLen);

  try {
    return isUtf16 ? String.fromCharCodes(textBytes) : utf8.decode(textBytes);
  } catch (_) {
    return String.fromCharCodes(textBytes);
  }
}
