import 'package:flutter/material.dart';

import '../common/mediahub_popup_menu.dart';

/// Show the app's popup menu either at [position] — where a right click
/// landed, in global coordinates — or just below the widget that [context]
/// belongs to.
///
/// One entry point for the row's "More" button, its right-click menu and the
/// file priority pickers, so a menu looks the same however it was opened.
/// The trigger stays an ordinary, enabled-looking button: wrapping a button
/// inside `PopupMenuButton` meant giving it `onPressed: null`, which drew it
/// disabled.
Future<T?> showTransfersMenu<T>({
  required BuildContext context,
  required List<PopupMenuEntry<T>> items,
  Offset? position,
}) {
  final overlay =
      Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
  final Rect anchor;
  if (position != null) {
    anchor = overlay.globalToLocal(position) & Size.zero;
  } else {
    final box = context.findRenderObject()! as RenderBox;
    anchor = Rect.fromPoints(
      box.localToGlobal(Offset(0, box.size.height), ancestor: overlay),
      box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
    );
  }
  return showMenu<T>(
    context: context,
    position: RelativeRect.fromRect(anchor, Offset.zero & overlay.size),
    items: items,
    color: kMediaHubPopupColor,
    shape: kMediaHubPopupShape,
  );
}
