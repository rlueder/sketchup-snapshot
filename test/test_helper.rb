# frozen_string_literal: true

# The version-control layer is free of SketchUp API calls, so it can be
# exercised under a plain Ruby. Since the plugin now writes git objects itself
# rather than shelling out, the tests do two things: drive the behaviour, and
# hand the result to a real git to confirm the bytes are actually valid.

require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'tmpdir'

$LOAD_PATH.unshift(File.expand_path('../src', __dir__))

# Loaded in the same order main.rb loads them, since the files no longer
# require each other.
require 'snapshot_vcs/log'
require 'snapshot_vcs/git'
require 'snapshot_vcs/object_store'
require 'snapshot_vcs/repo'

module SnapshotTestHelpers
  include SnapshotVCS

  # A throwaway folder containing a fake .skp file.
  def with_model(name: 'Model.skp', subdir: nil, content: 'skp-v1')
    Dir.mktmpdir('snapshot-test') do |dir|
      # macOS puts temp dirs under /var, a symlink to /private/var. Resolving
      # up front keeps expectations about paths honest.
      dir = File.realpath(dir)
      folder = subdir ? File.join(dir, subdir) : dir
      FileUtils.mkdir_p(folder)
      path = File.join(folder, name)
      File.binwrite(path, content)
      yield path
    end
  end

  def init_repo(path)
    Repo.init!(path)
  end

  def write(path, content)
    File.binwrite(path, content)
  end

  def read(path)
    File.binread(path)
  end

  # --- checking our work against the real thing ---------------------------

  def self.git_binary
    return @git_binary if defined?(@git_binary)

    @git_binary = SnapshotVCS::Git.new.available? ? SnapshotVCS::Git.new : nil
  end

  def real_git
    SnapshotTestHelpers.git_binary
  end

  # Tests that check git compatibility are pointless without a git to check
  # against, but the plugin itself must not need one — so they skip rather
  # than fail on a machine without it.
  def require_git!
    skip 'no git binary available to verify against' if real_git.nil?
  end

  # Run git in +dir+ and fail the test if it complains.
  def git!(dir, *argv)
    out, err, status = real_git.capture(*argv, chdir: dir)
    assert status.success?, "git #{argv.join(' ')} failed:\n#{err}#{out}"
    out.chomp
  end

  # The strongest check available: git's own integrity check over everything
  # this plugin wrote.
  def assert_valid_repository(repo)
    require_git!
    git!(repo.root, 'fsck', '--strict', '--no-progress')
  end
end
