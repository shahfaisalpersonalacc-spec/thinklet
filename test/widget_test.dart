import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:thinklet/claude_service.dart';
import 'package:thinklet/home_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thinklet/diff.dart';
import 'package:thinklet/main.dart';
import 'package:thinklet/widgets/common.dart';

void main() {
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

  testWidgets('wide window: the action button fits without scrolling', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // Short and tall desktop windows, in both modes (Translate adds the
    // language chips above the text box).
    for (final size in const [Size(1280, 640), Size(1280, 1000)]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(const ThinkletApp());
      await tester.pump(const Duration(seconds: 1));
      for (final mode in ['Correct', 'Translate']) {
        await tester.tap(find.text(mode).first);
        await tester.pump(const Duration(seconds: 1));
        final button = tester.getRect(find.text(mode).last);
        expect(button.bottom, lessThanOrEqualTo(size.height), reason: '$size');
        // The text box is still a usable height.
        expect(
          tester.getRect(find.byType(TextField)).height,
          greaterThanOrEqualTo(80),
          reason: '$size $mode',
        );
      }
    }
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

    // Translate: English is picked by default; choose Urdu for a plain
    // translation.
    await tester.tap(find.text('Translate').first);
    await settle();
    expect(
      tester.getSemantics(find.text('English')),
      isSemantics(isSelected: true),
    );
    await tester.tap(find.text('Urdu'));
    await settle();
    await tester.tap(find.text('Translate').last);
    await settle();
    expect(find.text('Copy translation'), findsOneWidget);

    // Seen again, the translation is shown whole at once (typed out only
    // the first time).
    await tester.tap(find.text('Your text'));
    await settle();
    await tester.tap(find.text('Translation'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      find.descendant(
        of: find.byType(Typewriter),
        matching: find.text('OUTPUT-TR'),
      ),
      findsOneWidget,
    );
    await settle();

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

  testWidgets('phone: swipe between the text and the result', (tester) async {
    final fake = MockClient(
      (req) async => http.Response(
        jsonEncode({
          'stop_reason': 'end_turn',
          'content': [
            {'type': 'text', 'text': 'I have an apple.'},
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 800);
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

    await tester.enterText(find.byType(TextField), 'i has a apple');
    await settle();
    // No result yet: nothing to swipe to, no indicator.
    expect(find.text('Your text'), findsNothing);

    await tester.tap(find.text('Correct').last);
    await settle();
    expect(find.text('Apply to text'), findsOneWidget);
    expect(find.text('Your text'), findsOneWidget); // the indicator
    expect(find.byIcon(Icons.swipe_rounded), findsNothing); // no hand icon

    // Swipe right on the result: back to the text box.
    await tester.drag(find.text('Apply to text'), const Offset(260, 0));
    await settle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Apply to text'), findsNothing);

    // A short drag snaps back to where it was.
    await tester.drag(find.text('YOUR LINE'), const Offset(-60, 0));
    await settle();
    expect(find.byType(TextField), findsOneWidget);

    // Swipe left starting on the text itself (a real finger: small steps),
    // so text selection doesn't take the gesture: on to the result.
    final g = await tester.startGesture(
      tester.getCenter(find.byType(TextField)),
    );
    for (var i = 0; i < 40; i++) {
      await g.moveBy(const Offset(-5, 0));
      await tester.pump(const Duration(milliseconds: 8));
    }
    await g.up();
    await settle();
    expect(find.text('Apply to text'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);

    // A vertical drag on the card still scrolls instead of swiping.
    await tester.drag(find.text('Apply to text'), const Offset(0, -80));
    await settle();
    expect(find.text('Apply to text'), findsOneWidget);
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

  testWidgets('Correct also offers a better way to say it', (tester) async {
    Map<String, dynamic>? sent;
    final fake = MockClient((req) async {
      sent = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({
          'stop_reason': 'end_turn',
          'content': [
            {
              'type': 'text',
              'text': jsonEncode({
                'corrected': 'This is not the good way to do this.',
                'suggestion': "This isn't the right way to do it.",
              }),
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 900);
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

    await tester.enterText(
      find.byType(TextField),
      'this is not the good way to do this',
    );
    await settle();
    await tester.tap(find.text('Correct').last);
    await settle();

    // Asked for both, as structured output.
    final format = (sent!['output_config'] as Map)['format'] as Map;
    expect(format['type'], 'json_schema');

    expect(find.text('BETTER WAY TO SAY IT'), findsOneWidget);
    expect(find.text("This isn't the right way to do it."), findsOneWidget);

    // "Use this" puts the better version in the text box (and shows it).
    await tester.tap(find.text('Use this'));
    await settle();
    expect(find.byType(TextField), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      "This isn't the right way to do it.",
    );
  });

  test('proxy mode calls our server and sends no API key', () async {
    late http.Request sent;
    final fake = MockClient((req) async {
      sent = req;
      return http.Response(
        jsonEncode({
          'stop_reason': 'end_turn',
          'content': [
            {'type': 'text', 'text': 'Fixed.'},
          ],
        }),
        200,
      );
    });
    final out = await ClaudeService.proxy(
      'https://thinklet.example/api/claude',
      client: fake,
    ).correct('fixd');
    expect(out.corrected, 'Fixed.');
    expect(sent.url.toString(), 'https://thinklet.example/api/claude');
    expect(sent.headers.containsKey('x-api-key'), isFalse);
  });

  test('diff flags only the changed words', () {
    final segs = diffSegments('i has went to office', 'I went to the office.');
    final changed = segs.where((s) => s.changed).map((s) => s.text).toList();
    expect(changed, ['I', 'the', '.']);
    expect(segs.map((s) => s.text).join(), 'I went to the office.');
  });
}
