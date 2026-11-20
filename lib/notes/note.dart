import 'package:flutter/material.dart';

import '../theme.dart';

/// Label colours a note can have ('none' = no strip). Same names as the
/// backend's COLORS list.
const noteColors = <String, Color?>{
  'none': null,
  'lime': TC.accent,
  'purple': TC.purple,
  'blue': Color(0xFF8AB4FF),
  'orange': Color(0xFFFFB86B),
  'pink': Color(0xFFFF8FC7),
  'teal': Color(0xFF5EEAD4),
};

class Note {
  const Note({
    required this.id,
    this.title = '',
    this.body = '',
    this.color = 'none',
    this.tags = const [],
    this.pinned = false,
    this.archived = false,
    this.checklist = false,
    this.source,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });

  factory Note.fromJson(Map<String, dynamic> j) => Note(
    id: j['id'] as String,
    title: j['title'] as String? ?? '',
    body: j['body'] as String? ?? '',
    color: j['color'] as String? ?? 'none',
    tags: [for (final t in (j['tags'] as List? ?? const [])) t as String],
    pinned: j['pinned'] as bool? ?? false,
    archived: j['archived'] as bool? ?? false,
    checklist: j['checklist'] as bool? ?? false,
    source: j['source'] as String?,
    createdAt: DateTime.parse(j['created_at'] as String).toLocal(),
    updatedAt: DateTime.parse(j['updated_at'] as String).toLocal(),
    deletedAt: j['deleted_at'] == null
        ? null
        : DateTime.parse(j['deleted_at'] as String).toLocal(),
  );

  final String id;
  final String title;
  final String body;
  final String color;
  final List<String> tags;
  final bool pinned;
  final bool archived;
  final bool checklist;
  final String? source; // 'correct' | 'translate' | null
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  bool get trashed => deletedAt != null;
  Color? get colorValue => noteColors[color];

  bool get isEmpty => title.trim().isEmpty && body.trim().isEmpty;

  int get wordCount => RegExp(
    r'\S+',
  ).allMatches(checklist ? ChecklistItem.plain(body) : body).length;

  Note copyWith({
    String? title,
    String? body,
    String? color,
    List<String>? tags,
    bool? pinned,
    bool? archived,
    bool? checklist,
    DateTime? updatedAt,
    DateTime? deletedAt,
    bool clearDeleted = false,
  }) => Note(
    id: id,
    title: title ?? this.title,
    body: body ?? this.body,
    color: color ?? this.color,
    tags: tags ?? this.tags,
    pinned: pinned ?? this.pinned,
    archived: archived ?? this.archived,
    checklist: checklist ?? this.checklist,
    source: source,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deletedAt: clearDeleted ? null : (deletedAt ?? this.deletedAt),
  );
}

/// One tick-box line of a checklist note. Stored in the body as plain text,
/// "[ ] buy milk" / "[x] buy milk", so the note still reads fine as text.
class ChecklistItem {
  ChecklistItem(this.text, {this.done = false});
  String text;
  bool done;

  static final _line = RegExp(r'^\s*\[( |x|X)\]\s?(.*)$');

  static List<ChecklistItem> parse(String body) {
    if (body.isEmpty) return [];
    return [
      for (final line in body.split('\n'))
        if (_line.firstMatch(line) case final m?)
          ChecklistItem(m.group(2)!, done: m.group(1) != ' ')
        else
          ChecklistItem(line),
    ];
  }

  static String format(List<ChecklistItem> items) =>
      items.map((i) => '[${i.done ? 'x' : ' '}] ${i.text}').join('\n');

  /// The text without the "[ ]" markers (for counting and previews).
  static String plain(String body) => parse(body).map((i) => i.text).join('\n');
}

/// "Just now", "5 min ago", "3 h ago", "Yesterday", "12 Nov".
String ago(DateTime t, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final d = n.difference(t);
  if (d.inMinutes < 1) return 'Just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  if (d.inDays == 1) return 'Yesterday';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec', //
  ];
  final date = '${t.day} ${months[t.month - 1]}';
  return t.year == n.year ? date : '$date ${t.year}';
}
