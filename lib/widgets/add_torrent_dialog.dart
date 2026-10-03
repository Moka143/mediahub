import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../design/app_typography.dart';
import '../models/torrent_action_result.dart';
import '../providers/settings_provider.dart';
import '../providers/torrent_provider.dart';
import '../utils/platform_utils.dart';
import 'common/editorial_dialog_shell.dart';
import 'common/hub_pressable.dart';
import 'editorial/editorial.dart';
import 'transfers/torrent_link.dart';
import 'transfers/transfer_actions.dart';

/// Add a torrent from a magnet link, a torrent web address, a bare info
/// hash, or a `.torrent` file.
///
/// What is typed is checked here, with the reason in words, before anything
/// reaches the engine; a magnet link already on the clipboard is offered in
/// the field. While the add is in flight the dialog cannot be dismissed — Esc
/// and a click outside used to close it mid-request, and the reply then
/// landed on a disposed dialog.
class AddTorrentDialog extends ConsumerStatefulWidget {
  const AddTorrentDialog({super.key, this.initialTorrentFile});

  /// A `.torrent` file to start with — one dropped onto the window.
  final String? initialTorrentFile;

  @override
  ConsumerState<AddTorrentDialog> createState() => _AddTorrentDialogState();
}

class _AddTorrentDialogState extends ConsumerState<AddTorrentDialog> {
  final _linkController = TextEditingController();
  String? _torrentFilePath;
  String? _savePath;
  bool _startNow = true;
  bool _adding = false;

  /// What is wrong with the typed link, shown under the field.
  String? _linkError;

  /// Why the last add (or a picker) failed, in words.
  String? _error;

  /// The field was filled from the clipboard, and says so.
  bool _fromClipboard = false;

  @override
  void initState() {
    super.initState();
    _savePath = ref.read(settingsProvider).defaultSavePath;
    _torrentFilePath = widget.initialTorrentFile;
    if (_torrentFilePath == null) unawaited(_offerClipboardMagnet());
  }

  @override
  void dispose() {
    _linkController.dispose();
    super.dispose();
  }

  /// Pre-fill a magnet link sitting on the clipboard — the usual reason this
  /// dialog is opened — selected, so typing replaces it.
  Future<void> _offerClipboardMagnet() async {
    ClipboardData? data;
    try {
      data = await Clipboard.getData(Clipboard.kTextPlain);
    } catch (_) {
      return;
    }
    final text = data?.text?.trim();
    if (!mounted || text == null || !looksLikeMagnet(text)) return;
    // Never over something the user already started on.
    if (_linkController.text.isNotEmpty || _torrentFilePath != null) return;
    setState(() {
      _linkController.value = TextEditingValue(
        text: text,
        selection: TextSelection(baseOffset: 0, extentOffset: text.length),
      );
      _fromClipboard = true;
    });
  }

  void _onLinkChanged(String value) {
    setState(() {
      // Typing a link switches back from a picked file.
      if (value.isNotEmpty) _torrentFilePath = null;
      _linkError = null;
      _error = null;
      _fromClipboard = false;
    });
  }

  Future<void> _pickTorrentFile() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['torrent'],
      );
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't open the file picker.");
      return;
    }
    final files = result?.files;
    final path = files == null || files.isEmpty ? null : files.first.path;
    if (!mounted || path == null) return;
    setState(() {
      _torrentFilePath = path;
      _linkController.clear();
      _linkError = null;
      _error = null;
      _fromClipboard = false;
    });
  }

  void _clearTorrentFile() => setState(() {
    _torrentFilePath = null;
    _error = null;
  });

  Future<void> _pickSavePath() async {
    String? path;
    try {
      path = await FilePicker.platform.getDirectoryPath();
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't open the folder picker.");
      return;
    }
    if (!mounted || path == null) return;
    setState(() => _savePath = path);
  }

  Future<void> _add() async {
    if (_adding) return;
    final file = _torrentFilePath;
    final link = file == null ? parseTorrentLink(_linkController.text) : null;
    if (link != null && !link.isValid) {
      setState(() {
        _linkError = link.problem;
        _error = null;
      });
      return;
    }

    // Read before the await: the dialog is gone by the time a success
    // answers, and must not touch `ref` or `context` after that.
    final list = ref.read(torrentListProvider.notifier);
    final navigator = Navigator.of(context);
    final savePath = (_savePath?.isEmpty ?? true) ? null : _savePath;
    setState(() {
      _adding = true;
      _linkError = null;
      _error = null;
    });

    TorrentActionResult result;
    try {
      result = file != null
          ? await list.addTorrentFile(
              File(file),
              savePath: savePath,
              startNow: _startNow,
            )
          : await list.addMagnet(
              link!.link!,
              savePath: savePath,
              startNow: _startNow,
            );
    } catch (e) {
      result = TorrentActionResult.failure('$e');
    }

    if (!mounted) return;
    if (result.success) {
      navigator.pop(true);
      return;
    }
    setState(() {
      _adding = false;
      _error = addTorrentFailureMessage(link?.kind, result);
    });
  }

  @override
  Widget build(BuildContext context) {
    final enabled = !_adding;
    return PopScope(
      canPop: !_adding,
      child: EditorialDialogShell(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _DialogHeader(),
            const SizedBox(height: AppSpacing.xl),
            _LinkField(
              controller: _linkController,
              enabled: enabled,
              errorText: _linkError,
              note: _fromClipboard ? 'Pasted from the clipboard' : null,
              onChanged: _onLinkChanged,
              onSubmitted: () => unawaited(_add()),
            ),
            const SizedBox(height: AppSpacing.lg),
            const _OrDivider(),
            const SizedBox(height: AppSpacing.lg),
            _TorrentFileChoice(
              path: _torrentFilePath,
              enabled: enabled,
              onPick: () => unawaited(_pickTorrentFile()),
              onClear: _clearTorrentFile,
            ),
            const SizedBox(height: AppSpacing.xl),
            _SavePathRow(
              path: _savePath,
              enabled: enabled,
              onBrowse: () => unawaited(_pickSavePath()),
            ),
            const SizedBox(height: AppSpacing.lg),
            _StartNowToggle(
              value: _startNow,
              onChanged: enabled
                  ? (value) => setState(() => _startNow = value)
                  : null,
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.lg),
              _ErrorNote(message: _error!),
            ],
            const SizedBox(height: AppSpacing.xl),
            _DialogActions(
              adding: _adding,
              onCancel: () => Navigator.of(context).pop(false),
              onAdd: () => unawaited(_add()),
            ),
          ],
        ),
      ),
    );
  }
}

