import 'dart:async';

import 'package:flutter/foundation.dart';

class TransferPillNotifier extends ValueNotifier<bool> {
  Timer? _timer;

  TransferPillNotifier() : super(false);

  void showForEntry() {
    value = true;
    _scheduleHide();
  }

  void toggle() {
    if (value) {
      _timer?.cancel();
      value = false;
    } else {
      value = true;
      _scheduleHide();
    }
  }

  void _scheduleHide() {
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 5), () => value = false);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
