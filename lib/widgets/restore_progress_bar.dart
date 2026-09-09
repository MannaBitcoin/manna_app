import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:manna/globals.dart';
import 'package:manna/router.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/state_extension.dart';

class RestoreProgressBar extends StatefulWidget {
  const RestoreProgressBar({super.key});

  @override
  State<RestoreProgressBar> createState() => _RestoreProgressBarState();
}

class _RestoreProgressBarState extends State<RestoreProgressBar> {
  Timer? timer;
  bool isSyncComplete = false;
  final random = math.Random();
  final restoreTexts = [
    '"Bitcoin fixes this" in progress',
    'Freedom going up',
    'Terminating fiat.exe',
    'Preparing to have fun playing with your bitcoins',
  ]..shuffle();
  int restoreTextIndex = 0;

  @override
  void initState() {
    timer = Timer.periodic(const Duration(milliseconds: 300), (ticker) {
      if (ticker.tick % 10 == 0) {
        update(() => restoreTextIndex = (restoreTextIndex + 1) % restoreTexts.length);
      }
      if (globalState.value.restoreSyncProgress < 0.6) {
        double increment = 0.005 + random.nextDouble() * 0.015;
        if (random.nextInt(10) == 0) {
          increment *= 0.5;
        }
        globalState.update(restoreSyncProgress: (globalState.value.restoreSyncProgress + increment).clamp(0.0, 0.95));
      } else if (globalState.value.restoreSyncProgress < 0.95) {
        final increment = random.nextDouble() * 0.005;
        globalState.update(restoreSyncProgress: (globalState.value.restoreSyncProgress + increment).clamp(0.0, 0.95));
      }
    });
    super.initState();
  }

  @override
  void dispose() {
    postFrameCallBack(() => globalState.update(restoreSyncProgress: 0));
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: globalState,
      builder: (context, value, child) {
        if (value.restoreSyncProgress > 0) {
          return Container(
            decoration: BoxDecoration(
              color: AppRouter.navigatorContext.themedColor(bright: Colors.white, dark: Colors.black),
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: .end,
              children: [
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: value.restoreSyncProgress,
                  minHeight: 8,
                  backgroundColor: Colors.white54,
                  valueColor: const AlwaysStoppedAnimation<Color>(AppColors.primaryColor),
                  borderRadius: BorderRadiusGeometry.circular(8),
                ),
                const SizedBox(height: 4),
                Text(
                  '${(value.restoreSyncProgress * 100).toStringAsFixed(0)}%',
                  style: TextStyle(
                    fontSize: 16,
                    color: context.themedColor(bright: Colors.black, dark: Colors.white),
                  ),
                ),
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    restoreTexts[restoreTextIndex],
                    style: TextStyle(
                      fontSize: 16,
                      color: context.themedColor(bright: Colors.black, dark: Colors.white),
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          );
        }
        return const SizedBox.shrink();
      },
    );
  }
}
