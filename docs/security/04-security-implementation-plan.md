# Security implementation plan

1. Preserve offline data and app upgrade path. Set public version to 1.0.0 while retaining monotonically increasing Android versionCode 16 to install over prior test builds without data loss.
2. Protect UI access with optional Android device credential authentication on app and pet AI popup.
3. Integrate optional Firebase email account operations once a matching project configuration and Email/Password provider are enabled. Do not claim account-scoped task storage or synchronization.
4. Authenticate widget action PendingIntents and disable automatic Android backup of local data.
5. Minimize Gemini request data; keep the user-supplied key in platform-backed secure storage.
6. Verify tests, build, manifest, signing, device flows and negative widget broadcast behavior.
7. For production: private signing, obfuscated release build with private symbols, and a deliberate encryption/sync architecture if cloud accounts must own task data.
