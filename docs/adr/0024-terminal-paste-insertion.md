# 0024: Clipboard paste into terminals

## Status

Accepted, 2026-09-24.

## Context

Automatic insertion types text into a focused Accessibility text element and reads it back. Terminal emulators (Terminal, iTerm2, Ghostty, cmux, Warp, Alacritty, kitty, WezTerm) expose no such element, so dictation into a shell or a TUI such as Claude Code was only saved to history. Typing Unicode key events into a terminal would also turn any newline in the text into Return and run the line.

## Decision

When the frontmost app is a built-in terminal, capture its focused window as a paste target. Before dispatch, revalidate that the same process and window are frontmost and that secure input is off; a terminal password prompt turns secure input on. Snapshot every clipboard item (up to 32 MB, otherwise skip the paste), write the text as a transient item, post Command-V to the terminal's process and restore the snapshot one second later unless the clipboard changed in between. Terminals deliver the text as a bracketed paste, so newlines do not submit. The paste is recorded as confirmed without readback. Correction learning is skipped, and context capture reads the window title only, never the scrollback.

## Consequences

The clipboard changes briefly without an explicit user action, and a clipboard manager that ignores the transient marker may record the dictation. A paste the terminal drops is still recorded as confirmed. A clipboard over 32 MB leaves the text in history for a manual copy. Category overrides from Settings do not make other apps paste targets.

## Alternatives considered

Typing Unicode events into the terminal, rejected because of Return on newlines and because nothing confirms it. Leaving terminals unsupported.
