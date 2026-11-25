// Voice input: mic -> words appear live -> Correct/Translate runs by itself.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text_platform_interface/speech_to_text_platform_interface.dart';
import 'package:thinklet/claude_service.dart';
import 'package:thinklet/home_page.dart';

/// Stands in for the browser / Windows speech engine.
class FakeSpeech extends SpeechToTextPlatform {
  String? locale;
  bool available = true;
  int busyStarts = 0; // next N starts fail like a browser still closing
  int starts = 0;

  @override
  Future<bool> hasPermission() async => available;

  @override
  Future<bool> initialize({
    dynamic debugLogging = false,
    List<SpeechConfigOption>? options,
  }) async => available;

  @override
  Future<bool> listen({
    String? localeId,
    dynamic partialResults = true,
    dynamic onDevice = false,
    int listenMode = 0,
    dynamic sampleRate = 0,
    SpeechListenOptions? options,
  }) async {
    if (busyStarts > 0) {
      busyStarts--;
      throw StateError('InvalidStateError: recognition has already started');
    }
    starts++;
    locale = options?.localeId ?? localeId;
    onStatus?.call('listening');
    return true;
  }

  @override
  Future<void> stop() async => onStatus?.call('done');

  @override
  Future<void> cancel() async {}

  @override
  Future<List<dynamic>> locales() async => ['en-US:English'];

  /// The user says [words]; [done] marks the end of the sentence.
  void say(String words, {bool done = false}) => onTextRecognition?.call(
    jsonEncode(
      SpeechRecognitionResult(
        [SpeechRecognitionWords(words, null, 0.9)],
        done ? ResultType.finalResult.value : ResultType.partial.value,
      ).toJson(),
    ),
  );
}

