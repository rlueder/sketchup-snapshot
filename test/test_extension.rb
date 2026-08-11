# frozen_string_literal: true

# Drives the SketchUp-facing half of the plugin against the stub API: command
# wiring, the prompt flow, the save/close/reopen cycle, and the observers.

require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'

$LOAD_PATH.unshift(File.expand_path('stubs', __dir__))
$LOAD_PATH.unshift(File.expand_path('../src', __dir__))

require 'snapshot_vcs' # registers the extension, which loads everything else

class ExtensionTest < Minitest::Test
  include SnapshotVCS

  def setup
    SketchupStub.reset!
    @dir = File.realpath(Dir.mktmpdir('snapshot-ext'))
    @path = File.join(@dir, 'House.skp')
    File.binwrite(@path, 'skp-v1')

    model = Sketchup::Model.new(@path)
    Sketchup.active_model = model
    Observers.attach(model)
    Status.reset!
    # Preferences are process-global in the stub, so reset every one of them
    # or a test that flips a setting silently changes the next test's world.
    Settings.auto_snapshot = false
    Settings.confirm_delete = true
    Settings.show_toolbar = true
    Settings.panel_placed = false
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def model
    Sketchup.active_model
  end

  def repo
    Repo.discover(@path)
  end

  # Answer the "start keeping snapshots of…" confirmation.
  def accept_tracking
    SketchupStub.queue_messagebox(IDOK)
  end
end

class TestExtensionLoading < ExtensionTest
  def test_toolbar_and_menu_are_built
    toolbar = SnapshotVCS.instance_variable_get(:@toolbar)

    # One button, and all it does is show and hide the panel.
    refute_nil toolbar
    assert_equal 1, toolbar.items.length
    assert_equal ['Snapshots'], toolbar.items.map(&:title)
  end

  def test_toolbar_icons_exist_on_disk
    SnapshotVCS.instance_variable_get(:@toolbar).items.each do |command|
      assert File.exist?(command.small_icon), "missing icon #{command.small_icon}"
      assert File.exist?(command.large_icon), "missing icon #{command.large_icon}"
    end
  end

  def test_menu_has_the_full_command_set
    menu = UI.menu('Extensions')
    # add_submenu returns a fresh Menu, so assert on what the commands do
    # rather than on the stub's menu tree.
    refute_nil menu
    assert SnapshotVCS.respond_to?(:build_commands)
    commands = SnapshotVCS.build_commands
    assert_equal %i[snapshot history new_variation auto reveal].sort, commands.keys.sort
  end
end

