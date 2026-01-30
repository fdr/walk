# frozen_string_literal: true

# test_walk_driver_loop.rb — End-to-end driver loop tests with mock agent.
#
# Exercises the full Walk::Driver loop (pick issue -> spawn agent -> detect
# close -> pick next -> planning when empty) using a mock agent script
# instead of Claude. No network or Claude CLI required.
#
# Usage:
#   ruby test/test_walk_driver_loop.rb

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "yaml"
require "logger"

require_relative "../lib/walk/driver"
require_relative "../lib/walk/directory_backend"
require_relative "../lib/walk/prompt_builder"

class WalkDriverLoopTest < Minitest::Test
  MOCK_AGENT = File.expand_path("mock-agent.rb", __dir__)

  def setup
    @tmpdir = Dir.mktmpdir("walk-loop-test-")
    @open_dir = File.join(@tmpdir, "open")
    @closed_dir = File.join(@tmpdir, "closed")
    FileUtils.mkdir_p(@open_dir)
    FileUtils.mkdir_p(@closed_dir)

    write_walk_meta(title: "Loop Test Walk", status: "open")

    @backend = Walk::DirectoryBackend.new(@tmpdir)
    @prompt_builder = Walk::PromptBuilder.new(
      project_dir: @tmpdir,
      close_protocol: :result_md
    )
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- Helpers ---

  def create_issue(slug, title: slug, priority: 2, body: "Test body.")
    dir = File.join(@open_dir, slug)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "issue.md"),
               yaml_frontmatter({ "title" => title, "type" => "task", "priority" => priority }, body))
    dir
  end

  def write_walk_meta(title:, status: "open")
    File.write(File.join(@tmpdir, "_walk.md"),
               yaml_frontmatter({ "title" => title, "status" => status },
                                 "Test walk for driver loop testing."))
  end

  def yaml_frontmatter(hash, body = nil)
    yaml = YAML.dump(hash).sub(/\.\.\.\n\z/, "")
    body ? "#{yaml}---\n\n#{body}\n" : "#{yaml}---\n"
  end

  def build_driver(**overrides)
    Walk::Driver.new(
      backend: @backend,
      prompt_builder: @prompt_builder,
      spawn_mode: :capture,
      command: ["ruby", MOCK_AGENT],
      sleep_interval: 0,
      logger: Logger.new(File::NULL),
      **overrides
    )
  end

  # --- Tests ---

  # 1. Single issue: driver picks it, mock agent closes it via result.md
  def test_once_mode_closes_single_issue
    create_issue("task-alpha", title: "Alpha task", priority: 1)

    driver = build_driver
    driver.run(once: true)

    refute Dir.exist?(File.join(@open_dir, "task-alpha")),
           "task-alpha should be moved out of open/"
    assert Dir.exist?(File.join(@closed_dir, "task-alpha")),
           "task-alpha should be in closed/"
    assert File.exist?(File.join(@closed_dir, "task-alpha", "result.md")),
           "result.md should exist in closed dir"
  end

  # 2. Two issues: driver processes both sequentially in loop mode.
  #    We test this by checking that both end up closed.
  #    The driver loop will: pick first -> close -> pick second -> close ->
  #    no issues -> planning (no create) -> planning round 2 -> ... -> exit
  def test_loop_closes_two_issues_then_exits
    create_issue("task-alpha", title: "Alpha task", priority: 1)
    create_issue("task-beta", title: "Beta task", priority: 2)

    driver = build_driver
    driver.run

    # Both issues should be closed
    refute Dir.exist?(File.join(@open_dir, "task-alpha")),
           "task-alpha should not be in open/"
    refute Dir.exist?(File.join(@open_dir, "task-beta")),
           "task-beta should not be in open/"
    assert Dir.exist?(File.join(@closed_dir, "task-alpha")),
           "task-alpha should be in closed/"
    assert Dir.exist?(File.join(@closed_dir, "task-beta")),
           "task-beta should be in closed/"
  end

  # 3. Priority ordering: highest priority (lowest number) is picked first.
  def test_picks_highest_priority_first
    create_issue("low-pri", title: "Low priority", priority: 3)
    create_issue("high-pri", title: "High priority", priority: 1)

    driver = build_driver
    driver.run(once: true)

    # high-pri should be closed first (picked first due to priority 1)
    assert Dir.exist?(File.join(@closed_dir, "high-pri")),
           "high-pri should be closed first"
    assert Dir.exist?(File.join(@open_dir, "low-pri")),
           "low-pri should still be open"
  end

  # 4. Close detection: driver reads result.md first line as close reason.
  def test_close_reason_from_result_md
    create_issue("reason-test", title: "Reason test", priority: 1)

    driver = build_driver
    driver.run(once: true)

    close_yaml = File.join(@closed_dir, "reason-test", "close.yaml")
    assert File.exist?(close_yaml), "close.yaml should exist"
    meta = YAML.safe_load(File.read(close_yaml), permitted_classes: [Time])
    assert_includes meta["reason"], "Mock agent completed reason-test"
  end

  # 5. Planning agent triggered when no issues remain and creates no issues,
  #    so MAX_PLANNING_ROUNDS is respected.
  def test_planning_rounds_limit_causes_exit
    # No issues at all — driver should enter planning immediately
    # Mock agent in planning mode creates no issues (no WALK_PLAN_CREATE env),
    # so planning returns :empty, and after MAX_PLANNING_ROUNDS the driver exits.
    driver = build_driver
    # This should exit after MAX_PLANNING_ROUNDS (3) planning attempts
    driver.run

    # The driver should have exited cleanly (no crash).
    # Verify open/ is still empty (no issues created by planning).
    assert_equal 0, Dir.glob(File.join(@open_dir, "*")).length,
                 "No issues should have been created"
  end

  # 6. Planning agent creates issues when WALK_PLAN_CREATE is set.
  #    We test this by setting up env so the mock creates an issue on
  #    the first planning round.
  def test_planning_creates_issue_which_gets_worked
    # Start with no issues. We need the planning mock to create one.
    # We'll use a custom mock script that creates an issue the first time.
    planning_mock = File.join(@tmpdir, "planning-mock.rb")
    File.write(planning_mock, <<~'RUBY')
      #!/usr/bin/env ruby
      # frozen_string_literal: true
      prompt = $stdin.read
      walk_dir = ENV["WALK_DIR"]
      walk_issue = ENV["WALK_ISSUE"]
      planning = ENV["WALK_PLANNING"] == "1"

      if planning
        marker = File.join(walk_dir, ".planning_done")
        unless File.exist?(marker)
          # First planning round: create an issue
          slug = "planned-task"
          dir = File.join(walk_dir, "open", slug)
          Dir.mkdir(dir) unless Dir.exist?(dir)
          File.write(File.join(dir, "issue.md"), <<~MD)
            ---
            title: "Planned task"
            type: task
            priority: 1
            ---

            Created by planning mock.
          MD
          File.write(marker, "done")
        end
        # Subsequent planning rounds: do nothing (triggers MAX_PLANNING_ROUNDS exit)
        exit 0
      end

      # Worker mode: close the issue
      if walk_dir && walk_issue
        issue_dir = File.join(walk_dir, "open", walk_issue)
        if Dir.exist?(issue_dir)
          File.write(File.join(issue_dir, "result.md"),
                     "Planned task completed.\nDone.\n")
        end
      end
      exit 0
    RUBY

    driver = build_driver(command: ["ruby", planning_mock])
    driver.run

    # The planned-task should have been created and then closed
    assert Dir.exist?(File.join(@closed_dir, "planned-task")),
           "planned-task should have been created by planning and closed by worker"
    assert File.exist?(File.join(@closed_dir, "planned-task", "result.md")),
           "result.md should exist for the planned task"
  end

  # 7. Agent comment is added when issue is started
  def test_agent_comment_added_on_start
    dir = create_issue("commented-task", title: "Commented task", priority: 1)

    driver = build_driver
    driver.run(once: true)

    # After close, the comments file should exist in closed/
    comments_file = File.join(@closed_dir, "commented-task", "comments.md")
    assert File.exist?(comments_file), "comments.md should exist"
    comments = File.read(comments_file)
    assert_includes comments, "Agent spawned by walk driver"
  end

  # 8. Prompt includes issue slug and result.md protocol
  def test_prompt_includes_issue_fields
    create_issue("prompt-check", title: "Prompt check task", priority: 1)
    issue = @backend.fetch_issue("prompt-check")
    prompt = @prompt_builder.build_prompt(issue, backend: @backend)

    assert_includes prompt, "prompt-check"
    assert_includes prompt, "result.md"
  end

  # 9. Walk meta is passed as parent context
  def test_parent_context_from_walk_meta
    create_issue("context-test", title: "Context test", priority: 1)
    issue = @backend.fetch_issue("context-test")
    context = @backend.load_parent_context(issue)

    assert_includes context, "Loop Test Walk"
  end

  # 10. Runs directory: prompt.txt and output.txt are created
  def test_runs_directory_created_with_artifacts
    create_issue("runs-test", title: "Runs test", priority: 1)

    driver = build_driver
    driver.run(once: true)

    # Issue should be closed
    closed_dir = File.join(@closed_dir, "runs-test")
    assert Dir.exist?(closed_dir), "runs-test should be in closed/"

    # runs/ directory should exist and contain one timestamped run
    runs_dir = File.join(closed_dir, "runs")
    assert Dir.exist?(runs_dir), "runs/ directory should exist"

    run_dirs = Dir.children(runs_dir).sort
    assert_equal 1, run_dirs.length, "Should have exactly one run"

    run_dir = File.join(runs_dir, run_dirs.first)
    assert File.exist?(File.join(run_dir, "prompt.txt")), "prompt.txt should exist"
    assert File.exist?(File.join(run_dir, "output.txt")), "output.txt should exist"
    assert File.exist?(File.join(run_dir, "stderr.txt")), "stderr.txt should exist"
    assert File.exist?(File.join(run_dir, "meta.json")), "meta.json should exist"

    # Verify prompt.txt contains something
    prompt = File.read(File.join(run_dir, "prompt.txt"))
    refute_empty prompt, "prompt.txt should not be empty"
    assert_includes prompt, "runs-test", "prompt should reference the issue slug"

    # Verify output.txt contains mock agent output
    output = File.read(File.join(run_dir, "output.txt"))
    assert_includes output, "Mock agent processed runs-test"

    # Verify meta.json has expected fields
    meta = JSON.parse(File.read(File.join(run_dir, "meta.json")))
    assert_equal 0, meta["exit_code"]
    assert meta["started_at"], "meta should have started_at"
    assert meta["finished_at"], "meta should have finished_at"
    assert meta["pid"], "meta should have pid"
  end

  # 11. Runs directory survives open/ -> closed/ move
  def test_runs_survive_close_move
    create_issue("survive-test", title: "Survive test", priority: 1)

    driver = build_driver
    driver.run(once: true)

    # The entire issue directory (including runs/) should be in closed/
    closed_issue_dir = File.join(@closed_dir, "survive-test")
    assert Dir.exist?(closed_issue_dir), "survive-test should be in closed/"

    runs_dir = File.join(closed_issue_dir, "runs")
    assert Dir.exist?(runs_dir), "runs/ should survive the move to closed/"

    run_dirs = Dir.children(runs_dir)
    assert_equal 1, run_dirs.length, "run directory should survive the move"

    run_dir = File.join(runs_dir, run_dirs.first)
    %w[prompt.txt output.txt stderr.txt meta.json].each do |file|
      assert File.exist?(File.join(run_dir, file)),
             "#{file} should survive the move to closed/"
    end
  end

  # 12. Runs timestamp directory name matches expected format
  def test_runs_timestamp_format
    create_issue("ts-test", title: "Timestamp test", priority: 1)

    driver = build_driver
    driver.run(once: true)

    runs_dir = File.join(@closed_dir, "ts-test", "runs")
    assert Dir.exist?(runs_dir)

    run_dirs = Dir.children(runs_dir)
    assert_equal 1, run_dirs.length
    assert_match(/\A\d{8}-\d{6}\z/, run_dirs.first,
                 "Run directory name should be YYYYMMDD-HHMMSS format")
  end

  # 13. Dry run does not spawn agents
  def test_dry_run_does_not_close
    create_issue("dry-task", title: "Dry task", priority: 1)

    driver = build_driver
    driver.run(once: true, dry_run: true)

    assert Dir.exist?(File.join(@open_dir, "dry-task")),
           "dry-task should still be open in dry_run mode"
    refute Dir.exist?(File.join(@closed_dir, "dry-task")),
           "dry-task should NOT be in closed/"
  end

  # 14. walk_status includes per-issue run metadata after driver closes issues
  def test_walk_status_includes_run_metadata
    create_issue("status-alpha", title: "Status alpha", priority: 1)
    create_issue("status-beta", title: "Status beta", priority: 2)

    driver = build_driver
    driver.run

    # Both should be closed now
    assert Dir.exist?(File.join(@closed_dir, "status-alpha"))
    assert Dir.exist?(File.join(@closed_dir, "status-beta"))

    status = @backend.walk_status

    # Aggregate stats
    assert_operator status[:total_runs], :>=, 2,
                    "Should have at least 2 runs (one per issue)"
    assert_operator status[:total_duration], :>=, 0,
                    "Total duration should be non-negative"
    assert_operator status[:success_count], :>=, 2,
                    "Both runs should succeed"
    assert_equal 0, status[:failure_count],
                 "No runs should fail"

    # Per-issue summaries
    summaries = status[:issue_summaries]
    assert_kind_of Array, summaries
    assert_equal 2, summaries.length, "Should have 2 issue summaries"

    slugs = summaries.map { |s| s[:slug] }
    assert_includes slugs, "status-alpha"
    assert_includes slugs, "status-beta"

    summaries.each do |s|
      assert_equal "closed", s[:status], "#{s[:slug]} should be closed"
      assert_operator s[:run_count], :>=, 1, "#{s[:slug]} should have at least 1 run"
      assert_operator s[:total_duration], :>=, 0, "#{s[:slug]} duration should be non-negative"
      assert_equal 0, s[:last_exit_code], "#{s[:slug]} last exit code should be 0"
      assert s[:result_excerpt], "#{s[:slug]} should have a result excerpt"
    end
  end

  # 15. walk_status with no runs returns zero aggregates
  def test_walk_status_zero_aggregates_when_no_runs
    # Create an issue without running the driver (no runs/ directory)
    create_issue("no-run-task", title: "No run task", priority: 1)

    status = @backend.walk_status

    assert_equal 0, status[:total_runs]
    assert_equal 0.0, status[:total_duration]
    assert_equal 0, status[:success_count]
    assert_equal 0, status[:failure_count]

    summaries = status[:issue_summaries]
    assert_equal 1, summaries.length
    assert_equal "no-run-task", summaries.first[:slug]
    assert_equal "open", summaries.first[:status]
    assert_equal 0, summaries.first[:run_count]
    assert_nil summaries.first[:result_excerpt]
  end

  # --- Stream mode tests ---

  MOCK_STREAM_AGENT = File.expand_path("mock-agent-stream.rb", __dir__)

  def build_stream_driver(logs_dir:, **overrides)
    Walk::Driver.new(
      backend: @backend,
      prompt_builder: @prompt_builder,
      spawn_mode: :stream,
      command: ["ruby", MOCK_STREAM_AGENT],
      logs_dir: logs_dir,
      sleep_interval: 0,
      logger: Logger.new(File::NULL),
      **overrides
    )
  end

  # 16. Stream mode creates output.jsonl and digest.json files
  def test_stream_mode_creates_output_and_digest_files
    create_issue("stream-alpha", title: "Stream alpha", priority: 1)
    logs_dir = File.join(@tmpdir, "logs")

    driver = build_stream_driver(logs_dir: logs_dir)
    driver.run(once: true)

    # output.jsonl should exist
    output_files = Dir.glob(File.join(logs_dir, "*-stream-alpha-output.jsonl"))
    assert_equal 1, output_files.length, "Should have exactly one output.jsonl"

    output_content = File.read(output_files.first)
    refute_empty output_content, "output.jsonl should not be empty"

    # Each line should be valid JSON
    lines = output_content.lines.reject(&:empty?)
    assert_operator lines.length, :>=, 3, "Should have at least 3 stream-json events"
    lines.each do |line|
      data = JSON.parse(line)
      assert data["type"], "Each line should have a type field"
    end

    # digest.json should exist
    digest_files = Dir.glob(File.join(logs_dir, "*-stream-alpha-digest.json"))
    assert_equal 1, digest_files.length, "Should have exactly one digest.json"

    digest = JSON.parse(File.read(digest_files.first), symbolize_names: true)
    assert digest[:issue_id], "Digest should have issue_id"
    assert digest[:status], "Digest should have status"
    assert digest[:timestamp], "Digest should have timestamp"
  end

  # 17. Digest contains expected fields from stream-json output
  def test_stream_mode_digest_has_expected_fields
    create_issue("stream-beta", title: "Stream beta", priority: 1)
    logs_dir = File.join(@tmpdir, "logs")

    driver = build_stream_driver(logs_dir: logs_dir)
    driver.run(once: true)

    digest_files = Dir.glob(File.join(logs_dir, "*-stream-beta-digest.json"))
    assert_equal 1, digest_files.length

    digest = JSON.parse(File.read(digest_files.first), symbolize_names: true)

    # Core fields from the result event
    assert_equal "stream-beta", digest[:issue_id]
    assert_equal "success", digest[:status]
    assert_equal 45.0, digest[:duration_s]
    assert_equal 5, digest[:num_turns]
    assert_includes digest[:result_text], "Mock agent completed successfully"
    assert_equal 0.42, digest[:cost_usd]

    # Tools summary from assistant messages (keys are symbols after symbolize_names)
    tools = digest[:tools_summary]
    assert_kind_of Hash, tools
    assert_equal 3, tools[:Bash], "Should count 3 Bash tool uses"
    assert_equal 1, tools[:Read], "Should count 1 Read tool use"
    assert_equal 1, tools[:Edit], "Should count 1 Edit tool use"
    assert_equal 1, tools[:Write], "Should count 1 Write tool use"

    # Files modified
    assert_includes digest[:files_modified], "/tmp/mock-edit.rb"
    assert_includes digest[:files_modified], "/tmp/mock-write.rb"

    # bd mutations (from Bash commands matching bd close/create/comments add)
    assert_operator digest[:bd_mutations].length, :>=, 2,
                    "Should detect bd mutations (comments add, close)"

    # Token usage
    tokens = digest[:token_usage]
    assert_equal 5000, tokens[:input]
    assert_equal 1200, tokens[:output]
    assert_equal 800, tokens[:cache_create]
    assert_equal 3000, tokens[:cache_read]
  end

  # 18. Agent comment with run stats is posted to the issue
  def test_stream_mode_posts_run_stats_comment
    create_issue("stream-gamma", title: "Stream gamma", priority: 1)
    logs_dir = File.join(@tmpdir, "logs")

    driver = build_stream_driver(logs_dir: logs_dir)
    driver.run(once: true)

    # The issue is still in open/ (stream mode doesn't close via backend)
    comments_file = File.join(@open_dir, "stream-gamma", "comments.md")
    assert File.exist?(comments_file), "comments.md should exist"

    comments = File.read(comments_file)

    # First comment: "Agent started" from work_issue_stream
    assert_includes comments, "Agent started"

    # Second comment: run stats from digest
    assert_includes comments, "[driver] Run stats:"
    assert_includes comments, "turns"
    assert_includes comments, "tools"
    assert_includes comments, "Status: success"
  end

  # 19. Prompt log file is created in stream mode
  def test_stream_mode_creates_prompt_log
    create_issue("stream-delta", title: "Stream delta", priority: 1)
    logs_dir = File.join(@tmpdir, "logs")

    driver = build_stream_driver(logs_dir: logs_dir)
    driver.run(once: true)

    prompt_files = Dir.glob(File.join(logs_dir, "*-stream-delta.txt"))
    assert_equal 1, prompt_files.length, "Should have exactly one prompt.txt"

    prompt = File.read(prompt_files.first)
    refute_empty prompt, "Prompt file should not be empty"
    assert_includes prompt, "stream-delta", "Prompt should reference the issue slug"
  end

  # 20. cleanup_old_logs removes excess log files
  def test_stream_mode_cleanup_old_logs
    logs_dir = File.join(@tmpdir, "logs")
    FileUtils.mkdir_p(logs_dir)

    # Create 45 old .txt files (threshold is 40, cleanup removes oldest)
    45.times do |i|
      File.write(File.join(logs_dir, "20260101-#{format('%06d', i)}-old.txt"), "old log #{i}")
    end

    create_issue("stream-cleanup", title: "Stream cleanup", priority: 1)

    driver = build_stream_driver(logs_dir: logs_dir)
    driver.run(once: true)

    # After cleanup, should have at most 40 .txt files plus any new ones
    txt_files = Dir.glob(File.join(logs_dir, "*.txt"))
    assert_operator txt_files.length, :<=, 42,
                    "Should have cleaned up old logs (40 kept + new prompt + margin)"
  end

  # --- Stream mode per-issue run artifact tests ---

  # 20b. Stream mode creates per-issue runs/ directory with meta.json and prompt.txt
  def test_stream_mode_creates_per_issue_run_artifacts
    create_issue("stream-run-test", title: "Stream run test", priority: 1)
    logs_dir = File.join(@tmpdir, "logs")

    driver = build_stream_driver(logs_dir: logs_dir)
    driver.run(once: true)

    # Per-issue runs/ directory should exist
    issue_dir = File.join(@open_dir, "stream-run-test")
    runs_dir = File.join(issue_dir, "runs")
    assert Dir.exist?(runs_dir), "runs/ directory should exist for stream-mode issue"

    run_dirs = Dir.children(runs_dir).sort
    assert_equal 1, run_dirs.length, "Should have exactly one run"

    run_dir = File.join(runs_dir, run_dirs.first)

    # meta.json should exist with expected fields
    meta_file = File.join(run_dir, "meta.json")
    assert File.exist?(meta_file), "meta.json should exist in stream-mode run"
    meta = JSON.parse(File.read(meta_file))
    assert_equal 0, meta["exit_code"], "exit_code should be 0"
    assert meta["started_at"], "meta should have started_at"
    assert meta["finished_at"], "meta should have finished_at"
    assert_equal 0.42, meta["cost_usd"], "meta should have cost_usd"
    assert meta["token_usage"], "meta should have token_usage"

    # prompt.txt should exist
    prompt_file = File.join(run_dir, "prompt.txt")
    assert File.exist?(prompt_file), "prompt.txt should exist in stream-mode run"
    prompt = File.read(prompt_file)
    refute_empty prompt, "prompt.txt should not be empty"
    assert_includes prompt, "stream-run-test", "prompt should reference the issue slug"

    # output.jsonl symlink should exist and point to the logs_dir file
    output_link = File.join(run_dir, "output.jsonl")
    assert File.exist?(output_link), "output.jsonl should exist in stream-mode run"
    assert File.symlink?(output_link), "output.jsonl should be a symlink"
  end

  # 20c. Stream mode retry policy works with per-issue run metadata
  MOCK_STREAM_FAILING_AGENT = File.expand_path("mock-agent-stream-failing.rb", __dir__)

  def build_stream_failing_driver(logs_dir:, **overrides)
    Walk::Driver.new(
      backend: @backend,
      prompt_builder: @prompt_builder,
      spawn_mode: :stream,
      command: ["ruby", MOCK_STREAM_FAILING_AGENT],
      logs_dir: logs_dir,
      sleep_interval: 0,
      logger: Logger.new(File::NULL),
      **overrides
    )
  end

  def test_stream_mode_retry_policy_counts_failures
    dir = create_issue("stream-retry", title: "Stream retry", priority: 1)
    logs_dir = File.join(@tmpdir, "logs")

    # Run the failing stream agent once
    driver = build_stream_failing_driver(logs_dir: logs_dir)
    driver.run(once: true)

    # Per-issue runs/ should exist with a failure recorded
    runs_dir = File.join(dir, "runs")
    assert Dir.exist?(runs_dir), "runs/ directory should exist after stream-mode failure"

    run_dirs = Dir.children(runs_dir).sort
    assert_equal 1, run_dirs.length, "Should have exactly one run"

    meta = JSON.parse(File.read(File.join(runs_dir, run_dirs.first, "meta.json")))
    assert_equal 1, meta["exit_code"], "exit_code should be 1 (failure)"

    # RetryPolicy should count this as 1 consecutive failure
    policy = Walk::RetryPolicy.new
    failures = policy.consecutive_failures(
      { dir: dir, slug: "stream-retry", id: "stream-retry" })
    assert_equal 1, failures,
                 "RetryPolicy should count 1 consecutive failure from stream-mode run"
  end

  # 20d. Stream mode blocks issue after MAX_CONSECUTIVE_FAILURES
  #       Pre-seed 3 failures — driver should block immediately without
  #       spawning the agent (same as capture-mode blocking).
  def test_stream_mode_blocks_after_max_failures
    dir = create_issue("stream-block", title: "Stream block", priority: 1)
    logs_dir = File.join(@tmpdir, "logs")

    # Simulate 3 prior failures (at threshold)
    simulate_failed_runs(dir, 3)

    driver = build_stream_failing_driver(logs_dir: logs_dir)
    driver.run(once: true)

    # Issue should be blocked (driver saw 3 consecutive failures)
    assert File.exist?(File.join(dir, "blocked_by_driver")),
           "stream-block should be blocked after 3 consecutive failures"

    # Comment should explain the block
    comments_file = File.join(dir, "comments.md")
    assert File.exist?(comments_file), "comments.md should exist"
    comments = File.read(comments_file)
    assert_includes comments, "consecutive failures"
  end

  # --- Retry policy tests ---

  MOCK_FAILING_AGENT = File.expand_path("mock-agent-failing.rb", __dir__)
  MOCK_RETRY_AGENT = File.expand_path("mock-agent-retry.rb", __dir__)

  def build_failing_driver(**overrides)
    Walk::Driver.new(
      backend: @backend,
      prompt_builder: @prompt_builder,
      spawn_mode: :capture,
      command: ["ruby", MOCK_FAILING_AGENT],
      sleep_interval: 0,
      logger: Logger.new(File::NULL),
      **overrides
    )
  end

  def build_retry_driver(**overrides)
    Walk::Driver.new(
      backend: @backend,
      prompt_builder: @prompt_builder,
      spawn_mode: :capture,
      command: ["ruby", MOCK_RETRY_AGENT],
      sleep_interval: 0,
      logger: Logger.new(File::NULL),
      **overrides
    )
  end

  # Helper: simulate N prior failed runs by writing meta.json files
  def simulate_failed_runs(issue_dir, count)
    count.times do |i|
      ts = "20260101-#{format('%06d', i)}"
      run_dir = File.join(issue_dir, "runs", ts)
      FileUtils.mkdir_p(run_dir)
      File.write(File.join(run_dir, "meta.json"), JSON.generate(
        "exit_code" => 1,
        "started_at" => "2026-01-01T00:00:#{format('%02d', i)}Z",
        "finished_at" => "2026-01-01T00:01:#{format('%02d', i)}Z",
        "pid" => 10_000 + i
      ))
    end
  end

  # 21. Second failure: driver warns about failure pattern before retrying
  def test_second_failure_warns_before_retry
    dir = create_issue("retry-alpha", title: "Retry alpha", priority: 1)

    # Simulate 2 prior failures — driver will see consecutive_failures=2 and warn
    simulate_failed_runs(dir, 2)

    # Run the failing agent once — should warn but NOT block (2 < 3)
    driver = build_failing_driver
    driver.run(once: true)

    # Issue should still be in open/ (not blocked yet)
    assert Dir.exist?(File.join(@open_dir, "retry-alpha")),
           "retry-alpha should still be in open/ after 2 prior failures"
    refute File.exist?(File.join(@open_dir, "retry-alpha", "blocked_by_driver")),
           "retry-alpha should NOT be blocked after 2 prior failures"

    # Should have a warning comment about 2 consecutive failures
    comments_file = File.join(@open_dir, "retry-alpha", "comments.md")
    assert File.exist?(comments_file), "comments.md should exist"
    comments = File.read(comments_file)
    assert_includes comments, "2 consecutive failures",
                    "Should warn about failure pattern"
  end

  # 22. Three consecutive failures block the issue
  def test_three_failures_blocks_issue
    dir = create_issue("retry-beta", title: "Retry beta", priority: 1)

    # Simulate 3 prior failures (already at threshold)
    simulate_failed_runs(dir, 3)

    # Run the driver — should detect 3 failures and block immediately
    driver = build_failing_driver
    driver.run(once: true)

    # Issue should still be in open/ but blocked
    assert Dir.exist?(File.join(@open_dir, "retry-beta")),
           "retry-beta should still be in open/"
    assert File.exist?(File.join(@open_dir, "retry-beta", "blocked_by_driver")),
           "retry-beta should have blocked_by_driver marker"

    # Blocked marker should contain useful info
    marker = File.read(File.join(@open_dir, "retry-beta", "blocked_by_driver"))
    assert_includes marker, "consecutive failures"

    # Comment should explain the block
    comments_file = File.join(@open_dir, "retry-beta", "comments.md")
    comments = File.read(comments_file)
    assert_includes comments, "[driver] Blocked after 3 consecutive failures"
    assert_includes comments, "To unblock"
  end

  # 23. Blocked issue is skipped by ready_issues
  def test_blocked_by_driver_excluded_from_ready_issues
    dir = create_issue("retry-gamma", title: "Retry gamma", priority: 1)
    create_issue("normal-task", title: "Normal task", priority: 2)

    # Block retry-gamma
    File.write(File.join(dir, "blocked_by_driver"), "blocked\n")

    issues = @backend.ready_issues
    slugs = issues.map { |i| i[:slug] }

    refute_includes slugs, "retry-gamma",
                    "retry-gamma should be excluded from ready_issues"
    assert_includes slugs, "normal-task",
                    "normal-task should still be in ready_issues"
  end

  # 24. Driver retries a failing issue and eventually succeeds
  def test_retry_then_succeed
    create_issue("retry-delta", title: "Retry delta", priority: 1,
                 body: "This issue will fail twice then succeed.")

    # Use the retry mock that fails MOCK_FAIL_COUNT times then succeeds
    # Default MOCK_FAIL_COUNT is 2, so: fail, fail, succeed
    driver = build_retry_driver
    driver.run(once: false)

    # Issue should eventually be closed (after 2 failures + 1 success)
    assert Dir.exist?(File.join(@closed_dir, "retry-delta")),
           "retry-delta should be closed after retries succeeded"

    # Should have 3 runs total
    runs_dir = File.join(@closed_dir, "retry-delta", "runs")
    assert Dir.exist?(runs_dir), "runs/ directory should exist"
    run_dirs = Dir.children(runs_dir).sort
    assert_equal 3, run_dirs.length,
                 "Should have 3 runs (2 failures + 1 success)"

    # First two should have exit_code=1, third exit_code=0
    run_dirs.each_with_index do |ts, i|
      meta = JSON.parse(File.read(File.join(runs_dir, ts, "meta.json")))
      if i < 2
        assert_equal 1, meta["exit_code"],
                     "Run #{i + 1} should have exit_code=1"
      else
        assert_equal 0, meta["exit_code"],
                     "Run #{i + 1} should have exit_code=0"
      end
    end
  end

  # 25. Walk status includes retry/failure breakdown
  def test_walk_status_retry_breakdown
    dir = create_issue("status-retry", title: "Status retry", priority: 1)

    # Simulate 2 consecutive failures
    simulate_failed_runs(dir, 2)

    status = @backend.walk_status

    assert_operator status[:total_retries], :>=, 2,
                    "total_retries should count consecutive failures"
    assert status.key?(:driver_blocked_count),
           "status should include driver_blocked_count"
    assert_equal 0, status[:driver_blocked_count],
                 "No issues should be driver-blocked yet"

    # Now block the issue
    File.write(File.join(dir, "blocked_by_driver"), "blocked\n")

    status = @backend.walk_status
    assert_equal 1, status[:driver_blocked_count],
                 "One issue should be driver-blocked"
    assert_equal 0, status[:ready_count],
                 "No issues should be ready (only issue is blocked)"
  end

  # 26. Issue summary includes consecutive_failures and driver_blocked fields
  def test_issue_summary_includes_retry_fields
    dir = create_issue("summary-retry", title: "Summary retry", priority: 1)
    simulate_failed_runs(dir, 2)
    File.write(File.join(dir, "blocked_by_driver"), "blocked\n")

    status = @backend.walk_status
    summary = status[:issue_summaries].find { |s| s[:slug] == "summary-retry" }

    assert summary, "Should find summary for summary-retry"
    assert_equal 2, summary[:consecutive_failures],
                 "Should report 2 consecutive failures"
    assert_equal 2, summary[:failure_runs],
                 "Should report 2 total failure runs"
    assert summary[:driver_blocked],
           "Should report driver_blocked=true"
  end

  # 27. Unblocking by removing marker file re-enables the issue
  def test_unblock_by_removing_marker
    dir = create_issue("unblock-test", title: "Unblock test", priority: 1)
    File.write(File.join(dir, "blocked_by_driver"), "blocked\n")

    issues = @backend.ready_issues
    assert_empty issues, "Blocked issue should not appear in ready_issues"

    # Remove the marker
    File.delete(File.join(dir, "blocked_by_driver"))

    issues = @backend.ready_issues
    assert_equal 1, issues.length,
                 "Unblocked issue should appear in ready_issues"
    assert_equal "unblock-test", issues.first[:slug]
  end

  # --- Interrupted run tests (validates h3h.53 fix) ---

  # Helper: simulate N interrupted runs (signal-killed, exit_code: nil)
  def simulate_interrupted_runs(issue_dir, count, offset: 0)
    count.times do |i|
      idx = offset + i
      ts = "20260102-#{format('%06d', idx)}"
      run_dir = File.join(issue_dir, "runs", ts)
      FileUtils.mkdir_p(run_dir)
      File.write(File.join(run_dir, "meta.json"), JSON.generate(
        "exit_code" => nil,
        "started_at" => "2026-01-02T00:00:#{format('%02d', idx)}Z",
        "finished_at" => "2026-01-02T00:01:#{format('%02d', idx)}Z",
        "pid" => 20_000 + idx
      ))
    end
  end

  # 27b. Interrupted runs (nil exit_code) do not count as consecutive failures
  def test_interrupted_runs_not_counted_as_failures
    dir = create_issue("int-alpha", title: "Interrupted alpha", priority: 1)

    # Simulate 5 interrupted runs — should all be skipped
    simulate_interrupted_runs(dir, 5)

    policy = Walk::RetryPolicy.new
    failures = policy.consecutive_failures(
      { dir: dir, slug: "int-alpha", id: "int-alpha" })
    assert_equal 0, failures,
                 "Interrupted runs (nil exit_code) should not count as failures"
  end

  # 27c. Interrupted runs between failures don't break the consecutive count
  def test_interrupted_runs_between_failures_are_transparent
    dir = create_issue("int-beta", title: "Interrupted beta", priority: 1)

    # Simulate: fail, interrupted, fail (chronological order)
    # The two real failures are consecutive (interrupted run is skipped)
    simulate_failed_runs(dir, 1)                       # 20260101-000000: exit_code=1
    simulate_interrupted_runs(dir, 1, offset: 0)       # 20260102-000000: exit_code=nil
    simulate_failed_runs_at(dir, "20260103-000000", 1) # 20260103-000000: exit_code=1

    policy = Walk::RetryPolicy.new
    failures = policy.consecutive_failures(
      { dir: dir, slug: "int-beta", id: "int-beta" })
    assert_equal 2, failures,
                 "Two real failures with an interrupted run between them should count as 2"
  end

  # 27d. Interrupted runs after a success don't affect count
  def test_interrupted_runs_after_success_no_failures
    dir = create_issue("int-gamma", title: "Interrupted gamma", priority: 1)

    # Simulate: success, then 3 interrupted runs
    ts = "20260101-000000"
    run_dir = File.join(dir, "runs", ts)
    FileUtils.mkdir_p(run_dir)
    File.write(File.join(run_dir, "meta.json"), JSON.generate(
      "exit_code" => 0,
      "started_at" => "2026-01-01T00:00:00Z",
      "finished_at" => "2026-01-01T00:01:00Z",
      "pid" => 30_000
    ))
    simulate_interrupted_runs(dir, 3, offset: 0) # 20260102-000000..2

    policy = Walk::RetryPolicy.new
    failures = policy.consecutive_failures(
      { dir: dir, slug: "int-gamma", id: "int-gamma" })
    assert_equal 0, failures,
                 "Interrupted runs after a success should not count as failures"
  end

  # 27e. Three interrupted runs do NOT block an issue
  def test_three_interrupted_runs_do_not_block
    dir = create_issue("int-delta", title: "Interrupted delta", priority: 1)

    # Simulate 3 interrupted runs (would have blocked under old behavior)
    simulate_interrupted_runs(dir, 3)

    driver = build_failing_driver
    driver.run(once: true)

    # Issue should still be in open/ and NOT blocked
    # (the failing agent adds 1 real failure, but interrupted ones don't count)
    assert Dir.exist?(File.join(@open_dir, "int-delta")),
           "int-delta should still be in open/"
    refute File.exist?(File.join(@open_dir, "int-delta", "blocked_by_driver")),
           "int-delta should NOT be blocked (interrupted runs don't count)"
  end

  # Helper: simulate a single failed run at a specific timestamp
  def simulate_failed_runs_at(issue_dir, timestamp, exit_code)
    run_dir = File.join(issue_dir, "runs", timestamp)
    FileUtils.mkdir_p(run_dir)
    File.write(File.join(run_dir, "meta.json"), JSON.generate(
      "exit_code" => exit_code,
      "started_at" => "2026-01-03T00:00:00Z",
      "finished_at" => "2026-01-03T00:01:00Z",
      "pid" => 40_000
    ))
  end

  # --- YAML escaping tests ---

  # 28. Title with double quotes doesn't crash
  def test_create_issue_with_double_quotes_in_title
    result = @backend.create_issue_by_slug("quote-test",
                                           title: 'Fix "broken" parser',
                                           body: "Description.")
    assert result, "create_issue_by_slug should succeed"
    assert_equal 'Fix "broken" parser', result[:title]

    # Round-trip: re-read and verify
    issue = @backend.show_issue("quote-test")
    assert_equal 'Fix "broken" parser', issue[:title]
  end

  # 29. Title with colons doesn't crash
  def test_create_issue_with_colons_in_title
    result = @backend.create_issue_by_slug("colon-test",
                                           title: "Fix: handle edge case",
                                           body: "Description.")
    assert result
    issue = @backend.show_issue("colon-test")
    assert_equal "Fix: handle edge case", issue[:title]
  end

  # 30. Title with hash character doesn't crash
  def test_create_issue_with_hash_in_title
    result = @backend.create_issue_by_slug("hash-test",
                                           title: "Issue #42: something broke",
                                           body: "Description.")
    assert result
    issue = @backend.show_issue("hash-test")
    assert_equal "Issue #42: something broke", issue[:title]
  end

  # 31. Title with single quotes doesn't crash
  def test_create_issue_with_single_quotes_in_title
    result = @backend.create_issue_by_slug("squote-test",
                                           title: "Fix it's broken parser",
                                           body: "Description.")
    assert result
    issue = @backend.show_issue("squote-test")
    assert_equal "Fix it's broken parser", issue[:title]
  end

  # 32. Close reason with special characters doesn't crash
  def test_close_reason_with_special_chars
    create_issue("close-special", title: "Close special", priority: 1)

    reason = 'Fixed "the bug": it\'s resolved #done'
    result = @backend.close_issue("close-special", reason: reason)
    assert result, "close_issue should succeed"
    assert_equal reason, result[:reason]

    # Verify close.md parses back correctly
    close_md = File.join(@closed_dir, "close-special", "close.md")
    assert File.exist?(close_md)
    content = File.read(close_md)
    if content =~ /\A---\n(.*?\n)---/m
      fm = YAML.safe_load(Regexp.last_match(1))
      assert_equal reason, fm["reason"]
    else
      flunk "close.md should have valid YAML frontmatter"
    end
  end

  # 33. scaffold_walk with special chars in title
  def test_scaffold_walk_with_special_title
    walk_path = File.join(@tmpdir, "special-walk")
    backend = Walk::DirectoryBackend.new(walk_path)
    result = backend.scaffold_walk(title: 'Walk: "investigate" issue #5')
    assert result

    meta = backend.read_walk_meta
    assert_equal 'Walk: "investigate" issue #5', meta[:title]
  end

  # 34. create_issue_by_slug rejects slug that already exists in closed/
  def test_create_issue_by_slug_rejects_closed_duplicate
    # Create and close an issue so the slug exists in closed/
    create_issue("dup-closed", title: "Original issue", priority: 1)
    @backend.close_issue("dup-closed", reason: "Done.")

    assert Dir.exist?(File.join(@closed_dir, "dup-closed")),
           "dup-closed should be in closed/"
    refute Dir.exist?(File.join(@open_dir, "dup-closed")),
           "dup-closed should NOT be in open/"

    # Attempting to create a new issue with the same slug should fail
    result = @backend.create_issue_by_slug("dup-closed",
                                            title: "Duplicate issue",
                                            body: "Should not be created.")
    assert_nil result, "create_issue_by_slug should return nil for closed slug"

    # Verify no new directory was created in open/
    refute Dir.exist?(File.join(@open_dir, "dup-closed")),
           "Should not create a new issue in open/ with a closed slug"
  end

  # 35. create_issue via backend interface (slug derived from title)
  def test_create_issue_interface_with_special_title
    result = @backend.create_issue(title: 'Fix: "broken" feature #99',
                                   description: "Some work.")
    assert result
    assert_equal 'Fix: "broken" feature #99', result[:title]
  end

  # --- Concurrent dispatch tests ---

  MOCK_TIMED_AGENT = File.expand_path("mock-agent-timed.rb", __dir__)

  def build_concurrent_driver(max_concurrent:, timing_file: nil, delay: "0.3", **overrides)
    env_cmd = ["ruby", MOCK_TIMED_AGENT]
    Walk::Driver.new(
      backend: @backend,
      prompt_builder: @prompt_builder,
      spawn_mode: :capture,
      command: env_cmd,
      sleep_interval: 0,
      max_concurrent: max_concurrent,
      logger: Logger.new(File::NULL),
      **overrides
    )
  end

  # Helper: parse timing file into array of {slug:, event:, time:}
  def parse_timing(path)
    return [] unless path && File.exist?(path)

    File.readlines(path).map { |line|
      slug, event, time = line.strip.split(" ")
      { slug: slug, event: event, time: time.to_f }
    }
  end

  # 35. Concurrent: 3 independent issues with max_concurrent: 2
  #     verifies 2 agents run simultaneously (overlapping times)
  def test_concurrent_two_agents_run_simultaneously
    timing_file = File.join(@tmpdir, "timing.log")

    create_issue("conc-a", title: "Concurrent A", priority: 1)
    create_issue("conc-b", title: "Concurrent B", priority: 2)
    create_issue("conc-c", title: "Concurrent C", priority: 3)

    # Override the command to pass TIMING_FILE and MOCK_DELAY via env
    env_wrapper = File.join(@tmpdir, "env-wrapper.rb")
    File.write(env_wrapper, <<~RUBY)
      #!/usr/bin/env ruby
      # frozen_string_literal: true

      ENV["TIMING_FILE"] = "#{timing_file}"
      ENV["MOCK_DELAY"] = "0.3"
      load "#{MOCK_TIMED_AGENT}"
    RUBY

    driver = Walk::Driver.new(
      backend: @backend,
      prompt_builder: @prompt_builder,
      spawn_mode: :capture,
      command: ["ruby", env_wrapper],
      sleep_interval: 0,
      max_concurrent: 2,
      logger: Logger.new(File::NULL)
    )
    driver.run

    # All 3 issues should be closed
    assert Dir.exist?(File.join(@closed_dir, "conc-a")),
           "conc-a should be in closed/"
    assert Dir.exist?(File.join(@closed_dir, "conc-b")),
           "conc-b should be in closed/"
    assert Dir.exist?(File.join(@closed_dir, "conc-c")),
           "conc-c should be in closed/"

    # Verify timing shows overlap: at least two agents were active
    # simultaneously (one started before the other ended)
    entries = parse_timing(timing_file)
    starts = entries.select { |e| e[:event] == "start" }.sort_by { |e| e[:time] }
    ends = entries.select { |e| e[:event] == "end" }.sort_by { |e| e[:time] }

    assert_equal 3, starts.length, "Should have 3 start entries"
    assert_equal 3, ends.length, "Should have 3 end entries"

    # Check overlap: the second start should happen before the first end
    # (meaning two agents ran concurrently)
    assert_operator starts[1][:time], :<, ends[0][:time],
                    "Second agent should start before first agent ends " \
                    "(proving concurrent execution). " \
                    "Starts: #{starts.map { |s| "#{s[:slug]}@#{s[:time]}" }.join(', ')} " \
                    "Ends: #{ends.map { |e| "#{e[:slug]}@#{e[:time]}" }.join(', ')}"
  end

  # 36. Concurrent: max_concurrent: 1 preserves sequential behavior
  def test_concurrent_max_one_is_sequential
    timing_file = File.join(@tmpdir, "timing.log")

    create_issue("seq-a", title: "Sequential A", priority: 1)
    create_issue("seq-b", title: "Sequential B", priority: 2)

    env_wrapper = File.join(@tmpdir, "env-wrapper.rb")
    File.write(env_wrapper, <<~RUBY)
      #!/usr/bin/env ruby
      # frozen_string_literal: true

      ENV["TIMING_FILE"] = "#{timing_file}"
      ENV["MOCK_DELAY"] = "0.1"
      load "#{MOCK_TIMED_AGENT}"
    RUBY

    driver = Walk::Driver.new(
      backend: @backend,
      prompt_builder: @prompt_builder,
      spawn_mode: :capture,
      command: ["ruby", env_wrapper],
      sleep_interval: 0,
      max_concurrent: 1,
      logger: Logger.new(File::NULL)
    )
    driver.run

    # Both should be closed
    assert Dir.exist?(File.join(@closed_dir, "seq-a")),
           "seq-a should be in closed/"
    assert Dir.exist?(File.join(@closed_dir, "seq-b")),
           "seq-b should be in closed/"

    # Verify no overlap: second start should be after first end
    entries = parse_timing(timing_file)
    starts = entries.select { |e| e[:event] == "start" }.sort_by { |e| e[:time] }
    ends = entries.select { |e| e[:event] == "end" }.sort_by { |e| e[:time] }

    assert_equal 2, starts.length, "Should have 2 start entries"
    assert_equal 2, ends.length, "Should have 2 end entries"

    # Sequential: second start should be AFTER first end
    assert_operator starts[1][:time], :>=, ends[0][:time],
                    "With max_concurrent: 1, second agent should start " \
                    "after first agent ends (sequential behavior)"
  end

  # 37. Concurrent: all issues get runs/ directories and result.md
  def test_concurrent_all_issues_get_run_artifacts
    create_issue("art-a", title: "Artifact A", priority: 1)
    create_issue("art-b", title: "Artifact B", priority: 2)

    driver = Walk::Driver.new(
      backend: @backend,
      prompt_builder: @prompt_builder,
      spawn_mode: :capture,
      command: ["ruby", MOCK_AGENT],
      sleep_interval: 0,
      max_concurrent: 2,
      logger: Logger.new(File::NULL)
    )
    driver.run

    %w[art-a art-b].each do |slug|
      closed_dir = File.join(@closed_dir, slug)
      assert Dir.exist?(closed_dir), "#{slug} should be in closed/"
      assert File.exist?(File.join(closed_dir, "result.md")),
             "#{slug} should have result.md"

      runs_dir = File.join(closed_dir, "runs")
      assert Dir.exist?(runs_dir), "#{slug} should have runs/"

      run_dirs = Dir.children(runs_dir)
      assert_equal 1, run_dirs.length, "#{slug} should have exactly 1 run"

      run_dir = File.join(runs_dir, run_dirs.first)
      %w[prompt.txt output.txt stderr.txt meta.json].each do |file|
        assert File.exist?(File.join(run_dir, file)),
               "#{slug}/runs/*/#{file} should exist"
      end
    end
  end

  # 38. Concurrent: max_concurrent respects the limit (doesn't spawn > max)
  def test_concurrent_respects_limit
    timing_file = File.join(@tmpdir, "timing.log")

    # Create 4 issues but limit to 2 concurrent
    create_issue("limit-a", title: "Limit A", priority: 1)
    create_issue("limit-b", title: "Limit B", priority: 2)
    create_issue("limit-c", title: "Limit C", priority: 3)
    create_issue("limit-d", title: "Limit D", priority: 3)

    env_wrapper = File.join(@tmpdir, "env-wrapper.rb")
    File.write(env_wrapper, <<~RUBY)
      #!/usr/bin/env ruby
      # frozen_string_literal: true

      ENV["TIMING_FILE"] = "#{timing_file}"
      ENV["MOCK_DELAY"] = "0.3"
      load "#{MOCK_TIMED_AGENT}"
    RUBY

    driver = Walk::Driver.new(
      backend: @backend,
      prompt_builder: @prompt_builder,
      spawn_mode: :capture,
      command: ["ruby", env_wrapper],
      sleep_interval: 0,
      max_concurrent: 2,
      logger: Logger.new(File::NULL)
    )
    driver.run

    # All 4 should be closed
    %w[limit-a limit-b limit-c limit-d].each do |slug|
      assert Dir.exist?(File.join(@closed_dir, slug)),
             "#{slug} should be in closed/"
    end

    # Check that at no point were more than 2 agents running simultaneously
    entries = parse_timing(timing_file)
    events = entries.sort_by { |e| e[:time] }
    active = 0
    max_active = 0
    events.each do |e|
      if e[:event] == "start"
        active += 1
        max_active = active if active > max_active
      elsif e[:event] == "end"
        active -= 1
      end
    end

    assert_operator max_active, :<=, 2,
                    "At most 2 agents should run simultaneously " \
                    "(max_concurrent: 2), but saw #{max_active}"
  end

  # 39. Concurrent: planning only triggers when all agents done
  def test_concurrent_planning_after_all_done
    # No issues — concurrent mode should fall through to planning
    driver = Walk::Driver.new(
      backend: @backend,
      prompt_builder: @prompt_builder,
      spawn_mode: :capture,
      command: ["ruby", MOCK_AGENT],
      sleep_interval: 0,
      max_concurrent: 2,
      logger: Logger.new(File::NULL)
    )
    driver.run

    # Should exit after MAX_PLANNING_ROUNDS with no issues created
    assert_equal 0, Dir.glob(File.join(@open_dir, "*")).length,
                 "No issues should have been created"
  end

  # 40. Walk config: max_concurrent is read from _walk.md
  def test_walk_config_max_concurrent
    write_walk_meta(title: "Concurrent walk")
    # Overwrite with config section
    File.write(File.join(@tmpdir, "_walk.md"), <<~MD)
      ---
      title: "Concurrent walk"
      status: open
      config:
        max_concurrent: 3
      ---

      Walk with concurrent config.
    MD

    meta = @backend.read_walk_meta
    config = meta[:config]

    assert_equal 3, config[:max_concurrent]
  end

  # --- Concurrent retry/failure tests (validates h3h.48 fix) ---

  # 41. Concurrent: agent failure is tracked via runs/meta.json with exit_code=1
  def test_concurrent_agent_failure_tracked_in_runs
    create_issue("conc-fail-a", title: "Concurrent Fail A", priority: 1)
    create_issue("conc-ok-b", title: "Concurrent OK B", priority: 2)

    # Use a mock that fails for conc-fail-a but succeeds for conc-ok-b
    conditional_mock = File.join(@tmpdir, "conditional-mock.rb")
    File.write(conditional_mock, <<~'RUBY')
      #!/usr/bin/env ruby
      # frozen_string_literal: true

      prompt = $stdin.read
      walk_dir   = ENV["WALK_DIR"]
      walk_issue = ENV["WALK_ISSUE"]

      if walk_issue == "conc-fail-a"
        puts "Simulated failure for #{walk_issue}"
        exit 1
      end

      # Success path
      issue_dir = File.join(walk_dir, "open", walk_issue)
      if Dir.exist?(issue_dir)
        File.write(File.join(issue_dir, "result.md"),
                   "Mock agent completed #{walk_issue}.\nDone.\n")
      end
      exit 0
    RUBY

    driver = Walk::Driver.new(
      backend: @backend,
      prompt_builder: @prompt_builder,
      spawn_mode: :capture,
      command: ["ruby", conditional_mock],
      sleep_interval: 0,
      max_concurrent: 2,
      logger: Logger.new(File::NULL)
    )
    driver.run

    # conc-ok-b should be closed
    assert Dir.exist?(File.join(@closed_dir, "conc-ok-b")),
           "conc-ok-b should be in closed/"

    # conc-fail-a should still be in open/ (it fails every time, eventually blocks)
    assert Dir.exist?(File.join(@open_dir, "conc-fail-a")),
           "conc-fail-a should still be in open/"

    # Verify failure is tracked in runs/
    runs_dir = File.join(@open_dir, "conc-fail-a", "runs")
    assert Dir.exist?(runs_dir), "runs/ directory should exist for failing issue"

    run_dirs = Dir.children(runs_dir).sort
    assert_operator run_dirs.length, :>=, 1,
                    "Should have at least 1 run recorded"

    # At least one run should have exit_code != 0
    has_failure = run_dirs.any? do |ts|
      meta_file = File.join(runs_dir, ts, "meta.json")
      next false unless File.exist?(meta_file)

      meta = JSON.parse(File.read(meta_file))
      meta["exit_code"] != 0
    end
    assert has_failure, "At least one run should have non-zero exit_code"
  end

  # 42. Concurrent: issue blocked after MAX_CONSECUTIVE_FAILURES
  def test_concurrent_agent_blocked_after_max_failures
    dir = create_issue("conc-block", title: "Concurrent Block", priority: 1)

    # Pre-seed 2 prior failures so next failure triggers block (3 total)
    simulate_failed_runs(dir, 2)

    # Use the always-failing mock
    driver = Walk::Driver.new(
      backend: @backend,
      prompt_builder: @prompt_builder,
      spawn_mode: :capture,
      command: ["ruby", MOCK_FAILING_AGENT],
      sleep_interval: 0,
      max_concurrent: 2,
      logger: Logger.new(File::NULL)
    )
    driver.run

    # Issue should be in open/ and blocked
    assert Dir.exist?(File.join(@open_dir, "conc-block")),
           "conc-block should still be in open/"
    assert File.exist?(File.join(@open_dir, "conc-block", "blocked_by_driver")),
           "conc-block should have blocked_by_driver marker"

    # Should have 3+ runs total (2 simulated + at least 1 from driver)
    runs_dir = File.join(@open_dir, "conc-block", "runs")
    run_dirs = Dir.children(runs_dir).sort
    assert_operator run_dirs.length, :>=, 3,
                    "Should have at least 3 runs (2 simulated + 1 real)"

    # Comment should explain the block
    comments_file = File.join(@open_dir, "conc-block", "comments.md")
    assert File.exist?(comments_file), "comments.md should exist"
    comments = File.read(comments_file)
    assert_includes comments, "consecutive failures"
  end

  # 43. Concurrent: reap_finished_threads removes completed threads from active set
  def test_concurrent_reap_cleans_up_finished_threads
    # Create 3 issues with a short delay — after all finish, active_threads
    # should be empty and driver moves to planning/exit
    create_issue("reap-a", title: "Reap A", priority: 1)
    create_issue("reap-b", title: "Reap B", priority: 2)
    create_issue("reap-c", title: "Reap C", priority: 3)

    driver = Walk::Driver.new(
      backend: @backend,
      prompt_builder: @prompt_builder,
      spawn_mode: :capture,
      command: ["ruby", MOCK_AGENT],
      sleep_interval: 0,
      max_concurrent: 3,
      logger: Logger.new(File::NULL)
    )
    driver.run

    # All 3 issues should be closed (reap cleaned up threads, allowing
    # driver to detect no remaining issues and exit via planning stall)
    %w[reap-a reap-b reap-c].each do |slug|
      assert Dir.exist?(File.join(@closed_dir, slug)),
             "#{slug} should be in closed/"
    end

    # Each should have exactly 1 run (no re-spawning of finished issues)
    %w[reap-a reap-b reap-c].each do |slug|
      runs_dir = File.join(@closed_dir, slug, "runs")
      assert Dir.exist?(runs_dir), "#{slug} should have runs/"
      run_dirs = Dir.children(runs_dir)
      assert_equal 1, run_dirs.length,
                   "#{slug} should have exactly 1 run (not re-spawned after reap)"
    end
  end

  # 44. Concurrent: stall detection fires after MAX_PLANNING_ROUNDS
  #     when all concurrent agents have finished and no new issues exist
  def test_concurrent_stall_detection
    write_walk_meta(title: "Concurrent Stall Walk", status: "open")
    # No issues — concurrent mode should fall through to planning and stall

    driver = Walk::Driver.new(
      backend: @backend,
      prompt_builder: @prompt_builder,
      spawn_mode: :capture,
      command: ["ruby", MOCK_AGENT],
      sleep_interval: 0,
      max_concurrent: 2,
      logger: Logger.new(File::NULL)
    )

    # Stub spawn_planning_agent to track calls and return :empty
    planning_count = 0
    driver.define_singleton_method(:spawn_planning_agent) { |dry_run: false|
      planning_count += 1
      :empty
    }

    output = StringIO.new
    $stdout = output
    driver.run
    $stdout = STDOUT

    # Should have hit MAX_PLANNING_ROUNDS
    assert_equal Walk::Driver::MAX_PLANNING_ROUNDS, planning_count,
                 "Should attempt exactly MAX_PLANNING_ROUNDS planning rounds"

    # Walk status should be stalled
    meta = @backend.read_walk_meta
    assert_equal "stalled", meta[:status]
    assert_includes meta[:frontmatter]["finish_reason"], "planning rounds"
  end

  # 45. Concurrent: blocked issue is excluded from candidate list
  #     (not re-spawned after being blocked)
  def test_concurrent_blocked_issue_not_respawned
    dir = create_issue("conc-blocked", title: "Blocked Issue", priority: 1)
    create_issue("conc-normal", title: "Normal Issue", priority: 2)

    # Pre-block the first issue
    File.write(File.join(dir, "blocked_by_driver"), "blocked\n")

    driver = Walk::Driver.new(
      backend: @backend,
      prompt_builder: @prompt_builder,
      spawn_mode: :capture,
      command: ["ruby", MOCK_AGENT],
      sleep_interval: 0,
      max_concurrent: 2,
      logger: Logger.new(File::NULL)
    )
    driver.run

    # conc-normal should be closed (was worked on)
    assert Dir.exist?(File.join(@closed_dir, "conc-normal")),
           "conc-normal should be in closed/"

    # conc-blocked should still be in open/ and NOT have any runs
    assert Dir.exist?(File.join(@open_dir, "conc-blocked")),
           "conc-blocked should still be in open/"
    runs_dir = File.join(@open_dir, "conc-blocked", "runs")
    refute Dir.exist?(runs_dir),
           "conc-blocked should not have runs/ (was never spawned)"
  end

  # 46. Concurrent: mixed success/failure with overlapping execution
  #     verifies that concurrent mode properly handles a mix of successful
  #     and failing agents running simultaneously
  def test_concurrent_mixed_success_failure_overlap
    timing_file = File.join(@tmpdir, "timing-mixed.log")

    create_issue("mix-ok", title: "Mix OK", priority: 1)
    create_issue("mix-fail", title: "Mix Fail", priority: 2)

    # Pre-seed 2 failures for mix-fail so next failure blocks it
    simulate_failed_runs(File.join(@open_dir, "mix-fail"), 2)

    # Mock that succeeds for mix-ok, fails for mix-fail, with timing
    mixed_mock = File.join(@tmpdir, "mixed-mock.rb")
    File.write(mixed_mock, <<~RUBY)
      #!/usr/bin/env ruby
      # frozen_string_literal: true

      prompt = $stdin.read
      walk_dir   = ENV["WALK_DIR"]
      walk_issue = ENV["WALK_ISSUE"]
      timing_file = "#{timing_file}"

      start_time = Time.now.to_f
      File.open(timing_file, "a") { |f| f.flock(File::LOCK_EX); f.puts "\#{walk_issue} start \#{start_time}" }

      sleep 0.2

      end_time = Time.now.to_f
      File.open(timing_file, "a") { |f| f.flock(File::LOCK_EX); f.puts "\#{walk_issue} end \#{end_time}" }

      if walk_issue == "mix-fail"
        exit 1
      end

      issue_dir = File.join(walk_dir, "open", walk_issue)
      if Dir.exist?(issue_dir)
        File.write(File.join(issue_dir, "result.md"),
                   "Mock agent completed \#{walk_issue}.\\nDone.\\n")
      end
      exit 0
    RUBY

    driver = Walk::Driver.new(
      backend: @backend,
      prompt_builder: @prompt_builder,
      spawn_mode: :capture,
      command: ["ruby", mixed_mock],
      sleep_interval: 0,
      max_concurrent: 2,
      logger: Logger.new(File::NULL)
    )
    driver.run

    # mix-ok should be closed
    assert Dir.exist?(File.join(@closed_dir, "mix-ok")),
           "mix-ok should be in closed/"

    # mix-fail should be blocked (2 pre-seeded + 1 real = 3 failures)
    assert Dir.exist?(File.join(@open_dir, "mix-fail")),
           "mix-fail should still be in open/"
    assert File.exist?(File.join(@open_dir, "mix-fail", "blocked_by_driver")),
           "mix-fail should be blocked after 3 total failures"

    # Verify overlap: both agents ran concurrently
    entries = parse_timing(timing_file)
    starts = entries.select { |e| e[:event] == "start" }.sort_by { |e| e[:time] }
    ends = entries.select { |e| e[:event] == "end" }.sort_by { |e| e[:time] }

    if starts.length >= 2 && ends.length >= 1
      assert_operator starts[1][:time], :<, ends[0][:time],
                      "Both agents should have run concurrently"
    end
  end

  # --- Planning result file protocol tests ---

  # 47. Planning agent writes outcome: completed → walk finalizes as completed
  def test_planning_result_completed_finalizes_walk
    # No issues — driver enters planning immediately
    # Planning mock writes _planning_result.md with outcome: completed
    planning_completed_mock = File.join(@tmpdir, "planning-completed-mock.rb")
    File.write(planning_completed_mock, <<~RUBY)
      #!/usr/bin/env ruby
      # frozen_string_literal: true

      prompt = $stdin.read
      walk_dir = ENV["WALK_DIR"]
      planning = ENV["WALK_PLANNING"] == "1"

      if planning && walk_dir
        File.write(File.join(walk_dir, "_planning_result.md"), <<~MD)
          ---
          outcome: completed
          reason: "All walk objectives achieved: tests pass and code reviewed"
          ---

          Detailed rationale here.
        MD
      end
      exit 0
    RUBY

    driver = build_driver(command: ["ruby", planning_completed_mock])
    driver.run

    # Walk should be finalized as "completed" (not "stalled")
    meta = @backend.read_walk_meta
    assert_equal "completed", meta[:status],
                 "Walk should be finalized as 'completed' when planner signals completion"
    assert_includes meta[:frontmatter]["finish_reason"],
                    "All walk objectives achieved",
                    "Finish reason should come from planning result"

    # _planning_result.md should be cleaned up
    refute File.exist?(File.join(@tmpdir, "_planning_result.md")),
           "_planning_result.md should be deleted after reading"
  end

  # 48. Planning agent writes outcome: created_issues → loop continues
  def test_planning_result_created_issues_continues_loop
    # Planning mock writes _planning_result.md with outcome: created_issues
    # and also creates an actual issue. Driver should process it.
    planning_creates_mock = File.join(@tmpdir, "planning-creates-mock.rb")
    File.write(planning_creates_mock, <<~RUBY)
      #!/usr/bin/env ruby
      # frozen_string_literal: true

      prompt = $stdin.read
      walk_dir = ENV["WALK_DIR"]
      walk_issue = ENV["WALK_ISSUE"]
      planning = ENV["WALK_PLANNING"] == "1"

      if planning && walk_dir
        marker = File.join(walk_dir, ".planning_done")
        unless File.exist?(marker)
          # Create an issue
          slug = "result-protocol-task"
          dir = File.join(walk_dir, "open", slug)
          Dir.mkdir(dir) unless Dir.exist?(dir)
          File.write(File.join(dir, "issue.md"), <<~MD)
            ---
            title: "Result protocol task"
            type: task
            priority: 1
            ---

            Created by planning mock with result file.
          MD
          File.write(marker, "done")

          # Write the result file
          File.write(File.join(walk_dir, "_planning_result.md"), <<~MD)
            ---
            outcome: created_issues
            reason: "Created 1 follow-up issue"
            ---
          MD
        end
        exit 0
      end

      # Worker mode: close the issue
      if walk_dir && walk_issue
        issue_dir = File.join(walk_dir, "open", walk_issue)
        if Dir.exist?(issue_dir)
          File.write(File.join(issue_dir, "result.md"),
                     "Result protocol task completed.\\nDone.\\n")
        end
      end
      exit 0
    RUBY

    driver = build_driver(command: ["ruby", planning_creates_mock])
    driver.run

    # The created issue should have been processed and closed
    assert Dir.exist?(File.join(@closed_dir, "result-protocol-task")),
           "result-protocol-task should have been created and closed"

    # _planning_result.md should be cleaned up
    refute File.exist?(File.join(@tmpdir, "_planning_result.md")),
           "_planning_result.md should be deleted after reading"
  end

  # 49. Planning agent writes outcome: no_work_found → stall counter increments
  def test_planning_result_no_work_found_increments_stall
    # Planning mock always writes outcome: no_work_found
    planning_no_work_mock = File.join(@tmpdir, "planning-no-work-mock.rb")
    File.write(planning_no_work_mock, <<~RUBY)
      #!/usr/bin/env ruby
      # frozen_string_literal: true

      prompt = $stdin.read
      walk_dir = ENV["WALK_DIR"]
      planning = ENV["WALK_PLANNING"] == "1"

      if planning && walk_dir
        File.write(File.join(walk_dir, "_planning_result.md"), <<~MD)
          ---
          outcome: no_work_found
          reason: "All issues terminal, no new gaps"
          ---
        MD
      end
      exit 0
    RUBY

    driver = build_driver(command: ["ruby", planning_no_work_mock])
    driver.run

    # After MAX_PLANNING_ROUNDS of no_work_found, walk should stall
    meta = @backend.read_walk_meta
    assert_equal "stalled", meta[:status],
                 "Walk should stall after MAX_PLANNING_ROUNDS of no_work_found"
    assert_includes meta[:frontmatter]["finish_reason"], "planning rounds",
                    "Finish reason should mention planning rounds"
  end

  # 50. Planning agent writes no file → existing stall behavior preserved
  #     (This confirms backward compatibility — already tested by test 5,
  #      but this makes the intent explicit for the result file protocol.)
  def test_planning_result_no_file_preserves_existing_behavior
    # Use the standard mock agent which does NOT write _planning_result.md
    driver = build_driver
    driver.run

    # After MAX_PLANNING_ROUNDS, walk should stall (existing behavior)
    meta = @backend.read_walk_meta
    assert_equal "stalled", meta[:status],
                 "Walk should stall when no result file is written"
    refute File.exist?(File.join(@tmpdir, "_planning_result.md")),
           "No _planning_result.md should exist"
  end

  # --- End-to-end lifecycle tests ---

  MOCK_COMPLETER_AGENT = File.expand_path("mock-agent-completer.rb", __dir__)

  # 51. Full lifecycle: worker closes issue → planning triggered →
  #     planner writes outcome:completed → walk finalized with summary.md
  def test_full_lifecycle_worker_then_planning_completion
    create_issue("lifecycle-alpha", title: "Lifecycle alpha", priority: 1)

    driver = build_driver(command: ["ruby", MOCK_COMPLETER_AGENT])
    driver.run

    # Issue should be closed by the worker mock
    refute Dir.exist?(File.join(@open_dir, "lifecycle-alpha")),
           "lifecycle-alpha should not be in open/"
    assert Dir.exist?(File.join(@closed_dir, "lifecycle-alpha")),
           "lifecycle-alpha should be in closed/"
    assert File.exist?(File.join(@closed_dir, "lifecycle-alpha", "result.md")),
           "result.md should exist in closed dir"

    # Walk should be finalized as "completed" (not "stalled")
    meta = @backend.read_walk_meta
    assert_equal "completed", meta[:status],
                 "Walk should be finalized as 'completed' after worker+planning lifecycle"
    assert_includes meta[:frontmatter]["finish_reason"],
                    "All walk objectives",
                    "Finish reason should come from planning result"

    # _planning_result.md should be cleaned up
    refute File.exist?(File.join(@tmpdir, "_planning_result.md")),
           "_planning_result.md should be deleted after reading"

    # summary.md should be generated
    summary_path = File.join(@tmpdir, "summary.md")
    assert File.exist?(summary_path),
           "summary.md should be generated on walk completion"

    summary = File.read(summary_path)
    assert_includes summary, "Loop Test Walk",
                    "Summary should include walk title"
    assert_includes summary, "completed",
                    "Summary should mention completed status"
    assert_includes summary, "lifecycle-alpha",
                    "Summary should list the closed issue"
  end

  # 52. Full lifecycle with multiple issues: all closed by worker →
  #     planning completes the walk
  def test_full_lifecycle_multiple_issues_then_completion
    create_issue("multi-a", title: "Multi A", priority: 1)
    create_issue("multi-b", title: "Multi B", priority: 2)
    create_issue("multi-c", title: "Multi C", priority: 3)

    driver = build_driver(command: ["ruby", MOCK_COMPLETER_AGENT])
    driver.run

    # All issues should be closed
    %w[multi-a multi-b multi-c].each do |slug|
      assert Dir.exist?(File.join(@closed_dir, slug)),
             "#{slug} should be in closed/"
    end

    # Walk finalized as completed
    meta = @backend.read_walk_meta
    assert_equal "completed", meta[:status],
                 "Walk should be completed after all issues closed and planning signals done"

    # Summary should list all closed issues
    summary = File.read(File.join(@tmpdir, "summary.md"))
    %w[multi-a multi-b multi-c].each do |slug|
      assert_includes summary, slug,
                      "Summary should mention #{slug}"
    end

    # Statistics section should reflect 3 closed issues
    assert_includes summary, "Issues closed**: 3",
                    "Summary should report 3 closed issues"
  end

  # 53. Full lifecycle with concurrent dispatch: workers close issues
  #     in parallel → planning completes the walk
  def test_full_lifecycle_concurrent_then_completion
    create_issue("conc-life-a", title: "Concurrent Lifecycle A", priority: 1)
    create_issue("conc-life-b", title: "Concurrent Lifecycle B", priority: 2)

    driver = Walk::Driver.new(
      backend: @backend,
      prompt_builder: @prompt_builder,
      spawn_mode: :capture,
      command: ["ruby", MOCK_COMPLETER_AGENT],
      sleep_interval: 0,
      max_concurrent: 2,
      logger: Logger.new(File::NULL)
    )
    driver.run

    # Both issues should be closed
    %w[conc-life-a conc-life-b].each do |slug|
      assert Dir.exist?(File.join(@closed_dir, slug)),
             "#{slug} should be in closed/"
    end

    # Walk finalized as completed
    meta = @backend.read_walk_meta
    assert_equal "completed", meta[:status],
                 "Walk should be completed in concurrent mode"

    # Summary should exist
    assert File.exist?(File.join(@tmpdir, "summary.md")),
           "summary.md should be generated"
  end
end
