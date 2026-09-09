import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:manna/utils/state_extension.dart';

class TextScramble extends StatefulWidget {
  const TextScramble({
    required this.text,
    required this.builder,
    this.speed = const Duration(milliseconds: 30),
    this.chars = r'!<>-_\/[]{}—=+*^?#________',
    this.correctCharProbability = 0.8,
    this.onComplete,
    super.key,
  });

  final String text;
  final Duration speed;
  final String chars;
  final double correctCharProbability;
  final Widget Function(BuildContext, String) builder;
  final Function()? onComplete;

  @override
  State<TextScramble> createState() => _TextScrambleState();
}

class _TextScrambleState extends State<TextScramble> {
  late String _displayText;
  final _random = math.Random();
  Timer? _timer;
  Timer? _completionTimer;
  int _done = 0;

  @override
  void initState() {
    _startScramble();
    super.initState();
  }

  @override
  void didUpdateWidget(covariant TextScramble oldWidget) {
    if (oldWidget.text != widget.text) {
      _timer?.cancel();
      _completionTimer?.cancel();
      _startScramble();
    }
    super.didUpdateWidget(oldWidget);
  }

  void _startScramble() {
    _displayText = List.filled(widget.text.length, '').join();
    _done = 0;
    _timer = Timer.periodic(widget.speed, (timer) {
      if (_done >= widget.text.length - 1) {
        timer.cancel();
        update(() => _displayText = widget.text);
        _completionTimer = Timer(Duration(milliseconds: (widget.text.length * 60).clamp(2000, 100000)), () {
          if (mounted) widget.onComplete?.call();
        });
        return;
      }

      if (_random.nextDouble() < widget.correctCharProbability) {
        _done++;
      }
      _displayText = List.generate((_done + 5).clamp(0, widget.text.length), (index) {
        if (index <= _done) return widget.text[index];

        return widget.chars[_random.nextInt(widget.chars.length)];
      }).join();
      update();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, _displayText);
  }
}
