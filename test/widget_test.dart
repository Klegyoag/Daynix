import 'package:flutter_test/flutter_test.dart';
import 'package:personal_productivity_app/main.dart';

void main() {
  test('formatDate uses a stable weekday and month label', () {
    expect(formatDate(DateTime(2026, 10, 26)), 'Mon, Oct 26');
  });

  test(
    'focus countdown uses wall time and stops at zero after backgrounding',
    () {
      final end = DateTime(2026, 10, 28, 12, 25);
      expect(
        focusSecondsRemaining(end, DateTime(2026, 10, 28, 12, 0), 1500),
        1500,
      );
      expect(
        focusSecondsRemaining(end, DateTime(2026, 10, 28, 12, 10), 1500),
        900,
      );
      expect(
        focusSecondsRemaining(end, DateTime(2026, 10, 28, 12, 30), 1500),
        0,
      );
    },
  );

  test('habit streak accepts yesterday but stops at a missed day', () {
    final today = DateTime(2026, 10, 28);
    expect(habitStreak({'2026-10-25', '2026-10-26', '2026-10-27'}, today), 3);
    expect(habitStreak({'2026-10-25', '2026-10-26'}, today), 0);
    expect(habitStreak({'2026-10-27', '2026-10-28'}, today), 2);
  });

  test('insights count stored task creation dates by selected period', () {
    final now = DateTime(2026, 10, 28);
    final tasks = <Map<String, Object?>>[
      {'createdAt': '2026-10-01T09:00:00', 'completed': 1},
      {'createdAt': '2026-10-26T10:00:00', 'completed': 1},
      {'createdAt': '2026-10-28T12:00:00', 'completed': 0},
      {'createdAt': '2026-11-01T08:00:00', 'completed': 0},
    ];
    expect(
      tasks.where((task) => taskCreatedInPeriod(task, 'week', now)),
      hasLength(3),
    );
    expect(
      insightCreationBars(tasks, 'week', now).map((bar) => bar.count).toList(),
      [1, 0, 1, 0, 0, 0, 1],
    );
    expect(
      insightCreationBars(
        tasks,
        'month',
        now,
      ).fold<int>(0, (sum, bar) => sum + bar.count),
      3,
    );
  });
}
