// App flows against a fake backend: login, history, Save to notes, the
// Notes tab (editor, autosave, checklist, trash + Undo), expired sign-in.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:thinklet/api.dart';
import 'package:thinklet/main.dart';

/// In-memory stand-in for thinklet/vercel/api.
class FakeBackend {
  final notes = <Map<String, dynamic>>[];
  final history = <Map<String, dynamic>>[];
  final requests = <String>[];
  bool rejectClaude = false; // simulate an expired sign-in
  int _id = 0;
  int _tick = 0;

  String _now() => DateTime.utc(
    2026,
    11,
    20,
    10,
  ).add(Duration(seconds: ++_tick)).toIso8601String();

  http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  late final client = MockClient((req) async {
    final path = req.url.path.split('/').last;
    final q = req.url.queryParameters;
    final body = req.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(req.body) as Map<String, dynamic>;
    requests.add('${req.method} $path${q.isEmpty ? '' : ' $q'}');
    if (path == 'login') {
      return body['username'] == 'me' && body['password'] == 'pw'
          ? _json({
              'token': 'tok',
              'expiresAt': DateTime(2030).millisecondsSinceEpoch,
            })
          : _json({
              'error': {'message': 'Wrong username or password.'},
            }, 401);
    }
    if (req.headers['authorization'] != 'Bearer tok') {
      return _json({
        'error': {'message': 'Please sign in again.'},
      }, 401);
    }
    switch ((req.method, path)) {
      case ('POST', 'claude'):
        if (rejectClaude) {
          return _json({
            'error': {'message': 'Please sign in again.'},
          }, 401);
        }
        return _json({
          'stop_reason': 'end_turn',
          'content': [
            {'type': 'text', 'text': 'I have an apple.'},
          ],
        });
      case ('GET', 'history'):
        return _json({'history': history.reversed.toList()});
      case ('POST', 'history'):
        final h = {...body, 'id': 'h${++_id}', 'created_at': _now()};
        history.add(h);
        return _json({'entry': h});
      case ('GET', 'notes'):
        final view = q['view'] ?? 'all';
        final list = notes.where((n) {
          final trashed = n['deleted_at'] != null;
          return switch (view) {
            'trash' => trashed,
            'archive' => !trashed && n['archived'] == true,
            'pinned' => !trashed && n['pinned'] == true,
            _ => !trashed && n['archived'] != true,
          };
        }).toList();
        return _json({'notes': list});
      case ('POST', 'notes'):
        if (q['action'] != null) {
          final n = notes.firstWhere((x) => x['id'] == q['id']);
          n['deleted_at'] = q['action'] == 'trash' ? _now() : null;
          return _json({'note': n});
        }
        final dup = notes.where(
          (n) =>
              body['source_key'] != null &&
              n['source_key'] == body['source_key'],
        );
        if (dup.isNotEmpty) return _json({'note': dup.first, 'existing': true});
        final n = {
          'id': 'n${++_id}',
          'title': '',
          'body': '',
          'color': 'none',
          'tags': <String>[],
          'pinned': false,
          'archived': false,
          'checklist': false,
          'source': null,
          'source_key': null,
          'created_at': _now(),
          'updated_at': _now(),
          'deleted_at': null,
          ...body,
        };
        notes.insert(0, n);
        return _json({'note': n});
      case ('PATCH', 'notes'):
        final n = notes.firstWhere((x) => x['id'] == q['id']);
        n
          ..addAll(body)
          ..['updated_at'] = _now();
        return _json({'note': n});
      case ('DELETE', 'notes'):
        notes.removeWhere((x) => x['id'] == q['id']);
        return _json({'ok': true});
    }
    return _json({
      'error': {'message': 'not found'},
    }, 404);
  });
}

