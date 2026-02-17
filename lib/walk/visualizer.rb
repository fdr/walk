# frozen_string_literal: true

# lib/walk/visualizer.rb — Discovery chain ASCII/Unicode visualizer.
#
# Renders compact visualizations of epoch-annotated discovery DAGs
# and blocking relationships. Designed to be token-efficient for
# inclusion in planner context.

module Walk
  class Visualizer
    # Status glyphs per the issue spec
    GLYPH_CLOSED  = "\u25CB" # ○
    GLYPH_RUNNING = "\u25CF" # ●
    GLYPH_BLOCKED = "\u25CC" # ◌
    GLYPH_OPEN    = "\u25A1" # □

    def initialize(backend)
      @backend = backend
    end

    # Full epoch-chain visualization showing discovery DAG with epoch markers,
    # generativity scores, status glyphs, and convergence annotations.
    #
    # Returns array of strings (lines).
    def render_chain(include_closed: true)
      tree = @backend.build_discovery_tree(include_closed: include_closed)
      blocking = @backend.build_blocking_tree(include_closed: include_closed)
      issues = tree[:issues]
      children_map = tree[:children]
      parents_of = tree[:parents_of] || {}
      blocked_by = blocking[:blocked_by] || {}

      return ["(no issues)"] if issues.empty?

      # Compute generativity: number of children in discovery DAG
      generativity = Hash.new(0)
      parents_of.each do |_child, parents|
        parents.each { |p| generativity[p] += 1 }
      end

      # Compute epoch for each issue
      epoch_of = {}
      @backend.list_epochs.each do |e|
        @backend.issues_in_epoch(e).each do |issue|
          epoch_of[issue[:slug]] = e
        end
      end
      # Open issues: no epoch yet
      issues.each_key { |s| epoch_of[s] ||= nil }

      # Determine issue status for glyphs
      status_of = {}
      issues.each do |slug, issue|
        status_of[slug] = compute_status(slug, issue, blocked_by)
      end

      # Render the tree via DFS, tracking which epoch was last shown
      lines = []
      rendered = Set.new
      last_epoch_ref = [nil]  # Mutable ref shared across all roots

      tree[:roots].each_with_index do |root_slug, idx|
        is_last_root = (idx == tree[:roots].length - 1)
        render_node(
          root_slug, "", is_last_root, true,
          lines: lines, rendered: rendered, last_epoch_ref: last_epoch_ref,
          tree: tree, children_map: children_map, parents_of: parents_of,
          blocked_by: blocked_by, generativity: generativity,
          epoch_of: epoch_of, status_of: status_of, issues: issues
        )
      end

      lines
    end

    # Compact timeline showing epoch boundaries, issue counts, and date ranges.
    # Returns array of strings.
    def render_timeline
      epochs = @backend.list_epochs
      return ["(no epochs)"] if epochs.empty?

      lines = []
      total_closed = @backend.list_issues(status: "closed").size
      open_count = all_open_issues.size

      lines << "#{total_closed} closed, #{open_count} open across #{epochs.size} epoch(s)"
      lines << ""

      epochs.each do |e|
        issues = @backend.issues_in_epoch(e)
        slugs = issues.map { |i| i[:slug] }
        dates = issues.filter_map { |i| i[:closed_at] }.sort
        date_range = if dates.any?
          first = Time.parse(dates.first.to_s).strftime("%m-%d") rescue "?"
          last = Time.parse(dates.last.to_s).strftime("%m-%d") rescue "?"
          first == last ? first : "#{first}..#{last}"
        else
          "?"
        end

        lines << "E#{e} [#{date_range}] #{issues.size} issues: #{slugs.join(', ')}"
      end

      # Show open issues
      open = all_open_issues
      if open.any?
        lines << ""
        lines << "Open: #{open.map { |i| i[:slug] }.join(', ')}"
      end

      lines
    end

    private

    def all_open_issues
      # List all open issues (including blocked ones) by scanning the directory
      open_dir = File.join(@backend.walk_dir, "open")
      return [] unless Dir.exist?(open_dir)

      Dir.glob(File.join(open_dir, "*")).select { |d| Dir.exist?(d) }.filter_map do |d|
        @backend.read_issue(d)
      end.sort_by { |i| i[:slug] }
    end

    def compute_status(slug, issue, blocked_by)
      if issue[:status] == "closed"
        :closed
      elsif blocked_by[slug]&.any? { |b| !is_closed?(b) }
        :blocked
      else
        # Check if there's a running agent (runs dir with no finish)
        :open
      end
    end

    def is_closed?(slug)
      Dir.exist?(File.join(@backend.walk_dir, "closed", slug))
    end

    def status_glyph(status)
      case status
      when :closed  then GLYPH_CLOSED
      when :running then GLYPH_RUNNING
      when :blocked then GLYPH_BLOCKED
      when :open    then GLYPH_OPEN
      end
    end

    def render_node(slug, prefix, is_last, is_root,
                    lines:, rendered:, last_epoch_ref:,
                    tree:, children_map:, parents_of:,
                    blocked_by:, generativity:, epoch_of:,
                    status_of:, issues:)
      issue = issues[slug]
      return unless issue

      # Handle already-rendered nodes (DAG convergence)
      if rendered.include?(slug)
        connector = is_root ? "" : (is_last ? "\u2514 " : "\u251C ")
        lines << "#{prefix}#{connector}\u21B1 #{slug} (see above)"
        return
      end
      rendered.add(slug)

      # Epoch marker on left margin
      epoch = epoch_of[slug]
      epoch_str = ""
      if epoch && epoch != last_epoch_ref[0]
        epoch_str = "E#{epoch}"
        last_epoch_ref[0] = epoch
      end

      # Build the line
      connector = is_root ? "" : (is_last ? "\u2514 " : "\u251C ")
      glyph = status_glyph(status_of[slug])
      gen = generativity[slug]
      gen_str = gen > 0 ? " [#{gen}\u2192]" : ""

      # Check for meta/self-modify marker
      type = issue[:type]
      meta_str = type == "meta" ? " [self-mod]" : ""

      # Convergence annotation: show blockers beyond discovery parent
      discovery_parents = parents_of[slug] || []
      all_blockers = blocked_by[slug] || []
      # Extra blockers not in discovery parents
      extra_blockers = all_blockers.select { |b| !discovery_parents.include?(b) && issues[b] }
      convergence_str = extra_blockers.any? ? " [\u2190#{extra_blockers.join(',')}]" : ""

      # Pad epoch marker to 4 chars for alignment
      epoch_col = epoch_str.ljust(4)

      line = "#{epoch_col}#{prefix}#{connector}#{glyph} #{slug}#{gen_str}#{meta_str}#{convergence_str}"
      lines << line

      # Recurse into children
      children = children_map[slug] || []
      children.each_with_index do |child_slug, idx|
        child_is_last = (idx == children.length - 1)
        child_prefix = prefix + (is_root ? "" : (is_last ? "  " : "\u2502 "))
        render_node(
          child_slug, child_prefix, child_is_last, false,
          lines: lines, rendered: rendered, last_epoch_ref: last_epoch_ref,
          tree: tree, children_map: children_map, parents_of: parents_of,
          blocked_by: blocked_by, generativity: generativity,
          epoch_of: epoch_of, status_of: status_of, issues: issues
        )
      end
    end
  end
end
