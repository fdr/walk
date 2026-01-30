# frozen_string_literal: true

# test_walk_backend.rb — Contract tests for walk backends.
#
# Verifies both DirectoryBackend and BeadsBackend return correct shapes
# from the 7 Backend interface methods.
#
# - DirectoryBackend: tested with tmpdir (unit test, always runnable)
# - BeadsBackend: tested with bd CLI (integration test, skip when bd unavailable)
#
# Usage:
#   ruby test/test_walk_backend.rb

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "yaml"
require "json"
require "open3"

require_relative "../lib/walk/directory_backend"
require_relative "../lib/walk/beads_backend"

# Shared contract assertions for any Walk::Backend subclass.
module BackendContractTests
  # --- ready_issues ---

  def test_ready_issues_returns_array
    issues = @backend.ready_issues
    assert_kind_of Array, issues
  end

  def test_ready_issues_elements_have_required_keys
    seed_issue
    issues = @backend.ready_issues
    return if issues.empty?

    issue = issues.first
    assert_respond_to issue, :[]
    assert issue[:slug] || issue[:id], "issue must have :slug or :id"
    assert issue[:title], "issue must have :title"
    assert issue[:priority], "issue must have :priority"
  end

  # --- fetch_issue ---

  def test_fetch_issue_returns_hash_or_nil
    result = @backend.fetch_issue(@known_issue_id)
    assert(result.nil? || result.is_a?(Hash),
           "fetch_issue must return Hash or nil, got #{result.class}")
  end

  def test_fetch_issue_nonexistent_returns_nil
    result = @backend.fetch_issue("nonexistent-issue-slug-xyz-999")
    assert_nil result
  end

  # --- add_comment ---

  def test_add_comment_does_not_raise
    seed_issue
    result = @backend.add_comment(@known_issue_id, "contract test comment")
    # Result may be a hash, true, or nil depending on backend; just assert no exception
    assert true
  end

  # --- fetch_comments ---

  def test_fetch_comments_returns_string_or_nil
    seed_issue
    @backend.add_comment(@known_issue_id, "contract test comment")
    result = @backend.fetch_comments(@known_issue_id)
    assert(result.nil? || result.is_a?(String),
           "fetch_comments must return String or nil, got #{result.class}")
  end

  # --- create_issue ---

  def test_create_issue_does_not_raise
    result = @backend.create_issue(title: "Contract test issue",
                                   description: "Created by contract test")
    assert true
  end

  # --- close_issue ---

  def test_close_issue_does_not_raise
    seed_closable_issue
    result = @backend.close_issue(@closable_issue_id, reason: "contract test close")
    assert true
  end

  # --- load_parent_context ---

  def test_load_parent_context_returns_string_or_nil
    seed_issue
    issue = @backend.fetch_issue(@known_issue_id)
    return skip("fetch_issue returned nil") unless issue

    result = @backend.load_parent_context(issue)
    assert(result.nil? || result.is_a?(String),
           "load_parent_context must return String or nil, got #{result.class}")
  end
end

# Shared lifecycle contract tests for backends that implement walk lifecycle
# methods (update_walk_status, read_walk_meta, walk_timeline, list_issues,
# walk_started_at). Requires @backend to respond to these methods and
# seed_lifecycle to populate test data.
module LifecycleContractTests
  # --- update_walk_status ---

  def test_update_walk_status_does_not_raise
    seed_lifecycle
    @backend.update_walk_status("completed", reason: "lifecycle contract test")
    assert true
  end

  # --- read_walk_meta ---

  def test_read_walk_meta_returns_hash_or_nil
    seed_lifecycle
    result = @backend.read_walk_meta
    assert(result.nil? || result.is_a?(Hash),
           "read_walk_meta must return Hash or nil, got #{result.class}")
  end

  def test_read_walk_meta_has_title_and_status
    seed_lifecycle
    meta = @backend.read_walk_meta
    return skip("read_walk_meta returned nil") unless meta

    assert meta[:title], "read_walk_meta must include :title"
    assert meta[:status], "read_walk_meta must include :status"
  end

  # --- walk_timeline ---

  def test_walk_timeline_returns_array
    seed_lifecycle
    result = @backend.walk_timeline
    assert_kind_of Array, result
  end

  def test_walk_timeline_entries_have_required_keys
    seed_lifecycle_with_closed_issue
    timeline = @backend.walk_timeline
    return skip("no closed issues in timeline") if timeline.empty?

    entry = timeline.first
    assert entry[:slug], "timeline entry must have :slug"
    assert entry[:type], "timeline entry must have :type"
    assert_respond_to entry[:duration_s], :to_f, "timeline entry must have numeric :duration_s"
    assert_respond_to entry[:run_count], :to_i, "timeline entry must have numeric :run_count"
  end

  # --- list_issues ---

  def test_list_issues_returns_array
    seed_lifecycle
    result = @backend.list_issues(status: "open")
    assert_kind_of Array, result
  end

  def test_list_issues_closed_returns_array
    seed_lifecycle
    result = @backend.list_issues(status: "closed")
    assert_kind_of Array, result
  end

  def test_list_issues_elements_have_required_keys
    seed_lifecycle
    issues = @backend.list_issues(status: "open")
    return skip("no open issues") if issues.empty?

    issue = issues.first
    assert issue[:slug], "list_issues entry must have :slug"
    assert issue[:title], "list_issues entry must have :title"
    assert issue[:priority], "list_issues entry must have :priority"
    assert issue[:type], "list_issues entry must have :type"
  end

  # --- walk_started_at ---

  def test_walk_started_at_returns_time_or_nil
    seed_lifecycle
    result = @backend.walk_started_at
    assert(result.nil? || result.is_a?(Time),
           "walk_started_at must return Time or nil, got #{result.class}")
  end
