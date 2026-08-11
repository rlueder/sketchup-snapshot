# frozen_string_literal: true

# Stands in for SketchUp's own sketchup.rb, which the extension requires by
# name. Pulling in the stub here means src/snapshot_vcs.rb can be loaded
# unmodified outside SketchUp.
require_relative '../sketchup_stub'
