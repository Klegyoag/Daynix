import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';

import 'recurrence.dart';
import 'note_format.dart';
import 'features/ai_chat/ai_chat.dart';
import 'features/security/app_lock.dart';
import 'features/notes/note_photo_strip.dart';

final taskiyaTheme = ValueNotifier<ThemeMode>(ThemeMode.system);
const taskiyaNative = MethodChannel('taskiya/native');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LocalStore.instance.open();
  final mode = await LocalStore.instance.setting('theme_mode') ?? 'dark';
  taskiyaTheme.value = switch (mode) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };
  runApp(const TaskiyaApp());
}

class LocalStore {
  LocalStore._();
  static final instance = LocalStore._();
  late Database db;
  static const _widgetChannel = MethodChannel('taskiya/native');

  Future<void> refreshWidgets() async {
    try {
      await _widgetChannel.invokeMethod<void>('refreshWidgets');
    } on PlatformException {
      // Widgets refresh on their next system update when the host is unavailable.
    } on MissingPluginException {
      // Native widgets are absent in desktop SQLite tests.
    }
  }

  Future<void> open({String? path}) async {
    db = await openDatabase(
      path ?? '${await getDatabasesPath()}/productivity.db',
      version: 5,
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE tasks(id TEXT PRIMARY KEY,title TEXT NOT NULL,description TEXT,dueAt TEXT,priority INTEGER NOT NULL DEFAULT 1,completed INTEGER NOT NULL DEFAULT 0,createdAt TEXT NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE notes(id TEXT PRIMARY KEY,title TEXT NOT NULL,body TEXT NOT NULL,updatedAt TEXT NOT NULL,pinned INTEGER NOT NULL DEFAULT 0)',
        );
        await db.execute(
          'CREATE TABLE habits(id TEXT PRIMARY KEY,title TEXT NOT NULL,doneDay TEXT)',
        );
        await db.execute(
          'CREATE TABLE dumps(id TEXT PRIMARY KEY,body TEXT NOT NULL,createdAt TEXT NOT NULL)',
        );
        await _createV2(db);
        await _createV3(db);
        await _createV4(db);
        await _createV5(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) await _createV2(db);
        if (oldVersion < 3) await _createV3(db);
        if (oldVersion < 4) await _createV4(db);
        if (oldVersion < 5) await _createV5(db);
      },
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS habit_entries(habitId TEXT NOT NULL,day TEXT NOT NULL,PRIMARY KEY(habitId,day),FOREIGN KEY(habitId) REFERENCES habits(id) ON DELETE CASCADE)',
    );
    await db.execute(
      'INSERT OR IGNORE INTO habit_entries(habitId,day) SELECT id,doneDay FROM habits WHERE doneDay IS NOT NULL',
    );
  }

  static Future<void> _createV2(DatabaseExecutor db) async {
    for (final sql in [
      'ALTER TABLE tasks ADD COLUMN project TEXT',
      'ALTER TABLE tasks ADD COLUMN labels TEXT',
      'ALTER TABLE tasks ADD COLUMN location TEXT',
      'ALTER TABLE tasks ADD COLUMN attachmentUri TEXT',
      'ALTER TABLE tasks ADD COLUMN reminderEnabled INTEGER NOT NULL DEFAULT 1',
      'ALTER TABLE notes ADD COLUMN folder TEXT',
      'ALTER TABLE notes ADD COLUMN tags TEXT',
    ]) {
      await db.execute(sql);
    }
    await db.execute(
      'CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY,value TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS subtasks(id TEXT PRIMARY KEY,taskId TEXT NOT NULL,title TEXT NOT NULL,completed INTEGER NOT NULL DEFAULT 0,FOREIGN KEY(taskId) REFERENCES tasks(id) ON DELETE CASCADE)',
    );
  }

  static Future<void> _createV3(DatabaseExecutor db) async {
    await db.execute(
      "ALTER TABLE tasks ADD COLUMN recurrence TEXT NOT NULL DEFAULT 'none'",
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS task_occurrences(taskId TEXT NOT NULL,scheduledAt TEXT NOT NULL,completedAt TEXT NOT NULL,PRIMARY KEY(taskId,scheduledAt),FOREIGN KEY(taskId) REFERENCES tasks(id) ON DELETE CASCADE)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS task_due_index ON tasks(dueAt,completed)',
    );
  }

  static Future<void> _createV4(DatabaseExecutor db) async {
    await db.execute(
      'CREATE TABLE IF NOT EXISTS ai_chat_messages(id TEXT PRIMARY KEY,role TEXT NOT NULL,text TEXT NOT NULL,createdAt TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS ai_chat_messages_date ON ai_chat_messages(createdAt)',
    );
  }

  static Future<void> _createV5(DatabaseExecutor db) async {
    await db.execute(
      'CREATE TABLE IF NOT EXISTS note_photos(id TEXT PRIMARY KEY,noteId TEXT NOT NULL,path TEXT NOT NULL,addedAt TEXT NOT NULL,FOREIGN KEY(noteId) REFERENCES notes(id) ON DELETE CASCADE)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS note_photos_note_index ON note_photos(noteId,addedAt)',
    );
  }

  Future<void> upsertNote(Map<String, Object?> values) async {
    final id = values['id'];
    if (id is! String || id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'Note ID is required');
    }
    final fields = Map<String, Object?>.of(values)..remove('id');
    await db.transaction((txn) async {
      final count = await txn.update(
        'notes',
        fields,
        where: 'id=?',
        whereArgs: [id],
      );
      if (count == 0) {
        await txn.insert('notes', {'id': id, ...fields});
      }
    });
  }

  Future<String?> setting(String key) async {
    final rows = await db.query('settings', where: 'key=?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> setSetting(String key, String value) async {
    await db.insert('settings', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await refreshWidgets();
  }

  Future<void> createTask(
    Map<String, Object?> values,
    List<String> subtaskTitles,
  ) async {
    final title = values['title'];
    if (title is! String || title.trim().isEmpty) {
      throw ArgumentError.value(title, 'title', 'Task title is required');
    }
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final now = DateTime.now().toIso8601String();
    await db.transaction((txn) async {
      await txn.insert('tasks', {
        'id': id,
        'title': title.trim(),
        'description': values['description'],
        'dueAt': values['dueAt'],
        'priority': values['priority'] ?? 1,
        'project': values['project'],
        'labels': values['labels'],
        'location': values['location'],
        'attachmentUri': values['attachmentUri'],
        'reminderEnabled': values['reminderEnabled'] ?? 1,
        'recurrence': values['recurrence'] ?? 'none',
        'completed': 0,
        'createdAt': now,
      });
      var subtaskIndex = 0;
      for (final title in subtaskTitles.where((x) => x.trim().isNotEmpty)) {
        await txn.insert('subtasks', {
          'id': '$id:${subtaskIndex++}',
          'taskId': id,
          'title': title.trim(),
          'completed': 0,
        });
      }
    });
    await refreshWidgets();
    if (values['dueAt'] != null && values['reminderEnabled'] != 0) {
      try {
        await taskiyaNative.invokeMethod('scheduleReminder', {
          'id': id,
          'title': values['title'],
          'dueAt': values['dueAt'],
        });
      } on PlatformException {
        /* The task remains saved. */
      } on MissingPluginException {
        // Android reminders are unavailable in desktop SQLite tests.
      }
    }
  }

  Future<void> updateTask(
    String id,
    Map<String, Object?> values,
    List<String> subtaskTitles,
  ) async {
    final title = values['title'];
    if (title is! String || title.trim().isEmpty) {
      throw ArgumentError.value(title, 'title', 'Task title is required');
    }
    values = {...values, 'title': title.trim()};
    await db.transaction((txn) async {
      await txn.update('tasks', values, where: 'id=?', whereArgs: [id]);
      await txn.delete('subtasks', where: 'taskId=?', whereArgs: [id]);
      var subtaskIndex = 0;
      for (final title in subtaskTitles.where((x) => x.trim().isNotEmpty)) {
        await txn.insert('subtasks', {
          'id': '$id:${subtaskIndex++}',
          'taskId': id,
          'title': title.trim(),
          'completed': 0,
        });
      }
    });
    await refreshWidgets();
    try {
      await taskiyaNative.invokeMethod('cancelReminder', {'id': id});
      if (values['dueAt'] != null && values['reminderEnabled'] != 0) {
        await taskiyaNative.invokeMethod('scheduleReminder', {
          'id': id,
          'title': values['title'],
          'dueAt': values['dueAt'],
        });
      }
    } on PlatformException {
      // The edited task remains saved even if native reminders are unavailable.
    } on MissingPluginException {
      // Android reminders are unavailable in desktop SQLite tests.
    }
  }

  Future<void> deleteTask(String id) async {
    await db.delete('subtasks', where: 'taskId=?', whereArgs: [id]);
    await db.delete('tasks', where: 'id=?', whereArgs: [id]);
    await refreshWidgets();
    try {
      await taskiyaNative.invokeMethod('cancelReminder', {'id': id});
    } on PlatformException {
      // The task is deleted even if the platform channel is unavailable.
    } on MissingPluginException {
      // Android reminders are unavailable in desktop SQLite tests.
    }
  }

  Future<void> setTaskCompleted(
    Map<String, Object?> task,
    bool completed,
  ) async {
    final id = task['id'] as String;
    final repeat = task['recurrence'] as String? ?? 'none';
    final due = DateTime.tryParse(task['dueAt'] as String? ?? '');
    DateTime? next;
    if (completed && repeat != 'none' && due != null) {
      next = nextOccurrence(due, repeat, DateTime.now());
    }
    await db.transaction((txn) async {
      if (next != null) {
        await txn.insert('task_occurrences', {
          'taskId': id,
          'scheduledAt': task['dueAt'],
          'completedAt': DateTime.now().toIso8601String(),
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        await txn.update(
          'tasks',
          {'dueAt': next!.toIso8601String(), 'completed': 0},
          where: 'id=?',
          whereArgs: [id],
        );
      } else {
        await txn.update(
          'tasks',
          {'completed': completed ? 1 : 0},
          where: 'id=?',
          whereArgs: [id],
        );
      }
    });
    await refreshWidgets();
    try {
      await taskiyaNative.invokeMethod('cancelReminder', {'id': id});
      final scheduled =
          next?.toIso8601String() ??
          (!completed && task['reminderEnabled'] != 0
              ? task['dueAt'] as String?
              : null);
      if (scheduled != null && task['reminderEnabled'] != 0) {
        await taskiyaNative.invokeMethod('scheduleReminder', {
          'id': id,
          'title': task['title'],
          'dueAt': scheduled,
        });
      }
    } on PlatformException {
      /* Saved locally. */
    } on MissingPluginException {
      /* Desktop tests. */
    }
  }

  Future<List<Map<String, Object?>>> read(
    String table, {
    String? where,
    List<Object?>? args,
    String order = 'rowid DESC',
  }) => db.query(table, where: where, whereArgs: args, orderBy: order);
  Future<void> addTask(String title) async {
    await createTask({'title': title.trim()}, []);
  }

  Future<void> clearProgress() async {
    await db.transaction((txn) async {
      await txn.update('tasks', {'completed': 0}, where: 'completed=1');
      await txn.delete('task_occurrences');
      await txn.delete('habit_entries');
      await txn.update('habits', {'doneDay': null});
    });
    await refreshWidgets();
  }
}

class TaskiyaApp extends StatelessWidget {
  const TaskiyaApp({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ThemeMode>(
    valueListenable: taskiyaTheme,
    builder: (context, mode, child) => MaterialApp(
      title: 'DAYNIX',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'TaskiyaRoboto',
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xffff5a99)),
        scaffoldBackgroundColor: const Color(0xfff7f7ff),
        cardTheme: const CardThemeData(
          color: Colors.white,
          elevation: 0,
          margin: EdgeInsets.zero,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        fontFamily: 'TaskiyaRoboto',
        colorScheme:
            ColorScheme.fromSeed(
              seedColor: const Color(0xffff91bb),
              brightness: Brightness.dark,
            ).copyWith(
              primary: const Color(0xffff91bb),
              onPrimary: const Color(0xff2b1420),
              surface: const Color(0xff201a22),
              onSurface: const Color(0xfff8eff5),
              surfaceContainerHighest: const Color(0xff302630),
              outline: const Color(0xff645364),
            ),
        scaffoldBackgroundColor: const Color(0xff120e15),
        appBarTheme: const AppBarTheme(backgroundColor: Color(0xff120e15)),
        cardTheme: CardThemeData(
          color: const Color(0xff201a22),
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: Color(0xff352b35)),
          ),
        ),
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Color(0xff211a22),
          indicatorColor: Color(0xff63364c),
        ),
        chipTheme: const ChipThemeData(
          backgroundColor: Color(0xff2d252e),
          selectedColor: Color(0xffff91bb),
          secondarySelectedColor: Color(0xffff91bb),
          side: BorderSide(color: Color(0xff584153)),
        ),
        datePickerTheme: DatePickerThemeData(
          backgroundColor: const Color(0xff211a22),
          headerBackgroundColor: const Color(0xff63364c),
          dayShape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: Color(0xff201a22),
          showDragHandle: true,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xff2d252e),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Color(0xff514050)),
          ),
        ),
      ),
      themeMode: mode,
      builder: (context, child) => AppLockGate(
        popup:
            WidgetsBinding.instance.platformDispatcher.defaultRouteName ==
            '/pet-ai',
        child: child!,
      ),
      routes: {'/pet-ai': (_) => const AiChatPage(popup: true)},
      home: const Workspace(),
    ),
  );
}

class Workspace extends StatefulWidget {
  const Workspace({super.key});
  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace> with WidgetsBindingObserver {
  int page = 0, revision = 0;
  final GlobalKey<_NotesPageState> notesKey = GlobalKey<_NotesPageState>();
  final GlobalKey<_PlannerPageState> plannerKey =
      GlobalKey<_PlannerPageState>();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  Future<void> refresh() async {
    if (mounted) setState(() => revision++);
  }

  Future<void> addTask({DateTime? initialDate}) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) =>
          TaskEditorSheet(onSaved: refresh, initialDate: initialDate),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomePage(
        key: ValueKey('home$revision'),
        changed: refresh,
        quickAdd: addTask,
        navigate: (index) => setState(() => page = index),
      ),
      TasksPage(
        key: ValueKey('tasks$revision'),
        changed: refresh,
        quickAdd: addTask,
      ),
      NotesPage(key: notesKey, changed: refresh),
      PlannerPage(
        key: plannerKey,
        changed: refresh,
        quickAdd: (date) => addTask(initialDate: date),
      ),
      MorePage(key: ValueKey('more$revision'), changed: refresh),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Image.asset('assets/taskiya_logo.png', width: 36, height: 36),
            const SizedBox(width: 10),
            const Text(
              'DAYNIX',
              style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: -.5),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: page == 2
                ? () => notesKey.currentState?.createNote()
                : page == 3
                ? () => plannerKey.currentState?.createTask()
                : addTask,
            icon: Icon(
              page == 2 ? Icons.note_add_outlined : Icons.add_circle_outline,
            ),
            tooltip: page == 2 ? 'Add note' : 'Quick add task',
          ),
        ],
      ),
      body: pages[page],
      floatingActionButton: page == 1 || page == 2 || page == 3
          ? null
          : FloatingActionButton.extended(
              onPressed: addTask,
              icon: const Icon(Icons.add),
              label: const Text('Quick add'),
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: page,
        onDestinationSelected: (v) => setState(() => page = v),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.grid_view_outlined),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.checklist_outlined),
            label: 'Tasks',
          ),
          NavigationDestination(
            icon: Icon(Icons.sticky_note_2_outlined),
            label: 'Notes',
          ),
          NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined),
            label: 'Planner',
          ),
          NavigationDestination(
            icon: Icon(Icons.widgets_outlined),
            label: 'More',
          ),
        ],
      ),
    );
  }
}

