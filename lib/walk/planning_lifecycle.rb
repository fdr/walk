# frozen_string_literal: true

# lib/walk/planning_lifecycle.rb — Planning lifecycle for walk driver.
#
# Extracted from Driver to encapsulate the planning agent spawning,
# result file protocol, walk finalization, and summary generation.
# The Driver delegates planning calls to this class.

require "fileutils"
require "open3"
require "yaml"
require "json"
require "time"
require_relative "reporting"

module Walk
  class PlanningLifecycle
    # Initialize with the dependencies needed from Driver.
    #
    # Options:
    #   backend:        a Walk::Backend instance
    #   prompt_builder: a Walk::PromptBuilder instance
    #   parent:         optional parent epic ID
    #   logs_dir:       directory for prompt/output logs
    #   spawn_mode:     :stream or :capture
    #   build_cmd:      callable(prompt, mode:, max_turns:) -> Array
    #   log:            callable(level, msg) -> void
    def initialize(backend:, prompt_builder:, parent: nil, logs_dir: nil,
                   spawn_mode: :stream, build_cmd:, log:)
      @backend = backend
      @prompt_builder = prompt_builder
      @parent = parent
      @logs_dir = logs_dir
      @spawn_mode = spawn_mode
      @build_cmd = build_cmd
      @log = log
    end

    # Spawn a planning agent. Returns :dry_run, :skip, :created, :empty,
    # or :completed.
    def spawn_planning_agent(dry_run: false)
      # Increment epoch at start of each planning round
      if @backend.respond_to?(:increment_epoch) && !dry_run
        new_epoch = @backend.increment_epoch
        log(:info, "Starting planning epoch #{new_epoch}")
      end

      if @backend.respond_to?(:fetch_epic_output)
        epic_id = @parent
        unless epic_id
          log(:warn, "No --parent specified, cannot spawn planning agent")
          return :skip
        end

        epic_output = @backend.fetch_epic_output(epic_id)
        return :skip unless epic_output

        prompt = @prompt_builder.build_planning_prompt(
          backend: @backend, epic_id: epic_id, epic_output: epic_output
        )
      else
        prompt = @prompt_builder.build_planning_prompt(backend: @backend)
      end

      if dry_run
        log(:info, "DRY RUN: would spawn planning agent")
        puts "=== Planning prompt ==="
        puts prompt
        return :dry_run
      end

      if @spawn_mode == :stream
        spawn_planning_stream(prompt)
      else
        spawn_planning_capture(prompt)
      end
    end

    # Finalize the walk with a status and optional reason. Updates the
    # backend status and writes a summary file.
    def finalize_walk(status, reason: nil)
      if @backend.respond_to?(:update_walk_status)
        @backend.update_walk_status(status, reason: reason)
        log(:info, "Walk status updated to '#{status}': #{reason}")
      end
      write_walk_summary
    end

    private

    def spawn_planning_stream(prompt)
      FileUtils.mkdir_p(@logs_dir) if @logs_dir
      timestamp = Time.now.strftime("%Y%m%d-%H%M%S")
      prompt_file = @logs_dir ? File.join(@logs_dir, "#{timestamp}-planning.txt") : nil
      output_file = @logs_dir ? File.join(@logs_dir, "#{timestamp}-planning-output.jsonl") : nil

      File.write(prompt_file, prompt) if prompt_file
      log(:info, "  Prompt: #{prompt_file}") if prompt_file
      log(:info, "  Output: #{output_file}") if output_file

      log(:info, "Planning agent started at #{Time.now}...")

      cmd = @build_cmd.call(prompt, mode: :stream)

      pid = if output_file
              spawn(*cmd, out: [output_file, "w"], err: [:child, :out])
            else
              spawn(*cmd)
            end
      Process.wait(pid)

      log(:info, "Planning agent exited at #{Time.now} with status #{$?.exitstatus}")

      result = handle_planning_result
      return result if result

      :created
    end

    def spawn_planning_capture(prompt)
      log(:info, "Spawning planning agent (capture mode)...")

      cmd = @build_cmd.call(prompt, mode: :capture, max_turns: 10)

      env = {}
      if @backend.respond_to?(:walk_dir)
        env["WALK_DIR"] = @backend.walk_dir
        env["WALK_PLANNING"] = "1"
      end

      stdout, _stderr, _status = Open3.capture3(env, *cmd, stdin_data: prompt)

      result = handle_planning_result
      return result if result

      new_issues = @backend.ready_issues(parent: @parent)
      if new_issues.any?
        log(:info, "Planning agent created #{new_issues.length} new issue(s)")
        :created
      else
        log(:info, "Planning agent did not create any new issues")
        log(:info, "Planning stdout (first 500 chars): #{stdout&.slice(0, 500)}") if stdout
        :empty
      end
    end

    # --- Planning result file protocol ---

    def planning_result_path
      if @backend.respond_to?(:walk_dir)
        File.join(@backend.walk_dir, "_planning_result.md")
      end
    end

    def read_planning_result
      path = planning_result_path
      return nil unless path && File.exist?(path)

      content = File.read(path)
      File.delete(path)

      if content =~ /\A---\n(.*?\n)---/m
        frontmatter = YAML.safe_load(Regexp.last_match(1)) || {}
        outcome = frontmatter["outcome"]
        reason = frontmatter["reason"]
        { outcome: outcome, reason: reason }
      end
    rescue => e
      log(:warn, "Failed to read planning result: #{e.message}")
      nil
    end

    def handle_planning_result
      result = read_planning_result
      return nil unless result

      case result[:outcome]
      when "completed"
        log(:info, "Planning agent signaled walk completion: #{result[:reason]}")
        finalize_walk("completed", reason: result[:reason])
        :completed
      when "created_issues"
        log(:info, "Planning agent signaled issues created: #{result[:reason]}")
        :created
      when "no_work_found"
        log(:info, "Planning agent signaled no work found: #{result[:reason]}")
        :empty
      else
        log(:warn, "Unknown planning outcome: #{result[:outcome]}")
        nil
      end
    end

    # --- Walk summary ---

    def write_walk_summary
      return unless @backend.respond_to?(:walk_dir)

      data = Reporting.walk_data(@backend)
      content = Reporting.render_summary_markdown(data, include_finished_at: true)

      summary_path = File.join(@backend.walk_dir, "summary.md")
      File.write(summary_path, content)
      log(:info, "Walk summary written to: #{summary_path}")
    rescue => e
      log(:warn, "Failed to write walk summary: #{e.message}")
    end

    def log(level, msg)
      @log.call(level, msg)
    end
  end
end
