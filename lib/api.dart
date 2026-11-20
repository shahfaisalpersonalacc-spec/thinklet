import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'notes/note.dart';

/// A backend call failed; [message] is safe to show the user.
class ApiException implements Exception {
  ApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The sign-in is missing, expired or was rejected: show the login screen.
class AuthExpired extends ApiException {
  AuthExpired() : super('Please sign in again.');
}

/// The backend couldn't be reached at all.
class Offline extends ApiException {
  Offline() : super("You're offline. Check your connection and try again.");
}

/// One saved Correct / Translate / Tone result.
class HistoryEntry {
  HistoryEntry(this.id, this.kind, this.before, this.after, this.at);

  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
    j['id'] as String,
    j['kind'] as String,
    j['before'] as String,
    j['after'] as String,
    DateTime.parse(j['created_at'] as String).toLocal(),
  );

  final String id;
  final String kind; // "Corrected", a tone name, or a language name
  final String before;
  final String after;
  final DateTime at;
}

/// Thinklet's backend (thinklet/vercel/api): login, Claude, history, notes.
class ApiClient {
  ApiClient({required this.base, http.Client? client, this.token})
    : _client = client ?? http.Client();

  /// "/api" on the hosted web app, or a full "https://…/api" URL.
  final String base;
  final http.Client _client;
  String? token;

  /// The HTTP client, shared with ClaudeService so all calls go one way.
  http.Client get httpClient => _client;

  Uri _uri(String path, [Map<String, String>? query]) {
    final u = Uri.base.resolve('$base/$path');
    return query == null || query.isEmpty
        ? u
        : u.replace(queryParameters: query);
  }

  /// Sends a request; returns the decoded JSON body or throws an ApiException.
  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    final req = http.Request(method, _uri(path, query));
    req.headers['content-type'] = 'application/json';
    if (token != null) req.headers['authorization'] = 'Bearer $token';
    if (body != null) req.body = jsonEncode(body);
    final http.Response res;
    try {
      res = await http.Response.fromStream(await _client.send(req));
    } catch (_) {
      throw Offline();
    }
    if (res.statusCode == 401 && path != 'login') throw AuthExpired();
    Map<String, dynamic> json;
    try {
      json = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw ApiException(
        'The server sent an unreadable reply (${res.statusCode}).',
      );
    }
    if (res.statusCode != 200) {
      final err = json['error'];
      throw ApiException(
        err is Map ? '${err['message']}' : 'Server error (${res.statusCode}).',
      );
    }
    return json;
  }

  // ------------------------------------------------------------- session

  /// Signs in; on success [token] is set and returned with its expiry.
  Future<({String token, DateTime expiresAt})> login(
    String username,
    String password,
  ) async {
    final j = await _send(
      'POST',
      'login',
      body: {'username': username, 'password': password},
    );
    token = j['token'] as String;
    return (
      token: token!,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(j['expiresAt'] as int),
    );
  }

  // ------------------------------------------------------------- history

  Future<List<HistoryEntry>> history() async {
    final j = await _send('GET', 'history');
    return [
      for (final h in j['history'] as List)
        HistoryEntry.fromJson(h as Map<String, dynamic>),
    ];
  }

  Future<HistoryEntry> addHistory(
    String kind,
    String before,
    String after,
  ) async {
    final j = await _send(
      'POST',
      'history',
      body: {'kind': kind, 'before': before, 'after': after},
    );
    return HistoryEntry.fromJson(j['entry'] as Map<String, dynamic>);
  }

  Future<void> deleteHistory(String id) =>
      _send('DELETE', 'history', query: {'id': id});

  Future<void> clearHistory() =>
      _send('DELETE', 'history', query: {'all': '1'});

  // --------------------------------------------------------------- notes

  Future<List<Note>> notes({
    String view = 'all',
    String? tag,
    String? search,
    String sort = 'edited',
  }) async {
    final j = await _send(
      'GET',
      'notes',
      query: {
        'view': view,
        'sort': sort,
        'tag': ?tag,
        if (search != null && search.trim().isNotEmpty) 'q': search.trim(),
      },
    );
    return [
      for (final n in j['notes'] as List)
        Note.fromJson(n as Map<String, dynamic>),
    ];
  }

  /// Creates a note. If one was already saved with the same `source_key`,
  /// returns that one instead.
  Future<Note> createNote(Map<String, dynamic> fields) async =>
      Note.fromJson((await _send('POST', 'notes', body: fields))['note']);

  Future<Note> updateNote(String id, Map<String, dynamic> fields) async =>
      Note.fromJson(
        (await _send(
          'PATCH',
          'notes',
          query: {'id': id},
          body: fields,
        ))['note'],
      );

  Future<Note> trashNote(String id) async => Note.fromJson(
    (await _send(
      'POST',
      'notes',
      query: {'action': 'trash', 'id': id},
    ))['note'],
  );

  Future<Note> restoreNote(String id) async => Note.fromJson(
    (await _send(
      'POST',
      'notes',
      query: {'action': 'restore', 'id': id},
    ))['note'],
  );

  Future<void> deleteNoteForever(String id) =>
      _send('DELETE', 'notes', query: {'id': id});
}

/// Remembers the sign-in on this device (web: localStorage).
class Session {
  static const _tokenKey = 'thinklet.token';
  static const _expiresKey = 'thinklet.expires';

  /// The saved token, if there is one that hasn't expired.
  static Future<String?> load() async {
    final p = await SharedPreferences.getInstance();
    final token = p.getString(_tokenKey);
    final exp = p.getInt(_expiresKey) ?? 0;
    final valid = exp > DateTime.now().millisecondsSinceEpoch;
    return valid ? token : null;
  }

  static Future<void> save(String token, DateTime expiresAt) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_tokenKey, token);
    await p.setInt(_expiresKey, expiresAt.millisecondsSinceEpoch);
  }

  static Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_tokenKey);
    await p.remove(_expiresKey);
  }
}