String formatDate(DateTime d) =>
    '${['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][d.weekday - 1]}, ${['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][d.month - 1]} ${d.day}';

class HomePage extends StatelessWidget {
  final Future<void> Function() changed, quickAdd;
  final ValueChanged<int> navigate;
  const HomePage({
    super.key,
    required this.changed,
    required this.quickAdd,
    required this.navigate,
  });
  @override
  Widget build(
    BuildContext context,
  ) => FutureBuilder<List<Map<String, Object?>>>(
    future: LocalStore.instance.read(
      'tasks',
      where: 'completed=0',
      order: 'dueAt ASC,createdAt DESC',
    ),
    builder: (context, snapshot) {
      final tasks = snapshot.data ?? [];
      final now = DateTime.now();
      final h = now.hour;
      final hello = h < 12
          ? 'Good morning'
          : h < 18
          ? 'Good afternoon'
          : 'Good evening';
      return ListView(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 105),
        children: [
          _DaynixHero(date: now, greeting: hello, onAdd: quickAdd),
          const SizedBox(height: 16),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _HomeNavChip('Today', Icons.wb_sunny_outlined, true, null),
                _HomeNavChip(
                  'Tasks',
                  Icons.checklist_outlined,
                  false,
                  () => navigate(1),
                ),
                _HomeNavChip(
                  'Notes',
                  Icons.sticky_note_2_outlined,
                  false,
                  () => navigate(2),
                ),
                _HomeNavChip(
                  'Planner',
                  Icons.calendar_month_outlined,
                  false,
                  () => navigate(3),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          SectionTitle('Today’s focus', '${tasks.length} open'),
          if (tasks.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 25, horizontal: 18),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                gradient: const LinearGradient(
                  colors: [Color(0xff2b1b2b), Color(0xff211a25)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                border: Border.all(color: const Color(0xff6b3655)),
              ),
              child: Column(
                children: [
                  const Icon(
                    Icons.task_alt_rounded,
                    color: Color(0xffff91bb),
                    size: 47,
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'No tasks yet',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Start with a small step.',
                    style: TextStyle(color: Color(0xffd3b9c8)),
                  ),
                  const SizedBox(height: 13),
                  FilledButton.icon(
                    onPressed: quickAdd,
                    icon: const Icon(Icons.add),
                    label: const Text('Add task'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xffff91bb),
                      foregroundColor: const Color(0xff291420),
                    ),
                  ),
                ],
              ),
            )
          else
            ...tasks.take(6).map((t) => TaskRow(task: t, changed: changed)),
          const SizedBox(height: 18),
          InkWell(
            onTap: () => navigate(2),
            child: SectionTitle('Pinned note', 'Notes  ›'),
          ),
          FutureBuilder<List<Map<String, Object?>>>(
            future: LocalStore.instance.read(
              'notes',
              where: 'pinned=1',
              order: 'updatedAt DESC',
            ),
            builder: (c, s) {
              if (s.data?.isEmpty != false) {
                return InkWell(
                  onTap: () => navigate(2),
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                      border: Border.all(color: const Color(0xff9d5278)),
                    ),
                    child: const Row(
                      children: [
                        Icon(
                          Icons.push_pin_outlined,
                          color: Color(0xffff91bb),
                          size: 32,
                        ),
                        SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Keep an idea close',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                              SizedBox(height: 5),
                              Text('Pin a note and it will appear here.'),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }
              final n = s.data!.first;
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        n['title'] as String,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        (n['body'] as String).isEmpty
                            ? 'No content yet'
                            : n['body'] as String,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 18),
          SectionTitle('Progress', 'All tasks'),
          FutureBuilder<List<Map<String, Object?>>>(
            future: LocalStore.instance.read('tasks'),
            builder: (c, s) {
              final rows = s.data ?? [];
              final done = rows.where((x) => x['completed'] == 1).length;
              final ratio = rows.isEmpty ? 0.0 : done / rows.length;
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 64,
                        height: 64,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            CircularProgressIndicator(
                              value: ratio,
                              strokeWidth: 7,
                              color: const Color(0xffff91bb),
                              backgroundColor: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                            ),
                            Text(
                              '${(ratio * 100).round()}%',
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Today’s progress',
                              style: TextStyle(fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 4),
                            Text('$done of ${rows.length} tasks completed'),
                            const SizedBox(height: 9),
                            LinearProgressIndicator(
                              value: ratio,
                              minHeight: 6,
                              borderRadius: BorderRadius.circular(8),
                              color: const Color(0xffff91bb),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      );
    },
  );
}

class _DaynixHero extends StatelessWidget {
  const _DaynixHero({
    required this.date,
    required this.greeting,
    required this.onAdd,
  });
  final DateTime date;
  final String greeting;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final words = greeting.split(' ');
    return ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: SizedBox(
        height: 248,
        child: _NeonHeroBackground(
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  formatDate(date).toUpperCase(),
                  style: const TextStyle(
                    color: Color(0xffe2c2d3),
                    fontSize: 11,
                    letterSpacing: 3.2,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  words.first,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    height: 1,
                  ),
                ),
                Text(
                  words.length > 1 ? words.last : '',
                  style: const TextStyle(
                    color: Color(0xffff91bb),
                    fontSize: 38,
                    fontWeight: FontWeight.w900,
                    height: 1.1,
                  ),
                ),
                const Spacer(),
                const Text(
                  'Small steps lead to big results.',
                  style: TextStyle(color: Color(0xfff4dfeb), fontSize: 13),
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: onAdd,
                  icon: const Icon(Icons.add, size: 19),
                  label: const Text('Add task'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xffff91bb),
                    foregroundColor: const Color(0xff26121f),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NeonHeroBackground extends StatelessWidget {
  const _NeonHeroBackground({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      Image.asset(
        'assets/daynix_neon_sunset.png',
        fit: BoxFit.cover,
        alignment: Alignment.centerRight,
      ),
      const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xf4141019), Color(0x99141019), Color(0x10141019)],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ),
        ),
      ),
      child,
    ],
  );
}

class _HomeNavChip extends StatelessWidget {
  const _HomeNavChip(this.label, this.icon, this.selected, this.onTap);
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: Material(
      color: selected
          ? const Color(0xffff91bb)
          : Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(
                icon,
                size: 18,
                color: selected ? const Color(0xff291420) : null,
              ),
              const SizedBox(width: 7),
              Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: selected ? const Color(0xff291420) : null,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class TasksPage extends StatefulWidget {
  final Future<void> Function() changed;
  final Future<void> Function() quickAdd;
  const TasksPage({super.key, required this.changed, required this.quickAdd});
  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  String query = '';
  int filter = 0;
  String sort = 'due';
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
        child: _TasksHero(onCreate: widget.quickAdd),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Search tasks',
                  filled: true,
                  border: OutlineInputBorder(
                    borderSide: const BorderSide(color: Color(0xff9d5278)),
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                onChanged: (v) => setState(() => query = v),
              ),
            ),
            const SizedBox(width: 8),
            PopupMenuButton<String>(
              tooltip: 'Sort tasks',
              icon: const Icon(Icons.tune),
              initialValue: sort,
              onSelected: (value) => setState(() => sort = value),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'due', child: Text('Due soon')),
                PopupMenuItem(value: 'recent', child: Text('Recently created')),
                PopupMenuItem(value: 'priority', child: Text('Priority')),
              ],
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            _TasksFilterButton(
              'Open',
              Icons.check,
              filter == 0,
              () => setState(() => filter = 0),
            ),
            const SizedBox(width: 7),
            _TasksFilterButton(
              'Completed',
              Icons.check_circle_outline,
              filter == 1,
              () => setState(() => filter = 1),
            ),
            const SizedBox(width: 7),
            _TasksFilterButton(
              'All',
              Icons.list,
              filter == 2,
              () => setState(() => filter = 2),
            ),
          ],
        ),
      ),
      Expanded(
        child: FutureBuilder<List<Map<String, Object?>>>(
          future: LocalStore.instance.read(
            'tasks',
            where: filter == 2 ? null : 'completed=?',
            args: filter == 2 ? null : [filter == 1 ? 1 : 0],
          ),
          builder: (c, s) {
            final rows = (s.data ?? [])
                .where(
                  (t) => (t['title'] as String).toLowerCase().contains(
                    query.toLowerCase(),
                  ),
                )
                .toList();
            if (sort == 'priority') {
              rows.sort(
                (a, b) =>
                    (b['priority'] as int).compareTo(a['priority'] as int),
              );
            } else if (sort == 'recent') {
              rows.sort(
                (a, b) => (b['createdAt'] as String).compareTo(
                  a['createdAt'] as String,
                ),
              );
            } else {
              rows.sort((a, b) {
                final aDate = a['dueAt'] as String?;
                final bDate = b['dueAt'] as String?;
                if (aDate == null) return bDate == null ? 0 : 1;
                if (bDate == null) return -1;
                return aDate.compareTo(bDate);
              });
            }
            if (rows.isEmpty) {
              return _TasksEmptyState(
                onCreate: widget.quickAdd,
                searching: query.isNotEmpty,
              );
            }
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: rows
                  .map((t) => TaskRow(task: t, changed: widget.changed))
                  .toList(),
            );
          },
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: _TasksQuickCard(onTap: widget.quickAdd),
      ),
    ],
  );
}

class _TasksHero extends StatelessWidget {
  const _TasksHero({required this.onCreate});
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(25),
    child: SizedBox(
      height: 185,
      width: double.infinity,
      child: _NeonHeroBackground(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'T A S K S',
                      style: TextStyle(
                        color: Color(0xffecd3e1),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Stay',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 31,
                        fontWeight: FontWeight.w800,
                        height: 1,
                      ),
                    ),
                    const Text(
                      'Productive',
                      style: TextStyle(
                        color: Color(0xffff91bb),
                        fontSize: 34,
                        fontWeight: FontWeight.w900,
                        height: 1.05,
                      ),
                    ),
                    const Spacer(),
                    const Text(
                      'Big goals start with small tasks.',
                      style: TextStyle(color: Color(0xfff0d4e4), fontSize: 12),
                    ),
                  ],
                ),
              ),
              IconButton.filled(
                onPressed: onCreate,
                tooltip: 'Create task',
                icon: const Icon(Icons.add),
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xffff91bb),
                  foregroundColor: const Color(0xff291420),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _TasksFilterButton extends StatelessWidget {
  const _TasksFilterButton(this.label, this.icon, this.selected, this.onTap);
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Material(
      color: selected
          ? const Color(0xffff91bb)
          : Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(15),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(15),
        child: SizedBox(
          height: 45,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 17,
                color: selected ? const Color(0xff291420) : null,
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: selected ? const Color(0xff291420) : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _TasksEmptyState extends StatelessWidget {
  const _TasksEmptyState({required this.onCreate, required this.searching});
  final VoidCallback onCreate;
  final bool searching;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
      child: Column(
        children: [
          Container(
            width: 122,
            height: 122,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [Color(0xff8f3b64), Color(0xff261824)],
              ),
            ),
            child: const Icon(
              Icons.fact_check_outlined,
              size: 72,
              color: Color(0xffff91bb),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            searching ? 'No matching tasks' : 'Nothing here yet',
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            searching
                ? 'Try a different search.'
                : 'Tasks you add will show up here.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 18),
          if (!searching)
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add),
              label: const Text('Create your first task'),
            ),
        ],
      ),
    ),
  );
}

class _TasksQuickCard extends StatelessWidget {
  const _TasksQuickCard({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    borderRadius: BorderRadius.circular(20),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xffaa4d79)),
        ),
        child: const Row(
          children: [
            Icon(Icons.bolt_outlined, color: Color(0xffff91bb)),
            SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Quick add',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Jot something down quickly',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: Color(0xffff91bb)),
          ],
        ),
      ),
    ),
  );
}

class TaskRow extends StatelessWidget {
  final Map<String, Object?> task;
  final Future<void> Function() changed;
  const TaskRow({super.key, required this.task, required this.changed});
  @override
  Widget build(BuildContext context) {
    final done = task['completed'] == 1;
    final priority = task['priority'] as int? ?? 1;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: .22),
        ),
      ),
      child: ListTile(
        onTap: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          builder: (_) => TaskEditorSheet(onSaved: changed, existing: task),
        ),
        leading: Checkbox(
          value: done,
          onChanged: (_) async {
            await LocalStore.instance.setTaskCompleted(task, !done);
            await changed();
          },
        ),
        title: Text(
          task['title'] as String,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            decoration: done ? TextDecoration.lineThrough : null,
          ),
        ),
        subtitle: task['dueAt'] == null
            ? null
            : Text(formatDate(DateTime.parse(task['dueAt'] as String))),
        trailing: priority >= 2
            ? Icon(
                Icons.flag_rounded,
                size: 19,
                color: priority == 3
                    ? const Color(0xffff6c9e)
                    : const Color(0xffffb078),
              )
            : null,
      ),
    );
  }
}

