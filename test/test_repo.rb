# frozen_string_literal: true

require_relative 'test_helper'

class TestRepoSetup < Minitest::Test
  include SnapshotTestHelpers

  def test_discover_returns_nil_outside_a_repository
    with_model { |path| assert_nil SnapshotVCS::Repo.discover(path) }
  end

  def test_init_creates_a_usable_repository
    with_model do |path|
      repo = init_repo(path)

      assert repo.empty?
      assert_equal 'Original', repo.current_variation
      assert_equal File.dirname(path), repo.root
      assert_equal 'Model.skp', repo.relative_path
      assert File.directory?(File.join(repo.root, '.git', 'objects'))
    end
  end

  def test_init_on_an_existing_repository_reuses_it
    with_model do |path|
      first = init_repo(path)
      second = init_repo(path)

      assert_equal first.root, second.root
    end
  end

  def test_init_writes_support_files_without_clobbering_existing_ones
    with_model do |path|
      ignore = File.join(File.dirname(path), '.gitignore')
      File.write(ignore, "# mine\nsecret.txt\n")

      init_repo(path)

      contents = File.read(ignore)
      assert_includes contents, 'secret.txt', 'existing entries must survive'
      assert_includes contents, '*.skb'
      assert_includes File.read(File.join(File.dirname(path), '.gitattributes')), '*.skp binary'
    end
  end

  def test_support_files_are_not_duplicated_on_repeated_writes
    with_model do |path|
      repo = init_repo(path)
      3.times { repo.write_support_files! }

      lines = File.read(File.join(repo.root, '.gitignore')).scan('*.skb')
      assert_equal 1, lines.length
    end
  end

  def test_committing_works_without_any_git_configuration
    with_model do |path|
      repo = init_repo(path)

      # The plugin must never depend on the machine having git set up, so an
      # identity is always resolvable.
      refute_nil repo.snapshot!('first')
      refute_empty repo.history.first.author
    end
  end

  def test_discovers_a_model_in_a_subfolder_of_an_existing_repo
    with_model(subdir: 'designs/house') do |path|
      root = path.split('/designs').first
      FileUtils.mkdir_p(File.join(root, '.git', 'objects'))
      FileUtils.mkdir_p(File.join(root, '.git', 'refs'))
      File.write(File.join(root, '.git', 'HEAD'), "ref: refs/heads/main\n")

      repo = SnapshotVCS::Repo.discover(path)

      refute_nil repo
      assert_equal root, repo.root
      assert_equal 'designs/house/Model.skp', repo.relative_path
    end
  end

  def test_a_model_in_a_subfolder_snapshots_into_nested_trees
    with_model(subdir: 'designs/house') do |path|
      repo = init_repo(File.join(path.split('/designs').first, 'Root.skp'))
      File.binwrite(File.join(repo.root, 'Root.skp'), 'root model')

      nested = SnapshotVCS::Repo.discover(path)
      nested.snapshot!('nested one')

      assert_equal ['nested one'], nested.history.map(&:subject)
      assert_equal 'skp-v1', read(path)
    end
  end
end