void main() {
  late FakeBackend server;

  Future<void> start(WidgetTester tester, {bool signedIn = false}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844); // phone
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    server = FakeBackend();
    final api = ApiClient(
      base: 'https://thinklet.test/api',
      client: server.client,
      token: signedIn ? 'tok' : null,
    );
    await tester.pumpWidget(ThinkletApp(api: api));
    await settle(tester);
  }

  testWidgets('login: wrong password shows an error, right one opens the app', (
    tester,
  ) async {
    await start(tester);
    expect(find.text('Welcome back'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(0), 'me');
    await tester.enterText(find.byType(TextField).at(1), 'nope');
    await tester.tap(find.text('Sign in'));
    await settle(tester);
    expect(find.text('Wrong username or password.'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(1), 'pw');
    await tester.tap(find.text('Sign in'));
    await settle(tester);
    expect(find.text('Welcome back'), findsNothing);
    expect(find.text('YOUR LINE'), findsOneWidget);
    expect(find.bySemanticsLabel('Notes'), findsOneWidget); // header switch
    // Remembered on this device.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('thinklet.token'), 'tok');
  });

  testWidgets('Save to notes: one tap saves, a second tap adds no duplicate', (
    tester,
  ) async {
    await start(tester, signedIn: true);
    await tester.enterText(find.byType(TextField), 'i has a apple');
    await settle(tester);
    await tester.tap(find.text('Correct').last);
    await settle(tester);
    expect(find.text('Apply to text'), findsOneWidget);
    expect(server.history.single['after'], 'I have an apple.'); // saved history

    // Top-right corner of the card: above the buttons, right of them.
    final save = tester.getCenter(find.bySemanticsLabel('Save to notes'));
    final apply = tester.getCenter(find.text('Apply to text'));
    expect(save.dy, lessThan(apply.dy));
    expect(save.dx, greaterThan(apply.dx));

    await tester.tap(find.bySemanticsLabel('Save to notes'));
    await settle(tester);
    expect(find.bySemanticsLabel('Saved to notes'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Saved to notes'));
    await settle(tester);
    expect(server.notes.length, 1);
    expect(server.notes.single['title'], 'Correction');
    expect(
      server.notes.single['body'],
      'I have an apple.\n\nOriginal: i has a apple',
    );
    expect(server.notes.single['tags'], ['correct']);

    // It shows up in the Notes tab.
    await tester.tap(find.bySemanticsLabel('Notes'));
    await settle(tester);
    expect(find.text('Correction'), findsOneWidget);
    expect(find.text('#correct'), findsWidgets);
  });

  testWidgets('notes: create, autosave, checklist, trash with Undo, restore', (
    tester,
  ) async {
    await start(tester, signedIn: true);
    await tester.tap(find.bySemanticsLabel('Notes'));
    await settle(tester);
    expect(find.textContaining('No notes yet'), findsOneWidget);

    await tester.tap(find.text('New note'));
    await settle(tester);
    await tester.enterText(find.byType(TextField).first, 'Groceries');
    await tester.pump(const Duration(milliseconds: 1500)); // autosave delay
    await settle(tester);
    expect(server.notes.single['title'], 'Groceries');
    expect(find.text('Saved'), findsOneWidget);

    // Checklist: type an item, tick it.
    await tester.tap(find.bySemanticsLabel('Turn into checklist'));
    await settle(tester);
    await tester.enterText(find.widgetWithText(TextField, '').last, 'milk');
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.tap(find.byType(Checkbox).first);
    await settle(tester);
    expect(server.notes.single['checklist'], true);
    expect(server.notes.single['body'], '[x] milk');

    // Back to the list, then trash it and undo.
    await tester.tap(find.bySemanticsLabel('Back to notes'));
    await settle(tester);
    expect(find.text('Groceries'), findsOneWidget);
    expect(find.text('☑ milk'), findsOneWidget);
    await tester.tap(find.text('Groceries'));
    await settle(tester);
    await tester.tap(find.bySemanticsLabel('Move to trash'));
    await settle(tester);
    expect(server.notes.single['deleted_at'], isNotNull);
    await tester.tap(find.text('Undo'));
    await settle(tester);
    expect(server.notes.single['deleted_at'], isNull);
    expect(find.text('Groceries'), findsOneWidget);

    // Trash view: restore from there too.
    await tester.tap(find.text('Groceries'));
    await settle(tester);
    await tester.tap(find.bySemanticsLabel('Move to trash'));
    await settle(tester);
    // The filter chips scroll sideways; Trash is at the far end.
    await tester.scrollUntilVisible(
      find.text('Trash'),
      150,
      scrollable: find.ancestor(
        of: find.text('All'),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.text('Trash'));
    await settle(tester);
    expect(find.text('Restore'), findsOneWidget);
    await tester.tap(find.text('Restore'));
    await settle(tester);
    expect(server.notes.single['deleted_at'], isNull);
  });

  testWidgets('an empty new note is thrown away on close', (tester) async {
    await start(tester, signedIn: true);
    await tester.tap(find.bySemanticsLabel('Notes'));
    await settle(tester);
    await tester.tap(find.text('New note'));
    await settle(tester);
    expect(server.notes.length, 1);
    await tester.tap(find.bySemanticsLabel('Back to notes'));
    await settle(tester);
    expect(server.notes, isEmpty);
  });

  testWidgets('expired sign-in: back to login, typed text kept', (
    tester,
  ) async {
    await start(tester, signedIn: true);
    server.rejectClaude = true;
    await tester.enterText(find.byType(TextField), 'keep this text');
    await settle(tester);
    await tester.tap(find.text('Correct').last);
    await settle(tester);
    expect(find.text('Welcome back'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(0), 'me');
    await tester.enterText(find.byType(TextField).at(1), 'pw');
    await tester.tap(find.text('Sign in'));
    await settle(tester);
    expect(find.text('keep this text'), findsOneWidget);
  });

  testWidgets('reload reopens the tab you left (Notes or Write)', (
    tester,
  ) async {
    await start(tester, signedIn: true);
    expect(find.text('YOUR LINE'), findsOneWidget); // first visit: Write
    await tester.tap(find.bySemanticsLabel('Notes'));
    await settle(tester);

    Future<void> reload() async {
      await tester.pumpWidget(const SizedBox()); // the page goes away…
      await tester.pumpWidget(
        ThinkletApp(
          api: ApiClient(
            base: 'https://thinklet.test/api',
            client: server.client,
            token: 'tok', // still signed in
          ),
        ),
      ); // …and loads again, with the same saved sign-in and settings
      await settle(tester);
    }

    await reload();
    expect(find.text('New note'), findsOneWidget);
    expect(find.text('YOUR LINE'), findsNothing);

    await tester.tap(find.bySemanticsLabel('Write'));
    await settle(tester);
    await reload();
    expect(find.text('YOUR LINE'), findsOneWidget);
  });

  testWidgets('sign out button returns to login', (tester) async {
    await start(tester, signedIn: true);
    await tester.tap(find.bySemanticsLabel('Sign out'));
    await settle(tester);
    expect(find.text('Welcome back'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('thinklet.token'), isNull);
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
