# seedkeep-ios — Agent Instructions

Shared agent rules live in `~/AGENTS.md` (chezmoi-managed; applies to every repo). This file adds only repo-specific guidance.

## Task tracking — beads (`bd`)

The canonical Beads database is in `/Users/tfinklea/git/seedkeep`. Run `bd`
from that umbrella checkout for work spanning this repo and the other Seedkeep
repos; do not maintain an independent local backlog here.

Agent loop (harness-agnostic — `bd` is just a CLI):
- From `/Users/tfinklea/git/seedkeep`, run `bd ready` to find available work,
  `bd show <id>` before starting, and `bd update <id> --claim` to claim it.
- Run the affected repo's build/test, then close the issue from the umbrella
  with `bd close <id> --reason "…"`.
- Create or link follow-up work from the umbrella with `bd create` and `bd dep
  add`; do not create a repo-local `.beads` backlog.

beads owns ONLY the backlog/ready-queue. Rationale/ADRs → `.docs/ai/decisions.md`, multi-session design → `.docs/ai/phases/*` (markdown prose; create as the project grows). Part of a cross-repo beads pilot (2026-06-30); see chezmoi-config `.docs/ai/phases/beads-pilot-spec.md`.
