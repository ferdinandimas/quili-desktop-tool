@AGENTS.md

# Claude Code

Everything above applies to you. In particular: **a change to the Windows code or the macOS code is only done once the other platform has the exact same change.** If you can't compile one of the platforms on this machine, say so in your summary instead of implying both were verified.

Also: a medium-sized or larger change (a feature, a visible behaviour change, a bug fix users would notice) is not done until it has an entry in `CHANGELOG.md` under `## Unreleased` (see *Changelog* in `AGENTS.md`). Say in your summary that you added it.

And a medium-sized or larger change is also not done until it is **committed** (see *Commits* in `AGENTS.md`): commit it yourself when it is finished, without waiting to be asked, but never push unless asked. **Always do it with `tools/commit.sh "<message>" ["<more paragraphs>"...]`**, not a bare `git commit` (it enforces the personal `ferdinandimas` author and never pushes). Say in your summary that you committed, with the short hash. Commit messages end with the attribution line your environment requires.