class NotesPage extends StatefulWidget {
  final Future<void> Function() changed;
  const NotesPage({super.key, required this.changed});
  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {
  String query = '';
  String category = 'All';
  String sort = 'recent';

  void createNote() => edit(
    null,
    initialFolder:
        const {'Personal', 'Work', 'Ideas', 'Lists'}.contains(category)
        ? category
        : null,
    initialPinned: category == 'Pinned',
  );

  Future<void> edit(
    Map<String, Object?>? note, {
    String? initialFolder,
    bool initialPinned = false,
  }) async {
    final title = TextEditingController(
      text: note == null ? '' : note['title'] as String,
    );
    final body = TextEditingController(
      text: note == null ? '' : note['body'] as String,
    );
    final folder = TextEditingController(
      text: note == null
          ? (initialFolder ?? '')
          : (note['folder'] as String? ?? ''),
    );
    final id = note == null
        ? DateTime.now().microsecondsSinceEpoch.toString()
        : note['id'] as String;
    var pinned = note == null ? (initialPinned ? 1 : 0) : note['pinned'] as int;
    var deleted = false;
    final initialPhotos = await LocalStore.instance.db.query(
      'note_photos',
      where: 'noteId=?',
      whereArgs: [id],
      orderBy: 'addedAt,id',
    );
    final photoCount = ValueNotifier<int>(initialPhotos.length);
    Timer? debounce;
    final preview = ValueNotifier(false);
    void save() {
      debounce?.cancel();
      debounce = Timer(const Duration(milliseconds: 400), () async {
        if (deleted ||
            (title.text.trim().isEmpty &&
                body.text.trim().isEmpty &&
                photoCount.value == 0)) {
          return;
        }
        await LocalStore.instance.upsertNote({
          'id': id,
          'title': title.text.trim().isEmpty ? 'Untitled' : title.text.trim(),
          'body': body.text,
          'updatedAt': DateTime.now().toIso8601String(),
          'pinned': pinned,
          'folder': folder.text.trim(),
        });
        await LocalStore.instance.refreshWidgets();
        await widget.changed();
      });
    }

    void applyFormat(String command) {
      body.value = formatNoteText(body.value, command);
      preview.value = false;
      save();
    }

    if (!mounted) {
      title.dispose();
      body.dispose();
      folder.dispose();
      preview.dispose();
      photoCount.dispose();
      return;
    }
    TransitionRoute<void>? noteRoute;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        noteRoute ??= ModalRoute.of<void>(ctx);
        return Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            20,
            20,
            MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Note',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        note != null && note['pinned'] == 1
                            ? Icons.push_pin
                            : Icons.push_pin_outlined,
                      ),
                      onPressed: () async {
                        pinned = pinned == 1 ? 0 : 1;
                        await LocalStore.instance.upsertNote({
                          'id': id,
                          'title': title.text.trim().isEmpty
                              ? 'Untitled'
                              : title.text.trim(),
                          'body': body.text,
                          'updatedAt': DateTime.now().toIso8601String(),
                          'pinned': pinned,
                          'folder': folder.text.trim(),
                        });
                        await LocalStore.instance.refreshWidgets();
                        await widget.changed();
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        deleted = true;
                        final attached = await LocalStore.instance.db.query(
                          'note_photos',
                          where: 'noteId=?',
                          whereArgs: [id],
                        );
                        await LocalStore.instance.db.transaction((txn) async {
                          await txn.delete(
                            'note_photos',
                            where: 'noteId=?',
                            whereArgs: [id],
                          );
                          await txn.delete(
                            'notes',
                            where: 'id=?',
                            whereArgs: [id],
                          );
                        });
                        for (final photo in attached) {
                          try {
                            await taskiyaNative.invokeMethod<void>(
                              'deleteNotePhoto',
                              {'path': photo['path']},
                            );
                          } on PlatformException {
                            // The note remains deleted if file cleanup fails.
                          } on MissingPluginException {
                            // Photo storage is Android-only.
                          }
                        }
                        await LocalStore.instance.refreshWidgets();
                        if (ctx.mounted) Navigator.pop(ctx);
                        await widget.changed();
                      },
                    ),
                  ],
                ),
                TextField(
                  controller: title,
                  autofocus: note == null,
                  decoration: const InputDecoration(
                    hintText: 'Title',
                    border: InputBorder.none,
                  ),
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                  onChanged: (_) => save(),
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      PopupMenuButton<String>(
                        tooltip: 'Text style',
                        onSelected: applyFormat,
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'heading',
                            child: Text('Main heading'),
                          ),
                          PopupMenuItem(
                            value: 'subheading',
                            child: Text('Subheading'),
                          ),
                          PopupMenuItem(value: 'body', child: Text('Body')),
                        ],
                        child: const Padding(
                          padding: EdgeInsets.all(10),
                          child: Text(
                            'H  ▾',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => applyFormat('bold'),
                        tooltip: 'Bold',
                        icon: const Icon(Icons.format_bold),
                      ),
                      IconButton(
                        onPressed: () => applyFormat('italic'),
                        tooltip: 'Italic',
                        icon: const Icon(Icons.format_italic),
                      ),
                      IconButton(
                        onPressed: () => applyFormat('strike'),
                        tooltip: 'Strikethrough',
                        icon: const Icon(Icons.format_strikethrough),
                      ),
                      IconButton(
                        onPressed: () => applyFormat('bullet'),
                        tooltip: 'Bullet list',
                        icon: const Icon(Icons.format_list_bulleted),
                      ),
                      IconButton(
                        onPressed: () => applyFormat('numbered'),
                        tooltip: 'Numbered list',
                        icon: const Icon(Icons.format_list_numbered),
                      ),
                      IconButton(
                        onPressed: () => applyFormat('table'),
                        tooltip: 'Table',
                        icon: const Icon(Icons.table_chart_outlined),
                      ),
                      PopupMenuButton<String>(
                        tooltip: 'Text size',
                        onSelected: applyFormat,
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'size14',
                            child: Text('Small · 14'),
                          ),
                          PopupMenuItem(
                            value: 'size18',
                            child: Text('Medium · 18'),
                          ),
                          PopupMenuItem(
                            value: 'size24',
                            child: Text('Large · 24'),
                          ),
                        ],
                        child: const Padding(
                          padding: EdgeInsets.all(10),
                          child: Text(
                            'Aa',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => preview.value = !preview.value,
                        tooltip: 'Toggle formatted preview',
                        icon: const Icon(Icons.visibility_outlined),
                      ),
                    ],
                  ),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: preview,
                  builder: (context, showingPreview, _) => showingPreview
                      ? SizedBox(
                          height: 260,
                          width: double.infinity,
                          child: SingleChildScrollView(
                            child: NoteMarkupPreview(body.text),
                          ),
                        )
                      : TextField(
                          controller: body,
                          minLines: 7,
                          maxLines: 12,
                          decoration: const InputDecoration(
                            hintText: 'Start writing…',
                            border: InputBorder.none,
                          ),
                          onChanged: (_) => save(),
                        ),
                ),
                NotePhotoStrip(
                  database: LocalStore.instance.db,
                  noteId: id,
                  initialPhotos: initialPhotos,
                  photoCount: photoCount,
                  beforeAdd: () async {
                    debounce?.cancel();
                    await LocalStore.instance.upsertNote({
                      'id': id,
                      'title': title.text.trim().isEmpty
                          ? 'Untitled'
                          : title.text.trim(),
                      'body': body.text,
                      'updatedAt': DateTime.now().toIso8601String(),
                      'pinned': pinned,
                      'folder': folder.text.trim(),
                    });
                  },
                  onChanged: () async {
                    await LocalStore.instance.refreshWidgets();
                    await widget.changed();
                  },
                ),
                TextField(
                  controller: folder,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.folder_outlined),
                    hintText: 'Folder (optional)',
                  ),
                  onChanged: (_) => save(),
                ),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Changes save automatically',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (noteRoute != null) await noteRoute!.completed;
    debounce?.cancel();
    if (!deleted &&
        (title.text.trim().isNotEmpty ||
            body.text.trim().isNotEmpty ||
            photoCount.value > 0)) {
      await LocalStore.instance.upsertNote({
        'id': id,
        'title': title.text.trim().isEmpty ? 'Untitled' : title.text.trim(),
        'body': body.text,
        'updatedAt': DateTime.now().toIso8601String(),
        'pinned': pinned,
        'folder': folder.text.trim(),
      });
      await LocalStore.instance.refreshWidgets();
      await widget.changed();
    }
    title.dispose();
    body.dispose();
    folder.dispose();
    preview.dispose();
    photoCount.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: _NotesHero(onCreate: createNote),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: 'Search notes',
                    filled: true,
                    border: OutlineInputBorder(
                      borderSide: const BorderSide(color: Color(0xff9d5278)),
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  onChanged: (v) => setState(() => query = v),
                ),
              ),
              const SizedBox(width: 8),
              PopupMenuButton<String>(
                tooltip: 'Sort notes',
                icon: const Icon(Icons.tune),
                initialValue: sort,
                onSelected: (value) => setState(() => sort = value),
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'recent',
                    child: Text('Recently edited'),
                  ),
                  PopupMenuItem(value: 'oldest', child: Text('Oldest first')),
                  PopupMenuItem(value: 'title', child: Text('Title A–Z')),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 112,
                child: ListView(
                  padding: const EdgeInsets.only(left: 8, bottom: 110),
                  children: [
                    for (final entry in const [
                      ('All', Icons.notes_rounded),
                      ('Personal', Icons.person_outline),
                      ('Work', Icons.work_outline),
                      ('Ideas', Icons.lightbulb_outline),
                      ('Lists', Icons.format_list_bulleted),
                      ('Pinned', Icons.push_pin_outlined),
                    ])
                      _NotesCategoryButton(
                        label: entry.$1,
                        icon: entry.$2,
                        selected: category == entry.$1,
                        onTap: () => setState(() => category = entry.$1),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: FutureBuilder<List<Map<String, Object?>>>(
                  future: LocalStore.instance.db.rawQuery(
                    'SELECT notes.*, (SELECT path FROM note_photos WHERE noteId=notes.id ORDER BY addedAt,id LIMIT 1) AS coverPhoto FROM notes ORDER BY pinned DESC,updatedAt DESC',
                  ),
                  builder: (context, snapshot) {
                    final notes = (snapshot.data ?? [])
                        .where(
                          (n) =>
                              '${n['title']} ${n['body']}'
                                  .toLowerCase()
                                  .contains(query.toLowerCase()) &&
                              (category == 'All' ||
                                  (category == 'Pinned' && n['pinned'] == 1) ||
                                  (n['folder'] as String? ?? '')
                                          .toLowerCase() ==
                                      category.toLowerCase()),
                        )
                        .toList();
                    if (sort == 'title') {
                      notes.sort(
                        (a, b) => (a['title'] as String)
                            .toLowerCase()
                            .compareTo((b['title'] as String).toLowerCase()),
                      );
                    } else if (sort == 'oldest') {
                      notes.sort(
                        (a, b) => (a['updatedAt'] as String).compareTo(
                          b['updatedAt'] as String,
                        ),
                      );
                    }
                    if (notes.isEmpty) {
                      return _NotesEmptyState(
                        onCreate: createNote,
                        searching: query.isNotEmpty,
                        category: category,
                      );
                    }
                    return GridView.builder(
                      padding: const EdgeInsets.fromLTRB(8, 0, 16, 105),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 1,
                            childAspectRatio: 1.8,
                            mainAxisSpacing: 10,
                          ),
                      itemCount: notes.length,
                      itemBuilder: (context, index) {
                        final note = notes[index];
                        return InkWell(
                          onTap: () => edit(note),
                          borderRadius: BorderRadius.circular(20),
                          child: Card(
                            child: Padding(
                              padding: const EdgeInsets.all(15),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          note['title'] as String,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                      if (note['pinned'] == 1)
                                        const Icon(Icons.push_pin, size: 16),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Expanded(
                                    child: Row(
                                      children: [
                                        if (note['coverPhoto'] is String)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              right: 10,
                                            ),
                                            child: ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(10),
                                              child: Image.file(
                                                File(
                                                  note['coverPhoto'] as String,
                                                ),
                                                width: 52,
                                                height: 52,
                                                fit: BoxFit.cover,
                                                cacheWidth: 156,
                                                errorBuilder: (_, _, _) =>
                                                    const SizedBox(
                                                      width: 52,
                                                      height: 52,
                                                      child: Icon(
                                                        Icons
                                                            .broken_image_outlined,
                                                      ),
                                                    ),
                                              ),
                                            ),
                                          ),
                                        Expanded(
                                          child: Text(
                                            (note['body'] as String).isEmpty
                                                ? 'Start writing…'
                                                : plainNotePreview(
                                                    note['body'] as String,
                                                  ),
                                            maxLines: 7,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: _NotesQuickCard(onTap: createNote),
        ),
      ],
    );
  }
}

class _NotesHero extends StatelessWidget {
  const _NotesHero({required this.onCreate});
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(25),
    child: SizedBox(
      height: 185,
      width: double.infinity,
      child: _NeonHeroBackground(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'N O T E S',
                      style: TextStyle(
                        color: Color(0xffecd3e1),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Your',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 31,
                        fontWeight: FontWeight.w800,
                        height: 1,
                      ),
                    ),
                    const Text(
                      'thoughts',
                      style: TextStyle(
                        color: Color(0xffff91bb),
                        fontSize: 35,
                        fontWeight: FontWeight.w900,
                        height: 1.05,
                      ),
                    ),
                    const Spacer(),
                    const Text(
                      'Capture ideas, anytime, anywhere.',
                      style: TextStyle(color: Color(0xfff0d4e4), fontSize: 12),
                    ),
                  ],
                ),
              ),
              IconButton.filled(
                onPressed: onCreate,
                tooltip: 'Create note',
                icon: const Icon(Icons.add),
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xffff91bb),
                  foregroundColor: const Color(0xff291420),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _NotesCategoryButton extends StatelessWidget {
  const _NotesCategoryButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Material(
      color: selected ? const Color(0xffaa3d71) : Colors.transparent,
      borderRadius: const BorderRadius.horizontal(left: Radius.circular(15)),
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.horizontal(left: Radius.circular(15)),
        child: SizedBox(
          height: 49,
          child: Row(
            children: [
              const SizedBox(width: 9),
              Icon(
                icon,
                size: 19,
                color: selected
                    ? Colors.white
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                    color: selected ? Colors.white : null,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _NotesEmptyState extends StatelessWidget {
  const _NotesEmptyState({
    required this.onCreate,
    required this.searching,
    required this.category,
  });
  final VoidCallback onCreate;
  final bool searching;
  final String category;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(8, 18, 16, 105),
      child: Column(
        children: [
          Container(
            width: 115,
            height: 115,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [Color(0xff8f3b64), Color(0xff261824)],
              ),
            ),
            child: const Icon(
              Icons.edit_note_rounded,
              size: 72,
              color: Color(0xffff91bb),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            searching
                ? 'No matching notes'
                : category == 'All'
                ? 'A space for your thoughts'
                : 'No $category notes yet',
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
          ),
          const SizedBox(height: 7),
          Text(
            searching
                ? 'Try a different search.'
                : 'Capture ideas, lists, and everything in between.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 18),
          if (!searching)
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.note_add_outlined),
              label: const Text('Create note'),
            ),
        ],
      ),
    ),
  );
}

class _NotesQuickCard extends StatelessWidget {
  const _NotesQuickCard({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    borderRadius: BorderRadius.circular(20),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xffaa4d79)),
        ),
        child: const Row(
          children: [
            Icon(Icons.note_alt_outlined, color: Color(0xffff91bb)),
            SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Quick note',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Jot something down quickly',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: Color(0xffff91bb)),
          ],
        ),
      ),
    ),
  );
}

class PlannerPage extends StatefulWidget {
  final Future<void> Function() changed;
  final Future<void> Function(DateTime) quickAdd;
  const PlannerPage({super.key, required this.changed, required this.quickAdd});
  @override
  State<PlannerPage> createState() => _PlannerPageState();
}

class _PlannerPageState extends State<PlannerPage> {
  DateTime selectedDay = DateUtils.dateOnly(DateTime.now());
  int scope = 0;

  void createTask() => widget.quickAdd(selectedDay);

  void shift(int direction) => setState(() {
    selectedDay = scope == 2
        ? DateTime(selectedDay.year, selectedDay.month + direction)
        : selectedDay.add(Duration(days: direction * 7));
  });

  Future<void> chooseDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: selectedDay,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) {
      setState(() {
        selectedDay = DateUtils.dateOnly(picked);
        scope = 0;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final weekStart = selectedDay.subtract(
      Duration(days: selectedDay.weekday - 1),
    );
    final rangeStart = switch (scope) {
      1 => weekStart,
      2 => DateTime(selectedDay.year, selectedDay.month),
      _ => selectedDay,
    };
    final rangeEnd = switch (scope) {
      1 => rangeStart.add(const Duration(days: 7)),
      2 => DateTime(selectedDay.year, selectedDay.month + 1),
      _ => rangeStart.add(const Duration(days: 1)),
    };
    final stripStart = scope == 1 ? weekStart : selectedDay;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: _PlannerHero(onCreate: () => widget.quickAdd(selectedDay)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 13, 16, 0),
          child: Row(
            children: [
              _PlannerScopeButton(
                'Today',
                Icons.today_outlined,
                scope == 0,
                () => setState(() {
                  scope = 0;
                  selectedDay = DateUtils.dateOnly(DateTime.now());
                }),
              ),
              _PlannerScopeButton(
                'This week',
                Icons.view_week_outlined,
                scope == 1,
                () => setState(() => scope = 1),
              ),
              _PlannerScopeButton(
                'This month',
                Icons.calendar_month_outlined,
                scope == 2,
                () => setState(() => scope = 2),
              ),
              _PlannerScopeButton(
                'All',
                Icons.apps_outlined,
                scope == 3,
                () => setState(() => scope = 3),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 5),
          child: Row(
            children: [
              Text(
                '${['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][selectedDay.month - 1]} ${selectedDay.year}',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              IconButton(
                onPressed: () => shift(-1),
                tooltip: 'Previous dates',
                icon: const Icon(Icons.chevron_left),
              ),
              IconButton(
                onPressed: chooseDate,
                tooltip: 'Pick date',
                icon: const Icon(Icons.calendar_today_outlined),
              ),
              IconButton(
                onPressed: () => shift(1),
                tooltip: 'Next dates',
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 73,
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            scrollDirection: Axis.horizontal,
            itemCount: 7,
            itemBuilder: (context, index) {
              final day = stripStart.add(Duration(days: index));
              return _PlannerDayButton(
                date: day,
                selected: DateUtils.isSameDay(day, selectedDay),
                onTap: () => setState(() {
                  selectedDay = day;
                  scope = 0;
                }),
              );
            },
          ),
        ),
        Expanded(
          child: FutureBuilder<List<Map<String, Object?>>>(
            future: LocalStore.instance.read(
              'tasks',
              where: 'dueAt IS NOT NULL AND completed=0',
              order: 'dueAt ASC',
            ),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting &&
                  !snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return const Center(
                  child: Text('Could not load your schedule.'),
                );
              }
              final all = snapshot.data ?? [];
              final tasks = all.where((task) {
                final date = DateTime.tryParse(task['dueAt'] as String? ?? '');
                return date != null &&
                    (scope == 3 ||
                        (!date.isBefore(rangeStart) &&
                            date.isBefore(rangeEnd)));
              }).toList();
              final scheduledDays = all
                  .map(
                    (task) => DateTime.tryParse(task['dueAt'] as String? ?? ''),
                  )
                  .whereType<DateTime>()
                  .map(DateUtils.dateOnly)
                  .toSet();
              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 5, 16, 16),
                children: [
                  if (scope == 2)
                    _PlannerMonthGrid(
                      month: selectedDay,
                      selected: selectedDay,
                      scheduledDays: scheduledDays,
                      onSelect: (day) => setState(() {
                        selectedDay = day;
                        scope = 0;
                      }),
                    ),
                  if (tasks.isEmpty)
                    _PlannerEmptyState(
                      onCreate: () => widget.quickAdd(selectedDay),
                    )
                  else
                    for (final task in tasks)
                      TaskRow(task: task, changed: widget.changed),
                ],
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: _PlannerQuickCard(onTap: () => widget.quickAdd(selectedDay)),
        ),
      ],
    );
  }
}

class _PlannerHero extends StatelessWidget {
  const _PlannerHero({required this.onCreate});
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(25),
    child: SizedBox(
      height: 185,
      width: double.infinity,
      child: _NeonHeroBackground(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'P L A N N E R',
                      style: TextStyle(
                        color: Color(0xffecd3e1),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Your',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 31,
                        fontWeight: FontWeight.w800,
                        height: 1,
                      ),
                    ),
                    const Text(
                      'planner',
                      style: TextStyle(
                        color: Color(0xffff91bb),
                        fontSize: 35,
                        fontWeight: FontWeight.w900,
                        height: 1.05,
                      ),
                    ),
                    const Spacer(),
                    const Text(
                      'Plan today for a better tomorrow.',
                      style: TextStyle(color: Color(0xfff0d4e4), fontSize: 12),
                    ),
                  ],
                ),
              ),
              IconButton.filled(
                onPressed: onCreate,
                tooltip: 'Add scheduled task',
                icon: const Icon(Icons.add),
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xffff91bb),
                  foregroundColor: const Color(0xff291420),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _PlannerScopeButton extends StatelessWidget {
  const _PlannerScopeButton(this.label, this.icon, this.selected, this.onTap);
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Padding(
      padding: const EdgeInsets.only(right: 5),
      child: Material(
        color: selected
            ? const Color(0xffff91bb)
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            height: 46,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 15,
                  color: selected ? const Color(0xff291420) : null,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: selected ? const Color(0xff291420) : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _PlannerDayButton extends StatelessWidget {
  const _PlannerDayButton({
    required this.date,
    required this.selected,
    required this.onTap,
  });
  final DateTime date;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 6),
    child: Material(
      color: selected
          ? const Color(0xffff91bb)
          : Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          width: 46,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${date.day}',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: selected ? const Color(0xff291420) : null,
                ),
              ),
              Text(
                ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][date.weekday -
                    1],
                style: TextStyle(
                  fontSize: 10,
                  color: selected ? const Color(0xff291420) : null,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _PlannerMonthGrid extends StatelessWidget {
  const _PlannerMonthGrid({
    required this.month,
    required this.selected,
    required this.scheduledDays,
    required this.onSelect,
  });
  final DateTime month;
  final DateTime selected;
  final Set<DateTime> scheduledDays;
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    final first = DateTime(month.year, month.month);
    final offset = first.weekday - 1;
    final days = DateTime(month.year, month.month + 1, 0).day;
    final cells = ((offset + days + 6) ~/ 7) * 7;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xff824264)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              for (final label in const ['M', 'T', 'W', 'T', 'F', 'S', 'S'])
                Expanded(
                  child: Center(
                    child: Text(
                      label,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: cells,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              childAspectRatio: 1.15,
            ),
            itemBuilder: (context, index) {
              final day = DateTime(month.year, month.month, index - offset + 1);
              final inMonth = day.month == month.month;
              final active = DateUtils.isSameDay(day, selected);
              return InkWell(
                onTap: () => onSelect(day),
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  margin: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: active ? const Color(0xffff91bb) : null,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '${day.day}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: active
                              ? FontWeight.w800
                              : FontWeight.w500,
                          color: active
                              ? const Color(0xff291420)
                              : inMonth
                              ? null
                              : Theme.of(context).colorScheme.onSurfaceVariant
                                    .withValues(alpha: .55),
                        ),
                      ),
                      if (scheduledDays.contains(DateUtils.dateOnly(day)))
                        Container(
                          width: 4,
                          height: 4,
                          decoration: const BoxDecoration(
                            color: Color(0xffff91bb),
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _PlannerEmptyState extends StatelessWidget {
  const _PlannerEmptyState({required this.onCreate});
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 15),
    child: Column(
      children: [
        Container(
          width: 115,
          height: 115,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [Color(0xff8f3b64), Color(0xff261824)],
            ),
          ),
          child: const Icon(
            Icons.calendar_month_outlined,
            size: 66,
            color: Color(0xffff91bb),
          ),
        ),
        const SizedBox(height: 15),
        const Text(
          'Your schedule is open',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
        ),
        const SizedBox(height: 5),
        Text(
          'Set due dates on tasks to plan ahead.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 15),
        FilledButton.icon(
          onPressed: onCreate,
          icon: const Icon(Icons.add),
          label: const Text('Add scheduled task'),
        ),
      ],
    ),
  );
}

class _PlannerQuickCard extends StatelessWidget {
  const _PlannerQuickCard({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    borderRadius: BorderRadius.circular(20),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xffaa4d79)),
        ),
        child: const Row(
          children: [
            Icon(Icons.calendar_today_outlined, color: Color(0xffff91bb)),
            SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Quick add',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Plan something quickly',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: Color(0xffff91bb)),
          ],
        ),
      ),
    ),
  );
}

