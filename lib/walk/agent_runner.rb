# frozen_string_literal: true

# lib/walk/agent_runner.rb — Agent spawning and lifecycle for walk driver.
#
# Extracted from Driver to encapsulate the agent spawn/capture/stream
# lifecycle. The Driver delegates work_issue calls to this class.

require "json"
require "fileutils"
require "open3"
require "yaml"
require_relative "reporting"

module Walk
  class AgentRunner
    # Initialize with the dependencies needed from Driver.
    #
    # Options:
    #   backend:        a Walk::Backend instance
    #   prompt_builder: a Walk::PromptBuilder instance
    #   retry_policy:   a Walk::RetryPolicy instance
    #   logs_dir:       directory for prompt/output/digest logs
    #   spawn_mode:     :stream or :capture
    #   build_cmd:      callable(prompt, mode:, max_turns:) -> Array
    #   log:            callable(level, msg) -> void
    #   backend_lock:   callable { block } -> result (serializes backend writes)
    def initialize(backend:, prompt_builder:, retry_policy:, logs_dir: nil,
                   spawn_mode: :stream, build_cmd:, log:,
                   backend_lock:)
      @backend = backend
      @prompt_builder = prompt_builder
      @retry_policy = retry_policy
      @logs_dir = logs_dir
      @spawn_mode = spawn_mode
      @build_cmd = build_cmd
      @log = log
      @backend_lock = backend_lock
    end

    # Work a single issue. Checks retry policy, builds prompt, and
    # dispatches to stream or capture mode.
    def work_issue(issue, dry_run: false)
      issue_id = issue[:id] || issue[:slug]

      if dry_run
        puts "[DRY RUN] Would run: claude -p '...'"
        return
      end

      failures = @retry_policy.consecutive_failures(issue)

      if @retry_policy.should_block?(failures)
        log(:info, "Blocking #{issue_id} after #{failures} consecutive failures")
        with_backend_lock { @retry_policy.block_issue!(issue, failures, backend: @backend) }
        return
      end

      if @retry_policy.should_warn?(failures)
        log(:warn, "#{issue_id} has #{failures} consecutive failures — last retry before block")
        with_backend_lock do
          @backend.add_comment(issue_id,
            "[driver] Warning: #{failures} consecutive failures detected. " \
            "Next failure will block this issue.")
        end
      end

      prompt = @prompt_builder.build_prompt(issue, backend: @backend)

      if @spawn_mode == :stream
        work_issue_stream(issue, issue_id, prompt)
      else
        work_issue_capture(issue, issue_id, prompt)
      end
    end

    # Extract a digest from a stream-json output file.
    # Public so tests can call it directly.
    def extract_digest(output_file, issue_id, exit_code)
      return nil unless File.exist?(output_file)

      tools_summary = Hash.new(0)
      files_modified = []
      bd_mutations = []
      result_event = nil

      File.foreach(output_file) do |line|
        data = JSON.parse(line)

        if data["type"] == "assistant" && data.dig("message", "content").is_a?(Array)
          data["message"]["content"].each do |content|
            next unless content["type"] == "tool_use"

            name = content["name"]
            tools_summary[name] += 1
            input = content["input"] || {}

            if %w[Write Edit].include?(name) && input["file_path"]
              files_modified << input["file_path"]
            end

            if name == "Bash" && input["command"]&.match?(/\bbd\s+(?:close|create|comments\s+add)/)
              bd_mutations << input["command"]
            end
          end
        end

        result_event = data if data["type"] == "result"
      rescue JSON::ParserError
        next
      end

      status = if result_event
                 result_event["subtype"] == "success" ? "success" : "failure"
               elsif exit_code == 0
                 "success"
               else
                 "failure"
               end

      duration_s = result_event ? (result_event["duration_ms"] || 0) / 1000.0 : 0
      num_turns = result_event ? (result_event["num_turns"] || 0) : 0
      result_text = result_event ? (result_event["result"] || "")[0, 500] : ""
      cost_usd = result_event ? result_event["total_cost_usd"] : nil

      usage = result_event&.dig("usage") || {}
      token_usage = {
        input: usage["input_tokens"] || 0,
        output: usage["output_tokens"] || 0,
        cache_create: usage["cache_creation_input_tokens"] || 0,
        cache_read: usage["cache_read_input_tokens"] || 0
      }

      {
        issue_id: issue_id,
        status: status,
        duration_s: duration_s.round(1),
        num_turns: num_turns,
        tools_summary: tools_summary.sort_by { |_, v| -v }.to_h,
        files_modified: files_modified.uniq,
        bd_mutations: bd_mutations,
        result_text: result_text,
        token_usage: token_usage,
        cost_usd: cost_usd,
        timestamp: Time.now.utc.iso8601
      }
    end

    private

    def work_issue_stream(issue, issue_id, prompt)
      type = @prompt_builder.issue_type(issue)
      FileUtils.mkdir_p(@logs_dir) if @logs_dir
      timestamp = Time.now.strftime("%Y%m%d-%H%M%S")
      prompt_file = @logs_dir ? File.join(@logs_dir, "#{timestamp}-#{issue_id}.txt") : nil
      output_file = @logs_dir ? File.join(@logs_dir, "#{timestamp}-#{issue_id}-output.jsonl") : nil

      File.write(prompt_file, prompt) if prompt_file

      lines = prompt.lines.count
      with_backend_lock do
        @backend.add_comment(issue_id,
          "Agent started. Type: #{type} | Lines: #{lines}")
      end

      log(:info, "Spawning Claude agent (stream mode)...")
      log(:info, "  Prompt logged to: #{prompt_file}") if prompt_file

      cmd = @build_cmd.call(prompt, mode: :stream)

      # Create runs/ symlink before spawning so we can track current work
      run_symlink = nil
      if @backend.respond_to?(:walk_dir) && output_file
        runs_dir = File.join(@backend.walk_dir, "runs")
        FileUtils.mkdir_p(runs_dir)
        run_symlink = File.join(runs_dir, issue_id)
        FileUtils.rm_f(run_symlink)  # Remove stale symlink
        File.symlink(output_file, run_symlink)
      end

      started_at = Time.now
      # Use stdin pipe to pass prompt (avoids argv length limits with large prompts)
      stdin_r, stdin_w = IO.pipe
      pid = if output_file
              spawn(*cmd, in: stdin_r, out: [output_file, "w"], err: [:child, :out])
            else
              spawn(*cmd, in: stdin_r)
            end
      stdin_r.close
      stdin_w.write(prompt)
      stdin_w.close

      exit_code = wait_for_agent(pid)
      finished_at = Time.now

      # Remove the runs/ symlink now that agent is done
      FileUtils.rm_f(run_symlink) if run_symlink

      if output_file && @logs_dir
        digest = extract_digest(output_file, issue_id, exit_code)
        if digest
          digest_file = File.join(@logs_dir, "#{timestamp}-#{issue_id}-digest.json")
          File.write(digest_file, JSON.pretty_generate(digest))
          log(:info, "Digest written to: #{digest_file}")

          # Write per-issue run artifacts (meta, prompt, output symlink)
          write_stream_run_meta(issue, timestamp, prompt, output_file,
                                started_at, finished_at, exit_code, digest)

          duration = Reporting.format_duration(digest[:duration_s])
          cost_part = digest[:cost_usd] ? " Cost: $#{"%.2f" % digest[:cost_usd]}." : ""
          stats = "[driver] Run stats: #{duration}, #{digest[:num_turns]} turns, " \
                  "#{digest[:tools_summary].values.sum} tools. " \
                  "Status: #{digest[:status]}.#{cost_part}"
          with_backend_lock { @backend.add_comment(issue_id, stats) }
        end
      end

      cleanup_old_logs if @logs_dir

      # Check for result.md and auto-close (same as capture mode)
      check_and_close_on_result(issue, issue_id)
    end

    # Check for result.md or close.yaml and close the issue if present.
    # Used by both stream and capture modes.
    # Handles both: (1) agent wrote result.md, driver closes, or
    #               (2) agent called `walk close`, issue already moved.
    def check_and_close_on_result(issue, issue_id)
      dir = issue[:dir]
      return :no_dir unless dir

      # If issue directory no longer exists in open/, check if agent already closed it
      unless Dir.exist?(dir)
        if @backend.respond_to?(:walk_dir)
          closed_dir = File.join(@backend.walk_dir, "closed", issue_id)
          if Dir.exist?(closed_dir)
            log(:info, "Issue #{issue_id} already closed by agent (via walk close)")
            return :closed
          end
        end
        log(:warn, "Issue directory missing: #{dir}")
        return :no_dir
      end

      close_yaml = File.join(dir, "close.yaml")
      result_file = File.join(dir, "result.md")

      if File.exist?(close_yaml)
        meta = YAML.safe_load(File.read(close_yaml), permitted_classes: [Time]) || {}
        reason = meta["reason"] || "completed"
        with_backend_lock do
          @backend.close_issue(issue_id, reason: reason, status: meta["status"] || "closed")
        end
        log(:info, "Issue #{issue_id} closed via close.yaml")
        :closed
      elsif File.exist?(result_file)
        reason = File.read(result_file).lines.first&.strip || "completed"
        with_backend_lock { @backend.close_issue(issue_id, reason: reason) }
        log(:info, "Issue #{issue_id} closed via result.md")
        :closed
      else
        log(:info, "Agent finished without closing #{issue_id}")
        :open
      end
    end

    # Issue types that typically need more turns (code changes, testing, committing).
    EXTENDED_TURN_TYPES = %i[fix meta ablation].freeze
    EXTENDED_TURN_MULTIPLIER = 2

    def work_issue_capture(issue, issue_id, prompt)
      type = @prompt_builder.issue_type(issue)
      if EXTENDED_TURN_TYPES.include?(type)
        log(:info, "Issue type :#{type} — using extended max_turns (#{EXTENDED_TURN_MULTIPLIER}x)")
      end

      log(:info, "Spawning Claude agent (capture mode)...")
      with_backend_lock { @backend.add_comment(issue_id, "Agent spawned by walk driver") }

      max_turns_for_type = EXTENDED_TURN_TYPES.include?(type) ? :extended : nil
      cmd = @build_cmd.call(prompt, mode: :capture, max_turns: max_turns_for_type)

      env = {}
      # Set env vars for directory-backend agents
      if @backend.respond_to?(:walk_dir)
        env["WALK_DIR"] = @backend.walk_dir
        env["WALK_ISSUE"] = issue[:slug] || issue_id
      end

      # Create per-issue runs/ directory for log storage
      run_dir = nil
      started_at = Time.now
      if issue[:dir]
        base_ts = started_at.strftime("%Y%m%d-%H%M%S")
        runs_parent = File.join(issue[:dir], "runs")
        FileUtils.mkdir_p(runs_parent)
        # Disambiguate runs within the same second
        timestamp = base_ts
        suffix = 1
        while Dir.exist?(File.join(runs_parent, timestamp))
          timestamp = "#{base_ts}-#{suffix}"
          suffix += 1
        end
        run_dir = File.join(runs_parent, timestamp)
        FileUtils.mkdir_p(run_dir)
        File.write(File.join(run_dir, "prompt.txt"), prompt)
      end

      stdout, stderr, status = Open3.capture3(env, *cmd, stdin_data: prompt)
      finished_at = Time.now

      log(:info, "Agent exit status: #{status.exitstatus}")

      # Write run artifacts
      # Issue may have been closed/moved during execution - relocate run_dir
      if run_dir && !Dir.exist?(run_dir)
        current_issue = @backend.show_issue(issue[:id] || issue[:slug])
        if current_issue && current_issue[:dir] && Dir.exist?(current_issue[:dir])
          runs_parent = File.join(current_issue[:dir], "runs")
          FileUtils.mkdir_p(runs_parent)
          run_dir = File.join(runs_parent, started_at.strftime("%Y%m%d-%H%M%S"))
          FileUtils.mkdir_p(run_dir)
        else
          run_dir = nil
        end
      end
      if run_dir
        File.write(File.join(run_dir, "output.txt"), stdout || "")
        File.write(File.join(run_dir, "stderr.txt"), stderr || "")
        File.write(File.join(run_dir, "meta.json"), JSON.pretty_generate(
          exit_code: status.exitstatus,
          started_at: started_at.iso8601,
          finished_at: finished_at.iso8601,
          pid: status.pid
        ))
      end

      handle_capture_result(issue, issue_id, stdout, stderr, status)
    end

    def handle_capture_result(issue, issue_id, stdout, stderr, status)
      result = check_and_close_on_result(issue, issue_id)

      # In capture mode, log stdout/stderr on failure to close
      if result == :open
        with_backend_lock do
          @backend.add_comment(issue_id,
            "Agent finished without closing.\n\nStdout:\n```\n#{stdout&.slice(0, 2000)}\n```\n\nStderr:\n```\n#{stderr&.slice(0, 500)}\n```")
        end
      end

      result
    end

    def wait_for_agent(pid)
      Process.wait(pid)
      status = $?
      exit_code = status.exitstatus || status.termsig

      if status.signaled?
        log(:warn, "Claude killed by signal #{status.termsig} (#{Signal.signame(status.termsig)})")
      elsif exit_code != 0
        log(:warn, "Claude exited with status #{exit_code}")
      else
        log(:info, "Claude exited normally at #{Time.now}")
      end

      exit_code
    rescue Errno::ECHILD
      log(:warn, "Claude process already reaped")
      -1
    end

    def write_stream_run_meta(issue, timestamp, prompt, output_file,
                              started_at, finished_at, exit_code, digest)
      dir = issue[:dir]
      return unless dir

      # Issue may have been closed/moved during execution - find current location
      unless Dir.exist?(dir)
        # Try to find new location via backend
        current_issue = @backend.show_issue(issue[:id] || issue[:slug])
        dir = current_issue[:dir] if current_issue && current_issue[:dir]
        return unless dir && Dir.exist?(dir)
      end

      runs_parent = File.join(dir, "runs")
      FileUtils.mkdir_p(runs_parent)
      run_dir = File.join(runs_parent, timestamp)
      FileUtils.mkdir_p(run_dir)

      meta = {
        exit_code: exit_code,
        started_at: started_at.iso8601,
        finished_at: finished_at.iso8601,
        cost_usd: digest[:cost_usd],
        token_usage: digest[:token_usage]
      }
      File.write(File.join(run_dir, "meta.json"), JSON.pretty_generate(meta))
      File.write(File.join(run_dir, "prompt.txt"), prompt)

      # Symlink the stream output file for easy access from per-issue runs/
      if output_file && File.exist?(output_file)
        link_path = File.join(run_dir, "output.jsonl")
        target = File.expand_path(output_file)
        File.symlink(target, link_path) rescue nil
      end
    end

    def cleanup_old_logs
      return unless @logs_dir

      # Keep 4 weeks of logs (time-based retention)
      cutoff = Time.now - (28 * 24 * 60 * 60)

      Dir.glob(File.join(@logs_dir, "*-output.jsonl")).each do |output_file|
        next if File.mtime(output_file) > cutoff

        # Delete the log set (prompt.txt, output.jsonl, digest.json)
        base = output_file.sub(/-output\.jsonl$/, "")
        [output_file, "#{base}.txt", "#{base}-digest.json"].each do |f|
          File.delete(f) rescue nil
        end
      end
    end

    def log(level, msg)
      @log.call(level, msg)
    end

    def with_backend_lock(&block)
      @backend_lock.call(&block)
    end
  end
end
