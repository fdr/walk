# frozen_string_literal: true

# test_walk_driver.rb - Tests for the directory-backend walk driver
#
# Tests backend operations (read, write, close), prompt assembly,
# and driver loop mechanics without spawning real Claude agents.
#
# Usage:
#   ruby test/test_walk_driver.rb          # Run all tests
#   ruby test/test_walk_driver.rb --name test_read_issue   # Run one test

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "yaml"
require "json"
require "time"
require "open3"
require "stringio"

require_relative "../lib/walk/directory_backend"
require_relative "../lib/walk/prompt_builder"
require_relative "../lib/walk/driver"

class WalkDriverTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("walk-test-")
    @open_dir = File.join(@tmpdir, "open")
    @closed_dir = File.join(@tmpdir, "closed")
    @walk_meta = File.join(@tmpdir, "_walk.md")
    FileUtils.mkdir_p(@open_dir)
    FileUtils.mkdir_p(@closed_dir)
    @backend = Walk::DirectoryBackend.new(@tmpdir)
    @prompt_builder = Walk::PromptBuilder.new(
      project_dir: @tmpdir,
      close_protocol: :result_md
    )
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- Helper: create an issue directory ---

  def create_issue(slug, title: slug, type: "task", priority: 2, body: "Test issue body.", dir: @open_dir)
    issue_dir = File.join(dir, slug)
    FileUtils.mkdir_p(issue_dir)
    File.write(File.join(issue_dir, "issue.md"), <<~MD)
      ---
      title: "#{title}"
      type: #{type}
      priority: #{priority}
      ---

      #{body}
    MD
    issue_dir
  end

  def write_walk_meta(title: "Test walk", status: "open", body: "Walk body.")
    File.write(@walk_meta, <<~MD)
      ---
      title: "#{title}"
      status: #{status}
      ---

      #{body}
    MD
  end

  # --- Backend: issue reading ---

  def test_read_issue_parses_frontmatter
    create_issue("my-issue", title: "My Issue", priority: 1)
    issue = @backend.read_issue(File.join(@open_dir, "my-issue"))

    assert_equal "my-issue", issue[:slug]
    assert_equal "My Issue", issue[:title]
    assert_equal 1, issue[:priority]
    assert_equal "task", issue[:type]
    assert_includes issue[:body], "Test issue body"
  end

  def test_read_issue_returns_nil_for_missing
    result = @backend.read_issue(File.join(@open_dir, "nonexistent"))
    assert_nil result
  end

  def test_ready_issues_sorted_by_priority
    create_issue("low-priority", priority: 3)
    create_issue("high-priority", priority: 1)
    create_issue("mid-priority", priority: 2)

    issues = @backend.ready_issues
    slugs = issues.map { _1[:slug] }
    assert_equal %w[high-priority mid-priority low-priority], slugs
  end

  def test_ready_issues_empty_dir
    issues = @backend.ready_issues
    assert_equal [], issues
  end

  # --- Backend: issue closing ---

  def test_close_issue_moves_to_closed
    create_issue("to-close")

    @backend.close_issue("to-close", reason: "done")

    refute Dir.exist?(File.join(@open_dir, "to-close")), "open dir should be gone"
    assert Dir.exist?(File.join(@closed_dir, "to-close")), "closed dir should exist"
    assert File.exist?(File.join(@closed_dir, "to-close", "close.md")), "close.md should exist"

    close_content = File.read(File.join(@closed_dir, "to-close", "close.md"))
    assert_includes close_content, "closed_at:"
    assert_includes close_content, "done"
  end

  # --- Backend: comments ---

  def test_add_comment_appends
    dir = create_issue("commented")

    @backend.add_comment("commented", "First comment")
    @backend.add_comment("commented", "Second comment")

    comments = File.read(File.join(dir, "comments.md"))
    assert_includes comments, "First comment"
    assert_includes comments, "Second comment"
    # Comments should have timestamps
    assert_match(/\d{4}-\d{2}-\d{2}T/, comments)
  end

  # --- Backend: walk metadata ---

  def test_read_walk_meta
    write_walk_meta(title: "My Walk", status: "open", body: "Walk description.")
    meta = @backend.read_walk_meta

    assert_equal "My Walk", meta[:title]
    assert_equal "open", meta[:status]
    assert_includes meta[:body], "Walk description"
  end

  def test_read_walk_meta_missing_file
    meta = Walk::DirectoryBackend.new(File.join(@tmpdir, "nonexistent")).read_walk_meta
    assert_nil meta
  end

  # --- Backend: closed issue reading ---

  def test_read_closed_issue_with_result
    issue_dir = create_issue("done-issue", dir: @closed_dir)
    File.write(File.join(issue_dir, "result.md"), "Found 42 bugs.\nDetails follow.")
    File.write(File.join(issue_dir, "close.md"), <<~MD)
      ---
      closed_at: 2026-01-30T10:00:00+00:00
      reason: "Found 42 bugs."
      ---
    MD

    closed = @backend.list_issues(status: "closed")
    issue = closed.find { _1[:slug] == "done-issue" }
    assert_equal "Found 42 bugs.\nDetails follow.", issue[:result]
    assert_equal "Found 42 bugs.", issue[:close_reason]
    assert_includes issue[:closed_at].to_s, "2026-01-30"
  end

  # --- Prompt assembly ---

  def test_build_prompt_includes_issue_fields
    create_issue("prompt-test", title: "Test Prompt Issue", type: "task")
    issue = @backend.fetch_issue("prompt-test")

    prompt = @prompt_builder.build_prompt(issue, backend: @backend)
    assert_includes prompt, "Issue: prompt-test"
    assert_includes prompt, "Type: general"
    assert_includes prompt, "result.md"
  end

  def test_build_prompt_includes_issue_dir
    dir = create_issue("dir-test", title: "Dir Test")
    issue = @backend.fetch_issue("dir-test")

    prompt = @prompt_builder.build_prompt(issue, backend: @backend)
    assert_includes prompt, dir
  end

  # --- Dependencies: blocked_by symlinks ---

  def test_blocked_issue_excluded_from_ready
    blocker_dir = create_issue("blocker-issue", priority: 1)
    blocked_dir = create_issue("blocked-issue", priority: 2)

    # Create blocked_by symlink: blocked-issue depends on blocker-issue
    FileUtils.mkdir_p(File.join(blocked_dir, "blocked_by"))
    File.symlink("../../blocker-issue", File.join(blocked_dir, "blocked_by", "blocker-issue"))

    issues = @backend.ready_issues
    slugs = issues.map { _1[:slug] }
    assert_includes slugs, "blocker-issue"
    refute_includes slugs, "blocked-issue"
  end

  def test_resolved_blocker_unblocks_issue
    blocker_dir = create_issue("resolved-blocker", priority: 1)
    blocked_dir = create_issue("waiting-issue", priority: 2)

    # Create blocked_by symlink
    FileUtils.mkdir_p(File.join(blocked_dir, "blocked_by"))
    File.symlink("../../resolved-blocker", File.join(blocked_dir, "blocked_by", "resolved-blocker"))

    # Before close: blocked
    issues = @backend.ready_issues
    refute_includes issues.map { _1[:slug] }, "waiting-issue"

    # Close the blocker
    @backend.close_issue("resolved-blocker", reason: "done")

    # After close: symlink target gone, so unblocked
    issues = @backend.ready_issues
    slugs = issues.map { _1[:slug] }
    assert_includes slugs, "waiting-issue"
    refute_includes slugs, "resolved-blocker" # moved to closed
  end

  def test_multiple_blockers_all_must_resolve
    create_issue("dep-a", priority: 1)
    create_issue("dep-b", priority: 1)
    blocked_dir = create_issue("needs-both", priority: 2)

    blocked_by = File.join(blocked_dir, "blocked_by")
    FileUtils.mkdir_p(blocked_by)
    File.symlink("../../dep-a", File.join(blocked_by, "dep-a"))
    File.symlink("../../dep-b", File.join(blocked_by, "dep-b"))

    # Both blockers open: blocked
    issues = @backend.ready_issues
    refute_includes issues.map { _1[:slug] }, "needs-both"

    # Close dep-b only: still blocked by dep-a
    @backend.close_issue("dep-b", reason: "done")
    issues = @backend.ready_issues
    refute_includes issues.map { _1[:slug] }, "needs-both"

    # Close dep-a: now unblocked
    @backend.close_issue("dep-a", reason: "done")
    issues = @backend.ready_issues
    assert_includes issues.map { _1[:slug] }, "needs-both"
  end

  def test_no_blocked_by_dir_means_not_blocked
    create_issue("no-deps", priority: 1)
    issues = @backend.ready_issues
    assert_equal 1, issues.length
    assert_equal "no-deps", issues.first[:slug]
  end

  def test_empty_blocked_by_dir_means_not_blocked
    dir = create_issue("empty-deps", priority: 1)
    FileUtils.mkdir_p(File.join(dir, "blocked_by"))

    issues = @backend.ready_issues
    assert_equal 1, issues.length
    assert_equal "empty-deps", issues.first[:slug]
  end

  def test_chain_dependency_a_blocks_b_blocks_c
    a_dir = create_issue("chain-a", priority: 1)
    b_dir = create_issue("chain-b", priority: 2)
    c_dir = create_issue("chain-c", priority: 3)

    # b blocked by a
    FileUtils.mkdir_p(File.join(b_dir, "blocked_by"))
    File.symlink("../../chain-a", File.join(b_dir, "blocked_by", "chain-a"))

    # c blocked by b
    FileUtils.mkdir_p(File.join(c_dir, "blocked_by"))
    File.symlink("../../chain-b", File.join(c_dir, "blocked_by", "chain-b"))

    # Only a is ready
    issues = @backend.ready_issues
    assert_equal ["chain-a"], issues.map { _1[:slug] }

    # Close a: b becomes ready, c still blocked by b
    @backend.close_issue("chain-a", reason: "done")
    issues = @backend.ready_issues
    assert_equal ["chain-b"], issues.map { _1[:slug] }

    # Close b: c becomes ready
    @backend.close_issue("chain-b", reason: "done")
    issues = @backend.ready_issues
    assert_equal ["chain-c"], issues.map { _1[:slug] }
  end

  # --- Smoke test: full mini-walk lifecycle ---

  def test_mini_walk_lifecycle
    write_walk_meta(title: "Mini Walk", status: "open")
    create_issue("task-1", title: "Task One", priority: 1, body: "Do thing one.")
    create_issue("task-2", title: "Task Two", priority: 2, body: "Do thing two.")

    # Simulate: agent works on task-1, writes result, driver closes it
    issues = @backend.ready_issues
    assert_equal 2, issues.length
    assert_equal "task-1", issues.first[:slug]

    # Agent writes result.md
    File.write(File.join(issues.first[:dir], "result.md"), "Task one completed.\nDid the thing.")

    # Driver detects result and closes
    result_file = File.join(issues.first[:dir], "result.md")
    assert File.exist?(result_file)
    reason = File.read(result_file).lines.first.strip
    @backend.close_issue("task-1", reason: reason)

    # Now only task-2 remains
    remaining = @backend.ready_issues
    assert_equal 1, remaining.length
    assert_equal "task-2", remaining.first[:slug]

    # Closed issues available for context
    closed = @backend.list_issues(status: "closed")
    assert_equal 1, closed.length
    assert_equal "task-1", closed.first[:slug]
    assert_equal "Task one completed.", closed.first[:close_reason]
  end

  # --- Walk config from _walk.md frontmatter ---

  def test_walk_config_full
    File.write(@walk_meta, <<~MD)
      ---
      title: "Configured walk"
      status: open
      config:
        max_turns: 15
        model: opus
        sleep_interval: 10
        spawn_mode: stream
        close_protocol: bd
        claude_md_path: /custom/CLAUDE.md
      ---

      Walk with full config.
    MD

    meta = @backend.read_walk_meta
    config = meta[:config]

    assert_equal 15, config[:max_turns]
    assert_equal "opus", config[:model]
    assert_equal 10, config[:sleep_interval]
    assert_equal :stream, config[:spawn_mode]
    assert_equal :bd, config[:close_protocol]
    assert_equal "/custom/CLAUDE.md", config[:claude_md_path]
  end

  def test_walk_config_empty
    File.write(@walk_meta, <<~MD)
      ---
      title: "No config walk"
      status: open
      ---

      Walk without config section.
    MD

    meta = @backend.read_walk_meta
    config = meta[:config]

    assert_kind_of Hash, config
    assert_empty config
  end

  def test_walk_config_partial
    File.write(@walk_meta, <<~MD)
      ---
      title: "Partial config walk"
      status: open
      config:
        max_turns: 20
      ---

      Walk with only max_turns configured.
    MD

    meta = @backend.read_walk_meta
    config = meta[:config]

    assert_equal 20, config[:max_turns]
    refute config.key?(:model)
    refute config.key?(:spawn_mode)
    refute config.key?(:sleep_interval)
  end

  def test_walk_config_unknown_keys_ignored
    File.write(@walk_meta, <<~MD)
      ---
      title: "Extra keys walk"
      status: open
      config:
        max_turns: 5
        unknown_key: should_be_dropped
        another: ignored
      ---

      Walk with unknown config keys.
    MD

    meta = @backend.read_walk_meta
    config = meta[:config]

    assert_equal 5, config[:max_turns]
    refute config.key?(:unknown_key)
    refute config.key?(:another)
  end

  def test_walk_config_missing_walk_md
    backend = Walk::DirectoryBackend.new(File.join(@tmpdir, "nonexistent"))
    meta = backend.read_walk_meta
    assert_nil meta
  end

  # --- walk_timeline ---

  def test_walk_timeline_empty_when_no_closed_issues
    timeline = @backend.walk_timeline
    assert_equal [], timeline
  end

  def test_walk_timeline_single_closed_issue
    issue_dir = create_issue("done-task", title: "Done Task", type: "task", dir: @closed_dir)
    File.write(File.join(issue_dir, "close.yaml"), YAML.dump(
      "status" => "closed",
      "reason" => "Completed the task successfully.",
      "closed_at" => "2026-01-30T10:00:00+00:00"
    ))
    File.write(File.join(issue_dir, "result.md"), "Completed the task successfully.\n")

    timeline = @backend.walk_timeline
    assert_equal 1, timeline.length

    entry = timeline.first
    assert_equal "done-task", entry[:slug]
    assert_equal "Done Task", entry[:title]
    assert_equal "task", entry[:type]
    assert_includes entry[:closed_at].to_s, "2026-01-30"
    assert_equal 0, entry[:run_count]
    assert_equal 0.0, entry[:duration_s]
    assert_equal "Completed the task successfully.", entry[:close_reason]
  end

  def test_walk_timeline_multiple_sorted_by_closed_at
    # Create two issues closed at different times
    dir_a = create_issue("task-a", title: "Task A", dir: @closed_dir)
    File.write(File.join(dir_a, "close.yaml"), YAML.dump(
      "status" => "closed",
      "reason" => "A done",
      "closed_at" => "2026-01-30T12:00:00+00:00"
    ))

    dir_b = create_issue("task-b", title: "Task B", dir: @closed_dir)
    File.write(File.join(dir_b, "close.yaml"), YAML.dump(
      "status" => "closed",
      "reason" => "B done",
      "closed_at" => "2026-01-30T08:00:00+00:00"
    ))

    timeline = @backend.walk_timeline
    assert_equal 2, timeline.length
    assert_equal "task-b", timeline[0][:slug], "Earlier closed_at should come first"
    assert_equal "task-a", timeline[1][:slug], "Later closed_at should come second"
  end

  def test_walk_timeline_with_run_data
    issue_dir = create_issue("ran-task", title: "Ran Task", dir: @closed_dir)
    File.write(File.join(issue_dir, "close.yaml"), YAML.dump(
      "status" => "closed",
      "reason" => "Done",
      "closed_at" => "2026-01-30T10:05:00+00:00"
    ))

    # Create two runs
    run1_dir = File.join(issue_dir, "runs", "20260130-100000")
    run2_dir = File.join(issue_dir, "runs", "20260130-100200")
    FileUtils.mkdir_p(run1_dir)
    FileUtils.mkdir_p(run2_dir)

    File.write(File.join(run1_dir, "meta.json"), JSON.generate(
      "started_at" => "2026-01-30T10:00:00+00:00",
      "finished_at" => "2026-01-30T10:01:30+00:00",
      "exit_code" => 0
    ))
    File.write(File.join(run2_dir, "meta.json"), JSON.generate(
      "started_at" => "2026-01-30T10:02:00+00:00",
      "finished_at" => "2026-01-30T10:04:00+00:00",
      "exit_code" => 0
    ))

    timeline = @backend.walk_timeline
    entry = timeline.first
    assert_equal 2, entry[:run_count]
    assert_in_delta 210.0, entry[:duration_s], 1.0  # 90s + 120s = 210s
  end

  def test_walk_timeline_missing_run_data_handled
    issue_dir = create_issue("no-runs", title: "No Runs", dir: @closed_dir)
    File.write(File.join(issue_dir, "close.yaml"), YAML.dump(
      "status" => "closed",
      "reason" => "Closed without runs",
      "closed_at" => "2026-01-30T10:00:00+00:00"
    ))

    timeline = @backend.walk_timeline
    entry = timeline.first
    assert_equal 0, entry[:run_count]
    assert_equal 0.0, entry[:duration_s]
  end

  def test_walk_timeline_truncates_close_reason
    issue_dir = create_issue("long-reason", title: "Long Reason", dir: @closed_dir)
    long_reason = "x" * 200
    File.write(File.join(issue_dir, "close.yaml"), YAML.dump(
      "status" => "closed",
      "reason" => long_reason,
      "closed_at" => "2026-01-30T10:00:00+00:00"
    ))

    timeline = @backend.walk_timeline
    entry = timeline.first
    assert_equal 120, entry[:close_reason].length
  end

  # --- walk_started_at ---

  def test_walk_started_at_nil_when_no_runs
    assert_nil @backend.walk_started_at
  end

  def test_walk_started_at_returns_earliest_run
    issue_dir = create_issue("with-runs")
    run1_dir = File.join(issue_dir, "runs", "20260130-100000")
    run2_dir = File.join(issue_dir, "runs", "20260130-080000")
    FileUtils.mkdir_p(run1_dir)
    FileUtils.mkdir_p(run2_dir)

    File.write(File.join(run1_dir, "meta.json"), JSON.generate(
      "started_at" => "2026-01-30T10:00:00+00:00",
      "finished_at" => "2026-01-30T10:01:00+00:00",
      "exit_code" => 0
    ))
    File.write(File.join(run2_dir, "meta.json"), JSON.generate(
      "started_at" => "2026-01-30T08:00:00+00:00",
      "finished_at" => "2026-01-30T08:01:00+00:00",
      "exit_code" => 0
    ))

    result = @backend.walk_started_at
    assert_equal Time.parse("2026-01-30T08:00:00+00:00"), result
  end

  # --- CLI: --walk-dir flag ---

  def test_cli_show_with_walk_dir_flag
    create_issue("flag-test", title: "Flag Test Issue")

    out, status = Open3.capture2("ruby", "bin/walk", "show", "flag-test", "--walk-dir", @tmpdir)
    assert_equal 0, status.exitstatus, "walk show should succeed with --walk-dir flag"
    assert_includes out, "flag-test"
    assert_includes out, "Flag Test Issue"
  end

  def test_cli_list_with_walk_dir_flag
    create_issue("list-flag-a", title: "List A")
    create_issue("list-flag-b", title: "List B")

    out, status = Open3.capture2("ruby", "bin/walk", "list", "--walk-dir", @tmpdir)
    assert_equal 0, status.exitstatus, "walk list should succeed with --walk-dir flag"
    assert_includes out, "list-flag-a"
    assert_includes out, "list-flag-b"
  end

  def test_cli_comment_with_walk_dir_and_slug_flags
    create_issue("comment-flag", title: "Comment Flag Test")

    out, _err, status = Open3.capture3("ruby", "bin/walk", "comment", "Hello from flag",
                                       "--walk-dir", @tmpdir, "--slug", "comment-flag")
    assert_equal 0, status.exitstatus, "walk comment should succeed with --walk-dir and --slug flags"

    comments = File.read(File.join(@open_dir, "comment-flag", "comments.md"))
    assert_includes comments, "Hello from flag"
  end

  def test_cli_create_with_walk_dir_flag
    out, status = Open3.capture2("ruby", "bin/walk", "create", "new-flag-issue",
                                 "--title", "New Issue via Flag",
                                 "--walk-dir", @tmpdir)
    assert_equal 0, status.exitstatus, "walk create should succeed with --walk-dir flag"
    assert_includes out, "new-flag-issue"
    assert Dir.exist?(File.join(@open_dir, "new-flag-issue"))
  end

  def test_cli_runs_with_walk_dir_flag
    create_issue("runs-flag", title: "Runs Flag Test")

    out, status = Open3.capture2("ruby", "bin/walk", "runs", "runs-flag", "--walk-dir", @tmpdir)
    assert_equal 0, status.exitstatus, "walk runs should succeed with --walk-dir flag"
    assert_includes out, "No runs"
  end

  def test_cli_close_with_walk_dir_and_slug_flags
    create_issue("close-flag", title: "Close Flag Test")

    out, _err, status = Open3.capture3("ruby", "bin/walk", "close", "--reason", "done via flag",
                                       "--walk-dir", @tmpdir, "--slug", "close-flag")
    assert_equal 0, status.exitstatus, "walk close should succeed with --walk-dir and --slug flags"
    assert Dir.exist?(File.join(@closed_dir, "close-flag"))
  end

  # --- Preview: closed issue annotation ---

  def test_preview_closed_issue_shows_annotation
    create_issue("closed-preview", title: "Closed Preview Test", dir: @closed_dir)
    File.write(File.join(@closed_dir, "closed-preview", "close.md"),
               "---\nclosed_at: 2026-01-30T10:00:00+00:00\nreason: done\n---\n")

    backend = Walk::DirectoryBackend.new(@tmpdir)
    prompt_builder = Walk::PromptBuilder.new(project_dir: @tmpdir, close_protocol: :result_md)
    driver = Walk::Driver.new(backend: backend, prompt_builder: prompt_builder)

    output = StringIO.new
    $stdout = output
    driver.preview("closed-preview")
    $stdout = STDOUT

    text = output.string
    assert_includes text, "[PREVIEW: this issue is closed"
    assert_includes text, "Closed Preview Test"
  end

  def test_preview_open_issue_no_annotation
    create_issue("open-preview", title: "Open Preview Test")

    backend = Walk::DirectoryBackend.new(@tmpdir)
    prompt_builder = Walk::PromptBuilder.new(project_dir: @tmpdir, close_protocol: :result_md)
    driver = Walk::Driver.new(backend: backend, prompt_builder: prompt_builder)

    output = StringIO.new
    $stdout = output
    driver.preview("open-preview")
    $stdout = STDOUT

    text = output.string
    refute_includes text, "[PREVIEW: this issue is closed"
    assert_includes text, "Open Preview Test"
  end

  # =====================================================================
  # Planning prompt tests: :result_md (directory backend) protocol
  # =====================================================================

  def test_planning_prompt_result_md_includes_walk_section
    write_walk_meta(title: "Test Walk", body: "Explore the thing.")

    prompt = @prompt_builder.build_planning_prompt(backend: @backend)
    assert_includes prompt, "Test Walk"
    assert_includes prompt, "Explore the thing."
  end

  def test_planning_prompt_result_md_includes_closed_issue_summaries
    write_walk_meta(title: "Summary Walk")

    dir = create_issue("done-task", title: "Done Task", type: "task", dir: @closed_dir)
    File.write(File.join(dir, "close.yaml"), YAML.dump(
      "status" => "closed",
      "reason" => "Completed with findings.",
      "closed_at" => "2026-01-30T10:00:00+00:00"
    ))
    File.write(File.join(dir, "result.md"), "Completed with findings.\nMore details.")

    prompt = @prompt_builder.build_planning_prompt(backend: @backend)
    assert_includes prompt, "done-task"
    assert_includes prompt, "Done Task"
    assert_includes prompt, "Completed with findings."
    assert_includes prompt, "More details."
  end

  def test_planning_prompt_result_md_no_closed_issues
    write_walk_meta(title: "Fresh Walk")

    prompt = @prompt_builder.build_planning_prompt(backend: @backend)
    assert_includes prompt, "No closed issues yet."
  end

  def test_planning_prompt_result_md_includes_create_instructions
    write_walk_meta(title: "Instruction Walk")

    prompt = @prompt_builder.build_planning_prompt(backend: @backend)
    assert_includes prompt, "mkdir"
    assert_includes prompt, "issue.md"
    assert_includes prompt, File.join(@tmpdir, "open")
  end

  def test_planning_prompt_result_md_includes_verify_and_exit
    write_walk_meta(title: "Verify Walk")

    prompt = @prompt_builder.build_planning_prompt(backend: @backend)
    assert_includes prompt, "After creating issues:"
    assert_includes prompt, "Verify they exist"
    assert_includes prompt, "EXIT"
  end

  def test_planning_prompt_result_md_includes_shared_structure
    write_walk_meta(title: "Structure Walk")

    prompt = @prompt_builder.build_planning_prompt(backend: @backend)

    # Step 1: meta-assessment
    assert_includes prompt, "Assess epic-level progress"
    assert_includes prompt, "Is that goal met, nearly met, or still far away?"

    # Step 2: deep exploration
    assert_includes prompt, "Deep exploration"

    # Step 3: triage
    assert_includes prompt, "terminal vs generative"

    # Step 4: create follow-ups
    assert_includes prompt, "Create follow-up issues"
    assert_includes prompt, "discovered-from"

    # Issue types
    assert_includes prompt, "**Investigate:**"
    assert_includes prompt, "**Experiment:**"
    assert_includes prompt, "**Compare:**"
    assert_includes prompt, "**Fix:**"

    # Quality rubric
    assert_includes prompt, "**Goal**:"
    assert_includes prompt, "**Success criteria**:"

    # Anti-patterns
    assert_includes prompt, "Anti-patterns to avoid"
    assert_includes prompt, "DO NOT create issues with vague goals"

    # Step 5: verify
    assert_includes prompt, "Verify and exit"
  end

  def test_planning_prompt_result_md_claude_md_embedded_in_directory_planning
    write_walk_meta(title: "Claude MD Walk")
    claude_md = File.join(@tmpdir, "CLAUDE.md")
    File.write(claude_md, "# Custom Instructions\n\nDo the right thing.")

    builder = Walk::PromptBuilder.new(
      project_dir: @tmpdir,
      claude_md_path: claude_md,
      close_protocol: :result_md
    )
    prompt = builder.build_planning_prompt(backend: @backend)
    assert_includes prompt, "planning agent"
    assert_includes prompt, "Claude MD Walk"
    assert_includes prompt, "# Custom Instructions"
    assert_includes prompt, "Do the right thing."
  end

  def test_planning_prompt_result_md_no_crash_when_claude_md_missing
    write_walk_meta(title: "No Claude MD Walk")
    nonexistent = File.join(@tmpdir, "NONEXISTENT.md")

    builder = Walk::PromptBuilder.new(
      project_dir: @tmpdir,
      claude_md_path: nonexistent,
      close_protocol: :result_md
    )
    prompt = builder.build_planning_prompt(backend: @backend)
    # Should not crash and should still include the planning structure
    assert_includes prompt, "planning agent"
  end

  def test_planning_prompt_result_md_includes_walk_dir_in_instructions
    write_walk_meta(title: "Dir Walk")

    prompt = @prompt_builder.build_planning_prompt(backend: @backend)
    assert_includes prompt, @tmpdir, "Planning prompt should reference the walk directory"
  end

  # =====================================================================
  # Planning prompt tests: :bd (beads) protocol
  # =====================================================================

  def test_planning_prompt_bd_includes_epic_output
    builder = Walk::PromptBuilder.new(
      project_dir: @tmpdir,
      close_protocol: :bd
    )
    epic_output = "EPIC: Investigate the widget system\nStatus: 5 issues closed"

    prompt = builder.build_planning_prompt(
      backend: @backend,
      epic_id: "epic-123",
      epic_output: epic_output
    )
    assert_includes prompt, "Investigate the widget system"
    assert_includes prompt, "5 issues closed"
  end

  def test_planning_prompt_bd_includes_bd_create_instructions
    builder = Walk::PromptBuilder.new(
      project_dir: @tmpdir,
      close_protocol: :bd
    )

    prompt = builder.build_planning_prompt(
      backend: @backend,
      epic_id: "epic-42",
      epic_output: "Epic description."
    )
    assert_includes prompt, "bd create"
    assert_includes prompt, "bd list"
    assert_includes prompt, "bd comments"
    assert_includes prompt, "epic-42"
  end

  def test_planning_prompt_bd_includes_exploration_steps
    builder = Walk::PromptBuilder.new(
      project_dir: @tmpdir,
      close_protocol: :bd
    )

    prompt = builder.build_planning_prompt(
      backend: @backend,
      epic_id: "epic-99",
      epic_output: "My epic."
    )
    assert_includes prompt, "List closed issues"
    assert_includes prompt, "Read conclusions"
    assert_includes prompt, "Do NOT re-read CLAUDE.md"
  end

  def test_planning_prompt_bd_includes_shared_structure
    builder = Walk::PromptBuilder.new(
      project_dir: @tmpdir,
      close_protocol: :bd
    )

    prompt = builder.build_planning_prompt(
      backend: @backend,
      epic_id: "epic-1",
      epic_output: "Test epic."
    )
    # Shared planning structure
    assert_includes prompt, "Assess epic-level progress"
    assert_includes prompt, "terminal vs generative"
    assert_includes prompt, "**Investigate:**"
    assert_includes prompt, "**Goal**:"
    assert_includes prompt, "Anti-patterns to avoid"
    assert_includes prompt, "Verify and exit"
  end

  def test_planning_prompt_bd_includes_claude_md_when_present
    claude_md = File.join(@tmpdir, "CLAUDE.md")
    File.write(claude_md, "# BD Custom Instructions\n\nFollow these rules.")

    builder = Walk::PromptBuilder.new(
      project_dir: @tmpdir,
      claude_md_path: claude_md,
      close_protocol: :bd
    )

    prompt = builder.build_planning_prompt(
      backend: @backend,
      epic_id: "epic-1",
      epic_output: "Test."
    )
    assert_includes prompt, "BD Custom Instructions"
    assert_includes prompt, "Follow these rules."
  end

  def test_planning_prompt_bd_omits_claude_md_when_missing
    builder = Walk::PromptBuilder.new(
      project_dir: @tmpdir,
      claude_md_path: "/tmp/does-not-exist-#{Process.pid}.md",
      close_protocol: :bd
    )

    prompt = builder.build_planning_prompt(
      backend: @backend,
      epic_id: "epic-1",
      epic_output: "Test."
    )
    # Should not crash
    assert_includes prompt, "planning agent"
  end

  def test_planning_prompt_bd_goal_met_action
    builder = Walk::PromptBuilder.new(
      project_dir: @tmpdir,
      close_protocol: :bd
    )

    prompt = builder.build_planning_prompt(
      backend: @backend,
      epic_id: "epic-1",
      epic_output: "Test."
    )
    assert_includes prompt, "goal is met"
    assert_includes prompt, "recommending closure"
  end

  # =====================================================================
  # Driver#spawn_planning_agent tests
  # =====================================================================

  def test_spawn_planning_dry_run_prints_prompt
    write_walk_meta(title: "Dry Run Walk")

    driver = Walk::Driver.new(
      backend: @backend,
      prompt_builder: @prompt_builder,
      spawn_mode: :capture,
      sleep_interval: 0
    )

    output = StringIO.new
    $stdout = output
    result = driver.send(:spawn_planning_agent, dry_run: true)
    $stdout = STDOUT

    assert_equal :dry_run, result
    text = output.string
    assert_includes text, "Planning prompt"
  end

  def test_spawn_planning_directory_backend_skips_fetch_epic
    # DirectoryBackend does NOT respond_to?(:fetch_epic_output), so
    # spawn_planning_agent should use the directory path (no epic_id needed)
    write_walk_meta(title: "Dir Planning Walk")

    refute @backend.respond_to?(:fetch_epic_output),
           "DirectoryBackend should not respond to fetch_epic_output"

    driver = Walk::Driver.new(
      backend: @backend,
      prompt_builder: @prompt_builder,
      spawn_mode: :capture,
      sleep_interval: 0
    )

    output = StringIO.new
    $stdout = output
    result = driver.send(:spawn_planning_agent, dry_run: true)
    $stdout = STDOUT

    assert_equal :dry_run, result
    text = output.string
    assert_includes text, "Dir Planning Walk"
  end

  def test_spawn_planning_bd_backend_returns_skip_without_parent
    # Create a mock backend that responds to fetch_epic_output
    mock_bd = Object.new
    def mock_bd.ready_issues(parent: nil); []; end
    def mock_bd.fetch_epic_output(_id); "Epic output"; end

    builder = Walk::PromptBuilder.new(project_dir: @tmpdir, close_protocol: :bd)
    driver = Walk::Driver.new(
      backend: mock_bd,
      prompt_builder: builder,
      parent: nil,  # No parent!
      spawn_mode: :capture,
      sleep_interval: 0,
      logger: Logger.new(File::NULL)
    )

    result = driver.send(:spawn_planning_agent, dry_run: false)
    assert_equal :skip, result
  end

  def test_spawn_planning_bd_backend_calls_fetch_epic_output
    # Create a mock backend that responds to fetch_epic_output
    mock_bd = Object.new
    epic_called_with = nil
    mock_bd.define_singleton_method(:ready_issues) { |parent: nil| [] }
    mock_bd.define_singleton_method(:fetch_epic_output) { |id|
      epic_called_with = id
      "Epic: My Test Epic\nDescription here."
    }

    builder = Walk::PromptBuilder.new(project_dir: @tmpdir, close_protocol: :bd)
    driver = Walk::Driver.new(
      backend: mock_bd,
      prompt_builder: builder,
      parent: "my-epic",
      spawn_mode: :capture,
      sleep_interval: 0,
      logger: Logger.new(File::NULL)
    )

    output = StringIO.new
    $stdout = output
    result = driver.send(:spawn_planning_agent, dry_run: true)
    $stdout = STDOUT

    assert_equal "my-epic", epic_called_with,
                 "fetch_epic_output should have been called with the parent epic id"
    assert_equal :dry_run, result
    text = output.string
    assert_includes text, "My Test Epic"
  end

  # =====================================================================
  # Walk completion lifecycle tests
  # =====================================================================

  # --- update_walk_status ---

  def test_update_walk_status_sets_stalled
    write_walk_meta(title: "Stall Walk", status: "open")

    result = @backend.update_walk_status("stalled", reason: "3 planning rounds with no progress")

    assert_equal "stalled", result[:status]
    assert result[:finished_at], "finished_at should be set"
    assert_equal "3 planning rounds with no progress", result[:finish_reason]

    # Verify persisted to _walk.md
    meta = @backend.read_walk_meta
    assert_equal "stalled", meta[:status]
    assert meta[:frontmatter]["finished_at"], "finished_at should be in frontmatter"
    assert_equal "3 planning rounds with no progress", meta[:frontmatter]["finish_reason"]
  end

  def test_update_walk_status_sets_completed
    write_walk_meta(title: "Done Walk", status: "open")

    result = @backend.update_walk_status("completed", reason: "all issues resolved")

    assert_equal "completed", result[:status]
    assert_equal "all issues resolved", result[:finish_reason]

    meta = @backend.read_walk_meta
    assert_equal "completed", meta[:status]
    assert_equal "all issues resolved", meta[:frontmatter]["finish_reason"]
  end

  def test_update_walk_status_sets_stopped
    write_walk_meta(title: "Stop Walk", status: "open")

    result = @backend.update_walk_status("stopped", reason: "parent closed")

    assert_equal "stopped", result[:status]
    assert_equal "parent closed", result[:finish_reason]
  end

  def test_update_walk_status_preserves_body
    write_walk_meta(title: "Body Walk", status: "open", body: "Important goals here.")

    @backend.update_walk_status("stalled", reason: "no progress")

    meta = @backend.read_walk_meta
    assert_includes meta[:body], "Important goals here."
  end

  def test_update_walk_status_reset_to_open_clears_finish_fields
    write_walk_meta(title: "Reset Walk", status: "open")

    # First finalize it
    @backend.update_walk_status("stalled", reason: "stuck")
    meta = @backend.read_walk_meta
    assert_equal "stalled", meta[:status]
    assert meta[:frontmatter]["finished_at"]

    # Now reset to open
    @backend.update_walk_status("open")
    meta = @backend.read_walk_meta
    assert_equal "open", meta[:status]
    refute meta[:frontmatter].key?("finished_at"), "finished_at should be removed on reset"
    refute meta[:frontmatter].key?("finish_reason"), "finish_reason should be removed on reset"
  end

  def test_update_walk_status_returns_nil_when_no_walk_md
    backend = Walk::DirectoryBackend.new(File.join(@tmpdir, "nonexistent"))
    result = backend.update_walk_status("stalled")
    assert_nil result
  end

  # --- Driver finalize_walk ---

  def test_driver_finalize_walk_updates_status_and_writes_summary
    write_walk_meta(title: "Finalize Walk", status: "open")
    create_issue("fin-task", title: "Finalize Task", dir: @closed_dir)
    File.write(File.join(@closed_dir, "fin-task", "close.yaml"), YAML.dump(
      "status" => "closed",
      "reason" => "Done.",
      "closed_at" => "2026-01-30T10:00:00+00:00"
    ))

    driver = Walk::Driver.new(
      backend: @backend,
      prompt_builder: @prompt_builder,
      spawn_mode: :capture,
      sleep_interval: 0,
      logger: Logger.new(File::NULL)
    )

    output = StringIO.new
    $stdout = output
    driver.send(:finalize_walk, "stalled", reason: "no progress")
    $stdout = STDOUT

    # Check status was updated
    meta = @backend.read_walk_meta
    assert_equal "stalled", meta[:status]

    # Check summary.md was written
    summary_path = File.join(@tmpdir, "summary.md")
    assert File.exist?(summary_path), "summary.md should be written"
    summary = File.read(summary_path)
    assert_includes summary, "Finalize Walk"
    assert_includes summary, "Statistics"
    assert_includes summary, "stalled"
  end

  def test_driver_finalize_walk_summary_includes_timeline
    write_walk_meta(title: "Timeline Walk", status: "open")

    dir = create_issue("tl-task", title: "Timeline Task", dir: @closed_dir)
    File.write(File.join(dir, "close.yaml"), YAML.dump(
      "status" => "closed",
      "reason" => "Traced the flow.",
      "closed_at" => "2026-01-30T10:00:00+00:00"
    ))
    File.write(File.join(dir, "result.md"), "Traced the flow.\n")

    driver = Walk::Driver.new(
      backend: @backend,
      prompt_builder: @prompt_builder,
      spawn_mode: :capture,
      sleep_interval: 0,
      logger: Logger.new(File::NULL)
    )

    output = StringIO.new
    $stdout = output
    driver.send(:finalize_walk, "completed", reason: "all done")
    $stdout = STDOUT

    summary = File.read(File.join(@tmpdir, "summary.md"))
    assert_includes summary, "Issue Timeline"
    assert_includes summary, "tl-task"
    assert_includes summary, "Traced the flow."
  end

  def test_driver_finalize_walk_summary_includes_open_issues
    write_walk_meta(title: "Open Issues Walk", status: "open")
    create_issue("still-open", title: "Still Open Task")

    driver = Walk::Driver.new(
      backend: @backend,
      prompt_builder: @prompt_builder,
      spawn_mode: :capture,
      sleep_interval: 0,
      logger: Logger.new(File::NULL)
    )

    output = StringIO.new
    $stdout = output
    driver.send(:finalize_walk, "stalled", reason: "stuck")
    $stdout = STDOUT

    summary = File.read(File.join(@tmpdir, "summary.md"))
    assert_includes summary, "Open Issues"
    assert_includes summary, "still-open"
  end

  # --- Driver stall detection via run_sequential ---

  def test_driver_sets_stalled_on_max_planning_rounds
    write_walk_meta(title: "Stall Test Walk", status: "open")
    # No issues — driver will attempt planning rounds

    planning_count = 0
    # Create a mock driver that short-circuits planning to avoid spawning real agents
    driver = Walk::Driver.new(
      backend: @backend,
      prompt_builder: @prompt_builder,
      spawn_mode: :capture,
      sleep_interval: 0,
      logger: Logger.new(File::NULL)
    )

    # Stub spawn_planning_agent to always return :empty (no new issues created)
    driver.define_singleton_method(:spawn_planning_agent) { |dry_run: false|
      planning_count += 1
      :empty
    }

    output = StringIO.new
    $stdout = output
    driver.send(:run_sequential)
    $stdout = STDOUT

    # Should have attempted MAX_PLANNING_ROUNDS planning rounds (exits before the next spawn)
    assert_equal Walk::Driver::MAX_PLANNING_ROUNDS, planning_count

    # Walk status should be 'stalled'
    meta = @backend.read_walk_meta
    assert_equal "stalled", meta[:status]
    assert_includes meta[:frontmatter]["finish_reason"], "planning rounds"

    # Summary should exist
    assert File.exist?(File.join(@tmpdir, "summary.md")), "summary.md should be written"
  end

  def test_driver_sets_stopped_on_parent_closed
    write_walk_meta(title: "Parent Closed Walk", status: "closed")
    # No issues, parent walk is already closed

    driver = Walk::Driver.new(
      backend: @backend,
      prompt_builder: @prompt_builder,
      parent: "parent-walk",  # parent must be set for parent_closed? to check
      spawn_mode: :capture,
      sleep_interval: 0,
      logger: Logger.new(File::NULL)
    )

    output = StringIO.new
    $stdout = output
    driver.send(:run_sequential)
    $stdout = STDOUT

    # Walk status should now be 'stopped' (the finalize overwrites 'closed' -> 'stopped')
    meta = @backend.read_walk_meta
    assert_equal "stopped", meta[:status]
    assert_equal "parent closed", meta[:frontmatter]["finish_reason"]
  end

  # --- Re-entrancy check in CLI ---

  def test_cli_reentrance_resets_stalled_walk
    write_walk_meta(title: "Stalled Walk", status: "open")
    @backend.update_walk_status("stalled", reason: "stuck earlier")

    # Verify it's stalled
    meta = @backend.read_walk_meta
    assert_equal "stalled", meta[:status]

    # Run walk run --dry-run to trigger re-entrancy check without spawning agents
    # We just need it to not error out — the re-entrancy check happens before driver starts
    _out, err, status = Open3.capture3("ruby", "bin/walk", "run", @tmpdir, "--dry-run")

    # Check stderr contains the re-entrancy warning
    assert_includes err, "Warning: walk 'Stalled Walk' has status 'stalled'"
    assert_includes err, "Resetting status to 'open'"

    # Verify status was reset
    meta = @backend.read_walk_meta
    assert_equal "open", meta[:status]
    refute meta[:frontmatter].key?("finished_at")
  end

  # =====================================================================
  # build_agent_cmd tests
  # =====================================================================

  def make_driver(**opts)
    Walk::Driver.new(
      backend: @backend,
      prompt_builder: @prompt_builder,
      **opts
    )
  end

  def test_build_agent_cmd_stream_default
    driver = make_driver
    # Prompt is now passed via stdin, not -p argument (avoids argv limits)
    cmd = driver.send(:build_agent_cmd, "do stuff", mode: :stream)
    assert_equal ["claude", "--verbose", "--output-format", "stream-json",
                  "--permission-mode", "bypassPermissions"], cmd
  end

  def test_build_agent_cmd_stream_with_model
    driver = make_driver(model: "opus")
    cmd = driver.send(:build_agent_cmd, "do stuff", mode: :stream)
    assert_includes cmd, "--model"
    assert_includes cmd, "opus"
    refute_includes cmd, "-p"  # Prompt via stdin
  end

  def test_build_agent_cmd_stream_with_custom_command
    driver = make_driver(command: "my-agent")
    cmd = driver.send(:build_agent_cmd, "do stuff", mode: :stream)
    assert_equal ["my-agent"], cmd  # Prompt via stdin
  end

  def test_build_agent_cmd_stream_with_custom_command_array
    driver = make_driver(command: ["my-agent", "--flag"])
    cmd = driver.send(:build_agent_cmd, "do stuff", mode: :stream)
    assert_equal ["my-agent", "--flag"], cmd  # Prompt via stdin
  end

  def test_build_agent_cmd_capture_default
    driver = make_driver
    cmd = driver.send(:build_agent_cmd, "do stuff", mode: :capture)
    assert_equal ["claude", "--print", "--dangerously-skip-permissions"], cmd
  end

  def test_build_agent_cmd_capture_with_max_turns
    driver = make_driver(max_turns: 25)
    cmd = driver.send(:build_agent_cmd, "do stuff", mode: :capture)
    assert_includes cmd, "--max-turns"
    idx = cmd.index("--max-turns")
    assert_equal "25", cmd[idx + 1]
  end

  def test_build_agent_cmd_capture_with_max_turns_override
    driver = make_driver(max_turns: 25)
    cmd = driver.send(:build_agent_cmd, "do stuff", mode: :capture, max_turns: 10)
    idx = cmd.index("--max-turns")
    assert_equal "10", cmd[idx + 1]
  end

  def test_build_agent_cmd_capture_with_model
    driver = make_driver(model: "sonnet")
    cmd = driver.send(:build_agent_cmd, "do stuff", mode: :capture)
    assert_includes cmd, "--model"
    assert_includes cmd, "sonnet"
  end

  def test_build_agent_cmd_capture_with_custom_command
    driver = make_driver(command: "my-agent")
    cmd = driver.send(:build_agent_cmd, "do stuff", mode: :capture)
    assert_equal ["my-agent"], cmd
  end

  def test_build_agent_cmd_capture_no_prompt_in_args
    driver = make_driver
    cmd = driver.send(:build_agent_cmd, "do stuff", mode: :capture)
    refute_includes cmd, "do stuff"
    refute_includes cmd, "-p"
  end

  def test_build_agent_cmd_invalid_mode_raises
    driver = make_driver
    assert_raises(ArgumentError) do
      driver.send(:build_agent_cmd, "x", mode: :bogus)
    end
  end

  # =====================================================================
  # AgentRunner isolation tests
  # =====================================================================

  def make_runner(spawn_mode: :capture, **overrides)
    log_proc = ->(_level, _msg) {}
    lock_proc = ->(&block) { block.call }
    build_cmd_proc = ->(prompt, mode:, max_turns: nil) {
      ["echo", "test"]
    }

    Walk::AgentRunner.new(
      backend: @backend,
      prompt_builder: @prompt_builder,
      retry_policy: Walk::RetryPolicy.new,
      logs_dir: nil,
      spawn_mode: spawn_mode,
      build_cmd: build_cmd_proc,
      log: log_proc,
      backend_lock: lock_proc,
      **overrides
    )
  end

  # --- extract_digest tests on AgentRunner directly ---

  def test_agent_runner_extract_digest_returns_nil_for_missing_file
    runner = make_runner
    result = runner.extract_digest("/nonexistent/path.jsonl", "test-1", 0)
    assert_nil result
  end

  def test_agent_runner_extract_digest_parses_stream_json
    runner = make_runner

    output_file = File.join(@tmpdir, "test-output.jsonl")
    File.write(output_file, [
      { "type" => "system", "subtype" => "init" },
      { "type" => "assistant", "message" => { "content" => [
        { "type" => "tool_use", "name" => "Bash", "input" => { "command" => "ls" } },
        { "type" => "tool_use", "name" => "Edit", "input" => { "file_path" => "/tmp/foo.rb",
                                                                 "old_string" => "a", "new_string" => "b" } }
      ] } },
      { "type" => "result", "subtype" => "success", "duration_ms" => 30_000,
        "num_turns" => 3, "result" => "Done.", "total_cost_usd" => 0.10,
        "usage" => { "input_tokens" => 1000, "output_tokens" => 200,
                     "cache_creation_input_tokens" => 100,
                     "cache_read_input_tokens" => 500 } }
    ].map { |h| JSON.generate(h) }.join("\n"))

    digest = runner.extract_digest(output_file, "test-issue", 0)

    assert_equal "test-issue", digest[:issue_id]
    assert_equal "success", digest[:status]
    assert_equal 30.0, digest[:duration_s]
    assert_equal 3, digest[:num_turns]
    assert_equal "Done.", digest[:result_text]
    assert_equal 0.10, digest[:cost_usd]
    assert_equal 1, digest[:tools_summary]["Bash"]
    assert_equal 1, digest[:tools_summary]["Edit"]
    assert_includes digest[:files_modified], "/tmp/foo.rb"
    assert_equal 1000, digest[:token_usage][:input]
    assert_equal 200, digest[:token_usage][:output]
  end

  def test_agent_runner_extract_digest_failure_status
    runner = make_runner

    output_file = File.join(@tmpdir, "fail-output.jsonl")
    File.write(output_file, [
      { "type" => "result", "subtype" => "error", "duration_ms" => 5000,
        "num_turns" => 1, "result" => "Failed." }
    ].map { |h| JSON.generate(h) }.join("\n"))

    digest = runner.extract_digest(output_file, "fail-issue", 1)

    assert_equal "failure", digest[:status]
  end

  def test_agent_runner_extract_digest_no_result_event_uses_exit_code
    runner = make_runner

    output_file = File.join(@tmpdir, "no-result.jsonl")
    File.write(output_file, JSON.generate("type" => "system", "subtype" => "init"))

    digest_ok = runner.extract_digest(output_file, "no-result", 0)
    assert_equal "success", digest_ok[:status]

    digest_fail = runner.extract_digest(output_file, "no-result", 1)
    assert_equal "failure", digest_fail[:status]
  end

  def test_agent_runner_extract_digest_detects_bd_mutations
    runner = make_runner

    output_file = File.join(@tmpdir, "bd-output.jsonl")
    File.write(output_file, [
      { "type" => "assistant", "message" => { "content" => [
        { "type" => "tool_use", "name" => "Bash",
          "input" => { "command" => "bd comments add issue-1 \"found it\"" } },
        { "type" => "tool_use", "name" => "Bash",
          "input" => { "command" => "bd create \"New task\" --parent epic-1" } },
        { "type" => "tool_use", "name" => "Bash",
          "input" => { "command" => "bd close issue-1 --reason done" } }
      ] } },
      { "type" => "result", "subtype" => "success", "duration_ms" => 10_000,
        "num_turns" => 2, "result" => "OK" }
    ].map { |h| JSON.generate(h) }.join("\n"))

    digest = runner.extract_digest(output_file, "bd-test", 0)

    assert_equal 3, digest[:bd_mutations].length
    assert digest[:bd_mutations].any? { |m| m.include?("comments add") }
    assert digest[:bd_mutations].any? { |m| m.include?("create") }
    assert digest[:bd_mutations].any? { |m| m.include?("close") }
  end

  def test_agent_runner_extract_digest_handles_malformed_json
    runner = make_runner

    output_file = File.join(@tmpdir, "malformed.jsonl")
    File.write(output_file, "not valid json\n{\"type\":\"result\",\"subtype\":\"success\",\"duration_ms\":1000,\"num_turns\":1,\"result\":\"ok\"}\n")

    digest = runner.extract_digest(output_file, "malformed", 0)
    assert_equal "success", digest[:status]
    assert_equal 1, digest[:num_turns]
  end

  # --- AgentRunner work_issue isolation tests ---

  def test_agent_runner_work_issue_dry_run
    runner = make_runner

    issue = { id: "dry-1", slug: "dry-1", title: "Dry", dir: @tmpdir }

    output = StringIO.new
    $stdout = output
    runner.work_issue(issue, dry_run: true)
    $stdout = STDOUT

    assert_includes output.string, "DRY RUN"
  end

  def test_agent_runner_blocks_issue_at_threshold
    dir = create_issue("runner-block", title: "Runner Block", priority: 1)

    # Simulate 3 prior failures
    3.times do |i|
      run_dir = File.join(dir, "runs", "20260101-#{format('%06d', i)}")
      FileUtils.mkdir_p(run_dir)
      File.write(File.join(run_dir, "meta.json"), JSON.generate("exit_code" => 1,
        "started_at" => "2026-01-01T00:00:00Z", "finished_at" => "2026-01-01T00:01:00Z", "pid" => 10_000 + i))
    end

    runner = make_runner
    issue = @backend.fetch_issue("runner-block")
    runner.work_issue(issue)

    # Should be blocked
    assert File.exist?(File.join(dir, "blocked_by_driver")),
           "Issue should be blocked after 3 consecutive failures"
    comments = File.read(File.join(dir, "comments.md"))
    assert_includes comments, "Blocked after 3 consecutive failures"
  end

  def test_agent_runner_warns_at_two_failures
    dir = create_issue("runner-warn", title: "Runner Warn", priority: 1)

    # Simulate 2 prior failures
    2.times do |i|
      run_dir = File.join(dir, "runs", "20260101-#{format('%06d', i)}")
      FileUtils.mkdir_p(run_dir)
      File.write(File.join(run_dir, "meta.json"), JSON.generate("exit_code" => 1,
        "started_at" => "2026-01-01T00:00:00Z", "finished_at" => "2026-01-01T00:01:00Z", "pid" => 10_000 + i))
    end

    # Use a real command that exits quickly for the capture path
    build_cmd_proc = ->(_prompt, mode:, max_turns: nil) { ["echo", "test"] }
    runner = make_runner(build_cmd: build_cmd_proc)
    issue = @backend.fetch_issue("runner-warn")
    runner.work_issue(issue)

    # Should not be blocked yet
    refute File.exist?(File.join(dir, "blocked_by_driver")),
           "Issue should NOT be blocked after 2 failures"

    # Should have a warning comment
    comments = File.read(File.join(dir, "comments.md"))
    assert_includes comments, "2 consecutive failures"
  end
end
