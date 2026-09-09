import 'package:flutter/material.dart';

class AppRouter {
  AppRouter._();

  static final MannaNavigatorObserver navigatorObserver = MannaNavigatorObserver();

  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  static BuildContext get navigatorContext =>
      navigatorKey.currentContext != null ? navigatorKey.currentContext! : throw 'Navigation Context null!';

  static Future<T?> push<T>(Widget page) {
    return Navigator.push<T>(
      navigatorContext,
      MaterialPageRoute(
        builder: (context) => page,
        settings: RouteSettings(name: page.runtimeType.toString()),
      ),
    );
  }

  static void replace(Widget page) {
    Navigator.pushReplacement(
      navigatorContext,
      MaterialPageRoute(
        builder: (context) => page,
        settings: RouteSettings(name: page.runtimeType.toString()),
      ),
    );
  }

  static void pop<T>([T? result]) {
    if (Navigator.of(navigatorContext).canPop()) {
      Navigator.of(navigatorContext).pop(result);
    }
  }

  static void replaceAll<T>(Widget page) => Navigator.of(navigatorContext, rootNavigator: true).pushAndRemoveUntil(
    MaterialPageRoute(
      builder: (context) => page,
      settings: RouteSettings(name: page.runtimeType.toString()),
    ),
    (route) => false,
  );

  static void popIfExists<T>(String pageName) {
    if (navigatorObserver.pageStack.lastOrNull?.settings.name == pageName) {
      if (Navigator.of(navigatorContext).canPop()) {
        Navigator.of(navigatorContext).pop();
      }
    }
  }

  static void pushIfNotExists<T>(Widget page) {
    if (navigatorObserver.pageStack.lastOrNull?.settings.name == page.runtimeType.toString()) {
      return;
    }

    Navigator.push<T>(
      navigatorContext,
      MaterialPageRoute(
        builder: (context) => page,
        settings: RouteSettings(name: page.runtimeType.toString()),
      ),
    );
  }

  static void replaceIfExists<T>(Widget page) {
    if (navigatorObserver.pageStack.lastOrNull?.settings.name == page.runtimeType.toString()) {
      if (Navigator.of(navigatorContext).canPop()) {
        Navigator.of(navigatorContext).pop();
      }
    }

    Navigator.push<T>(
      navigatorContext,
      MaterialPageRoute(
        builder: (context) => page,
        settings: RouteSettings(name: page.runtimeType.toString()),
      ),
    );
  }

  static bool canPop() => Navigator.canPop(navigatorContext);
}

class MannaNavigatorObserver extends NavigatorObserver {
  List<Route<dynamic>> pageStack = [];
  List<Route<dynamic>> popupStack = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    (route is PopupRoute ? popupStack : pageStack).add(route);
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    (route is PopupRoute ? popupStack : pageStack).removeLast();
    super.didPop(route, previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    (route is PopupRoute ? popupStack : pageStack).removeAt(0);
    super.didRemove(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    (newRoute is PopupRoute ? popupStack : pageStack).remove(oldRoute);
    if (newRoute != null) {
      (newRoute is PopupRoute ? popupStack : pageStack).add(newRoute);
    }
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }
}