class TestSnapshotCommand < ExtensionTest
  def test_first_snapshot_initialises_the_repository
    accept_tracking

    assert Commands.snapshot('Initial massing')

    assert_equal ['Initial massing'], repo.history.map(&:subject)
    assert_match(/Start keeping snapshots/, SketchupStub.prompts.first)
  end

  def test_declining_to_start_tracking_does_nothing
    SketchupStub.queue_messagebox(IDCANCEL)

    refute Commands.snapshot('nope')
    assert_nil repo
  end

  def test_unsaved_model_is_asked_to_be_saved_first
    Sketchup.active_model = Sketchup::Model.new('')
    SketchupStub.queue_messagebox(IDOK)

    refute Commands.snapshot('anything')

    assert_match(/hasn't been saved yet/, SketchupStub.prompts.first)
    assert_includes SketchupStub.status_texts, 'send_action:saveDocumentAs:'
  end

  def test_the_model_is_written_to_disk_before_being_snapshotted
    accept_tracking
    model.modified = true
    File.binwrite(@path, 'skp-edited') # stands in for SketchUp writing the file

    assert Commands.snapshot('edited')

    refute model.modified?, 'the model should have been saved'
    refute repo.dirty?
  end

  def test_snapshot_with_no_changes_reports_instead_of_failing
    accept_tracking
    Commands.snapshot('first')

    refute Commands.snapshot('again')
    assert_includes SketchupStub.status_texts, 'Nothing has changed since the last snapshot.'
  end

  def test_blank_description_is_rejected
    accept_tracking
    SketchupStub.queue_messagebox(:default)

    refute Commands.snapshot('   ')
  end

  def test_asking_for_a_description_opens_the_panel_rather_than_a_dialog
    # Every field lives in the panel now. The toolbar brings it up with the
    # right one focused instead of putting a native dialog on screen.
    refute Commands.snapshot

    assert Panel.visible?
    assert(Panel.dialog.scripts.any? { |js| js.include?('SnapshotUI.focus("message")') })
    assert_nil repo, 'nothing should be recorded just by asking'
  ensure
    Panel.close
  end
end

class TestRestoreCommand < ExtensionTest
  def setup
    super
    accept_tracking
    Commands.snapshot('one')
    @first = repo.head_sha
    File.binwrite(@path, 'skp-v2')
    Commands.snapshot('two')
  end

  def test_restore_rewrites_the_file_and_reopens_the_model
    assert Commands.restore(@first)
    SketchupStub.run_timers!

    assert_equal 'skp-v1', File.binread(@path)
    assert_equal [@path], SketchupStub.opened_files
    # Going back is presented as switching versions, not as a new event.
    assert_equal %w[two one], repo.history.map(&:subject)
    assert_equal 'one', repo.history.find(&:head?).subject
  end

  def test_restoring_a_snapshot_already_shown_does_not_reopen_anything
    Commands.restore(@first)
    SketchupStub.run_timers!
    SketchupStub.reset!

    assert Commands.restore(@first)
    SketchupStub.run_timers!

    assert_empty SketchupStub.opened_files
    assert_includes SketchupStub.status_texts, 'Already showing "one".'
  end

  def test_the_camera_is_carried_across_the_reload
    view = model.active_view
    view.camera.set([10, 20, 30], [1, 2, 3], [0, 0, 1])
    view.camera.fov = 52.0

    Commands.restore(@first)
    SketchupStub.run_timers!

    # Each .skp carries its own saved camera, so without this the user is
    # thrown to wherever the snapshot happened to be saved from.
    reopened = Sketchup.active_model.active_view.camera
    refute_same view.camera, reopened
    assert_equal [10, 20, 30], reopened.eye
    assert_equal [1, 2, 3], reopened.target
    assert_in_delta 52.0, reopened.fov, 0.001
  end

  def test_a_camera_that_cannot_be_read_does_not_break_the_restore
    def model.active_view
      raise 'no view here'
    end

    assert Commands.restore(@first)
    SketchupStub.run_timers!

    assert_equal 'skp-v1', File.binread(@path)
    assert_equal [@path], SketchupStub.opened_files
  end

  def test_restore_closes_the_model_before_reopening_it
    original = model
    Commands.restore(@first)
    SketchupStub.run_timers!

    assert original.closed, 'macOS will not re-read an already-open file'
    refute_same original, Sketchup.active_model
  end

  def test_pending_work_can_be_snapshotted_before_restoring
    model.modified = true
    File.binwrite(@path, 'skp-wip')
    SketchupStub.queue_messagebox(IDYES)

    assert Commands.restore(@first)
    SketchupStub.run_timers!

    subjects = repo.history.map(&:subject)
    assert_includes subjects, 'Before restoring "one"'
    assert_equal 'skp-v1', File.binread(@path)
  end

  def test_pending_work_can_be_discarded
    model.modified = true
    File.binwrite(@path, 'skp-wip')
    SketchupStub.queue_messagebox(IDNO)

    assert Commands.restore(@first)
    SketchupStub.run_timers!

    refute_includes repo.history.map(&:subject), 'Before restoring "one"'
    assert_equal 'skp-v1', File.binread(@path)
  end

  def test_cancelling_leaves_everything_alone
    model.modified = true
    SketchupStub.queue_messagebox(IDCANCEL)

    refute Commands.restore(@first)

    assert_equal 'skp-v2', File.binread(@path)
    assert_empty SketchupStub.opened_files
  end

  def test_restoring_an_unknown_snapshot_is_reported
    SketchupStub.queue_messagebox(IDOK)

    refute Commands.restore('0' * 40)
    assert(SketchupStub.prompts.any? { |text| text.include?('could not be found') })
  end
end

class TestVariationCommands < ExtensionTest
  def setup
    super
    accept_tracking
    Commands.snapshot('base')
  end

  def test_create_option_uses_the_typed_name_as_a_label
    assert Commands.create_variation('Option B')

    current = repo.variations.find(&:current?)
    assert_equal 'Option-B', current.name
    assert_equal 'Option B', current.label
  end

  def test_asking_for_a_variation_name_opens_the_panel
    refute Commands.create_variation

    assert Panel.visible?
    assert(Panel.dialog.scripts.any? { |js| js.include?('SnapshotUI.focus("variation")') })
    assert_equal ['Original'], repo.variations.map(&:name)
  ensure
    Panel.close
  end

  def test_the_panel_is_told_what_to_suggest_as_a_name
    assert_equal 'Variation A', Commands.state['suggested_variation']

    Commands.create_variation('Variation A')
    assert_equal 'Variation B', Commands.state['suggested_variation']
  end

  def test_switching_between_options_reopens_the_model
    Commands.create_variation('Option B')
    File.binwrite(@path, 'skp-optionB')
    Commands.snapshot('curved facade')

    assert Commands.switch_variation('Original')
    SketchupStub.run_timers!

    assert_equal 'skp-v1', File.binread(@path)
    assert_equal [@path], SketchupStub.opened_files
  end

  def test_switching_to_an_identical_option_skips_the_reload
    Commands.create_variation('Option B')

    assert Commands.switch_variation('Original')
    SketchupStub.run_timers!

    assert_empty SketchupStub.opened_files, 'nothing changed, so nothing to reopen'
  end

  def test_switching_requires_pending_work_to_be_snapshotted
    Commands.create_variation('Option B')
    File.binwrite(@path, 'skp-optionB')
    Commands.snapshot('curved facade')

    model.modified = true
    File.binwrite(@path, 'skp-wip')
    SketchupStub.queue_messagebox(IDOK)

    assert Commands.switch_variation('Original')
    SketchupStub.run_timers!

    assert(SketchupStub.prompts.any? { |text| text.include?('have to be snapshotted') })
  end

  def test_cancelling_the_switch_leaves_the_option_alone
    Commands.create_variation('Option B')
    model.modified = true
    File.binwrite(@path, 'skp-wip')
    SketchupStub.queue_messagebox(IDCANCEL)

    refute Commands.switch_variation('Original')
    assert_equal 'Option-B', repo.current_variation
  end
end

class TestAutoSnapshot < ExtensionTest
  def test_off_by_default
    refute Settings.auto_snapshot?
  end

  def test_saving_takes_a_snapshot_when_enabled
    accept_tracking
    Commands.snapshot('base')
    Settings.auto_snapshot = true

    model.modified = true
    File.binwrite(@path, 'skp-v2')
    model.save

    assert_equal 2, repo.history.length
    assert_match(/\ASaved /, repo.history.first.subject)
  end

  def test_an_explicit_snapshot_does_not_also_trigger_an_auto_snapshot
    accept_tracking
    Commands.snapshot('base')
    Settings.auto_snapshot = true

    model.modified = true
    File.binwrite(@path, 'skp-v2')
    Commands.snapshot('deliberate')

    # The save performed by Commands.snapshot must not race its own commit.
    assert_equal %w[deliberate base], repo.history.map(&:subject)
  end

  def test_auto_snapshot_never_creates_a_repository_on_its_own
    Settings.auto_snapshot = true
    model.modified = true
    model.save

    assert_nil repo
  end
end

class TestStatusIndicator < ExtensionTest
  def test_an_edited_model_is_dirty
    model.modified = true
    assert Status.dirty?
  end

  def test_an_untracked_model_invites_a_first_snapshot
    Status.reset!
    assert Status.dirty?, 'nothing is tracked yet, so there is a snapshot to take'
  end

  def test_a_freshly_snapshotted_model_is_clean
    accept_tracking
    Commands.snapshot('base')

    refute Status.dirty?
  end

  def test_the_indicator_notices_a_change_after_the_cache_expires
    accept_tracking
    Commands.snapshot('base')
    refute Status.dirty?

    File.binwrite(@path, 'changed outside SketchUp')
    Status.reset!

    assert Status.dirty?
  end
end

class TestPanelState < ExtensionTest
  def test_state_describes_an_untracked_model
    state = Commands.state

    assert state['ok']
    assert state['saved']
    refute state['tracked']
    assert_equal 'House.skp', state['model_name']
    assert_empty state['snapshots']
  end

  def test_state_describes_a_tracked_model
    accept_tracking
    Commands.snapshot('base')
    Commands.create_variation('Option B')

    state = Commands.state

    assert state['tracked']
    assert_equal 'Option-B', state['variation']
    assert_equal 'Option B', state['variation_label']
    refute state['dirty']
    assert_equal ['base'], state['snapshots'].map { |s| s['subject'] }
    assert_equal %w[Option-B Original].sort, state['variations'].map { |o| o['name'] }.sort
  end

  def test_state_is_serialisable_as_json
    accept_tracking
    Commands.snapshot('café ☕')

    require 'json'
    round_tripped = JSON.parse(JSON.generate(Commands.state))

    assert_equal 'café ☕', round_tripped['snapshots'].first['subject']
  end

  def test_refreshing_a_closed_panel_is_harmless
    refute Panel.visible?
    refute Panel.refresh
  end

  def test_reveal_folder_opens_the_repository_root
    accept_tracking
    Commands.snapshot('base')

    assert Commands.reveal_folder
    assert_equal ["file://#{@dir}"], SketchupStub.urls
  end
end

class TestDeleteCommand < ExtensionTest
  def setup
    super
    accept_tracking
    Commands.snapshot('one')
    @first = repo.history.first.sha
    File.binwrite(@path, 'skp-v2')
    Commands.snapshot('two')
  end

  def test_confirming_removes_it_from_the_list
    SketchupStub.queue_messagebox(IDOK)

    assert Commands.delete_snapshot(@first)

    assert_equal ['two'], repo.history.map(&:subject)
    assert(SketchupStub.prompts.any? { |text| text.include?('Remove "one"') })
  end

  def test_cancelling_keeps_it
    SketchupStub.queue_messagebox(IDCANCEL)

    refute Commands.delete_snapshot(@first)
    assert_equal %w[two one], repo.history.map(&:subject)
  end

  def test_the_confirmation_is_honest_about_what_removing_does
    SketchupStub.queue_messagebox(IDCANCEL)
    Commands.delete_snapshot(@first)

    prompt = SketchupStub.prompts.last
    assert_includes prompt, 'model is not affected'
    assert_includes prompt, 'stays on disk'
    assert_operator prompt.length, :<, 200, 'the confirmation should stay short'
  end

  def test_turning_the_confirmation_off_removes_without_asking
    Settings.confirm_delete = false

    assert Commands.delete_snapshot(@first)

    assert_equal ['two'], repo.history.map(&:subject)
    refute(SketchupStub.prompts.any? { |text| text.include?('Remove "one"') })
  end

  def test_the_version_being_shown_is_refused_with_an_explanation
    SketchupStub.queue_messagebox(IDOK) # the confirmation
    SketchupStub.queue_messagebox(IDOK) # the refusal it runs into
    newest = repo.history.first.sha

    refute Commands.delete_snapshot(newest)

    assert(SketchupStub.prompts.any? { |text| text.include?('looking at right now') })
    assert_equal %w[two one], repo.history.map(&:subject)
  end

  def test_deleting_an_unknown_snapshot_is_reported
    SketchupStub.queue_messagebox(IDOK)

    refute Commands.delete_snapshot('0' * 40)
    assert(SketchupStub.prompts.any? { |text| text.include?('could not be found') })
  end

  def test_a_removed_snapshot_no_longer_reaches_the_panel
    SketchupStub.queue_messagebox(IDOK)
    Commands.delete_snapshot(@first)

    assert_equal ['two'], Commands.state['snapshots'].map { |s| s['subject'] }
  end

  def test_the_confirmation_preference_is_on_by_default_and_can_be_turned_off
    assert Commands.state['confirm_delete'], 'asking must be the default'

    Settings.confirm_delete = false
    refute Commands.state['confirm_delete']

    # And it has to be reachable again, or "don't ask again" is a one-way door.
    Settings.confirm_delete = true
    assert Commands.state['confirm_delete']
  end
end

class TestRenameCommand < ExtensionTest
  def setup
    super
    accept_tracking
    Commands.snapshot('Frist draft')
    @sha = repo.history.first.sha
  end

  def test_renaming_changes_what_the_list_shows
    assert Commands.rename_snapshot(@sha, 'First draft')

    assert_equal ['First draft'], repo.history.map(&:subject)
    assert_equal ['First draft'], Commands.state['snapshots'].map { |s| s['subject'] }
  end

  def test_renaming_is_remembered
    Commands.rename_snapshot(@sha, 'First draft')

    assert_equal ['First draft'], Repo.discover(@path).history.map(&:subject)
  end

  def test_renaming_to_the_same_text_changes_nothing
    refute Commands.rename_snapshot(@sha, 'Frist draft')
  end

  def test_an_empty_name_is_ignored
    refute Commands.rename_snapshot(@sha, '   ')
    assert_equal ['Frist draft'], repo.history.map(&:subject)
  end

  def test_renaming_does_not_disturb_restoring
    File.binwrite(@path, 'skp-v2')
    Commands.snapshot('second')
    Commands.rename_snapshot(@sha, 'First draft')

    assert Commands.restore(@sha)
    SketchupStub.run_timers!

    assert_equal 'skp-v1', File.binread(@path)
    assert_equal 'First draft', repo.history.find(&:head?).subject
  end
end

class TestToolbarPreference < ExtensionTest
  def test_the_toolbar_is_shown_by_default_but_can_be_turned_off
    assert Commands.state['show_toolbar']

    Settings.show_toolbar = false
    refute Commands.state['show_toolbar']
    assert SnapshotVCS.show_toolbar(false)

    Settings.show_toolbar = true
    assert SnapshotVCS.show_toolbar(true)
  end
end

# Entitlement, as reported by Extension Warehouse. The trial itself is
# Trimble's; these cover how the plugin reacts to each answer.
class TestLicensing < ExtensionTest
  def setup
    super
    Sketchup::Licensing.reset!
    Licensing.reset!
    Licensing.extension_id = 'test-uuid'
    accept_tracking
    Commands.snapshot('base')
    @first = repo.history.first.sha
    File.binwrite(@path, 'skp-v2')
    Commands.snapshot('second')
  end

  def teardown
    Licensing.reset!
    Sketchup::Licensing.reset!
    super
  end

  def license(state, days: nil)
    Sketchup::Licensing.stub =
      Sketchup::Licensing::ExtensionLicense.new(state: state, days_remaining: days)
  end

  def test_an_unlisted_build_is_never_gated
    # No Extension Warehouse id means a source build or development: there is
    # nothing to ask about, so nothing is restricted.
    Licensing.extension_id = ''
    license(Sketchup::Licensing::TRIAL_EXPIRED)

    File.binwrite(@path, 'skp-v3')
    assert Commands.snapshot('still fine')
  end

  def test_a_trial_can_do_everything
    license(Sketchup::Licensing::TRIAL, days: 12)

    File.binwrite(@path, 'skp-v3')
    assert Commands.snapshot('during trial')
    assert Commands.create_variation('Flat roof')
    assert_empty SketchupStub.prompts.grep(/trial has ended/)
  end

  def test_an_expired_trial_pauses_new_snapshots
    license(Sketchup::Licensing::TRIAL_EXPIRED)
    SketchupStub.queue_messagebox(IDCANCEL)

    File.binwrite(@path, 'skp-v3')
    refute Commands.snapshot('after trial')

    assert(SketchupStub.prompts.any? { |t| t.include?('trial has ended') })
    assert_equal %w[second base], repo.history.map(&:subject)
  end

  def test_an_expired_trial_still_lets_you_reach_your_own_work
    license(Sketchup::Licensing::TRIAL_EXPIRED)

    # Nothing that reads or recovers existing work may be blocked. The
    # pending-changes question drops the option the gate would refuse.
    File.binwrite(@path, 'skp-v3')
    Sketchup.active_model.modified = false
    SketchupStub.queue_messagebox(IDOK) # throw the unsnapshotted changes away
    assert Commands.restore(@first)
    SketchupStub.run_timers!
    assert_equal 'skp-v1', File.binread(@path)

    assert Commands.rename_snapshot(@first, 'Renamed after expiry')
    refute_empty Commands.state['snapshots']
  end

  def test_the_dead_end_option_is_not_offered_once_the_trial_ends
    license(Sketchup::Licensing::TRIAL_EXPIRED)
    File.binwrite(@path, 'skp-v3')
    SketchupStub.queue_messagebox(IDCANCEL)

    refute Commands.restore(@first)

    prompt = SketchupStub.prompts.last
    assert_includes prompt, 'Throw those changes away'
    refute_includes prompt, 'snapshot them first'
  end

  def test_the_upgrade_prompt_opens_the_store
    license(Sketchup::Licensing::NOT_LICENSED)
    SketchupStub.queue_messagebox(IDOK)

    File.binwrite(@path, 'skp-v3')
    refute Commands.snapshot('nope')

    assert_includes SketchupStub.urls, SnapshotVCS::Licensing::STORE_URL
  end

  def test_a_failing_licence_check_fails_open
    # A network hiccup must never stop a paying customer working.
    Sketchup::Licensing.stub = :error

    File.binwrite(@path, 'skp-v3')
    assert Commands.snapshot('offline'), 'a failed check must not block work'
  end

  def test_state_reports_trial_days_to_the_panel
    license(Sketchup::Licensing::TRIAL, days: 9)

    info = Commands.state['license']
    assert info['licensed']
    assert info['trial']
    assert_equal 9, info['days_remaining']
    assert_equal 'trial', info['state']
  end

  def test_a_bought_licence_reports_nothing_worth_showing
    license(Sketchup::Licensing::LICENSED)

    info = Commands.state['license']
    assert info['licensed']
    refute info['trial'], 'a paying customer should never see licensing UI'
  end

  def test_creating_a_variation_is_gated_too
    license(Sketchup::Licensing::EXPIRED)
    SketchupStub.queue_messagebox(IDCANCEL)

    refute Commands.create_variation('Flat roof')
    assert_equal ['Original'], repo.variations.map(&:name)
  end
end

class TestObserverAttachment < ExtensionTest
  def test_attaching_the_same_model_twice_does_not_double_up
    model = Sketchup::Model.new(@path)
    3.times { Observers.attach(model) }

    assert_equal 1, model.observers.length, 'a doubled observer means doubled snapshots'
  end

  def test_a_reused_object_id_does_not_leave_a_model_unwatched
    first = Sketchup::Model.new(@path)
    Observers.attach(first)
    recycled = first.object_id

    # Ruby hands object ids out again after garbage collection, and this
    # plugin churns through models — every restore closes one and opens
    # another. Keying "have I seen this?" on object_id eventually skips a live
    # model and auto-snapshot dies silently for the rest of the session.
    replacement = Sketchup::Model.new(@path)
    replacement.define_singleton_method(:object_id) { recycled }
    Observers.attach(replacement)

    assert Observers.watching?(replacement)
    assert_equal 1, replacement.observers.length
  end

  def test_the_previous_model_stops_being_watched
    old = Sketchup::Model.new(@path)
    Observers.attach(old)
    Observers.attach(Sketchup::Model.new(@path))

    assert_empty old.observers, 'a stale observer on a dead model is a leak'
  end

  def test_the_panel_repairs_a_watcher_that_went_missing
    Observers.detach
    refute Observers.watching?(Sketchup.active_model)

    Commands.state

    assert Observers.watching?(Sketchup.active_model)
  end

  def test_auto_snapshot_survives_a_restore_reload
    accept_tracking
    Commands.snapshot('one')
    first = repo.history.first.sha
    File.binwrite(@path, 'skp-v2')
    Commands.snapshot('two')

    Commands.restore(first)
    SketchupStub.run_timers!

    # The model on screen is now a different object than the one watched at
    # the start. Saving must still record a snapshot.
    Settings.auto_snapshot = true
    reopened = Sketchup.active_model
    reopened.modified = true
    File.binwrite(@path, 'skp-v3')
    reopened.save

    assert_match(/\ASaved /, repo.history.first.subject)
  end
end

class TestAutoSnapshotNaming < ExtensionTest
  def setup
    super
    accept_tracking
    Commands.snapshot('base')
    Settings.auto_snapshot = true
  end

  def save_with_a_change
    model.modified = true
    File.binwrite(@path, 'skp-v2')
    model.save
    SketchupStub.run_timers!
  end

  def test_the_snapshot_still_gets_a_timestamp_name
    save_with_a_change

    assert_match(/\ASaved /, repo.history.first.subject)
  end

  def test_the_name_is_handed_over_for_editing
    save_with_a_change
    sha = repo.history.first.sha

    # The timestamp is a placeholder: the panel opens with it selected, so
    # typing replaces it and clicking away keeps it.
    assert Panel.visible?
    assert(Panel.dialog.scripts.any? { |js| js.include?("SnapshotUI.rename(\"#{sha}\")") })
  ensure
    Panel.close
  end

  def test_keeping_the_suggestion_leaves_it_alone
    save_with_a_change
    sha = repo.history.first.sha
    suggested = repo.history.first.subject

    # Clicking away sends the unchanged text back, which must not churn.
    refute Commands.rename_snapshot(sha, suggested)
    assert_equal suggested, repo.history.first.subject
  ensure
    Panel.close
  end

  def test_typing_a_name_replaces_the_timestamp
    save_with_a_change
    sha = repo.history.first.sha

    assert Commands.rename_snapshot(sha, 'Roof at 30 degrees')
    assert_equal 'Roof at 30 degrees', repo.history.first.subject
  ensure
    Panel.close
  end
end

class TestPanelDocument < ExtensionTest
  def teardown
    Panel.close
    super
  end

  def test_the_page_is_self_contained
    html = Panel.send(:page_html)

    # CEF caches sub-resources behind a file:// URL, so a linked stylesheet or
    # script can survive an edit and even a restart. Nothing is linked.
    refute_match(/<link[^>]+stylesheet/, html)
    refute_match(%r{<script src=}, html)
    assert_includes html, '<style>'
    assert_includes html, 'SnapshotUI'
  end

  def test_it_carries_both_modus_and_our_own_styles
    html = Panel.send(:page_html)

    assert_includes html, 'Modus Bootstrap'      # the vendored framework
    assert_includes html, '.snap-dot'            # our timeline
    assert_includes html, '--bs-body-bg'         # tokens hung off Modus
  end

  def test_a_script_close_tag_in_the_source_cannot_break_the_document
    html = Panel.send(:page_html)
    inline = html[html.index('<script>')..-1]

    # Anything after the opening tag must not contain a literal closing tag
    # except the real one at the end.
    assert_equal 1, inline.scan('</script>').length
  end

  def test_the_dialog_loads_that_document_rather_than_a_file
    Panel.show

    assert Panel.visible?
    assert_nil Panel.dialog.file, 'set_file would reintroduce the cache'
    assert_includes Panel.dialog.html.to_s, 'SnapshotUI'
  end
end

# The panel's own markup is not otherwise covered, and edits to it have twice
# gone in half-applied. These read the shipped source directly.
#
# They assert with a message rather than a matcher: a failed match against a
# whole source file prints the whole source file.
class TestPanelSource < ExtensionTest
  def source
    @source ||= File.read(File.join(SnapshotVCS::PLUGIN_DIR, 'html', 'panel.js'))
  end

  def has?(fragment)
    source.include?(fragment)
  end

  def test_one_sentence_covers_both_states
    # A pill beside the picker said the same thing as this line, in fewer and
    # vaguer words.
    assert has?('Nothing has changed since your last snapshot.'), 'the clean state'
    assert has?('changes that aren'), 'the dirty state'
    refute has?("'state-badge'"), 'the pill is gone'
  end

  def test_naming_a_variation_does_not_round_trip_through_ruby
    assert has?('namingVariation = true;'), 'the picker should open the field itself'
    refute has?("bridge('su_create_variation', '')"), 'no empty round trip to Ruby'
  end

  def test_the_picker_and_the_field_below_share_one_container
    assert has?("el('div', 'top')"), 'they need one container to share one gap'
  end
end

# The panel is a separate window and nothing tells it the model changed, so it
# polls. Without this the state pill sits on "Up to date" while you work.
class TestPanelPolling < ExtensionTest
  def teardown
    Panel.close
    super
  end

  def test_it_starts_polling_when_shown_and_stops_when_closed
    Panel.show
    refute_empty SketchupStub.repeating, 'an open panel should be watching'

    Panel.close
    assert_empty SketchupStub.repeating, 'a closed panel should not be'
  end

  def test_a_change_to_the_model_reaches_the_panel
    accept_tracking
    Commands.snapshot('base')
    Panel.show
    before = Panel.dialog.scripts.length

    model.modified = true
    SketchupStub.tick!

    pushed = Panel.dialog.scripts[before..-1].join
    assert_includes pushed, '"dirty":true', 'the panel should learn the model drifted'
  end

  def test_an_unchanged_model_does_not_churn
    accept_tracking
    Commands.snapshot('base')
    Panel.show
    before = Panel.dialog.scripts.length

    3.times { SketchupStub.tick! }

    assert_equal before, Panel.dialog.scripts.length, 'nothing changed, so nothing to push'
  end
end

class TestPanelPlacement < ExtensionTest
  def teardown
    Panel.close
    super
  end

  def test_the_first_appearance_is_centred
    Panel.show

    assert_equal 1, Panel.dialog.centered
    assert Settings.panel_placed?
  end

  def test_reopening_leaves_the_window_where_the_user_put_it
    Panel.show
    Panel.close

    # Toggling destroys and rebuilds the dialog. Centring again would undo
    # whatever position SketchUp restored from preferences_key.
    Panel.show
    assert_equal 0, Panel.dialog.centered
  end
end
