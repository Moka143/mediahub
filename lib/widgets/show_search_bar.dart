import 'dart:async';
import 'package:flutter/material.dart';

import '../design/app_tokens.dart';
import '../design/app_theme.dart';

/// Search bar widget for searching TV shows
class ShowSearchBar extends StatefulWidget {
  final String? initialValue;
  final ValueChanged<String>? onSearch;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onClear;
  final Duration debounceDuration;
  final String hintText;
  final bool autofocus;

  const ShowSearchBar({
    super.key,
    this.initialValue,
    this.onSearch,
    this.onChanged,
    this.onClear,
    this.debounceDuration = const Duration(milliseconds: 500),
    this.hintText = 'Search TV shows...',
    this.autofocus = false,
  });

  @override
  State<ShowSearchBar> createState() => _ShowSearchBarState();
}

class _ShowSearchBarState extends State<ShowSearchBar> {
  late TextEditingController _controller;
  Timer? _debounceTimer;
  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onTextChanged(String value) {
    widget.onChanged?.call(value);

    _debounceTimer?.cancel();
    setState(() => _isSearching = value.isNotEmpty);

    if (value.isEmpty) {
      widget.onClear?.call();
      return;
    }

    _debounceTimer = Timer(widget.debounceDuration, () {
      widget.onSearch?.call(value);
      if (mounted) {
        setState(() => _isSearching = false);
      }
    });
  }

  void _onClear() {
    _controller.clear();
    _debounceTimer?.cancel();
    setState(() => _isSearching = false);
    widget.onClear?.call();
  }

  void _onSubmitted(String value) {
    _debounceTimer?.cancel();
    if (value.isNotEmpty) {
      widget.onSearch?.call(value);
    }
    setState(() => _isSearching = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = context.appColors;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: AppSpacing.screenPadding,
        vertical: AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: widget.autofocus,
            onChanged: _onTextChanged,
            onSubmitted: _onSubmitted,
            decoration: InputDecoration(
              hintText: widget.hintText,
              prefixIcon: AnimatedSwitcher(
                duration: AppDuration.fast,
                child: _isSearching
                    ? Padding(
                        key: const ValueKey('loading'),
                        padding: EdgeInsets.all(AppSpacing.md),
                        child: SizedBox(
                          width: AppIconSize.md,
                          height: AppIconSize.md,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      )
                    : Icon(Icons.search, key: const ValueKey('search')),
              ),
              suffixIcon: _buildSuffixIcon(),
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.5,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
                borderSide: BorderSide(
                  color: theme.colorScheme.primary,
                  width: 2,
                ),
              ),
              contentPadding: EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.md,
              ),
            ),
          ),
          // Search hint
          if (_controller.text.isEmpty)
            Padding(
              padding: EdgeInsets.only(left: AppSpacing.xs, top: AppSpacing.xs),
              child: Text(
                'Search by show name • Press Enter to search immediately',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: appColors.mutedText,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget? _buildSuffixIcon() {
    if (_controller.text.isNotEmpty) {
      return IconButton(
        onPressed: _onClear,
        icon: const Icon(Icons.clear_rounded),
        tooltip: 'Clear search',
      );
    }

    return null;
  }
}

/// Search bar with suggestions dropdown
class ShowSearchBarWithSuggestions extends StatefulWidget {
  final ValueChanged<String>? onSearch;
  final List<String> recentSearches;
  final ValueChanged<String>? onRecentSearchTap;
  final VoidCallback? onClearRecentSearches;

  const ShowSearchBarWithSuggestions({
    super.key,
    this.onSearch,
    this.recentSearches = const [],
    this.onRecentSearchTap,
    this.onClearRecentSearches,
  });

  @override
  State<ShowSearchBarWithSuggestions> createState() =>
      _ShowSearchBarWithSuggestionsState();
}

class _ShowSearchBarWithSuggestionsState
    extends State<ShowSearchBarWithSuggestions> {
  final FocusNode _focusNode = FocusNode();
  bool _showSuggestions = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      setState(() {
        _showSuggestions =
            _focusNode.hasFocus && widget.recentSearches.isNotEmpty;
      });
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ShowSearchBar(
          onSearch: widget.onSearch,
          onClear: () {
            widget.onSearch?.call('');
          },
        ),
        if (_showSuggestions)
          Container(
            margin: EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: AppSpacing.sm,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                    vertical: AppSpacing.sm,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Recent Searches',
                        style: TextStyle(
                          color: context.appColors.mutedText,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (widget.onClearRecentSearches != null)
                        TextButton(
                          onPressed: widget.onClearRecentSearches,
                          child: const Text('Clear'),
                        ),
                    ],
                  ),
                ),
                ...widget.recentSearches
                    .take(5)
                    .map(
                      (search) => ListTile(
                        leading: const Icon(Icons.history),
                        title: Text(search),
                        dense: true,
                        onTap: () {
                          _focusNode.unfocus();
                          widget.onRecentSearchTap?.call(search);
                        },
                      ),
                    ),
              ],
            ),
          ),
      ],
    );
  }
}
