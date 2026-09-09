import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:manna/router.dart';
import 'package:manna/theme.dart';
import 'package:manna/utils/state_extension.dart';

class ToastService {
  static void show(String m) async {
    if (AppRouter.navigatorKey.currentContext == null) return;
    FToast()
        .init(AppRouter.navigatorContext)
        .showToast(
          child: Center(
            child: GestureDetector(
              onTap: () => FToast().removeCustomToast(),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                decoration: BoxDecoration(
                  color: const Color.fromARGB(255, 238, 237, 244),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: const [
                    BoxShadow(color: Colors.black26, spreadRadius: 0.1, blurRadius: 2, offset: Offset(0, 2)),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 12,
                  children: [
                    Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(color: AppColors.primaryColor, borderRadius: BorderRadius.circular(99)),
                      padding: const EdgeInsets.all(4),
                      child: SvgPicture.asset('assets/images/manna_white.svg'),
                    ),
                    Flexible(
                      child: Text(
                        m,
                        style: const TextStyle(fontSize: 15, color: Colors.black),
                        maxLines: 10,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          toastDuration: Duration(milliseconds: m.length > 200 ? 3000 : m.length * 160),
          gravity: ToastGravity.BOTTOM,
          positionedToastBuilder: (context, child, gravity) =>
              Positioned(bottom: context.keyboardPadding.bottom + 72, left: 16, right: 16, child: child),
        );
  }
}
