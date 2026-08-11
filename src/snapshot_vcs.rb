# frozen_string_literal: true
#
# Snapshot for SketchUp — local version control for .skp files.
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

  EXTENSION_NAME = 'Snapshot'
  VERSION = '1.0.0'

  unless defined?(@extension)
    @extension = SketchupExtension.new(
      EXTENSION_NAME,
      File.join(PLUGIN_DIR, 'main')
    )
    @extension.version = VERSION
    @extension.creator = 'Rafael Lueder'
    @extension.copyright = "© #{Time.now.year} Rafael Lueder — MIT licensed"
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
