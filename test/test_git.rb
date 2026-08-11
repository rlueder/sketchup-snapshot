# frozen_string_literal: true

require_relative 'test_helper'

# The plugin does not need a git binary any more — it writes objects itself.
# The Git class survives for one job: reading objects back when something has
# packed them away. These tests cover finding a binary and talking to it
# safely, and they skip when the machine has none, because that is a supported
# state rather than a broken one.
class TestGit < Minitest::Test
  include SnapshotTestHelpers

  def setup
    @git = SnapshotVCS::Git.new
  end

  def test_finds_a_git_binary_when_one_is_installed
    require_git!

    assert @git.available?
    assert @git.version_ok?
    assert_match(/\Agit version /, @git.version_string)
    assert_operator @git.version.first, :>=, 2
  end

  def test_a_missing_binary_is_reported_rather_than_raised
    missing = SnapshotVCS::Git.new(executable: '/nonexistent/git')

    refute missing.available?
    assert_includes missing.unavailable_reason, 'not found'
    # Nothing here may raise: absent git is normal now.
    assert_nil missing.try('status')
    refute missing.ok?('status')
  end

  def test_run_raises_with_git_stderr_attached
    require_git!

    with_model do |path|
      error = assert_raises(SnapshotVCS::GitError) do
        @git.run('rev-parse', '--show-toplevel', chdir: File.dirname(path))
      end

      refute_equal 0, error.exitstatus
      # What a user sees should come from git, not our wrapper.
      assert_includes error.user_message.downcase, 'not a git repository'
    end
  end

  def test_capture_raw_does_not_touch_the_bytes
    require_git!

    # #run tags output as UTF-8 and strips a trailing newline, either of which
    # would corrupt a blob. Object reads must go through capture_raw.
    content = "binary \x00\x01\xfe\xff ending in a newline\n".b

    with_model(content: content) do |path|
      repo = init_repo(path)
      repo.snapshot!('binary')

      blob = repo.send(:tip_blob)
      raw, status = @git.capture_raw('cat-file', 'blob', blob, chdir: repo.git_dir)

      assert status.success?
      assert_equal Encoding::ASCII_8BIT, raw.encoding
      assert_equal content, raw
    end
  end

  def test_arguments_are_never_passed_through_a_shell
    require_git!

    # A filename a shell would mangle proves we spawn git directly.
    with_model(name: "Weird ' \" $(x) & name.skp") do |path|
      repo = init_repo(path)
      repo.snapshot!('spaces and quotes')

      assert_valid_repository(repo)
      assert_equal 1, repo.history.length
    end
  end
end
