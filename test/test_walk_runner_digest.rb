# frozen_string_literal: true

# test_walk_runner_digest.rb - Tests for post-close log digest extraction
#
# Tests extract_digest against synthetic and real stream-json logs.
#
# Usage:
#   ruby test/test_walk_runner_digest.rb

require "minitest/autorun"
require "json"
require "tmpdir"

require_relative "../lib/walk/directory_backend"
require_relative "../lib/walk/driver"

class WalkRunnerDigestTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("walk-digest-test")
    FileUtils.mkdir_p(File.join(@tmpdir, "open"))
    FileUtils.mkdir_p(File.join(@tmpdir, "closed"))
    backend = Walk::DirectoryBackend.new(@tmpdir)
    prompt_builder = Walk::PromptBuilder.new(project_dir: @tmpdir, claude_md_path: "/dev/null")
    @runner = Walk::Driver.new(backend: backend, prompt_builder: prompt_builder)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def write_log(lines)
    path = File.join(@tmpdir, "test-output.jsonl")
    File.write(path, lines.map { JSON.generate(_1) }.join("\n") + "\n")
    path
  end

  def test_extract_digest_returns_nil_for_missing_file
    result = @runner.extract_digest( "/nonexistent/path.jsonl", "test.1", 0)
    assert_nil result
  end

  def test_extract_digest_parses_result_event
    log = write_log([
      { "type" => "result", "subtype" => "success", "duration_ms" => 120_000,
        "num_turns" => 25, "result" => "Done successfully.",
        "total_cost_usd" => 0.85,
        "usage" => { "input_tokens" => 100, "output_tokens" => 200,
                     "cache_creation_input_tokens" => 50,
                     "cache_read_input_tokens" => 300 } }
    ])
    digest = @runner.extract_digest( log, "test.1", 0)

    assert_equal "test.1", digest[:issue_id]
    assert_equal "success", digest[:status]
    assert_equal 120.0, digest[:duration_s]
    assert_equal 25, digest[:num_turns]
    assert_equal "Done successfully.", digest[:result_text]
    assert_equal 0.85, digest[:cost_usd]
    assert_equal 100, digest[:token_usage][:input]
    assert_equal 200, digest[:token_usage][:output]
    assert_equal 50, digest[:token_usage][:cache_create]
    assert_equal 300, digest[:token_usage][:cache_read]
  end

  def test_extract_digest_counts_tool_uses
    log = write_log([
      { "type" => "assistant", "message" => { "content" => [
        { "type" => "tool_use", "name" => "Bash", "input" => { "command" => "ls" } },
        { "type" => "tool_use", "name" => "Read", "input" => { "file_path" => "/tmp/x" } }
      ] } },
      { "type" => "assistant", "message" => { "content" => [
        { "type" => "tool_use", "name" => "Bash", "input" => { "command" => "pwd" } },
        { "type" => "tool_use", "name" => "Edit", "input" => { "file_path" => "/tmp/y", "old_string" => "a", "new_string" => "b" } }
      ] } },
      { "type" => "result", "subtype" => "success", "duration_ms" => 5000,
        "num_turns" => 2, "result" => "ok",
        "usage" => { "input_tokens" => 10, "output_tokens" => 20,
                     "cache_creation_input_tokens" => 0, "cache_read_input_tokens" => 0 } }
    ])
    digest = @runner.extract_digest( log, "test.2", 0)

    assert_equal({ "Bash" => 2, "Read" => 1, "Edit" => 1 }, digest[:tools_summary])
  end

  def test_extract_digest_tracks_files_modified
    log = write_log([
      { "type" => "assistant", "message" => { "content" => [
        { "type" => "tool_use", "name" => "Write", "input" => { "file_path" => "/tmp/a.rb", "content" => "x" } },
        { "type" => "tool_use", "name" => "Edit", "input" => { "file_path" => "/tmp/b.rb", "old_string" => "x", "new_string" => "y" } },
        { "type" => "tool_use", "name" => "Write", "input" => { "file_path" => "/tmp/a.rb", "content" => "z" } }
      ] } },
      { "type" => "result", "subtype" => "success", "duration_ms" => 1000,
        "num_turns" => 1, "result" => "ok",
        "usage" => { "input_tokens" => 0, "output_tokens" => 0,
                     "cache_creation_input_tokens" => 0, "cache_read_input_tokens" => 0 } }
    ])
    digest = @runner.extract_digest( log, "test.3", 0)

    assert_equal ["/tmp/a.rb", "/tmp/b.rb"], digest[:files_modified]
  end

  def test_extract_digest_captures_bd_mutations
    log = write_log([
      { "type" => "assistant", "message" => { "content" => [
        { "type" => "tool_use", "name" => "Bash", "input" => { "command" => "bd show test.1" } },
        { "type" => "tool_use", "name" => "Bash", "input" => { "command" => "bd comments add test.1 \"found something\"" } },
        { "type" => "tool_use", "name" => "Bash", "input" => { "command" => "bd close test.1 --reason \"done\"" } },
        { "type" => "tool_use", "name" => "Bash", "input" => { "command" => "bd create \"Follow-up\" --parent test" } }
      ] } },
      { "type" => "result", "subtype" => "success", "duration_ms" => 1000,
        "num_turns" => 1, "result" => "ok",
        "usage" => { "input_tokens" => 0, "output_tokens" => 0,
                     "cache_creation_input_tokens" => 0, "cache_read_input_tokens" => 0 } }
    ])
    digest = @runner.extract_digest( log, "test.4", 0)

    # bd show is read-only, should NOT be in mutations
    assert_equal 3, digest[:bd_mutations].length
    assert digest[:bd_mutations].any? { _1.include?("comments add") }
    assert digest[:bd_mutations].any? { _1.include?("close") }
    assert digest[:bd_mutations].any? { _1.include?("create") }
  end

  def test_extract_digest_truncates_result_text_at_500
    long_text = "x" * 1000
    log = write_log([
      { "type" => "result", "subtype" => "success", "duration_ms" => 1000,
        "num_turns" => 1, "result" => long_text,
        "usage" => { "input_tokens" => 0, "output_tokens" => 0,
                     "cache_creation_input_tokens" => 0, "cache_read_input_tokens" => 0 } }
    ])
    digest = @runner.extract_digest( log, "test.5", 0)

    assert_equal 500, digest[:result_text].length
  end

  def test_extract_digest_failure_status_from_result_event
    log = write_log([
      { "type" => "result", "subtype" => "error", "duration_ms" => 500,
        "num_turns" => 1, "result" => "crashed",
        "usage" => { "input_tokens" => 0, "output_tokens" => 0,
                     "cache_creation_input_tokens" => 0, "cache_read_input_tokens" => 0 } }
    ])
    digest = @runner.extract_digest( log, "test.6", 1)

    assert_equal "failure", digest[:status]
  end

  def test_extract_digest_failure_from_exit_code_when_no_result
    log = write_log([
      { "type" => "system", "subtype" => "init", "cwd" => "/tmp" }
    ])
    digest = @runner.extract_digest( log, "test.7", 1)

    assert_equal "failure", digest[:status]
    assert_equal 0, digest[:num_turns]
  end

  def test_extract_digest_skips_malformed_json_lines
    path = File.join(@tmpdir, "malformed.jsonl")
    File.write(path, "not json\n{\"type\":\"result\",\"subtype\":\"success\",\"duration_ms\":1000,\"num_turns\":1,\"result\":\"ok\",\"usage\":{\"input_tokens\":0,\"output_tokens\":0,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}\n")
    digest = @runner.extract_digest( path, "test.8", 0)

    assert_equal "success", digest[:status]
  end

  def test_extract_digest_includes_timestamp
    log = write_log([
      { "type" => "result", "subtype" => "success", "duration_ms" => 1000,
        "num_turns" => 1, "result" => "ok",
        "usage" => { "input_tokens" => 0, "output_tokens" => 0,
                     "cache_creation_input_tokens" => 0, "cache_read_input_tokens" => 0 } }
    ])
    digest = @runner.extract_digest( log, "test.9", 0)

    assert digest[:timestamp], "digest must include timestamp"
    # Should be ISO8601 format
    assert_match(/\d{4}-\d{2}-\d{2}T/, digest[:timestamp])
  end

  def test_format_duration_seconds
    assert_equal "30.5s", Walk::Reporting.format_duration(30.5)
  end

  def test_format_duration_minutes
    assert_equal "2m26s", Walk::Reporting.format_duration(146.2)
  end

  # Test against a real log file if available
  def test_extract_digest_from_real_log
    logs_dir = File.expand_path("../logs/prompts", __dir__)
    real_log = Dir.glob(File.join(logs_dir, "*-output.jsonl"))
      .reject { _1.include?("planning") }
      .max_by { File.mtime(_1) }
    skip "No real log files found" unless real_log

    # Extract issue id from filename (e.g., 20260130-081136-vpp-bench-h3h.12-output.jsonl)
    basename = File.basename(real_log, "-output.jsonl")
    issue_id = basename.sub(/^\d{8}-\d{6}-/, "")

    digest = @runner.extract_digest( real_log, issue_id, 0)

    assert digest, "digest should not be nil for real log"
    assert_equal issue_id, digest[:issue_id]
    assert_includes %w[success failure], digest[:status]
    assert digest[:duration_s] >= 0, "duration should be non-negative"
    assert digest[:num_turns] >= 0, "num_turns should be non-negative"
    assert digest[:tools_summary].is_a?(Hash), "tools_summary should be a hash"
    assert digest[:files_modified].is_a?(Array), "files_modified should be an array"
    assert digest[:bd_mutations].is_a?(Array), "bd_mutations should be an array"
    assert digest[:token_usage].is_a?(Hash), "token_usage should be a hash"
  end
end
