# frozen_string_literal: true

# lib/walk/prompt_builder.rb — Builds agent and planning prompts for walk drivers.
#
# Backend-agnostic: all issue/context fetching is done through the Backend
# interface. Both the beads-backed walk-runner.rb and the directory-backed
# bin/walk use this class.

module Walk
  class PromptBuilder
    # Options:
    #   project_dir:    working directory included in preamble
    #   claude_md_path: path to CLAUDE.md (nil to skip)
    #   preamble:       custom preamble text (overrides default)
    #   close_protocol: :bd (use bd CLI) or :result_md (write result.md)
    def initialize(project_dir:, claude_md_path: nil, preamble: nil, close_protocol: :bd)
      @project_dir = project_dir
      @claude_md_path = claude_md_path
      @preamble = preamble
      @close_protocol = close_protocol
    end

    # Detect issue type from title prefix or slug pattern.
    def issue_type(issue)
      title = issue[:title] || ""
      slug = issue[:slug] || issue[:id] || ""

      # First try title prefix (canonical)
      case title
      when /^Investigate:/i then return :investigate
      when /^Instrument:/i  then return :instrument
      when /^Trace:/i       then return :trace
      when /^Test:/i        then return :test
      when /^Compare:/i     then return :compare
      when /^Experiment:/i  then return :experiment
      when /^Fix:/i         then return :fix
      when /^Ablation:/i    then return :ablation
      end

      # Fallback: check slug pattern (planners often use descriptive slugs)
      case slug
      when /^investigate-/i then :investigate
      when /^instrument-/i  then :instrument
      when /^trace-/i       then :trace
      when /^test-/i        then :test
      when /^compare-/i     then :compare
      when /^experiment-/i  then :experiment
      when /^benchmark-/i   then :experiment
      when /^fix-/i         then :fix
      when /^ablation-/i    then :ablation
      when /^meta-/i        then :meta
      else                       :general
      end
    end

    # Type-specific task instructions for the worker agent.
    def task_instructions(type)
      instructions = build_task_instructions
      instructions.fetch(type, instructions[:general])
    end

    # Build the full agent prompt for working on a single issue.
    #
    # backend: a Walk::Backend used to load parent context
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
      PROMPT
    end

    # Build the planning prompt for creating new issues when all are closed.
    #
    # For :bd close_protocol, epic_id and epic_output are used.
    # For :result_md close_protocol, backend and walk_dir are used.
    def build_planning_prompt(backend:, epic_id: nil, epic_output: nil)
      claude_md = load_claude_md

      if @close_protocol == :bd
        build_bd_planning_prompt(claude_md, epic_id, epic_output)
      else
        build_directory_planning_prompt(claude_md, backend)
      end
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

    def build_epilogue(issue, type)
      id = issue[:id] || issue[:slug]

      if @close_protocol == :bd
        snippets = build_bd_epilogue_snippets(id)
      else
        snippets = build_result_md_epilogue_snippets(issue)
      end
      build_shared_epilogue(snippets)
    end

    # Backend-specific snippets for bd (beads) protocol.
    def build_bd_epilogue_snippets(id)
      {
        driver_protocol: <<~S.chomp,
          DRIVER PROTOCOL:
          - Work ONLY on issue #{id}. Do NOT expand scope.
          - Read issue first: bd show #{id}
          - Document approach: bd comments add #{id} "Chose <approach> because <why>"
          - Document findings as you go: bd comments add #{id} "<what-you-learned>"
          - Create sub-issues for follow-up work: bd create "Prefix: title" --parent #{id} --deps "discovered-from:#{id}" --description="..."
            (The --deps flag links back to THIS issue for context. Always include it so readers know where the task came from.)
          - Close ONLY when you have concrete results (code traced, comparison done, experiment ran, fix tested)
          - DO NOT close with "need more investigation" - leave open or create specific sub-issues instead
          - Close with rationale: bd close #{id} --reason "<specific-finding-or-result>"
          - EXIT immediately after closing. The driver restarts you with fresh context.
        S
        live_comment_watching: <<~S.chomp,
          LIVE COMMENT WATCHING (for user feedback during execution):
          - Periodically check for new comments (every few major steps) with:
            bd activity --mol #{id} --type comment --since 5m
          - If you see NEW comments (timestamps after your agent started at #{Time.now.strftime('%H:%M')}),
            fetch full content with: bd comments #{id}
          - Incorporate any user feedback or direction into your work
          - This lets the user communicate with you while you work
        S
        git_branch_doc: "Document the branch name in your bd comments so the next agent can find it"
      }
    end

    # Backend-specific snippets for directory (result.md) protocol.
    def build_result_md_epilogue_snippets(issue)
      dir = issue[:dir] || "(issue directory)"
      {
        driver_protocol: <<~S.chomp,
          DRIVER PROTOCOL:
          - Work ONLY on this issue. Do NOT expand scope.
          - Document approach and findings as you go using: walk comment "your notes here"
          - Create sub-issues for follow-up work using: walk create <slug> --title "..." --derived-from <current-issue> --body "..."
          - Close ONLY when you have concrete results (code traced, comparison done, experiment ran, fix tested)
          - DO NOT close with "need more investigation" - leave open or create specific sub-issues instead
          - TO CLOSE: walk close --reason "Brief summary of what was accomplished"
            Then EXIT immediately. The driver handles the rest.

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

    # Shared epilogue structure used by both backends.
    # Accepts a hash of backend-specific snippets:
    #   :driver_protocol        - scope, progress docs, close commands
    #   :live_comment_watching  - how to check for user feedback during execution
    #   :git_branch_doc         - how to document git branch name
    def build_shared_epilogue(snippets)
      parts = [snippets[:driver_protocol]]
      parts << snippets[:live_comment_watching] if snippets[:live_comment_watching]
      parts << <<~GIT.chomp
        GIT HYGIENE (MANDATORY -- other agents share these trees):
        If you modify source code in any shared repo:
        1. EXPLORE first: run `git branch` and `git log --oneline --all --graph | head -30`
           to understand the branch topology. Other agents may have created branches
           with fixes you need. Branch names are descriptive.
        2. DECIDE where to base your work:
           - If a branch already has the fix/feature you need, branch from it or commit on it
           - If starting fresh, branch from the most relevant existing branch
           - Bug fixes: fix-<thing> (e.g., fix-vhost-polling)
           - Experiments: experiment/<thing> (e.g., experiment/gso-batching)
        3. Make atomic commits with clear messages describing what and why
        4. After building and testing, verify the branch is clean (git status)
        5. NEVER leave uncommitted changes -- commit or stash before exiting
        6. NEVER force-push or delete existing branches
        7. NEVER commit to master/main directly
        8. #{snippets[:git_branch_doc]}
      GIT
      parts << <<~NAMING.chomp
        SUB-ISSUE NAMING (optional prefixes, helps driver pick instructions):
        - Investigate: - research/analysis, understanding behavior
        - Experiment: - trying things, running benchmarks
        - Compare: - A vs B measurements
        - Fix: - implementing and verifying fixes
        - Trace: - following execution flow through code
        - Instrument: - adding logging/tracing to code
        - Ablation: - removing/simplifying code to test necessity
        - Meta: - improving walk itself (source in ~/walk/)
        Or just use a descriptive title.
      NAMING
      parts << <<~SELFMOD.chomp
        SELF-MODIFICATION (for Meta: issues only):
        Walk source lives in ~/walk/. To modify walk and trigger a restart:
        1. Edit walk source files (bin/walk, lib/walk/*.rb)
        2. Verify syntax: ruby -c <modified-file>
        3. Run: walk self-modify --reason "Brief description of change"
        This commits, writes a restart marker, and the trampoline restarts walk.
      SELFMOD
      parts.join("\n\n")
    end

    def build_bd_planning_prompt(claude_md, epic_id, epic_output)
      snippets = {
        preamble: <<~S,
          #{preamble_text}

          ---

          #{claude_md}

          ---

          ALL ISSUES UNDER THIS EPIC HAVE BEEN CLOSED.

          ## Current Epic

          #{epic_output}
        S
        exploration_steps: <<~S,
          Do ALL of these before creating any issues:
          1. List closed issues: bd list --status closed --parent #{epic_id}
          2. Read conclusions of the 3-5 most recent closed issues: bd comments <id>
          3. Check for result files: ls results/ and read any relevant ones
          4. Check git state of repos that were modified: git log --oneline -5 in relevant repos
          5. Read any source files that recent issues referenced as changed

          Do NOT re-read CLAUDE.md (it is already in your context above).
          Do NOT spend time learning bd CLI syntax (use: bd create, bd comments, bd list).
        S
        recording_instruction: '"bd comments add <id> RESULT: ..."',
        traceability: <<~S,
          Always link to the source: --deps "discovered-from:<source-issue-id>"
          Create with: bd create "Prefix: title" --parent #{epic_id} --deps "discovered-from:<source-issue-id>" -p 2 --description="..."
        S
        goal_met_action: <<~S,
          If the goal is met: create 0-1 cleanup/documentation issues, add a
          comment to the epic recommending closure, and write a result file:

          ```
          cat > #{@project_dir}/_planning_result.md << 'PLANNING_EOF'
          ---
          outcome: completed
          reason: "All epic objectives have been met: <brief explanation>"
          ---
          PLANNING_EOF
          ```

          Then EXIT. The driver reads this file and finalizes the walk.
        S
        verify_and_exit: <<~S
          After creating issues:
          1. List them to verify: bd list --parent #{epic_id} --status open
          2. Write a result file:
             ```
             cat > #{@project_dir}/_planning_result.md << 'PLANNING_EOF'
             ---
             outcome: created_issues
             reason: "Created N follow-up issues from generative findings"
             ---
             PLANNING_EOF
             ```
          3. Then EXIT. The driver will pick them up.

          If you found no generative findings and created no issues:
             ```
             cat > #{@project_dir}/_planning_result.md << 'PLANNING_EOF'
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
        # Build compact table: Epoch | Slug | Prior (what was attempted) | Bytes
        total_bytes = recent_by_epoch.values.flatten.sum { |i| i[:result_bytes] || 0 }
        issues_flat = recent_by_epoch.sort.reverse.flat_map do |epoch, issues|
          issues.map do |i|
            parent = parent_of[i[:slug]]
            {
              epoch: epoch,
              slug: parent ? "#{i[:slug]} (from #{parent})" : i[:slug],
              prior: i[:title] || i[:slug],
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

        table_header = "| Epoch | %-#{slug_w}s | %-#{prior_w}s | %#{bytes_w}s |" % ["Slug", "Prior (what was attempted)", "Bytes"]
        table_sep = "|-------|-%s-|-%s-|-%s-|" % ["-" * slug_w, "-" * prior_w, "-" * bytes_w]
        table_rows = issues_flat.map do |i|
          "| %5s | %-#{slug_w}s | %-#{prior_w}s | %#{bytes_w}s |" % [i[:epoch], i[:slug], i[:prior], format_bytes(i[:bytes])]
        end

        <<~TABLE
          #{header}

          #{table_header}
          #{table_sep}
          #{table_rows.join("\n")}

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

    # Shared planning prompt structure used by both backends.
    # Accepts a hash of backend-specific snippets:
    #   :preamble            - opening context (epic info or walk meta + closed issues)
    #   :exploration_steps   - how to review what's been done
    #   :recording_instruction - how the worker should record results
    #   :traceability        - how to link issues to their source
    #   :goal_met_action     - what to do if the goal is already met
    #   :create_issue_how_to - (optional) how to create issues (directory backend)
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

        #{snippets[:goal_met_action]}
        If gaps remain: proceed to Step 2.

        ## Step 2: Deep exploration (REQUIRED before creating issues)

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
          Fix in prompt_builder.rb (task instructions, epilogue, planning prompt).
        - Did executors lack CLI features? → Add a new walk subcommand in bin/walk.
        - Did driver behavior cause problems? → Fix in lib/walk/driver.rb.
        - Did planning produce poor issue descriptions? → Fix the planning prompt
          structure in prompt_builder.rb (the build_shared_planning_prompt method).
        - Were logs too large for effective review? → Consider adding summary
          extraction or size-limited output to the reporting or agent_runner.

        Walk architecture (for context — read source before modifying):
        - `bin/walk` — CLI entrypoint, ~1100 lines. All subcommands defined here.
        - `lib/walk/driver.rb` — Core loop: pick issues, spawn agents, plan.
          EXIT_CODE_RESTART=42 triggers trampoline restart.
        - `lib/walk/prompt_builder.rb` — Builds agent and planning prompts.
          Issue types: investigate, instrument, trace, test, compare, experiment,
          fix, ablation, meta, general. Each has task_instructions().
          Planning prompt: 5-step process (assess, explore, evaluate, create, verify).
        - `lib/walk/agent_runner.rb` — Spawns claude, captures output, detects results.
        - `lib/walk/planning_lifecycle.rb` — Planning agent spawning, result parsing.
        - `lib/walk/retry_policy.rb` — Blocks issues after 3 consecutive failures.
        - `lib/walk/directory_backend.rb` — File-based issue storage (open/, closed/).

        Create 0-1 "Meta: ..." issues per planning round if a concrete improvement
        exists. Use the `meta` issue type. Be specific: name the file, method, and
        what to change. The executor for meta issues will modify walk source and call
        `walk self-modify --reason "..."` to trigger a trampoline restart.

        Be cognizant that executor run logs can be very large (10K+ lines). If you
        find yourself unable to effectively review executor behavior due to log size,
        that itself is a meta-improvement opportunity (e.g., add structured summaries,
        limit output capture, or add a `walk digest` command).

        ## Step 4: Create follow-up issues

        For each generative finding, create 0-2 follow-up issues.

        ### The issue body IS the prompt

        The executor receives your issue body plus minimal driver framing. Everything
        the executor needs to do the work correctly must be in the issue body.

        Write substantial issues: Goal, Background, Method, Success Criteria, specific
        commands and file paths. The key addition: **close escape hatches** based on
        how previous executors failed.

        ### Strengthen based on execution history

        When you evaluated execution quality in Step 3, you identified how prompts
        failed. Use that to strengthen follow-up issues:

        - Executor substituted easier work → "Do X. Do NOT do Y instead."
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

    # rubocop:disable Metrics/MethodLength
    def build_task_instructions
      doc = doc_instruction
      {
        investigate: <<~TASK,
          INVESTIGATION TASK:
          - Read the issue description carefully
          - Search source code, read files, analyze structure
          - #{doc}
          - If you find actionable items, create child issues
          - Close with summary of what you learned
        TASK
        instrument: <<~TASK,
          INSTRUMENTATION TASK:
          - Add logging/tracing to specified code paths
          - Rebuild the affected component
          - Verify instrumentation compiles and runs
          - Document what output to expect
          - Close with instructions for running instrumented version
        TASK
        test: <<~TASK,
          TEST TASK:
          - Run the test scenario described in the issue
          - Capture all relevant output
          - Analyze results and document findings
          - Create follow-up issues if problems found
          - Close with test results summary
        TASK
        compare: <<~TASK,
          COMPARISON TASK:
          - Run the scenarios described in the issue
          - Capture data from each variant
          - Identify specific differences
          - Document which aspects differ and how
          - Close with comparison summary
        TASK
        trace: <<~TASK,
          TRACE TASK:
          - Follow execution flow through the specified code path
          - Read source files to understand the call chain
          - #{doc}
          - Identify key decision points and data transformations
          - Close with summary of the traced flow
        TASK
        experiment: <<~TASK,
          EXPERIMENT TASK:
          - Try the experimental approach described in the issue
          - Document what you tried and what happened
          - Capture output/logs as evidence
          - Analyze results - did it work? why or why not?
          - Create follow-up issues based on findings
          - Close with experiment results summary
        TASK
        fix: <<~TASK,
          FIX TASK:
          - Implement the fix described in the issue
          - Rebuild and test
          - Verify the original problem is resolved
          - Document any side effects or limitations
          - Close with description of fix and test results
        TASK
        ablation: <<~TASK,
          ABLATION TASK:
          - Identify the mechanism to remove or simplify (branch, conditional, function)
          - Make the change and rebuild
          - Run tests to verify system function is not impaired
          - Measure for performance regression if applicable
          - Document detailed observations on any differences caused
          - Close with confirmation the ablation is safe, or explanation of why it's needed
        TASK
        meta: <<~TASK,
          META-IMPROVEMENT TASK (modifying walk itself):
          - The walk source lives in ~/walk/ (bin/walk, lib/walk/*.rb)
          - Read the issue description for what to change
          - Read the relevant walk source files BEFORE modifying
          - Make targeted, minimal changes — do not refactor unrelated code
          - After modifying, run: ruby -c <file> to verify syntax for each changed file
          - Test your changes if possible (e.g., run `walk --help` to verify CLI changes)
          - Call `walk self-modify --reason "Brief description"` to commit and request restart
          - The trampoline will restart walk with your changes on the next iteration
          - Close with summary of what was changed and why
        TASK
        general: <<~TASK
          TASK:
          - Read the issue description - it tells you what to do
          - #{doc}
          - Create sub-issues if you discover follow-up work
          - Close with summary of what was done or learned
        TASK
      }
    end
    # rubocop:enable Metrics/MethodLength

    def doc_instruction
      if @close_protocol == :bd
        "Document findings as you go with bd comments add"
      else
        "Document findings as you go (write notes to comments.md in the issue directory)"
      end
    end
  end
end