/// What a failed add tells the user — never the engine's raw error.
///
/// When the cause is known (engine down, too slow, login refused) that is
/// the message; otherwise the engine simply said no, and the useful advice
/// depends on what was being added.
String addTorrentFailureMessage(
  TorrentLinkKind? kind,
  TorrentActionResult result,
) {
  if (classifyTransferFailure(result.error) != TransferFailure.unknown) {
    return "Couldn't add the torrent. ${transferFailureReason(result.error)}";
  }
  return switch (kind) {
    TorrentLinkKind.magnet =>
      "The torrent engine didn't accept this magnet link. Check that it's "
          'complete, or try another source.',
    TorrentLinkKind.url =>
      "The torrent engine couldn't get a torrent from that address. Check "
          'the link, or download the .torrent file and choose it below.',
    null =>
      "The torrent engine couldn't read this .torrent file. It may be "
          'damaged — try downloading it again.',
  };
}

class _DialogHeader extends StatelessWidget {
  const _DialogHeader();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        Icon(Icons.add_rounded, color: AppColors.accent, size: AppIconSize.lg),
        SizedBox(width: AppSpacing.md),
        SerifTitle('Add torrent', size: AppType.sizeTitle, height: 1.05),
      ],
    );
  }
}

OutlineInputBorder _fieldBorder(Color color) => OutlineInputBorder(
  borderRadius: BorderRadius.circular(AppRadius.sm),
  borderSide: BorderSide(color: color),
);

class _LinkField extends StatelessWidget {
  const _LinkField({
    required this.controller,
    required this.enabled,
    required this.onChanged,
    required this.onSubmitted,
    this.errorText,
    this.note,
  });

  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmitted;
  final String? errorText;

  /// A quiet line under the field, when there is no error to show.
  final String? note;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      autofocus: true,
      // A URL keyboard and a "go" action make Enter submit, while a long
      // magnet link still wraps onto up to three lines.
      keyboardType: TextInputType.url,
      textInputAction: TextInputAction.go,
      minLines: 1,
      maxLines: 3,
      onChanged: onChanged,
      onSubmitted: (_) => onSubmitted(),
      style: AppType.ui(size: AppType.sizeBody, color: AppColors.fg),
      cursorColor: AppColors.accent,
      decoration: InputDecoration(
        labelText: 'Magnet link, torrent URL or info hash',
        labelStyle: AppType.mono(
          size: AppType.sizeSmall,
          color: AppColors.fg2,
          letterSpacing: 0.06,
        ),
        hintText: 'magnet:?xt=urn:btih:…',
        hintStyle: AppType.ui(size: AppType.sizeBody, color: AppColors.fg2),
        helperText: note,
        helperStyle: AppType.caption(color: AppColors.fg2),
        errorText: errorText,
        errorStyle: AppType.caption(color: AppColors.err),
        errorMaxLines: 3,
        prefixIcon: const Icon(
          Icons.link_rounded,
          color: AppColors.fg2,
          size: AppIconSize.sm,
        ),
        filled: true,
        fillColor: AppColors.bgPage,
        border: _fieldBorder(AppColors.line),
        enabledBorder: _fieldBorder(AppColors.line),
        disabledBorder: _fieldBorder(AppColors.line),
        focusedBorder: _fieldBorder(AppColors.accent),
        errorBorder: _fieldBorder(AppColors.err),
        focusedErrorBorder: _fieldBorder(AppColors.err),
      ),
    );
  }
}

