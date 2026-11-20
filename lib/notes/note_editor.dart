import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'note.dart';

enum _Save { saved, saving, failed }

/// Edits one note. Every change is saved on its own about a second after
/// typing stops; a failed save keeps the text and retries.
class NoteEditor extends StatefulWidget {
  const NoteEditor({
    super.key,
    required this.note,
    required this.api,
    required this.fullScreen,
    required this.onSaved,
    required this.onClose,
    required this.onTrash,
    required this.onToggleArchive,
    required this.onAuthExpired,
    required this.onToast,
  });

  final Note note;
  final ApiClient api;
  final bool fullScreen;
  final ValueChanged<Note> onSaved;
  final ValueChanged<Note> onClose;
  final ValueChanged<Note> onTrash;
  final ValueChanged<Note> onToggleArchive;
  final VoidCallback onAuthExpired;
  final void Function(String text) onToast;

  @override
  State<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<NoteEditor> {
  static const _debounce = Duration(seconds: 1);
  static const _retry = Duration(seconds: 3);

  late Note _note = widget.note;
  late final _title = TextEditingController(text: _note.title);
  late final _body = TextEditingController(text: _note.body);
  final _tagInput = TextEditingController();

  // Checklist mode: one controller + focus per line.
  final _items = <ChecklistItem>[];
  final _itemText = <TextEditingController>[];
  final _itemFocus = <FocusNode>[];

  final _pending = <String, dynamic>{};
  Timer? _timer;
  _Save _status = _Save.saved;
  Future<void>? _inFlight;

  @override
  void initState() {
    super.initState();
    if (_note.checklist) _loadItems(_note.body);
  }

  @override
  void dispose() {
    _timer?.cancel();
    // Leaving (e.g. another note picked): save what's left, unawaited.
    if (_pending.isNotEmpty) _flush();
    _title.dispose();
    _body.dispose();
    _tagInput.dispose();
    _disposeItems();
    super.dispose();
  }

  // ------------------------------------------------------------- saving

  void _change(Map<String, dynamic> fields, {bool now = false}) {
    _pending.addAll(fields);
    setState(() {
      _note = _note.copyWith(
        title: fields['title'] as String?,
        body: fields['body'] as String?,
        color: fields['color'] as String?,
        tags: fields['tags'] as List<String>?,
        pinned: fields['pinned'] as bool?,
        checklist: fields['checklist'] as bool?,
      );
      _status = _Save.saving;
    });
    _timer?.cancel();
    _timer = Timer(now ? Duration.zero : _debounce, _flush);
  }

  Future<void> _flush() {
    _timer?.cancel();
    if (_pending.isEmpty) return _inFlight ?? Future.value();
    // One save at a time; changes made meanwhile go in the next one.
    return _inFlight ??= _send().whenComplete(() => _inFlight = null);
  }

  Future<void> _send() async {
    final fields = Map<String, dynamic>.of(_pending);
    _pending.clear();
    try {
      final saved = await widget.api.updateNote(_note.id, fields);
      widget.onSaved(saved);
      if (!mounted) return;
      setState(() => _status = _pending.isEmpty ? _Save.saved : _Save.saving);
      if (_pending.isNotEmpty) _timer = Timer(Duration.zero, _flush);
    } on AuthExpired {
      _requeue(fields);
      widget.onAuthExpired();
    } on ApiException {
      _requeue(fields);
      if (!mounted) return;
      setState(() => _status = _Save.failed);
      _timer = Timer(_retry, _flush);
    }
  }

  /// Puts unsent fields back; edits made since (already in _pending) win.
  void _requeue(Map<String, dynamic> unsent) {
    final newer = Map<String, dynamic>.of(_pending);
    _pending
      ..clear()
      ..addAll(unsent)
      ..addAll(newer);
  }

  Future<void> _close() async {
    await _flush();
    widget.onClose(_note);
  }

  // ---------------------------------------------------------- checklist

  void _loadItems(String body) {
    _disposeItems();
    _items.addAll(ChecklistItem.parse(body));
    if (_items.isEmpty) _items.add(ChecklistItem(''));
    for (final i in _items) {
      _itemText.add(TextEditingController(text: i.text));
      _itemFocus.add(FocusNode());
    }
  }

  void _disposeItems() {
    for (final c in _itemText) {
      c.dispose();
    }
    for (final f in _itemFocus) {
      f.dispose();
    }
    _items.clear();
    _itemText.clear();
    _itemFocus.clear();
  }

  void _itemsChanged() => _change({'body': ChecklistItem.format(_items)});

  void _toggleChecklist() {
    if (_note.checklist) {
      final text = _items.map((i) => i.text).join('\n');
      _body.text = text;
      _disposeItems();
      _change({'checklist': false, 'body': text}, now: true);
    } else {
      _loadItems(_body.text);
      _change({
        'checklist': true,
        'body': ChecklistItem.format(_items),
      }, now: true);
    }
  }

  void _addItem(int after) {
    final at = after + 1;
    setState(() {
      _items.insert(at, ChecklistItem(''));
      _itemText.insert(at, TextEditingController());
      _itemFocus.insert(at, FocusNode());
    });
    _itemsChanged();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && at < _itemFocus.length) _itemFocus[at].requestFocus();
    });
  }

  void _removeItem(int i) {
    setState(() {
      _items.removeAt(i);
      _itemText.removeAt(i).dispose();
      _itemFocus.removeAt(i).dispose();
      if (_items.isEmpty) {
        _items.add(ChecklistItem(''));
        _itemText.add(TextEditingController());
        _itemFocus.add(FocusNode());
      }
    });
    _itemsChanged();
  }

  // -------------------------------------------------------------- tags

  void _addTag(String raw) {
    final t = raw.trim().toLowerCase().replaceAll(RegExp(r'^#+'), '');
    _tagInput.clear();
    if (t.isEmpty || _note.tags.contains(t)) return;
    if (t.length > 30 || _note.tags.length >= 20) {
      widget.onToast('Tags are up to 30 letters, 20 per note.');
      return;
    }
    _change({
      'tags': [..._note.tags, t],
    }, now: true);
  }

  void _copy() {
    final body = _note.checklist ? ChecklistItem.plain(_note.body) : _note.body;
    final text = [
      _note.title,
      body,
    ].where((s) => s.trim().isNotEmpty).join('\n\n');
    Clipboard.setData(ClipboardData(text: text));
    widget.onToast('Note copied');
  }

  // -------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final strip = _note.colorValue;
    return Container(
      decoration: BoxDecoration(
        color: TC.surface,
        borderRadius: BorderRadius.circular(widget.fullScreen ? 20 : 22),
        border: Border.all(color: strip?.withValues(alpha: 0.6) ?? TC.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _toolbar(),
          const Divider(height: 1, color: TC.border),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
              children: [
                TextField(
                  controller: _title,
                  onChanged: (v) => _change({'title': v}),
                  maxLength: 200,
                  style: grotesk(size: 22, spacing: -0.3),
                  cursorColor: TC.accent,
                  decoration: InputDecoration.collapsed(
                    hintText: 'Title',
                    hintStyle: grotesk(size: 22, color: TC.placeholder),
                  ).copyWith(counterText: ''),
                ),
                const SizedBox(height: 12),
                _tagsRow(),
                const SizedBox(height: 12),
                _colors(),
                const SizedBox(height: 16),
                if (_note.checklist) _checklist() else _plainBody(),
              ],
            ),
          ),
          const Divider(height: 1, color: TC.border),
          _footer(),
        ],
      ),
    );
  }

  Widget _icon(
    IconData icon,
    String label,
    VoidCallback onTap, {
    Color color = TC.textSoft,
  }) => Tooltip(
    message: label,
    child: Pressable(
      onTap: onTap,
      label: label,
      radius: 20,
      lift: false,
      child: SizedBox(
        width: 40,
        height: 44,
        child: Icon(icon, size: 20, color: color),
      ),
    ),
  );

  Widget _toolbar() {
    final status = switch (_status) {
      _Save.saved => 'Saved',
      _Save.saving => 'Saving…',
      _Save.failed => "Couldn't save, retrying…",
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Row(
        children: [
          _icon(
            widget.fullScreen ? Icons.arrow_back_rounded : Icons.close_rounded,
            widget.fullScreen ? 'Back to notes' : 'Close note',
            _close,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Text(
                status,
                overflow: TextOverflow.ellipsis,
                style: inter(
                  size: 12,
                  color: _status == _Save.failed ? TC.dangerSoft : TC.muted,
                ),
              ),
            ),
          ),
          _icon(
            _note.pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
            _note.pinned ? 'Unpin' : 'Pin to top',
            () => _change({'pinned': !_note.pinned}, now: true),
            color: _note.pinned ? TC.accent : TC.textSoft,
          ),
          _icon(
            _note.checklist ? Icons.notes_rounded : Icons.checklist_rounded,
            _note.checklist ? 'Turn into plain text' : 'Turn into checklist',
            _toggleChecklist,
          ),
          _icon(Icons.copy_rounded, 'Copy note', _copy),
          _icon(
            _note.archived ? Icons.unarchive_outlined : Icons.archive_outlined,
            _note.archived ? 'Unarchive' : 'Archive',
            () async {
              await _flush();
              widget.onToggleArchive(_note);
            },
          ),
          _icon(Icons.delete_outline_rounded, 'Move to trash', () async {
            await _flush();
            widget.onTrash(_note);
          }, color: TC.dangerSoft),
        ],
      ),
    );
  }

  Widget _tagsRow() => Wrap(
    spacing: 6,
    runSpacing: 6,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      for (final t in _note.tags)
        Container(
          height: 30,
          padding: const EdgeInsets.only(left: 10, right: 4),
          decoration: BoxDecoration(
            color: TC.purpleTint,
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: TC.purpleBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('#$t', style: inter(size: 13, color: TC.purpleSoft)),
              Semantics(
                button: true,
                label: 'Remove tag $t',
                child: GestureDetector(
                  onTap: () => _change({
                    'tags': _note.tags.where((x) => x != t).toList(),
                  }, now: true),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(
                      Icons.close_rounded,
                      size: 14,
                      color: TC.purpleSoft,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      SizedBox(
        width: 120,
        height: 30,
        child: TextField(
          controller: _tagInput,
          onSubmitted: _addTag,
          style: inter(size: 13),
          cursorColor: TC.accent,
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 7,
            ),
            hintText: '+ Add tag',
            hintStyle: inter(size: 13, color: TC.placeholder),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(15),
              borderSide: const BorderSide(color: TC.borderStrong),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(15),
              borderSide: const BorderSide(color: TC.borderStrong),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(15),
              borderSide: const BorderSide(color: TC.accent),
            ),
          ),
        ),
      ),
    ],
  );

  Widget _colors() => Row(
    children: [
      for (final e in noteColors.entries)
        Semantics(
          button: true,
          selected: _note.color == e.key,
          label: 'Colour ${e.key}',
          child: GestureDetector(
            onTap: () => _change({'color': e.key}, now: true),
            child: Container(
              width: 26,
              height: 26,
              margin: const EdgeInsets.only(right: 10),
              decoration: BoxDecoration(
                color: e.value ?? Colors.transparent,
                shape: BoxShape.circle,
                border: Border.all(
                  color: _note.color == e.key ? TC.text : TC.borderStrong,
                  width: _note.color == e.key ? 2 : 1,
                ),
              ),
              child: e.value == null
                  ? const Icon(Icons.block_rounded, size: 14, color: TC.muted)
                  : null,
            ),
          ),
        ),
    ],
  );

  Widget _plainBody() => TextField(
    controller: _body,
    onChanged: (v) => _change({'body': v}),
    maxLines: null,
    minLines: 12,
    style: inter(size: 16, height: 1.6),
    cursorColor: TC.accent,
    decoration: InputDecoration.collapsed(
      hintText: 'Write your note…',
      hintStyle: inter(size: 16, color: TC.placeholder),
    ),
  );

  Widget _checklist() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < _items.length; i++)
        Row(
          children: [
            Checkbox(
              value: _items[i].done,
              activeColor: TC.accent,
              checkColor: TC.bg,
              side: const BorderSide(color: TC.borderStrong, width: 1.5),
              onChanged: (v) {
                setState(() => _items[i].done = v ?? false);
                _change({'body': ChecklistItem.format(_items)}, now: true);
              },
            ),
            Expanded(
              child: TextField(
                controller: _itemText[i],
                focusNode: _itemFocus[i],
                onChanged: (v) {
                  _items[i].text = v;
                  _itemsChanged();
                },
                onSubmitted: (_) => _addItem(i),
                textInputAction: TextInputAction.next,
                style:
                    inter(
                      size: 16,
                      color: _items[i].done ? TC.muted : TC.text,
                    ).copyWith(
                      decoration: _items[i].done
                          ? TextDecoration.lineThrough
                          : null,
                    ),
                cursorColor: TC.accent,
                decoration: InputDecoration.collapsed(
                  hintText: 'List item',
                  hintStyle: inter(size: 16, color: TC.placeholder),
                ),
              ),
            ),
            _icon(
              Icons.close_rounded,
              'Remove item',
              () => _removeItem(i),
              color: TC.muted,
            ),
          ],
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => _addItem(_items.length - 1),
          icon: const Icon(Icons.add_rounded, size: 18, color: TC.accent),
          label: Text('Add item', style: inter(size: 14, color: TC.accent)),
        ),
      ),
    ],
  );

  Widget _footer() {
    final done = _note.checklist ? _items.where((i) => i.done).length : 0;
    final words = _note.wordCount;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      child: Row(
        children: [
          Flexible(
            child: Text(
              '$words ${words == 1 ? 'word' : 'words'}'
              '${_note.checklist ? ' · $done/${_items.length} done' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: inter(size: 12, color: TC.muted),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              'Edited ${ago(_note.updatedAt)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: inter(size: 12, color: TC.muted),
            ),
          ),
        ],
      ),
    );
  }
}