class TestSnapshots < Minitest::Test
  include SnapshotTestHelpers

  def test_snapshot_records_the_file_and_clears_dirty
    with_model do |path|
      repo = init_repo(path)
      assert repo.dirty?, 'an untracked file counts as dirty'

      sha = repo.snapshot!('Initial massing')

      assert_equal 40, sha.length
      refute repo.dirty?
      assert repo.tracked?
      assert_equal ['Initial massing'], repo.history.map(&:subject)
    end
  end

  def test_snapshot_refuses_an_empty_description
    with_model do |path|
      repo = init_repo(path)
      assert_raises(ArgumentError) { repo.snapshot!('   ') }
    end
  end

  def test_snapshotting_an_unchanged_file_raises_nothing_to_snapshot
    with_model do |path|
      repo = init_repo(path)
      repo.snapshot!('first')

      assert_raises(SnapshotVCS::NothingToSnapshot) { repo.snapshot!('again') }
    end
  end

  def test_a_leading_hash_survives_the_commit_message
    with_model do |path|
      repo = init_repo(path)
      # git's default cleanup would treat this whole line as a comment and
      # reject the commit for having an empty message.
      repo.snapshot!('#3 attempt at the roof')

      assert_equal '#3 attempt at the roof', repo.history.first.subject
    end
  end

  def test_history_is_newest_first_and_marks_head
    with_model do |path|
      repo = init_repo(path)
      repo.snapshot!('one')
      write(path, 'skp-v2')
      repo.snapshot!('two')

      history = repo.history

      assert_equal %w[two one], history.map(&:subject)
      assert history.first.head?
      refute history.last.head?
    end
  end

  def test_history_carries_multi_line_detail
    with_model do |path|
      repo = init_repo(path)
      repo.snapshot!("Roof study\n\nTried a 30 degree pitch instead.")

      snap = repo.history.first
      assert_equal 'Roof study', snap.subject
      assert_includes snap.body, '30 degree pitch'
    end
  end

  def test_two_models_in_one_folder_keep_separate_histories
    with_model do |path|
      repo = init_repo(path)
      repo.snapshot!('mine')

      other_path = File.join(repo.root, 'Other.skp')
      write(other_path, 'other')
      other = SnapshotVCS::Repo.discover(other_path)
      other.snapshot!('someone else')

      assert_equal ['mine'], repo.history.map(&:subject)
      assert_equal ['someone else'], other.history.map(&:subject)
    end
  end

  def test_snapshotting_one_model_preserves_the_other_in_the_tree
    with_model do |path|
      repo = init_repo(path)
      repo.snapshot!('mine')

      other_path = File.join(repo.root, 'Other.skp')
      write(other_path, 'other')
      other = SnapshotVCS::Repo.discover(other_path)
      other.snapshot!('theirs')

      # Both files must survive in the tree; rebuilding it for one model must
      # not drop the other.
      write(path, 'skp-v2')
      repo.snapshot!('mine again')

      assert_equal 'other', read(other_path)
      refute_nil SnapshotVCS::Repo.discover(other_path).history.first
      assert_equal ['theirs'], SnapshotVCS::Repo.discover(other_path).history.map(&:subject)
    end
  end
end

