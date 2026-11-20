import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:thinklet/claude_service.dart';
import 'package:thinklet/home_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:thinklet/diff.dart';
import 'package:thinklet/main.dart';

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets('home shows brand, mode switch and actions', (tester) async {
    await tester.pumpWidget(const ThinkletApp());
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Thinklet'), findsOneWidget);
    expect(find.text('Translate'), findsOneWidget);
    expect(find.text('Tone'), findsOneWidget);

    // Our own placeholder: shown when empty, hidden once there is text, and
    // never passed as hintText (web would copy it into the hidden HTML input).
    const hint = 'Type or paste your sentence here…';
    expect(find.text(hint), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.decoration?.hintText, isNull);
    await tester.enterText(find.byType(TextField), 'hello');
    // Let the caret-reveal scroll finish (taps are ignored mid-scroll).
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text(hint), findsNothing);

    // Switching to Translate shows the language chips and keeps the text.
    await tester.tap(find.text('Translate'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('hello'), findsOneWidget);
    expect(find.text('Urdu'), findsOneWidget);
    expect(find.text('Hindi'), findsOneWidget);
    expect(find.text('Tone'), findsNothing);
  });

  testWidgets('phone: Correct button stays visible above the keyboard', (
    tester,
  ) async {
    // A phone whose keyboard leaves only ~420 px of page visible.
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 420);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const ThinkletApp());
    await tester.pump(const Duration(seconds: 1));

    // Pinned bar: Correct is on screen right away, before any scrolling.
    expect(
      tester.getRect(find.text('Correct').last).bottom,
      lessThanOrEqualTo(420),
    );

    // Focus the box (the user tapping it), then type.
    await tester.showKeyboard(find.byType(TextField));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      tester.getRect(find.text('Correct').last).bottom,
      lessThanOrEqualTo(420),
    );

    await tester.enterText(find.byType(TextField), 'i has went to office');
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final button = tester.getRect(find.text('Correct').last);
    expect(button.bottom, lessThanOrEqualTo(420));
    expect(button.top, greaterThanOrEqualTo(0));
    final field = tester.getRect(find.byType(TextField));
    expect(field.bottom, greaterThan(0)); // text box still on screen

    // The box's footer ("Clear") doesn't touch the pinned button bar.
    final clear = tester.getRect(find.text('Clear'));
    expect(button.top - clear.bottom, greaterThanOrEqualTo(24));
  });

  testWidgets('text survives leaving and returning to the app/tab', (
    tester,
  ) async {
    await tester.pumpWidget(const ThinkletApp());
    await tester.pump(const Duration(seconds: 1));
    await tester.enterText(find.byType(TextField), 'keep me please');
    await tester.pump();

    // Hide the tab, then show it again.
    for (final s in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('keep me please'), findsOneWidget);
    expect(find.text('14 characters'), findsOneWidget);
    // Back in Correct mode the text is still there too.
    await tester.tap(find.text('Translate'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.text('Correct').first);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('keep me please'), findsOneWidget);
  });

  testWidgets('Correct and Translate results survive switching modes', (
    tester,
  ) async {
    // Fake Claude: answers by looking at which task the system prompt asks.
    final fake = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final translate = (body['system'] as String).contains('translator');
      return http.Response(
        jsonEncode({
          'stop_reason': 'end_turn',
          'content': [
            {'type': 'text', 'text': translate ? 'OUTPUT-TR' : 'OUTPUT-FIX'},
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(
          claude: ClaudeService(apiKey: 'test', client: fake),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    Future<void> settle() async {
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.enterText(find.byType(TextField), 'i has a apple');
    await settle();

    // Correct: on a phone the result takes the text box's place.
    await tester.tap(find.text('Correct').last);
    await settle();
    expect(find.text('Apply to text'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);

    // Floating switch: left button back to the text, right one to the result.
    await tester.tap(find.text('Your text'));
    await settle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Apply to text'), findsNothing);
    expect(
      tester.getCenter(find.text('Correction')).dx,
      greaterThan(400), // right side
    );
    await tester.tap(find.text('Correction'));
    await settle();
    expect(find.text('Apply to text'), findsOneWidget);
    expect(tester.getCenter(find.text('Your text')).dx, lessThan(400));

    // Translate.
    await tester.tap(find.text('Translate').first);
    await settle();
    await tester.tap(find.text('Translate').last);
    await settle();
    expect(find.text('Copy translation'), findsOneWidget);

    // Back to Correct: its result is still there (no new request needed).
    await tester.tap(find.text('Correct').first);
    await settle();
    expect(find.text('Apply to text'), findsOneWidget);
    expect(find.text('Copy translation'), findsNothing);

    // And to Translate again: the translation is still there too.
    await tester.tap(find.text('Translate').first);
    await settle();
    expect(find.text('Copy translation'), findsOneWidget);

    // Editing the text clears results (they no longer match it).
    await tester.tap(find.text('Your text'));
    await settle();
    await tester.enterText(find.byType(TextField), 'something else');
    await settle();
    expect(find.text('Copy translation'), findsNothing);
    expect(find.text('Translation'), findsNothing); // no switch without result
  });

  testWidgets('English target: a word gets a dictionary definition', (
    tester,
  ) async {
    final requests = <Map<String, dynamic>>[];
    final fake = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      requests.add(body);
      final userText = (body['messages'] as List).first['content'] as String;
      final Map<String, dynamic> answer = userText.contains('happy')
          ? {
              'kind': 'definition',
              'text': 'Feeling or showing pleasure.',
              'word': 'happy',
              'phonetic': '/ˈhæpi/',
              'meanings': [
                {
                  'part_of_speech': 'adjective',
                  'definition': 'Feeling or showing pleasure.',
                  'example': 'She was happy with the result.',
                },
              ],
              'synonyms': ['cheerful', 'glad'],
            }
          : userText.contains('cheerful')
          ? {
              'kind': 'definition',
              'text': 'Noticeably happy.',
              'word': 'cheerful',
              'phonetic': '/ˈtʃɪəfəl/',
              'meanings': [
                {
                  'part_of_speech': 'adjective',
                  'definition': 'Noticeably happy and optimistic.',
                  'example': 'A cheerful smile.',
                },
              ],
              'synonyms': <String>[],
            }
          : {
              'kind': 'explanation',
              'text': 'The project is late.',
              'word': '',
              'phonetic': '',
              'meanings': <dynamic>[],
              'synonyms': <String>[],
            };
      return http.Response(
        jsonEncode({
          'stop_reason': 'end_turn',
          'content': [
            {'type': 'text', 'text': jsonEncode(answer)},
          ],
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 1400); // wide web layout
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(
          claude: ClaudeService(apiKey: 'test', client: fake),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    Future<void> settle() async {
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.tap(find.text('Translate').first);
    await settle();
    await tester.tap(find.text('English'));
    await settle();
    await tester.enterText(find.byType(TextField), 'happy');
    await settle();
    await tester.tap(find.text('Translate').last);
    await settle();

    // Asked for structured output.
    final format = (requests.last['output_config'] as Map)['format'] as Map;
    expect(format['type'], 'json_schema');

    expect(find.text('Copy definition'), findsOneWidget);
    expect(find.text('/ˈhæpi/'), findsOneWidget);
    expect(find.text('adjective'), findsOneWidget);
    expect(find.text('“She was happy with the result.”'), findsOneWidget);

    // Tapping a synonym looks that word up.
    await tester.tap(find.text('cheerful'));
    await settle();
    expect(find.text('/ˈtʃɪəfəl/'), findsOneWidget);
    expect(find.text('cheerful'), findsWidgets);

    // A full English sentence gets a plain-English explanation instead.
    await tester.enterText(
      find.byType(TextField),
      'The project is running behind schedule.',
    );
    await settle();
    await tester.tap(find.text('Translate').last);
    await settle();
    expect(find.text('Simple English'), findsOneWidget);
    expect(find.text('Copy definition'), findsNothing);
  });

  test('diff flags only the changed words', () {
    final segs = diffSegments('i has went to office', 'I went to the office.');
    final changed = segs.where((s) => s.changed).map((s) => s.text).toList();
    expect(changed, ['I', 'the', '.']);
    expect(segs.map((s) => s.text).join(), 'I went to the office.');
  });
}
