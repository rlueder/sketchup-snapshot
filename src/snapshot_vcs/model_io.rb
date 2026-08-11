# frozen_string_literal: true

module SnapshotVCS
  # Saving, closing and reopening the SketchUp model.
  #
  # This is the part the spec calls the trickiest UX bit, so the reasoning is
  # spelled out here rather than in a commit message.
  #
  # The "discard unsaved changes" prompt appears because SketchUp asks about
  # the dirty flag when a model closes. Rather than trying to suppress the
  # prompt, we make it impossible for it to fire: the model is always saved to
  # disk *before* git touches the file, so by the time we close, the model is
  # clean as far as SketchUp is concerned. Whether the user keeps or discards
  # that saved state is decided one level up, in Commands, where they are asked
  # in plain language.
  #
  # Reopening then differs by platform:
  #
  #   Windows — one document at a time. Model#close performs a File/New, and
  #             Sketchup.open_file replaces the current model.
  #   macOS   — multi-document. Calling Sketchup.open_file on a path that is
  #             already open just raises the existing window; it does not
  #             re-read the file. The model must be closed first.
  #
  # Closing first is correct on both, so that is what we do everywhere.
  module ModelIO
    module_function

    # @return [String, nil] the model's path, or nil when it was never saved
    def model_path(model = Sketchup.active_model)
      return nil if model.nil?

      path = model.path.to_s
      path.empty? ? nil : path
    end

    # Flush the model to disk so the file git sees matches what is on screen.
    #
    # @return [Boolean] true when the file on disk is up to date afterwards
    def save(model = Sketchup.active_model)
      return false if model.nil?
      return true unless model.modified?

      # Guarded so this save does not fire the auto-snapshot observer: the
      # caller is already about to snapshot, and a double commit would leave
      # the explicit one with nothing to record.
      Observers.guard { model.save }
    rescue StandardError => e
      Log.error("save failed: #{e.message}")
      false
    end

    # Ask SketchUp to reopen the file from disk.
    #
    # @param path [String]
    # @param note [String] short description of why, used in the manual message
    # @return [Boolean] true when a reload was scheduled
    def reload(path, note: 'The snapshot has been restored.')
      unless File.exist?(path)
        UI.messagebox("The model file is missing:\n\n#{path}")
        return false
      end

      # Defer so we are not closing the model from inside a menu command or an
      # HtmlDialog callback that still has frames on the Ruby stack.
      UI.start_timer(0.0, false) { perform_reload(path, note) }
      true
    end

    def perform_reload(path, note)
      model = Sketchup.active_model

      if model && same_file?(model_path(model), path)
        if model.modified?
          # Should not happen — Commands saves first — but never throw away
          # the user's work just because an assumption slipped.
          Log.error('refusing to close a modified model; falling back to manual reload')
          UI.messagebox("#{note}\n\nReopen the file to see it:\n\n#{path}")
          return false
        end

        # Remember where the user was standing. Each .skp carries its own saved
        # camera, so without this you get thrown to wherever the model happened
        # to be saved from — which is most of what makes switching versions
        # feel like the whole application blinked, rather than the model
        # changing in front of you.
        camera = capture_camera(model)

        begin
          model.close(true)
        rescue StandardError => e
          Log.error("model.close failed: #{e.message}")
        end
      end

      # One event-loop turn, not a fixed pause. Deferring is what keeps this
      # off the stack of whatever triggered it; the length of the wait was
      # never the safety property, and 200ms of empty screen was just flicker.
      UI.start_timer(0.0, false) { open_file(path, note, camera) }
      true
    end

    def open_file(path, note, camera = nil)
      status = begin
        Sketchup.open_file(path, with_status: true)
      rescue ArgumentError, NoMethodError
        # with_status: is SketchUp 2021+. Older versions return a boolean.
        Sketchup.open_file(path)
      end

      if status == false
        UI.messagebox("SketchUp could not reopen the file.\n\n#{note}\nOpen it manually:\n\n#{path}")
        return false
      end

      # Applied in the same tick as the load, so the view is only painted once.
      apply_camera(Sketchup.active_model, camera)

      Sketchup.status_text = note
      Panel.refresh
      true
    rescue StandardError => e
      Log.error("open_file failed: #{e.message}")
      UI.messagebox("SketchUp could not reopen the file.\n\n#{note}\nOpen it manually:\n\n#{path}")
      false
    end

    # @return [Hash, nil] enough to put the view back exactly where it was
    def capture_camera(model)
      camera = model.active_view.camera
      {
        eye: camera.eye,
        target: camera.target,
        up: camera.up,
        perspective: camera.perspective?,
        fov: (camera.fov if camera.perspective?),
        height: (camera.height unless camera.perspective?)
      }
    rescue StandardError => e
      Log.error("could not read the camera: #{e.message}")
      nil
    end

    def apply_camera(model, saved)
      return false if model.nil? || saved.nil?

      view = model.active_view
      camera = view.camera
      camera.set(saved[:eye], saved[:target], saved[:up])
      camera.perspective = saved[:perspective]

      if saved[:perspective]
        camera.fov = saved[:fov] if saved[:fov]
      elsif saved[:height]
        camera.height = saved[:height]
      end

      view.invalidate
      true
    rescue StandardError => e
      # A restored view is a nicety; never let it break the restore itself.
      Log.error("could not restore the camera: #{e.message}")
      false
    end

    # Windows paths are case-insensitive and may mix separators.
    def same_file?(a, b)
      return false if a.nil? || b.nil?

      a = File.expand_path(a)
      b = File.expand_path(b)
      if Sketchup.platform == :platform_win
        a.casecmp(b).zero?
      else
        a == b
      end
    end

    # Nudge SketchUp's Save As dialog for a model that has never been saved.
    def request_save_as
      # Documented action string, valid on both platforms.
      Sketchup.send_action('saveDocumentAs:')
    rescue StandardError => e
      Log.error("could not trigger Save As: #{e.message}")
      false
    end
  end
end