class TestRestore < Minitest::Test
  include SnapshotTestHelpers

  def test_restore_switches_the_model_without_growing_the_history
    with_model do |path|
      repo = init_repo(path)
      first = repo.snapshot!('one')
      write(path, 'skp-v2')
      repo.snapshot!('two')

      restored = repo.restore!(first)

      assert_equal 'skp-v1', read(path)
      refute_nil restored
      # To the user this is "go to that version": the list is unchanged and
      # only the marker moves.
      assert_equal %w[two one], repo.history.map(&:subject)
      assert_equal 'one', repo.history.find(&:head?).subject
      refute repo.dirty?
    end
  end

  def test_the_state_left_behind_stays_reachable_in_git
    with_model do |path|
      repo = init_repo(path)
      first = repo.snapshot!('one')
      write(path, 'skp-v2')
      repo.snapshot!('two')
      repo.restore!(first)

      # The restore is a forward commit, so nothing was rewritten and the
      # bookkeeping is still there for anyone looking with git itself.
      require_git!
      log = git!(repo.root, 'log', '--pretty=format:%s', 'refs/snapshots/Original')
      assert_equal ['Restored: one', 'two', 'one'], log.split("\n")
    end
  end

  def test_jumping_around_repeatedly_does_not_clutter_the_history
    with_model do |path|
      repo = init_repo(path)
      first = repo.snapshot!('one')
      write(path, 'skp-v2')
      second = repo.snapshot!('two')

      repo.restore!(first)
      repo.restore!(second)
      repo.restore!(first)

      assert_equal %w[two one], repo.history.map(&:subject)
      assert_equal 'one', repo.history.find(&:head?).subject
      assert_equal 'skp-v1', read(path)
    end
  end

  def test_snapshotting_after_a_restore_continues_from_there
    with_model do |path|
      repo = init_repo(path)
      first = repo.snapshot!('one')
      write(path, 'skp-v2')
      repo.snapshot!('two')
      repo.restore!(first)

      write(path, 'skp-v3')
      repo.snapshot!('three')

      assert_equal %w[three two one], repo.history.map(&:subject)
      assert_equal 'three', repo.history.find(&:head?).subject
    end
  end

  def test_the_marker_moves_even_between_identical_snapshots
    with_model do |path|
      repo = init_repo(path)
      first = repo.snapshot!('one')
      write(path, 'skp-v2')
      repo.snapshot!('two')
      write(path, 'skp-v1')
      same = repo.snapshot!('back to the first shape by hand')

      repo.restore!(first)

      # 'one' and 'same' hold identical bytes, so nothing on disk changes —
      # but the user asked for 'one' and that is what should be marked.
      refute_nil same
      assert_equal 'one', repo.history.find(&:head?).subject
    end
  end

  def test_restore_leaves_you_on_the_same_option
    with_model do |path|
      repo = init_repo(path)
      first = repo.snapshot!('one')
      write(path, 'skp-v2')
      repo.snapshot!('two')

      repo.restore!(first)

      assert_equal 'Original', repo.current_variation
      assert_equal first, repo.current_snapshot_sha
    end
  end

  def test_restoring_the_snapshot_already_shown_is_a_no_op
    with_model do |path|
      repo = init_repo(path)
      head = repo.snapshot!('one')

      assert_nil repo.restore!(head)
      assert_equal 1, repo.history.length
      assert_equal head, repo.head_sha, 'no bookkeeping commit should be written'
    end
  end

  def test_restore_rejects_a_snapshot_without_this_file
    with_model do |path|
      repo = init_repo(path)

      # A commit made for a different model in the same folder. Restoring from
      # it would have nothing to put back.
      other_path = File.join(repo.root, 'Other.skp')
      write(other_path, 'x')
      other = SnapshotVCS::Repo.discover(other_path)
      before_model = other.snapshot!('other only')

      repo.snapshot!('base')

      error = assert_raises(SnapshotVCS::RepoError) { repo.restore!(before_model) }
      assert_includes error.message, 'does not contain this file'
      assert_equal 'skp-v1', read(path), 'the model must be left untouched'
    end
  end
end