end

# --- DirectoryBackend contract tests (always runnable) ---

class DirectoryBackendContractTest < Minitest::Test
  include BackendContractTests
  include LifecycleContractTests

  def setup
    @tmpdir = Dir.mktmpdir("walk-contract-")
    open_dir = File.join(@tmpdir, "open")
    FileUtils.mkdir_p(open_dir)
    FileUtils.mkdir_p(File.join(@tmpdir, "closed"))

    # Write _walk.md for load_parent_context
    File.write(File.join(@tmpdir, "_walk.md"), <<~MD)
      ---
      title: "Contract test walk"
      status: open
      ---

      Contract testing walk.
    MD

    @backend = Walk::DirectoryBackend.new(@tmpdir)
    @known_issue_id = "contract-issue"
    @closable_issue_id = "closable-issue"
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  private

  def seed_issue
    dir = File.join(@tmpdir, "open", @known_issue_id)
    return if Dir.exist?(dir)

    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "issue.md"), <<~MD)
      ---
      title: "Contract test issue"
      type: task
      priority: 2
      ---

      Body for contract testing.
    MD
  end

  def seed_closable_issue
    dir = File.join(@tmpdir, "open", @closable_issue_id)
    return if Dir.exist?(dir)

    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "issue.md"), <<~MD)
      ---
      title: "Closable issue"
      type: task
      priority: 2
      ---

      Will be closed by contract test.
    MD
  end

  def seed_lifecycle
    seed_issue
  end

  def seed_lifecycle_with_closed_issue
    seed_lifecycle
    slug = "closed-lifecycle-issue"
    dir = File.join(@tmpdir, "closed", slug)
    return if Dir.exist?(dir)

    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "issue.md"), <<~MD)
      ---
      title: "Closed lifecycle issue"
      type: task
      priority: 2
      ---

      Closed for lifecycle testing.
    MD
    File.write(File.join(dir, "close.yaml"), YAML.dump(
      "status" => "closed",
      "reason" => "lifecycle test",
      "closed_at" => Time.now.iso8601
    ))
  end
end

# --- BeadsBackend contract tests (sandbox temp database) ---
#
# Creates a temporary bd database in a tmpdir so write operations
# (create_issue, close_issue, add_comment) are tested without
# mutating the real project database.

class BeadsBackendContractTest < Minitest::Test
  include BackendContractTests
  include LifecycleContractTests

  def setup
    _out, status = Open3.capture2("bd", "version")
    skip "bd CLI not available" unless status.success?

    # Create a temp directory with a fresh bd database
    @tmpdir = Dir.mktmpdir("bd-contract-")
    @walk_dir = File.join(@tmpdir, "walk-output")
    FileUtils.mkdir_p(@walk_dir)
    system("git", "init", @tmpdir, out: File::NULL, err: File::NULL)
    system("bd", "init", "--prefix", "ct", "--quiet",
           "--skip-hooks", "--skip-merge-driver",
           chdir: @tmpdir)
    @db_path = File.join(@tmpdir, ".beads", "beads.db")

    # Create a parent epic for lifecycle tests
    output, _status = Open3.capture2(
      "bd", "--db", @db_path, "create", "Contract test epic",
      "-p", "1", "--description", "Epic for lifecycle contract tests."
    )
    @parent_id = output[/^. Created issue: (\S+)/, 1]

    @backend = Walk::BeadsBackend.new(db: @db_path, parent: @parent_id,
                                      walk_dir: @walk_dir)

    # Seed a known issue as child of the epic
    output, _status = Open3.capture2(
      "bd", "--db", @db_path, "create", "Seed issue",
      "-p", "2", "--parent", @parent_id,
      "--description", "Seeded in setup for contract tests."
    )
    @known_issue_id = output[/^. Created issue: (\S+)/, 1]
    @closable_issue_id = nil
  end

  def teardown
    FileUtils.rm_rf(@tmpdir) if @tmpdir
  end

  private

  def seed_issue
    return if @known_issue_id

    output, _status = Open3.capture2(
      "bd", "--db", @db_path, "create", "Contract test issue",
      "-p", "2", "--parent", @parent_id,
      "--description", "Body for contract testing."
    )
    @known_issue_id = output[/^. Created issue: (\S+)/, 1]
  end

  def seed_closable_issue
    return if @closable_issue_id

    output, _status = Open3.capture2(
      "bd", "--db", @db_path, "create", "Closable issue",
      "-p", "2", "--parent", @parent_id,
      "--description", "Will be closed by contract test."
    )
    @closable_issue_id = output[/^. Created issue: (\S+)/, 1]
  end

  def seed_lifecycle
    seed_issue
  end

  def seed_lifecycle_with_closed_issue
    seed_lifecycle
    return if @_closed_lifecycle_seeded

    output, _status = Open3.capture2(
      "bd", "--db", @db_path, "create", "Closed lifecycle issue",
      "-p", "2", "--parent", @parent_id,
      "--description", "Will be closed for lifecycle testing."
    )
    closed_id = output[/^. Created issue: (\S+)/, 1]
    system("bd", "--db", @db_path, "close", closed_id,
           "--reason", "lifecycle test",
           out: File::NULL, err: File::NULL)
    @_closed_lifecycle_seeded = true
  end
end
