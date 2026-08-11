# frozen_string_literal: true

module SnapshotVCS
  # HtmlDialog needs 2017; keyword_init Structs and the safe navigation
  # operator need Ruby 2.5, which arrived with SketchUp 2019.
  MINIMUM_SKETCHUP = 19 unless defined?(MINIMUM_SKETCHUP)

  ICONS_DIR = File.join(PLUGIN_DIR, 'icons') unless defined?(ICONS_DIR)

  if Sketchup.version.to_i < MINIMUM_SKETCHUP
    UI.messagebox(
      "Snapshot needs SketchUp #{2000 + MINIMUM_SKETCHUP} or newer. " \
      "This is SketchUp #{Sketchup.version.to_i + 2000}."
    )
  else
    %w[log settings git object_store repo model_io commands observers panel].each do |file|
      Sketchup.require(File.join(PLUGIN_DIR, file))
    end

    # Vector icons are per-platform: SVG on Windows, PDF on macOS. PNG is
    # accepted by both and is only there in case a vector file is missing.
    def self.icon(name)
      extension = Sketchup.platform == :platform_win ? 'svg' : 'pdf'
      path = File.join(ICONS_DIR, "#{name}.#{extension}")
      return path if File.exist?(path)

      File.join(ICONS_DIR, "#{name}.png")
    end

    def self.build_commands
      snapshot = UI::Command.new('Take Snapshot') { Commands.snapshot }
      snapshot.tooltip = 'Take Snapshot'
      snapshot.status_bar_text = 'Save the current state of this model so you can come back to it.'
      snapshot.menu_text = 'Take Snapshot…'
      snapshot.small_icon = icon('snapshot')
      snapshot.large_icon = icon('snapshot')
      # SketchUp cannot swap a toolbar icon after the command is built, so the
      # dirty indicator is expressed as the button's checked (highlighted)
      # state. Deliberately never MF_GRAYED: the button must stay clickable for
      # a model that has no history yet.
      snapshot.set_validation_proc do
        begin
          Status.dirty? ? MF_CHECKED : MF_UNCHECKED
        rescue StandardError
          MF_UNCHECKED
        end
      end

      history = UI::Command.new('Snapshots') { Panel.toggle }
      history.tooltip = 'SketchUp Snapshots'
      history.status_bar_text = 'Show or hide the Snapshots panel.'
      history.menu_text = 'Snapshots…'
      history.small_icon = icon('snapshot')
      history.large_icon = icon('snapshot')
      history.set_validation_proc do
        begin
          Panel.visible? ? MF_CHECKED : MF_UNCHECKED
        rescue StandardError
          MF_UNCHECKED
        end
      end

      new_variation = UI::Command.new('New Variation') { Commands.create_variation }
      new_variation.menu_text = 'New Variation…'
      new_variation.status_bar_text = 'Start a separate line of snapshots to explore a different idea.'

      auto = UI::Command.new('Snapshot on Save') { Commands.toggle_auto_snapshot }
      auto.menu_text = 'Snapshot Every Save'
      auto.status_bar_text = 'Automatically take a snapshot each time you save this model.'
      auto.set_validation_proc do
        begin
          Settings.auto_snapshot? ? MF_CHECKED : MF_UNCHECKED
        rescue StandardError
          MF_UNCHECKED
        end
      end

      reveal = UI::Command.new('Open History Folder') { Commands.reveal_folder }
      reveal.menu_text = 'Open History Folder'
      reveal.status_bar_text = 'Show the folder where this model and its history are kept.'

      { snapshot: snapshot, history: history, new_variation: new_variation,
        auto: auto, reveal: reveal }
    end

    # Show or hide the toolbar without restarting SketchUp.
    def self.show_toolbar(visible)
      return false if @toolbar.nil?

      visible ? @toolbar.show : @toolbar.hide
      true
    rescue StandardError => e
      Log.error("toolbar visibility: #{e.message}")
      false
    end

    def self.build_ui
      commands = build_commands

      menu = UI.menu('Extensions').add_submenu('Snapshot')
      menu.add_item(commands[:snapshot])
      menu.add_item(commands[:history])
      menu.add_separator
      menu.add_item(commands[:new_variation])
      menu.add_separator
      menu.add_item(commands[:auto])
      menu.add_item(commands[:reveal])

      # One button, and all it does is show and hide the panel. Every action
      # lives in the panel, so a toolbar that could fire one would be a second
      # way to do the same thing — and the camera means "take a snapshot"
      # inside the panel, so it would mean two things at once out here.
      toolbar = UI::Toolbar.new('Snapshot')
      toolbar.add_item(commands[:history])

      # Read this before restore(), which is what sets it.
      never_shown = (toolbar.get_last_state == TB_NEVER_SHOWN)

      if Settings.show_toolbar?
        toolbar.restore
      else
        toolbar.hide
      end

      [toolbar, never_shown]
    end

    unless file_loaded?(__FILE__)
      @toolbar, first_run = build_ui
      Observers.install!

      # On macOS a new toolbar is a small floating palette that is genuinely
      # easy to miss, so on the very first launch the panel — which is the
      # actual interface — opens itself once. Never again after that.
      if first_run
        UI.start_timer(1.5, false) do
          begin
            Panel.show
          rescue StandardError => e
            Log.error("could not open the panel on first run: #{e.message}")
          end
        end
      end

      file_loaded(__FILE__)
    end
  end
end
