# Thinklet fork of speech_to_text_windows 1.0.1

Changed only `windows/speech_to_text_windows_plugin.{h,cpp}`:

- Speech events come in as a window message on the UI thread (SAPI
  `SetNotifyWindowMessage`) instead of a polling background thread that
  called Flutter from the wrong thread.
- Asks SAPI for hypotheses, so words appear while you speak.
- Keeps every phrase of one recording; results are always "partial" with
  the whole text so far, and stopping ends it (with a 700 ms grace so the
  last words land).
- Escapes the JSON it sends; no `soundDetected`/`soundEnded` statuses
  (they made the app think the mic had stopped).
