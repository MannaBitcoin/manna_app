import 'package:manna_core/src/rust/frb_generated.dart';

class LibMannaCore {
  static Future<void> init() async {
    try {
      if (!MannaCore.instance.initialized) {
        await MannaCore.init();
      }
    } catch (e) {
      throw Exception('Failed to initialize manna core: $e');
    }
  }
}
