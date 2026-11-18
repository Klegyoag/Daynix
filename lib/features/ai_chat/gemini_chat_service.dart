import 'dart:convert';

import 'package:http/http.dart' as http;

/// The original Antigravity chatbot's task tools, backed by DAYNIX's task store.
abstract class ChatTaskGateway {
  Future<List<Map<String, Object?>>> listTasks();
  Future<String> addTask(Map<String, dynamic> arguments);
  Future<String> completeTask(String query);
  Future<String> deleteTask(String query);
  Future<String> breakDownTask(Map<String, dynamic> arguments);
}

class GeminiChatService {
  GeminiChatService({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  static const models = [
    'gemini-3.5-flash-lite',
    'gemini-3.8-flash',
    'gemini-2.5-flash',
  ];

  static const _tools = [
    {
      'functionDeclarations': [
        {
          'name': 'addTask',
          'description': 'Create a task in DAYNIX.',
          'parameters': {
            'type': 'OBJECT',
            'properties': {
              'title': {'type': 'STRING'},
              'description': {'type': 'STRING'},
              'priority': {
                'type': 'STRING',
                'enum': ['low', 'medium', 'high', 'urgent'],
              },
              'category': {'type': 'STRING'},
              'dueDateDaysFromNow': {'type': 'INTEGER'},
              'dueTime': {
                'type': 'STRING',
                'description': 'Optional local 24-hour HH:mm. Omit if no time was requested.',
              },
            },
            'required': ['title'],
          },
        },
        {
          'name': 'completeTask',
          'description': 'Complete one existing DAYNIX task by title.',
          'parameters': {
            'type': 'OBJECT',
            'properties': {
              'taskQuery': {'type': 'STRING'},
            },
            'required': ['taskQuery'],
          },
        },
        {
          'name': 'deleteTask',
          'description': 'Request deletion of one existing task. DAYNIX asks the user to confirm.',
          'parameters': {
            'type': 'OBJECT',
            'properties': {
              'taskQuery': {'type': 'STRING'},
            },
            'required': ['taskQuery'],
          },
        },
        {
          'name': 'listTasks',
          'description': 'List the user\'s existing DAYNIX tasks.',
          'parameters': {
            'type': 'OBJECT',
            'properties': {
              'filter': {
                'type': 'STRING',
                'enum': ['all', 'pending', 'completed'],
              },
            },
          },
        },
        {
          'name': 'breakDownTask',
          'description':
              'Create a main task with the suggested steps as its subtasks.',
          'parameters': {
            'type': 'OBJECT',
            'properties': {
              'parentTask': {'type': 'STRING'},
              'subtasks': {
                'type': 'ARRAY',
                'items': {'type': 'STRING'},
              },
              'autoAddToList': {'type': 'BOOLEAN'},
            },
            'required': ['parentTask', 'subtasks'],
          },
        },
      ],
    },
  ];

  Future<Map<String, dynamic>> _post(
    String key,
    String model,
    Map<String, dynamic> body,
  ) async {
    if (!models.contains(model)) throw const FormatException('Unknown model');
    final response = await _client
        .post(
          Uri.https(
            'generativelanguage.googleapis.com',
            '/v1beta/models/$model:generateContent',
          ),
          headers: {'Content-Type': 'application/json', 'x-goog-api-key': key},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 90));
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid Gemini response');
    }
    if (response.statusCode != 200) {
      final error = decoded['error'];
      final message = error is Map ? error['message'] : null;
      throw StateError(
        message is String ? message : 'Gemini HTTP ${response.statusCode}',
      );
    }
    return decoded;
  }

  static List<Map<String, dynamic>> _parts(Map<String, dynamic> response) {
    final candidates = response['candidates'];
    if (candidates is! List || candidates.isEmpty) {
      throw const FormatException('Gemini returned no answer');
    }
    final content = candidates.first['content'];
    final parts = content?['parts'];
    if (parts is! List || parts.isEmpty) {
      throw const FormatException('Gemini returned no content');
    }
    return parts
        .whereType<Map>()
        .map((part) => Map<String, dynamic>.from(part))
        .toList();
  }

  static String _text(List<Map<String, dynamic>> parts) =>
      parts.map((part) => part['text']).whereType<String>().join('\n').trim();

  Future<String> reply({
    required String apiKey,
    required String model,
    required List<Map<String, String>> history,
    required ChatTaskGateway tasks,
  }) async {
    if (apiKey.trim().isEmpty) {
      throw StateError('Add your Gemini API key in chat settings.');
    }
    final instruction = {
      'parts': [
        {
          'text':
              'You are DAYNIX AI. Answer general questions conversationally as well as helping with tasks. If you do not know, say so. Today is ${DateTime.now().toLocal().toIso8601String().split('T').first}. '
              'Use addTask, completeTask, deleteTask, listTasks, and breakDownTask for real task actions. '
              'Never claim an action succeeded unless its tool response says so. '
              'A date without a time should not imply an alarm time. Keep replies clear and concise. '
              'For questions about saved tasks, call listTasks; do not assume task details.',
        },
      ],
    };
    final contents = history
        .takeLast(12)
        .map(
          (message) => {
            'role': message['role'] == 'user' ? 'user' : 'model',
            'parts': [
              {'text': message['text'] ?? ''},
            ],
          },
        )
        .toList();
    final first = _parts(
      await _post(apiKey, model, {
        'systemInstruction': instruction,
        'tools': _tools,
        'contents': contents,
      }),
    );
    final calls = first.where((part) => part['functionCall'] is Map).toList();
    if (calls.isEmpty) return _text(first);

    final responses = <Map<String, dynamic>>[];
    final descriptions = <String>[];
    for (final part in calls.take(5)) {
      final call = Map<String, dynamic>.from(part['functionCall'] as Map);
      final name = call['name']?.toString() ?? '';
      final args = call['args'] is Map
          ? Map<String, dynamic>.from(call['args'] as Map)
          : <String, dynamic>{};
      String result;
      try {
        result = switch (name) {
          'addTask' => await tasks.addTask(args),
          'completeTask' => await tasks.completeTask(
            args['taskQuery']?.toString() ?? '',
          ),
          'deleteTask' => await tasks.deleteTask(
            args['taskQuery']?.toString() ?? '',
          ),
          'listTasks' => jsonEncode(await tasks.listTasks()),
          'breakDownTask' => await tasks.breakDownTask(args),
          _ => 'Unsupported action',
        };
      } catch (error) {
        result = 'Action failed: $error';
      }
      descriptions.add(result);
      responses.add({
        'functionResponse': {
          'name': name,
          'response': {'result': result},
        },
      });
    }
    try {
      final second = _parts(
        await _post(apiKey, model, {
          'systemInstruction': instruction,
          'contents': [
            ...contents,
            {'role': 'model', 'parts': first},
            {'role': 'user', 'parts': responses},
          ],
        }),
      );
      final answer = _text(second);
      return answer.isEmpty ? descriptions.join('\n') : answer;
    } catch (_) {
      // Local task actions already succeeded. Do not report a failed action or
      // retry the whole turn, which could duplicate a newly created task.
      return descriptions.join('\n');
    }
  }

  void close() => _client.close();
}

extension _TakeLast<T> on Iterable<T> {
  Iterable<T> takeLast(int count) {
    final values = toList();
    return values.skip(values.length > count ? values.length - count : 0);
  }
}