class _OrDivider extends StatelessWidget {
  const _OrDivider();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        Expanded(child: Divider(color: AppColors.line, height: 1)),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: MonoLabel('or', color: AppColors.fg2, letterSpacing: 0.12),
        ),
        Expanded(child: Divider(color: AppColors.line, height: 1)),
      ],
    );
  }
}

/// "Choose .torrent file", or the chosen file with a way to change or drop
/// it — the magnet field stays usable either way.
class _TorrentFileChoice extends StatelessWidget {
  const _TorrentFileChoice({
    required this.path,
    required this.enabled,
    required this.onPick,
    required this.onClear,
  });

  final String? path;
  final bool enabled;
  final VoidCallback onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final path = this.path;
    if (path == null) {
      return EditorialButton(
        label: 'Choose .torrent file',
        icon: Icons.folder_open_rounded,
        kind: EditorialButtonKind.ghost,
        expand: true,
        onPressed: enabled ? onPick : null,
      );
    }
    return _Panel(
      child: Row(
        children: [
          const Icon(
            Icons.description_outlined,
            size: AppIconSize.sm,
            color: AppColors.fg1,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              basenameOf(path),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.ui(size: AppType.sizeBody, color: AppColors.fg),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          EditorialButton(
            label: 'Change',
            kind: EditorialButtonKind.subtle,
            onPressed: enabled ? onPick : null,
          ),
          const SizedBox(width: AppSpacing.xs),
          HubPressable(
            tooltip: 'Remove this file',
            onTap: enabled ? onClear : null,
            child: SizedBox(
              width: 28,
              height: 28,
              child: Icon(
                Icons.close_rounded,
                size: AppIconSize.sm,
                color: enabled ? AppColors.fg1 : AppColors.fg3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SavePathRow extends StatelessWidget {
  const _SavePathRow({
    required this.path,
    required this.enabled,
    required this.onBrowse,
  });

  final String? path;
  final bool enabled;
  final VoidCallback onBrowse;

  @override
  Widget build(BuildContext context) {
    final path = this.path;
    return Row(
      children: [
        Expanded(
          child: _Panel(
            child: Row(
              children: [
                const Icon(
                  Icons.folder_rounded,
                  size: AppIconSize.sm,
                  color: AppColors.fg2,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const MonoLabel(
                        'Save to',
                        color: AppColors.fg2,
                        letterSpacing: 0.08,
                      ),
                      const SizedBox(height: AppSpacing.xxs),
                      Text(
                        path == null || path.isEmpty
                            ? 'Default download folder'
                            : path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.ui(
                          size: AppType.sizeBody,
                          color: AppColors.fg,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        EditorialButton(
          label: 'Browse',
          icon: Icons.folder_open_rounded,
          kind: EditorialButtonKind.subtle,
          onPressed: enabled ? onBrowse : null,
        ),
      ],
    );
  }
}

class _StartNowToggle extends StatelessWidget {
  const _StartNowToggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Row(
        children: [
          const Icon(
            Icons.play_arrow_rounded,
            color: AppColors.fg1,
            size: AppIconSize.sm,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              'Start immediately',
              style: AppType.ui(size: AppType.sizeBody, color: AppColors.fg),
            ),
          ),
          Switch(
            value: value,
            activeThumbColor: AppColors.accent,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _ErrorNote extends StatelessWidget {
  const _ErrorNote({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.err.withAlpha(AppOpacity.light),
        border: Border.all(color: AppColors.err.withAlpha(AppOpacity.semi)),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: AppColors.err,
            size: AppIconSize.sm,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Text(
                message,
                style: AppType.caption(color: AppColors.err),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DialogActions extends StatelessWidget {
  const _DialogActions({
    required this.adding,
    required this.onCancel,
    required this.onAdd,
  });

  final bool adding;
  final VoidCallback onCancel;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        // Both inert while adding — and drawn that way: a null onPressed
        // dims an EditorialButton.
        EditorialButton(
          label: 'Cancel',
          kind: EditorialButtonKind.ghost,
          onPressed: adding ? null : onCancel,
        ),
        const SizedBox(width: AppSpacing.sm),
        EditorialButton(
          label: adding ? 'Adding…' : 'Add',
          icon: adding ? Icons.hourglass_top_rounded : Icons.add_rounded,
          kind: EditorialButtonKind.accent,
          onPressed: adding ? null : onAdd,
        ),
      ],
    );
  }
}

/// The hairline-bordered input surface the dialog's rows sit on.
class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: AppColors.bgPage,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.line),
      ),
      child: child,
    );
  }
}

/// Show the add torrent dialog, starting from [torrentFile] when one was
/// dropped onto the window. Resolves to true once a torrent was added.
Future<bool?> showAddTorrentDialog(
  BuildContext context, {
  String? torrentFile,
}) {
  return showDialog<bool>(
    context: context,
    builder: (context) => AddTorrentDialog(initialTorrentFile: torrentFile),
  );
}
