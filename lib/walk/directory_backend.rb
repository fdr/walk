# frozen_string_literal: true

# lib/walk/directory_backend.rb — Directory-based walk backend.
#
# Stores issues as directories under walk_dir/open/ and walk_dir/closed/.
# Each issue has an issue.md (YAML frontmatter + body), optional comments.md,
# and optional blocked_by/ directory with symlinks to blocking issues.

require "json"
require "time"
require "yaml"

require_relative "backend"

module Walk
  class DirectoryBackend < Backend
    attr_reader :walk_dir

    def initialize(walk_dir)
      @walk_dir = walk_dir
    end

    # --- Backend interface ---

    def ready_issues(parent: nil)
      # list_issues already filters out blocked issues via blocked?
      # Just exclude epics (containers, not work items)
      list_issues(status: "open").reject { |i| i[:type] == "epic" }
    end

    def fetch_issue(id)
      show_issue(id)
    end

    def close_issue(id, reason:, status: "closed")
      close_issue_with_status(id, reason: reason, status: status)
    end

    def add_comment(id, text)
      issue_dir = find_issue_dir(id)
      unless issue_dir
        $stderr.puts "Error: issue '#{id}' not found"
        return nil
      end

      comments_file = File.join(issue_dir, "comments.md")
      File.open(comments_file, "a") do |f|
        f.flock(File::LOCK_EX)
        f.puts "\n## #{Time.now.iso8601}\n\n#{text}\n"
      end

      { slug: id, commented: true, file: comments_file }
    end

    def create_issue(title:, parent: nil, deps: nil, priority: 2, description: "")
      # For directory backend, parent is ignored (flat structure).
      # Use a slug derived from title if no explicit slug is given.
      slug = title.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/^-|-$/, "")
      create_issue_by_slug(slug, title: title, type: "task", priority: priority,
                           body: description, blocked_by: deps)
    end

    def fetch_comments(id)
      issue_dir = find_issue_dir(id)
      return nil unless issue_dir

      comments_file = File.join(issue_dir, "comments.md")
      return nil unless File.exist?(comments_file)

      comments = File.read(comments_file)
      comments.length > 2000 ? comments[-2000..] : comments
    end

    def load_parent_context(issue)
      # Return walk-level context only.
      # Agents can opt-in to reading parent issues via discovered_by/ symlinks.
      meta = read_walk_meta
      return nil unless meta

      "## Walk: #{meta[:title]}\n\n#{meta[:body]}"
    end

    # --- Extended API (used by CLI subcommands) ---

    def read_walk_meta
      meta_path = File.join(@walk_dir, "_walk.md")
      return nil unless File.exist?(meta_path)

      parsed = parse_frontmatter_file(meta_path)
      config = parsed[:frontmatter]["config"] || {}
      parsed.merge(walk_dir: @walk_dir, config: symbolize_config(config))
    end

    def read_issue(dir_path)
      issue_file = File.join(dir_path, "issue.md")
      return nil unless File.exist?(issue_file)

      parsed = parse_frontmatter_file(issue_file)
      slug = File.basename(dir_path)
      {
        slug: slug,
        dir: dir_path,
        title: parsed[:frontmatter]["title"] || slug,
        type: parsed[:frontmatter]["type"] || "task",
        priority: parsed[:frontmatter]["priority"] || 2,
        body: parsed[:body]
      }
    end

    def list_issues(status: "open")
      dir = File.join(@walk_dir, status == "closed" ? "closed" : "open")
      return [] unless Dir.exist?(dir)

      Dir.glob(File.join(dir, "*")).select { |d| Dir.exist?(d) }.filter_map do |d|
        if status == "closed"
          read_closed_issue(d)
        else
          next if blocked?(d)
          read_issue(d)
        end
      rescue Errno::ENOENT
        # Issue directory was moved by a concurrent thread (e.g. closed by
        # another agent). Safe to skip — the issue is already handled.
        nil
      end.sort_by do |i|
        if status == "closed"
          i[:closed_at].to_s
        else
          # .next file bumps to front (priority 0), deleted when issue is closed
          has_next = File.exist?(File.join(i[:dir], ".next"))
          [has_next ? 0 : 1, i[:priority]]
        end
      end
    end

    def show_issue(slug)
      %w[open closed].each do |subdir|
        dir_path = File.join(@walk_dir, subdir, slug)
        if Dir.exist?(dir_path)
          issue = subdir == "closed" ? read_closed_issue(dir_path) : read_issue(dir_path)
          return issue.merge(status: subdir) if issue
        end
      end
      nil
    end

    def create_issue_by_slug(slug, title:, type: "task", priority: 2, body: "", blocked_by: nil)
      with_walk_lock do
        existing = find_issue_dir(slug)
        if existing
          location = existing.include?("/closed/") ? "closed/" : "open/"
          $stderr.puts "Error: issue '#{slug}' already exists in #{location}"
          return nil
        end

        open_dir = File.join(@walk_dir, "open")
        issue_dir = File.join(open_dir, slug)

        FileUtils.mkdir_p(issue_dir)
        File.write(File.join(issue_dir, "issue.md"),
                   yaml_frontmatter({ "title" => title, "type" => type, "priority" => priority }, body))

        if blocked_by
          blocked_by_dir = File.join(issue_dir, "blocked_by")
          FileUtils.mkdir_p(blocked_by_dir)
          Array(blocked_by).each do |dep_slug|
            File.symlink("../../#{dep_slug}", File.join(blocked_by_dir, dep_slug))
          end
        end

        read_issue(issue_dir)
      end
    end

    def scaffold_walk(title:)
      path = @walk_dir
      if Dir.exist?(path) && !Dir.empty?(path)
        $stderr.puts "Error: directory '#{path}' already exists and is not empty"
        return nil
      end

      FileUtils.mkdir_p(File.join(path, "open"))
      FileUtils.mkdir_p(File.join(path, "closed"))
      File.write(File.join(path, "_walk.md"),
                 yaml_frontmatter({ "title" => title, "status" => "open" },
                                  "## Goals\n\n- (describe walk goals here)"))

      { walk_dir: path, title: title }
    end

    def walk_timeline
      closed_dir = File.join(@walk_dir, "closed")
      return [] unless Dir.exist?(closed_dir)

      entries = Dir.glob(File.join(closed_dir, "*")).select { |d| Dir.exist?(d) }.filter_map { |d|
        issue = read_closed_issue(d)
        next unless issue

        runs_dir = File.join(d, "runs")
        run_count = 0
        duration_s = 0.0
        cost_usd = 0.0

        if Dir.exist?(runs_dir)
          Dir.children(runs_dir).sort.each do |ts_dir|
            meta_file = File.join(runs_dir, ts_dir, "meta.json")
            next unless File.exist?(meta_file)

            run_count += 1
            begin
              meta = JSON.parse(File.read(meta_file))
              if meta["started_at"] && meta["finished_at"]
                started = Time.parse(meta["started_at"])
                finished = Time.parse(meta["finished_at"])
                duration_s += (finished - started)
              end
              cost_usd += meta["cost_usd"] if meta["cost_usd"]
            rescue JSON::ParserError, ArgumentError
              # skip malformed meta
            end
          end
        end

        close_reason = issue[:close_reason] || issue[:result]
        close_reason = close_reason[0, 120] if close_reason

        {
          slug: issue[:slug],
          title: issue[:title],
          type: issue[:type],
          closed_at: issue[:closed_at],
          duration_s: duration_s,
          run_count: run_count,
          cost_usd: cost_usd.positive? ? cost_usd.round(2) : nil,
          close_reason: close_reason
        }
      }

      entries.sort_by { |e| e[:closed_at].to_s }
    end

    def walk_started_at
      # Infer from the earliest run timestamp across all issues
      earliest = nil
      %w[open closed].each do |subdir|
        dir = File.join(@walk_dir, subdir)
        next unless Dir.exist?(dir)

        Dir.glob(File.join(dir, "*/runs/*")).each do |run_dir|
          meta_file = File.join(run_dir, "meta.json")
          next unless File.exist?(meta_file)

          begin
            meta = JSON.parse(File.read(meta_file))
            if meta["started_at"]
              t = Time.parse(meta["started_at"])
              earliest = t if earliest.nil? || t < earliest
            end
          rescue JSON::ParserError, ArgumentError
            # skip
          end
        end
      end
      earliest
    end

    def update_walk_status(new_status, reason: nil)
      meta_path = File.join(@walk_dir, "_walk.md")
      return nil unless File.exist?(meta_path)

      parsed = parse_frontmatter_file(meta_path)
      fm = parsed[:frontmatter]
      fm["status"] = new_status

      if new_status == "open"
        fm.delete("finished_at")
        fm.delete("finish_reason")
      else
        fm["finished_at"] = Time.now.iso8601
        fm["finish_reason"] = reason if reason
      end

      File.write(meta_path, yaml_frontmatter(fm, parsed[:body]))
      { status: new_status, finished_at: fm["finished_at"], finish_reason: reason }
    end

    def walk_status
      meta = read_walk_meta
      open_dir = File.join(@walk_dir, "open")
      closed_dir = File.join(@walk_dir, "closed")

      open_issues = Dir.exist?(open_dir) ? Dir.glob(File.join(open_dir, "*")).select { |d| Dir.exist?(d) } : []
      closed_issues = Dir.exist?(closed_dir) ? Dir.glob(File.join(closed_dir, "*")).select { |d| Dir.exist?(d) } : []

      blocked_count = open_issues.count { |d| blocked?(d) }
      driver_blocked_count = open_issues.count { |d| File.exist?(File.join(d, "blocked_by_driver")) }
      ready_count = open_issues.length - blocked_count

      # Collect per-issue summaries and aggregate stats
      issue_summaries = []
      total_runs = 0
      total_duration = 0.0
      total_cost = 0.0
      success_count = 0
      failure_count = 0
      total_retries = 0

      closed_issues.each do |d|
        summary = issue_run_summary(d)
        issue_summaries << summary
        total_runs += summary[:run_count]
        total_duration += summary[:total_duration]
        total_cost += summary[:cost_usd] if summary[:cost_usd]
        success_count += summary[:success_runs]
        failure_count += summary[:failure_runs]
        total_retries += summary[:consecutive_failures]
      end

      open_issues.each do |d|
        summary = issue_run_summary(d)
        issue_summaries << summary
        total_runs += summary[:run_count]
        total_duration += summary[:total_duration]
        total_cost += summary[:cost_usd] if summary[:cost_usd]
        success_count += summary[:success_runs]
        failure_count += summary[:failure_runs]
        total_retries += summary[:consecutive_failures]
      end

      {
        title: meta ? meta[:title] : "Untitled walk",
        walk_status: meta ? meta[:status] : "unknown",
        open_count: open_issues.length,
        closed_count: closed_issues.length,
        ready_count: ready_count,
        blocked_count: blocked_count,
        driver_blocked_count: driver_blocked_count,
        walk_dir: @walk_dir,
        issue_summaries: issue_summaries,
        total_runs: total_runs,
        total_duration: total_duration,
        total_cost: total_cost.positive? ? total_cost.round(2) : nil,
        success_count: success_count,
        failure_count: failure_count,
        total_retries: total_retries
      }
    end

    private

    # Acquire an exclusive file lock on a walk-level lockfile.
    # Provides defense-in-depth against concurrent writes from multiple
    # processes (e.g. multiple driver instances or manual CLI use).
    def with_walk_lock
      lockfile = File.join(@walk_dir, ".walk.lock")
      File.open(lockfile, File::CREAT | File::RDWR) do |f|
        f.flock(File::LOCK_EX)
        yield
      end
    end

    # Generate a markdown file with YAML frontmatter.
    # Uses YAML.dump for proper escaping of special characters.
    def yaml_frontmatter(hash, body = nil)
      # YAML.dump produces "---\n...\n" — strip the trailing "...\n"
      yaml = YAML.dump(hash).sub(/\.\.\.\n\z/, "")
      body ? "#{yaml}---\n\n#{body}\n" : "#{yaml}---\n"
    end

    def issue_run_summary(issue_dir)
      slug = File.basename(issue_dir)
      issue = read_issue(issue_dir)
      title = issue ? issue[:title] : slug
      status = Dir.exist?(File.join(@walk_dir, "closed", slug)) ? "closed" : "open"
      driver_blocked = File.exist?(File.join(issue_dir, "blocked_by_driver"))

      runs_dir = File.join(issue_dir, "runs")
      run_count = 0
      total_duration = 0.0
      cost_usd = 0.0
      success_runs = 0
      failure_runs = 0
      last_exit_code = nil
      # Track consecutive trailing failures for retry breakdown
      consecutive_failures = 0
      exit_codes = []

      if Dir.exist?(runs_dir)
        Dir.children(runs_dir).sort.each do |ts_dir|
          meta_file = File.join(runs_dir, ts_dir, "meta.json")
          next unless File.exist?(meta_file)

          run_count += 1
          begin
            meta = JSON.parse(File.read(meta_file))
            exit_code = meta["exit_code"]
            last_exit_code = exit_code
            exit_codes << exit_code

            if exit_code == 0
              success_runs += 1
            else
              failure_runs += 1
            end

            if meta["started_at"] && meta["finished_at"]
              started = Time.parse(meta["started_at"])
              finished = Time.parse(meta["finished_at"])
              total_duration += (finished - started)
            end

            cost_usd += meta["cost_usd"] if meta["cost_usd"]
          rescue JSON::ParserError, ArgumentError
            failure_runs += 1
            exit_codes << -1
          end
        end
      end

      # Count consecutive trailing failures
      exit_codes.reverse_each do |code|
        break if code == 0

        consecutive_failures += 1
      end

      result_excerpt = nil
      result_file = File.join(issue_dir, "result.md")
      if File.exist?(result_file)
        first_line = File.read(result_file).lines.first&.strip
        result_excerpt = first_line unless first_line.to_s.empty?
      end

      {
        slug: slug,
        title: title,
        status: status,
        run_count: run_count,
        total_duration: total_duration,
        cost_usd: cost_usd.positive? ? cost_usd.round(2) : nil,
        success_runs: success_runs,
        failure_runs: failure_runs,
        consecutive_failures: consecutive_failures,
        last_exit_code: last_exit_code,
        result_excerpt: result_excerpt,
        driver_blocked: driver_blocked
      }
    end

    # Convert string-keyed config hash to symbols, filtering to known keys.
    def symbolize_config(hash)
      known_keys = %w[max_turns spawn_mode sleep_interval model claude_md_path close_protocol preamble max_concurrent]
      result = {}
      hash.each do |k, v|
        next unless known_keys.include?(k.to_s)

        key = k.to_sym
        result[key] = case key
                      when :spawn_mode, :close_protocol then v.to_s.to_sym
                      when :max_turns, :sleep_interval, :max_concurrent then v.to_i
                      else v.to_s
                      end
      end
      result
    end

    def close_issue_with_status(slug, reason:, status: "closed")
      with_walk_lock do
        issue_dir = File.join(@walk_dir, "open", slug)
        unless Dir.exist?(issue_dir)
          $stderr.puts "Error: issue '#{slug}' not found in open/"
          return nil
        end

        case status
        when "closed"
          closed_dir = File.join(@walk_dir, "closed")
          dest = File.join(closed_dir, slug)
          FileUtils.mkdir_p(closed_dir)
          FileUtils.mv(issue_dir, dest)

          # Remove .next file if present (used to bump issue priority)
          next_file = File.join(dest, ".next")
          FileUtils.rm_f(next_file)

          epoch = current_epoch
          epoch = 1 if epoch == 0  # First closure is epoch 1

          File.write(File.join(dest, "close.yaml"), YAML.dump(
            "status" => status,
            "reason" => reason,
            "closed_at" => Time.now.iso8601,
            "epoch" => epoch
          ))

          File.write(File.join(dest, "result.md"), "#{reason}\n")

          File.write(File.join(dest, "close.md"),
                     yaml_frontmatter("closed_at" => Time.now.iso8601, "reason" => reason))

          # Record in temporal epoch directory
          record_closure_in_epoch(slug, epoch)

          { slug: slug, status: status, reason: reason, dir: dest, epoch: epoch }
        when "blocked", "deferred"
          File.write(File.join(issue_dir, "close.yaml"), YAML.dump(
            "status" => status,
            "reason" => reason,
            "marked_at" => Time.now.iso8601
          ))
          { slug: slug, status: status, reason: reason, dir: issue_dir }
        else
          $stderr.puts "Error: unknown status '#{status}'. Use: closed, blocked, deferred"
          nil
        end
      end
    end

    def blocked?(issue_dir)
      # Check driver-level block (retry policy exhausted)
      return true if File.exist?(File.join(issue_dir, "blocked_by_driver"))

      # Check dependency-based blocks (symlinks to other issues)
      blocked_dir = File.join(issue_dir, "blocked_by")
      return false unless Dir.exist?(blocked_dir)

      Dir.children(blocked_dir).any? { |entry|
        path = File.join(blocked_dir, entry)
        File.symlink?(path) && File.exist?(path)
      }
    end

    def find_issue_dir(slug)
      %w[open closed].each do |subdir|
        dir_path = File.join(@walk_dir, subdir, slug)
        return dir_path if Dir.exist?(dir_path)
      end
      nil
    end

    def read_closed_issue(dir_path)
      issue = read_issue(dir_path)
      return nil unless issue

      result_file = File.join(dir_path, "result.md")
      issue[:result] = File.exist?(result_file) ? File.read(result_file).strip : nil

      close_yaml = File.join(dir_path, "close.yaml")
      close_md = File.join(dir_path, "close.md")

      if File.exist?(close_yaml)
        close_meta = YAML.safe_load(File.read(close_yaml), permitted_classes: [Time]) || {}
        issue[:closed_at] = close_meta["closed_at"]
        issue[:close_reason] = close_meta["reason"]
        issue[:close_status] = close_meta["status"] || "closed"
      elsif File.exist?(close_md)
        close_content = File.read(close_md)
        if close_content =~ /\A---\n(.*?\n)---/m
          close_meta = YAML.safe_load(Regexp.last_match(1), permitted_classes: [Time]) || {}
          issue[:closed_at] = close_meta["closed_at"]
          issue[:close_reason] = close_meta["reason"]
          issue[:close_status] = "closed"
        end
      end

      comments_file = File.join(dir_path, "comments.md")
      if File.exist?(comments_file)
        comments = File.read(comments_file)
        issue[:comments] = comments.length > 2000 ? comments[-2000..] : comments
      end

      issue
    end

    def parse_frontmatter_file(path)
      content = File.read(path)
      if content =~ /\A---\n(.*?\n)---\n(.*)\z/m
        frontmatter = YAML.safe_load(Regexp.last_match(1)) || {}
        body = Regexp.last_match(2).strip
      else
        frontmatter = {}
        body = content.strip
      end
      { frontmatter: frontmatter, title: frontmatter["title"], status: frontmatter["status"], body: body }
    end

    public  # Tree views are part of public API

    # --- Tree views ---

    # Build discovery tree: parent -> children it spawned.
    # Returns { roots: [...], children: { slug => [child_slugs] }, issues: { slug => issue } }
    def build_discovery_tree(include_closed: false)
      issues = {}
      parent_of = {}  # child_slug => parent_slug

      # Collect all issues and their discovered_by parents
      subdirs = include_closed ? %w[open closed] : %w[open]
      subdirs.each do |subdir|
        dir = File.join(@walk_dir, subdir)
        next unless Dir.exist?(dir)

        Dir.glob(File.join(dir, "*")).each do |issue_dir|
          next unless Dir.exist?(issue_dir)

          issue = subdir == "closed" ? read_closed_issue(issue_dir) : read_issue(issue_dir)
          next unless issue

          slug = issue[:slug]
          issue[:status] = subdir
          issues[slug] = issue

          # Check discovered_by for parent
          discovered_by_dir = File.join(issue_dir, "discovered_by")
          if Dir.exist?(discovered_by_dir)
            Dir.children(discovered_by_dir).each do |entry|
              path = File.join(discovered_by_dir, entry)
              next unless File.symlink?(path)
              # entry is the parent slug
              parent_of[slug] = entry
              break  # assume single parent for tree structure
            end
          end
        end
      end

      # Invert to get children map
      children = Hash.new { |h, k| h[k] = [] }
      parent_of.each do |child, parent|
        children[parent] << child
      end

      # Sort children by slug for consistent output
      children.each_value(&:sort!)

      # Find roots (issues with no parent, or parent not in our set)
      roots = issues.keys.select { |slug| !parent_of[slug] || !issues[parent_of[slug]] }
      roots.sort!

      { roots: roots, children: children, issues: issues, parent_of: parent_of }
    end

    # Build blocking tree: shows what blocks what.
    # Returns { roots: [...], blocked_by: { slug => [blocker_slugs] }, issues: { slug => issue } }
    def build_blocking_tree(include_closed: false)
      issues = {}
      blocked_by = Hash.new { |h, k| h[k] = [] }

      subdirs = include_closed ? %w[open closed] : %w[open]
      subdirs.each do |subdir|
        dir = File.join(@walk_dir, subdir)
        next unless Dir.exist?(dir)

        Dir.glob(File.join(dir, "*")).each do |issue_dir|
          next unless Dir.exist?(issue_dir)

          issue = subdir == "closed" ? read_closed_issue(issue_dir) : read_issue(issue_dir)
          next unless issue

          slug = issue[:slug]
          issue[:status] = subdir
          issues[slug] = issue

          # Check blocked_by
          blocked_by_dir = File.join(issue_dir, "blocked_by")
          if Dir.exist?(blocked_by_dir)
            Dir.children(blocked_by_dir).each do |entry|
              path = File.join(blocked_by_dir, entry)
              next unless File.symlink?(path)
              blocked_by[slug] << entry
            end
          end
        end
      end

      blocked_by.each_value(&:sort!)

      # Roots are issues that aren't blocked by anything
      roots = issues.keys.select { |slug| blocked_by[slug].empty? }
      roots.sort!

      { roots: roots, blocked_by: blocked_by, issues: issues }
    end

    # Render discovery tree as text.
    def render_discovery_tree(tree, root: nil, prefix: "", is_last: true, output: [])
      roots = root ? [root] : tree[:roots]

      roots.each_with_index do |slug, idx|
        issue = tree[:issues][slug]
        next unless issue

        is_last_root = (idx == roots.length - 1)
        connector = root ? (is_last ? "└── " : "├── ") : ""
        status_mark = issue[:status] == "closed" ? "✓" : "○"
        close_reason = issue[:close_reason] ? " — #{issue[:close_reason][0, 40]}" : ""

        output << "#{prefix}#{connector}#{status_mark} #{slug}: #{issue[:title][0, 50]}#{close_reason}"

        children = tree[:children][slug] || []
        children.each_with_index do |child_slug, cidx|
          child_is_last = (cidx == children.length - 1)
          child_prefix = prefix + (root ? (is_last ? "    " : "│   ") : "")
          render_discovery_tree(tree, root: child_slug, prefix: child_prefix,
                                is_last: child_is_last, output: output)
        end
      end

      output
    end

    # Render blocking tree as text (shows execution order).
    def render_blocking_tree(tree, output: [])
      # Show issues grouped by "depth" in blocking graph
      issues = tree[:issues]
      blocked_by = tree[:blocked_by]

      # Compute depths: issues with no blockers are depth 0
      depths = {}
      remaining = issues.keys.dup

      depth = 0
      while remaining.any?
        at_depth = remaining.select do |slug|
          blockers = blocked_by[slug]
          blockers.all? { |b| depths[b] }  # all blockers have depth assigned
        end

        break if at_depth.empty?  # cycle or orphan blockers

        at_depth.each { |slug| depths[slug] = depth }
        remaining -= at_depth
        depth += 1
      end

      # Assign remaining (cycles or missing blockers) to max depth
      remaining.each { |slug| depths[slug] = depth }

      # Group and render
      by_depth = issues.keys.group_by { |slug| depths[slug] || 0 }
      by_depth.keys.sort.each do |d|
        output << "=== Depth #{d} ==="
        by_depth[d].sort.each do |slug|
          issue = issues[slug]
          status_mark = issue[:status] == "closed" ? "✓" : "○"
          blockers = blocked_by[slug]
          blocker_str = blockers.any? ? " [blocked by: #{blockers.join(', ')}]" : ""
          output << "  #{status_mark} #{slug}: #{issue[:title][0, 50]}#{blocker_str}"
        end
        output << ""
      end

      output
    end

    # --- Temporal epochs (planning rounds) ---

    # Get current epoch number (0 if no epochs yet)
    def current_epoch
      current_link = File.join(@walk_dir, "epochs", "current")
      return 0 unless File.symlink?(current_link)
      File.basename(File.readlink(current_link)).to_i
    end

    # Increment epoch and return new value. Creates epochs/ dir if needed.
    # Uses dense numbering based on max existing epoch.
    def increment_epoch
      with_walk_lock do
        epochs_dir = File.join(@walk_dir, "epochs")
        FileUtils.mkdir_p(epochs_dir)

        # Find highest existing epoch (dense numbering)
        existing = Dir.children(epochs_dir)
          .select { |e| e =~ /^\d+$/ && Dir.exist?(File.join(epochs_dir, e)) }
          .map(&:to_i)
        new_epoch = (existing.max || 0) + 1

        epoch_dir = File.join(epochs_dir, new_epoch.to_s)
        FileUtils.mkdir_p(epoch_dir)

        # Update current symlink
        current_link = File.join(epochs_dir, "current")
        FileUtils.rm_f(current_link)
        File.symlink(new_epoch.to_s, current_link)

        new_epoch
      end
    end

    # Record that an issue was closed in a specific epoch.
    # Creates symlink: epochs/N/<slug> -> ../../closed/<slug>
    def record_closure_in_epoch(slug, epoch = nil)
      epoch ||= current_epoch
      epoch = increment_epoch if epoch == 0  # First closure triggers epoch 1

      epochs_dir = File.join(@walk_dir, "epochs")
      epoch_dir = File.join(epochs_dir, epoch.to_s)
      FileUtils.mkdir_p(epoch_dir)

      symlink_path = File.join(epoch_dir, slug)
      target = "../../closed/#{slug}"

      FileUtils.rm_f(symlink_path)  # Remove if exists (reclose case)
      File.symlink(target, symlink_path)
    end

    # List issues closed in a specific epoch.
    # Returns array of issue hashes (with :epoch field).
    def issues_in_epoch(epoch)
      epoch_dir = File.join(@walk_dir, "epochs", epoch.to_s)
      return [] unless Dir.exist?(epoch_dir)

      Dir.children(epoch_dir).filter_map do |entry|
        next if entry == "current"
        path = File.join(epoch_dir, entry)
        next unless File.symlink?(path)

        # Resolve to closed/ or open/ (if reopened)
        if File.exist?(path)
          issue_dir = File.realpath(path)
        else
          # Broken symlink - try open/
          open_dir = File.join(@walk_dir, "open", entry)
          issue_dir = File.exist?(open_dir) ? open_dir : nil
        end
        next unless issue_dir

        issue = issue_dir.include?("/closed/") ? read_closed_issue(issue_dir) : read_issue(issue_dir)
        issue[:epoch] = epoch if issue
        issue
      end.compact
    end

    # Get recently closed issues from the last N epochs.
    # Returns { epoch => [issues], ... } for non-empty epochs in window.
    def recent_closed_issues(window: 2)
      cur = current_epoch
      return {} if cur == 0

      start_epoch = [cur - window + 1, 1].max
      result = {}

      (start_epoch..cur).each do |e|
        issues = issues_in_epoch(e)
        result[e] = issues if issues.any?
      end

      result
    end

    # List all epoch numbers that exist.
    def list_epochs
      epochs_dir = File.join(@walk_dir, "epochs")
      return [] unless Dir.exist?(epochs_dir)

      Dir.children(epochs_dir)
        .select { |e| e =~ /^\d+$/ && Dir.exist?(File.join(epochs_dir, e)) }
        .map(&:to_i)
        .sort
    end
  end
end
