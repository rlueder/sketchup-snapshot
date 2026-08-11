# frozen_string_literal: true

module SnapshotVCS
  # Watches a single model for saves.
  #
  # Only used for the optional auto-snapshot setting and for keeping the panel
  # in sync; nothing here runs work the user did not ask for when the setting
  # is off.
  class ModelWatcher < Sketchup::ModelObserver
    def onSaveModel(model) # rubocop:disable Naming/MethodName
      # A save triggered by our own snapshot must not trigger another one.
      return if Observers.reentrant?

      Observers.guard do
        Commands.auto_snapshot(model)
        Panel.refresh
      end
    rescue StandardError => e
      # An exception escaping an observer can destabilise SketchUp.
      Log.error("onSaveModel: #{e.message}")
    end
  end

  # Watches the application for models opening and closing so observers get
  # re-attached and the panel follows whatever model is in front.
  class AppWatcher < Sketchup::AppObserver
    def onNewModel(model) # rubocop:disable Naming/MethodName
      Observers.attach(model)
      Panel.refresh
    rescue StandardError => e
      Log.error("onNewModel: #{e.message}")
    end

    def onOpenModel(model) # rubocop:disable Naming/MethodName
      Observers.attach(model)
      Panel.refresh
    rescue StandardError => e
      Log.error("onOpenModel: #{e.message}")
    end

    def onActivateModel(model) # rubocop:disable Naming/MethodName
      Observers.attach(model)
      Panel.refresh
    rescue StandardError => e
      Log.error("onActivateModel: #{e.message}")
    end
  end

  module Observers
    class << self
      def install!
        return if @installed

        @app_watcher = AppWatcher.new
        Sketchup.add_observer(@app_watcher)
        attach(Sketchup.active_model)
        @installed = true
      end

      # Watch a model, replacing whatever was watched before.
      #
      # Identity, never object_id: Ruby reuses ids after garbage collection,
      # and this plugin destroys and recreates models constantly (every
      # restore closes one and opens another). Keying a "have I seen this?"
      # check on object_id means a new model eventually lands on a dead one's
      # id, gets skipped, and is never watched again — auto-snapshot then
      # stops for the rest of the session with nothing to show for it.
      #
      # Exactly one model is watched at a time, and the previous observer is
      # removed rather than left behind, so a save can never be counted twice.
      def attach(model)
        return if model.nil?
        return if @watched && @watched.equal?(model)

        detach
        watcher = ModelWatcher.new
        model.add_observer(watcher)
        @watched = model
        @watcher = watcher
        Status.reset!
      rescue StandardError => e
        Log.error("attach observer: #{e.message}")
      end

      def detach
        return if @watched.nil?

        @watched.remove_observer(@watcher)
      rescue StandardError
        nil # the model may already be gone, which is fine
      ensure
        @watched = nil
        @watcher = nil
      end

      # True when +model+ is the one currently being watched.
      def watching?(model)
        !model.nil? && !@watched.nil? && @watched.equal?(model)
      end

      # Re-entrancy guard so a save the plugin performs itself cannot trigger
      # an auto-snapshot, and an auto-snapshot cannot trigger another save.
      def guard
        @depth = depth + 1
        yield
      ensure
        @depth = depth - 1
      end

      def reentrant?
        depth.positive?
      end

      def depth
        @depth ||= 0
      end
    end
  end
end
