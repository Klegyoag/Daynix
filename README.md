# DAYNIX Flutter source

This directory contains the Flutter and native Android source for DAYNIX. The Android package ID remains `com.personalworkspace.personal_productivity_app` to preserve upgrades and local app data from the earlier build.

Build with:

```powershell
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
flutter build apk --release
```

The Android widgets, native quick capture dialogs, NIYA overlay, and reminders are in `android/app/src/main/kotlin/com/personalworkspace/personal_productivity_app/`. App source is in `lib/main.dart`; visual assets are in `assets/`.

Pet assistant settings can import a photo through Android's document picker. `CustomPet.kt` creates a private, offline cartoon-style sticker and `NiyaFrames.kt` selects it for the native overlay. The custom image is static; switching back to NIYA restores the original pose atlas.

The accompanying `../documentation/` folder records supported features, setup, and test results. The APKs are in `../apk/app-debug.apk` and `../apk/app-release-test-signed.apk`. Both use Android debug signing.



## Current release

DAYNIX displays version 1.0.0. Internal Android versionCode 16 permits upgrading the prior test installation with the same signing certificate. Tapping a floating pet opens the DAYNIX AI popup. Dictation uses the installed phone speech engine and AI replies can be spoken by Android text-to-speech. More -> Security & sign-in contains an optional phone credential lock and optional Firebase email account. Firebase requires a matching google-services.json and Email/Password setup; local tasks and notes do not sync to the account. See docs/security/ for the audit and limits.

Notes support multiple photos. Add photo uses Android's system image picker, saves an optimized private copy, and links it to the note through schema v5. No storage permission is required. The copies are removed when their photo or note is deleted.
