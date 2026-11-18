# Evidence-based findings

| ID | Severity | Evidence and prerequisite | Impact | Status |
|---|---|---|---|---|
| SEC-001 | High | `TaskiyaWidgets.kt`: exported widget receiver handled custom completion/filter broadcasts without authenticating their origin. Another installed app could send an explicit broadcast with a known task ID. | Unauthorized task completion or widget filter change. | Remediated with a random app-private action token in immutable widget PendingIntents; compile verification pending device test. |
| SEC-002 | Medium | `AndroidManifest.xml` previously omitted explicit backup/data extraction policy while SQLite stores task, note and chat text in plaintext. Device backup behavior depends on OS. | Potential exposure through backup/transfer. | `allowBackup=false`, full backup and data extraction exclusions added. APK manifest verification pending. |
| SEC-003 | Medium | `gemini_chat_service.dart` previously appended up to 50 task summaries to every Gemini request, including general questions. | Unnecessary disclosure of task titles/dates. | Removed automatic task attachment; task data is sent only when Gemini calls `listTasks`, and the gateway limits fields. Regression test added. |
| SEC-004 | Medium | `productivity.db` remains plaintext for Flutter and Kotlin widget access. Requires device/file access to exploit. | Local data disclosure on compromised devices or through unauthorized copies. | Open architectural risk; database encryption needs a shared native/Flutter key strategy and widget migration. |
| SEC-005 | Medium | `android/app/build.gradle.kts` release uses the debug signing certificate. | Test APK is unsuitable for production distribution. | Open until private production signing credentials are supplied. |
| SEC-006 | Medium | Firebase configuration and provider enablement are external. Account sign-in cannot authenticate against a project without them. | Online account feature unavailable in the current unconfigured build. | Integration UI and SDK added; project configuration pending. |
| SEC-007 | Low | Native widget and lock-screen alarm surfaces remain accessible when Flutter app lock is enabled by design. | Task previews/actions may be visible outside the app lock. | Documented; users can use widget and notification privacy settings. |
| SEC-008 | Informational | The user earlier shared a Gemini key in a screenshot outside source control. | That key may have been disclosed. | Rotate/revoke it in Google AI Studio; no key is included in the source or report. |

No backend authorization, payment, JWT or server rate-limit finding is claimed because those systems are absent. The project directory is not a Git repository; a security branch could not be created without changing the project baseline.
