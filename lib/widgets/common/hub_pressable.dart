import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';

/// A clickable region that also works from the keyboard and is announced as
/// a button.
///
/// The app's custom buttons were bare `GestureDetector`s: they could not take
/// focus, Enter and Space did nothing, screen readers saw no button, and the
/// pointer stayed an arrow. This wraps [child] with all four — a place in the
/// focus order, activation by Enter/Space, `Semantics(button: true)` and a
/// click cursor — and draws a visible ring while it has keyboard focus.
///
/// It paints nothing else. Callers that draw their own hover state get it
/// through [onHoverChanged], exactly as they did from a `MouseRegion`.
class HubPressable extends StatefulWidget {
  const HubPressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTap,
    this.onHoverChanged,
    this.onFocusChanged,
    this.semanticLabel,
    this.tooltip,
    this.selected,
    this.focusNode,
    this.autofocus = false,
    this.borderRadius = const BorderRadius.all(Radius.circular(AppRadius.sm)),
    this.showFocusRing = true,
    this.focusRingColor = AppColors.accent,
    this.excludeChildSemantics = false,
  });

  final Widget child;

  /// Activation by click, Enter or Space. Null disables the control: it
  /// leaves the focus order and keeps the default cursor.
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Right click — for context menus.
  final VoidCallback? onSecondaryTap;

  /// Pointer entered (true) or left (false).
  final ValueChanged<bool>? onHoverChanged;

  /// Focus gained (true) or lost (false), by any means.
  final ValueChanged<bool>? onFocusChanged;

  /// Read by screen readers. Only needed when [child] carries no text of its
  /// own, such as an icon.
  final String? semanticLabel;

  /// Shown on hover and long-press; also used as the semantic label when
  /// [semanticLabel] is null.
  final String? tooltip;

  /// For toggles and tabs: whether this is the current one.
  final bool? selected;

  final FocusNode? focusNode;
  final bool autofocus;

  /// Shape of the focus ring. Match the child's own corners.
  final BorderRadius borderRadius;

  final bool showFocusRing;

  /// The ring's colour. The accent by default; pass a light colour for a
  /// child that is itself accent-filled, where an accent ring would vanish.
  final Color focusRingColor;

  /// Replace the child's semantics with [semanticLabel] instead of merging
  /// — for a child whose text would repeat or garble the label. The tap
  /// action, focus and button role are kept either way.
  final bool excludeChildSemantics;

  @override
  State<HubPressable> createState() => _HubPressableState();
}

class _HubPressableState extends State<HubPressable> {
  bool _focusVisible = false;

  bool get _enabled =>
      widget.onTap != null ||
      widget.onLongPress != null ||
      widget.onSecondaryTap != null;

  void _activate() => widget.onTap?.call();

  @override
  Widget build(BuildContext context) {
    Widget result = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onSecondaryTap: widget.onSecondaryTap,
      // Only the child's own semantics are dropped. Excluding at the outer
      // Semantics instead took the tap action and focusability with them,
      // leaving a "button" a screen reader could neither press nor reach.
      child: widget.excludeChildSemantics
          ? ExcludeSemantics(child: widget.child)
          : widget.child,
    );

    if (widget.showFocusRing) {
      result = DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: widget.borderRadius,
          border: Border.all(
            color: _focusVisible ? widget.focusRingColor : Colors.transparent,
            width: 2,
          ),
        ),
        child: result,
      );
    }

    result = FocusableActionDetector(
      enabled: _enabled,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      mouseCursor: _enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onShowFocusHighlight: (visible) {
        if (visible != _focusVisible) setState(() => _focusVisible = visible);
      },
      onShowHoverHighlight: widget.onHoverChanged,
      onFocusChange: widget.onFocusChanged,
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _activate();
            return null;
          },
        ),
        ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
          onInvoke: (_) {
            _activate();
            return null;
          },
        ),
      },
      child: result,
    );

    result = Semantics(
      button: true,
      enabled: _enabled,
      selected: widget.selected,
      label: widget.semanticLabel ?? widget.tooltip,
      child: result,
    );

    final tooltip = widget.tooltip;
    if (tooltip != null && tooltip.isNotEmpty) {
      // The tooltip is already the control's semantic label (above);
      // letting the Tooltip announce it too made screen readers say it twice.
      result = Tooltip(
        message: tooltip,
        excludeFromSemantics: true,
        child: result,
      );
    }
    return result;
  }
}
