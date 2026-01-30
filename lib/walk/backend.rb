# frozen_string_literal: true

# lib/walk/backend.rb — Abstract base class for walk backends.
#
# Subclasses implement issue I/O against a concrete storage layer
# (directory-based, beads database, etc). The driver and CLI delegate
# all persistence through this interface.

module Walk
  class Backend
    # Returns an array of issue hashes ready to be worked on.
    # Options:
    #   parent: optional parent slug/id to scope the query
    def ready_issues(parent: nil)
      raise NotImplementedError, "#{self.class}#ready_issues"
    end

    # Returns a single issue hash, or nil if not found.
    def fetch_issue(id)
      raise NotImplementedError, "#{self.class}#fetch_issue"
    end

    # Closes an issue. Returns a result hash.
    def close_issue(id, reason:)
      raise NotImplementedError, "#{self.class}#close_issue"
    end

    # Adds a comment to an issue. Returns a result hash.
    def add_comment(id, text)
      raise NotImplementedError, "#{self.class}#add_comment"
    end

    # Creates a new issue. Returns an issue hash.
    def create_issue(title:, parent: nil, deps: nil, priority: 2, description: "")
      raise NotImplementedError, "#{self.class}#create_issue"
    end

    # Returns comments for an issue as a String, or nil.
    def fetch_comments(id)
      raise NotImplementedError, "#{self.class}#fetch_comments"
    end

    # Returns parent/epic context as a String, or nil.
    def load_parent_context(issue)
      raise NotImplementedError, "#{self.class}#load_parent_context"
    end
  end
end
