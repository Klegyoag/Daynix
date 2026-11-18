import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

/// Optional Firebase identity. Local DAYNIX data remains on this device and is
/// not uploaded or scoped to the signed-in account.
class FirebaseAccountPage extends StatefulWidget {
  const FirebaseAccountPage({super.key});
  @override
  State<FirebaseAccountPage> createState() => _FirebaseAccountPageState();
}

class _FirebaseAccountPageState extends State<FirebaseAccountPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  StreamSubscription<User?>? _changes;
  bool _loading = true;
  bool _configured = false;
  bool _busy = false;
  User? _user;
  String? _message;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      if (Firebase.apps.isEmpty) await Firebase.initializeApp();
      _changes = FirebaseAuth.instance.authStateChanges().listen((user) {
        if (mounted) setState(() => _user = user);
      });
      if (mounted) {
        setState(() {
          _configured = true;
          _user = FirebaseAuth.instance.currentUser;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _configured = false;
          _loading = false;
        });
      }
    }
  }

  Future<void> _run(Future<void> Function() operation, String success) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await operation();
      _password.clear();
      if (mounted) setState(() => _message = success);
    } on FirebaseAuthException catch (error) {
      if (mounted) {
        setState(
          () => _message = switch (error.code) {
            'weak-password' => 'Choose a stronger password.',
            'invalid-email' => 'Enter a valid email address.',
            'network-request-failed' =>
              'Connect to the internet and try again.',
            _ =>
              'Could not complete sign-in. Check your details and try again.',
          },
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = 'Account service is unavailable. Try again later.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signIn() => _run(() async {
    await FirebaseAuth.instance.signInWithEmailAndPassword(
      email: _email.text.trim(),
      password: _password.text,
    );
  }, 'Signed in to your Firebase account.');

  Future<void> _register() => _run(() async {
    final result = await FirebaseAuth.instance.createUserWithEmailAndPassword(
      email: _email.text.trim(),
      password: _password.text,
    );
    await result.user?.sendEmailVerification();
  }, 'Account created. Check your email to verify it.');

  Future<void> _resetPassword() => _run(() async {
    final email = _email.text.trim();
    if (email.isEmpty) throw const FormatException('Missing email');
    await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
  }, 'If that address has an account, a reset email will arrive.');

  @override
  void dispose() {
    _changes?.cancel();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('DAYNIX account')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Icon(Icons.shield_outlined, color: Color(0xffff77ae), size: 52),
        const SizedBox(height: 16),
        const Text(
          'Firebase account',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text(
          'An account is optional. Signing in does not upload or separate tasks and notes stored on this phone.',
        ),
        const SizedBox(height: 20),
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else if (!_configured)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(18),
              child: Text(
                'Firebase is not configured for this build. Add a google-services.json matching this Android package and enable Email/Password in Firebase Console, then rebuild DAYNIX.',
              ),
            ),
          )
        else if (_user != null) ...[
          Card(
            child: ListTile(
              leading: const Icon(Icons.account_circle_outlined),
              title: Text(_user!.email ?? 'Signed in'),
              subtitle: Text(
                _user!.emailVerified
                    ? 'Email verified'
                    : 'Verify your email address',
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (!_user!.emailVerified)
            OutlinedButton(
              onPressed: _busy
                  ? null
                  : () => _run(
                      () => _user!.sendEmailVerification(),
                      'Verification email requested.',
                    ),
              child: const Text('Send verification email'),
            ),
          FilledButton.tonal(
            onPressed: _busy
                ? null
                : () => _run(
                    () => FirebaseAuth.instance.signOut(),
                    'Signed out. Local tasks and notes stay on this device.',
                  ),
            child: const Text('Sign out'),
          ),
        ] else ...[
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(labelText: 'Email'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: true,
            autofillHints: const [AutofillHints.password],
            decoration: const InputDecoration(labelText: 'Password'),
          ),
          const SizedBox(height: 18),
          FilledButton(
            onPressed: _busy ? null : _signIn,
            child: const Text('Sign in'),
          ),
          OutlinedButton(
            onPressed: _busy ? null : _register,
            child: const Text('Create account'),
          ),
          TextButton(
            onPressed: _busy ? null : _resetPassword,
            child: const Text('Forgot password?'),
          ),
        ],
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(top: 18),
            child: Text(_message!, textAlign: TextAlign.center),
          ),
      ],
    ),
  );
}
