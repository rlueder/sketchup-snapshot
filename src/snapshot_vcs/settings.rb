# frozen_string_literal: true

module SnapshotVCS
  # Persisted preferences. Backed by Sketchup.read_default/write_default, which
  # writes a plist on macOS and the registry on Windows.
  module Settings
    SECTION = 'SnapshotVCS'

    # Take a snapshot every time the model is saved. Off by default.
    AUTO_SNAPSHOT = 'auto_snapshot'

    # Ask before taking a snapshot out of the history list.
    CONFIRM_DELETE = 'confirm_delete'

    # Show the Snapshot toolbar. A custom toolbar is the usual pattern for a
    # SketchUp extension, but on macOS it arrives as a small floating palette
    # that not everyone wants, and the panel does everything it does.
    SHOW_TOOLBAR = 'show_toolbar'

    # Whether the panel has ever been positioned. Only the first appearance is
    # centred; after that SketchUp restores wherever the user left it.
    PANEL_PLACED = 'panel_placed'

    # How many snapshots to show in the panel.
    HISTORY_LIMIT = 'history_limit'

    module_function

    def auto_snapshot?
      read(AUTO_SNAPSHOT, false)
    end

    def auto_snapshot=(value)
      write(AUTO_SNAPSHOT, !!value)
    end

    def confirm_delete?
      read(CONFIRM_DELETE, true)
    end

    def confirm_delete=(value)
      write(CONFIRM_DELETE, !!value)
    end

    def show_toolbar?
      read(SHOW_TOOLBAR, true)
    end

    def show_toolbar=(value)
      write(SHOW_TOOLBAR, !!value)
    end

    def panel_placed?
      read(PANEL_PLACED, false)
    end

    def panel_placed=(value)
      write(PANEL_PLACED, !!value)
    end

    def history_limit
      value = read(HISTORY_LIMIT, 200).to_i
      value.between?(10, 2000) ? value : 200
    end

    def read(key, default)
      Sketchup.read_default(SECTION, key, default)
    rescue StandardError
      default
    end

    def write(key, value)
      Sketchup.write_default(SECTION, key, value)
      value
    end
  end
end
