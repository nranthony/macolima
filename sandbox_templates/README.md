# sandbox_templates/

Everything that is COPIED somewhere else — into the image at build time, or
into a profile's `claude-home/` at `up`. Nothing here is read at runtime by the
sandbox itself; if a file is read in place rather than copied, it does not
belong in this tree.

```
claude/claude-settings.json   -> a profile's claude-home/settings.json
claude/hooks/                 -> baked into the image at /usr/local/lib/claude-hooks/
common/.zshrc, .p10k.zsh      -> baked into the image at /home/agent/
common/db.env.template        -> a profile's db.env.example
common/zshrc-snippet.sh       -> printed by bootstrap.sh for the HOST ~/.zshrc
skills/<name>/                -> a profile's claude-home/skills/<name>/
wheels/                       -> vendored wheels, baked into the image (V4)
VENDORED.lock                 -> what the channel supplied (V3); a FILE at this
                                 root on purpose, so the skills convergence loop
                                 (which iterates DIRECTORIES) can never carry it
                                 into a profile
```

Renamed from `config/` in work/0002 V2, for parity with windows-ai-sandbox and
because `config/` was ambiguous: it held both things the sandbox reads and
things the sandbox copies. `wheels/` and `skills/` are written by
`scripts/vendor-tools.sh` from the depot channel — treat anything it manages as
derived, and change it upstream.