class TestOptions < Minitest::Test
  include SnapshotTestHelpers

  def test_slugify_makes_typed_names_usable_as_branches
    assert_equal 'Option-B', SnapshotVCS::Repo.slugify('Option B')
    assert_equal 'roof-study', SnapshotVCS::Repo.slugify('  roof   study  ')
    assert_equal 'a-b', SnapshotVCS::Repo.slugify('a..b')
    assert_equal 'plan', SnapshotVCS::Repo.slugify('--plan--')
    assert_equal '', SnapshotVCS::Repo.slugify('   ')
  end

  def test_the_starting_line_of_work_is_not_shown_as_a_git_branch_name
    with_model do |path|
      repo = init_repo(path)
      repo.snapshot!('base')

      # "main" means nothing to an architect.
      assert_equal 'Original', repo.current_variation
      assert_equal 'Original', repo.variations.find(&:current?).label
      assert_equal ['Original'], repo.variations.map(&:name)
    end
  end

  def test_create_option_keeps_the_typed_name_as_a_label
    with_model do |path|
      repo = init_repo(path)
      repo.snapshot!('base')

      slug = repo.create_variation!('Option B')

      assert_equal 'Option-B', slug
      assert_equal 'Option B', repo.variation_label(slug)
      assert_equal 'Option-B', repo.current_variation
    end
  end

  def test_create_option_rejects_duplicates_and_empty_names
    with_model do |path|
      repo = init_repo(path)
      repo.snapshot!('base')
      repo.create_variation!('Option B')

      assert_raises(SnapshotVCS::InvalidVariationName) { repo.create_variation!('Option B') }
      assert_raises(SnapshotVCS::InvalidVariationName) { repo.create_variation!('   ') }
    end
  end

  def test_create_option_requires_a_first_snapshot
    with_model do |path|
      repo = init_repo(path)
      assert_raises(SnapshotVCS::InvalidVariationName) { repo.create_variation!('Option B') }
    end
  end

  def test_options_diverge_and_switching_swaps_the_file
    with_model do |path|
      repo = init_repo(path)
      repo.snapshot!('base')

      repo.create_variation!('Option B')
      write(path, 'skp-optionB')
      repo.snapshot!('curved facade')

      changed = repo.switch_variation!('Original')
      assert changed, 'the model file differs between options, so a reload is needed'
      assert_equal 'skp-v1', read(path)

      repo.switch_variation!('Option-B')
      assert_equal 'skp-optionB', read(path)

      # Each option keeps its own history.
      assert_equal ['curved facade', 'base'], repo.history.map(&:subject)
    end
  end

  def test_switching_reports_no_change_when_the_model_is_identical
    with_model do |path|
      repo = init_repo(path)
      repo.snapshot!('base')
      repo.create_variation!('Option B')

      refute repo.switch_variation!('Original'), 'identical content should not force a reload'
    end
  end

  def test_options_lists_the_current_one
    with_model do |path|
      repo = init_repo(path)
      repo.snapshot!('base')
      repo.create_variation!('Option B')

      current = repo.variations.find(&:current?)

      assert_equal 'Option-B', current.name
      assert_equal 'Option B', current.label
      assert_equal %w[Option-B Original].sort, repo.variations.map(&:name).sort
    end
  end

  def test_switching_to_an_unknown_option_is_rejected
    with_model do |path|
      repo = init_repo(path)
      repo.snapshot!('base')

      assert_raises(SnapshotVCS::InvalidVariationName) { repo.switch_variation!('nope') }
    end
  end

  def test_switching_is_refused_when_the_option_has_no_model_file
    with_model do |path|
      repo = init_repo(path)

      # An option created from a different model's history, which therefore
      # has no version of this one to open.
      other_path = File.join(repo.root, 'Other.skp')
      write(other_path, 'x')
      other = SnapshotVCS::Repo.discover(other_path)
      other.snapshot!('other only')
      other.create_variation!('Theirs')
      other.switch_variation!('Original')

      # Only now does this model get a history, so "Theirs" never saw it.
      repo.snapshot!('base')

      error = assert_raises(SnapshotVCS::RepoError) { repo.switch_variation!('Theirs') }
      assert_includes error.message, "doesn't contain this model file"
    end
  end
end

