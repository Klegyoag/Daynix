import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../main.dart' show LocalStore;
import 'gemini_chat_service.dart';

const _pink = Color(0xffff77ae);
const _keyName = 'daynix_gemini_api_key';

class _DaynixTasks implements ChatTaskGateway {
  _DaynixTasks(this.context);
  final BuildContext context;
  final store = LocalStore.instance;

  @override
  Future<List<Map<String, Object?>>> listTasks() async =>
      (await store.read('tasks'))
          .take(100)
          .map(
            (row) => <String, Object?>{
              'title': row['title'],
              'dueAt': row['dueAt'],
              'priority': row['priority'],
              'completed': row['completed'],
            },
          )
          .toList();

  @override
  Future<String> addTask(Map<String, dynamic> arguments) async {
    final title = arguments['title']?.toString().trim() ?? '';
    if (title.isEmpty) return 'Task title is required.';
    final priority = switch (arguments['priority']?.toString().toLowerCase()) {
      'low' => 0,
      'high' => 2,
      'urgent' => 3,
      _ => 1,
    };
    DateTime? due;
    final days = arguments['dueDateDaysFromNow'];
    if (days is num && days >= 0 && days <= 3650) {
      final now = DateTime.now();
      final date = DateTime(now.year, now.month, now.day + days.toInt());
      final time = RegExp(r'^(\d{1,2}):(\d{2})$')
          .firstMatch(arguments['dueTime']?.toString() ?? '');
      if (time != null) {
        final hour = int.parse(time.group(1)!);
        final minute = int.parse(time.group(2)!);
        if (hour <= 23 && minute <= 59) {
          due = DateTime(date.year, date.month, date.day, hour, minute);
        }
      }
      due ??= DateTime(date.year, date.month, date.day, 23, 59);
    }
    final hasSpecificTime =
        arguments['dueTime'] != null &&
        RegExp(r'^\d{1,2}:\d{2}$').hasMatch(arguments['dueTime'].toString());
    await store.createTask({
      'title': title,
      'description': arguments['description']?.toString() ?? '',
      'project': arguments['category']?.toString(),
      'priority': priority,
      'dueAt': due?.toIso8601String(),
      'reminderEnabled': hasSpecificTime ? 1 : 0,
    }, []);
    return 'Added task "$title" to DAYNIX.';
  }

  Future<Map<String, Object?>?> _match(String query) async {
    final clean = query.trim().toLowerCase();
    if (clean.isEmpty) return null;
    final rows = await store.read('tasks');
    final exact = rows
        .where((row) => (row['title'] as String? ?? '').toLowerCase() == clean)
        .toList();
    if (exact.length == 1) return exact.first;
    if (exact.length > 1) throw StateError('Several tasks have that title.');
    final partial = rows
        .where(
          (row) =>
              (row['title'] as String? ?? '').toLowerCase().contains(clean),
        )
        .toList();
    if (partial.length == 1) return partial.first;
    if (partial.length > 1) {
      throw StateError('Several tasks match "$query". Be more specific.');
    }
    return null;
  }

  @override
  Future<String> completeTask(String query) async {
    final task = await _match(query);
    if (task == null) return 'No task matched "$query".';
    if (task['completed'] == 1) {
      return 'Task "${task['title']}" is already complete.';
    }
    await store.setTaskCompleted(task, true);
    return 'Completed task "${task['title']}".';
  }