class MorePage extends StatelessWidget {
  final Future<void> Function() changed;
  const MorePage({super.key, required this.changed});
  Future<void> clear(BuildContext context) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear progress?'),
        content: const Text(
          'Completed tasks become open again. Recurring completion history and habit check-ins are cleared. Notes and task details remain.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear progress'),
          ),
        ],
      ),
    );
    if (approved != true) return;
    await LocalStore.instance.clearProgress();
    await changed();
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Progress cleared')));
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(18, 10, 18, 100),
    children: [
      _NeonSectionHero(
        eyebrow: 'MORE',
        first: 'Your',
        second: 'workspace',
        quote: 'All the tools you need, in one place.',
      ),
      const SizedBox(height: 18),
      const _MoreSectionTitle(
        Icons.grid_view_rounded,
        'Daily productivity',
        'Build better days, one step at a time.',
        '6 tools',
      ),
      const SizedBox(height: 10),
      GridView.count(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisCount: 2,
        childAspectRatio: 1.18,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        children: [
          MoreTile(
            icon: Icons.repeat,
            title: 'Habits',
            subtitle: 'Build consistency one day at a time',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => HabitPage(changed: changed)),
            ),
          ),
          MoreTile(
            icon: Icons.timer_outlined,
            title: 'Focus timer',
            subtitle: 'Set aside time for focused work',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const FocusPage()),
            ),
          ),
          MoreTile(
            icon: Icons.lightbulb_outline,
            title: 'Brain dump',
            subtitle: 'Capture thoughts before they drift away',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const DumpPage()),
            ),
          ),
          MoreTile(
            icon: Icons.insights_outlined,
            title: 'Insights',
            subtitle: 'A snapshot from your local task list',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const InsightPage()),
            ),
          ),
          MoreTile(
            icon: Icons.alarm,
            title: 'Alarms',
            subtitle: 'Schedule, repeat and snooze task alarms',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AlarmsPage()),
            ),
          ),
          MoreTile(
            icon: Icons.auto_awesome_outlined,
            title: 'AI task chat',
            subtitle: 'Plan and manage your DAYNIX tasks with Gemini',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AiChatPage()),
            ),
          ),
        ],
      ),
      const SizedBox(height: 24),
      const _MoreSectionTitle(
        Icons.palette_outlined,
        'Customization',
        'Make DAYNIX look and feel like yours.',
        '3 tools',
      ),
      const SizedBox(height: 10),
      MoreTile(
        icon: Icons.widgets_outlined,
        title: 'Widget studio',
        subtitle: 'Task and note widgets · pastel themes',
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const TaskiyaSettingsPage()),
        ),
      ),
      MoreTile(
        icon: Icons.face_retouching_natural,
        title: 'Pet assistant',
        subtitle: 'NIYA or your photo, reminders, and privacy',
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const NiyaSettingsPage()),
        ),
      ),
      MoreTile(
        icon: Icons.settings_outlined,
        title: 'Appearance',
        subtitle: 'Light and dark modes for DAYNIX',
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const TaskiyaSettingsPage()),
        ),
      ),
      const SizedBox(height: 20),
      const _MoreSectionTitle(
        Icons.shield_outlined,
        'System',
        'Keep things running smoothly.',
        '2 tools',
      ),
      const SizedBox(height: 10),
      MoreTile(
        icon: Icons.shield_outlined,
        title: 'App permissions',
        subtitle: 'Overlay, notifications and precise reminders',
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const PermissionsPage()),
        ),
      ),
      MoreTile(
        icon: Icons.lock_outline,
        title: 'Security & sign-in',
        subtitle: 'Phone app lock and account settings',
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const AppSecurityPage()),
        ),
      ),
      MoreTile(
        icon: Icons.restart_alt,
        title: 'Clear progress',
        subtitle: 'Reset task completions and habit check-ins',
        onTap: () => clear(context),
      ),
    ],
  );
}

class AlarmsPage extends StatefulWidget {
  const AlarmsPage({super.key});
  @override
  State<AlarmsPage> createState() => _AlarmsPageState();
}

class _AlarmsPageState extends State<AlarmsPage> {
  Future<void> editAlarm([Map<String, Object?>? task]) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => TaskEditorSheet(
        onSaved: () async {
          if (mounted) setState(() {});
        },
        existing: task,
        initialDate: DateTime.now(),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> chooseRingtone() async {
    try {
      await taskiyaNative.invokeMethod<String>('pickRingtone');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ringtone saved for DAYNIX alarms.')),
        );
      }
    } on PlatformException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Ringtone picker is unavailable on this device.'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Alarms')),
    body: ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const _NeonSectionHero(
          eyebrow: 'DAYNIX ALARMS',
          first: 'Wake up',
          second: 'and do',
          quote: 'A ringtone for the tasks that matter.',
        ),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: () => editAlarm(),
          icon: const Icon(Icons.alarm_add),
          label: const Text('Add task alarm'),
        ),
        TextButton.icon(
          onPressed: chooseRingtone,
          icon: const Icon(Icons.music_note_outlined),
          label: const Text('Choose alarm ringtone'),
        ),
        const SizedBox(height: 16),
        const Text(
          'Scheduled alarms',
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        FutureBuilder<List<Map<String, Object?>>>(
          future: LocalStore.instance.read(
            'tasks',
            where: "dueAt LIKE '%T%' AND reminderEnabled=1 AND completed=0",
            order: 'dueAt ASC',
          ),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            final alarms = snapshot.data ?? [];
            if (alarms.isEmpty) {
              return const Card(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No alarms yet. Add a task with a date, time and reminder.',
                  ),
                ),
              );
            }
            return Column(
              children: alarms.map((task) {
                final due = DateTime.tryParse(task['dueAt'] as String? ?? '');
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.alarm, color: Color(0xffff91bb)),
                    title: Text(task['title'] as String),
                    subtitle: Text(
                      due == null
                          ? 'Invalid date'
                          : '${TimeOfDay.fromDateTime(due).format(context)} · ${formatDate(due)} · ${task['recurrence'] == 'none' ? 'Once' : task['recurrence']}',
                    ),
                    trailing: const Icon(Icons.edit_outlined),
                    onTap: () => editAlarm(task),
                  ),
                );
              }).toList(),
            );
          },
        ),
        const SizedBox(height: 14),
        const Text(
          'When an alarm rings, use Snooze, Dismiss or Done on the alarm screen or notification. Exact delivery and lock-screen presentation depend on Android permissions.',
          style: TextStyle(fontSize: 12),
        ),
      ],
    ),
  );
}

class MoreTile extends StatelessWidget {
  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;
  const MoreTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainerHigh
        .withValues(alpha: .85),
    borderRadius: BorderRadius.circular(22),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(22),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border.all(
            color: const Color(0xffff72aa).withValues(alpha: .35),
          ),
          borderRadius: BorderRadius.circular(22),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: const Color(0xffff91bb), size: 27),
            const SizedBox(height: 10),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            const SizedBox(height: 3),
            Text(
              subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _MoreSectionTitle extends StatelessWidget {
  const _MoreSectionTitle(this.icon, this.title, this.subtitle, this.count);
  final IconData icon;
  final String title, subtitle, count;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, color: const Color(0xffff91bb), size: 27),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
            ),
            Text(
              subtitle,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
      Text(
        count,
        style: const TextStyle(color: Color(0xffff91bb), fontSize: 12),
      ),
    ],
  );
}

class _NeonSectionHero extends StatelessWidget {
  const _NeonSectionHero({
    required this.eyebrow,
    required this.first,
    required this.second,
    required this.quote,
  });
  final String eyebrow, first, second, quote;
  @override
  Widget build(BuildContext context) => Container(
    height: 250,
    padding: const EdgeInsets.all(23),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(27),
      image: const DecorationImage(
        image: AssetImage('assets/daynix_neon_sunset.png'),
        fit: BoxFit.cover,
        alignment: Alignment.centerRight,
      ),
      gradient: const LinearGradient(
        colors: [Color(0xff100c15), Color(0xff4f1631)],
      ),
    ),
    child: Stack(
      children: [
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Color(0xf5110b14),
                  Color(0x55110b14),
                  Color(0x00110b14),
                ],
              ),
            ),
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              eyebrow,
              style: const TextStyle(
                color: Color(0xffff91bb),
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 4,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              first,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 38,
                fontWeight: FontWeight.w900,
                height: 1,
              ),
            ),
            Text(
              second,
              style: const TextStyle(
                color: Color(0xffff91bb),
                fontSize: 38,
                fontWeight: FontWeight.w900,
                height: 1.05,
              ),
            ),
            const SizedBox(height: 15),
            Container(width: 42, height: 3, color: const Color(0xffff91bb)),
            const Spacer(),
            Text(
              quote,
              style: const TextStyle(color: Color(0xffe8dce5), fontSize: 13),
            ),
          ],
        ),
      ],
    ),
  );
}

class PermissionsPage extends StatefulWidget {
  const PermissionsPage({super.key});
  @override
  State<PermissionsPage> createState() => _PermissionsPageState();
}

class _PermissionsPageState extends State<PermissionsPage>
    with WidgetsBindingObserver {
  Map<String, dynamic> status = {};
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) load();
  }

  Future<void> load() async {
    try {
      final value = await taskiyaNative.invokeMethod<Map>('getStatus');
      if (mounted) {
        setState(() => status = Map<String, dynamic>.from(value ?? {}));
      }
    } on PlatformException {
      if (mounted) setState(() => status = {});
    }
  }

  Future<void> action(String method) async {
    try {
      await taskiyaNative.invokeMethod(method);
    } on PlatformException {
      // Device settings may be unavailable on older Android versions.
    }
    await load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('App permissions')),
    body: ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const Text(
          'DAYNIX uses these Android permissions for NIYA and reminders. Tap a row to review or grant access.',
        ),
        const SizedBox(height: 16),
        ListTile(
          leading: const Icon(Icons.picture_in_picture_alt_outlined),
          title: const Text('Display over other apps'),
          subtitle: Text(
            status['overlay'] == true ? 'Allowed' : 'Needed for floating NIYA',
          ),
          trailing: const Icon(Icons.open_in_new),
          onTap: () => action('requestOverlay'),
        ),
        ListTile(
          leading: const Icon(Icons.notifications_outlined),
          title: const Text('Notifications'),
          subtitle: Text(
            status['notifications'] == true
                ? 'Allowed'
                : 'Needed for task alarm notifications',
          ),
          trailing: const Icon(Icons.open_in_new),
          onTap: () => action('requestNotifications'),
        ),
        ListTile(
          leading: const Icon(Icons.alarm),
          title: const Text('Precise alarms'),
          subtitle: Text(
            status['exactAlarms'] == true
                ? 'Available'
                : 'Reminders may arrive late',
          ),
          trailing: const Icon(Icons.open_in_new),
          onTap: () => action('requestExactAlarms'),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: () => action('openAppPermissions'),
          icon: const Icon(Icons.settings_outlined),
          label: const Text('Open Android app settings'),
        ),
        const SizedBox(height: 12),
        const Text(
          'Android lock-screen notification settings and battery restrictions are controlled by your phone.',
        ),
      ],
    ),
  );
}

String habitDayKey(DateTime day) =>
    DateUtils.dateOnly(day).toIso8601String().substring(0, 10);

int habitStreak(Set<String> completedDays, DateTime today) {
  var day = DateUtils.dateOnly(today);
  if (!completedDays.contains(habitDayKey(day))) {
    day = day.subtract(const Duration(days: 1));
  }
  var count = 0;
  while (completedDays.contains(habitDayKey(day))) {
    count++;
    day = day.subtract(const Duration(days: 1));
  }
  return count;
}

class HabitPage extends StatefulWidget {
  final Future<void> Function() changed;
  const HabitPage({super.key, required this.changed});
  @override
  State<HabitPage> createState() => _HabitPageState();
}

class _HabitPageState extends State<HabitPage> {
  DateTime selectedDay = DateUtils.dateOnly(DateTime.now());
  DateTime stripStart = DateUtils.dateOnly(DateTime.now());

  Future<
    ({List<Map<String, Object?>> habits, List<Map<String, Object?>> entries})
  >
  load() async {
    final habits = await LocalStore.instance.read('habits', order: 'title');
    final entries = await LocalStore.instance.read('habit_entries');
    return (habits: habits, entries: entries);
  }

