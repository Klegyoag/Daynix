import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

import 'firebase_account.dart';

const _lockSetting = 'daynix_device_lock_enabled';
const _secure = FlutterSecureStorage();
final appLockEnabled = ValueNotifier<bool>(false);

/// UI privacy gate. Android's trusted device prompt verifies the credential.
/// This does not encrypt the SQLite database or protect home-screen widgets.
class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key, required this.child, this.popup = false});
  final Widget child;
  final bool popup;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  final _auth = LocalAuthentication();
  bool _checking = true;
  bool _enabled = false;
  bool _unlocked = false;
  bool _authenticating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    appLockEnabled.addListener(_settingChanged);
    unawaited(_load());
  }

  void _settingChanged() {
    if (!mounted) return;
    setState(() {
      _enabled = appLockEnabled.value;
      if (!_enabled) _unlocked = true;
    });
  }

  Future<void> _load() async {
    try {
      final enabled = await _secure.read(key: _lockSetting) == 'true';
      if (!mounted) return;
      appLockEnabled.value = enabled;
      setState(() {
        _enabled = enabled;
        _unlocked = !enabled;
        _checking = false;
      });
      if (enabled) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _checking = false;
          _enabled = true;
          _error = 'Device lock settings could not be read. Restart DAYNIX or check your phone security settings.';
        });
      }
    }
  }

  Future<void> _unlock() async {
    if (!mounted || _authenticating || !_enabled || _unlocked) return;
    setState(() {
      _authenticating = true;
      _error = null;
    });
    try {
      final available = await _auth.isDeviceSupported();
      if (!available) {
        if (mounted) {
          setState(
            () =>
                _error = 'Set up a screen lock on this phone to unlock DAYNIX.',
          );
        }
        return;
      }
      final ok = await _auth.authenticate(
        localizedReason: 'Unlock DAYNIX',
        persistAcrossBackgrounding: true,
      );
      if (mounted) {
        setState(() {
          _unlocked = ok;
          if (!ok) _error = 'Authentication was canceled or unsuccessful.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not verify your phone credential. Try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _authenticating = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_enabled || _authenticating || AppLockGateAuthentication.inProgress) {
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      if (mounted) setState(() => _unlocked = false);
    } else if (state == AppLifecycleState.resumed && !_unlocked) {
      unawaited(_unlock());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    appLockEnabled.removeListener(_settingChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_checking && (!_enabled || _unlocked)) return widget.child;
    final card = Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(28),
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_rounded, size: 48, color: Color(0xffff77ae)),
            const SizedBox(height: 18),
            const Text(
              'DAYNIX is locked',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              _error ?? 'Use your phone fingerprint, face, PIN, or pattern.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _checking || _authenticating ? null : _unlock,
              icon: _authenticating
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.fingerprint),
              label: const Text('Unlock'),
            ),
          ],
        ),
      ),
    );
    return ColoredBox(
      color: widget.popup
          ? Colors.black54
          : Theme.of(context).scaffoldBackgroundColor,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(padding: const EdgeInsets.all(24), child: card),
        ),
      ),
    );
  }
}

class AppSecurityPage extends StatefulWidget {
  const AppSecurityPage({super.key});
  @override
  State<AppSecurityPage> createState() => _AppSecurityPageState();
}

class _AppSecurityPageState extends State<AppSecurityPage> {
  final _auth = LocalAuthentication();
  bool _enabled = false;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final value = await _secure.read(key: _lockSetting) == 'true';
      if (mounted) {
        setState(() {
          _enabled = value;
          _busy = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggle(bool value) async {
    if (_busy) return;
    setState(() => _busy = true);
    AppLockGateAuthentication.inProgress = true;
    try {
      if (!await _auth.isDeviceSupported()) {
        throw StateError('Set up a phone screen lock first.');
      }
      final verified = await _auth.authenticate(
        localizedReason: value
            ? 'Enable DAYNIX app lock'
            : 'Disable DAYNIX app lock',
        persistAcrossBackgrounding: true,
      );
      if (!verified) return;
      if (value) {
        await _secure.write(key: _lockSetting, value: 'true');
      } else {
        await _secure.delete(key: _lockSetting);
      }
      appLockEnabled.value = value;
      if (mounted) setState(() => _enabled = value);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('App lock was not changed: $error')),
        );
      }
    } finally {
      AppLockGateAuthentication.inProgress = false;
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('DAYNIX security')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        SwitchListTile(
          title: const Text('Lock DAYNIX with your phone'),
          subtitle: const Text(
            'Require fingerprint, face, PIN, or pattern when opening DAYNIX or pet AI.',
          ),
          value: _enabled,
          onChanged: _busy ? null : _toggle,
        ),
        const SizedBox(height: 16),
        ListTile(
          leading: const Icon(Icons.account_circle_outlined),
          title: const Text('Online account'),
          subtitle: const Text('Firebase email sign-in (optional)'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const FirebaseAccountPage()),
          ),
        ),
        const SizedBox(height: 16),
        const ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('Your tasks stay on this phone'),
          subtitle: Text(
            'The app lock hides DAYNIX screens. Android widgets and lock-screen alarms can still show information; control them in widget and reminder settings.',
          ),
        ),
      ],
    ),
  );
}

class AppLockGateAuthentication {
  static bool inProgress = false;
}
