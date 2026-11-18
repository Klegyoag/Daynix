/// Returns the next due instant, preserving the selected local wall-clock time.
DateTime? nextOccurrence(DateTime current, String rule, DateTime now) {
  if (rule == 'none') return null;
  final weekdays = switch (rule) {
    'weekdays' => {1, 2, 3, 4, 5},
    _ when rule.startsWith('custom:') =>
      rule
          .substring(7)
          .split(',')
          .map(int.tryParse)
          .whereType<int>()
          .where((v) => v >= 1 && v <= 7)
          .toSet(),
    _ => <int>{},
  };
  if (rule == 'daily' || rule == 'weekdays' || weekdays.isNotEmpty) {
    var candidate = DateTime(
      current.year,
      current.month,
      current.day + 1,
      current.hour,
      current.minute,
      current.second,
    );
    for (var i = 0; i < 3660; i++) {
      if (candidate.isAfter(now) &&
          (rule == 'daily' || weekdays.contains(candidate.weekday))) {
        return candidate;
      }
      candidate = DateTime(
        candidate.year,
        candidate.month,
        candidate.day + 1,
        current.hour,
        current.minute,
        current.second,
      );
    }
    return null;
  }
  if (rule == 'weekly') {
    var candidate = DateTime(
      current.year,
      current.month,
      current.day + 7,
      current.hour,
      current.minute,
      current.second,
    );
    while (!candidate.isAfter(now)) {
      candidate = DateTime(
        candidate.year,
        candidate.month,
        candidate.day + 7,
        current.hour,
        current.minute,
        current.second,
      );
    }
    return candidate;
  }
  if (rule == 'monthly') {
    var year = current.year;
    var month = current.month;
    for (var i = 0; i < 120; i++) {
      month++;
      if (month > 12) {
        month = 1;
        year++;
      }
      final last = DateTime(year, month + 1, 0).day;
      final day = current.day > last ? last : current.day;
      final candidate = DateTime(
        year,
        month,
        day,
        current.hour,
        current.minute,
        current.second,
      );
      if (candidate.isAfter(now)) return candidate;
    }
  }
  return null;
}
