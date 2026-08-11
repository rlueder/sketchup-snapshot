# frozen_string_literal: true

require 'open3'
require 'rbconfig'

module SnapshotVCS
  # Raised for any git invocation that exits non-zero.
  class GitError < StandardError
    attr_reader :argv, :exitstatus, :out, :err

    def initialize(message, argv: [], exitstatus: nil, out: '', err: '')
      super(message)
      @argv = argv
      @exitstatus = exitstatus
      @out = out
      @err = err
    end

    # Best line to show a human: git's own stderr beats our generic wrapper.
    def user_message
      text = err.to_s.strip
      text = out.to_s.strip if text.empty?
      text.empty? ? message : text
    end
  end

  # No usable `git` binary on this machine.
  class GitMissing < GitError; end

  # Thin, dependency-free wrapper around the system git binary.
  #
  # Deliberately knows nothing about SketchUp so it can be exercised by the
  # test suite under a normal Ruby.
  class Git
    # SketchUp is a GUI app. On macOS, GUI apps are launched by launchd and
    # inherit a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin) rather than the
    # PATH from the user's shell profile, so a Homebrew git is invisible to a
    # bare `git` lookup. On Windows the installer usually does put git on PATH,
    # but per-user installs frequently do not. Both platforms therefore get an
    # explicit candidate list in addition to the PATH probe.
    WINDOWS = (File::ALT_SEPARATOR == '\\')

    MAC_CANDIDATES = [
      '/opt/homebrew/bin/git',      # Apple Silicon Homebrew
      '/usr/local/bin/git',         # Intel Homebrew, or a standalone installer
      '/opt/local/bin/git',         # MacPorts
      '/usr/bin/git',               # Xcode Command Line Tools shim
      '/Applications/Xcode.app/Contents/Developer/usr/bin/git'
    ].freeze

    # Minimum git we rely on. 2.5 predates every flag used here except
    # `init -b`, which has an explicit fallback.
    MINIMUM_VERSION = [2, 5, 0].freeze

    class << self
      # Process-wide default instance.
      def instance
        @instance ||= new
      end

      def reset!
        @instance = nil
      end
    end

    attr_reader :executable, :version_string

    # @param executable [String, nil] force a specific binary; nil to autodetect
    def initialize(executable: nil)
      @executable = executable
      @version_string = nil
      @probed = false
    end

    # True when a working git binary was found. Never raises.
    def available?
      probe!
      !@executable.nil?
    end

    # @return [Array<Integer>] e.g. [2, 53, 0]; [] when unavailable
    def version
      probe!
      return [] unless @version_string

      @version_string[/\d+(\.\d+)*/].to_s.split('.').map(&:to_i)
    end

    def version_ok?
      v = version
      return false if v.empty?

      (v <=> MINIMUM_VERSION) >= 0
    end

    # Human-readable reason the extension cannot run, or nil when all is well.
    def unavailable_reason
      return nil if available? && version_ok?

      if !available?
        if WINDOWS
          'Git was not found on this computer. Install Git for Windows from ' \
            'https://git-scm.com/download/win, then restart SketchUp.'
        else
          'Git was not found on this computer. Install the Xcode Command ' \
            "Line Tools by running `xcode-select --install` in Terminal (or " \
            'install Git from https://git-scm.com/download/mac), then ' \
            'restart SketchUp.'
        end
      else
        "Git #{@version_string} is too old. Snapshot needs at least " \
          "#{MINIMUM_VERSION.join('.')}."
      end
    end

    # Run git and return stdout on success.
    #
    # @param argv [Array<String>] arguments after the binary
    # @param chdir [String, nil] working directory
    # @raise [GitError] on a non-zero exit
    # @return [String] stdout, UTF-8, trailing newline stripped
    def run(*argv, chdir: nil)
      out, err, status = capture(*argv, chdir: chdir)
      unless status.success?
        raise GitError.new(
          "git #{argv.join(' ')} failed (exit #{status.exitstatus})",
          argv: argv, exitstatus: status.exitstatus, out: out, err: err
        )
      end
      out.chomp
    end

    # Like #run but returns nil instead of raising. For predicate-style calls
    # where a non-zero exit is an expected answer, not a failure.
    def try(*argv, chdir: nil)
      run(*argv, chdir: chdir)
    rescue GitError
      nil
    end

    # True when git exits zero. For `cat-file -e`, `check-ref-format`, etc.
    def ok?(*argv, chdir: nil)
      !try(*argv, chdir: chdir).nil?
    end

    # Capture stdout as raw bytes, for object content that is not text.
    #
    # #run and #capture tag stdout as UTF-8 and #run strips a trailing
    # newline, either of which would quietly corrupt a binary blob.
    #
    # @return [Array(String, Process::Status)] stdout in ASCII-8BIT
    def capture_raw(*argv, chdir: nil)
      probe!
      raise GitMissing.new(unavailable_reason || 'git not found') unless @executable

      opts = {}
      opts[:chdir] = chdir if chdir
      out, _err, status = Open3.capture3(child_env, @executable, *global_flags,
                                         *argv.map(&:to_s), **opts)
      [out.to_s.b, status]
    end

    # Raw three-value capture, no raising.
    # @return [Array(String, String, Process::Status)]
    def capture(*argv, chdir: nil)
      probe!
      raise GitMissing.new(unavailable_reason || 'git not found') unless @executable

      opts = {}
      opts[:chdir] = chdir if chdir

      out, err, status = Open3.capture3(child_env, @executable, *global_flags, *argv.map(&:to_s), **opts)
      [force_utf8(out), force_utf8(err), status]
    rescue Errno::ENOENT => e
      raise GitMissing.new("Could not run git: #{e.message}")
    end

    private

    # Flags applied to every invocation.
    #
    #   core.quotepath=false   keep non-ASCII paths readable instead of \303\251
    #   core.pager / --no-pager  never block waiting on a pager
    #   advice.detachedHead=false  we never show git's own advice text
    def global_flags
      [
        '--no-pager',
        '-c', 'core.quotepath=false',
        '-c', 'advice.detachedHead=false',
        '-c', 'color.ui=false'
      ]
    end

    def child_env
      {
        # Never let git block the SketchUp UI thread on a credential or
        # passphrase prompt. v1 is local-only, so there is nothing to prompt for.
        'GIT_TERMINAL_PROMPT' => '0',
        # nil unsets an inherited value. Setting these to an empty string would
        # instead have git try to execute a program with no name.
        'GIT_ASKPASS' => nil,
        'SSH_ASKPASS' => nil,
        # Do not take index.lock for read-only commands; keeps us from fighting
        # a git GUI the user may have open on the same folder.
        'GIT_OPTIONAL_LOCKS' => '0',
        # Stable, parseable English for git's own diagnostics.
        'LC_ALL' => 'C',
        'LANG' => 'C',
        # An editor must never open: every commit here passes -m.
        'GIT_EDITOR' => 'true',
        'EDITOR' => 'true'
      }
    end

    def force_utf8(str)
      return '' if str.nil?

      str.dup.force_encoding(Encoding::UTF_8)
    end

    def probe!
      return if @probed

      @probed = true
      candidates = @executable ? [@executable] : default_candidates
      @executable = nil

      candidates.each do |candidate|
        version = probe_version(candidate)
        next unless version

        @executable = candidate
        @version_string = version
        break
      end
    end

    def probe_version(candidate)
      out, _err, status = Open3.capture3(child_env, candidate, '--version')
      return nil unless status.success?

      text = force_utf8(out).strip
      # On macOS without Command Line Tools, /usr/bin/git is a shim that pops a
      # GUI installer and exits non-zero, so a zero exit here is meaningful.
      text.start_with?('git version') ? text : nil
    rescue StandardError
      nil
    end

    def default_candidates
      list = ['git'] # PATH first: respects a user's deliberate choice
      list.concat(WINDOWS ? windows_candidates : MAC_CANDIDATES)
      list.uniq
    end

    def windows_candidates
      roots = [
        ENV['ProgramFiles'],
        ENV['ProgramFiles(x86)'],
        ENV['ProgramW6432'],
        'C:/Program Files',
        'C:/Program Files (x86)'
      ].compact.map { |r| File.join(r.tr('\\', '/'), 'Git') }

      local = ENV['LOCALAPPDATA']
      roots << File.join(local.tr('\\', '/'), 'Programs', 'Git') if local

      roots.uniq.flat_map do |root|
        # cmd/git.exe is the wrapper meant for non-shell callers; bin/git.exe
        # is the MSYS build and can drag in a console window.
        [File.join(root, 'cmd', 'git.exe'), File.join(root, 'bin', 'git.exe')]
      end
    end
  end
end
