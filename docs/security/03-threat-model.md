# Threat model

Assets: local tasks, notes, chat history, Gemini API key, optional Firebase session, reminders and pet settings. Actors: device owner, launcher/widget host, other installed apps, Google services, and a physical/device-compromise attacker.

STRIDE checks: **Spoofing** exported widget actions was possible and is mitigated with an app-private token. **Tampering** with SQLite remains possible for a rooted or compromised device; app lock is not a database security boundary. **Repudiation** is limited to local task history; there is no remote audit log. **Information disclosure** can occur via widgets, lock-screen notifications, plaintext DB, and intentionally sent Gemini prompts; privacy controls and tool-scoped Gemini data reduce exposure. **Denial of service** remains possible when Android kills the overlay or notification permissions are revoked. **Elevation of privilege** through Firebase identity cannot grant task access because no remote task API exists.

Assumptions: Android OS and Keystore are trusted for normal device use; root access is outside the protection promise. The app cannot guarantee exact alarms, overlay visibility, speech recognition, or TTS on every device.
