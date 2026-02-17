# Walk: Temporal Logic

Walk is a sliding-window planner that drives LLM agents through multi-epoch
investigations. The core loop is: plan a batch, execute serially, review
results, plan the next batch. Context pressure — not human intervention —
determines batch size and pacing.

---

## 1. The Epoch Loop

An epoch is one plan-execute-review cycle. The planner sees all prior results
and creates the next batch of issues. Executors work them one at a time.

```
    Epoch 1                 Epoch 2                 Epoch 3
    ───────                 ───────                 ───────

    ┌─────────┐
    │ PLANNER │─── creates ──▶ issue A
    │         │─── creates ──▶ issue B
    │         │─── creates ──▶ issue C
    └─────────┘
                    │
                    ▼
              A ──▶ B ──▶ C     (serial execution)
              │    │    │
              ▼    ▼    ▼
           result result result
                    │
                    ▼
              ┌─────────┐
              │ PLANNER │─── creates ──▶ issue D
              │ (reads   │─── creates ──▶ issue E
              │  A,B,C)  │
              └─────────┘
                              │
                              ▼
                        D ──▶ E
                        │    │
                        ▼    ▼
                     result result
                              │
                              ▼
                        ┌─────────┐
                        │ PLANNER │──▶ ...
                        │ (reads   │
                        │  A–E)    │
                        └─────────┘
```

The planner is re-invoked from scratch each epoch. It has no memory of its
own — it reads results, memories, and the walk goals to reconstruct state.

---

## 2. Derivation Chains

Issues derive from other issues. The planner reads closed results and decides
what to do next. Not 1:1 — derivation is many-to-many.

```
  Terminal (one → zero)         The result is complete.
  ─────────────────────         No follow-up needed.

      ┌───┐
      │ A │──▶ result ──▶ (nothing)
      └───┘


  Convergent (many → one)       Multiple results inform
  ───────────────────────       a single next step.

      ┌───┐
      │ A │──▶ result ─┐
      └───┘             │
                        ├──▶ ┌───┐
      ┌───┐             │    │ D │
      │ B │──▶ result ─┘    └───┘
      └───┘             │
                        │
      ┌───┐             │
      │ C │──▶ result ─┘
      └───┘


  Divergent (one → many)        One result opens multiple
  ──────────────────────        lines of investigation.

      ┌───┐             ┌───┐
      │ A │──▶ result ──▶│ B │
      └───┘           │  └───┘
                      │  ┌───┐
                      ├──▶│ C │
                      │  └───┘
                      │  ┌───┐
                      └──▶│ D │
                         └───┘


  Replacement (one → revised)   Result contradicts the plan.
  ───────────────────────────   Planner discards queued work.

      ┌───┐                     ┌───┐
      │ A │──▶ PIVOTAL ────────▶│ A'│  (revised approach)
      └───┘    result           └───┘
                  │
                  ╳ issue B (was queued, now stale)
                  ╳ issue C
```

The planner doesn't mechanically fan out — it reads all results and decides
from scratch. "Derived from" is a lineage annotation, not a workflow edge.

---

## 3. Context Budget

The planner can't create unlimited issues per epoch. Each issue generates
context: its body (small) expands into a result (large). The planner must
estimate how much context the next epoch's review will consume.

```
  Issue body      Executor runs      Closed result
  (seed)          (work happens)     (expanded)
  ─────────       ──────────────     ──────────────

  ┌──┐                               ┌──────────┐
  │  │  ──── expansion ratio ────▶   │          │
  │  │       (typically 3-8x)        │          │
  └──┘                               │          │
  ~500B                              │          │
                                     └──────────┘
                                     ~2-4KB

  Context budget for next epoch's planning prompt:

  ┌─────────────────────────────── ~120KB context window ──────┐
  │                                                            │
  │  walk goals    memories    closed results ... issue body   │
  │  ┌────┐        ┌──┐        ┌────┬────┬────┐   ┌────┐      │
  │  │    │        │  │        │ A  │ B  │ C  │   │ ??  │     │
  │  └────┘        └──┘        └────┴────┴────┘   └────┘      │
  │  fixed         grows       grows with each    the actual   │
  │                slowly      closed issue       task         │
  │                                                            │
  └────────────────────────────────────────────────────────────┘

  The planner orders by criticality, estimates expansion,
  and stops creating issues when the next epoch's review
  would blow the budget:

  Epoch 2 plan:
    issue D  (~500B body → est. ~3KB result)  ✓ fits
    issue E  (~800B body → est. ~5KB result)  ✓ fits
    issue F  (~400B body → est. ~2KB result)  ✓ fits
    issue G  ...                              ✗ would exceed budget
                                                (defer to epoch 3)
```

Expansion ratios are tracked empirically from prior issues, grouped by type
(investigate issues expand more than fix issues).

