"""Palette and themes.

Design principle, and the reason the colours are arranged this way:

    The running row is the only luminous thing on screen, and warmth always
    means attention.

A wave-scheduler queue is mostly *waiting* — a 1.4B-molecule library takes days,
so at any moment one row is working and the rest are idle or finished. A palette
that gives every status an equally bright hue turns that into a wall of confetti
and buries the one row you actually care about. So:

  * the ground is a deep petrol-black, and structure is a desaturated sea-teal
  * `running` is the single bright cool colour — the eye lands on it immediately
  * everything settled (pending, done, skipped) is low-chroma and recedes
  * warm hues are reserved for things needing a human: held, missing, failed,
    cancelled, stale. Any warmth in the table means "look here"

Both a dark and a light variant are defined, because a terminal's background is
not ours to choose. The light variant is not the dark one lightened: each hue is
re-picked for contrast against a pale ground.
"""

from __future__ import annotations

from typing import Dict, Tuple

from textual.theme import Theme

# ---------------------------------------------------------------------------
# themes  (drive Textual's own widgets too: footer, toasts, modals, dropdowns)
# ---------------------------------------------------------------------------

ERSILIA_DARK = Theme(
    name="ersilia-dark",
    dark=True,
    background="#0d1319",   # deep petrol black — calm, and not pure black
    surface="#121a22",
    panel="#18222c",
    foreground="#cfd9e2",
    primary="#5fb3a1",      # sea teal: structure, selection, headings
    secondary="#56b6f0",    # instrument cyan: the live signal
    success="#5f9e76",
    warning="#c99542",
    error="#d75f5f",
    accent="#9d76ad",
    variables={
        "block-cursor-background": "#1a3a35",
        "block-cursor-foreground": "#eaf3f0",
        "block-cursor-text-style": "bold",
        "footer-key-foreground": "#5fb3a1",
        "footer-description-foreground": "#7d8b9a",
    },
)

ERSILIA_LIGHT = Theme(
    name="ersilia-light",
    dark=False,
    background="#f4f7f8",
    surface="#ffffff",
    panel="#e7eef0",
    foreground="#1d2730",
    primary="#2f7d6d",
    secondary="#1f6f9e",
    success="#35774f",
    warning="#8a5f14",
    error="#a83232",
    accent="#6c4a7c",
    variables={
        "block-cursor-background": "#cfe6df",
        "block-cursor-foreground": "#12211d",
        "block-cursor-text-style": "bold",
        "footer-key-foreground": "#2f7d6d",
        "footer-description-foreground": "#5c6b78",
    },
)

THEMES = (ERSILIA_DARK, ERSILIA_LIGHT)

# ---------------------------------------------------------------------------
# status palette
# ---------------------------------------------------------------------------
# (colour, glyph). The glyph carries the meaning where colour cannot: a
# monochrome terminal, a colour-blind reader, or a screenshot pasted into chat.

# Glyphs are drawn from the geometric/dingbat ranges that monospace terminal fonts
# reliably ship (DejaVu, Liberation, Menlo, Cascadia). Deliberately NO emoji: an
# emoji-presentation codepoint like ⚠ or ⏸ renders double-width in some terminals
# and single in others, which silently shifts every column after it out of line.
_DARK_STATUS: Dict[str, Tuple[str, str]] = {
    "running":       ("#56b6f0", "●"),   # the one bright cool — draws the eye
    "pending":       ("#64737f", "○"),   # waiting is not news
    "done":          ("#5f9e76", "✓"),   # muted: finished work should settle
    "skipped":       ("#4c5762", "·"),
    "held":          ("#a8823c", "‖"),   # warm from here down = wants a human
    "missing-files": ("#c08a3e", "△"),
    "cancelled":     ("#9d76ad", "⊘"),
    "failed":        ("#d75f5f", "✕"),
    "stale":         ("#d97742", "?"),
}

_LIGHT_STATUS: Dict[str, Tuple[str, str]] = {
    "running":       ("#1f6f9e", "●"),
    "pending":       ("#7a8895", "○"),
    "done":          ("#35774f", "✓"),
    "skipped":       ("#9aa5ae", "·"),
    "held":          ("#8a6a1e", "‖"),
    "missing-files": ("#8a5f14", "△"),
    "cancelled":     ("#6c4a7c", "⊘"),
    "failed":        ("#a83232", "✕"),
    "stale":         ("#a4531f", "?"),
}

_FALLBACK = ("#7d8b9a", "·")


class Palette:
    """Colours the Rich-rendered table cells need, for one theme mode."""

    def __init__(self, dark: bool) -> None:
        self.dark = dark
        self.status = _DARK_STATUS if dark else _LIGHT_STATUS
        # The bar track must be barely there: on a queue of 50 rows a bright track
        # becomes a texture that competes with the fills it exists to measure.
        self.track = "#1e2a35" if dark else "#dbe3e7"
        self.dim = "#5b6976" if dark else "#8996a2"
        self.text = "#cfd9e2" if dark else "#1d2730"
        self.bright = "#eaf3f0" if dark else "#0d1a16"
        self.rule = "#26313d" if dark else "#ccd7dc"

    def status_style(self, status: str) -> Tuple[str, str]:
        return self.status.get(status, _FALLBACK)


PALETTES = {True: Palette(dark=True), False: Palette(dark=False)}


def palette(dark: bool = True) -> Palette:
    return PALETTES[bool(dark)]