# The point of writing git objects in Ruby is that the plugin works on a
# machine with no git at all. These tests hand it a binary that cannot exist,
# so any code path that quietly shells out will blow up here.
class TestWithoutAnyGit < Minitest::Test
  include SnapshotTestHelpers

  def no_git
    SnapshotVCS::Git.new(executable: '/nonexistent/git')
  end

  def test_the_whole_flow_works_with_no_git_binary
    with_model do |path|
      repo = SnapshotVCS::Repo.init!(path, git: no_git)

      first = repo.snapshot!('one')
      write(path, 'skp-v2')
      repo.snapshot!('two')

      assert_equal %w[two one], repo.history.map(&:subject)
      refute repo.dirty?

      repo.create_variation!('Flat roof')
      write(path, 'skp-flat')
      repo.snapshot!('flat')
      assert_equal %w[Flat-roof Original].sort, repo.variations.map(&:name).sort

      assert repo.switch_variation!('Original')
      assert_equal 'skp-v2', read(path)

      repo.restore!(first)
      assert_equal 'skp-v1', read(path)
      assert_equal 'one', repo.history.find(&:head?).subject
    end
  end

  def test_reopening_the_repository_without_git_sees_the_same_history
    with_model do |path|
      repo = SnapshotVCS::Repo.init!(path, git: no_git)
      repo.snapshot!('one')
      write(path, 'skp-v2')
      repo.snapshot!('two')

      reopened = SnapshotVCS::Repo.discover(path, git: no_git)

      assert_equal %w[two one], reopened.history.map(&:subject)
      assert_equal 'Original', reopened.current_variation
    end
  end

  def test_a_large_model_is_hashed_and_stored_without_git
    with_model(content: 'x' * (3 * 1024 * 1024)) do |path|
      repo = SnapshotVCS::Repo.init!(path, git: no_git)
      repo.snapshot!('big')

      write(path, 'y' * (3 * 1024 * 1024))
      assert repo.dirty?
      repo.snapshot!('bigger')

      repo.restore!(repo.history.last.sha)
      assert_equal 'x' * (3 * 1024 * 1024), read(path)
    end
  end
end

# Regression: the stat cache must never report a modified file as clean.
class TestStatCache < Minitest::Test
  include SnapshotTestHelpers

  def test_a_same_size_edit_in_the_same_second_is_still_noticed
    with_model(content: 'a' * 4096) do |path|
      repo = init_repo(path)
      repo.snapshot!('one')
      refute repo.dirty?

      # Same length, written immediately: on a filesystem with coarse
      # timestamps this is indistinguishable from the snapshotted file by
      # size and mtime alone.
      write(path, 'b' * 4096)

      assert repo.dirty?, 'an edit must never be cached away as clean'
    end
  end

  def test_the_cache_still_avoids_rehashing_an_untouched_file
    with_model do |path|
      repo = init_repo(path)
      repo.snapshot!('one')

      # Age the entry past the racy window so the fast path is in play.
      cache = repo.send(:stat_cache)
      cache[repo.relative_path]['at'] = Time.now.to_f + 10
      repo.send(:write_meta_json, 'stat.json', cache)

      calls = 0
      repo.define_singleton_method(:hash_working_file) do
        calls += 1
        super()
      end

      3.times { refute repo.dirty? }
      assert_equal 0, calls, 'an untouched file should not be hashed again'
    end
  end
end