---

## 4. Memory Span

Memories are temporal facts with epoch bounds. They're alive from the epoch
they're created until they're killed. The planner sees alive memories each
round and propagates them into issue bodies.

```
  Epoch    1       2       3       4       5       6
           │       │       │       │       │       │
           │       │       │       │       │       │
  server   │▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓│  (alive entire walk)
  -ip      │       │       │       │       │       │
           │       │       │       │       │       │
  old      │▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░│       │       │  (killed at E3:
  -kernel  │       │       │       │       │       │   replaced by upgrade)
           │       │       │       │       │       │
  new      │       │       │▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓│  (alive from E3 on)
  -kernel  │       │       │       │       │       │
           │       │       │       │       │       │
  ch       │       │       │       │▓▓▓▓▓▓▓▓▓▓▓▓▓▓│  (built at E4,
  -binary  │       │       │       │       │       │   alive until reimaged)
           │       │       │       │       │       │
  eval     │       │       │▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░│  (objective: assessed
  -ratio   │       │       │       │       │       │   E3-E5, then retired)
           │       │       │       │       │       │

  ▓ = alive (planner sees it)
  ░ = recently dead (planner sees it struck through, for context)

  What the planner sees at Epoch 4:

  ┌──────────────────────────────────────────────────┐
  │ Memories (E4)                                    │
  │                                                  │
  │  server-ip   65.109.156.200         E1→          │
  │  new-kernel  6.18-rc4 backport      E3→          │
  │  ch-binary   /opt/ch-dev (abc123)   E4→          │
  │  eval-ratio  track expansion ratio  E3→          │
  │                                                  │
  │  Recently dead:                                  │
  │  ~~old-kernel~~ 6.12 (E1→E3, killed by upgrade) │
  └──────────────────────────────────────────────────┘
```

Memories are just key + text + epoch bounds. The planner interprets them
freely — artifacts, environment facts, evaluation objectives, constraints.
No enforced categories.

---

## 5. The Full Picture

```
                         ┌──────────────────────────┐
                         │       Walk Goals          │
                         │   (_walk.md — stable)     │
                         └────────────┬─────────────┘
                                      │
              ┌───────────────────────┼───────────────────────┐
              │                       │                       │
              ▼                       ▼                       ▼
     ┌─── Epoch 1 ───┐      ┌─── Epoch 2 ───┐      ┌─── Epoch 3 ───┐
     │                │      │                │      │                │
     │  ┌──────────┐  │      │  ┌──────────┐  │      │  ┌──────────┐  │
     │  │ PLANNER  │  │      │  │ PLANNER  │  │      │  │ PLANNER  │  │
     │  │          │  │      │  │          │  │      │  │          │  │
     │  │ goals    │  │      │  │ goals    │  │      │  │ goals    │  │
     │  │ (empty)  │──│──┐   │  │ results  │──│──┐   │  │ results  │  │
     │  │          │  │  │   │  │ memories │  │  │   │  │ memories │  │
     │  │          │  │  │   │  │ budget   │  │  │   │  │ budget   │  │
     │  └────┬─────┘  │  │   │  └────┬─────┘  │  │   │  └────┬─────┘  │
     │       │        │  │   │       │        │  │   │       │        │
     │  A  B  C       │  │   │  D  E          │  │   │  F            │
     │  │  │  │       │  │   │  │  │          │  │   │  │            │
     │  ▼  ▼  ▼       │  │   │  ▼  ▼          │  │   │  ▼            │
     │  r  r  r ──────│──┘   │  r  r ─────────│──┘   │  r            │
     │                │      │                │      │                │
     └────────────────┘      └────────────────┘      └────────────────┘

     3 issues                2 issues                1 issue
     (budget allows)         (results grew,          (converging
                              less room)              on answer)
```

The system converges naturally. Early epochs explore broadly (many small
issues). As results accumulate and consume context, later epochs focus
narrowly. The planner doesn't need a "stop" signal — context pressure
is the stopping condition.

---

## Blocking (light touch)

Issues can declare `blocked-by` dependencies. The driver respects these
for topological ordering — a blocked issue won't execute until its
dependency closes. This is sugar for "do X before Y" when order matters
(e.g., build the binary before running benchmarks).

```
  ┌───────────┐
  │ build CH  │────blocks────▶ ┌──────────────┐
  └───────────┘                │ perf test    │
                               │ (with CH)    │
  ┌───────────┐                └──────────────┘
  │ baseline  │────blocks────▶ ┌──────────────┐
  └───────────┘                │ compare with │
                               │ optimization │
                               └──────────────┘
```

Most issues don't need blocking — serial execution and planner intelligence
handle ordering. Blocking is for hard data dependencies, not sequencing
preferences.
