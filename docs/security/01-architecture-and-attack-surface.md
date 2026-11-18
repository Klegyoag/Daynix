# Architecture and attack surface

DAYNIX is an Android-first Flutter 3.47.7 / Dart 3.13.5 app with Kotlin Android widgets, alarms, and a user-enabled floating pet service. SQLite through `sqflite` is the local source of truth. Native Kotlin code opens the same database for widgets and alarms. There is no DAYNIX backend, payment system, or active iOS target in this source tree. The only network flows are user-initiated Gemini chat over HTTPS and optional Firebase Authentication when configured. The Gemini key is stored with `flutter_secure_storage`, not in source.

The phone app lock uses Android device authentication through `local_auth`. It is a screen privacy gate; it does not encrypt SQLite or authorize widget actions. The optional Firebase account is identity only: local tasks and notes are neither uploaded nor isolated by account. Signing out does not delete local data.

Trust boundaries: Flutter UI ↔ Android MethodChannel; exported widget receivers ↔ external apps/launcher; local SQLite ↔ device access/backup; app ↔ Google Gemini; app ↔ Firebase Auth. Inputs include widget broadcasts, voice transcription, task/note text, imported images and attachments, and Gemini function calls. Task deletion still requires user confirmation.

Main attack surfaces: exported widget receivers, overlay permission, notification actions, local database, secure key storage, attachment intents, Gemini request payload, optional Firebase sign-in, and Android backup. A malicious app on the same device can send exported broadcasts; an attacker with physical or rooted device access has stronger access to local data. See the threat model and findings below.
