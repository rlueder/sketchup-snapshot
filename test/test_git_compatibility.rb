# frozen_string_literal: true

require_relative 'test_helper'

# The plugin writes git objects with Ruby and Zlib instead of running git, so
# the thing most worth proving is that a real git agrees with every byte.
#
# These tests need a git binary. The plugin does not — that is the whole point
# — so they skip rather than fail when there is none.
class TestGitCompatibility < Minitest::Test
  include SnapshotTestHelpers

  def test_blob_ids_match_git_hash_object
    require_git!

    with_model(content: "not really a skp\x00\xff binary".b) do |path|
      repo = init_repo(path)
      repo.snapshot!('one')

      expected = git!(repo.root, 'hash-object', '--', 'Model.skp')
      stored = repo.send(:tip_blob)

      assert_equal expected, stored, 'our blob id must be the one git computes'
      assert repo.store.exist?(stored), 'and the object must be on disk'
    end
  end

  def test_git_fsck_accepts_everything_we_write
    require_git!

    with_model(subdir: 'designs/house') do |path|
      repo = init_repo(path)
      repo.snapshot!('one')
      write(path, 'skp-v2')
      first = repo.history.last.sha
      repo.snapshot!('two')
      repo.create_variation!('Flat roof')
      write(path, 'skp-v3')
      repo.snapshot!('three')
      repo.restore!(first)

      assert_valid_repository(repo)
    end
  end

  def test_git_can_read_the_history_we_wrote
    require_git!

    with_model do |path|
      repo = init_repo(path)
      repo.snapshot!('first idea')
      write(path, 'skp-v2')
      repo.snapshot!('second idea')

      log = git!(repo.root, 'log', '--pretty=format:%s', 'refs/snapshots/Original')

      assert_equal ['second idea', 'first idea'], log.split("\n")
    end
  end

  def test_git_can_check_out_a_snapshot_we_wrote
    require_git!

    with_model do |path|
      repo = init_repo(path)
      repo.snapshot!('one')
      write(path, 'skp-v2')
      repo.snapshot!('two')

      # Somebody could recover an old model with nothing but git, which is the
      # promise made by storing real git objects rather than a private format.
      old = repo.history.last.sha
      content = git!(repo.root, 'cat-file', 'blob', "#{old}:Model.skp")

      assert_equal 'skp-v1', content
    end
  end

  def test_nested_trees_hash_the_way_git_hashes_them
    require_git!

    # Tree entry ordering is the easiest thing to get subtly wrong: git sorts
    # directories as though their name ended in a slash. A mismatch here would
    # give a different tree id for identical content.
    with_model(subdir: 'a/b c/d') do |path|
      repo = init_repo(path)
      repo.snapshot!('nested')

      ours = git!(repo.root, 'rev-parse', 'refs/snapshots/Original^{tree}')
      git!(repo.root, 'read-tree', ours)
      rebuilt = git!(repo.root, 'write-tree')

      assert_equal ours, rebuilt, 'git must round-trip our tree unchanged'
    end
  end

  def test_the_author_line_is_well_formed
    require_git!

    with_model do |path|
      repo = init_repo(path)
      repo.snapshot!('one')

      name = git!(repo.root, 'log', '-1', '--pretty=format:%an', 'refs/snapshots/Original')
      email = git!(repo.root, 'log', '-1', '--pretty=format:%ae', 'refs/snapshots/Original')

      refute_empty name
      assert_includes email, '@'
    end
  end

  def test_a_model_inside_someone_elses_repository_is_left_alone
    require_git!

    with_model(subdir: 'models') do |path|
      root = File.dirname(File.dirname(path))
      git!(root, 'init', '-b', 'main')
      git!(root, 'config', 'user.name', 'Someone')
      git!(root, 'config', 'user.email', 'someone@example.com')
      File.write(File.join(root, 'notes.txt'), 'their work')
      git!(root, 'add', '--', 'notes.txt')
      git!(root, 'commit', '-m', 'their commit')
      their_head = git!(root, 'rev-parse', 'HEAD')

      repo = Repo.discover(path)
      assert_equal root, repo.root
      repo.snapshot!('our snapshot')
      write(path, 'skp-v2')
      repo.snapshot!('another')

      # Their branch, their HEAD and their index must be exactly as they left
      # them: the plugin only ever adds refs under its own namespace.
      assert_equal their_head, git!(root, 'rev-parse', 'HEAD')
      assert_equal 'main', git!(root, 'rev-parse', '--abbrev-ref', 'HEAD')
      assert_equal '', git!(root, 'diff', '--cached', '--name-only')
      assert_valid_repository(repo)
    end
  end

  def test_history_survives_git_packing_the_objects
    require_git!

    with_model do |path|
      repo = init_repo(path)
      repo.snapshot!('one')
      write(path, 'skp-v2')
      repo.snapshot!('two')

      # Someone runs `git gc` by hand. Loose objects disappear into a packfile
      # and loose refs into packed-refs; the plugin falls back to the binary.
      git!(repo.root, 'gc', '--aggressive', '--prune=now')

      reopened = Repo.discover(path)
      assert_equal %w[two one], reopened.history.map(&:subject)
      assert_equal 'Original', reopened.current_variation
    end
  end
