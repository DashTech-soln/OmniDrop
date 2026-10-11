import 'package:wechat_assets_picker/wechat_assets_picker.dart';

FilterOptionGroup newestFirstPhotoFilter() => FilterOptionGroup(
  orders: const [
    OrderOption(type: OrderOptionType.createDate, asc: false),
  ],
);
