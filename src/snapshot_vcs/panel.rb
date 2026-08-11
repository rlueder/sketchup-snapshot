# frozen_string_literal: true

require 'json'

module SnapshotVCS
  # The History window.
  #
  # SketchUp has no cross-platform docking API for extension panels, so this is
  # a non-modal HtmlDialog with STYLE_DIALOG: it floats above SketchUp and can
  # be left open beside the model, which is as close to a side panel as the API
  # allows on both Windows and macOS.
  module Panel
    HTML_DIR = File.join(SnapshotVCS::PLUGIN_DIR, 'html')

    # How often the open panel checks whether the model has drifted from its
    # newest snapshot. Editing a model tells the panel nothing — it is a
    # separate window and no observer fires for ordinary drawing — so without
    # this the badge sits on "Up to date" while you work.
    POLL_INTERVAL = 1.0
    PREFERENCES_KEY = 'com.rafaellueder.snapshot_vcs.panel'

    class << self
      # Show the panel, or bring it forward if it is already open.
      def show
        dialog = self.dialog
        if dialog.visible?
          dialog.bring_to_front
        else
          dialog.show
        end
        refresh
        watch
        dialog
      end

      # Bring the panel up with a particular field ready to type in. This is
      # what the toolbar and menu do instead of opening a dialog of their own.
      def focus(field)
        show
        return false unless @dialog

        @dialog.execute_script("window.SnapshotUI && SnapshotUI.focus(#{js_literal(field.to_s)});")
        true
      rescue StandardError => e
        Log.error("could not focus #{field}: #{e.message}")
        false
      end

      # Open the panel with a snapshot's description selected and ready to
      # overwrite. Deferred, because this is called from a model observer and
      # showing a dialog from inside one is asking for trouble.
      def rename(sha)
        UI.start_timer(0.0, false) do
          begin
            show
            if @dialog
              @dialog.execute_script("window.SnapshotUI && SnapshotUI.rename(#{js_literal(sha.to_s)});")
            end
          rescue StandardError => e
            Log.error("could not open the description for editing: #{e.message}")
          end
        end
        true
      end

      def toggle
        if @dialog && @dialog.visible?
          @dialog.close
          false
        else
          show
          true
        end
      end

      def visible?
        !@dialog.nil? && @dialog.visible?
      end

      # Push current state into the page. Safe to call when nothing is open.
      def refresh
        return false unless visible?

        push(Commands.state)
        true
      rescue StandardError => e
        Log.error("panel refresh failed: #{e.message}")
        false
      end

      def close
        unwatch
        @dialog.close if @dialog && @dialog.visible?
        @dialog = nil
      end

      # Only the dirty flag is polled, and only a change in it pushes state.
      # Status.dirty? is Model#modified? plus a cached answer, so the tick
      # itself costs nothing.
      def watch
        return if @timer

        @timer = UI.start_timer(POLL_INTERVAL, true) { tick }
      end

      def unwatch
        UI.stop_timer(@timer) if @timer
        @timer = nil
      end

      def tick
        return unwatch unless visible?

        dirty = Status.dirty?
        return if dirty == @last_dirty

        push(Commands.state)
      rescue StandardError => e
        Log.error("panel poll failed: #{e.message}")
        unwatch
      end

      # Keep a strong reference: an HtmlDialog that gets garbage collected
      # closes its window.
      def dialog
        @dialog ||= build_dialog
      end

      private

      def build_dialog
        dialog = UI::HtmlDialog.new(
          dialog_title: "SketchUp Snapshots #{SnapshotVCS::VERSION}",
          preferences_key: PREFERENCES_KEY,
          scrollable: true,
          resizable: true,
          width: 360,
          height: 620,
          min_width: 300,
          min_height: 360,
          style: UI::HtmlDialog::STYLE_DIALOG
        )

        # Callbacks must be attached before show, and the page asks for state
        # itself once it has loaded rather than us guessing at load timing.
        attach_callbacks(dialog)
        load_page(dialog)
        dialog.set_on_closed do
          unwatch
          @dialog = nil
        end
        # Not centred every time. SketchUp remembers size and position against
        # preferences_key, and centring throws that away on each reopen — the
        # panel is closed and rebuilt whenever it is toggled, so the window
        # jumped back to the middle every time. Centre only the first
        # appearance, when there is nothing to restore.
        unless Settings.panel_placed?
          dialog.center
          Settings.panel_placed = true
        end

        dialog
      end

      # The stylesheet and script are inlined rather than linked.
      #
      # set_file hands CEF a file:// URL, and CEF caches the sub-resources
      # behind it — so editing panel.css or panel.js and reopening the dialog,
      # or even restarting SketchUp, can still show the previous version. That
      # is a miserable thing to debug, because the files on disk are plainly
      # correct. Passing one self-contained document leaves nothing to cache.
      def load_page(dialog)
        dialog.set_html(page_html)
      rescue StandardError => e
        Log.error("could not inline the panel assets: #{e.message}")
        dialog.set_file(File.join(HTML_DIR, 'panel.html'))
      end

      def page_html
        html = File.read(File.join(HTML_DIR, 'panel.html'))

        html = html.gsub(/<link rel="stylesheet" href="([^"]+)">/) do
          "<style>\n#{read_asset(Regexp.last_match(1))}\n</style>"
        end

        html.gsub(%r{<script src="([^"]+)"></script>}) do
          # A literal </script> inside the source would close the tag early.
          body = read_asset(Regexp.last_match(1)).gsub('</script', '<\\/script')
          "<script>\n#{body}\n</script>"
        end
      end

      def read_asset(relative)
        File.read(File.join(HTML_DIR, relative))
      end

      def attach_callbacks(dialog)
        dialog.add_action_callback('su_ready') { |_ctx| push(Commands.state) }

        dialog.add_action_callback('su_snapshot') do |_ctx, message|
          text = message.to_s.strip
          Commands.snapshot(text.empty? ? nil : text)
          push(Commands.state)
        end

        dialog.add_action_callback('su_restore') do |_ctx, sha|
          Commands.restore(sha.to_s)
          push(Commands.state)
        end

        dialog.add_action_callback('su_delete') do |_ctx, sha|
          Commands.delete_snapshot(sha.to_s)
          push(Commands.state)
        end

        dialog.add_action_callback('su_rename') do |_ctx, sha, label|
          Commands.rename_snapshot(sha.to_s, label.to_s)
          push(Commands.state)
        end

        dialog.add_action_callback('su_set_confirm_delete') do |_ctx, value|
          Settings.confirm_delete = truthy?(value)
          push(Commands.state)
        end

        dialog.add_action_callback('su_create_variation') do |_ctx, name|
          text = name.to_s.strip
          Commands.create_variation(text.empty? ? nil : text)
          push(Commands.state)
        end

        dialog.add_action_callback('su_switch_variation') do |_ctx, name|
          Commands.switch_variation(name.to_s)
          push(Commands.state)
        end

        dialog.add_action_callback('su_start_tracking') do |_ctx|
          # context(create: true) does the asking and the git init.
          Commands.context
          push(Commands.state)
        end

        dialog.add_action_callback('su_save_model') do |_ctx|
          ModelIO.request_save_as
          push(Commands.state)
        end

        dialog.add_action_callback('su_buy') do |_ctx|
          Licensing.open_store
        end

        dialog.add_action_callback('su_reveal') do |_ctx|
          Commands.reveal_folder
        end

        dialog.add_action_callback('su_set_auto_snapshot') do |_ctx, value|
          Settings.auto_snapshot = truthy?(value)
          push(Commands.state)
        end

        dialog.add_action_callback('su_set_show_toolbar') do |_ctx, value|
          Settings.show_toolbar = truthy?(value)
          SnapshotVCS.show_toolbar(Settings.show_toolbar?)
          push(Commands.state)
        end
      end

      def truthy?(value)
        [true, 'true', 1, '1'].include?(value)
      end

      def push(state)
        return unless @dialog

        @last_dirty = state['dirty']

        @dialog.execute_script("window.SnapshotUI && SnapshotUI.render(#{js_literal(state)});")
      end

      # JSON is a JavaScript expression, with two historical exceptions:
      # U+2028 and U+2029 are legal in JSON strings but were line terminators
      # in JavaScript before ES2019. Escaping them costs nothing.
      def js_literal(data)
        JSON.generate(data).gsub("\u2028", '\\u2028').gsub("\u2029", '\\u2029')
      end
    end
  end
end
