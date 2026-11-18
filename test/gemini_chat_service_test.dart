import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:personal_productivity_app/features/ai_chat/gemini_chat_service.dart';

class _Tasks implements ChatTaskGateway {
  final created = <String>[];
  @override
  Future<String> addTask(Map<String, dynamic> arguments) async {
    final title = arguments['title'] as String;
    created.add(title);
    return 'Added task "$title" to DAYNIX.';
  }

  @override
  Future<String> breakDownTask(Map<String, dynamic> arguments) async =>
      'Added subtasks';
  @override
  Future<String> completeTask(String query) async => 'Completed "$query"';
  @override
  Future<String> deleteTask(String query) async => 'Deletion canceled by user.';
  @override
  Future<List<Map<String, Object?>>> listTasks() async => [
    {'title': 'Existing task', 'completed': 0, 'priority': 1},
  ];
}

void main() {
  test(
    'Gemini tool call saves via DAYNIX gateway and sends tool result',
    () async {
      final tasks = _Tasks();
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        expect(request.headers['x-goog-api-key'], 'test-key');
        expect(request.url.query, isEmpty);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (requests == 1) {
          expect(body['tools'], isNotEmpty);
          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {
                        'functionCall': {
                          'name': 'addTask',
                          'args': {'title': 'Buy milk'},
                        },
                      },
                    ],
                  },
                },
              ],
            }),
            200,
          );
        }
        expect(jsonEncode(body['contents']), contains('Added task'));
        return http.Response(
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'I added Buy milk.'},
                  ],
                },
              },
            ],
          }),
          200,
        );
      });
      final service = GeminiChatService(client: client);
      final result = await service.reply(
        apiKey: 'test-key',
        model: GeminiChatService.models.first,
        history: [
          {'role': 'user', 'text': 'Add Buy milk'},
        ],
        tasks: tasks,
      );
      expect(result, 'I added Buy milk.');
      expect(tasks.created, ['Buy milk']);
      expect(requests, 2);
      service.close();
    },
  );

  test(
    'general question does not send saved tasks without a tool call',
    () async {
      final client = MockClient((request) async {
        expect(request.body, isNot(contains('Existing task')));
        return http.Response(
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'A short answer.'},
                  ],
                },
              },
            ],
          }),
          200,
        );
      });
      final service = GeminiChatService(client: client);
      final answer = await service.reply(
        apiKey: 'test-key',
        model: GeminiChatService.models.first,
        history: [
          {'role': 'user', 'text': 'What is a healthy work break?'},
        ],
        tasks: _Tasks(),
      );
      expect(answer, 'A short answer.');
      service.close();
    },
  );

  test('chat refuses missing API key without a network request', () async {
    final service = GeminiChatService(
      client: MockClient((_) async {
        fail('Network should not be called');
      }),
    );
    expect(
      () => service.reply(
        apiKey: '',
        model: GeminiChatService.models.first,
        history: const [],
        tasks: _Tasks(),
      ),
      throwsStateError,
    );
    service.close();
  });

  test(
    'completed local tool action survives a slow Gemini follow-up',
    () async {
      final tasks = _Tasks();
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        if (requests == 1) {
          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {
                        'functionCall': {
                          'name': 'addTask',
                          'args': {'title': 'Read book'},
                        },
                      },
                    ],
                  },
                },
              ],
            }),
            200,
          );
        }
        throw TimeoutException('Follow-up timed out');
      });
      final service = GeminiChatService(client: client);
      final result = await service.reply(
        apiKey: 'test-key',
        model: GeminiChatService.models.first,
        history: [
          {'role': 'user', 'text': 'Add Read book'},
        ],
        tasks: tasks,
      );
      expect(result, contains('Added task "Read book"'));
      expect(tasks.created, ['Read book']);
      expect(requests, 2);
      service.close();
    },
  );

  test('the fast model is selected by default', () {
    expect(GeminiChatService.models.first, 'gemini-3.5-flash-lite');
  });
}
