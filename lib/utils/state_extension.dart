import 'package:flutter/material.dart';

extension StateExtension on State {
  @pragma('vm:prefer-inline')
  void update([void Function()? fn]) {
    if (mounted && context.mounted) {
      // ignore:invalid_use_of_protected_member
      setState(() {
        fn?.call();
      });
    }
  }
}

extension ContextExtension on BuildContext {
  @pragma('vm:prefer-inline')
  Size get screenSize => MediaQuery.sizeOf(this);

  @pragma('vm:prefer-inline')
  double get screenHeight => MediaQuery.sizeOf(this).height;

  @pragma('vm:prefer-inline')
  double get screenWidth => MediaQuery.sizeOf(this).width;

  @pragma('vm:prefer-inline')
  EdgeInsets get keyboardPadding => EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(this).bottom);

  @pragma('vm:prefer-inline')
  Rect get sharePlusRect => Rect.fromLTWH(0, 0, screenWidth, screenHeight);

  Color themedColor({required Color bright, required Color dark}) =>
      Theme.of(this).brightness == Brightness.dark ? dark : bright;

  bool get isDarkMode => Theme.of(this).brightness == Brightness.dark;
}

@pragma('vm:prefer-inline')
void postFrameCallBack(void Function() fn) => WidgetsBinding.instance.addPostFrameCallback((_) {
  try {
    fn();
  } catch (_) {}
});
