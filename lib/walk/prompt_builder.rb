# frozen_string_literal: true

# lib/walk/prompt_builder.rb — Builds agent and planning prompts for walk drivers.

module Walk
  class PromptBuilder
    # Options:
    #   project_dir:    working directory included in preamble
    #   claude_md_path: path to CLAUDE.md (nil to skip)
    #   preamble:       custom preamble text (overrides default)
    def initialize(project_dir:, claude_md_path: nil, preamble: nil, **_ignored)
      @project_dir = project_dir
      @claude_md_path = claude_md_path
      @preamble = preamble
    end

    # Extract issue type prefix from title or slug for logging.
    # Returns a simple string (e.g. "investigate", "fix", "meta").
    # No fixed enum — just extracts the prefix as-is.
    def issue_type(issue)
      title = issue[:title] || ""
      slug = issue[:slug] || issue[:id] || ""

      # Extract prefix from title (e.g. "Fix: foo" -> "fix")
      if (m = title.match(/^([A-Za-z][\w-]*)\s*:/))
        return m[1].downcase
      end

      # Fallback: extract prefix from slug (e.g. "fix-foo" -> "fix")
      if (m = slug.match(/^([a-z][\w]*)-/))
        return m[1]
      end

      "general"
    end

    # Build the full agent prompt for working on a single issue.
    #
    # backend: a Walk::DirectoryBackend used to load parent context
    def build_prompt(issue, backend:)
      parent_context = backend.load_parent_context(issue)
      claude_md = load_claude_md
      issue_body = issue[:body] || ""
      issue_title = issue[:title] || issue[:slug] || issue[:id]

      parent_section = if parent_context
        <<~PARENT

          ---

          PROJECT CONTEXT (from parent epic -- read this for project-level goals, constraints, and conventions):

          #{parent_context}
        PARENT
      else
        ""
      end

      epilogue = build_epilogue(issue, nil)

      <<~PROMPT
        #{preamble_text}

        ---

        #{claude_md}
        #{parent_section}
        ---

        ## Issue: #{issue[:id] || issue[:slug]}

        **#{issue_title}**

        #{issue_body}

        ---

        #{epilogue}

        YOUR TASK: #{issue_title}. Refer to the issue body above for goals, method, and close criteria.
      PROMPT
    end

    # Build the planning prompt for creating new issues when all are closed.
    def build_planning_prompt(backend:, epic_id: nil, epic_output: nil)
      claude_md = load_claude_md
      build_directory_planning_prompt(claude_md, backend)
    end

    private

    def preamble_text
      return @preamble if @preamble

      lines = []
      lines << "Issue tracker: WALK_DIR=#{@project_dir}"
      if @claude_md_path && File.exist?(@claude_md_path)
        lines << "Project context: #{@claude_md_path} - READ IT FIRST."
      end
      lines.join("\n")
    end

    def format_bytes(bytes)
      if bytes >= 1024 * 1024
        format("%.1fM", bytes / (1024.0 * 1024))
      elsif bytes >= 1024
        format("%.1fK", bytes / 1024.0)
      else
        "#{bytes}B"
      end
    end

    def load_claude_md
      return "" unless @claude_md_path && File.exist?(@claude_md_path)
      File.read(@claude_md_path)
    end

    # Build a memories section for the planning prompt.
    # Shows alive memories + recently dead ones.
    def build_memories_section(backend)
      epoch = [backend.current_epoch, 1].max
      alive = backend.alive_memories(epoch: epoch)
      recently_dead = backend.recently_dead_memories(epoch: epoch, window: 2)
      return "" if alive.empty? && recently_dead.empty?

      lines = []
      lines << "## Memories (epoch #{epoch})"
      lines << ""

      if alive.any?
        lines << "| Key | Text | Alive | By |"
        lines << "|-----|------|-------|----|"
        alive.each do |m|
          by = m[:created_by] || ""
          lines << "| #{m[:key]} | #{m[:text]} | E#{m[:alive_from]}→ | #{by} |"
        end
        lines << ""
      end

      if recently_dead.any?
        dead_strs = recently_dead.map { |m|
          "~~#{m[:key]}~~ (E#{m[:alive_from]}→E#{m[:alive_until]}#{m[:killed_by] ? ", killed by #{m[:killed_by]}" : ""})"
        }
        lines << "Recently dead: #{dead_strs.join(', ')}"
        lines << ""
      end

      # Byte count for context pressure awareness
      total_bytes = alive.sum { |m| (m[:text] || "").bytesize + (m[:key] || "").bytesize }
      if total_bytes > 0
        lines << "_Memories: #{total_bytes} bytes of context._"
        lines << ""
      end

      lines << <<~GUIDANCE.chomp
        Memories are short descriptions with epoch bounds. Executors record them with
        `walk remember`. Common patterns include artifact locations, environment state,
        evaluation objectives, and constraints — but any memory that saves re-discovery
        or directs evaluation is useful. Propagate relevant memories into issue bodies.
        When a memory becomes stale, the executor should `walk forget` it.
      GUIDANCE
      lines << ""

      lines.join("\n")
    end

    # Build a proposals section for the planning prompt.
    # Shows pending memory proposals from executors for planner review.
    def build_proposals_section(backend)
      proposals = backend.pending_proposals
      return "" if proposals.empty?

      # Auto-cleanup stale proposals (older than 3 epochs)
      backend.cleanup_stale_proposals(max_age: 3)
      proposals = backend.pending_proposals
      return "" if proposals.empty?

      lines = []
      lines << "## Memory Proposals (from executors)"
      lines << ""
      lines << "Executors proposed these memories. Review each one:"
      lines << "- **Accept** valuable ones: `walk accept-proposal \"key\"` (promotes to memory)"
      lines << "- **Synthesize**: if multiple proposals cover the same topic, create one"
      lines << "  consolidated memory with `walk remember` and discard the proposals"
      lines << "- **Discard** noise: `walk discard-proposal \"key\"`"
      lines << ""
      lines << "| Key | Text | By | Epoch |"
      lines << "|-----|------|----|-------|"
      proposals.each do |p|
        by = p[:proposed_by] || ""
        lines << "| #{p[:key]} | #{p[:text]} | #{by} | E#{p[:epoch]} |"
      end
      lines << ""

      lines.join("\n")
    end

    # Build a context pressure section showing expansion ratios and budget.
    # The planner uses this to self-limit how many issues it creates.
    def build_context_pressure_section(exp_stats, budget_bytes, memories_bytes: 0)
      overall = exp_stats[:overall]
      return "" if overall[:count] == 0

      by_type = exp_stats[:by_type]

      type_rows = by_type.sort_by { |_, v| -v[:count] }.map do |type, stats|
        "| %-12s | %5d | %5.1fx | %5.1fx |" % [type, stats[:count], stats[:median_ratio], stats[:p75_ratio]]
      end

      <<~SECTION
        ## Context Pressure (sliding window budget)

        Context budget: ~#{format_bytes(budget_bytes)}. Issues you create now will be
        reviewed next round — their closed size consumes your future review budget.

        **Expansion ratios** (issue body → closed result+comments):

        | Type         | Count | Median |   P75 |
        |--------------|-------|--------|-------|
        #{type_rows.join("\n")}
        | **Overall**  | #{"%5d" % overall[:count]} | #{"%5.1fx" % overall[:median_ratio]} | #{"%5.1fx" % overall[:p75_ratio]} |

        Totals: #{format_bytes(overall[:total_initial])} initial → #{format_bytes(overall[:total_closed])} closed.
        #{"Memories: #{format_bytes(memories_bytes)} (counted toward budget).\n" if memories_bytes > 0}
        Use the P75 ratio to estimate: a 2K issue body at #{overall[:p75_ratio]}x expansion
        ≈ #{format_bytes((2000 * overall[:p75_ratio]).to_i)} of review context next round.
      SECTION
    end

    def build_epilogue(issue, type)
      snippets = build_epilogue_snippets(issue)
      build_shared_epilogue(snippets)
    end

    def build_epilogue_snippets(issue)
      dir = issue[:dir] || "(issue directory)"
      {
        driver_protocol: <<~S.chomp,
          DRIVER PROTOCOL:
          - Work ONLY on this issue.
          - Use the walk CLI for all state mutations:
            - To close: `walk close --reason "..."`
            - To comment: `walk comment "..."`
            - To create issues: `walk create <slug> --title "..." --body "..."`
            - To read: filesystem reads are fine (cat, ls, grep, walk show, walk list)
          - The walk CLI handles locking, validation, and state transitions safely.
            Direct filesystem writes can race with the driver and corrupt state.
          - Document approach and findings as you go using: walk comment "your notes here"
          - Create sub-issues for follow-up work using: walk create <slug> --title "..." --derived-from <current-issue> --body "..."
          - Close with concrete results: data, traces, measurements, or verified code
          - TO CLOSE: walk close --reason "Brief summary of what was accomplished"
            Then EXIT immediately. The driver handles the rest.

          If your findings were unexpected, contradict prior assumptions, or suggest
          open issues may be based on stale information, use `walk close --signal`:
            walk close --reason "..." --signal surprising  # unexpected finding, planner should know soon
            walk close --reason "..." --signal pivotal     # landscape changed fundamentally, plan NOW
          Default signal is `routine` (no flag needed for expected results).
          The driver tracks signals and accumulated context — `pivotal` triggers an
          immediate planning round; `surprising` with enough accumulated context
          triggers planning before the next issue. This prevents wasted work on issues
          based on outdated assumptions.

          VERIFY YOUR WALK OPERATIONS (use walk CLI, not just filesystem):
          - After `walk create <slug>`: run `walk list` to confirm issue appears
          - After `walk comment`: run `walk show` to verify comment was added
          - After `walk close`: the issue moves from open/ to closed/ automatically
        S
        live_comment_watching: <<~S.chomp,
          LIVE FEEDBACK (for user steering during execution):
          - Periodically check for new feedback (every few major steps):
            cat #{dir}/comments.md | tail -40
          - Look for entries timestamped AFTER your agent start time (#{Time.now.strftime('%H:%M')})
            that you did NOT write — these are human feedback
          - Incorporate any user direction into your work
          - This lets the user communicate with you while you run
          - After responding to feedback, use `walk show` to verify issue state
        S
        git_branch_doc: "Document the branch name using: walk comment \"Branch: <branch-name>\""
      }
    end

    # Epilogue structure appended to every agent prompt.
    # Accepts a hash of snippets:
    #   :driver_protocol        - scope, progress docs, close commands
    #   :live_comment_watching  - how to check for user feedback during execution
    #   :git_branch_doc         - how to document git branch name
    def build_shared_epilogue(snippets)
      parts = [snippets[:driver_protocol]]
      parts << snippets[:live_comment_watching] if snippets[:live_comment_watching]
      parts << <<~GIT.chomp
        GIT HYGIENE (other agents share these trees):
        If you modify source code in any shared repo:
        1. Explore first: run `git branch` and `git log --oneline --all --graph | head -30`
           to understand the branch topology. Other agents may have created branches
           with fixes you need. Branch names are descriptive.
        2. Decide where to base your work:
           - If a branch already has the fix/feature you need, branch from it or commit on it
           - If starting fresh, branch from the most relevant existing branch
           - Bug fixes: fix-<thing> (e.g., fix-vhost-polling)
           - Experiments: experiment/<thing> (e.g., experiment/gso-batching)
        3. Make atomic commits with clear messages describing what and why
        4. After building and testing, verify the branch is clean (git status)
        5. Commit or stash all changes before exiting
        6. Preserve all existing branches (no force-push or deletion)
        7. Create a named branch for your work (not master/main)
        8. #{snippets[:git_branch_doc]}
      GIT
      parts << <<~NAMING.chomp
        SUB-ISSUE NAMING (optional prefixes for clarity, not enforced):
        - Investigate: - research/analysis, understanding behavior
        - Experiment: - trying things, running benchmarks
        - Compare: - A vs B measurements
        - Fix: - implementing and verifying fixes
        - Trace: - following execution flow through code
        - Instrument: - adding logging/tracing to code
        - Ablation: - removing/simplifying code to test necessity
        - Meta: - improving walk itself (source in ~/walk/)
        These are conventions that have been empirically useful. Use them
        when they fit, or use your own descriptive prefix or none at all.
      NAMING
      parts << <<~SELFMOD.chomp
        SELF-MODIFICATION (for Meta: issues only):
        Walk source lives in ~/walk/ (git repo). To modify walk and trigger a restart:
        1. Edit walk source files (bin/walk, lib/walk/*.rb)
        2. Verify syntax: for f in ~/walk/lib/walk/*.rb ~/walk/bin/walk; do ruby -c "$f"; done
        3. Commit: cd ~/walk && git add -A && git commit -m "general: description"
           or: git commit -m "provisional: description"
           (general = candidate for permanent inclusion; provisional = project-specific, expected to be discarded)
        4. Write restart marker: echo "description" > $WALK_DIR/_restart_requested
        5. The trampoline restarts walk on the next iteration.

        To review accumulated walk changes since last known-good state:
          cd ~/walk && git diff $(cat .last_good_commit)..HEAD
      SELFMOD
      parts << <<~PROPOSALS.chomp
        MEMORY PROPOSALS:
        When you discover a procedure, workaround, or fact that required reading
        source code or trial-and-error to figure out, propose it as a memory:
          walk propose "short-key" --text "One-line description of the procedure"

        Good proposals save the next executor from re-deriving the same knowledge.
        Propose when you:
        - Had to read multiple files to understand how to do something common
        - Found a non-obvious prerequisite or setup step
        - Discovered a useful command pattern not in CLAUDE.md
      PROPOSALS
      parts.join("\n\n")
    end

    def build_directory_planning_prompt(claude_md, backend)
      meta = backend.read_walk_meta
      walk_dir = backend.walk_dir
      open_dir = File.join(walk_dir, "open")

      walk_section = if meta
        "## Walk: #{meta[:title]}\n\n#{meta[:body]}"
      else
        "## Walk\n\n(No _walk.md found.)"
      end

      # Get recently closed issues by size (backwards-chain until ~20KB)
      recent_by_epoch = backend.recent_closed_issues(min_bytes: 20_000)
      current_epoch = backend.current_epoch
      total_closed = backend.list_issues(status: "closed").size

      # Build discovery tree for parent annotations
      tree = backend.build_discovery_tree(include_closed: true)
      parent_of = tree[:parent_of]

      closed_context = if recent_by_epoch.empty?
        "No closed issues yet."
      else
        # Build compact table: Epoch | Slug | Prior (what was attempted) | Signal | Bytes
        total_bytes = recent_by_epoch.values.flatten.sum { |i| i[:result_bytes] || 0 }
        has_signals = recent_by_epoch.values.flatten.any? { |i| i[:signal] }
        issues_flat = recent_by_epoch.sort.reverse.flat_map do |epoch, issues|
          issues.map do |i|
            parent = parent_of[i[:slug]]
            {
              epoch: epoch,
              slug: parent ? "#{i[:slug]} (from #{parent})" : i[:slug],
              prior: i[:title] || i[:slug],
              signal: i[:signal],
              bytes: i[:result_bytes] || 0
            }
          end
        end

        # Calculate column widths
        slug_w = [issues_flat.map { |i| i[:slug].length }.max, 4].max
        prior_w = [issues_flat.map { |i| i[:prior].length }.max, 24].max
        bytes_w = 5

        header = "#{issues_flat.size} issues, #{format_bytes(total_bytes)} total. " \
                 "Epochs #{recent_by_epoch.keys.min}-#{recent_by_epoch.keys.max}. Total closed: #{total_closed}."

        if has_signals
          signal_w = 10
          table_header = "| Epoch | %-#{slug_w}s | %-#{prior_w}s | %-#{signal_w}s | %#{bytes_w}s |" % ["Slug", "Prior (what was attempted)", "Signal", "Bytes"]
          table_sep = "|-------|-%s-|-%s-|-%s-|-%s-|" % ["-" * slug_w, "-" * prior_w, "-" * signal_w, "-" * bytes_w]
          table_rows = issues_flat.map do |i|
            sig = i[:signal] || ""
            "| %5s | %-#{slug_w}s | %-#{prior_w}s | %-#{signal_w}s | %#{bytes_w}s |" % [i[:epoch], i[:slug], i[:prior], sig, format_bytes(i[:bytes])]
          end
        else
          table_header = "| Epoch | %-#{slug_w}s | %-#{prior_w}s | %#{bytes_w}s |" % ["Slug", "Prior (what was attempted)", "Bytes"]
          table_sep = "|-------|-%s-|-%s-|-%s-|" % ["-" * slug_w, "-" * prior_w, "-" * bytes_w]
          table_rows = issues_flat.map do |i|
            "| %5s | %-#{slug_w}s | %-#{prior_w}s | %#{bytes_w}s |" % [i[:epoch], i[:slug], i[:prior], format_bytes(i[:bytes])]
          end
        end

        signal_note = if has_signals
          surprising_slugs = issues_flat.select { |i| i[:signal] }.map { |i| i[:slug] }
          "\nIssues with signals (surprising/pivotal) triggered this planning round — " \
          "prioritize reviewing these: #{surprising_slugs.join(', ')}\n"
        else
          ""
        end

        <<~TABLE
          #{header}

          #{table_header}
          #{table_sep}
          #{table_rows.join("\n")}
          #{signal_note}
          Use `walk show <slug>` to load full content (body, comments, result).
        TABLE
      end

      # Show open issues separately
      open_issues = backend.list_issues(status: "open")
      open_context = if open_issues.empty?
        "No open issues."
      else
        open_issues.map { |i|
          parent = parent_of[i[:slug]]
          parent_note = parent ? " (from #{parent})" : ""
          "- #{i[:slug]}#{parent_note}: #{i[:title]}"
        }.join("\n")
      end

      claude_md_section = if claude_md.empty?
        ""
      else
        "\n---\n\n#{claude_md}\n\n---\n"
      end

      # Epoch info for planner
      all_epochs = backend.list_epochs
      epoch_info = if current_epoch == 0
        "No epochs yet (this will be epoch 1)."
      else
        "Current epoch: #{current_epoch}. All epochs: #{all_epochs.join(', ')}."
      end

      # Memories section
      memories_section = build_memories_section(backend)
      memories_bytes = backend.alive_memories_bytes

      # Proposals section (executor -> planner review)
      proposals_section = build_proposals_section(backend)

      # Context pressure: expansion stats for sliding window awareness
      # ~120KB budget proxy for 200K token window minus system prompt and safety margin
      context_budget_bytes = 120_000
      exp_stats = backend.expansion_stats
      context_pressure_section = build_context_pressure_section(exp_stats, context_budget_bytes, memories_bytes: memories_bytes)

      snippets = {
        preamble: <<~S,
          You are a planning agent for a walk exploration.
          Working directory: #{walk_dir}

          ## Epochs (Planning Rounds)

          #{epoch_info}

          Each epoch represents one planning round. Issues closed since last planning
          appear in the current epoch. When you create new issues, they will be worked
          on and closed in the NEXT epoch.

          The table below loads recent issues by size (~20KB), spanning however many
          epochs that requires. Use `walk show <slug>` to expand specific issues.
          To trace back further (e.g., understand a discovery chain):
            ls #{walk_dir}/epochs/          # list all epochs
            ls #{walk_dir}/epochs/3/        # issues closed in epoch 3

          #{claude_md_section}
          #{walk_section}

          ## Recently Closed (epochs #{recent_by_epoch.keys.min || '?'}-#{recent_by_epoch.keys.max || '?'})

          #{closed_context}

          ## Open Issues (still in progress)

          #{open_context}
          #{memories_section}
          #{proposals_section}
          #{context_pressure_section}
        S
        exploration_steps: <<~S,
          The table shows what was *attempted* (prior) and how much context each issue
          contains (bytes). Before expanding anything:

          1. Scan the table for relevance to epic goals - which issues matter?
          2. Check git state: git log --oneline -5 in repos that were modified
          3. Follow discovery links ("from <parent>") to understand investigation chains
          4. Look at earlier epochs if needed: ls #{walk_dir}/epochs/<N>/

          Then proceed to Step 3 for selective expansion and critical evaluation.
        S
        recording_instruction: '"Write findings to result.md in the issue directory"',
        traceability: <<~S,
          Always use --derived-from to record epistemic provenance:
          `walk create new-issue --title "..." --derived-from source-issue --body "..."`
          Use --blocked-by for execution ordering (scheduling dependencies).
        S
        goal_met_action: <<~S,
          If the walk goals have been met, do not create issues. Instead, write
          a result file to signal completion:

          ```
          cat > #{walk_dir}/_planning_result.md << 'PLANNING_EOF'
          ---
          outcome: completed
          reason: "All epic objectives have been met: <brief explanation>"
          ---

          Optional detailed rationale.
          PLANNING_EOF
          ```

          Then EXIT. The driver reads this file and finalizes the walk.
        S
        create_issue_how_to: <<~S,
          To create an issue, use the walk CLI:

          ```
          walk create investigate-something \\
            --title "Investigate something specific" \\
            --type investigate \\
            --priority 2 \\
            --derived-from source-issue-slug \\
            --body "Description of what to investigate and why.

          ## Close with

          What the agent should report when done."
          ```

          Always use `walk create` to make issues — the CLI handles locking and validation.
          Use `walk list` to verify issues were created.

          Always specify --derived-from to record where this issue came from (epistemic
          provenance — what you learned that led to this issue). Multiple sources are
          allowed: `--derived-from foo --derived-from bar`. This is about provenance
          (what you learned), not scheduling (use --blocked-by for execution ordering).

          For issues that depend on another issue completing first:
          ```
          walk create child-issue --title "..." --blocked-by parent-issue --derived-from source-issue --body "..."
          ```
        S
        verify_and_exit: <<~S
          After creating issues:
          1. Verify they exist: walk list (should show your new issues)
          2. Write a result file to signal what happened:
             ```
             cat > #{walk_dir}/_planning_result.md << 'PLANNING_EOF'
             ---
             outcome: created_issues
             reason: "Created N follow-up issues from generative findings"
             ---
             PLANNING_EOF
             ```
          3. Then EXIT. The driver will pick them up.

          If you found no generative findings and created no issues:
             ```
             cat > #{walk_dir}/_planning_result.md << 'PLANNING_EOF'
             ---
             outcome: no_work_found
             reason: "All closed issues are terminal; no new questions or gaps identified"
             ---
             PLANNING_EOF
             ```
          Then EXIT.
        S
      }
      build_shared_planning_prompt(snippets)
    end

    # Planning prompt structure.
    # Accepts a hash of snippets:
    #   :preamble            - opening context (walk meta + closed issues)
    #   :exploration_steps   - how to review what's been done
    #   :recording_instruction - how the worker should record results
    #   :traceability        - how to link issues to their source
    #   :goal_met_action     - what to do if the goal is already met
    #   :create_issue_how_to - how to create issues
    #   :verify_and_exit     - how to verify and exit
    def build_shared_planning_prompt(snippets)
      create_how_to = snippets[:create_issue_how_to] ? "\n#{snippets[:create_issue_how_to]}" : ""

      <<~PROMPT
        #{snippets[:preamble]}
        ## Your job

        You are the planning agent. You write issues that will be executed by an
        LLM worker agent. Your job is twofold:

        1. Review what was learned and decide what to pursue next
        2. Craft issue descriptions that will produce good executor behavior

        The closed issues show issue descriptions paired with executor results. Compare
        what the issue asked for vs what the executor produced. When output diverges
        from intent, that's signal about the prompt, not just the technical problem.

        ## Step 1: Assess epic-level progress

        Before creating any issues, answer these questions:
        - What was the epic's goal?
        - Is that goal met, nearly met, or still far away?
        - What concrete gaps remain?
        - What is your single largest uncertainty about whether the goal is met?
          (If you cannot articulate one, the assessment is more trustworthy.)

        #{snippets[:goal_met_action]}
        If gaps remain: proceed to Step 2.

        ## Step 2: Deep exploration (before creating any issues)

        #{snippets[:exploration_steps]}
        ## Step 3: Expand and critically evaluate

        For each issue you identified as relevant in Step 2, run `walk show <slug>`.
        Budget by bytes: expanding a 6K issue costs more context than a 2K issue.
        Skip issues that are clearly tangential or failed for environmental reasons.

        For each expanded issue, evaluate:

        **A. Did the executor do the work?**
        Compare prior (what was attempted, from title) vs posterior (what was produced).
        - Did they do what was asked, or something adjacent?
        - Did they use the methods specified, or substitute easier ones?
        - Did they stop at a blocker, or find a way through?

        **B. Is the conclusion trustworthy?**
        Executor results contain claims. Evaluate critically:
        - Is there evidence (data, traces, benchmarks) or just reasoning?
        - Does it contradict findings from other issues?
        - Did they answer the actual question or deflect?

        **C. Terminal or generative?**
        - **Terminal**: Question answered, fix verified, artifact delivered. No follow-up.
        - **Generative**: Exposes new questions, gaps, or contradictions. Warrants follow-up.

        When execution diverged from intent, diagnose:
        - Vague goal → executor chose its own interpretation
        - Missing constraints → executor took path of least resistance
        - No verification criteria → executor declared success without evidence
        - Escape hatch available → executor rationalized why goal was impossible

        Write your triage. Format:
        ```
        <slug>: EXPANDED | SKIPPED (reason)
          Prior: <what was attempted>
          Posterior: <what was concluded>
          Trust: <high/medium/low - why>
          Classification: TERMINAL | GENERATIVE
          Follow-ups: <what they address, if any>
        ```

        ## Step 3.5: Meta-evaluation (improve walk itself)

        Review executor behavior from the closed issues. Consider:

        - Did executors misunderstand instructions? → The issue body IS the prompt.
          Fix in prompt_builder.rb (epilogue, planning prompt).
        - Did executors lack CLI features? → Add a new walk subcommand in bin/walk.
        - Did driver behavior cause problems? → Fix in lib/walk/driver.rb.
        - Did planning produce poor issue descriptions? → Fix the planning prompt
          structure in prompt_builder.rb (the build_shared_planning_prompt method).
        - Were logs too large for effective review? → Consider adding summary
          extraction or size-limited output to the reporting or agent_runner.

        Review alive memories. Are any stale? Should new ones be created based on
        recent results? Are there evaluation objectives that should be assessed this
        round? Create a meta issue if a memory-related improvement is needed.

        Walk architecture (for context — read source before modifying):
        - `bin/walk` — CLI entrypoint, ~1100 lines. All subcommands defined here.
        - `lib/walk/driver.rb` — Core loop: pick issues, spawn agents, plan.
          EXIT_CODE_RESTART=42 triggers trampoline restart.
        - `lib/walk/prompt_builder.rb` — Builds agent and planning prompts.
          Issue type prefixes (investigate, fix, meta, etc.) are conventions for
          clarity, not enforced by the driver. `issue_type()` extracts the prefix
          as a string for logging only.
          Planning prompt: 5-step process (assess, explore, evaluate, create, verify).
        - `lib/walk/agent_runner.rb` — Spawns claude, captures output, detects results.
        - `lib/walk/planning_lifecycle.rb` — Planning agent spawning, result parsing.
        - `lib/walk/retry_policy.rb` — Blocks issues after 3 consecutive failures.
        - `lib/walk/directory_backend.rb` — File-based issue storage (open/, closed/).

        Create 0-1 "Meta: ..." issues per planning round if a concrete improvement
        exists. Be specific: name the file, method, and what to change. The executor
        for meta issues will modify walk source in ~/walk/, commit with git, and write
        a restart marker to $WALK_DIR/_restart_requested to trigger a trampoline restart.

        Be cognizant that executor run logs can be very large (10K+ lines). If you
        find yourself unable to effectively review executor behavior due to log size,
        that itself is a meta-improvement opportunity (e.g., add structured summaries,
        limit output capture, or add a `walk digest` command).

        ## Step 4: Create follow-up issues (sliding window)

        You are operating in a **sliding window** over the problem space. You will get
        another planning round after this batch completes. Branches you don't pursue
        now aren't lost — they'll be available next round.

        **Order by criticality**: Create the most informative/generative issues first.
        After each issue you create, mentally estimate its closed size using the
        expansion ratios from the Context Pressure section above. Stop creating issues
        when the estimated next-round review budget would exceed the context window.
        It's better to create 3 high-criticality issues than 8 mixed ones.

        For each generative finding, create 0-2 follow-up issues.

        Check Alive Memories for information the executor will need. Include relevant
        memories directly in the issue body — do not force re-discovery of known state.
        When an issue's result invalidates a memory, instruct the executor to
        `walk forget` the old one and `walk remember` the new state.

        ### The issue body IS the prompt

        The executor receives your issue body plus minimal driver framing. Everything
        the executor needs to do the work correctly must be in the issue body.

        Write substantial issues: Goal, Background, Method, Success Criteria, specific
        commands and file paths. The key addition: **close escape hatches** based on
        how previous executors failed.

        Weak (executor will drift):
          "Investigate IPsec performance. Check if it's slow."
        Strong (executor has a clear path):
          "Measure iperf3 throughput between VM1 and VM2 over plain IPv6 vs ESP
           tunnel. Run 30s with -P 4. Record per-core CPU%.
           ## Close with: plain IPv6 Gbps, ESP Gbps, which cores saturated."

        ### Strengthen based on execution history

        When you evaluated execution quality in Step 3, you identified how prompts
        failed. Use that to strengthen follow-up issues:

        - Executor substituted easier work → specify the exact method and add verification criteria
        - Executor stopped at blocker → include workaround, or create dependency first
        - Executor produced shallow output → add depth requirements, minimum counts
        - Executor rationalized impossibility → close the escape: "This is achievable
          because X demonstrates Y. Find why Z differs."
        - Executor used wrong tools → specify tools explicitly: "Use perf, not analysis
          of existing data"

        The goal is iterating on prompt design. Each follow-up should be harder to
        deflect than the issue that spawned it.

        ### Traceability

        Every follow-up names its source: "Discovered from: <source-slug>".
        No source = no issue (exception: first planning round).

        #{snippets[:traceability]}
        #{create_how_to}
        **Scratchpad**: Observations that don't warrant an issue yet:
          walk comment "Scratchpad: <observation>"

        ## Step 5: Verify and exit

        #{snippets[:verify_and_exit]}
      PROMPT
    end

  end
end
