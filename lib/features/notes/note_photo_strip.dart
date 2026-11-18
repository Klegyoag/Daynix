import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';

/// Local photo copies attached to a note.
class NotePhotoStrip extends StatefulWidget {
  const NotePhotoStrip({
    super.key,
    required this.database,
    required this.noteId,
    required this.initialPhotos,
    required this.photoCount,
    required this.beforeAdd,
    required this.onChanged,
  });

  final Database database;
  final String noteId;
  final List<Map<String, Object?>> initialPhotos;
  final ValueNotifier<int> photoCount;
  final Future<void> Function() beforeAdd;
  final Future<void> Function() onChanged;

  @override
  State<NotePhotoStrip> createState() => _NotePhotoStripState();
}

class _NotePhotoStripState extends State<NotePhotoStrip> {
  static const _native = MethodChannel('taskiya/native');
  late final List<Map<String, Object?>> _photos = List.of(widget.initialPhotos);
  bool _busy = false;
  String? _error;

  Future<void> _add() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final path = await _native.invokeMethod<String>('pickNotePhoto');
      if (path == null || !mounted) return;
      await widget.beforeAdd();
      final now = DateTime.now();
      final row = <String, Object?>{
        'id': '${now.microsecondsSinceEpoch}_${_photos.length}',
        'noteId': widget.noteId,
        'path': path,
        'addedAt': now.toIso8601String(),
      };
      try {
        await widget.database.insert('note_photos', row);
      } catch (_) {
        await _deletePrivateFile(path);
        rethrow;
      }
      if (mounted) {
        setState(() => _photos.add(row));
        widget.photoCount.value = _photos.length;
      }
      await widget.onChanged();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error is PlatformException
              ? (error.message ?? 'Could not import this photo.')
              : 'Could not add this photo. Please try another image.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(Map<String, Object?> photo) async {
    await widget.database.delete(
      'note_photos',
      where: 'id=? AND noteId=?',
      whereArgs: [photo['id'], widget.noteId],
    );
    if (mounted) {
      setState(() => _photos.removeWhere((item) => item['id'] == photo['id']));
      widget.photoCount.value = _photos.length;
    }
    await _deletePrivateFile(photo['path'] as String);
    await widget.onChanged();
  }

  static Future<void> _deletePrivateFile(String path) async {
    try {
      await _native.invokeMethod<void>('deleteNotePhoto', {'path': path});
    } on PlatformException {
      // The database row remains deleted if file cleanup fails.
    } on MissingPluginException {
      // Android-only photo storage.
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: _busy ? null : _add,
        icon: const Icon(Icons.add_photo_alternate_outlined),
        label: const Text('Add photo'),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      if (_photos.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final photo in _photos)
                Stack(
                  children: [
                    InkWell(
                      onTap: () => showDialog<void>(
                        context: context,
                        builder: (_) => Dialog(
                          child: InteractiveViewer(
                            child: Image.file(
                              File(photo['path'] as String),
                              fit: BoxFit.contain,
                              errorBuilder: (_, _, _) => const Padding(
                                padding: EdgeInsets.all(24),
                                child: Text('Photo unavailable'),
                              ),
                            ),
                          ),
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: Image.file(
                          File(photo['path'] as String),
                          width: 96,
                          height: 96,
                          fit: BoxFit.cover,
                          cacheWidth: 288,
                          errorBuilder: (_, _, _) => const SizedBox(
                            width: 96,
                            height: 96,
                            child: Icon(Icons.broken_image_outlined),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 2,
                      right: 2,
                      child: IconButton.filledTonal(
                        tooltip: 'Remove photo',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => _remove(photo),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
    ],
  );
}