class TestHidingSnapshots < Minitest::Test
  include SnapshotTestHelpers

  def three_snapshots(path)
    repo = init_repo(path)
    first = repo.snapshot!('one')
    write(path, 'skp-v2')
    second = repo.snapshot!('two')
    write(path, 'skp-v3')
    repo.snapshot!('three')
    [repo, first, second]
  end

  def test_hiding_takes_a_snapshot_out_of_the_list
    with_model do |path|
      repo, _first, second = three_snapshots(path)

      assert repo.hide_snapshot!(second)

      assert_equal %w[three one], repo.history.map(&:subject)
    end
  end

  def test_hiding_leaves_the_rest_of_the_list_intact
    with_model do |path|
      repo, first, second = three_snapshots(path)
      repo.hide_snapshot!(second)

      # The snapshot before the hidden one must still be reachable and usable.
      repo.restore!(first)

      assert_equal 'skp-v1', read(path)
      assert_equal 'one', repo.history.find(&:head?).subject
    end
  end

  def test_hiding_is_remembered_across_reopening
    with_model do |path|
      repo, _first, second = three_snapshots(path)
      repo.hide_snapshot!(second)

      assert_equal %w[three one], SnapshotVCS::Repo.discover(path).history.map(&:subject)
    end
  end

  def test_hiding_is_reversible_because_nothing_is_destroyed
    with_model do |path|
      repo, _first, second = three_snapshots(path)
      repo.hide_snapshot!(second)

      assert repo.unhide_snapshot!(second)
      assert_equal %w[three two one], repo.history.map(&:subject)
    end
  end

  def test_hiding_the_same_snapshot_twice_is_harmless
    with_model do |path|
      repo, _first, second = three_snapshots(path)

      assert repo.hide_snapshot!(second)
      refute repo.hide_snapshot!(second)
      assert_equal 1, repo.hidden_shas.length
    end
  end

  def test_the_version_being_shown_cannot_be_hidden
    with_model do |path|
      repo, first, = three_snapshots(path)
      repo.restore!(first)

      error = assert_raises(SnapshotVCS::RepoError) { repo.hide_snapshot!(first) }
      assert_includes error.message, 'looking at right now'
      assert_equal 'one', repo.history.find(&:head?).subject
    end
  end

  def test_the_newest_snapshot_cannot_be_hidden_while_it_is_current
    with_model do |path|
      repo, = three_snapshots(path)
      newest = repo.history.first.sha

      assert_raises(SnapshotVCS::RepoError) { repo.hide_snapshot!(newest) }
    end
  end

  def test_hiding_an_unknown_snapshot_is_reported
    with_model do |path|
      repo = init_repo(path)
      repo.snapshot!('one')

      assert_raises(SnapshotVCS::RepoError) { repo.hide_snapshot!('0' * 40) }
    end
  end

  def test_snapshotting_still_works_after_hiding
    with_model do |path|
      repo, _first, second = three_snapshots(path)
      repo.hide_snapshot!(second)

      write(path, 'skp-v4')
      repo.snapshot!('four')

      assert_equal %w[four three one], repo.history.map(&:subject)
    end
  end
end

class TestRenamingSnapshots < Minitest::Test
  include SnapshotTestHelpers

  def test_renaming_replaces_the_description_in_the_list
    with_model do |path|
      repo = init_repo(path)
      sha = repo.snapshot!('Frist draft')

      assert repo.rename_snapshot!(sha, 'First draft')
      assert_equal ['First draft'], repo.history.map(&:subject)
    end
  end

  def test_renaming_does_not_touch_the_commit
    with_model do |path|
      repo = init_repo(path)
      sha = repo.snapshot!('Frist draft')
      repo.rename_snapshot!(sha, 'First draft')

      # The id must not move: restores point at these, and rewriting the
      # message would change them.
      assert_equal sha, repo.history.first.sha
      assert_equal 'Frist draft', repo.send(:load_commit, sha).message.split("\n").first
    end
  end

  def test_renaming_back_to_the_original_drops_the_override
    with_model do |path|
      repo = init_repo(path)
      sha = repo.snapshot!('Frist draft')
      repo.rename_snapshot!(sha, 'First draft')

      assert repo.rename_snapshot!(sha, 'Frist draft')
      assert_empty repo.snapshot_labels
      assert_equal ['Frist draft'], repo.history.map(&:subject)
    end
  end

  def test_renaming_survives_reopening
    with_model do |path|
      repo = init_repo(path)
      sha = repo.snapshot!('Frist draft')
      repo.rename_snapshot!(sha, 'First draft')

      assert_equal ['First draft'], SnapshotVCS::Repo.discover(path).history.map(&:subject)
    end
  end

  def test_an_empty_description_is_refused
    with_model do |path|
      repo = init_repo(path)
      sha = repo.snapshot!('one')

      assert_raises(ArgumentError) { repo.rename_snapshot!(sha, '  ') }
    end
  end

  def test_the_detail_lines_are_kept_when_the_subject_is_renamed
    with_model do |path|
      repo = init_repo(path)
      sha = repo.snapshot!("Roof study\n\nTried a 30 degree pitch.")
      repo.rename_snapshot!(sha, 'Roof, take two')

      snap = repo.history.first
      assert_equal 'Roof, take two', snap.subject
      assert_includes snap.body, '30 degree pitch'
    end
  end
end
