# Handoff: seed-prompt-quality walk

## What was done

### 1. `walk plan` command (committed)

Added `walk plan <walk-dir>` — prints a prompt to stdout that the user
pastes into a Claude session for interactive seed-issue creation.

- `lib/walk/prompt_builder.rb` — `build_seed_prompt(backend:)` method
- `bin/walk` — `cmd_plan` subcommand + dispatch + help text

The prompt teaches the receiving agent about the three cognitive layers:
- Layer 1 (seed planner): context engineering, captures human intent
- Layer 2 (planning agents): synthesizes closed results, creates follow-ups
- Layer 3 (workers): subject matter, follows discovery chains

Then guides a 5-question Q&A → seed issue design → `walk create` commands.

### 2. Auto-ordinal slugs and prefix matching (committed)

- `create_issue_by_slug` now prepends `NNN-` (e.g. `005-investigate-foo`)
- `show_issue` and `find_issue_dir` support prefix matching
- `walk show 003` works like `bd show enx.3`

### 3. Seed-prompt-quality walk (committed, not yet run)

Walk dir: `walks/seed-prompt-quality/`

4 seed issues:
```
001-investigate-enx-seed-patterns        P1  What made enx seeds productive vs premature
002-investigate-golden-set-design        P1  Design golden-set eval framework for back-validation
003-experiment-roleplay-seed-session     P2  Simulate seed planning against enx ground truth
004-investigate-prompt-vs-planning-prompt P2  Compare seed prompt rigor against planning prompt
```

Issues 002 and 003 have human-context comments capturing:
- The enx epic description was mutated over time (mostly stable after early bias corrections)
- The human spent significant effort on addressing section specifically
- Perfect preemption of agent bias isn't realistic; prompt should help surface/counteract it
- Need to evaluate whether 5 generic Q&A questions are sufficient

## To run

```bash
cd ~/vpp-bench
./bin/walk run walks/seed-prompt-quality
```

## Key context not in the walk itself

- enx.1-3, 5-6 were all closed as "Premature — superseded by investigation-first approach"
- enx.4 (SEGV check) and enx.7 (broad end-to-end) were productive
- enx.7 worked because it said "theory is secondary, primary deliverable is code that runs"
  and gave freedom ("VPP source modifications are acceptable")
- The one-shot prompt we wrote is probably not good enough — the walk exists to
  iteratively improve it using enx as ground truth
- The golden-set idea (issue 002) is the key long-term play: distill enx into a
  static test fixture so prompt changes can be back-validated without running VPP

## Commits

```
1a8b629 feat: add `walk plan` command for interactive seed-issue creation
8364328 feat: auto-ordinal issue slugs and prefix matching
```
