# frozen_string_literal: true
#
# Snapshots for SketchUp — local version control for .skp files.
#
# This file is the extension registrar. SketchUp loads every .rb directly
# inside its Plugins folder at startup, so this file must stay tiny and must
# not touch the model. All real work lives in snapshot_vcs/ and is only loaded
# once the user has the extension enabled.

require 'sketchup.rb'
require 'extensions.rb'

module SnapshotVCS
  PLUGIN_ROOT = File.expand_path(File.dirname(__FILE__)).freeze
  PLUGIN_DIR  = File.join(PLUGIN_ROOT, 'snapshot_vcs').freeze

  # Matches the Extension Warehouse listing title exactly.
  EXTENSION_NAME = 'Snapshots'
  VERSION = '1.0.0'

  unless defined?(@extension)
    @extension = SketchupExtension.new(
      EXTENSION_NAME,
      File.join(PLUGIN_DIR, 'main')
    )
    @extension.version = VERSION
    @extension.creator = 'Rafael Lueder'
    # The year is fixed on purpose: a year computed at load time would change
    # under the user and say nothing about which release they are running.
    @extension.copyright = '© 2026 Rafael Lueder, MIT licensed'
    @extension.description =
      'Save named snapshots of your model and jump back to any of them. ' \
      'Explore competing ideas as parallel variations. Nothing to install ' \
      'alongside it.'

    Sketchup.register_extension(@extension, true)
  end

  # The SketchupExtension instance, for introspection/debugging.
  def self.extension
    @extension
  end
end
