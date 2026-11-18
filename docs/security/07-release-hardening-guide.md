# Release hardening

The current optimized APK is signed by the Android debug certificate for testing. It is not a production release. Set a private signing configuration outside source control before distribution; keep signing keys and passwords in a local secret store or CI secrets.

Production command: `flutter build apk --release --obfuscate --split-debug-info=build-symbols/android`. Keep symbols private and associate them with the exact APK/version for stack-trace symbolization. Dart obfuscation does not protect resources or embedded secrets. Verify R8, plugins, widgets, notifications and Firebase sign-in in the obfuscated build. Do not publish `build-symbols` in the source ZIP.

Use HTTPS and normal TLS validation. Gemini uses `Uri.https` with a 90-second timeout. Do not add certificate bypasses. Restrict the Firebase/Google API key as appropriate in Google Cloud, use Firebase App Check/Play Integrity only when a trusted backend can verify and act on results, and do not use a client-side integrity Boolean as authorization.
