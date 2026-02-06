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

    # Detect issue type from title prefix.
    def issue_type(issue)
      title = issue[:title] || ""

      case title
      when /^Investigate:/i then :investigate
      when /^Instrument:/i  then :instrument
      when /^Trace:/i       then :trace
      when /^Test:/i        then :test
      when /^Compare:/i     then :compare
      when /^Experiment:/i  then :experiment
      when /^Fix:/i         then :fix
      when /^Ablation:/i    then :ablation
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
      type = issue_type(issue)
      task = task_instructions(type)
      parent_context = backend.load_parent_context(issue)
      claude_md = load_claude_md

      parent_section = if parent_context
        <<~PARENT

          ---

          PROJECT CONTEXT (from parent epic -- read this for project-level goals, constraints, and conventions):

          #{parent_context}
        PARENT
      else
        ""
      end

      epilogue = build_epilogue(issue, type)

      <<~PROMPT
        #{preamble_text}

        ---

        #{claude_md}
        #{parent_section}
        ---

        Issue: #{issue[:id] || issue[:slug]}
        Type: #{type}

        #{task}

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
          - Create sub-issues for follow-up work using: walk create <slug> --title "..." --body "..."
          - Close ONLY when you have concrete results (code traced, comparison done, experiment ran, fix tested)
          - DO NOT close with "need more investigation" - leave open or create specific sub-issues instead
          - TO CLOSE: write result.md in #{dir} (first line = close reason), then EXIT immediately.
            The driver handles the rest.

          VERIFY YOUR WALK OPERATIONS (use walk CLI, not just filesystem):
          - After `walk create <slug>`: run `walk list` to confirm issue appears
          - After `walk comment`: run `walk show` to verify comment was added
          - If you write files directly (issue.md, result.md): run `walk show` to check state
          - Prefer `walk comment "..."` over writing to comments.md directly
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
    #   :driver_protocol       - scope, progress docs, close commands
    #   :git_branch_doc         - how to document git branch name
    def build_shared_epilogue(snippets)
      parts = [snippets[:driver_protocol]]
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
        Or just use a descriptive title.
      NAMING
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

      # Get recently closed issues from temporal epochs (planning rounds)
      recent_by_epoch = backend.recent_closed_issues(window: 2)
      current_epoch = backend.current_epoch
      total_closed = backend.list_issues(status: "closed").size

      # Build discovery tree for parent annotations
      tree = backend.build_discovery_tree(include_closed: true)
      parent_of = tree[:parent_of]

      closed_context = if recent_by_epoch.empty?
        "No closed issues yet."
      else
        epoch_sections = recent_by_epoch.sort.map do |epoch, issues|
          issue_lines = issues.map do |i|
            parent = parent_of[i[:slug]]
            parent_note = parent ? " (from #{parent})" : ""
            parts = ["### #{i[:slug]}#{parent_note} -- #{i[:title]}"]
            parts << "Close reason: #{i[:close_reason]}" if i[:close_reason]
            if i[:result]
              result_preview = i[:result].to_s[0, 500]
              result_preview += "..." if i[:result].to_s.length > 500
              parts << "Result: #{result_preview}"
            end
            parts.join("\n")
          end
          "## Epoch #{epoch} (#{issues.size} issues closed)\n\n#{issue_lines.join("\n\n")}"
        end

        header = "Showing epochs #{recent_by_epoch.keys.min}-#{recent_by_epoch.keys.max} " \
                 "(#{recent_by_epoch.values.flatten.size} recent). Total closed: #{total_closed}."
        "#{header}\n\n#{epoch_sections.join("\n\n---\n\n")}"
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

          Your context window shows the last 2 epochs. If you need to trace back further
          (e.g., to understand a discovery chain), you can read earlier epochs:
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
          Review the recently closed issues above. These are what was accomplished in
          the last planning round(s). Then:
          1. Check result files in closed issue directories for detailed findings
          2. Check git state of repos that were modified: git log --oneline -5 in relevant repos
          3. Follow discovery links (issues say "from <parent>") to understand context
          4. If needed, look back at earlier epochs: ls #{walk_dir}/epochs/<N>/
        S
        recording_instruction: '"Write findings to result.md in the issue directory"',
        traceability: <<~S,
          To link issues, create a blocked_by/ directory with symlinks to dependencies.
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
          To create an issue, make a new directory under #{open_dir}/ and write
          an issue.md file with YAML frontmatter. Example:

          ```
          mkdir -p #{open_dir}/investigate-something
          cat > #{open_dir}/investigate-something/issue.md << 'ISSUE_EOF'
          ---
          title: "Investigate something specific"
          type: task
          priority: 2
          ---

          Description of what to investigate and why.

          ## Close with

          What the agent should report when done.
          ISSUE_EOF
          ```
        S
        verify_and_exit: <<~S
          After creating issues:
          1. Verify they exist: ls #{open_dir}/
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

        You are the planning agent. Your job is to review what has been learned
        and decide what to do next: create follow-up issues for generative
        findings, or recommend closing the epic/walk.

        ## Step 1: Assess epic-level progress

        Before creating any issues, answer these questions:
        - What was the epic's goal?
        - Is that goal met, nearly met, or still far away?
        - What concrete gaps remain?

        #{snippets[:goal_met_action]}
        If gaps remain: proceed to Step 2.

        ## Step 2: Deep exploration (REQUIRED before creating issues)

        #{snippets[:exploration_steps]}
        ## Step 3: Triage closed issues (terminal vs generative)

        For each closed issue you read in detail, classify it:

        - **Terminal**: Findings are self-contained — fix applied, design consumed
          by implementation, or investigation answered its question fully.
          Terminal issues generate 0 follow-ups.
        - **Generative**: Findings expose new questions, gaps, or implementation
          needs. Generative issues generate 1-2 follow-ups each.

        Write your triage before creating any issues. Format:
        - <id> (<title>): TERMINAL — <one-line rationale>
        - <id> (<title>): GENERATIVE — <what new question/gap it opens> → N follow-ups

        ## Step 4: Create follow-up issues from generative findings

        For each generative issue from your triage, create 0-2 follow-up issues.
        Every follow-up MUST cite its source via --deps discovered-from:<source-id>.
        If a follow-up synthesizes findings from multiple sources, cite all of them.

        Do not create issues without a source. If you cannot name which closed
        issue's findings warrant the follow-up, the issue is not warranted.
        (Exception: the first planning round with no closed issues creates issues
        based on the epic description.)

        If you have observations that don't yet warrant an issue, leave a comment
        on the epic as a scratchpad note for the next planning round.

        Fewer well-specified issues are better than more vague ones.
        #{create_how_to}
        ### Issue types and what the downstream worker will be told

        Choose the right type. The worker agent receives type-specific instructions.
        Adapt these descriptions to your specific context when writing the issue:

        **Investigate:** Worker searches source code, reads files, documents findings,
        creates child issues for actionable items. USE WHEN: tracing code paths,
        analyzing architecture, understanding why something behaves a certain way.
        The worker generates many tokens reading and annotating source.
        SUCCESS = documented understanding, not code changes.

        **Experiment:** Worker tries an approach, captures output/logs, analyzes
        results, creates follow-ups. USE WHEN: testing a hypothesis, running a
        benchmark, trying a configuration change. The issue should specify what
        to try and what to measure. SUCCESS = data captured and interpreted.

        **Compare:** Worker runs multiple scenarios, captures data from each,
        identifies differences. USE WHEN: A vs B measurements, before/after
        benchmarks, platform comparisons. The issue should specify both variants
        and what metrics to capture. SUCCESS = comparison table with analysis.

        **Fix:** Worker implements a change, rebuilds, tests, verifies. USE WHEN:
        known bugs with proposed solution or clear direction. CRITICAL: the issue
        description must specify acceptance criteria beyond "compiles and runs" —
        e.g., "benchmark numbers showing improvement," "crash does not reproduce
        under test X." Without this, workers will close after a smoke test
        (observed repeatedly).

        **Trace:** Worker follows execution flow through specified code paths,
        documents the call chain and key decision points. USE WHEN: understanding
        how data flows through a pipeline, identifying where a transformation
        happens. SUCCESS = documented sequence with file:line references.

        **Instrument:** Worker adds logging/tracing to code paths, rebuilds,
        verifies output. USE WHEN: you need runtime data that isn't available
        from source reading alone. The issue should specify what events to
        capture and where to add instrumentation.

        **Ablation:** Worker investigates removing or simplifying code and
        testing for lack of failures or performance regression. USE WHEN: a
        mechanism might be unnecessary — branches, conditionals, expressions,
        or even entire functions. When possible, bigger ablations in exchange
        for shorter code are better. Overall system function should not be
        impaired. SUCCESS = detailed comments on any differences caused by
        the ablation, or confirmation that the ablation is safe.

        ### Required fields for each issue

        Every issue description MUST include:
        1. **Goal**: One sentence. What will we know or have when this is done?
        2. **Hypothesis or deliverable**: What we expect to find, or what artifact to produce
        3. **Specific starting point**: File paths, function names, commands to run
        4. **Success criteria**: Quantitative if possible ("throughput > 5 Gbps",
           "crash does not reproduce"), otherwise a concrete observable
        5. **Recording instruction**: #{snippets[:recording_instruction]}

        ### Traceability

        #{snippets[:traceability]}
        ### Anti-patterns to avoid

        - DO NOT create issues without citing a discovered-from source
          (exception: first planning round with no closed issues)
        - DO NOT create issues with multiple objectives ("investigate A and also try B")
        - DO NOT create issues with vague goals ("improve performance", "investigate further")
        - DO NOT create issues that duplicate recently-closed work
        - DO NOT create more issues than there are generative findings to follow up

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
