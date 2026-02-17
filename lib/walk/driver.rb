# frozen_string_literal: true

# lib/walk/driver.rb — Walk driver: pick ready issues, spawn agents, plan.
#
# Backend-agnostic driver loop. Both the beads-backed walk-runner.rb and
# the directory-backed bin/walk use this class.

require "json"
require "fileutils"
require "open3"
require "logger"
require "set"

require_relative "backend"
require_relative "prompt_builder"
require_relative "retry_policy"
require_relative "planning_lifecycle"
require_relative "agent_runner"

module Walk
  class Driver
    MAX_PLANNING_ROUNDS = 3
    EXIT_CODE_RESTART = 42

    # Options:
    #   backend:        a Walk::Backend instance
    #   prompt_builder: a Walk::PromptBuilder instance
    #   parent:         optional parent epic ID (for beads backend)
    #   logs_dir:       directory for prompt/output/digest logs
    #   pid_file:       path to PID file (nil to skip)
    #   logger:         a Logger instance (nil to create default)
    #   spawn_mode:     :stream (stream-json + digest) or :capture (--print)
    #   max_turns:      max agent turns (for :capture mode)
    #   command:        override the agent command (default: "claude")
    #   sleep_interval: seconds between iterations (default: 5)
    def initialize(backend:, prompt_builder:, parent: nil, logs_dir: nil,
                   pid_file: nil, logger: nil, spawn_mode: :stream, max_turns: nil,
                   command: nil, sleep_interval: 5, model: nil, max_concurrent: 1)
      @backend = backend
      @prompt_builder = prompt_builder
      @parent = parent
      @logs_dir = logs_dir
      @pid_file = pid_file
      @logger = logger || null_logger
      @spawn_mode = spawn_mode
      @max_turns = max_turns
      @command = command
      @sleep_interval = sleep_interval
      @model = model
      @max_concurrent = [max_concurrent.to_i, 1].max
      @retry_policy = RetryPolicy.new
      @iteration = 0
      @shutdown_requested = false
      @mutex = Mutex.new
      @backend_mutex = Mutex.new
      @planning_threshold = 15_000  # bytes; adaptive, clamped to [5KB, 50KB]
      @last_planning_time = Time.now
      @planning = PlanningLifecycle.new(
        backend: @backend,
        prompt_builder: @prompt_builder,
        parent: @parent,
        logs_dir: @logs_dir,
        spawn_mode: @spawn_mode,
        build_cmd: method(:build_agent_cmd),
        log: method(:log)
      )
      @agent_runner = AgentRunner.new(
        backend: @backend,
        prompt_builder: @prompt_builder,
        retry_policy: @retry_policy,
        logs_dir: @logs_dir,
        spawn_mode: @spawn_mode,
        build_cmd: method(:build_agent_cmd),
        log: method(:log),
        backend_lock: method(:with_backend_lock)
      )
    end

    # Run the driver loop. Picks ready issues, spawns agents, plans when
    # all issues are closed.
    #
    # Options:
    #   once:    run a single issue then return
    #   dry_run: print prompts without spawning agents
    def run(once: false, dry_run: false)
      check_already_running
      write_pid_file

      log :info, "=== Walk Driver ==="
      log :info, "Started at: #{Time.now} (PID: #{Process.pid})"
      log :info, "Parent filter: #{@parent || '(none)'}"
      log :info, "Max concurrent: #{@max_concurrent}" if @max_concurrent > 1

      setup_signal_handlers

      if @max_concurrent > 1 && !once && !dry_run
        run_concurrent
      else
        run_sequential(once: once, dry_run: dry_run)
      end
    rescue SystemExit
      raise
    rescue => e
      log :error, "Driver crashed: #{e.class}: #{e.message}"
      log :error, e.backtrace.first(10).join("\n")
      raise
    end

    # Preview a prompt for a single issue (no spawning).
    def preview(issue_id)
      issue = @backend.fetch_issue(issue_id)
      unless issue
        warn "Error: Could not find issue #{issue_id}"
        return nil
      end

      is_closed = issue[:status] == "closed"

      puts "=== Preview for #{issue_id} ==="
      if is_closed
        puts "[PREVIEW: this issue is closed — prompt below is for debugging only, not sent to agents]"
        puts ""
      end
      puts "Title: #{issue[:title]}"
      puts "Priority: #{issue[:priority]}"
      puts ""
      puts "=== Full prompt ==="
      puts "---"
      prompt = @prompt_builder.build_prompt(issue, backend: @backend)
      puts prompt
      prompt
    end

    # Preview the planning prompt.
    def preview_planning(epic_id: nil)
      if @backend.respond_to?(:fetch_epic_output)
        epic_output = @backend.fetch_epic_output(epic_id || @parent)
        unless epic_output
          warn "Error: Could not find epic #{epic_id || @parent}"
          return nil
        end
      end

      puts "=== Planning prompt for #{epic_id || @parent} ==="
      puts ""
      puts "=== Full prompt ==="
      puts "---"
      prompt = @prompt_builder.build_planning_prompt(
        backend: @backend, epic_id: epic_id || @parent,
        epic_output: epic_output
      )
      puts prompt
      prompt
    end

    # Extract a digest from a stream-json output file.
    # Delegates to AgentRunner. Public so tests can call it directly.
    def extract_digest(output_file, issue_id, exit_code)
      @agent_runner.extract_digest(output_file, issue_id, exit_code)
    end

    private

    # --- Sequential loop (max_concurrent == 1, once, or dry_run) ---

    def check_restart_requested
      marker = File.join(@backend.walk_dir, "_restart_requested")
      if File.exist?(marker)
        log :info, "Restart marker found. Exiting with code #{EXIT_CODE_RESTART}."
        File.delete(marker)
        exit EXIT_CODE_RESTART
      end
    end

    def run_sequential(once: false, dry_run: false)
      planning_rounds = 0

      loop do
        check_restart_requested

        if @shutdown_requested
          log :info, "Shutdown requested, exiting sequential loop."
          finalize_walk("stopped", reason: "signal")
          return
        end

        @iteration += 1
        log :info, "--- Iteration #{@iteration} ---"

        # Check if accumulated context warrants an early planning round
        if should_plan_now?
          issues = @backend.ready_issues(parent: @parent)
          if !issues.empty?
            log :info, "Context-triggered planning — running planner before next issue."
            result = run_planning_round(dry_run: dry_run)
            return if dry_run
            return if result == :completed
            sleep @sleep_interval
            next
          end
        end

        issues = @backend.ready_issues(parent: @parent)
        log :info, "Ready issues: #{issues.length}"

        if issues.empty?
          if parent_closed?
            log :info, "Parent is closed. Exiting."
            finalize_walk("stopped", reason: "parent closed")
            return
          end

          planning_rounds += 1
          if planning_rounds > MAX_PLANNING_ROUNDS
            log :info, "Reached #{MAX_PLANNING_ROUNDS} consecutive planning rounds " \
                        "with no issues created. Exiting."
            finalize_walk("stalled",
                          reason: "#{MAX_PLANNING_ROUNDS} consecutive planning rounds with no progress")
            return
          end

          log :info, "No ready issues (planning round #{planning_rounds}/#{MAX_PLANNING_ROUNDS}). " \
                      "Spawning planning agent..."
          result = run_planning_round(dry_run: dry_run)
          return if dry_run
          return if result == :completed

          planning_rounds = 0 if result == :created
          sleep @sleep_interval
          next
        end

        planning_rounds = 0
        issue = issues.first
        issue_id = issue[:id] || issue[:slug]
        log :info, "Working on: #{issue_id} -- #{issue[:title]}"

        work_issue(issue, dry_run: dry_run)
        return if once || dry_run

        sleep @sleep_interval
      end
    end

    # --- Concurrent loop (max_concurrent > 1) ---

    SHUTDOWN_DRAIN_TIMEOUT = 30

    def run_concurrent
      planning_rounds = 0
      active_threads = {}  # issue_id => { thread:, issue: }

      loop do
        check_restart_requested

        if @shutdown_requested
          log :info, "Shutdown requested, draining #{active_threads.size} active thread(s)..."
          drain_active_threads(active_threads)
          finalize_walk("stopped", reason: "signal")
          return
        end

        @iteration += 1
        log :info, "--- Iteration #{@iteration} (active: #{active_threads.size}) ---"

        # Reap finished threads
        reap_finished_threads(active_threads)

        # Determine how many new agents we can spawn
        available_slots = @max_concurrent - active_threads.size

        if available_slots > 0
          issues = @backend.ready_issues(parent: @parent)
          # Exclude issues already being worked on
          active_ids = active_threads.keys.to_set
          candidates = issues.reject { |i| active_ids.include?(i[:id] || i[:slug]) }
          log :info, "Ready issues: #{issues.length} (#{candidates.length} available, " \
                      "#{active_threads.size} active)"

          to_spawn = candidates.first(available_slots)

          if to_spawn.any?
            planning_rounds = 0
            to_spawn.each do |issue|
              issue_id = issue[:id] || issue[:slug]
              log :info, "Spawning concurrent agent for: #{issue_id} -- #{issue[:title]}"
              thread = Thread.new(issue) do |iss|
                work_issue(iss, dry_run: false)
              end
              active_threads[issue_id] = { thread: thread, issue: issue }
            end
          end
        end

        # Context-triggered planning: if accumulated context warrants it and
        # no agents are active, run a planning round before picking next issues
        if active_threads.empty? && should_plan_now?
          issues = @backend.ready_issues(parent: @parent)
          if issues.any?
            log :info, "Context-triggered planning (concurrent) — running planner."
            result = run_planning_round(dry_run: false)
            return if result == :completed
            next
          end
        end

        # If no active threads and no ready issues, try planning (drain fallback)
        if active_threads.empty?
          issues = @backend.ready_issues(parent: @parent)
          if issues.empty?
            if parent_closed?
              log :info, "Parent is closed. Exiting."
              finalize_walk("stopped", reason: "parent closed")
              return
            end

            planning_rounds += 1
            if planning_rounds > MAX_PLANNING_ROUNDS
              log :info, "Reached #{MAX_PLANNING_ROUNDS} consecutive planning rounds " \
                          "with no issues created. Exiting."
              finalize_walk("stalled",
                            reason: "#{MAX_PLANNING_ROUNDS} consecutive planning rounds with no progress")
              return
            end

            log :info, "No ready issues and no active agents " \
                        "(planning round #{planning_rounds}/#{MAX_PLANNING_ROUNDS}). " \
                        "Spawning planning agent..."
            result = run_planning_round(dry_run: false)
            return if result == :completed

            planning_rounds = 0 if result == :created
          end
        end

        sleep @sleep_interval
      end
    end

    # Wait for active threads to finish, with a timeout.
    def drain_active_threads(active_threads)
      return if active_threads.empty?

      deadline = Time.now + SHUTDOWN_DRAIN_TIMEOUT
      active_threads.each do |issue_id, entry|
        remaining = deadline - Time.now
        if remaining > 0
          entry[:thread].join(remaining)
        end
        if entry[:thread].alive?
          log :warn, "Thread for #{issue_id} did not finish within timeout, abandoning."
        else
          log :info, "Thread for #{issue_id} finished during drain."
        end
      end
    end

    # Reap threads that have finished and log any errors.
    # Applies the same retry policy as sequential mode: tracks consecutive
    # failures and blocks issues after RetryPolicy::MAX_CONSECUTIVE_FAILURES.
    def reap_finished_threads(active_threads)
      active_threads.delete_if do |issue_id, entry|
        thread = entry[:thread]
        next false if thread.alive?

        begin
          thread.value # raises if thread raised an exception
          log :info, "Agent finished for: #{issue_id}"
        rescue => e
          log :error, "Agent thread for #{issue_id} raised: #{e.class}: #{e.message}"
          log :error, e.backtrace.first(5).join("\n")

          # Apply retry policy: check if this issue should be blocked
          issue = entry[:issue]
          failures = @retry_policy.consecutive_failures(issue)
          if @retry_policy.should_block?(failures)
            log :info, "Blocking #{issue_id} after #{failures} consecutive failures (concurrent)"
            with_backend_lock { @retry_policy.block_issue!(issue, failures, backend: @backend) }
          end
        end
        true
      end
    end

    # --- PID file management ---

    def check_already_running
      return unless @pid_file && File.exist?(@pid_file)

      old_pid = File.read(@pid_file).to_i
      if old_pid > 0 && process_running?(old_pid)
        warn "Driver already running with PID #{old_pid}"
        warn "Kill it first: kill #{old_pid}"
        exit 1
      end
    end

    def process_running?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    def write_pid_file
      return unless @pid_file

      FileUtils.mkdir_p(File.dirname(@pid_file))
      File.write(@pid_file, Process.pid.to_s)
      at_exit { FileUtils.rm_f(@pid_file) }
    end

    def setup_signal_handlers
      %w[INT TERM].each do |sig|
        Signal.trap(sig) do
          @shutdown_requested = true
          @logger.info("Received SIG#{sig}, shutting down gracefully...")
          puts "\nReceived SIG#{sig}, shutting down..."
        end
      end

      Signal.trap("HUP") do
        @logger.info("Received SIGHUP, continuing...")
      end
    end

    # --- Command building ---

    # Build the agent command array. DRYs up the four spawn methods.
    #
    # mode:       :stream or :capture
    # prompt:     the prompt string (passed via stdin to avoid argv limits)
    # max_turns:  override for --max-turns (capture mode only; nil = use @max_turns)
    def build_agent_cmd(prompt, mode:, max_turns: nil)
      case mode
      when :stream
        if @command
          Array(@command)
        else
          base = ["claude", "--verbose", "--output-format", "stream-json",
                  "--permission-mode", "bypassPermissions"]
          base += ["--model", @model] if @model
          base
        end
      when :capture
        if @command
          Array(@command)
        else
          base = ["claude", "--print", "--dangerously-skip-permissions"]
          turns = if max_turns == :extended && @max_turns
                    @max_turns * AgentRunner::EXTENDED_TURN_MULTIPLIER
                  else
                    max_turns || @max_turns
                  end
          base += ["--max-turns", turns.to_s] if turns
          base += ["--model", @model] if @model
          base
        end
      else
        raise ArgumentError, "unknown mode: #{mode.inspect}"
      end
    end

    # --- Issue lifecycle (delegated to AgentRunner) ---

    def parent_closed?
      return false unless @parent

      if @backend.respond_to?(:parent_closed?)
        @backend.parent_closed?(@parent)
      elsif @backend.respond_to?(:read_walk_meta)
        meta = @backend.read_walk_meta
        meta && meta[:status] == "closed"
      else
        false
      end
    end

    def work_issue(issue, dry_run: false)
      @agent_runner.work_issue(issue, dry_run: dry_run)
    end

    # --- Planning (delegated to PlanningLifecycle) ---

    def spawn_planning_agent(dry_run: false)
      @planning.spawn_planning_agent(dry_run: dry_run)
    end

    def finalize_walk(status, reason: nil)
      @planning.finalize_walk(status, reason: reason)
    end

    # --- Context-triggered planning ---

    PLANNING_THRESHOLD_MIN = 5_000    # bytes
    PLANNING_THRESHOLD_MAX = 50_000   # bytes

    # Check if accumulated context since last planning warrants an early round.
    # Returns true if:
    #   - Any issue closed with "pivotal" signal, OR
    #   - Cumulative new bytes > threshold AND at least one "surprising" signal
    def should_plan_now?
      return false unless @backend.respond_to?(:new_context_since)

      ctx = @backend.new_context_since(@last_planning_time)
      return false if ctx[:issues].empty?

      if ctx[:signals].include?("pivotal")
        log :info, "Pivotal signal detected in #{ctx[:issues].join(', ')} — plan now."
        return true
      end

      if ctx[:bytes] > @planning_threshold && ctx[:signals].include?("surprising")
        log :info, "Context threshold exceeded (#{ctx[:bytes]} > #{@planning_threshold}) " \
                    "with surprising signal — plan now."
        return true
      end

      false
    end

    # Wrapper around spawn_planning_agent that also updates the adaptive threshold
    # and resets the last_planning_time.
    def run_planning_round(dry_run: false)
      pre_planning_open = @backend.ready_issues(parent: @parent).size
      result = spawn_planning_agent(dry_run: dry_run)
      return result if dry_run

      @last_planning_time = Time.now

      # Adapt threshold based on planning round value
      post_planning_open = @backend.ready_issues(parent: @parent).size
      issues_created = [post_planning_open - pre_planning_open, 0].max

      if issues_created <= 1
        # Low-value planning round — raise threshold to plan less often
        @planning_threshold = [(@planning_threshold * 1.5).to_i, PLANNING_THRESHOLD_MAX].min
        log :info, "Low-value planning (#{issues_created} created) — threshold raised to #{@planning_threshold}"
      elsif issues_created >= 3
        # High-value planning round — lower threshold to be more responsive
        @planning_threshold = [(@planning_threshold * 0.75).to_i, PLANNING_THRESHOLD_MIN].max
        log :info, "High-value planning (#{issues_created} created) — threshold lowered to #{@planning_threshold}"
      end

      result
    end

    # --- Housekeeping ---

    # Serialize backend writes when running in concurrent mode.
    # In sequential mode (max_concurrent == 1), yields without locking.
    def with_backend_lock
      if @max_concurrent > 1
        @backend_mutex.synchronize { yield }
      else
        yield
      end
    end

    def log(level, msg)
      @mutex.synchronize do
        @logger.send(level, msg)
        case level
        when :info then puts msg
        when :warn then puts "WARN: #{msg}"
        when :error then puts "ERROR: #{msg}"
        end
      end
    end

    def null_logger
      Logger.new(File::NULL)
    end
  end
end