  @override
  Future<String> deleteTask(String query) async {
    final task = await _match(query);
    if (task == null) return 'No task matched "$query".';
    if (!context.mounted) return 'Deletion canceled.';
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete task?'),
        content: Text('Delete "${task['title']}" from DAYNIX?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep task'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (approved != true) return 'Deletion canceled by user.';
    await store.deleteTask(task['id'] as String);
    return 'Deleted task "${task['title']}".';
  }

  @override
  Future<String> breakDownTask(Map<String, dynamic> arguments) async {
    final parent = arguments['parentTask']?.toString().trim() ?? '';
    final raw = arguments['subtasks'];
    if (parent.isEmpty || raw is! List) {
      return 'A main task and steps are required.';
    }
    final steps = raw
        .map((value) => value.toString().trim())
        .where((value) => value.isNotEmpty)
        .take(30)
        .toList();
    if (steps.isEmpty) return 'No valid steps were provided.';
    if (arguments['autoAddToList'] == false) {
      return 'Suggested steps for "$parent": ${steps.join('; ')}';
    }
    await store.createTask({'title': parent}, steps);
    return 'Added "$parent" with ${steps.length} subtasks.';
  }
}

class AiChatPage extends StatefulWidget {
  const AiChatPage({super.key, this.popup = false});
  final bool popup;
  @override
  State<AiChatPage> createState() => _AiChatPageState();
}

class _AiChatPageState extends State<AiChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _secure = const FlutterSecureStorage();
  final _service = GeminiChatService();
  final _speech = stt.SpeechToText();
  final _tts = FlutterTts();
  String _dictationPrefix = '';
  bool _listening = false;
  bool _voiceReplies = true;
  final _messages = <Map<String, String>>[];
  String _model = GeminiChatService.models.first;
  String? _apiKey;
  bool _busy = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final key = await _secure.read(key: _keyName);
      final model = await LocalStore.instance.setting('gemini_model');
      final voiceSetting = await LocalStore.instance.setting(
        'ai_voice_replies',
      );
      final rows = await LocalStore.instance.read(
        'ai_chat_messages',
        order: 'createdAt ASC',
      );
      if (!mounted) return;
      setState(() {
        _apiKey = key;
        _voiceReplies = voiceSetting != 'false';
        if (GeminiChatService.models.contains(model)) _model = model!;
        _messages.addAll(
          rows.map(
            (row) => {
              'role': row['role'] as String,
              'text': row['text'] as String,
            },
          ),
        );
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _saveMessage(String role, String value) async {
    await LocalStore.instance.db.insert('ai_chat_messages', {
      'id': DateTime.now().microsecondsSinceEpoch.toString(),
      'role': role,
      'text': value,
      'createdAt': DateTime.now().toIso8601String(),
    });
    if (!mounted) return;
    setState(() => _messages.add({'role': role, 'text': value}));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send([String? prompt]) async {
    final value = (prompt ?? _input.text).trim();
    if (value.isEmpty || _busy) return;
    if (_apiKey == null || _apiKey!.isEmpty) {
      await _settings();
      if (_apiKey == null || _apiKey!.isEmpty) return;
    }
    _input.clear();
    await _saveMessage('user', value);
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      final answer = await _service.reply(
        apiKey: _apiKey!,
        model: _model,
        history: _messages,
        tasks: _DaynixTasks(context),
      );
      await _saveMessage(
        'model',
        answer.isEmpty ? 'Gemini returned an empty answer.' : answer,
      );
      if (answer.isNotEmpty && _voiceReplies) _speak(answer);
    } on TimeoutException {
      await _saveMessage(
        'model',
        'Gemini took too long to reply. Check your connection or try the faster Gemini 3.5 Flash-Lite model in Settings.',
      );
    } catch (error) {
      await _saveMessage('model', 'Could not reach Gemini: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleDictation() async {
    if (_speech.isListening) {
      await _speech.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    try {
      await _tts.stop();
      final available = await _speech.initialize(
        onStatus: (status) {
          if (mounted) setState(() => _listening = status == 'listening');
        },
        onError: (error) =>
            _voiceError('Speech recognition: ${error.errorMsg}'),
      );
      if (!available) {
        _voiceError(
          'Speech recognition is unavailable. Check microphone permission and the device speech service.',
        );
        return;
      }
      _dictationPrefix = _input.text.trim();
      await _speech.listen(
        onResult: (result) {
          if (!mounted) return;
          final words = result.recognizedWords.trim();
          final value = [
            _dictationPrefix,
            words,
          ].where((part) => part.isNotEmpty).join(' ');
          _input.value = TextEditingValue(
            text: value,
            selection: TextSelection.collapsed(offset: value.length),
          );
          if (result.finalResult) setState(() => _listening = false);
        },
        listenOptions: stt.SpeechListenOptions(
          listenMode: stt.ListenMode.dictation,
          partialResults: true,
          listenFor: const Duration(seconds: 60),
          pauseFor: const Duration(seconds: 4),
        ),
      );
      if (mounted) setState(() => _listening = true);
    } catch (_) {
      _voiceError(
        'Could not start voice typing. Check microphone permission and speech services.',
      );
    }
  }

  void _voiceError(String message) {
    if (!mounted) return;
    setState(() => _listening = false);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _toggleVoiceReplies() async {
    final enabled = !_voiceReplies;
    setState(() => _voiceReplies = enabled);
    await LocalStore.instance.setSetting('ai_voice_replies', '$enabled');
    if (!enabled) await _tts.stop();
  }

  void _speak(String answer) {
    final spoken = answer
        .replaceAll(RegExp(r'[`*_#]'), '')
        .replaceAll(RegExp(r'\[[^\]]+\]\([^)]*\)'), '')
        .trim();
    if (spoken.isEmpty) return;
    unawaited(() async {
      try {
        await _tts.stop();
        await _tts.setSpeechRate(0.48);
        await _tts.speak(spoken);
      } catch (_) {
        _voiceError('Voice response is unavailable on this device.');
      }
    }());
  }

  void _closePopup() {
    if (widget.popup) {
      unawaited(SystemNavigator.pop());
    } else {
      Navigator.of(context).pop();
    }
  }

  Future<void> _settings() async {
    final controller = TextEditingController(text: _apiKey ?? '');
    var visible = false;
    var selectedModel = _model;
    final result = await showDialog<(String, String)?>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Gemini chat settings'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'DAYNIX sends your message to Google Gemini when you tap Send. If your question needs saved tasks, Gemini can request their titles, dates, priorities and completion state. The rest of DAYNIX works offline.',
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: controller,
                  obscureText: !visible,
                  decoration: InputDecoration(
                    labelText: 'Gemini API key',
                    suffixIcon: IconButton(
                      onPressed: () => update(() => visible = !visible),
                      icon: Icon(
                        visible ? Icons.visibility_off : Icons.visibility,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: selectedModel,
                  decoration: const InputDecoration(labelText: 'Model'),
                  items: GeminiChatService.models
                      .map(
                        (model) =>
                            DropdownMenuItem(value: model, child: Text(model)),
                      )
                      .toList(),
                  onChanged: (value) =>
                      update(() => selectedModel = value ?? selectedModel),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, ('', selectedModel)),
              child: const Text('Remove key'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, (
                controller.text.trim(),
                selectedModel,
              )),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (result == null) return;
    if (result.$1.isEmpty) {
      await _secure.delete(key: _keyName);
    } else {
      await _secure.write(key: _keyName, value: result.$1);
    }
    await LocalStore.instance.setSetting('gemini_model', result.$2);
    if (mounted) {
      setState(() {
        _apiKey = result.$1;
        _model = result.$2;
      });
    }
  }

  Future<void> _clearHistory() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear chat history?'),
        content: const Text('Your DAYNIX tasks will remain.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await LocalStore.instance.db.delete('ai_chat_messages');
    if (mounted) setState(_messages.clear);
  }

  @override
  void dispose() {
    _service.close();
    unawaited(_speech.cancel());
    unawaited(_tts.stop());
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final surface = dark ? const Color(0xff241a27) : Colors.white;
    final chat = Scaffold(
      appBar: AppBar(
        leading: widget.popup
            ? IconButton(
                icon: const Icon(Icons.close_rounded),
                tooltip: 'Close AI popup',
                onPressed: _closePopup,
              )
            : null,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('DAYNIX AI', style: TextStyle(fontWeight: FontWeight.w800)),
            Text('Your Gemini task assistant', style: TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _toggleVoiceReplies,
            icon: Icon(
              _voiceReplies
                  ? Icons.volume_up_rounded
                  : Icons.volume_off_rounded,
            ),
            tooltip: _voiceReplies
                ? 'Turn spoken replies off'
                : 'Turn spoken replies on',
          ),
          IconButton(
            onPressed: _settings,
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Gemini settings',
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'clear') _clearHistory();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'clear', child: Text('Clear chat history')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (_apiKey == null || _apiKey!.isEmpty)
            MaterialBanner(
              content: const Text(
                'Add your Gemini API key to use AI chat. DAYNIX tasks remain available offline.',
              ),
              actions: [
                TextButton(onPressed: _settings, child: const Text('Set up')),
              ],
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _messages.isEmpty
                ? _welcome(surface)
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(18),
                    itemCount: _messages.length + (_busy ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == _messages.length) {
                        return const Padding(
                          padding: EdgeInsets.all(16),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: CircularProgressIndicator(),
                          ),
                        );
                      }
                      final message = _messages[index];
                      final user = message['role'] == 'user';
                      return Align(
                        alignment: user
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(15),
                          constraints: BoxConstraints(
                            maxWidth: MediaQuery.sizeOf(context).width * .82,
                          ),
                          decoration: BoxDecoration(
                            color: user
                                ? _pink.withValues(alpha: dark ? .25 : .18)
                                : surface,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: user
                                  ? _pink
                                  : Theme.of(context).dividerColor,
                            ),
                          ),
                          child: SelectableText(message['text'] ?? ''),
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      enabled: !_busy,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: _listening
                            ? 'Listening…'
                            : 'Ask DAYNIX AI anything…',
                        prefixIcon: const Icon(Icons.auto_awesome),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: _busy ? null : _toggleDictation,
                    icon: Icon(
                      _listening
                          ? Icons.stop_circle_rounded
                          : Icons.mic_rounded,
                    ),
                    color: _listening ? _pink : null,
                    tooltip: _listening ? 'Stop voice typing' : 'Voice typing',
                  ),
                  const SizedBox(width: 4),
                  IconButton.filled(
                    onPressed: _busy ? null : () => _send(),
                    icon: const Icon(Icons.send_rounded),
                    tooltip: 'Send to Gemini',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    if (!widget.popup) return chat;
    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: .60),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _closePopup,
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, bounds) => Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 16,
                ),
                child: GestureDetector(
                  onTap: () {},
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: SizedBox(
                      height: (bounds.maxHeight - 32).clamp(280.0, 680.0),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(28),
                        child: chat,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _welcome(Color surface) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const Icon(Icons.auto_awesome_rounded, color: _pink, size: 54),
          const SizedBox(height: 15),
          const Text(
            'Plan with DAYNIX AI',
            style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Ask Gemini to add, complete, list or break down your tasks.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          for (final prompt in [
            'What tasks do I have today?',
            'Add a task to plan tomorrow',
            'Break down my next project',
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => _send(prompt),
                  style: OutlinedButton.styleFrom(backgroundColor: surface),
                  child: Text(prompt),
                ),
              ),
            ),
          const SizedBox(height: 12),
          const Text(
            'Your message and task summary go to Google only when you send. Gemini needs internet and your own API key.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    ),
  );
}
