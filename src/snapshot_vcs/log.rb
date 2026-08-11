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

      def record(level, message)
        entry = "#{Time.now.strftime('%H:%M:%S')} #{level} #{message}"
        history << entry
        history.shift while history.length > MAX_HISTORY
        # Published extensions must not write to the console uninvited; this
        # only speaks when a developer has explicitly asked it to.
        puts "[Snapshot] #{level} #{message}" if verbose
        entry
      end
    end

    self.verbose = false
  end
end
