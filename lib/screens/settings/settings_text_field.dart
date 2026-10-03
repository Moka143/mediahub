import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';

/// Saves a settings value. Resolves to an error to show under the field —
/// the value was not saved — or null once it is saved.
typedef SettingsSave = Future<String?> Function(String value);

/// A Settings text field that saves when the user is done with it: on Enter,
/// when focus moves elsewhere, or when the page closes — and only once the
/// value passes [validator].
///
/// Settings used to save on every keystroke. Every save rebuilt the torrent
/// engine, which watches the settings, so typing tore down streams that were
/// still buffering; and typing a port of 7000 pointed the engine at 7, 70 and
/// 700 on the way. An invalid port was dropped without a word.
class SettingsTextField extends StatefulWidget {
  const SettingsTextField({
    super.key,
    required this.value,
    required this.onSave,
    required this.label,
    this.validator,
    this.hint,
    this.helperText,
    this.prefixIcon,
    this.obscure = false,
    this.revealLabel = 'value',
    this.keyboardType,
    this.inputFormatters,
    this.extraSuffix,
  });

  /// The saved value. The field follows it whenever the user is not editing
  /// — after a reset, say — and compares against it to decide whether there
  /// is anything to save.
  final String value;

  final SettingsSave onSave;

  /// Returns the message for an invalid value, or null. Runs on the trimmed
  /// text before anything is saved.
  final String? Function(String value)? validator;

  final String label;
  final String? hint;
  final String? helperText;
  final IconData? prefixIcon;

  /// Hide the text, with a button to reveal it.
  final bool obscure;

  /// What the reveal button shows and hides, for its tooltip ("Show
  /// password").
  final String revealLabel;

  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;

  /// More suffix buttons, before the reveal toggle.
  final Widget? extraSuffix;

  @override
  State<SettingsTextField> createState() => SettingsTextFieldState();
}

@visibleForTesting
class SettingsTextFieldState extends State<SettingsTextField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.value,
  );
  final FocusNode _focus = FocusNode();

  String? _error;

  /// The last value this field saved, so a save the page has not caught up
  /// with yet is not repeated when it closes.
  String? _lastSaved;
  bool _saving = false;
  bool _justSaved = false;
  bool _revealed = false;
  Timer? _savedTimer;

  /// How long the Saved tick stays up after a save: long enough to notice,
  /// short enough not to linger.
  static const Duration _savedTickDuration = Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(covariant SettingsTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Follow the saved value — but never over an edit in progress. A field
    // still showing the old saved value has no edit to lose, focused or not
    // (a reset button in the field's own suffix changes the value while the
    // field keeps focus).
    final untouched =
        !_focus.hasFocus || _controller.text.trim() == oldWidget.value;
    if (widget.value != oldWidget.value &&
        untouched &&
        _controller.text.trim() != widget.value) {
      _controller.text = widget.value;
      _error = null;
    }
  }

  @override
  void dispose() {
    // Leaving the page mid-edit (Esc, Back) is "done" too. The save is a
    // notifier call bound when the page was built, so it does not need this
    // widget to be alive.
    final pending = _controller.text.trim();
    if (!_saving &&
        pending != widget.value &&
        pending != _lastSaved &&
        widget.validator?.call(pending) == null) {
      unawaited(widget.onSave(pending));
    }
    _savedTimer?.cancel();
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!_focus.hasFocus) unawaited(commit());
  }

  /// Validate and, if the value changed, save it. Public for tests.
  Future<void> commit() async {
    if (_saving) return;
    final text = _controller.text.trim();
    if (text == widget.value) {
      if (_error != null) setState(() => _error = null);
      return;
    }
    final invalid = widget.validator?.call(text);
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    String? failure;
    try {
      failure = await widget.onSave(text);
    } catch (_) {
      failure = 'Couldn\'t save this. Try again.';
    }
    if (failure == null) _lastSaved = text;
    if (!mounted) return;
    setState(() {
      _saving = false;
      _error = failure;
      _justSaved = failure == null;
    });
    if (failure == null) {
      _savedTimer?.cancel();
      _savedTimer = Timer(_savedTickDuration, () {
        if (mounted) setState(() => _justSaved = false);
      });
    }
  }

  void _onChanged(String _) {
    // Once an error is up, let it clear as soon as the text is fixed rather
    // than leaving a stale complaint until the next save.
    if (_error != null) {
      final now = widget.validator?.call(_controller.text.trim());
      if (now == null) setState(() => _error = null);
    }
    if (_justSaved) setState(() => _justSaved = false);
  }

  @override
  Widget build(BuildContext context) {
    final status = _saving
        ? const Padding(
            padding: EdgeInsets.all(AppSpacing.md),
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        : _justSaved
        ? const Tooltip(
            message: 'Saved',
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: Icon(
                Icons.check_rounded,
                size: 18,
                color: AppColors.ok,
                semanticLabel: 'Saved',
              ),
            ),
          )
        : null;

    final suffixes = <Widget>[
      ?status,
      ?widget.extraSuffix,
      if (widget.obscure)
        IconButton(
          icon: Icon(
            _revealed ? Icons.visibility_off_rounded : Icons.visibility_rounded,
            color: AppColors.fg2,
          ),
          tooltip: _revealed
              ? 'Hide ${widget.revealLabel}'
              : 'Show ${widget.revealLabel}',
          onPressed: () => setState(() => _revealed = !_revealed),
        ),
    ];

    return TextField(
      controller: _controller,
      focusNode: _focus,
      obscureText: widget.obscure && !_revealed,
      enableSuggestions: !widget.obscure,
      autocorrect: false,
      keyboardType: widget.keyboardType,
      inputFormatters: widget.inputFormatters,
      textInputAction: TextInputAction.done,
      onChanged: _onChanged,
      onSubmitted: (_) => unawaited(commit()),
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        helperText: widget.helperText,
        errorText: _error,
        prefixIcon: widget.prefixIcon == null
            ? null
            : Icon(widget.prefixIcon, color: AppColors.fg2),
        suffixIcon: suffixes.isEmpty
            ? null
            : Row(mainAxisSize: MainAxisSize.min, children: suffixes),
      ),
    );
  }
}