void main() {
  // One engine for the whole run: the plugin connects to it once (like a
  // real device), so every test must talk through the same one.
  final speech = FakeSpeech();
  SpeechToTextPlatform.instance = speech;
  late List<String> asked; // texts sent to Claude

  Future<void> start(
    WidgetTester tester, {
    Size size = const Size(390, 900),
  }) async {
    speech
      ..available = true
      ..busyStarts = 0
      ..starts = 0
      ..locale = null;
    asked = [];
    final fake = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      asked.add((body['messages'] as List).first['content'] as String);
      final translate = (body['system'] as String).contains('translator');
      return http.Response(
        jsonEncode({
          'stop_reason': 'end_turn',
          'content': [
            {
              'type': 'text',
              'text': translate
                  ? 'میں گھر جا رہا ہوں'
                  : jsonEncode({
                      'corrected': 'I am going home.',
                      'suggestion': "I'm heading home.",
                    }),
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(
          claude: ClaudeService(apiKey: 'test', client: fake),
        ),
      ),
    );
    await settle(tester);
  }

  // Must run first: the plugin remembers a successful start for the rest of
  // the test run, so "no engine" can only be seen before any start works.
  testWidgets('no speech engine: a clear message instead of a crash', (
    tester,
  ) async {
    await start(tester);
    speech.available = false;
    await tester.tap(find.bySemanticsLabel('Speak'));
    await settle(tester);
    expect(find.textContaining('Voice input'), findsWidgets);
    expect(find.bySemanticsLabel('Speak'), findsOneWidget); // not stuck
  });

  testWidgets('speak -> words appear live -> correction runs by itself', (
    tester,
  ) async {
    await start(tester);
    await tester.tap(find.bySemanticsLabel('Speak'));
    await settle(tester);
    expect(find.text('Listening… speak in English'), findsOneWidget);
    expect(speech.locale, 'en-US');

    speech.say('i going');
    await settle(tester);
    expect(find.text('i going'), findsOneWidget); // live, while talking
    expect(asked, isEmpty); // not sent mid-sentence

    speech.say('i going home', done: true);
    await settle(tester);
    expect(asked.single, contains('i going home'));
    expect(find.text('BETTER WAY TO SAY IT'), findsOneWidget);
    expect(find.text("I'm heading home."), findsOneWidget);
  });

  testWidgets('tapping the mic again stops and sends what was heard', (
    tester,
  ) async {
    await start(tester);
    await tester.tap(find.bySemanticsLabel('Speak'));
    await settle(tester);
    speech.say('i going home'); // no final result yet
    await settle(tester);
    await tester.tap(find.bySemanticsLabel('Stop listening'));
    await settle(tester);
    expect(asked.single, contains('i going home'));
    expect(find.bySemanticsLabel('Speak'), findsOneWidget); // mic is idle
  });

  testWidgets('stopping before saying anything does not re-send typed text', (
    tester,
  ) async {
    await start(tester);
    await tester.enterText(find.byType(TextField), 'typed earlier');
    await tester.tap(find.bySemanticsLabel('Speak'));
    await settle(tester);
    await tester.tap(find.bySemanticsLabel('Stop listening'));
    await settle(tester);
    expect(asked, isEmpty);
    expect(find.text('typed earlier'), findsOneWidget); // left alone
    expect(find.bySemanticsLabel('Speak'), findsOneWidget);
  });

  testWidgets('mic busy from the last recording: retries instead of failing', (
    tester,
  ) async {
    await start(tester);
    speech.busyStarts = 1;
    await tester.tap(find.bySemanticsLabel('Speak'));
    await settle(tester);
    expect(find.textContaining('Voice input'), findsNothing);
    expect(find.bySemanticsLabel('Stop listening'), findsOneWidget);
    speech.say('i going home', done: true);
    await settle(tester);
    expect(asked.single, contains('i going home'));
  });

  testWidgets('record, stop, record again right away: both work', (
    tester,
  ) async {
    await start(tester, size: const Size(1200, 900)); // mic stays in view
    for (final words in ['first one', 'second one']) {
      await tester.tap(find.bySemanticsLabel('Speak'));
      await settle(tester);
      speech.say(words, done: true);
      await settle(tester);
    }
    expect(asked, hasLength(2));
    expect(asked.last, contains('second one'));
  });

  testWidgets('a new screen (after sign-out/in) still gets the voice', (
    tester,
  ) async {
    await start(tester);
    await tester.tap(find.bySemanticsLabel('Speak'));
    await settle(tester);
    speech.say('old screen', done: true);
    await settle(tester);
    await tester.pumpWidget(const SizedBox()); // screen closed
    await start(tester); // fresh screen, same shared engine
    await tester.tap(find.bySemanticsLabel('Speak'));
    await settle(tester);
    speech.say('new screen', done: true);
    await settle(tester);
    expect(asked.single, contains('new screen'));
    expect(find.text("I'm heading home."), findsOneWidget);
  });

  testWidgets('double-tapping the mic starts only one recording', (
    tester,
  ) async {
    await start(tester);
    await tester.tap(find.bySemanticsLabel('Speak'));
    await tester.tap(find.bySemanticsLabel('Speak'), warnIfMissed: false);
    await settle(tester);
    expect(speech.starts, 1); // never two recordings at once
    expect(find.textContaining('Voice input'), findsNothing);
  });

  testWidgets('speak Urdu in Translate: the chosen speech language is used', (
    tester,
  ) async {
    await start(tester);
    await tester.tap(find.text('Translate').first);
    await settle(tester);
    await tester.tap(find.text('Urdu')); // target language
    await settle(tester);

    await tester.tap(find.text('EN')); // "I will speak in"
    await settle(tester);
    await tester.tap(find.text('Hindi').last);
    await settle(tester);
    expect(find.text('HI'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Speak'));
    await settle(tester);
    expect(speech.locale, 'hi-IN');
    speech.say('main ghar ja raha hoon', done: true);
    await settle(tester);
    expect(asked.single, contains('main ghar ja raha hoon'));
    expect(find.text('Copy translation'), findsOneWidget);
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