  Future<void> add({String? preset}) async {
    final c = TextEditingController(text: preset ?? '');
    final v =
        preset ??
        await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('New habit'),
            content: TextField(
              controller: c,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(hintText: 'e.g. Read 10 pages'),
              onSubmitted: (value) => Navigator.pop(ctx, value),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, c.text),
                child: const Text('Create'),
              ),
            ],
          ),
        );
    c.dispose();
    if (v == null || v.trim().isEmpty || !mounted) return;
    final existing = await LocalStore.instance.read('habits');
    if (existing.any(
      (habit) =>
          (habit['title'] as String).toLowerCase() == v.trim().toLowerCase(),
    )) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That habit already exists.')),
        );
      }
      return;
    }
    await LocalStore.instance.db.insert('habits', {
      'id': DateTime.now().microsecondsSinceEpoch.toString(),
      'title': v.trim(),
    });
    await LocalStore.instance.refreshWidgets();
    await widget.changed();
    if (mounted) setState(() {});
  }

  Future<void> toggle(Map<String, Object?> habit, bool done) async {
    final id = habit['id'] as String;
    final day = habitDayKey(selectedDay);
    await LocalStore.instance.db.transaction((txn) async {
      if (done) {
        await txn.delete(
          'habit_entries',
          where: 'habitId=? AND day=?',
          whereArgs: [id, day],
        );
      } else {
        await txn.insert('habit_entries', {
          'habitId': id,
          'day': day,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      if (day == habitDayKey(DateTime.now()) ||
          (done && habit['doneDay'] == day)) {
        await txn.update(
          'habits',
          {'doneDay': done ? null : day},
          where: 'id=?',
          whereArgs: [id],
        );
      }
    });
    await LocalStore.instance.refreshWidgets();
    await widget.changed();
    if (mounted) setState(() {});
  }

  Future<void> manage(Map<String, Object?> habit) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Rename habit'),
              onTap: () => Navigator.pop(context, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete habit'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'rename') {
      final input = TextEditingController(text: habit['title'] as String);
      final name = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Rename habit'),
          content: TextField(
            controller: input,
            autofocus: true,
            onSubmitted: (value) => Navigator.pop(ctx, value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, input.text),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      input.dispose();
      if (name != null && name.trim().isNotEmpty) {
        await LocalStore.instance.db.update(
          'habits',
          {'title': name.trim()},
          where: 'id=?',
          whereArgs: [habit['id']],
        );
      }
    } else if (action == 'delete') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Delete habit?'),
          content: const Text(
            'This removes the habit and its check-in history.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (confirmed == true) {
        await LocalStore.instance.db.transaction((txn) async {
          await txn.delete(
            'habit_entries',
            where: 'habitId=?',
            whereArgs: [habit['id']],
          );
          await txn.delete('habits', where: 'id=?', whereArgs: [habit['id']]);
        });
      }
    }
    await LocalStore.instance.refreshWidgets();
    await widget.changed();
    if (mounted) setState(() {});
  }

  void shiftWeek(int direction) => setState(() {
    stripStart = stripStart.add(Duration(days: direction * 7));
    selectedDay = stripStart;
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    extendBodyBehindAppBar: true,
    appBar: AppBar(
      title: const Text('Habits'),
      backgroundColor: Colors.transparent,
      foregroundColor: Colors.white,
      systemOverlayStyle: SystemUiOverlayStyle.light,
      actions: [
        IconButton(
          tooltip: 'View insights',
          icon: const Icon(Icons.bar_chart_rounded),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const InsightPage()),
          ),
        ),
      ],
    ),
    floatingActionButton: FloatingActionButton(
      onPressed: () => add(),
      backgroundColor: const Color(0xffff91bb),
      foregroundColor: const Color(0xff291420),
      tooltip: 'Create habit',
      child: const Icon(Icons.add),
    ),
    body: Stack(
      fit: StackFit.expand,
      children: [
        Image.asset(
          'assets/daynix_neon_sunset.png',
          fit: BoxFit.cover,
          alignment: Alignment.centerRight,
        ),
        const ColoredBox(color: Color(0xb8120b17)),
        SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 68, 18, 110),
            children: [
              const Text(
                'H A B I T S',
                style: TextStyle(
                  color: Color(0xffff91bb),
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Small',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 39,
                  fontWeight: FontWeight.w900,
                  height: 1,
                ),
              ),
              const Text(
                'steps',
                style: TextStyle(
                  color: Color(0xffff91bb),
                  fontSize: 43,
                  fontWeight: FontWeight.w900,
                  height: 1.05,
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'A better you is built daily.',
                style: TextStyle(color: Color(0xfff5ddeb), fontSize: 14),
              ),
              const SizedBox(height: 36),
              Row(
                children: [
                  Text(
                    formatDate(selectedDay),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => shiftWeek(-1),
                    tooltip: 'Previous week',
                    color: Colors.white,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  IconButton(
                    onPressed: () => shiftWeek(1),
                    tooltip: 'Next week',
                    color: Colors.white,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
              SizedBox(
                height: 72,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: 7,
                  itemBuilder: (context, index) {
                    final day = stripStart.add(Duration(days: index));
                    return _HabitDayButton(
                      date: day,
                      selected: DateUtils.isSameDay(day, selectedDay),
                      onTap: () => setState(() => selectedDay = day),
                    );
                  },
                ),
              ),
              const SizedBox(height: 18),
              FutureBuilder<
                ({
                  List<Map<String, Object?>> habits,
                  List<Map<String, Object?>> entries,
                })
              >(
                future: load(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting &&
                      !snapshot.hasData) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(40),
                        child: CircularProgressIndicator(),
                      ),
                    );
                  }
                  if (snapshot.hasError) {
                    return const Text(
                      'Could not load habits.',
                      style: TextStyle(color: Colors.white),
                    );
                  }
                  final habits = snapshot.data?.habits ?? [];
                  final entries = snapshot.data?.entries ?? [];
                  final day = habitDayKey(selectedDay);
                  if (habits.isEmpty) {
                    return _HabitEmptyCard(
                      onCreate: () => add(),
                      onPreset: (title) => add(preset: title),
                    );
                  }
                  return Column(
                    children: [
                      for (final habit in habits)
                        _HabitTile(
                          title: habit['title'] as String,
                          done: entries.any(
                            (entry) =>
                                entry['habitId'] == habit['id'] &&
                                entry['day'] == day,
                          ),
                          streak: habitStreak(
                            entries
                                .where(
                                  (entry) => entry['habitId'] == habit['id'],
                                )
                                .map((entry) => entry['day'] as String)
                                .toSet(),
                            DateTime.now(),
                          ),
                          onToggle: () => toggle(
                            habit,
                            entries.any(
                              (entry) =>
                                  entry['habitId'] == habit['id'] &&
                                  entry['day'] == day,
                            ),
                          ),
                          onManage: () => manage(habit),
                        ),
                      const SizedBox(height: 8),
                      _HabitPresetPanel(
                        onPreset: (title) => add(preset: title),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _HabitDayButton extends StatelessWidget {
  const _HabitDayButton({
    required this.date,
    required this.selected,
    required this.onTap,
  });
  final DateTime date;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 7),
    child: Material(
      color: selected ? const Color(0xffff91bb) : const Color(0xe5221725),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          width: 46,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${date.day}',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: selected ? const Color(0xff291420) : Colors.white,
                ),
              ),
              Text(
                ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][date.weekday -
                    1],
                style: TextStyle(
                  fontSize: 10,
                  color: selected
                      ? const Color(0xff291420)
                      : const Color(0xffedd4e1),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _HabitEmptyCard extends StatelessWidget {
  const _HabitEmptyCard({required this.onCreate, required this.onPreset});
  final VoidCallback onCreate;
  final ValueChanged<String> onPreset;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
    decoration: BoxDecoration(
      color: const Color(0xe7211320),
      borderRadius: BorderRadius.circular(28),
      border: Border.all(color: const Color(0xffff6da7), width: 1.3),
      boxShadow: const [BoxShadow(color: Color(0x55fa4e99), blurRadius: 26)],
    ),
    child: Column(
      children: [
        Container(
          width: 136,
          height: 136,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [Color(0xff8f3b64), Color(0xff261824)],
            ),
          ),
          child: const Icon(
            Icons.fact_check_outlined,
            size: 78,
            color: Color(0xffff91bb),
          ),
        ),
        const SizedBox(height: 18),
        const Text(
          'Small steps add up',
          style: TextStyle(
            color: Colors.white,
            fontSize: 21,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Create a habit and check it off each day.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Color(0xffe2c9d6)),
        ),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: onCreate,
          icon: const Icon(Icons.add),
          label: const Text('Create your first habit'),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xffff91bb),
            foregroundColor: const Color(0xff291420),
          ),
        ),
        const SizedBox(height: 20),
        _HabitPresetPanel(onPreset: onPreset),
      ],
    ),
  );
}

class _HabitPresetPanel extends StatelessWidget {
  const _HabitPresetPanel({required this.onPreset});
  final ValueChanged<String> onPreset;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xff2c1929),
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: const Color(0xff864163)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.bolt_outlined, color: Color(0xffff91bb)),
            SizedBox(width: 8),
            Text(
              'Quick add',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 16,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          'Start building good habits',
          style: TextStyle(color: Color(0xffe2c9d6), fontSize: 12),
        ),
        const SizedBox(height: 13),
        Row(
          children: [
            _HabitPresetCard(
              'Drink water',
              Icons.water_drop_outlined,
              () => onPreset('Drink water'),
            ),
            _HabitPresetCard(
              'Exercise',
              Icons.fitness_center_outlined,
              () => onPreset('Exercise'),
            ),
            _HabitPresetCard(
              'Read',
              Icons.menu_book_outlined,
              () => onPreset('Read'),
            ),
            _HabitPresetCard(
              'Good sleep',
              Icons.nightlight_outlined,
              () => onPreset('Good sleep'),
            ),
          ],
        ),
      ],
    ),
  );
}

class _HabitPresetCard extends StatelessWidget {
  const _HabitPresetCard(this.title, this.icon, this.onTap);
  final String title;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Padding(
      padding: const EdgeInsets.only(right: 5),
      child: Material(
        color: const Color(0xff422036),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            height: 92,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: const Color(0xffffaad0), size: 24),
                const SizedBox(height: 8),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _HabitTile extends StatelessWidget {
  const _HabitTile({
    required this.title,
    required this.done,
    required this.streak,
    required this.onToggle,
    required this.onManage,
  });
  final String title;
  final bool done;
  final int streak;
  final VoidCallback onToggle;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) => Card(
    color: const Color(0xe72d1a2b),
    margin: const EdgeInsets.only(bottom: 9),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: const BorderSide(color: Color(0xff864163)),
    ),
    child: ListTile(
      onTap: onToggle,
      leading: Checkbox(
        value: done,
        onChanged: (_) => onToggle(),
        activeColor: const Color(0xffff91bb),
      ),
      title: Text(
        title,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: Text(
        streak == 0 ? 'Daily habit' : '$streak day streak',
        style: const TextStyle(color: Color(0xffe2c9d6)),
      ),
      trailing: IconButton(
        onPressed: onManage,
        tooltip: 'Manage habit',
        icon: const Icon(Icons.more_vert, color: Color(0xffff91bb)),
      ),
    ),
  );
}

int focusSecondsRemaining(DateTime endAt, DateTime now, int durationSeconds) =>
    ((endAt.millisecondsSinceEpoch - now.millisecondsSinceEpoch + 999) ~/ 1000)
        .clamp(0, durationSeconds);

class FocusPage extends StatefulWidget {
  const FocusPage({super.key});
  @override
  State<FocusPage> createState() => _FocusPageState();
}

class _FocusPageState extends State<FocusPage> with WidgetsBindingObserver {
  int durationSeconds = 1500;
  int remaining = 1500;
  String mode = 'Focus';
  DateTime? endAt;
  bool running = false;
  bool loaded = false;
  Timer? timer;

  String get display =>
      '${(remaining ~/ 60).toString().padLeft(2, '0')}:${(remaining % 60).toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(restore());
  }

  Future<void> restore() async {
    final store = LocalStore.instance;
    final savedDuration =
        int.tryParse(await store.setting('focus_duration') ?? '') ?? 1500;
    final savedRemaining =
        int.tryParse(await store.setting('focus_remaining') ?? '') ??
        savedDuration;
    final savedEnd = DateTime.tryParse(
      await store.setting('focus_end_at') ?? '',
    );
    final savedMode = await store.setting('focus_mode') ?? 'Focus';
    if (!mounted) return;
    setState(() {
      durationSeconds = savedDuration.clamp(60, 10800);
      remaining = savedEnd == null
          ? savedRemaining.clamp(0, durationSeconds)
          : focusSecondsRemaining(savedEnd, DateTime.now(), durationSeconds);
      endAt = savedEnd != null && remaining > 0 ? savedEnd : null;
      running = endAt != null;
      mode = savedMode;
      loaded = true;
    });
    if (running) startTicker();
  }

