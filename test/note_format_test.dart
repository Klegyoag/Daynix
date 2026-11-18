import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_productivity_app/note_format.dart';

void main() {
  test('formatting selected text preserves surrounding content', () {
    const input = TextEditingValue(
      text: 'one two three',
      selection: TextSelection(baseOffset: 4, extentOffset: 7),
    );
    final result = formatNoteText(input, 'bold');
    expect(result.text, 'one **two** three');
    expect(
      result.text.substring(result.selection.start, result.selection.end),
      'two',
    );
  });

  test('headings and lists change only the current line', () {
    const input = TextEditingValue(
      text: 'First\nSecond',
      selection: TextSelection.collapsed(offset: 8),
    );
    expect(formatNoteText(input, 'heading').text, 'First\n# Second');
    expect(formatNoteText(input, 'bullet').text, 'First\n- Second');
  });

  test('table template and plain preview keep note content readable', () {
    const input = TextEditingValue(
      text: '',
      selection: TextSelection.collapsed(offset: 0),
    );
    expect(
      formatNoteText(input, 'table').text,
      contains('| Column 1 | Column 2 |'),
    );
    expect(
      plainNotePreview('# Title\n**bold** and ~~old~~'),
      'Title\nbold and old',
    );
  });

  testWidgets('formatted preview renders a table and inline emphasis', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: NoteMarkupPreview(
            '# Heading\n**Bold**\n| A | B |\n| --- | --- |\n| 1 | 2 |',
          ),
        ),
      ),
    );
    expect(find.textContaining('Heading'), findsOneWidget);
    expect(find.textContaining('Bold'), findsOneWidget);
    expect(find.byType(Table), findsOneWidget);
  });
}
