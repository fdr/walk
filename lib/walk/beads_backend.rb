# frozen_string_literal: true

# lib/walk/beads_backend.rb — Beads (bd CLI) walk backend.
#
# Implements the Backend interface by shelling out to the `bd` CLI tool.
# Used by scripts/walk-runner.rb for the original beads-backed driver loop.

require "fileutils"
require "json"
require "open3"
require "time"
require_relative "backend"

module Walk
  class BeadsBackend < Backend
    attr_reader :walk_dir

    def initialize(parent: nil, db: nil, walk_dir: nil)
      @parent = parent
      @db = db
      @walk_dir = walk_dir
    end

    def ready_issues(parent: nil)
      filter = parent || @parent
      cmd = bd_cmd("ready", "--limit", "20", "--json")
      cmd += ["--parent", filter] if filter
      output, status = Open3.capture2(*cmd)
      return [] unless status.success?

      JSON.parse(output, symbolize_names: true)
        .sort_by { _1[:priority] }
    rescue JSON::ParserError
      []
    end

    def fetch_issue(id)
      output, status = Open3.capture2(*bd_cmd("show", id, "--json"))
      return nil unless status.success?

      issues = JSON.parse(output, symbolize_names: true)
      issues.first
    rescue JSON::ParserError
      nil
    end

    def close_issue(id, reason:)
      system(*bd_cmd("close", id, "--reason", reason))
    end

    def add_comment(id, text)
      system(*bd_cmd("comments", "add", id, text))
    end

    def create_issue(title:, parent: nil, deps: nil, priority: 2, description: "")
      cmd = bd_cmd("create", title)
      cmd += ["--parent", parent] if parent
      cmd += ["--deps", deps] if deps
      cmd += ["-p", priority.to_s]
      cmd += ["--description", description] unless description.empty?
      system(*cmd)
    end

    def fetch_comments(id)
      output, status = Open3.capture2(*bd_cmd("comments", id))
      return nil unless status.success?

      output.strip.empty? ? nil : output.strip
    end

    def load_parent_context(issue)
      parent_id = issue[:parent]
      return nil unless parent_id

      load_parent_epic(issue)
    end

    # Fetch epic output for planning prompts.
    def fetch_epic_output(epic_id)
      output, status = Open3.capture2(*bd_cmd("show", epic_id))
      return nil unless status.success?

      output
    end

    # Check if parent epic is closed.
    def parent_closed?(parent_id)
      parent = fetch_issue(parent_id)
      parent && parent[:status] == "closed"
    end

    # --- Walk lifecycle methods (used by PlanningLifecycle) ---

    # Record walk status as a comment on the parent epic.
    def update_walk_status(status, reason: nil)
      return unless @parent

      msg = "Walk status: #{status}"
      msg += " — #{reason}" if reason
      add_comment(@parent, msg)
    end

    # Return walk metadata from the parent epic.
    def read_walk_meta
      return nil unless @parent

      epic = fetch_issue(@parent)
      return nil unless epic

      {
        title: epic[:title],
        status: epic[:status],
        body: epic[:description]
      }
    end

    # Return closed child issues with close timestamps for timeline.
    def walk_timeline
      return [] unless @parent

      issues = list_issues_raw(status: "closed")
      issues.map do |issue|
        {
          slug: issue[:id],
          title: issue[:title],
          type: issue[:issue_type] || "task",
          closed_at: issue[:closed_at],
          duration_s: duration_from_timestamps(issue[:created_at], issue[:closed_at]),
          run_count: 1,
          close_reason: issue[:close_reason]&.slice(0, 120)
        }
      end.sort_by { |e| e[:closed_at].to_s }
    end

    # List issues filtered by status.
    def list_issues(status: "open")
      return [] unless @parent

      issues = list_issues_raw(status: status)
      issues.map do |issue|
        {
          slug: issue[:id],
          title: issue[:title],
          priority: issue[:priority],
          type: issue[:issue_type] || "task"
        }
      end
    end

    # Return the earliest created_at among child issues.
    def walk_started_at
      return nil unless @parent

      cmd = bd_cmd("list", "--parent", @parent, "--all", "--limit", "0", "--json")
      output, status = Open3.capture2(*cmd)
      return nil unless status.success?

      issues = JSON.parse(output, symbolize_names: true)
      earliest = nil
      issues.each do |issue|
        next unless issue[:created_at]

        t = Time.parse(issue[:created_at].to_s)
        earliest = t if earliest.nil? || t < earliest
      rescue ArgumentError
        # skip unparseable timestamps
      end
      earliest
    rescue JSON::ParserError
      nil
    end

    private

    # Fetch child issues from bd list with status filter, returning raw hashes.
    def list_issues_raw(status:)
      cmd = bd_cmd("list", "--parent", @parent, "--status", status,
                    "--limit", "0", "--json")
      output, st = Open3.capture2(*cmd)
      return [] unless st.success?

      JSON.parse(output, symbolize_names: true)
    rescue JSON::ParserError
      []
    end

    # Estimate duration from created_at to closed_at timestamps.
    # Beads doesn't track per-run durations, so this is the best approximation.
    def duration_from_timestamps(created_at, closed_at)
      return 0.0 unless created_at && closed_at

      started = Time.parse(created_at.to_s)
      finished = Time.parse(closed_at.to_s)
      [finished - started, 0.0].max
    rescue ArgumentError
      0.0
    end

    # Build a bd CLI command array, injecting --db when configured.
    def bd_cmd(*args)
      @db ? ["bd", "--db", @db, *args] : ["bd", *args]
    end

    def load_parent_epic(issue)
      parent_id = issue[:parent]
      return nil unless parent_id

      parent = fetch_issue(parent_id)
      return nil unless parent

      parts = []
      if parent[:parent]
        grandparent_context = load_parent_epic(parent)
        parts << grandparent_context if grandparent_context
      end
      parts << "## Parent: #{parent[:id]} -- #{parent[:title]}\n\n#{parent[:description]}"

      comments = fetch_comments(parent_id)
      if comments
        parts << "## Epic Comments\n\n#{comments}"
      end

      parts.join("\n\n---\n\n")
    end
  end
end
