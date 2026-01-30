# frozen_string_literal: true

# lib/walk/reporting.rb — Shared reporting logic for walk CLI and driver.
#
# Centralizes data-gathering and formatting used by bin/walk (status,
# history, summary) and PlanningLifecycle#write_walk_summary so that
# changes to the report format only need to happen in one place.

require "time"

module Walk
  module Reporting
    module_function

    # Format a duration in seconds into a human-readable string.
    # Handles hours, minutes, and seconds.
    def format_duration(seconds)
      if seconds >= 3600
        h = (seconds / 3600).to_i
        m = ((seconds % 3600) / 60).to_i
        "#{h}h#{m}m"
      elsif seconds >= 60
        "#{(seconds / 60).to_i}m#{(seconds % 60).to_i}s"
      else
        "#{seconds.round(1)}s"
      end
    end

    # Gather aggregated walk data from a backend. Returns a hash with
    # all the fields needed by history, summary, and write_walk_summary.
    #
    # Keys:
    #   :title, :body, :status, :started_at, :timeline,
    #   :open_issues, :issues_closed, :open_issues_count,
    #   :total_runs, :total_duration_s, :total_cost
    def walk_data(backend)
      meta = backend.respond_to?(:read_walk_meta) ? backend.read_walk_meta : nil
      timeline = backend.respond_to?(:walk_timeline) ? backend.walk_timeline : []
      started_at = backend.respond_to?(:walk_started_at) ? backend.walk_started_at : nil
      open_issues = backend.respond_to?(:list_issues) ? backend.list_issues(status: "open") : []

      total_runs = timeline.sum { |e| e[:run_count] }
      total_dur = timeline.sum { |e| e[:duration_s] }
      total_cost_raw = timeline.sum { |e| e[:cost_usd] || 0 }

      {
        title: meta ? meta[:title] : "Untitled walk",
        body: meta && meta[:body] && !meta[:body].empty? ? meta[:body] : nil,
        status: meta ? meta[:status] : "unknown",
        started_at: started_at,
        timeline: timeline,
        open_issues: open_issues,
        issues_closed: timeline.length,
        open_issues_count: open_issues.length,
        total_runs: total_runs,
        total_duration_s: total_dur,
        total_cost: total_cost_raw.positive? ? total_cost_raw.round(2) : nil
      }
    end

    # Format a single timeline entry into a one-line string.
    #
    # Example: "2026-01-30 14:30  fix-bug (task, 2 runs, 3m12s, $0.42)"
    def format_timeline_entry(entry)
      ts = entry[:closed_at] ? Time.parse(entry[:closed_at].to_s).strftime("%Y-%m-%d %H:%M") : "??"
      runs_label = "#{entry[:run_count]} run#{"s" if entry[:run_count] != 1}"
      dur_label = format_duration(entry[:duration_s])
      cost_label = entry[:cost_usd] ? ", $#{"%.2f" % entry[:cost_usd]}" : ""
      { ts: ts, runs_label: runs_label, dur_label: dur_label, cost_label: cost_label }
    end

    # Print a walk status dashboard to stdout. Used by bin/walk status.
    def print_status(s)
      puts "Walk: #{s[:title]}"
      puts "Status: #{s[:walk_status]}"
      puts "Open: #{s[:open_count]} (#{s[:ready_count]} ready, #{s[:blocked_count]} blocked)"
      puts "Closed: #{s[:closed_count]}"
      puts "Dir: #{s[:walk_dir]}"

      if s[:total_runs] > 0
        puts ""
        puts "Runs: #{s[:total_runs]} total, #{s[:success_count]} ok, #{s[:failure_count]} failed"
        puts "Agent time: #{format_duration(s[:total_duration])}"
        puts "Total cost: $#{"%.2f" % s[:total_cost]}" if s[:total_cost]
      end

      summaries = s[:issue_summaries] || []
      if summaries.any? { |i| i[:run_count] > 0 || i[:result_excerpt] }
        puts ""
        puts "Issues:"
        summaries.each do |i|
          status_mark = i[:status] == "closed" ? "x" : " "
          dur = i[:total_duration] > 0 ? format_duration(i[:total_duration]) : "-"
          runs = i[:run_count] > 0 ? "#{i[:run_count]} run#{"s" if i[:run_count] != 1}" : "no runs"
          fail_note = i[:failure_runs] > 0 ? " (#{i[:failure_runs]} FAILED)" : ""
          cost_note = i[:cost_usd] ? " $#{"%.2f" % i[:cost_usd]}" : ""
          excerpt = i[:result_excerpt] ? " | #{i[:result_excerpt]}" : ""
          puts "  [#{status_mark}] #{i[:slug]} | #{dur} | #{runs}#{fail_note}#{cost_note}#{excerpt}"
        end
      end
    end

    # Print a walk history timeline to stdout. Used by bin/walk history.
    def print_history(data)
      puts "Walk: #{data[:title]}"
      puts "Started: #{data[:started_at]&.iso8601 || '(unknown)'}"
      puts "Timeline (#{data[:issues_closed]} issues closed):"
      puts ""

      data[:timeline].each do |entry|
        parts = format_timeline_entry(entry)
        puts "  #{parts[:ts]}  #{entry[:slug]} (#{entry[:type]}, #{parts[:runs_label]}, #{parts[:dur_label]}#{parts[:cost_label]})"
        puts "    Done: #{entry[:close_reason]}" if entry[:close_reason]
        puts ""
      end

      total_dur = format_duration(data[:total_duration_s])
      cost_part = data[:total_cost] ? ", $#{"%.2f" % data[:total_cost]} total cost" : ""
      puts "Total: #{data[:issues_closed]} issues, #{data[:total_runs]} runs, #{total_dur} agent time#{cost_part}"
    end

    # Render a markdown summary of the walk. Used by both
    # PlanningLifecycle#write_walk_summary and bin/walk summary.
    #
    # Options:
    #   include_finished_at: true to include a "Finished" timestamp
    def render_summary_markdown(data, include_finished_at: false)
      lines = []
      lines << "# #{data[:title]}"
      lines << ""
      lines << data[:body] if data[:body]
      lines << ""
      lines << "## Statistics"
      lines << ""
      lines << "- **Status**: #{data[:status]}" if include_finished_at
      lines << "- **Started**: #{data[:started_at]&.iso8601 || '(unknown)'}"
      lines << "- **Finished**: #{Time.now.iso8601}" if include_finished_at
      lines << "- **Issues closed**: #{data[:issues_closed]}"
      lines << "- **Issues open**: #{data[:open_issues_count]}"
      lines << "- **Total runs**: #{data[:total_runs]}"
      lines << "- **Agent time**: #{format_duration(data[:total_duration_s])}"
      lines << "- **Total cost**: $#{"%.2f" % data[:total_cost]}" if data[:total_cost]
      lines << ""

      if data[:timeline].any?
        lines << "## Issue Timeline"
        lines << ""
        data[:timeline].each do |entry|
          parts = format_timeline_entry(entry)
          lines << "- **#{parts[:ts]}** - #{entry[:slug]} (#{entry[:type]}, #{parts[:runs_label]}, #{parts[:dur_label]}#{parts[:cost_label]})"
          lines << "  - #{entry[:close_reason]}" if entry[:close_reason]
        end
        lines << ""
      end

      open_issues = data[:open_issues] || []
      if open_issues.any?
        lines << "## Open Issues"
        lines << ""
        open_issues.each do |i|
          lines << "- #{i[:slug]} - #{i[:title]} (P#{i[:priority]}, #{i[:type]})"
        end
        lines << ""
      end

      lines.join("\n")
    end
  end
end
