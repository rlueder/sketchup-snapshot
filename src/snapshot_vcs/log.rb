# frozen_string_literal: true

module SnapshotVCS
  # Minimal logging to the Ruby Console.
  #
  # Quiet by default so the console stays usable; turn it on from the console
  # with `SnapshotVCS::Log.verbose = true` when diagnosing a problem, then read
  # `SnapshotVCS::Log.history` for the last few entries.
  module Log
    MAX_HISTORY = 200

    class << self
      attr_accessor :verbose

      def history
        @history ||= []
      end

      def info(message)
        record('INFO', message)
      end

      def error(message)
        record('ERROR', message)
      end

      # For code that runs on every UI tick (menu validation, preference
      # reads): a failure there is recorded the first time it is seen, so it
      # leaves a trace without pushing everything else out of the history.
      def error_once(message)
        return nil if reported.include?(message)

        reported << message
        reported.shift while reported.length > MAX_HISTORY
        error(message)
      end

      def reported
        @reported ||= []
      end

      def record(level, message)
        entry = "#{Time.now.strftime('%H:%M:%S')} #{level} #{message}"
        history << entry
        history.shift while history.length > MAX_HISTORY
        # Published extensions must not write to the console uninvited; this
        # only speaks when a developer has explicitly asked it to.
        puts "[Snapshots] #{level} #{message}" if verbose
        entry
      end
    end

    self.verbose = false
  end
end
