# Security changes

- Added optional `local_auth` app lock using phone biometric or device credential. Gate covers Flutter routes, including the pet AI popup. Enabling and disabling requires credential confirmation.
- Added optional Firebase Authentication email sign-in, registration, email verification, password reset and sign-out UI. SDK initialization is deferred to the account page so offline DAYNIX starts without Firebase.
- Added `RECORD_AUDIO` only for user-triggered voice dictation and `USE_BIOMETRIC` for app lock.
- Added Android cleartext denial and no-backup/data-extraction rules.
- Added a 256-bit random widget broadcast token stored in app-private preferences; custom task and notes widget actions reject missing/wrong tokens.
- Removed automatic task-list inclusion in Gemini prompts and narrowed tool results to title, due date, priority and completion state.
- Added a separate translucent pet AI activity excluded from Recents, reusing the saved Gemini key and local task tools.
- Added speech recognition and optional spoken AI replies; these run only after user interaction with AI.

No custom cryptography, client-only integrity check, or pretend server authorization was added. Existing local tasks remain in place.
