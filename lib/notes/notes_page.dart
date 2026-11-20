import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'note.dart';
import 'note_editor.dart';

/// The Notes tab: search, filters (All, Pinned, tags, Archive, Trash), sort,
/// note cards, and the editor (side panel when [wide], full screen if not).
class NotesPage extends StatefulWidget {
  const NotesPage({
    super.key,
    required this.api,
    required this.wide,
    required this.onAuthExpired,
  });

  final ApiClient api;
  final bool wide;
  final VoidCallback onAuthExpired;

  @override
  State<NotesPage> createState() => NotesPageState();
}

class NotesPageState extends State<NotesPage> {
  final _search = TextEditingController();
  Timer? _searchDebounce;

  String _view = 'all'; // all | pinned | archive | trash
  String? _tag;
  String _sort = 'edited'; // edited | created
  List<Note> _notes = const [];
  final _knownTags = <String>{};
  bool _loading = true;
  String? _error;
  int _loadSeq = 0;

  Note? _open; // note in the editor

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  /// Reloads the list (e.g. after a note was saved from Write).
  void refresh() => _load();

  Future<T?> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on AuthExpired {
      widget.onAuthExpired();
    } on ApiException catch (e) {
      _toast(e.message);
    }
    return null;
  }

  Future<void> _load() async {
    final seq = ++_loadSeq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final notes = await widget.api.notes(
        view: _view,
        tag: _tag,
        search: _search.text,
        sort: _sort,
      );
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _notes = notes;
        _loading = false;
        for (final n in notes) {
          _knownTags.addAll(n.tags);
        }
      });
    } on AuthExpired {
      widget.onAuthExpired();
    } on ApiException catch (e) {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  void _setFilter(String view, [String? tag]) {
    if (view == _view && tag == _tag) return;
    setState(() {
      _view = view;
      _tag = tag;
      _open = null;
    });
    _load();
  }

  void _onSearch(String _) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), _load);
  }

  void _toast(String text, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text, style: inter(size: 14)),
          backgroundColor: TC.surface,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 5),
          action: action,
        ),
      );
  }

  Future<void> _newNote() async {
    final n = await _guard(
      () => widget.api.createNote({
        if (_tag != null) 'tags': [_tag],
      }),
    );
    if (n == null || !mounted) return;
    setState(() {
      if (_view == 'trash' || _view == 'archive') _view = 'all';
      _notes = [n, ..._notes];
      _open = n;
    });
  }

  /// The editor saved a change: keep the card in step.
  void _onSaved(Note n) {
    if (!mounted) return;
    setState(() {
      _knownTags.addAll(n.tags);
      final i = _notes.indexWhere((x) => x.id == n.id);
      if (i >= 0) _notes = [..._notes]..[i] = n;
      if (_open?.id == n.id) _open = n;
    });
  }

  Future<void> _closeEditor(Note n) async {
    setState(() => _open = null);
    if (n.isEmpty && !n.trashed) {
      // An untouched new note isn't worth keeping.
      setState(() => _notes = _notes.where((x) => x.id != n.id).toList());
      await _guard(() async {
        await widget.api.trashNote(n.id);
        await widget.api.deleteNoteForever(n.id);
      });
      return;
    }
    _load(); // order may have changed (last edited first)
  }

  Future<void> _trash(Note n) async {
    setState(() {
      _notes = _notes.where((x) => x.id != n.id).toList();
      if (_open?.id == n.id) _open = null;
    });
    if (await _guard(() => widget.api.trashNote(n.id)) == null) return _load();
    _toast(
      'Note moved to trash',
      action: SnackBarAction(
        label: 'Undo',
        textColor: TC.accent,
        onPressed: () async {
          await _guard(() => widget.api.restoreNote(n.id));
          _load();
        },
      ),
    );
  }

  Future<void> _restore(Note n) async {
    setState(() => _notes = _notes.where((x) => x.id != n.id).toList());
    if (await _guard(() => widget.api.restoreNote(n.id)) != null) {
      _toast('Note restored');
    }
  }

  Future<void> _deleteForever(Note n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: TC.surface,
        title: Text('Delete forever?', style: grotesk(size: 20)),
        content: Text(
          '"${n.title.isEmpty ? 'Untitled' : n.title}" will be gone for good.',
          style: inter(size: 14, color: TC.textSoft),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text('Cancel', style: inter(color: TC.textSoft)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(
              'Delete forever',
              style: inter(weight: FontWeight.w600, color: TC.dangerSoft),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _notes = _notes.where((x) => x.id != n.id).toList());
    await _guard(() => widget.api.deleteNoteForever(n.id));
  }

  Future<void> _toggleArchive(Note n) async {
    final updated = await _guard(
      () => widget.api.updateNote(n.id, {'archived': !n.archived}),
    );
    if (updated == null) return;
    setState(() => _open = null);
    _toast(updated.archived ? 'Note archived' : 'Note moved back to notes');
    _load();
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final editor = _open == null
        ? null
        : NoteEditor(
            key: ValueKey(_open!.id),
            note: _open!,
            api: widget.api,
            fullScreen: !widget.wide,
            onSaved: _onSaved,
            onClose: _closeEditor,
            onTrash: _trash,
            onToggleArchive: _toggleArchive,
            onAuthExpired: widget.onAuthExpired,
            onToast: _toast,
          );

    if (widget.wide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: 380, child: _list()),
          const SizedBox(width: 20),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: editor ?? _emptyEditor(),
            ),
          ),
        ],
      );
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      switchInCurve: easeOutSoft,
      transitionBuilder: (child, a) => FadeTransition(
        opacity: a,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0.06, 0),
            end: Offset.zero,
          ).animate(a),
          child: child,
        ),
      ),
      child:
          editor ?? KeyedSubtree(key: const ValueKey('list'), child: _list()),
    );
  }

  Widget _emptyEditor() => Container(
    key: const ValueKey('empty'),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: TC.border),
    ),
    alignment: Alignment.center,
    child: Text(
      'Pick a note, or create a new one.',
      style: inter(size: 15, color: TC.muted),
    ),
  );

  Widget _list() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: _searchBox()),
            const SizedBox(width: 8),
            _sortMenu(),
          ],
        ),
        const SizedBox(height: 10),
        _filters(),
        const SizedBox(height: 12),
        if (_view != 'trash')
          Pressable(
            onTap: _newNote,
            label: 'New note',
            radius: 16,
            child: Container(
              height: 46,
              decoration: BoxDecoration(
                color: TC.accent,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.add_rounded, size: 20, color: TC.bg),
                  const SizedBox(width: 6),
                  Text(
                    'New note',
                    style: inter(
                      size: 15,
                      weight: FontWeight.w600,
                      color: TC.bg,
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          Text(
            'Notes in the trash are deleted for good after 30 days.',
            style: inter(size: 13, color: TC.muted),
          ),
        const SizedBox(height: 12),
        Expanded(child: _results()),
      ],
    );
  }

  Widget _searchBox() => Container(
    height: 44,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    decoration: BoxDecoration(
      color: TC.surface,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: TC.border),
    ),
    child: Row(
      children: [
        const Icon(Icons.search_rounded, size: 18, color: TC.muted),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: _search,
            onChanged: _onSearch,
            style: inter(size: 15),
            cursorColor: TC.accent,
            decoration: InputDecoration.collapsed(
              hintText: 'Search notes',
              hintStyle: inter(size: 15, color: TC.placeholder),
            ),
          ),
        ),
        if (_search.text.isNotEmpty)
          GestureDetector(
            onTap: () {
              _search.clear();
              _load();
            },
            child: const Icon(Icons.close_rounded, size: 18, color: TC.muted),
          ),
      ],
    ),
  );

  Widget _sortMenu() {
    PopupMenuEntry<String> option(String value, String label, IconData icon) {
      final on = _sort == value;
      return PopupMenuItem<String>(
        value: value,
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: on ? TC.accentTint : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: on ? TC.accent : TC.muted),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: inter(
                    size: 14,
                    weight: on ? FontWeight.w600 : FontWeight.w500,
                    color: on ? TC.accent : TC.text,
                  ),
                ),
              ),
              if (on)
                const Icon(Icons.check_rounded, size: 18, color: TC.accent),
            ],
          ),
        ),
      );
    }

    return PopupMenuButton<String>(
      tooltip: 'Sort notes',
      initialValue: _sort,
      color: TC.surface,
      elevation: 12,
      shadowColor: Colors.black,
      position: PopupMenuPosition.under,
      offset: const Offset(0, 8),
      constraints: const BoxConstraints(minWidth: 200, maxWidth: 220),
      menuPadding: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: TC.borderStrong),
      ),
      onSelected: (s) {
        if (s == _sort) return;
        setState(() => _sort = s);
        _load();
      },
      itemBuilder: (_) => [
        PopupMenuItem<String>(
          enabled: false,
          height: 30,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
          child: Text('SORT BY', style: capsLabel()),
        ),
        option('edited', 'Last edited', Icons.edit_calendar_outlined),
        option('created', 'Date created', Icons.event_outlined),
      ],
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: TC.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: TC.border),
        ),
        child: const Icon(
          Icons.swap_vert_rounded,
          size: 20,
          color: TC.textSoft,
        ),
      ),
    );
  }

  Widget _filters() {
    Widget chip(String label, bool on, VoidCallback tap, {IconData? icon}) =>
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Pressable(
            onTap: tap,
            label: label,
            radius: 17,
            lift: false,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: on ? TC.accent : Colors.transparent,
                borderRadius: BorderRadius.circular(17),
                border: Border.all(color: on ? TC.accent : TC.borderStrong),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 15, color: on ? TC.bg : TC.textSoft),
                    const SizedBox(width: 5),
                  ],
                  Text(
                    label,
                    style: inter(
                      size: 13,
                      weight: FontWeight.w600,
                      color: on ? TC.bg : TC.textSoft,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
    final tags = _knownTags.toList()..sort();
    return SizedBox(
      height: 34,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          chip('All', _view == 'all' && _tag == null, () => _setFilter('all')),
          chip(
            'Pinned',
            _view == 'pinned',
            () => _setFilter('pinned'),
            icon: Icons.push_pin_outlined,
          ),
          for (final t in tags)
            chip('#$t', _tag == t, () => _setFilter('all', t)),
          chip(
            'Archive',
            _view == 'archive',
            () => _setFilter('archive'),
            icon: Icons.archive_outlined,
          ),
          chip(
            'Trash',
            _view == 'trash',
            () => _setFilter('trash'),
            icon: Icons.delete_outline_rounded,
          ),
        ],
      ),
    );
  }

  Widget _results() {
    if (_loading && _notes.isEmpty) {
      return const Center(child: PulseDot());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: inter(size: 14, height: 1.5, color: TC.dangerSoft),
            ),
            const SizedBox(height: 12),
            GhostButton(label: 'Retry', onTap: _load),
          ],
        ),
      );
    }
    if (_notes.isEmpty) {
      final text = switch (_view) {
        'trash' => 'The trash is empty.',
        'archive' => 'No archived notes.',
        'pinned' => 'No pinned notes yet.',
        _ =>
          _search.text.isNotEmpty || _tag != null
              ? 'No notes match.'
              : 'No notes yet. Create one, or save a correction or '
                    'translation from Write.',
      };
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: inter(size: 14, height: 1.5, color: TC.muted),
          ),
        ),
      );
    }
    return RefreshIndicator(
      color: TC.accent,
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.only(bottom: 16),
        itemCount: _notes.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (_, i) => _card(_notes[i]),
      ),
    );
  }

  Widget _card(Note n) {
    final strip = n.colorValue;
    final preview = n.checklist
        ? ChecklistItem.parse(
            n.body,
          ).map((i) => '${i.done ? '☑' : '☐'} ${i.text}').join('\n')
        : n.body;
    final selected = _open?.id == n.id;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                n.title.isEmpty ? 'Untitled' : n.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: inter(
                  size: 15,
                  weight: FontWeight.w600,
                  color: n.title.isEmpty ? TC.muted : TC.text,
                ),
              ),
            ),
            if (n.pinned)
              const Icon(Icons.push_pin_rounded, size: 15, color: TC.accent),
          ],
        ),
        if (preview.trim().isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            preview,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: inter(size: 14, height: 1.45, color: TC.textSoft),
          ),
        ],
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final t in n.tags)
              Text('#$t', style: inter(size: 12, color: TC.purpleSoft)),
            Text(
              n.trashed ? 'Deleted ${ago(n.deletedAt!)}' : ago(n.updatedAt),
              style: inter(size: 12, color: TC.muted),
            ),
          ],
        ),
        if (n.trashed) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: GhostButton(label: 'Restore', onTap: () => _restore(n)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Pressable(
                  onTap: () => _deleteForever(n),
                  label: 'Delete forever',
                  radius: 14,
                  child: Container(
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: TC.dangerTint,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: TC.danger),
                    ),
                    child: Text(
                      'Delete forever',
                      style: inter(
                        size: 14,
                        weight: FontWeight.w600,
                        color: TC.dangerSoft,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
    final card = AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: TC.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: selected ? TC.accent : TC.border),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (strip != null) Container(width: 5, color: strip),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: content,
              ),
            ),
          ],
        ),
      ),
    );
    if (n.trashed) return card;
    return Pressable(
      onTap: () => setState(() => _open = n),
      label: 'Open note ${n.title.isEmpty ? 'Untitled' : n.title}',
      radius: 18,
      lift: false,
      pressScale: 0.98,
      child: card,
    );
  }
}
