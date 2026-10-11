import 'package:localsend_app/model/persistence/browser_surface_style.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

final browserSurfaceStyleProvider = NotifierProvider<BrowserSurfaceStyleService, BrowserSurfaceStyle>(
  (ref) => BrowserSurfaceStyleService(ref.read(persistenceProvider)),
);

class BrowserSurfaceStyleService extends PureNotifier<BrowserSurfaceStyle> {
  final PersistenceService _persistence;

  BrowserSurfaceStyleService(this._persistence);

  @override
  BrowserSurfaceStyle init() => _persistence.getBrowserSurfaceStyle();

  Future<void> setStyle(BrowserSurfaceStyle style) async {
    await _persistence.setBrowserSurfaceStyle(style);
    state = style;
  }
}
