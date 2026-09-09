import 'package:flutter/material.dart';

class AppColors {
  static const primaryColor = Color.fromARGB(255, 86, 86, 230);

  static const accentColor = Color.fromARGB(255, 128, 128, 128);
  static const darkCardColor = Color.fromARGB(255, 42, 42, 42);
}

final brightTheme = ThemeData(
  brightness: Brightness.light,
  textSelectionTheme: const TextSelectionThemeData(selectionColor: Colors.black26),
  scaffoldBackgroundColor: Colors.white,
  useMaterial3: true,
  elevatedButtonTheme: ElevatedButtonThemeData(
    style: ElevatedButton.styleFrom(
      backgroundColor: AppColors.primaryColor,
      foregroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
  ),
  floatingActionButtonTheme: const FloatingActionButtonThemeData(
    backgroundColor: AppColors.primaryColor,
    foregroundColor: Colors.white,
  ),
  switchTheme: SwitchThemeData(
    trackColor: WidgetStateColor.resolveWith((states) {
      if (states.contains(WidgetState.selected)) {
        return AppColors.primaryColor.withAlpha(200);
      }
      return Colors.transparent;
    }),
  ),
  inputDecorationTheme: InputDecorationTheme(
    hintStyle: const TextStyle(color: Colors.grey),
    labelStyle: const TextStyle(color: Colors.grey),
    border: OutlineInputBorder(
      borderSide: const BorderSide(color: Colors.grey),
      borderRadius: BorderRadius.circular(12),
    ),
    enabledBorder: OutlineInputBorder(
      borderSide: const BorderSide(color: Colors.grey),
      borderRadius: BorderRadius.circular(12),
    ),
    focusedBorder: OutlineInputBorder(
      borderSide: const BorderSide(color: AppColors.primaryColor),
      borderRadius: BorderRadius.circular(12),
    ),
    errorBorder: OutlineInputBorder(
      borderSide: const BorderSide(color: Colors.red),
      borderRadius: BorderRadius.circular(12),
    ),
    focusedErrorBorder: OutlineInputBorder(
      borderSide: const BorderSide(color: Colors.red),
      borderRadius: BorderRadius.circular(12),
    ),
    disabledBorder: OutlineInputBorder(
      borderSide: const BorderSide(color: Colors.grey),
      borderRadius: BorderRadius.circular(12),
    ),
  ),
  checkboxTheme: const CheckboxThemeData(shape: StadiumBorder(), visualDensity: VisualDensity.compact),
  colorScheme: ColorScheme.fromSeed(seedColor: AppColors.primaryColor, primary: AppColors.primaryColor),
  chipTheme: ChipThemeData(
    selectedColor: AppColors.primaryColor.withValues(alpha: 0.5),
    iconTheme: const IconThemeData(color: Colors.black),
  ),
  tooltipTheme: const TooltipThemeData(exitDuration: Duration(milliseconds: 200)),
);

final darkTheme = ThemeData(
  brightness: Brightness.dark,
  textSelectionTheme: const TextSelectionThemeData(selectionColor: Colors.white24),
  scaffoldBackgroundColor: Colors.black,
  useMaterial3: true,
  elevatedButtonTheme: ElevatedButtonThemeData(
    style: ElevatedButton.styleFrom(
      backgroundColor: AppColors.primaryColor,
      foregroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
  ),
  floatingActionButtonTheme: const FloatingActionButtonThemeData(
    backgroundColor: AppColors.primaryColor,
    foregroundColor: Colors.white,
  ),
  switchTheme: SwitchThemeData(
    trackColor: WidgetStateColor.resolveWith((states) {
      if (states.contains(WidgetState.selected)) {
        return AppColors.primaryColor.withAlpha(200);
      }
      return Colors.transparent;
    }),
    thumbColor: WidgetStateColor.resolveWith((states) => Colors.white),
  ),
  inputDecorationTheme: InputDecorationTheme(
    hintStyle: const TextStyle(color: Colors.grey),
    labelStyle: const TextStyle(color: Colors.grey),
    border: OutlineInputBorder(
      borderSide: const BorderSide(color: Colors.grey),
      borderRadius: BorderRadius.circular(12),
    ),
    enabledBorder: OutlineInputBorder(
      borderSide: const BorderSide(color: Colors.grey),
      borderRadius: BorderRadius.circular(12),
    ),
    focusedBorder: OutlineInputBorder(
      borderSide: const BorderSide(color: AppColors.primaryColor),
      borderRadius: BorderRadius.circular(12),
    ),
    errorBorder: OutlineInputBorder(
      borderSide: const BorderSide(color: Colors.red),
      borderRadius: BorderRadius.circular(12),
    ),
    focusedErrorBorder: OutlineInputBorder(
      borderSide: const BorderSide(color: Colors.red),
      borderRadius: BorderRadius.circular(12),
    ),
    disabledBorder: OutlineInputBorder(
      borderSide: const BorderSide(color: Colors.grey),
      borderRadius: BorderRadius.circular(12),
    ),
  ),
  checkboxTheme: const CheckboxThemeData(shape: StadiumBorder(), visualDensity: VisualDensity.compact),
  colorScheme: ColorScheme.fromSeed(
    brightness: Brightness.dark,
    seedColor: AppColors.primaryColor,
    primary: AppColors.primaryColor,
  ),
  chipTheme: ChipThemeData(
    selectedColor: AppColors.primaryColor.withValues(alpha: 0.5),
    iconTheme: const IconThemeData(color: Colors.white),
  ),
  tooltipTheme: const TooltipThemeData(exitDuration: Duration(milliseconds: 200)),
  outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(foregroundColor: Colors.white)),
);
