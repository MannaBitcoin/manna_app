import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:manna/app_state.dart';

class AudioService {
  static final player = AudioPlayer();

  static Future<void> playSuccess() async {
    if (AppState.isSoundEffectsOn) {
      await player.setVolume(1);
      if (player.source == null ||
          player.source is! AssetSource ||
          (player.source as AssetSource).path != 'audio/success.wav') {
        await player.setSource(AssetSource('audio/success.wav'));
      }
      await player.resume();
    }
  }
}

Future<void> hapticFeedback() async {
  final isIpad = AppState.prefs.getBool('isIpad') ?? false;

  if (Platform.isAndroid || !isIpad) {
    try {
      await HapticFeedback.mediumImpact();
      return;
    } catch (_) {}
  }

  // Fallback: use a tick sound for iPad
  try {
    await SystemSound.play(SystemSoundType.tick);
  } catch (_) {}
}