  Future<void> persist() async {
    final values = {
      'focus_duration': '$durationSeconds',
      'focus_remaining': '$remaining',
      'focus_end_at': endAt?.toIso8601String() ?? '',
      'focus_mode': mode,
    };
    await LocalStore.instance.db.transaction((txn) async {
      for (final entry in values.entries) {
        await txn.insert('settings', {
          'key': entry.key,
          'value': entry.value,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
    await LocalStore.instance.refreshWidgets();
  }

  void startTicker() {
    timer?.cancel();
    timer = Timer.periodic(const Duration(seconds: 1), (_) => syncClock());
  }

  void syncClock() {
    if (!mounted || endAt == null) return;
    final next = focusSecondsRemaining(endAt!, DateTime.now(), durationSeconds);
    if (next == 0) {
      timer?.cancel();
      setState(() {
        remaining = 0;
        running = false;
        endAt = null;
      });
      unawaited(persist());
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Focus session complete')));
    } else if (next != remaining) {
      setState(() => remaining = next);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) syncClock();
  }

  void start() {
    if (!loaded || running) return;
    if (remaining == 0) remaining = durationSeconds;
    setState(() {
      endAt = DateTime.now().add(Duration(seconds: remaining));
      running = true;
    });
    startTicker();
    unawaited(persist());
  }

  void pause() {
    if (!running || endAt == null) return;
    timer?.cancel();
    setState(() {
      remaining = focusSecondsRemaining(
        endAt!,
        DateTime.now(),
        durationSeconds,
      );
      endAt = null;
      running = false;
    });
    unawaited(persist());
  }

  void reset() {
    timer?.cancel();
    setState(() {
      remaining = durationSeconds;
      endAt = null;
      running = false;
    });
    unawaited(persist());
  }

  void selectPreset(int minutes, String name) {
    timer?.cancel();
    setState(() {
      durationSeconds = minutes * 60;
      remaining = durationSeconds;
      mode = name;
      endAt = null;
      running = false;
    });
    unawaited(persist());
  }

  Future<void> chooseCustomDuration() async {
    final input = TextEditingController(text: '${durationSeconds ~/ 60}');
    String? error;
    final minutes = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Custom focus duration'),
          content: TextField(
            controller: input,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: 'Minutes', errorText: error),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final value = int.tryParse(input.text.trim());
                if (value == null || value < 1 || value > 180) {
                  update(() => error = 'Choose 1 to 180 minutes');
                } else {
                  Navigator.pop(context, value);
                }
              },
              child: const Text('Set duration'),
            ),
          ],
        ),
      ),
    );
    input.dispose();
    if (minutes != null && mounted) selectPreset(minutes, 'Custom');
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    extendBodyBehindAppBar: true,
    appBar: AppBar(
      title: const Text('Focus timer'),
      backgroundColor: Colors.transparent,
      foregroundColor: Colors.white,
      systemOverlayStyle: SystemUiOverlayStyle.light,
      actions: [
        IconButton(
          tooltip: 'View insights',
          icon: const Icon(Icons.bar_chart_rounded),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const InsightPage()),
          ),
        ),
      ],
    ),
    body: Stack(
      fit: StackFit.expand,
      children: [
        Image.asset(
          'assets/daynix_neon_sunset.png',
          fit: BoxFit.cover,
          alignment: Alignment.centerRight,
        ),
        const ColoredBox(color: Color(0xb8120b17)),
        SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 66, 20, 36),
            children: [
              const Text(
                'Focus',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 39,
                  fontWeight: FontWeight.w900,
                  height: 1,
                ),
              ),
              const Text(
                'Better',
                style: TextStyle(
                  color: Color(0xffff91bb),
                  fontSize: 43,
                  fontWeight: FontWeight.w900,
                  height: 1.05,
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'A focused mind builds a brighter you.',
                style: TextStyle(color: Color(0xfff5ddeb), fontSize: 14),
              ),
              const SizedBox(height: 28),
              Center(
                child: SizedBox(
                  width: 266,
                  height: 266,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Color(0xe01d111f),
                          boxShadow: [
                            BoxShadow(
                              color: Color(0x99ff4e99),
                              blurRadius: 28,
                              spreadRadius: 3,
                            ),
                          ],
                        ),
                      ),
                      SizedBox.expand(
                        child: CircularProgressIndicator(
                          value: durationSeconds == 0
                              ? 0
                              : remaining / durationSeconds,
                          strokeWidth: 10,
                          strokeCap: StrokeCap.round,
                          color: const Color(0xffff91bb),
                          backgroundColor: const Color(0xff5c2945),
                        ),
                      ),
                      Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.spa_outlined,
                            color: Color(0xffffc3db),
                            size: 32,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            display,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 58,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -2,
                            ),
                          ),
                          Text(
                            '${durationSeconds ~/ 60} minute ${mode.toLowerCase()} session',
                            style: const TextStyle(
                              color: Color(0xffe8d1df),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 26),
              Center(
                child: SizedBox(
                  width: 242,
                  height: 54,
                  child: FilledButton.icon(
                    onPressed: loaded ? (running ? pause : start) : null,
                    icon: Icon(
                      running ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    ),
                    label: Text(
                      running
                          ? 'Pause focus'
                          : remaining < durationSeconds && remaining > 0
                          ? 'Resume focus'
                          : 'Start focus',
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xffff75ac),
                      foregroundColor: const Color(0xff2a1020),
                      textStyle: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _FocusAction(
                    icon: Icons.timer_outlined,
                    label: 'Pomodoro',
                    onTap: () => selectPreset(25, 'Focus'),
                  ),
                  _FocusAction(
                    icon: Icons.restart_alt_rounded,
                    label: 'Reset',
                    onTap: reset,
                  ),
                  _FocusAction(
                    icon: Icons.settings_outlined,
                    label: 'Settings',
                    onTap: chooseCustomDuration,
                  ),
                ],
              ),
              const SizedBox(height: 25),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xe2211421),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: const Color(0xffa84d77)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.star_border_rounded,
                          color: Color(0xffff91bb),
                        ),
                        const SizedBox(width: 9),
                        const Expanded(
                          child: Text(
                            'Focus presets',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: chooseCustomDuration,
                          child: const Text('Custom  ›'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        _FocusPresetCard(
                          minutes: 25,
                          label: 'Focus',
                          icon: Icons.spa_outlined,
                          selected: durationSeconds == 1500 && mode == 'Focus',
                          onTap: () => selectPreset(25, 'Focus'),
                        ),
                        _FocusPresetCard(
                          minutes: 5,
                          label: 'Short break',
                          icon: Icons.coffee_outlined,
                          selected:
                              durationSeconds == 300 && mode == 'Short break',
                          onTap: () => selectPreset(5, 'Short break'),
                        ),
                        _FocusPresetCard(
                          minutes: 15,
                          label: 'Deep work',
                          icon: Icons.local_florist_outlined,
                          selected:
                              durationSeconds == 900 && mode == 'Deep work',
                          onTap: () => selectPreset(15, 'Deep work'),
                        ),
                        _FocusPresetCard(
                          minutes: 30,
                          label: 'Long focus',
                          icon: Icons.nightlight_outlined,
                          selected:
                              durationSeconds == 1800 && mode == 'Long focus',
                          onTap: () => selectPreset(30, 'Long focus'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _FocusAction extends StatelessWidget {
  const _FocusAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      IconButton.filledTonal(
        onPressed: onTap,
        icon: Icon(icon),
        tooltip: label,
      ),
      Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
    ],
  );
}

class _FocusPresetCard extends StatelessWidget {
  const _FocusPresetCard({
    required this.minutes,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });
  final int minutes;
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: selected ? const Color(0xffa4386d) : const Color(0xff321b2c),
        borderRadius: BorderRadius.circular(17),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(17),
          child: SizedBox(
            height: 102,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: const Color(0xffffc3db), size: 24),
                const SizedBox(height: 7),
                Text(
                  '$minutes min',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  ),
                ),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xffead0dd),
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class DumpPage extends StatefulWidget {
  const DumpPage({super.key});
  @override
  State<DumpPage> createState() => _DumpPageState();
}

class _DumpPageState extends State<DumpPage> {
  final controller = TextEditingController();
  final search = TextEditingController();
  String query = '';

  @override
  void dispose() {
    controller.dispose();
    search.dispose();
    super.dispose();
  }

  void insertBullet() {
    final current = controller.value;
    final position = current.selection.isValid
        ? current.selection.start
        : current.text.length;
    final updated = current.text.replaceRange(position, position, '• ');
    controller.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: position + 2),
    );
  }

  Future<void> save() async {
    final text = controller.text.trim();
    if (text.isEmpty) return;
    await LocalStore.instance.db.insert('dumps', {
      'id': DateTime.now().microsecondsSinceEpoch.toString(),
      'body': text,
      'createdAt': DateTime.now().toIso8601String(),
    });
    controller.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xff110c15),
    appBar: AppBar(
      title: const Text('Brain dump'),
      backgroundColor: const Color(0xff110c15),
      foregroundColor: Colors.white,
    ),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 36),
      children: [
        const _NeonSectionHero(
          eyebrow: 'BRAIN DUMP',
          first: 'Free',
          second: 'your mind',
          quote: 'Get it out of your head and into a safer place.',
        ),
        const SizedBox(height: 22),
        Container(
          padding: const EdgeInsets.fromLTRB(17, 12, 17, 10),
          decoration: BoxDecoration(
            color: const Color(0xff241522),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: const Color(0xffff78ac), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: const Color(0xffff4f96).withValues(alpha: .16),
                blurRadius: 20,
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              TextField(
                controller: controller,
                onChanged: (_) => setState(() {}),
                minLines: 7,
                maxLines: 12,
                maxLength: 500,
                style: const TextStyle(color: Colors.white, fontSize: 17),
                decoration: const InputDecoration(
                  hintText: 'Get it out of your head...',
                  hintStyle: TextStyle(color: Color(0xffc9aebb)),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  counterText: '',
                ),
              ),
              Text(
                '${controller.text.length}/500',
                style: const TextStyle(color: Color(0xffdfb7c9)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: insertBullet,
              icon: const Icon(Icons.format_list_bulleted),
              label: const Text('List'),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: controller.text.trim().isEmpty ? null : save,
              icon: const Icon(Icons.send_outlined),
              label: const Text('Save thought'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xffff79ad),
                foregroundColor: const Color(0xff241021),
                padding: const EdgeInsets.symmetric(
                  horizontal: 17,
                  vertical: 16,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 25),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xff2d1827),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xff94345e)),
          ),
          child: const Row(
            children: [
              Icon(Icons.lightbulb_outline, color: Color(0xffff91bb), size: 34),
              SizedBox(width: 15),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Quick capture',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: 5),
                    Text(
                      'Jot down anything on your mind — ideas, thoughts, worries, or reminders.',
                      style: TextStyle(color: Color(0xffd9c5ce)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        const Text(
          'Saved thoughts',
          style: TextStyle(
            color: Colors.white,
            fontSize: 19,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: search,
          onChanged: (value) =>
              setState(() => query = value.trim().toLowerCase()),
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: 'Search thoughts',
          ),
        ),
        const SizedBox(height: 12),
        FutureBuilder<List<Map<String, Object?>>>(
          future: LocalStore.instance.read('dumps'),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: CircularProgressIndicator(),
                ),
              );
            }
            final items = (snapshot.data ?? [])
                .where(
                  (item) =>
                      (item['body'] as String).toLowerCase().contains(query),
                )
                .toList();
            if (items.isEmpty) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 22),
                child: Text(
                  'No saved thoughts here yet.',
                  style: TextStyle(color: Color(0xffd9c5ce)),
                ),
              );
            }
            return Column(
              children: items
                  .map(
                    (item) => Card(
                      color: const Color(0xff2a1928),
                      child: ListTile(
                        title: Text(
                          item['body'] as String,
                          style: const TextStyle(color: Colors.white),
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          formatDate(
                            DateTime.parse(item['createdAt'] as String),
                          ),
                          style: const TextStyle(color: Color(0xffc9aebb)),
                        ),
                        trailing: PopupMenuButton<String>(
                          tooltip: 'Thought actions',
                          onSelected: (action) async {
                            if (action == 'task') {
                              await LocalStore.instance.addTask(
                                item['body'] as String,
                              );
                            } else if (action == 'note') {
                              final now = DateTime.now();
                              await LocalStore.instance.db.insert('notes', {
                                'id': now.microsecondsSinceEpoch.toString(),
                                'title': (item['body'] as String)
                                    .split('\n')
                                    .first,
                                'body': item['body'],
                                'updatedAt': now.toIso8601String(),
                                'pinned': 0,
                              });
                              await LocalStore.instance.refreshWidgets();
                            } else {
                              final approved = await showDialog<bool>(
                                context: context,
                                builder: (dialogContext) => AlertDialog(
                                  title: const Text('Delete thought?'),
                                  content: const Text(
                                    'This saved thought will be removed.',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(dialogContext, false),
                                      child: const Text('Cancel'),
                                    ),
                                    FilledButton(
                                      onPressed: () =>
                                          Navigator.pop(dialogContext, true),
                                      child: const Text('Delete'),
                                    ),
                                  ],
                                ),
                              );
                              if (approved != true) return;
                              await LocalStore.instance.db.delete(
                                'dumps',
                                where: 'id=?',
                                whereArgs: [item['id']],
                              );
                            }
                            if (context.mounted) setState(() {});
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: 'task',
                              child: Text('Turn into task'),
                            ),
                            PopupMenuItem(
                              value: 'note',
                              child: Text('Turn into note'),
                            ),
                            PopupMenuItem(
                              value: 'delete',
                              child: Text('Delete thought'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                  .toList(),
            );
          },
        ),
      ],
    ),
  );
}

class InsightBar {
  const InsightBar(this.label, this.count);
  final String label;
  final int count;
}

bool taskCreatedInPeriod(
  Map<String, Object?> task,
  String period,
  DateTime now,
) {
  if (period == 'all') return true;
  final created = DateTime.tryParse(task['createdAt'] as String? ?? '');
  if (created == null) return false;
  final today = DateUtils.dateOnly(now);
  final start = switch (period) {
    'today' => today,
    'week' => today.subtract(Duration(days: today.weekday - 1)),
    'month' => DateTime(today.year, today.month),
    _ => today,
  };
  final end = switch (period) {
    'today' => start.add(const Duration(days: 1)),
    'week' => start.add(const Duration(days: 7)),
    'month' => DateTime(today.year, today.month + 1),
    _ => start.add(const Duration(days: 1)),
  };
  return !created.isBefore(start) && created.isBefore(end);
}

List<InsightBar> insightCreationBars(
  List<Map<String, Object?>> tasks,
  String period,
  DateTime now,
) {
  final today = DateUtils.dateOnly(now);
  final dates = tasks
      .map((task) => DateTime.tryParse(task['createdAt'] as String? ?? ''))
      .whereType<DateTime>()
      .toList();
  if (period == 'all') {
    return List.generate(6, (index) {
      final month = DateTime(today.year, today.month - 5 + index);
      final label = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ][month.month - 1];
      return InsightBar(
        label,
        dates
            .where(
              (date) => date.year == month.year && date.month == month.month,
            )
            .length,
      );
    });
  }
  if (period == 'month') {
    final days = DateTime(today.year, today.month + 1, 0).day;
    return List.generate((days + 6) ~/ 7, (index) {
      final from = DateTime(today.year, today.month, index * 7 + 1);
      final to = DateTime(today.year, today.month, index * 7 + 8);
      return InsightBar(
        'W${index + 1}',
        dates
            .where(
              (date) =>
                  date.year == today.year &&
                  date.month == today.month &&
                  !date.isBefore(from) &&
                  date.isBefore(to),
            )
            .length,
      );
    });
  }
  final first = period == 'today'
      ? today.subtract(const Duration(days: 6))
      : today.subtract(Duration(days: today.weekday - 1));
  return List.generate(7, (index) {
    final day = first.add(Duration(days: index));
    return InsightBar(
      ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][day.weekday - 1],
      dates.where((date) => DateUtils.isSameDay(date, day)).length,
    );
  });
}

class InsightPage extends StatefulWidget {
  const InsightPage({super.key});
  @override
  State<InsightPage> createState() => _InsightPageState();
}

