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

      lines = ["You are working in #{@project_dir}."]
      if @claude_md_path && File.exist?(@claude_md_path)
        lines << "Your context file is #{@claude_md_path} - READ IT FIRST."
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
          - Document approach and findings as you go (write notes to #{dir}/comments.md).
          - Create sub-issues for follow-up work by creating directories under open/ with issue.md files.
          - Close ONLY when you have concrete results (code traced, comparison done, experiment ran, fix tested)
          - DO NOT close with "need more investigation" - leave open or create specific sub-issues instead
          - Close with rationale: write a file called "result.md" in this directory:
            #{dir}
            The file should contain your findings/result.
            The first line of result.md will be used as the close reason.
          - EXIT immediately after closing. The driver restarts you with fresh context.
        S
        live_comment_watching: <<~S.chomp,
          LIVE FEEDBACK (for user steering during execution):
          - Periodically check for new feedback (every few major steps):
            cat #{dir}/comments.md | tail -40
          - Look for entries timestamped AFTER your agent start time (#{Time.now.strftime('%H:%M')})
            that you did NOT write — these are human feedback
          - Incorporate any user direction into your work
          - This lets the user communicate with you while you run
        S
        git_branch_doc: "Document the branch name in #{dir}/comments.md so the next agent can find it"
      }
    end

    # Shared epilogue structure used by both backends.
    # Accepts a hash of backend-specific snippets:
    #   :driver_protocol       - scope, progress docs, close commands
    #   :live_comment_watching  - (optional) bd-specific comment watching
    #   :git_branch_doc         - how to document git branch name
    def build_shared_epilogue(snippets)
      parts = [snippets[:driver_protocol]]
      parts << snippets[:live_comment_watching] if snippets[:live_comment_watching]
      parts << <<~GIT.chomp
        GIT HYGIENE (MANDATORY -- other agents share these trees):
        If you modify source code in any shared repo:
        1. EXPLORE first: run `git branch` and `git log --oneline --all --graph | head -30`
        2. Make atomic commits with clear messages describing what and why
        3. After building and testing, verify the branch is clean (git status)
        4. NEVER leave uncommitted changes -- commit or stash before exiting
        5. NEVER force-push or delete existing branches
        6. NEVER commit to master/main directly
        7. #{snippets[:git_branch_doc]}
      GIT
      parts << <<~NAMING.chomp
        SUB-ISSUE NAMING (optional prefixes, helps driver pick instructions):
        - Investigate: - research/analysis
        - Instrument: - adding logging/tracing
        - Trace: - following execution flow
        - Compare: - A vs B comparisons
        - Experiment: - trying things
        - Fix: - implementing fixes
        Or just use a descriptive title - the driver will give general instructions.
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
      closed = backend.list_issues(status: "closed")
      walk_dir = backend.walk_dir
      open_dir = File.join(walk_dir, "open")

      walk_section = if meta
        "## Walk: #{meta[:title]}\n\n#{meta[:body]}"
      else
        "## Walk\n\n(No _walk.md found.)"
      end

      closed_context = if closed.empty?
        "No closed issues yet."
      else
        closed.map { |i|
          parts = ["### #{i[:slug]} -- #{i[:title]}"]
          parts << "Type: #{i[:type]} | Closed: #{i[:closed_at]}"
          parts << "Close reason: #{i[:close_reason]}" if i[:close_reason]
          if i[:result]
            parts << ""
            parts << "**Result:**"
            parts << i[:result]
          end
          parts.join("\n")
        }.join("\n\n---\n\n")
      end

      claude_md_section = if claude_md.empty?
        ""
      else
        "\n---\n\n#{claude_md}\n\n---\n"
      end

      snippets = {
        preamble: <<~S,
          You are a planning agent for a walk exploration.
          Working directory: #{walk_dir}
          #{claude_md_section}
          #{walk_section}

          ## Closed Issues (what has been done so far)

          #{closed_context}
        S
        exploration_steps: <<~S,
          Review the closed issues above. Then:
          1. Check for result files in closed issue directories
          2. Check git state of repos that were modified: git log --oneline -5 in relevant repos
          3. Read any source files that recent issues referenced as changed
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

        Choose the right type. The worker agent receives type-specific instructions:

        **Investigate:** Worker is told to search source code, read files, document
        findings, and create child issues. USE FOR: tracing code paths, analyzing
        architecture, understanding why something behaves a certain way.

        **Experiment:** Worker is told to try an approach, capture output/logs,
        analyze results, and create follow-ups. USE FOR: testing a specific
        hypothesis, running a benchmark, trying a configuration change.

        **Compare:** Worker is told to run scenarios, capture data from each
        variant, identify differences, and produce a comparison. USE FOR:
        A vs B measurements, before/after benchmarks.

        **Fix:** Worker is told to implement a fix, rebuild, test, and verify
        the original problem is resolved. USE FOR: known bugs with a proposed
        solution or clear direction.

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