end

# Picking up history the plugin did not write itself.
class TestAdoptingExistingHistory < Minitest::Test
  include SnapshotTestHelpers

  def setup
    require_git!
  end

  def commit_model(root, path, content, message)
    write(path, content)
    git!(root, 'add', '--', File.basename(path))
    git!(root, 'commit', '-m', message)
  end

  def with_git_history
    with_model do |path|
      root = File.dirname(path)
      git!(root, 'init', '-b', 'main')
      git!(root, 'config', 'user.name', 'Someone')
      git!(root, 'config', 'user.email', 'someone@example.com')
      commit_model(root, path, 'skp-v1', 'their first')
      commit_model(root, path, 'skp-v2', 'their second')
      yield path, root
    end
  end

  def test_history_made_with_git_shows_up_in_the_panel
    with_git_history do |path, _root|
      repo = Repo.discover(path)

      assert_equal ['their second', 'their first'], repo.history.map(&:subject)
      refute repo.empty?
      refute repo.dirty?
    end
  end

  def test_our_first_snapshot_continues_from_their_history
    with_git_history do |path, root|
      repo = Repo.discover(path)
      their_head = git!(root, 'rev-parse', 'HEAD')

      write(path, 'skp-v3')
      repo.snapshot!('ours')

      assert_equal ['ours', 'their second', 'their first'], repo.history.map(&:subject)
      # Their branch stays exactly where it was.
      assert_equal their_head, git!(root, 'rev-parse', 'HEAD')
      assert_equal their_head, git!(root, 'rev-parse', 'refs/snapshots/Original~1')
      assert_valid_repository(repo)
    end
  end

  def test_a_repository_without_this_model_is_not_adopted
    with_model do |path|
      root = File.dirname(path)
      git!(root, 'init', '-b', 'main')
      git!(root, 'config', 'user.name', 'Someone')
      git!(root, 'config', 'user.email', 'someone@example.com')
      File.write(File.join(root, 'notes.txt'), 'unrelated')
      git!(root, 'add', '--', 'notes.txt')
      git!(root, 'commit', '-m', 'nothing to do with the model')

      repo = Repo.discover(path)

      assert repo.empty?, 'their history does not contain this model'
      assert_empty repo.history
    end
  end
end

class TestHidingKeepsTheRepositoryValid < Minitest::Test
  include SnapshotTestHelpers

  def test_a_hidden_snapshot_is_still_intact_in_git
    require_git!

    with_model do |path|
      repo = init_repo(path)
      repo.snapshot!('one')
      write(path, 'skp-v2')
      second = repo.snapshot!('two')
      write(path, 'skp-v3')
      repo.snapshot!('three')

      repo.hide_snapshot!(second)

      # Hiding must not orphan or rewrite anything: the commit chain is
      # untouched and the model is still recoverable from the hidden snapshot.
      assert_valid_repository(repo)
      log = git!(repo.root, 'log', '--pretty=format:%s', 'refs/snapshots/Original')
      assert_equal %w[three two one], log.split("\n")
      assert_equal 'skp-v2', git!(repo.root, 'cat-file', 'blob', "#{second}:Model.skp")
    end
  end
end
