"""Purpose-based grouping for allowlist block tags.

Categories are a dashboard-only view concern — they do not exist in
`allowed_domains.txt` itself, which is organised by LIFECYCLE TIER (ALWAYS ON /
PLANNING-MODE / PROJECT-PERSISTENT / DROPPED), not by purpose. Both groupings
are useful and neither replaces the other: the file's tiers say when a block is
expected to be on, these categories say what it is for.

Ported from windows-ai-sandbox with the tag map REBUILT for this repo. Their
map names blender, pytorch, nvidia, numerai, kaggle, clickup and more — none of
which exist here — and misses `github-raw`, `paperbridge`, `oa-publishers`,
`wearables` and `archive`, which do. Taking theirs verbatim would have dropped
five of macolima's fourteen blocks into "Other".

Anything unmapped falls into "Other" rather than raising: a forgotten mapping
must not break the page. `tests/test_allowlist_roundtrip.py` asserts that no
tag in the live allowlist lands there, so a new block forces a deliberate
one-line decision instead of quietly accumulating in the junk drawer.

Colours are the first five slots of a categorical palette in fixed order, never
cycled or reassigned per render — a block's accent colour has to mean the same
thing on every load.
"""

from __future__ import annotations

CATEGORY_TAGS: dict[str, list[str]] = {
    "AI / LLM CLIs & APIs": [
        "claude", "antigravity", "antigravity-install",
    ],
    "Dev tooling & docs": [
        "git", "github-raw", "vscode", "playwright-install",
    ],
    "Package & OS registries": [
        "pypi", "npm", "apt",
    ],
    "Academic & research data": [
        "paperbridge", "oa-publishers",
    ],
    "Reference & vendor docs": [
        "wearables", "archive",
    ],
}

CATEGORY_ORDER: list[str] = list(CATEGORY_TAGS.keys()) + ["Other"]

CATEGORY_COLORS: dict[str, dict[str, str]] = {
    "AI / LLM CLIs & APIs":      {"light": "#2a78d6", "dark": "#3987e5"},
    "Dev tooling & docs":        {"light": "#eb6834", "dark": "#d95926"},
    "Package & OS registries":   {"light": "#1baf7a", "dark": "#199e70"},
    "Academic & research data":  {"light": "#eda100", "dark": "#c98500"},
    "Reference & vendor docs":   {"light": "#e87ba4", "dark": "#d55181"},
    "Other":                     {"light": "#898781", "dark": "#898781"},
}

CATEGORY_SLUGS: dict[str, str] = {
    "AI / LLM CLIs & APIs": "ai",
    "Dev tooling & docs": "dev",
    "Package & OS registries": "pkg",
    "Academic & research data": "research",
    "Reference & vendor docs": "refdocs",
    "Other": "other",
}

TAG_CATEGORY: dict[str, str] = {
    tag: category
    for category, tags in CATEGORY_TAGS.items()
    for tag in tags
}


def category_for(tag: str) -> str:
    return TAG_CATEGORY.get(tag, "Other")


def color_var(tag: str) -> str:
    """CSS var() reference for a tag's category accent colour."""
    slug = CATEGORY_SLUGS[category_for(tag)]
    return f"var(--cat-{slug})"


def css_vars_block() -> str:
    """<style> block declaring one CSS var per category, light + dark.

    Emitted once per render. Using CSS vars rather than inlining the hex at
    every call site is what makes the dark-mode variant possible at all —
    Streamlit gives the page no server-side signal for the viewer's theme.
    """
    light = "\n".join(
        f"  --cat-{CATEGORY_SLUGS[cat]}: {colors['light']};"
        for cat, colors in CATEGORY_COLORS.items()
    )
    dark = "\n".join(
        f"  --cat-{CATEGORY_SLUGS[cat]}: {colors['dark']};"
        for cat, colors in CATEGORY_COLORS.items()
    )
    return (
        f"<style>\n"
        f":root {{\n{light}\n}}\n"
        f"@media (prefers-color-scheme: dark) {{\n"
        f"  :root {{\n{dark}\n  }}\n"
        f"}}\n"
        f"</style>"
    )
