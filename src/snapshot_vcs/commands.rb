# frozen_string_literal: true

module SnapshotVCS
  # Cheap, cached answer to "is there anything to snapshot?".
  #
  # The toolbar validation proc runs on every UI idle tick, and answering
  # properly means hashing the model, which is far too expensive to do on a
  # tick. Sketchup::Model#modified? covers the common case for free, and the
  # rest is cached.
  module Status
    # Longest a cached answer is trusted. Short enough to feel live, long
    # enough that the validation proc's tick rate never turns into a stream of
    # file hashing.
    REFRESH_INTERVAL = 2.0

    class << self
      def dirty?
        model = Sketchup.active_model
        return false if model.nil?
        return true if model.modified? # free, and covers the common case

        refresh_if_stale(model)
        git_dirty
      end

      def git_dirty
        @git_dirty = false if @git_dirty.nil?
        @git_dirty
      end

      def git_dirty=(value)
        @git_dirty = value
        @checked_at = now
      end

      def reset!
        @git_dirty = false
        @checked_at = 0.0
        @repo_cache = nil
      end

      private

      def now
        Time.now.to_f
      end

      def checked_at
        @checked_at ||= 0.0
      end

      def refresh_if_stale(model)
        return if now - checked_at < REFRESH_INTERVAL

        @checked_at = now
        path = ModelIO.model_path(model)
        if path.nil?
          @git_dirty = false
          return
        end

        repo = repo_for(path)
        # No repository yet means the first snapshot is still to be taken, so
        # the toolbar should invite it rather than look satisfied.
        @git_dirty = repo.nil? ? true : repo.dirty?
      rescue StandardError => e
        Log.error("dirty check failed: #{e.message}")
        @git_dirty = false
      end

      # Only positive lookups are cached: a model that is not tracked yet may
      # become tracked at any moment.
      def repo_for(path)
        cached_path, cached_repo = @repo_cache
        return cached_repo if cached_repo && cached_path == path

        repo = Repo.discover(path)
        @repo_cache = [path, repo] if repo
        repo
      end
    end
  end

  # Everything a user can ask the plugin to do, with all the prompting and
  # error reporting in one place.
  #
  # Every public method returns true on success and false when it was
  # cancelled or failed, so callers can chain them.
  module Commands
    module_function

    # Everything the version-control layer can fail with. There is no longer a
    # git binary to be missing, so these are all real problems worth showing.
    FAILURES = [RepoError, GitError, ObjectUnavailable, ArgumentError].freeze

    # Resolve the active model to a Repo, prompting to create one if needed.
    #
    # @return [Array(Sketchup::Model, Repo), nil]
    def context(create: true)
      model = Sketchup.active_model
      path = ModelIO.model_path(model)

      if path.nil?
        answer = UI.messagebox(
          "This model hasn't been saved yet.\n\n" \
          "Snapshot keeps its history next to the .skp file, so save the " \
          "model somewhere first.\n\nOpen Save As now?",
          MB_OKCANCEL
        )
        ModelIO.request_save_as if answer == IDOK
        return nil
      end

      repo = Repo.discover(path)
      if repo.nil?
        return nil unless create

        folder = File.dirname(path)
        answer = UI.messagebox(
          "Start keeping snapshots of \"#{File.basename(path)}\"?\n\n" \
          "A hidden history folder will be created in:\n#{folder}\n\n" \
          'Nothing else in that folder is touched.',
          MB_OKCANCEL
        )
        return nil unless answer == IDOK

        repo = Repo.init!(path)
        Log.info("initialised repository at #{repo.root}")
      end

      [model, repo]
    rescue *FAILURES => e
      report(e)
      nil
    end

    # --- snapshot ----------------------------------------------------------

    # @param message [String, nil] nil prompts the user
    # @return [Boolean]
    def snapshot(message = nil)
      # Nothing is typed into a native dialog any more. Asking from the toolbar
      # means opening the panel with the field focused, so there is one place a
      # snapshot is described and it looks the same however you got there.
      # Checked before anything else, so merely asking cannot start tracking a
      # model as a side effect.
      if message.nil?
        Panel.focus(:message)
        return false
      end

      ctx = context
      return false if ctx.nil?

      model, repo = ctx
      message = message.to_s.strip
      if message.empty?
        UI.messagebox('Give the snapshot a short description so you can recognise it later.')
        return false
      end

      with_status('Snapshot: saving model…') do
        unless ModelIO.save(model)
          UI.messagebox("SketchUp could not save the model, so there is nothing to snapshot yet.")
          return false
        end
      end

      begin
        sha = with_status('Snapshot: recording…') { repo.snapshot!(message) }
      rescue NothingToSnapshot
        Status.git_dirty = false
        Sketchup.status_text = 'Nothing has changed since the last snapshot.'
        Panel.refresh
        return false
      rescue *FAILURES => e
        report(e)
        return false
      end

      Status.git_dirty = false
      Sketchup.status_text = "Snapshot saved: #{message}"
      Log.info("snapshot #{sha[0, 7]} #{message}")
      Panel.refresh
      true
    end

    # --- restore -----------------------------------------------------------

    # @param sha [String] full or abbreviated commit id
    # @return [Boolean]
    def restore(sha)
      ctx = context(create: false)
      return false if ctx.nil?

      model, repo = ctx

      snap = repo.snapshot_for(sha)
      if snap.nil?
        UI.messagebox('That snapshot could not be found any more.')
        Panel.refresh
        return false
      end

      return false unless settle_pending_changes(
        model, repo,
        action: "going back to \"#{snap.subject}\"",
        auto_message: "Before restoring \"#{snap.subject}\""
      )

      begin
        moved = with_status("Snapshot: opening \"#{snap.subject}\"…") { repo.restore!(sha) }
      rescue *FAILURES => e
        report(e)
        return false
      end

      Status.git_dirty = false
      Panel.refresh

      if moved.nil?
        Sketchup.status_text = "Already showing \"#{snap.subject}\"."
        return true
      end

      Log.info("restored #{snap.short_sha}")
      ModelIO.reload(repo.file_path, note: "Now showing \"#{snap.subject}\".")
      true
    end

    # --- editing the list ----------------------------------------------------

    # Take a snapshot out of the history list.
    #
    # Confirmation is a plain system dialog. An inline version was tried so it
    # could carry its own "don't ask again" tickbox, and it was worse: bulky,
    # and it shoved the list around under the pointer. UI.messagebox has
    # nowhere to put a checkbox, so that preference lives in Settings instead.
    #
    # @return [Boolean]
    def delete_snapshot(sha)
      ctx = context(create: false)
      return false if ctx.nil?

      _model, repo = ctx

      snap = repo.snapshot_for(sha)
      if snap.nil?
        UI.messagebox('That snapshot could not be found any more.')
        Panel.refresh
        return false
      end

      if Settings.confirm_delete?
        answer = UI.messagebox(
          "Remove \"#{snap.subject}\" from the history?\n\n" \
          'Your model is not affected. The snapshot leaves the list but stays ' \
          'on disk, so no space is freed.',
          MB_OKCANCEL
        )
        return false unless answer == IDOK
      end

      begin
        repo.hide_snapshot!(sha)
      rescue *FAILURES => e
        report(e)
        return false
      end

      Sketchup.status_text = "Removed \"#{snap.subject}\" from the history."
      Log.info("hid snapshot #{snap.short_sha}")
      Panel.refresh
      true
    end

    # Give a snapshot a different description.
    #
    # @return [Boolean]
    def rename_snapshot(sha, label)
      ctx = context(create: false)
      return false if ctx.nil?

      _model, repo = ctx

      label = label.to_s.strip
      return false if label.empty?

      begin
        changed = repo.rename_snapshot!(sha, label)
      rescue *FAILURES => e
        report(e)
        return false
      end

      Sketchup.status_text = "Renamed to \"#{label}\"." if changed
      Panel.refresh
      changed
    end

    # --- variations (branches) ------------------------------------------------

    # @param name [String, nil] nil prompts the user
    def create_variation(name = nil)
      ctx = context
      return false if ctx.nil?

      _model, repo = ctx

      if repo.empty?
        UI.messagebox('Take your first snapshot before creating a variation to explore.')
        return false
      end

      if name.nil?
        Panel.focus(:variation)
        return false
      end

      begin
        slug = repo.create_variation!(name)
      rescue InvalidVariationName => e
        UI.messagebox(e.message)
        return false
      rescue *FAILURES => e
        report(e)
        return false
      end

      Sketchup.status_text = "Now working on variation \"#{repo.variation_label(slug)}\"."
      Log.info("created variation #{slug}")
      Panel.refresh
      true
    end

    # @param name [String] the variation's internal name, not its display label
    def switch_variation(name)
      ctx = context(create: false)
      return false if ctx.nil?

      model, repo = ctx
      return true if repo.current_variation == name

      label = repo.variation_label(name)

      return false unless settle_pending_changes(
        model, repo,
        action: "switching to \"#{label}\"",
        auto_message: "Before switching to \"#{label}\"",
        allow_discard: false
      )

      begin
        changed = with_status("Snapshot: opening #{label}…") { repo.switch_variation!(name) }
      rescue InvalidVariationName => e
        UI.messagebox(e.message)
        return false
      rescue *FAILURES => e
        report(e)
        return false
      end

      Status.git_dirty = false
      Log.info("switched to variation #{name} (content changed: #{changed})")
      Panel.refresh

      if changed
        ModelIO.reload(repo.file_path, note: "Switched to \"#{label}\".")
      else
        Sketchup.status_text = "Switched to \"#{label}\". The model is identical here."
      end
      true
    end

    # --- settings ----------------------------------------------------------

    def toggle_auto_snapshot
      Settings.auto_snapshot = !Settings.auto_snapshot?
      Sketchup.status_text =
        if Settings.auto_snapshot?
          'Auto-snapshot on save is ON.'
        else
          'Auto-snapshot on save is OFF.'
        end
      Panel.refresh
      Settings.auto_snapshot?
    end

    def auto_snapshot(model)
      return false unless Settings.auto_snapshot?

      path = ModelIO.model_path(model)
      return false if path.nil?

      repo = Repo.discover(path)
      return false if repo.nil? # never auto-create a repo behind the user's back

      begin
        sha = repo.snapshot!("Saved #{Time.now.strftime('%-d %b %Y, %H:%M')}")
      rescue NothingToSnapshot
        Status.git_dirty = false
        return false
      rescue *FAILURES => e
        # A failing auto-snapshot must never interrupt a save.
        Log.error("auto-snapshot failed: #{e.message}")
        return false
      end

      Status.git_dirty = false
      Sketchup.status_text = 'Auto-snapshot saved.'
      Log.info("auto-snapshot #{sha[0, 7]}")
      Panel.refresh

      # The timestamp is a placeholder, not a decision. Hand it over selected,
      # so typing replaces it and clicking away keeps it.
      Panel.rename(sha)
      true
    end

    def reveal_folder
      ctx = context(create: false)
      return false if ctx.nil?

      _model, repo = ctx
      UI.openURL("file://#{repo.root}")
      true
    end

    # --- state for the panel ----------------------------------------------

    # Snapshot of everything the UI needs, as plain JSON-ready data.
    def state
      model = Sketchup.active_model

      # Cheap self-repair. If a model-open event was ever missed, this puts the
      # watcher back the next time the user touches the panel, rather than
      # leaving auto-snapshot quietly dead until SketchUp restarts.
      Observers.attach(model) unless Observers.watching?(model)

      path = ModelIO.model_path(model)

      data = {
        'ok' => true,
        'problem' => nil,
        'saved' => !path.nil?,
        'model_name' => path ? File.basename(path) : nil,
        'model_path' => path,
        'tracked' => false,
        'dirty' => model ? model.modified? : false,
        'auto_snapshot' => Settings.auto_snapshot?,
        'confirm_delete' => Settings.confirm_delete?,
        'suggested_variation' => nil,
        'show_toolbar' => Settings.show_toolbar?,
        'snapshots' => [],
        'variations' => []
      }
      return data if path.nil?

      repo = Repo.discover(path)
      return data if repo.nil?

      variation = repo.current_variation
      Status.git_dirty = repo.dirty?

      data.merge(
        'tracked' => true,
        'root' => repo.root,
        'relative_path' => repo.relative_path,
        'empty' => repo.empty?,
        'variation' => variation,
        'variation_label' => repo.variation_label(variation),
        'dirty' => Status.dirty?,
        'snapshots' => repo.history(limit: Settings.history_limit).map(&:to_h),
        'variations' => repo.variations.map(&:to_h),
        'suggested_variation' => suggested_variation_name(repo)
      )
    rescue *FAILURES => e
      message = e.respond_to?(:user_message) ? e.user_message : e.message
      Log.error("state failed: #{message}")
      { 'ok' => false, 'problem' => message, 'snapshots' => [], 'variations' => [] }
    end

    # --- helpers -----------------------------------------------------------

    # Make sure nothing unsnapshotted is about to be destroyed, and leave the
    # model clean on disk so it can be closed without SketchUp prompting.
    #
    # @return [Boolean] false when the user cancelled
    def settle_pending_changes(model, repo, action:, auto_message:, allow_discard: true)
      pending = model.modified? || repo.dirty?

      if pending && allow_discard
        answer = UI.messagebox(
          "You have changes that aren't in a snapshot yet.\n\n" \
          "Yes — snapshot them first, then continue\n" \
          "No — throw them away and continue #{action}\n" \
          "Cancel — stay where I am",
          MB_YESNOCANCEL
        )
        return false if answer == IDCANCEL
        return false if answer == IDYES && !snapshot(auto_message)
      elsif pending
        # Opening another variation overwrites the model file with that variation's
        # version, so unsnapshotted work would simply vanish. Unlike a restore,
        # there is no discard path worth offering here.
        answer = UI.messagebox(
          "You have changes that aren't in a snapshot yet.\n\n" \
          "They have to be snapshotted before #{action}.\n\nSnapshot them now?",
          MB_OKCANCEL
        )
        return false unless answer == IDOK
        return false unless snapshot(auto_message)
      end

      # Even when discarding, write the model out first: a clean model closes
      # without SketchUp asking about unsaved changes, and the file is
      # overwritten from the history a moment later anyway.
      if model.modified? && !ModelIO.save(model)
        UI.messagebox('SketchUp could not save the model, so nothing was changed.')
        return false
      end

      true
    end

    def suggested_variation_name(repo)
      taken = repo.variations.map { |o| o.label.downcase }
      ('A'..'Z').each do |letter|
        candidate = "Variation #{letter}"
        return candidate unless taken.include?(candidate.downcase)
      end
      'New variation'
    end

    # Large .skp files take a noticeable moment to write and hash, and that
    # work happens on the UI thread. Leaving a note in the status bar is the cheapest honest
    # signal that SketchUp has not hung.
    def with_status(text)
      Sketchup.status_text = text
      yield
    end

    def report(error)
      message =
        if error.respond_to?(:user_message)
          error.user_message
        else
          error.message
        end
      Log.error(message)
      UI.messagebox("Snapshot couldn't finish that:\n\n#{message}")
      false
    end
  end
end
