import 'package:flutter/material.dart';

/// Applies a formatting command to the selected note text.
TextEditingValue formatNoteText(TextEditingValue value, String command) {
  final source = value.text;
  final selection = value.selection.isValid
      ? value.selection
      : TextSelection.collapsed(offset: source.length);
  final start = selection.start.clamp(0, source.length);
  final end = selection.end.clamp(start, source.length);
  final selected = source.substring(start, end);

  String insert;
  int cursorStart;
  int cursorEnd;
  switch (command) {
    case 'heading':
    case 'subheading':
    case 'body':
    case 'bullet':
    case 'numbered':
      final lineStart = start == 0
          ? 0
          : source.lastIndexOf('\n', start - 1) + 1;
      final lineEnd = source.indexOf('\n', lineStart);
      final actualEnd = lineEnd < 0 ? source.length : lineEnd;
      final line = source.substring(lineStart, actualEnd);
      final clean = line.replaceFirst(RegExp(r'^(#{1,2} |[-] |\d+\. )'), '');
      final prefix = switch (command) {
        'heading' => '# ',
        'subheading' => '## ',
        'bullet' => '- ',
        'numbered' => '1. ',
        _ => '',
      };
      insert = '$prefix$clean';
      cursorStart = lineStart + insert.length;
      return TextEditingValue(
        text: source.replaceRange(lineStart, actualEnd, insert),
        selection: TextSelection.collapsed(offset: cursorStart),
      );
    case 'table':
      insert = '| Column 1 | Column 2 |\n| --- | --- |\n| Cell | Cell |';
      cursorStart = start;
      cursorEnd = start + insert.length;
      break;
    default:
      final wrapper = switch (command) {
        'bold' => ('**', '**', 'bold text'),
        'italic' => ('*', '*', 'italic text'),
        'strike' => ('~~', '~~', 'struck text'),
        'size14' => ('<size=14>', '</size>', 'small text'),
        'size18' => ('<size=18>', '</size>', 'text'),
        'size24' => ('<size=24>', '</size>', 'large text'),
        _ => ('', '', ''),
      };
      if (wrapper.$3.isEmpty) return value;
      final content = selected.isEmpty ? wrapper.$3 : selected;
      insert = '${wrapper.$1}$content${wrapper.$2}';
      cursorStart = start + wrapper.$1.length;
      cursorEnd = cursorStart + content.length;
  }
  return TextEditingValue(
    text: source.replaceRange(start, end, insert),
    selection: TextSelection(baseOffset: cursorStart, extentOffset: cursorEnd),
  );
}

String plainNotePreview(String value) => value
    .replaceAll(RegExp(r'<size=\d+>|</size>|\*\*|~~'), '')
    .replaceAll(RegExp(r'^#{1,2} |^- |^\d+\. ', multiLine: true), '')
    .replaceAll('|', ' ')
    .trim();

class NoteMarkupPreview extends StatelessWidget {
  const NoteMarkupPreview(this.source, {super.key});
  final String source;

  List<TextSpan> inline(String line, Color color) {
    final pattern = RegExp(
      r'(\*\*[^*]+\*\*|~~[^~]+~~|\*[^*]+\*|<size=(14|18|24)>.*?</size>)',
    );
    final spans = <TextSpan>[];
    var position = 0;
    for (final match in pattern.allMatches(line)) {
      if (match.start > position) {
        spans.add(TextSpan(text: line.substring(position, match.start)));
      }
      final token = match.group(0)!;
      if (token.startsWith('**')) {
        spans.add(
          TextSpan(
            text: token.substring(2, token.length - 2),
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        );
      } else if (token.startsWith('~~')) {
        spans.add(
          TextSpan(
            text: token.substring(2, token.length - 2),
            style: const TextStyle(decoration: TextDecoration.lineThrough),
          ),
        );
      } else if (token.startsWith('*')) {
        spans.add(
          TextSpan(
            text: token.substring(1, token.length - 1),
            style: const TextStyle(fontStyle: FontStyle.italic),
          ),
        );
      } else {
        final size = double.parse(match.group(2)!);
        spans.add(
          TextSpan(
            text: token.substring(token.indexOf('>') + 1, token.length - 7),
            style: TextStyle(fontSize: size),
          ),
        );
      }
      position = match.end;
    }
    if (position < line.length) {
      spans.add(TextSpan(text: line.substring(position)));
    }
    return [
      TextSpan(
        style: TextStyle(color: color, fontSize: 16),
        children: spans,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (source.trim().isEmpty) {
      return const Text('Your formatted note appears here.');
    }
    final color = Theme.of(context).colorScheme.onSurface;
    final lines = source.split('\n');
    final blocks = <Widget>[];
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      if (line.startsWith('|') &&
          index + 1 < lines.length &&
          lines[index + 1].startsWith('|')) {
        final tableLines = <String>[];
        while (index < lines.length && lines[index].startsWith('|')) {
          tableLines.add(lines[index]);
          index++;
        }
        index--;
        blocks.add(
          Table(
            border: TableBorder.all(
              color: Theme.of(context).colorScheme.outline,
            ),
            children: tableLines
                .where((row) => !RegExp(r'^\|[\s\-|]+\|$').hasMatch(row))
                .map((row) {
                  final cells = row
                      .split('|')
                      .skip(1)
                      .take(row.split('|').length - 2);
                  return TableRow(
                    children: cells
                        .map(
                          (cell) => Padding(
                            padding: const EdgeInsets.all(8),
                            child: Text(cell.trim()),
                          ),
                        )
                        .toList(),
                  );
                })
                .toList(),
          ),
        );
        continue;
      }
      final heading = line.startsWith('# ')
          ? 28.0
          : line.startsWith('## ')
          ? 22.0
          : 16.0;
      final text = line.replaceFirst(RegExp(r'^(#{1,2} |[-] |\d+\. )'), '');
      final leading = line.startsWith('- ')
          ? '•  '
          : RegExp(r'^\d+\. ').hasMatch(line)
          ? '${line.split('.').first}.  '
          : '';
      blocks.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 7),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: leading),
                ...inline(text, color),
              ],
            ),
            style: TextStyle(
              fontSize: heading,
              fontWeight: heading > 16 ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: blocks,
    );
  }
}
