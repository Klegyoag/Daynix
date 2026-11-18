import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/material.dart';
import 'package:personal_productivity_app/main.dart';
import 'package:personal_productivity_app/recurrence.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('tasks, subtasks, settings and deletion persist in SQLite', () async {
    await LocalStore.instance.open(path: inMemoryDatabasePath);
    try {
      final store = LocalStore.instance;
      await store.createTask(
        {
          'title': '  Finish report  ',
          'priority': 3,
          'dueAt': '2026-11-01T12:00:00.000',
        },
        ['Draft', 'Review', 'Review'],
      );
      final tasks = await store.read('tasks');
      expect(tasks, hasLength(1));
      final id = tasks.single['id'] as String;
      expect(tasks.single['title'], 'Finish report');
      expect(tasks.single['priority'], 3);
      expect(
        await store.read('subtasks', where: 'taskId=?', args: [id]),
        hasLength(3),
      );

      await store.updateTask(
        id,
        {'title': 'Send report', 'priority': 2, 'dueAt': '2026-11-02'},
        ['Attach PDF'],
      );
      expect((await store.read('tasks')).single['title'], 'Send report');
      expect(
        await store.read('subtasks', where: 'taskId=?', args: [id]),
        hasLength(1),
      );

      await store.setSetting('widget_theme', 'dark');
      expect(await store.setting('widget_theme'), 'dark');
      await store.deleteTask(id);
      expect(await store.read('tasks'), isEmpty);
      expect(await store.read('subtasks'), isEmpty);
    } finally {
      await LocalStore.instance.db.close();
    }
  });

  test('invalid task titles are rejected without writing a row', () async {
    await LocalStore.instance.open(path: inMemoryDatabasePath);
    try {
      await expectLater(
        LocalStore.instance.createTask({'title': '   '}, []),
        throwsArgumentError,
      );
      expect(await LocalStore.instance.read('tasks'), isEmpty);
    } finally {
      await LocalStore.instance.db.close();
    }
  });

  test('clearing progress removes habit check-in history', () async {
    await LocalStore.instance.open(path: inMemoryDatabasePath);
    try {
      final store = LocalStore.instance;
      await store.db.insert('habits', {
        'id': 'habit-1',
        'title': 'Read',
        'doneDay': '2026-10-28',
      });
      await store.db.insert('habit_entries', {
        'habitId': 'habit-1',
        'day': '2026-10-28',
      });
      await store.clearProgress();
      expect(await store.read('habit_entries'), isEmpty);
      expect((await store.read('habits')).single['doneDay'], isNull);
    } finally {
      await LocalStore.instance.db.close();
    }
  });

  test('schema v1 upgrades to v5 without losing tasks and notes', () async {
    final dir = await Directory.systemTemp.createTemp('taskiya_migration_');
    final path = '${dir.path}${Platform.pathSeparator}productivity.db';
    try {
      final old = await openDatabase(
        path,
        version: 1,
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
          await db.insert('tasks', {
            'id': 'old-task',
            'title': 'Keep me',
            'createdAt': '2026-01-01',
          });
          await db.insert('notes', {
            'id': 'old-note',
            'title': 'Keep note',
            'body': 'Saved',
            'updatedAt': '2026-01-01',
          });
          await db.insert('habits', {
            'id': 'old-habit',
            'title': 'Read',
            'doneDay': '2026-10-27',
          });
        },
      );
      await old.close();

      await LocalStore.instance.open(path: path);
      expect(await LocalStore.instance.db.getVersion(), 5);
      expect(await LocalStore.instance.read('ai_chat_messages'), isEmpty);
      expect(
        (await LocalStore.instance.read('tasks')).single['title'],
        'Keep me',
      );
      expect((await LocalStore.instance.read('notes')).single['body'], 'Saved');
      await LocalStore.instance.db.insert('note_photos', {
        'id': 'photo-1',
        'noteId': 'old-note',
        'path': '/private/note.jpg',
        'addedAt': '2026-11-04',
      });
      expect(
        (await LocalStore.instance.read('note_photos')).single['path'],
        '/private/note.jpg',
      );
      expect(
        (await LocalStore.instance.read('habit_entries')).single['day'],
        '2026-10-27',
      );
      final taskColumns = (await LocalStore.instance.db.rawQuery(
        'PRAGMA table_info(tasks)',
      )).map((c) => c['name']);
      expect(
        taskColumns,
        containsAll([
          'project',
          'labels',
          'location',
          'reminderEnabled',
          'recurrence',
        ]),
      );
      await LocalStore.instance.setSetting('theme_mode', 'dark');
      expect(await LocalStore.instance.setting('theme_mode'), 'dark');
      await LocalStore.instance.db.close();
    } finally {
      await deleteDatabase(path);
      await dir.delete(recursive: true);
    }
  });

  test(
    'editing a note keeps attached photos with foreign keys enabled',
    () async {
      await LocalStore.instance.open(path: inMemoryDatabasePath);
      try {
        final store = LocalStore.instance;
        await store.db.execute('PRAGMA foreign_keys=ON');
        await store.upsertNote({
          'id': 'note-with-photo',
          'title': 'Trip',
          'body': 'First draft',
          'updatedAt': '2026-11-04',
          'pinned': 0,
          'folder': '',
        });
        await store.db.insert('note_photos', {
          'id': 'photo-1',
          'noteId': 'note-with-photo',
          'path': '/private/photo.jpg',
          'addedAt': '2026-11-04',
        });
        await store.upsertNote({
          'id': 'note-with-photo',
          'title': 'Trip plans',
          'body': 'Revised',
          'updatedAt': '2026-11-04',
          'pinned': 1,
          'folder': '',
        });
        expect((await store.read('notes')).single['body'], 'Revised');
        expect(
          (await store.read('note_photos')).single['path'],
          '/private/photo.jpg',
        );
      } finally {
        await LocalStore.instance.db.close();
      }
    },
  );

  test('repeat rules preserve local time and skip excluded weekdays', () {
    final friday = DateTime(2026, 10, 30, 9, 15);
    expect(
      nextOccurrence(friday, 'daily', friday),
      DateTime(2026, 10, 31, 9, 15),
    );
    expect(
      nextOccurrence(friday, 'weekdays', friday),
      DateTime(2026, 11, 2, 9, 15),
    );
    expect(
      nextOccurrence(friday, 'custom:2,4', friday),
      DateTime(2026, 11, 3, 9, 15),
    );
    expect(
      nextOccurrence(friday, 'weekly', friday),
      DateTime(2026, 11, 6, 9, 15),
    );
    expect(
      nextOccurrence(
        DateTime(2026, 1, 31, 9),
        'monthly',
        DateTime(2026, 1, 31, 9),
      ),
      DateTime(2026, 2, 28, 9),
    );
  });

  test(
    'completing a repeating task records an occurrence and keeps it open',
    () async {
      await LocalStore.instance.open(path: inMemoryDatabasePath);
      try {
        final store = LocalStore.instance;
        final tomorrow = DateTime.now().add(const Duration(days: 1));
        final scheduled = DateTime(
          tomorrow.year,
          tomorrow.month,
          tomorrow.day,
          8,
        );
        await store.createTask({
          'title': 'Stretch',
          'dueAt': scheduled.toIso8601String(),
          'recurrence': 'daily',
        }, []);
        final task = (await store.read('tasks')).single;
        await store.setTaskCompleted(task, true);
        final updated = (await store.read('tasks')).single;
        expect(updated['completed'], 0);
        expect(
          updated['dueAt'],
          scheduled.add(const Duration(days: 1)).toIso8601String(),
        );
        expect(await store.read('task_occurrences'), hasLength(1));
      } finally {
        await LocalStore.instance.db.close();
      }
    },
  );

  testWidgets('enabled device lock conceals the app navigation', (
    tester,
  ) async {
    await LocalStore.instance.open(path: inMemoryDatabasePath);
    FlutterSecureStorage.setMockInitialValues({
      'daynix_device_lock_enabled': 'true',
    });
    try {
      await tester.pumpWidget(const TaskiyaApp());
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('DAYNIX is locked'), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox());
      FlutterSecureStorage.setMockInitialValues({});
      await LocalStore.instance.db.close();
    }
  });

  testWidgets('note editor saves title and body when dismissed', (
    tester,
  ) async {
    await LocalStore.instance.open(path: inMemoryDatabasePath);
    try {
      await tester.pumpWidget(const TaskiyaApp());
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Notes'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Add note'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(1), 'Project idea');
      await tester.enterText(fields.at(2), 'Write the proposal');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      final notes = await LocalStore.instance.read('notes');
      expect(notes, hasLength(1));
      expect(notes.single['title'], 'Project idea');
      expect(notes.single['body'], 'Write the proposal');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await LocalStore.instance.db.close();
    }
  });
  testWidgets('photo remains attached after closing and reopening a note', (
    tester,
  ) async {
    await LocalStore.instance.open(path: inMemoryDatabasePath);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(taskiyaNative, (call) async {
      if (call.method == 'pickNotePhoto') return 'C:/fake/note-photo.jpg';
      if (call.method == 'deleteNotePhoto') return true;
      return null;
    });
    try {
      await tester.pumpWidget(const TaskiyaApp());
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Notes'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Add note'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(1), 'Photo note');
      await tester.ensureVisible(find.text('Add photo'));
      await tester.tap(find.text('Add photo'));
      await tester.pumpAndSettle();
      expect(await LocalStore.instance.read('note_photos'), hasLength(1));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Photo note').last);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Remove photo'), findsOneWidget);
      expect(await LocalStore.instance.read('note_photos'), hasLength(1));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      messenger.setMockMethodCallHandler(taskiyaNative, null);
      await LocalStore.instance.db.close();
    }
  });
}
