import 'dart:io';

import 'package:flutter/services.dart';
import 'package:manna/utils/toast_service.dart';

import 'audio_service.dart';

class ClipboardService {
  static Future<String?> read(String format) async {
    if (await Clipboard.hasStrings()) {
      return (await Clipboard.getData(format))?.text;
    }
    return null;
  }

  static Future<void> setClipBoard(String data, [String text = 'copied']) async {
    await Clipboard.setData(ClipboardData(text: data));
    await hapticFeedback();
    if (!Platform.isAndroid) {
      ToastService.show(text);
    }
  }

  static Future<void> clearClipBoard() async {
    await Clipboard.setData(const ClipboardData(text: ''));
  }
}
