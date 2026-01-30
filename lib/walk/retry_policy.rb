# frozen_string_literal: true

# lib/walk/retry_policy.rb — Retry policy for walk driver issue execution.
#
# Tracks consecutive failures per issue and blocks issues after
# MAX_CONSECUTIVE_FAILURES to prevent infinite retry loops.

require "json"

module Walk
  class RetryPolicy
    MAX_CONSECUTIVE_FAILURES = 3

    # Count consecutive failures (non-zero exit) from the most recent runs.
    # Returns 0 if no runs exist or if the last run succeeded.
    # Skips runs with nil exit_code (signal-killed / interrupted) so that
    # external interruptions (SIGINT/SIGTERM) don't inflate the failure count.
    def consecutive_failures(issue)
      runs_dir = issue[:dir] && File.join(issue[:dir], "runs")
      return 0 unless runs_dir && Dir.exist?(runs_dir)

      count = 0
      Dir.children(runs_dir).sort.reverse_each do |ts_dir|
        meta_file = File.join(runs_dir, ts_dir, "meta.json")
        next unless File.exist?(meta_file)

        begin
          meta = JSON.parse(File.read(meta_file))
          next if meta["exit_code"].nil?
          break if meta["exit_code"] == 0

          count += 1
        rescue JSON::ParserError
          count += 1
        end
      end
      count
    end

    # Whether the driver should warn about impending block.
    def should_warn?(failures)
      failures == 2
    end

    # Whether the driver should block the issue.
    def should_block?(failures)
      failures >= MAX_CONSECUTIVE_FAILURES
    end

    # Block an issue after MAX_CONSECUTIVE_FAILURES.
    # Writes a marker file and adds an explanatory comment via the backend.
    def block_issue!(issue, failure_count, backend:)
      issue_id = issue[:id] || issue[:slug]
      issue_dir = issue[:dir]

      # Collect run details for the comment
      run_details = []
      if issue_dir
        runs_dir = File.join(issue_dir, "runs")
        if Dir.exist?(runs_dir)
          Dir.children(runs_dir).sort.last(failure_count).each do |ts_dir|
            meta_file = File.join(runs_dir, ts_dir, "meta.json")
            next unless File.exist?(meta_file)

            begin
              meta = JSON.parse(File.read(meta_file))
              run_details << "#{ts_dir}: exit_code=#{meta['exit_code']}"
            rescue JSON::ParserError
              run_details << "#{ts_dir}: (corrupt meta.json)"
            end
          end
        end

        # Write marker file
        File.write(File.join(issue_dir, "blocked_by_driver"),
                   "Blocked after #{failure_count} consecutive failures at #{Time.now.iso8601}\n" \
                   "Runs: #{run_details.join(', ')}\n")
      end

      comment = "[driver] Blocked after #{failure_count} consecutive failures.\n" \
                "Failed runs:\n#{run_details.map { |d| "  - #{d}" }.join("\n")}\n\n" \
                "To unblock: remove the `blocked_by_driver` file from the issue directory."
      backend.add_comment(issue_id, comment)
    end
  end
end