class _InsightPageState extends State<InsightPage> {
  String period = 'week';
  String get periodLabel => switch (period) {
    'today' => 'Today',
    'month' => 'This month',
    'all' => 'All time',
    _ => 'This week',
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    extendBodyBehindAppBar: true,
    appBar: AppBar(
      title: const Text('Insights'),
      backgroundColor: Colors.transparent,
      foregroundColor: Colors.white,
      systemOverlayStyle: SystemUiOverlayStyle.light,
      actions: [
        PopupMenuButton<String>(
          tooltip: 'Choose period',
          initialValue: period,
          onSelected: (value) => setState(() => period = value),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'today', child: Text('Today')),
            PopupMenuItem(value: 'week', child: Text('This week')),
            PopupMenuItem(value: 'month', child: Text('This month')),
            PopupMenuItem(value: 'all', child: Text('All time')),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text(periodLabel, style: const TextStyle(color: Colors.white)),
                const Icon(Icons.expand_more, color: Colors.white),
              ],
            ),
          ),
        ),
      ],
    ),
    body: Stack(
      fit: StackFit.expand,
      children: [
        Image.asset(
          'assets/daynix_neon_sunset.png',
          fit: BoxFit.cover,
          alignment: Alignment.centerRight,
        ),
        const ColoredBox(color: Color(0xc5120b17)),
        SafeArea(
          child: FutureBuilder<List<Map<String, Object?>>>(
            future: LocalStore.instance.read('tasks'),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting &&
                  !snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return const Center(
                  child: Text(
                    'Could not load insights.',
                    style: TextStyle(color: Colors.white),
                  ),
                );
              }
              final all = snapshot.data ?? [];
              final now = DateTime.now();
              final tasks = all
                  .where((task) => taskCreatedInPeriod(task, period, now))
                  .toList();
              final done = tasks.where((task) => task['completed'] == 1).length;
              final open = tasks.length - done;
              final ratio = tasks.isEmpty ? 0.0 : done / tasks.length;
              final bars = insightCreationBars(all, period, now);
              return ListView(
                padding: const EdgeInsets.fromLTRB(18, 68, 18, 40),
                children: [
                  const Text(
                    'Your',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 39,
                      fontWeight: FontWeight.w900,
                      height: 1,
                    ),
                  ),
                  const Text(
                    'progress',
                    style: TextStyle(
                      color: Color(0xffff91bb),
                      fontSize: 43,
                      fontWeight: FontWeight.w900,
                      height: 1.05,
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Consistency today builds a brighter tomorrow.',
                    style: TextStyle(color: Color(0xfff5ddeb), fontSize: 14),
                  ),
                  const SizedBox(height: 34),
                  _InsightSummaryCard(
                    total: tasks.length,
                    done: done,
                    open: open,
                    ratio: ratio,
                  ),
                  const SizedBox(height: 27),
                  Row(
                    children: [
                      const Icon(
                        Icons.bar_chart_rounded,
                        color: Color(0xffff91bb),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Productivity overview',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const Text(
                        'Tasks created',
                        style: TextStyle(
                          color: Color(0xffff91bb),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _InsightChartCard(
                    bars: bars,
                    caption: period == 'all'
                        ? 'Recent six months'
                        : period == 'today'
                        ? 'Last seven days'
                        : periodLabel,
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: _InsightMetricCard(
                          icon: Icons.check_circle_rounded,
                          value: done,
                          label: 'Tasks completed',
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _InsightMetricCard(
                          icon: Icons.radio_button_unchecked,
                          value: open,
                          label: 'Tasks open',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 25),
                  const Row(
                    children: [
                      Icon(Icons.pie_chart_outline, color: Color(0xffff91bb)),
                      SizedBox(width: 10),
                      Text(
                        'Task status',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _InsightStatusCard(
                    total: tasks.length,
                    done: done,
                    open: open,
                    ratio: ratio,
                  ),
                  const SizedBox(height: 18),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xe2211421),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xffa84d77)),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.lock_outline, color: Color(0xffff91bb)),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Based on task creation dates and current completion state. Your data stays private and offline.',
                            style: TextStyle(
                              color: Color(0xffe8d1df),
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    ),
  );
}

class _InsightSummaryCard extends StatelessWidget {
  const _InsightSummaryCard({
    required this.total,
    required this.done,
    required this.open,
    required this.ratio,
  });
  final int total;
  final int done;
  final int open;
  final double ratio;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: const Color(0xe2211421),
      borderRadius: BorderRadius.circular(25),
      border: Border.all(color: const Color(0xffb94e7e)),
      boxShadow: const [BoxShadow(color: Color(0x55fa4e99), blurRadius: 22)],
    ),
    child: Row(
      children: [
        SizedBox(
          width: 112,
          height: 112,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox.expand(
                child: CircularProgressIndicator(
                  value: ratio,
                  strokeWidth: 11,
                  color: const Color(0xffff91bb),
                  backgroundColor: const Color(0xff613047),
                ),
              ),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '${(ratio * 100).round()}%',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 27,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    '$done / $total',
                    style: const TextStyle(
                      color: Color(0xffe8d1df),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 17),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '✓  $done completed',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '○  $open open',
                style: const TextStyle(color: Color(0xffe8d1df)),
              ),
              const SizedBox(height: 17),
              LinearProgressIndicator(
                value: ratio,
                minHeight: 8,
                borderRadius: BorderRadius.circular(8),
                color: const Color(0xffff91bb),
                backgroundColor: const Color(0xff613047),
              ),
              const SizedBox(height: 9),
              const Text(
                'Tasks stored on this device',
                style: TextStyle(color: Color(0xffd9bdcf), fontSize: 10),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _InsightChartCard extends StatelessWidget {
  const _InsightChartCard({required this.bars, required this.caption});
  final List<InsightBar> bars;
  final String caption;

  @override
  Widget build(BuildContext context) {
    final peak = bars.fold<int>(
      1,
      (current, bar) => bar.count > current ? bar.count : current,
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(15, 14, 15, 18),
      decoration: BoxDecoration(
        color: const Color(0xe2211421),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xff6c3a55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            caption,
            style: const TextStyle(color: Color(0xffe8d1df), fontSize: 12),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 125,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final bar in bars)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Container(
                            height: bar.count == 0 ? 3 : 96 * bar.count / peak,
                            decoration: BoxDecoration(
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(7),
                              ),
                              gradient: const LinearGradient(
                                colors: [Color(0xffff91bb), Color(0xffa73569)],
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                              ),
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            bar.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xffdcc2d1),
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InsightMetricCard extends StatelessWidget {
  const _InsightMetricCard({
    required this.icon,
    required this.value,
    required this.label,
  });
  final IconData icon;
  final int value;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(
      color: const Color(0xe2211421),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: const Color(0xff9f4b72)),
    ),
    child: Row(
      children: [
        Icon(icon, color: const Color(0xffff91bb), size: 25),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$value',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                ),
              ),
              Text(
                label,
                style: const TextStyle(color: Color(0xffe8d1df), fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _InsightStatusCard extends StatelessWidget {
  const _InsightStatusCard({
    required this.total,
    required this.done,
    required this.open,
    required this.ratio,
  });
  final int total;
  final int done;
  final int open;
  final double ratio;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(17),
    decoration: BoxDecoration(
      color: const Color(0xe2211421),
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: const Color(0xff6c3a55)),
    ),
    child: Row(
      children: [
        SizedBox(
          width: 105,
          height: 105,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox.expand(
                child: CircularProgressIndicator(
                  value: ratio,
                  strokeWidth: 10,
                  color: const Color(0xffff91bb),
                  backgroundColor: const Color(0xff613047),
                ),
              ),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '$total',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 25,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const Text(
                    'Total tasks',
                    style: TextStyle(color: Color(0xffe8d1df), fontSize: 10),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 17),
        Expanded(
          child: Column(
            children: [
              Row(
                children: [
                  const Icon(Icons.circle, color: Color(0xffff91bb), size: 10),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text(
                      'Completed',
                      style: TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                  Text(
                    '$done',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 13),
              Row(
                children: [
                  const Icon(Icons.circle, color: Color(0xff7a6575), size: 10),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text(
                      'Open',
                      style: TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                  Text(
                    '$open',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class SectionTitle extends StatelessWidget {
  final String title, trailing;
  const SectionTitle(this.title, this.trailing, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
        ),
        Text(
          trailing,
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title, body;
  final String? action;
  final Future<void> Function()? onTap;
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.action,
    this.onTap,
  });
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Column(
        children: [
          Icon(icon, size: 30, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 9),
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          if (action != null) ...[
            const SizedBox(height: 8),
            TextButton(onPressed: () => onTap?.call(), child: Text(action!)),
          ],
        ],
      ),
    ),
  );
}

class TaskEditorSheet extends StatefulWidget {
  final Future<void> Function() onSaved;
  final Map<String, Object?>? existing;
  final DateTime? initialDate;
  const TaskEditorSheet({
    super.key,
    required this.onSaved,
    this.existing,
    this.initialDate,
  });
  @override
  State<TaskEditorSheet> createState() => _TaskEditorSheetState();
}

class _TaskEditorSheetState extends State<TaskEditorSheet> {
  final title = TextEditingController();
  final description = TextEditingController();
  final project = TextEditingController();
  final labels = TextEditingController();
  final location = TextEditingController();
  final subtasks = TextEditingController();
  DateTime? selected;
  TimeOfDay? time;
  int priority = 1;
  bool reminder = true;
  String recurrence = 'none';
  final Set<int> repeatDays = {};
  String? attachment;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    final task = widget.existing;
    if (task == null) {
      selected = widget.initialDate;
      return;
    }
    title.text = task['title'] as String? ?? '';
    description.text = task['description'] as String? ?? '';
    project.text = task['project'] as String? ?? '';
    labels.text = task['labels'] as String? ?? '';
    location.text = task['location'] as String? ?? '';
    attachment = task['attachmentUri'] as String?;
    priority = task['priority'] as int? ?? 1;
    reminder = task['reminderEnabled'] != 0;
    recurrence = task['recurrence'] as String? ?? 'none';
    if (recurrence.startsWith('custom:')) {
      repeatDays.addAll(
        recurrence.substring(7).split(',').map(int.tryParse).whereType<int>(),
      );
    }
    final due = DateTime.tryParse(task['dueAt'] as String? ?? '');
    if (due != null) {
      selected = due;
      if ((task['dueAt'] as String).length > 10) {
        time = TimeOfDay.fromDateTime(due);
      }
    }
    LocalStore.instance
        .read('subtasks', where: 'taskId=?', args: [task['id']])
        .then((rows) {
          if (mounted) {
            setState(
              () => subtasks.text = rows.map((r) => r['title']).join('\n'),
            );
          }
        });
  }

  @override
  void dispose() {
    for (final c in [title, description, project, labels, location, subtasks]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> pickDate({bool tomorrow = false}) async {
    final now = DateTime.now();
    final value = tomorrow
        ? DateTime(now.year, now.month, now.day + 1)
        : await showDatePicker(
            context: context,
            initialDate: selected ?? now,
            firstDate: DateTime(now.year - 1),
            lastDate: DateTime(now.year + 10),
            builder: (context, child) => Theme(
              data: Theme.of(context).copyWith(
                colorScheme: Theme.of(context).colorScheme
                    .copyWith(primary: const Color(0xffff69a4)),
              ),
              child: child!,
            ),
          );
    if (value != null && mounted) setState(() => selected = value);
  }

  Future<void> save() async {
    if (title.text.trim().isEmpty || busy) return;
    if (recurrence != 'none' &&
        (selected == null ||
            time == null ||
            ((recurrence == 'custom' || recurrence.startsWith('custom:')) &&
                repeatDays.isEmpty))) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Choose a date, time and repeat days first.'),
        ),
      );
      return;
    }
    setState(() => busy = true);
    final due = selected == null
        ? null
        : time == null
        ? '${selected!.year.toString().padLeft(4, '0')}-${selected!.month.toString().padLeft(2, '0')}-${selected!.day.toString().padLeft(2, '0')}'
        : DateTime(
            selected!.year,
            selected!.month,
            selected!.day,
            time!.hour,
            time!.minute,
          ).toIso8601String();
    try {
      final values = <String, Object?>{
        'title': title.text.trim(),
        'description': description.text.trim(),
        'project': project.text.trim(),
        'labels': labels.text.trim(),
        'location': location.text.trim(),
        'attachmentUri': attachment,
        'dueAt': due,
        'priority': priority,
        'reminderEnabled': reminder ? 1 : 0,
        'recurrence': recurrence == 'custom' || recurrence.startsWith('custom:')
            ? 'custom:${(repeatDays.toList()..sort()).join(',')}'
            : recurrence,
      };
      if (widget.existing == null) {
        await LocalStore.instance.createTask(values, subtasks.text.split('\n'));
      } else {
        await LocalStore.instance.updateTask(
          widget.existing!['id'] as String,
          values,
          subtasks.text.split('\n'),
        );
      }
      await widget.onSaved();
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not save task: $error')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> delete() async {
    final id = widget.existing?['id'] as String?;
    if (id == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete task?'),
        content: const Text('This task and its subtasks will be removed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await LocalStore.instance.deleteTask(id);
    await widget.onSaved();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final pink = colors.primary;
    final fieldColor = colors.surfaceContainerHighest.withValues(alpha: 0.55);
    InputDecoration taskField(String hint, IconData icon) => InputDecoration(
      hintText: hint,
      floatingLabelBehavior: FloatingLabelBehavior.never,
      prefixIcon: Icon(icon, size: 21),
      filled: true,
      fillColor: fieldColor,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(18)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: colors.outline.withValues(alpha: 0.65)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: pink, width: 1.6),
      ),
    );
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          18,
          8,
          18,
          MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.existing == null ? 'Add task' : 'Edit task',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                        color: pink,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                  if (widget.existing != null)
                    IconButton(
                      onPressed: delete,
                      tooltip: 'Delete task',
                      icon: const Icon(Icons.delete_outline),
                    ),
                ],
              ),
              const Padding(
                padding: EdgeInsets.only(bottom: 15),
                child: Text('Turn your thoughts into action.'),
              ),
              TextField(
                controller: title,
                autofocus: true,
                textInputAction: TextInputAction.next,
                decoration: taskField(
                  'What needs doing?',
                  Icons.add_circle_outline,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 7,
                runSpacing: 4,
                children: [
                  ChoiceChip(
                    avatar: const Icon(Icons.wb_sunny_outlined, size: 18),
                    label: const Text('Today'),
                    selected:
                        selected != null &&
                        DateUtils.isSameDay(selected, DateTime.now()),
                    onSelected: (_) =>
                        setState(() => selected = DateTime.now()),
                  ),
                  ChoiceChip(
                    avatar: const Icon(Icons.cloud_outlined, size: 18),
                    label: const Text('Tomorrow'),
                    selected:
                        selected != null &&
                        DateUtils.isSameDay(
                          selected,
                          DateTime.now().add(const Duration(days: 1)),
                        ),
                    onSelected: (_) => pickDate(tomorrow: true),
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.calendar_month_outlined, size: 18),
                    label: Text(
                      selected == null ? 'Pick date' : formatDate(selected!),
                    ),
                    onPressed: pickDate,
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.schedule, size: 18),
                    label: Text(time == null ? 'Time' : time!.format(context)),
                    onPressed: () async {
                      final picked = await showTimePicker(
                        context: context,
                        initialTime: time ?? TimeOfDay.now(),
                      );
                      if (picked != null) setState(() => time = picked);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'Repeat',
                style: TextStyle(color: pink, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: recurrence.startsWith('custom:')
                    ? 'custom'
                    : recurrence,
                decoration: taskField('Repeat', Icons.repeat),
                items: const [
                  DropdownMenuItem(
                    value: 'none',
                    child: Text('Does not repeat'),
                  ),
                  DropdownMenuItem(value: 'daily', child: Text('Daily')),
                  DropdownMenuItem(
                    value: 'weekdays',
                    child: Text('Mon to Fri'),
                  ),
                  DropdownMenuItem(value: 'weekly', child: Text('Weekly')),
                  DropdownMenuItem(value: 'monthly', child: Text('Monthly')),
                  DropdownMenuItem(
                    value: 'custom',
                    child: Text('Custom weekdays'),
                  ),
                ],
                onChanged: (value) =>
                    setState(() => recurrence = value ?? 'none'),
              ),
              if (recurrence == 'custom' || recurrence.startsWith('custom:'))
                Wrap(
                  spacing: 5,
                  runSpacing: 4,
                  children: List.generate(
                    7,
                    (index) => FilterChip(
                      label: Text(
                        [
                          'Mon',
                          'Tue',
                          'Wed',
                          'Thu',
                          'Fri',
                          'Sat',
                          'Sun',
                        ][index],
                      ),
                      selected: repeatDays.contains(index + 1),
                      onSelected: (on) => setState(() {
                        if (on) {
                          repeatDays.add(index + 1);
                        } else {
                          repeatDays.remove(index + 1);
                        }
                      }),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHigh.withValues(alpha: .68),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: pink.withValues(alpha: .55)),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 5,
                ),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(top: 8, bottom: 4),
                  initiallyExpanded: true,
                  title: const Text(
                    'Details & reminders',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  children: [
                    TextField(
                      controller: description,
                      minLines: 2,
                      maxLines: 3,
                      decoration: taskField('Description', Icons.notes),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: project,
                      decoration: taskField('Project', Icons.folder_outlined),
                    ),
                    const SizedBox(height: 14),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Priority',
                        style: TextStyle(
                          color: pink,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<int>(
                      isExpanded: true,
                      initialValue: priority,
                      decoration: taskField('Priority', Icons.flag_outlined),
                      items: const [
                        DropdownMenuItem(value: 0, child: Text('Low')),
                        DropdownMenuItem(value: 1, child: Text('Medium')),
                        DropdownMenuItem(value: 2, child: Text('High')),
                        DropdownMenuItem(value: 3, child: Text('Urgent')),
                      ],
                      onChanged: (v) => setState(() => priority = v ?? 1),
                    ),
                    SwitchListTile(
                      contentPadding: const EdgeInsets.symmetric(vertical: 6),
                      title: const Text('Ring 10 seconds before'),
                      subtitle: const Text(
                        'Choose a date and time. Snooze or dismiss the alarm from the lock screen.',
                      ),
                      value: reminder,
                      onChanged: (v) => setState(() => reminder = v),
                    ),
                    TextField(
                      controller: labels,
                      decoration: taskField(
                        'Labels, comma separated',
                        Icons.label_outline,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: location,
                      decoration: taskField('Location', Icons.place_outlined),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: subtasks,
                      minLines: 1,
                      maxLines: 4,
                      decoration: taskField(
                        'Subtasks, one per line',
                        Icons.subdirectory_arrow_right,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      decoration: BoxDecoration(
                        color: fieldColor,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: colors.outline.withValues(alpha: 0.65),
                        ),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                        ),
                        leading: const Icon(Icons.attach_file),
                        title: Text(
                          attachment == null
                              ? 'Attachment'
                              : 'Attachment selected',
                        ),
                        trailing: attachment == null
                            ? null
                            : IconButton(
                                tooltip: 'Open attachment',
                                icon: const Icon(Icons.open_in_new),
                                onPressed: () async {
                                  try {
                                    await taskiyaNative.invokeMethod(
                                      'openAttachment',
                                      {'uri': attachment},
                                    );
                                  } on PlatformException {
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                            const SnackBar(
                                              content: Text(
                                                'No app could open this attachment.',
                                              ),
                                            ),
                                          );
                                    }
                                  }
                                },
                              ),
                        onTap: () async {
                          try {
                            final uri = await taskiyaNative
                                .invokeMethod<String>('pickAttachment');
                            if (uri != null && mounted) {
                              setState(() => attachment = uri);
                            }
                          } on PlatformException {
                            /* Optional attachment. */
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: busy ? null : save,
                  icon: const Icon(Icons.add),
                  label: Text(
                    widget.existing == null ? 'Add task' : 'Save changes',
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: pink,
                    foregroundColor: const Color(0xff26121f),
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class TaskiyaSettingsPage extends StatefulWidget {
  const TaskiyaSettingsPage({super.key});
  @override
  State<TaskiyaSettingsPage> createState() => _TaskiyaSettingsPageState();
}

class _TaskiyaSettingsPageState extends State<TaskiyaSettingsPage> {
  String widgetMode = 'system';
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    widgetMode = await LocalStore.instance.setting('widget_theme') ?? 'system';
    if (mounted) setState(() {});
  }

  Future<void> setWidget(String value) async {
    await LocalStore.instance.setSetting('widget_theme', value);
    await LocalStore.instance.refreshWidgets();
    setState(() => widgetMode = value);
  }

  Future<void> setApp(String value) async {
    await LocalStore.instance.setSetting('theme_mode', value);
    taskiyaTheme.value = switch (value) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  Future<void> pinWidget(String kind) async {
    var requested = false;
    try {
      requested =
          await taskiyaNative.invokeMethod<bool>('pinWidget', {'kind': kind}) ??
          false;
    } on PlatformException {
      // The launcher may not expose a widget pin request.
    }
    if (mounted && !requested) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Open your home screen widget picker to add DAYNIX.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xff120c16),
    appBar: AppBar(
      title: const Text('DAYNIX appearance'),
      backgroundColor: const Color(0xff120c16),
      foregroundColor: Colors.white,
    ),
    body: ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const _NeonSectionHero(
          eyebrow: 'MAKE IT',
          first: 'Yours',
          second: 'Always',
          quote: 'A space that looks and feels like you.',
        ),
        const SizedBox(height: 22),
        Card(
          color: const Color(0xff281a27),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'App theme',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const Text(
                  'Choose how DAYNIX looks on your device.',
                  style: TextStyle(color: Color(0xffd7bfca)),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  style: const TextStyle(color: Colors.white),
                  dropdownColor: const Color(0xff35202e),
                  decoration: const InputDecoration(
                    filled: true,
                    fillColor: Color(0xff35202e),
                    prefixIcon: Icon(
                      Icons.palette_outlined,
                      color: Color(0xffff91bb),
                    ),
                  ),
                  initialValue: switch (taskiyaTheme.value) {
                    ThemeMode.light => 'light',
                    ThemeMode.dark => 'dark',
                    _ => 'system',
                  },
                  items: const [
                    DropdownMenuItem(
                      value: 'system',
                      child: Text('Follow system'),
                    ),
                    DropdownMenuItem(value: 'light', child: Text('Light')),
                    DropdownMenuItem(
                      value: 'dark',
                      child: Text('Dark / AMOLED'),
                    ),
                  ],
                  onChanged: (v) {
                    if (v != null) setApp(v);
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          color: const Color(0xff281a27),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Widget theme',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const Text(
                  'Applies to both task and notes widgets. Tap a widget header on your home screen to set a theme for that instance.',
                  style: TextStyle(color: Color(0xffd7bfca)),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  style: const TextStyle(color: Colors.white),
                  dropdownColor: const Color(0xff35202e),
                  decoration: const InputDecoration(
                    filled: true,
                    fillColor: Color(0xff35202e),
                    prefixIcon: Icon(
                      Icons.widgets_outlined,
                      color: Color(0xffff91bb),
                    ),
                  ),
                  key: ValueKey(widgetMode),
                  initialValue: widgetMode,
                  items: const [
                    DropdownMenuItem(
                      value: 'system',
                      child: Text('Follow system'),
                    ),
                    DropdownMenuItem(
                      value: 'light',
                      child: Text('Light pastel'),
                    ),
                    DropdownMenuItem(value: 'dark', child: Text('Dark pastel')),
                  ],
                  onChanged: (v) {
                    if (v != null) setWidget(v);
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          color: const Color(0xff281a27),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Add DAYNIX widgets',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Pin a 4×3 widget to your home screen. Your launcher may ask for confirmation.',
                  style: TextStyle(color: Color(0xffd7bfca)),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: () => pinWidget('tasks'),
                      icon: const Icon(Icons.checklist),
                      label: const Text('Tasks widget'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => pinWidget('notes'),
                      icon: const Icon(Icons.sticky_note_2_outlined),
                      label: const Text('Notes widget'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class NiyaSettingsPage extends StatefulWidget {
  const NiyaSettingsPage({super.key});
  @override
  State<NiyaSettingsPage> createState() => _NiyaSettingsPageState();
}

class _NiyaSettingsPageState extends State<NiyaSettingsPage> {
  static const petNames = {
    'niya': 'NIYA',
    'titta': 'Titta',
    'luna': 'Luna',
    'kleg': 'Kleg',
    'momo': 'Momo',
    'custom': 'My pet',
  };
  static const petAssets = {
    'niya': 'assets/niya_idle.png',
    'titta': 'assets/pet_titta.png',
    'luna': 'assets/pet_luna.png',
    'kleg': 'assets/pet_kleg.png',
    'momo': 'assets/pet_momo.png',
  };
  String petKind = 'niya';
  String? customPetPath;
  bool importingPet = false;
  bool enabled = false;
  int hideSeconds = 10;
  int size = 72;
  double opacity = .5;
  int lead = 10;
  String privacy = 'private';
  String preferredEdge = 'auto';
  bool animations = true;
  bool taskPopup = true;
  bool celebration = true;
  bool lockReminders = true;
  bool lockScreenPet = true;
  bool batterySaver = false;
  bool reducedMotion = false;
  String ringtone = 'System default';
  Map<String, dynamic> status = {};
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    enabled = (await LocalStore.instance.setting('niya_enabled')) == 'true';
    hideSeconds =
        int.tryParse(
          await LocalStore.instance.setting('hide_seconds') ?? '10',
        ) ??
        10;
    size =
        int.tryParse(await LocalStore.instance.setting('pet_size') ?? '72') ??
        72;
    opacity =
        double.tryParse(
          await LocalStore.instance.setting('pet_opacity') ?? '0.5',
        )?.clamp(.2, .8).toDouble() ??
        .5;
    lead =
        int.tryParse(
          await LocalStore.instance.setting('lead_seconds') ?? '10',
        ) ??
        10;
    privacy = await LocalStore.instance.setting('lock_privacy') ?? 'private';
    preferredEdge =
        await LocalStore.instance.setting('preferred_edge') ?? 'auto';
    animations =
        (await LocalStore.instance.setting('animations_enabled')) != 'false';
    taskPopup =
        (await LocalStore.instance.setting('task_popup_enabled')) != 'false';
    celebration =
        (await LocalStore.instance.setting('celebration_enabled')) != 'false';
    lockReminders =
        (await LocalStore.instance.setting('lock_reminders_enabled')) !=
        'false';
    lockScreenPet =
        (await LocalStore.instance.setting('lockscreen_pet_enabled')) !=
        'false';
    batterySaver =
        (await LocalStore.instance.setting('battery_saver')) == 'true';
    reducedMotion =
        (await LocalStore.instance.setting('reduced_motion')) == 'true';
    try {
      status = Map<String, dynamic>.from(
        await taskiyaNative.invokeMethod<Map>('getStatus') ?? {},
      );
      ringtone = '${status['ringtone'] ?? 'System default'}';
      final savedKind = '${status['petKind'] ?? 'niya'}';
      petKind = petNames.containsKey(savedKind) ? savedKind : 'niya';
      customPetPath = status['customPetPath'] as String?;
    } on PlatformException {
      /* Native feature may be unavailable on this device. */
    }
    if (mounted) setState(() {});
  }

  Future<void> option(String key, Object value) async {
    await LocalStore.instance.setSetting(key, '$value');
    try {
      await taskiyaNative.invokeMethod('setOption', {
        'key': key,
        'value': value,
      });
    } on PlatformException {
      /* Native feature may be unavailable on this device. */
    }
    if (mounted) setState(() {});
  }

  Future<void> toggle(bool value) async {
    if (value) {
      try {
        await taskiyaNative.invokeMethod('startNiya');
      } on PlatformException {
        /* Native feature may be unavailable on this device. */
      }
    } else {
      try {
        await taskiyaNative.invokeMethod('stopNiya');
      } on PlatformException {
        /* Native feature may be unavailable on this device. */
      }
    }
    enabled = value;
    await option('niya_enabled', value);
    await load();
  }

  Future<void> choosePetPhoto() async {
    if (importingPet) return;
    setState(() => importingPet = true);
    try {
      final path = await taskiyaNative.invokeMethod<String>('pickPetPhoto');
      if (path != null) {
        customPetPath = path;
        petKind = 'custom';
        await load();
      }
    } on PlatformException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error.message ?? 'Could not stylize this photo.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => importingPet = false);
    }
  }

  Future<void> selectPet(String kind) async {
    try {
      await taskiyaNative.invokeMethod('setPetKind', {'kind': kind});
      await load();
    } on PlatformException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message ?? 'Could not switch pet.')),
        );
      }
    }
  }

  Future<void> removeCustomPet() async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove custom pet?'),
        content: const Text(
          'This deletes the stylized pet saved by DAYNIX. The original photo in your gallery is untouched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (remove != true) return;
    try {
      await taskiyaNative.invokeMethod('deletePetPhoto');
      await load();
    } on PlatformException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message ?? 'Could not remove the pet.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Pet assistant')),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 30),
      children: [
        Center(
          child: customPetPath != null && petKind == 'custom'
              ? Image.file(
                  File(customPetPath!),
                  key: ValueKey(customPetPath),
                  height: 150,
                  errorBuilder: (context, error, stackTrace) =>
                      const Icon(Icons.pets, size: 90),
                )
              : Image.asset(
                  petAssets[petKind] ?? 'assets/niya_idle.png',
                  height: 150,
                ),
        ),
        Center(
          child: Text(
            petNames[petKind] ?? 'NIYA',
            style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
          ),
        ),
        const SizedBox(height: 10),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Choose your pet',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Choose NIYA, Titta, Luna, Kleg, Momo, or a pet photo from your phone.',
                ),
                const SizedBox(height: 14),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final cardWidth = (constraints.maxWidth - 16) / 3;
                    return Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: petNames.entries.map((entry) {
                        final selected = petKind == entry.key;
                        final hasPhoto = customPetPath != null;
                        final image = entry.key == 'custom'
                            ? hasPhoto
                                  ? Image.file(
                                      File(customPetPath!),
                                      height: 72,
                                      fit: BoxFit.contain,
                                      errorBuilder: (_, _, _) => const Icon(
                                        Icons.add_photo_alternate_outlined,
                                        size: 54,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.add_photo_alternate_outlined,
                                      size: 54,
                                    )
                            : Image.asset(
                                petAssets[entry.key]!,
                                height: 72,
                                fit: BoxFit.contain,
                              );
                        return SizedBox(
                          width: cardWidth,
                          child: Material(
                            color: selected
                                ? Theme.of(context).colorScheme.primaryContainer
                                : Theme.of(context)
                                      .colorScheme
                                      .surfaceContainer,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                              side: BorderSide(
                                color: selected
                                    ? Theme.of(context).colorScheme.primary
                                    : Theme.of(context)
                                          .colorScheme
                                          .outlineVariant,
                                width: selected ? 2 : 1,
                              ),
                            ),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: () => entry.key == 'custom' && !hasPhoto
                                  ? choosePetPhoto()
                                  : selectPet(entry.key),
                              child: Padding(
                                padding: const EdgeInsets.all(8),
                                child: Column(
                                  children: [
                                    image,
                                    const SizedBox(height: 4),
                                    Text(
                                      entry.value,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    );
                  },
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: importingPet ? null : choosePetPhoto,
                  icon: importingPet
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add_photo_alternate_outlined),
                  label: Text(
                    importingPet
                        ? 'Styling photo…'
                        : customPetPath == null
                        ? 'Choose a pet photo'
                        : 'Replace pet photo',
                  ),
                ),
                if (customPetPath != null)
                  TextButton.icon(
                    onPressed: removeCustomPet,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Remove custom pet'),
                  ),
                const Text(
                  'NIYA, Titta, Luna, Kleg, and Momo have matching idle, blink, happy, walking, running, sleeping, peeking, reminder, completion, sad, thinking, and waving poses. Custom photos use a single portrait. Your photo stays on this phone.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          title: const Text('Enable floating pet'),
          subtitle: const Text(
            'Show the pet above other apps after granting overlay access.',
          ),
          value: enabled,
          onChanged: toggle,
        ),
        ListTile(
          title: const Text('Overlay permission'),
          subtitle: Text(
            status['overlay'] == true ? 'Granted' : 'Needed for floating NIYA',
          ),
          trailing: const Icon(Icons.open_in_new),
          onTap: () async {
            try {
              await taskiyaNative.invokeMethod('startNiya');
            } on PlatformException {
              /* Native feature may be unavailable on this device. */
            }
            await load();
          },
        ),
        ListTile(
          title: const Text('Notification permission'),
          subtitle: Text(
            status['notifications'] == true
                ? 'Granted'
                : 'Tap to request reminder permission',
          ),
          onTap: () async {
            try {
              await taskiyaNative.invokeMethod('requestNotifications');
            } on PlatformException {
              /* Native feature may be unavailable on this device. */
            }
            await load();
          },
        ),
        ListTile(
          title: const Text('Precise alarm access'),
          subtitle: Text(
            status['exactAlarms'] == true
                ? 'Available'
                : 'Inexact reminders are used until access is granted',
          ),
          onTap: () async {
            try {
              await taskiyaNative.invokeMethod('requestExactAlarms');
            } on PlatformException {
              /* Native feature may be unavailable on this device. */
            }
            await load();
          },
        ),
        const Divider(),
        Text('Auto-hide after $hideSeconds seconds'),
        Slider(
          value: hideSeconds.toDouble(),
          min: 3,
          max: 60,
          divisions: 57,
          label: '$hideSeconds s',
          onChanged: (v) => setState(() => hideSeconds = v.round()),
          onChangeEnd: (v) => option('hide_seconds', v.round()),
        ),
        Text('Character size: $size dp'),
        Slider(
          value: size.toDouble(),
          min: 48,
          max: 120,
          divisions: 18,
          label: '$size dp',
          onChanged: (v) => setState(() => size = v.round()),
          onChangeEnd: (v) => option('pet_size', v.round()),
        ),
        Text('Idle opacity: ${(opacity * 100).round()}% (active: 100%)'),
        Slider(
          value: opacity,
          min: .2,
          max: .8,
          divisions: 6,
          onChanged: (v) => setState(() => opacity = v),
          onChangeEnd: (v) => option('pet_opacity', v),
        ),
        DropdownButtonFormField<String>(
          key: ValueKey(preferredEdge),
          initialValue: preferredEdge,
          decoration: const InputDecoration(labelText: 'Preferred screen edge'),
          items: const [
            DropdownMenuItem(value: 'auto', child: Text('Nearest edge')),
            DropdownMenuItem(value: 'left', child: Text('Left')),
            DropdownMenuItem(value: 'right', child: Text('Right')),
          ],
          onChanged: (v) async {
            if (v != null) {
              preferredEdge = v;
              await option('preferred_edge', v);
            }
          },
        ),
        SwitchListTile(
          title: const Text('Character animations'),
          value: animations,
          onChanged: (v) async {
            animations = v;
            await option('animations_enabled', v);
          },
        ),
        SwitchListTile(
          title: const Text('Floating task popup'),
          value: taskPopup,
          onChanged: (v) async {
            taskPopup = v;
            await option('task_popup_enabled', v);
          },
        ),
        SwitchListTile(
          title: const Text('Task celebration'),
          value: celebration,
          onChanged: (v) async {
            celebration = v;
            await option('celebration_enabled', v);
          },
        ),
        SwitchListTile(
          title: const Text('Reduced motion'),
          value: reducedMotion,
          onChanged: (v) async {
            reducedMotion = v;
            await option('reduced_motion', v);
          },
        ),
        SwitchListTile(
          title: const Text('Battery saver'),
          subtitle: const Text('Skip periodic blinking.'),
          value: batterySaver,
          onChanged: (v) async {
            batterySaver = v;
            await option('battery_saver', v);
          },
        ),
        const Divider(),
        Text('Reminder lead: $lead seconds'),
        Slider(
          value: lead.toDouble(),
          min: 0,
          max: 60,
          divisions: 60,
          onChanged: (v) => setState(() => lead = v.round()),
          onChangeEnd: (v) => option('lead_seconds', v.round()),
        ),
        DropdownButtonFormField<String>(
          key: ValueKey(privacy),
          initialValue: privacy,
          decoration: const InputDecoration(labelText: 'Lock screen privacy'),
          items: const [
            DropdownMenuItem(value: 'show', child: Text('Show task details')),
            DropdownMenuItem(
              value: 'private',
              child: Text('Hide sensitive details'),
            ),
            DropdownMenuItem(
              value: 'hidden',
              child: Text('Hide on lock screen'),
            ),
          ],
          onChanged: (v) {
            if (v != null) {
              privacy = v;
              option('lock_privacy', v);
            }
          },
        ),
        SwitchListTile(
          title: const Text('Lock screen reminders'),
          value: lockReminders,
          onChanged: (v) async {
            lockReminders = v;
            await option('lock_reminders_enabled', v);
          },
        ),
        SwitchListTile(
          title: const Text('Show NIYA on lock screen'),
          subtitle: const Text(
            'Show NIYA’s avatar in an ongoing notification while floating mode is enabled. Your phone’s lock-screen notification settings control visibility.',
          ),
          value: lockScreenPet,
          onChanged: (v) async {
            lockScreenPet = v;
            await option('lockscreen_pet_enabled', v);
          },
        ),
        ListTile(
          title: const Text('Custom reminder ringtone'),
          subtitle: Text(
            ringtone,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.music_note),
          onTap: () async {
            try {
              final value = await taskiyaNative.invokeMethod<String>(
                'pickRingtone',
              );
              if (value != null && mounted) setState(() => ringtone = value);
            } on PlatformException {
              /* Native feature may be unavailable on this device. */
            }
          },
        ),
        const Divider(),
        FilledButton.icon(
          onPressed: enabled
              ? () async {
                  await taskiyaNative.invokeMethod('startNiya');
                  await load();
                }
              : null,
          icon: const Icon(Icons.refresh),
          label: const Text('Restart NIYA'),
        ),
        OutlinedButton.icon(
          onPressed: enabled
              ? () async {
                  await taskiyaNative.invokeMethod('pauseNiya');
                  await load();
                }
              : null,
          icon: const Icon(Icons.visibility_off),
          label: Text(
            status['niyaPaused'] == true
                ? 'NIYA is paused'
                : 'Hide NIYA temporarily',
          ),
        ),
        TextButton.icon(
          onPressed: enabled ? () => toggle(false) : null,
          icon: const Icon(Icons.power_settings_new),
          label: const Text('Disable NIYA completely'),
        ),
        const Text(
          'Floating mode runs as a visible Android service while enabled. Android may restrict its restoration after force stop, reboot, or battery optimization. Reminders fall back to notifications when the overlay is unavailable.',
          style: TextStyle(fontSize: 12),
        ),
      ],
    ),
  );
}
