# External configuration

- Register Android package `com.personalworkspace.personal_productivity_app` in a Firebase project. Place matching `google-services.json` in `source/android/app/`; enable Email/Password in Firebase Authentication. Rebuild and test sign-in, registration, reset, verification and sign-out on a device. Firebase project identifiers in the config are public app configuration, not server-admin credentials.
- Decide whether account-specific cloud sync is required. Firebase Authentication alone does not store, upload or isolate tasks. Any Firestore/backend sync needs per-user authorization rules, migrations and offline conflict handling before claiming account-private data.
- Rotate/revoke any previously exposed Gemini API key. Enter its replacement inside DAYNIX AI settings; never put it into source, build arguments or screenshots.
- Provide private Android production signing credentials before a production release. Do not commit them.
- If Google Play Integrity is desired, enroll/distribute via Google Play and provide a backend for token verification. No backend exists in this project today.
