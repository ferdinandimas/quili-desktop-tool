# Changelog

All notable changes to Quili. Versions follow the `VERSION` file; the newest changes are at the top.

## Unreleased

### Fixed
- **The ✦ button no longer covers the text you type.** When the typing caret reached the button (for example at the
  bottom-right of a text field) the button sat on top of the characters being typed. Quili now follows the caret
  and slides the button to the right of it, with a 5 px gap, and slides it back to its usual place once the caret
  has moved away (after a new line, say). A button you dragged yourself is never moved. macOS and Windows.

  | Before | After |
  | --- | --- |
  | ![The button covers the text next to the caret](docs/images/caret-button-before.png) | ![The button sits to the right of the caret](docs/images/caret-button-after.png) |

### Added
- **Summarize a Slack thread.** A ✦ button appears beside Slack's own "Summarize thread" button; Quili reads the
  open thread through the accessibility API (no Slack API or token), scrolls through a long thread to read all of
  it, and shows a short briefing: the key discussion, the outcome classified into decisions, action items, open
  questions and risks, and the key details, with the most important points in bold. The bubble scrolls, stays
  until you close it with ×, and the summary is copied to the clipboard.
- **Mock server (offline)** setting: every action (paraphrase, translate, summarize) can run against a built-in
  fixed-answer server when the real one is down.
- **Write debug log** setting to turn logging off.
- Build guide for both platforms and `build.sh` usage in the README.

### Changed
- Paraphrase and translate keep the original line breaks and blank lines, and the whitespace around the text,
  so the structure of a message survives being replaced (server side).
- Server-side guards: the text sent to paraphrase, translate and summarize is treated strictly as data and can
  no longer make the model run commands or follow instructions hidden in it.

## 1.0.0
- First release: ✦ button on the focused text field that paraphrases the selected text (or the whole field) in
  place, translates it to natural English, and streams the result into a preview bubble. Windows tray app and macOS
  menu-bar app.
