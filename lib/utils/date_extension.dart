import 'package:intl/intl.dart';

extension DateExtension on DateTime {
  String format({bool withSeconds = false}) =>
      DateFormat('MMM dd, yyyy hh:mm${withSeconds ? ':ss' : ''} a').format(this);
}
