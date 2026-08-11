# frozen_string_literal: true

require 'rake/testtask'
require 'fileutils'

ROOT = __dir__
SRC = File.join(ROOT, 'src')
BUILD = File.join(ROOT, 'build')
LOADER = 'snapshot_vcs.rb'
PACKAGE = 'snapshot_vcs'

def version
  @version ||= File.read(File.join(SRC, LOADER))[/VERSION\s*=\s*'([^']+)'/, 1] ||
               raise('could not read VERSION from the loader')
end

# Everything that ships inside the .rbz, as archive path => source path.
def payload
  Dir.chdir(SRC) do
    Dir.glob(['*.rb', "#{PACKAGE}/**/*"])
       .select { |path| File.file?(path) }
       .reject { |path| File.basename(path).start_with?('.') }
       .each_with_object({}) { |path, files| files[path] = File.join(SRC, path) }
  end
end

Rake::TestTask.new(:test) do |t|
  t.libs << 'test'
  t.test_files = FileList['test/test_*.rb']
  t.warning = false
end

desc 'Check every Ruby file parses'
task :syntax do
  files = Dir.glob(File.join(ROOT, '{src,test,tools}/**/*.rb')) + [__FILE__]
  failures = files.reject do |file|
    system(RbConfig.ruby, '-c', file, out: File::NULL, err: File::NULL)
  end
  abort "Syntax errors in:\n  #{failures.join("\n  ")}" unless failures.empty?
  puts "#{files.length} files parse cleanly"
end

desc 'Check the panel JavaScript (needs node; skipped without it)'
task :js do
  script = File.join(ROOT, 'test', 'time_labels.js')

  panel = File.join(ROOT, 'src', 'snapshot_vcs', 'html', 'panel.js')

  if system('node', '--version', out: File::NULL, err: File::NULL)
    sh('node', '--check', panel)
    sh('node', script)
  else
    puts 'node not found — skipping the panel JavaScript checks'
  end
end

desc 'Regenerate the toolbar icons from their geometry definitions'
task :icons do
  ruby File.join(ROOT, 'tools', 'build_icons.rb')
end

desc 'Package the extension as an .rbz'
task build: %i[syntax] do
  require_relative 'tools/rbz'

  FileUtils.mkdir_p(BUILD)
  output = File.join(BUILD, "#{PACKAGE}-#{version}.rbz")
  files = payload
  RBZ.write(output, files)

  puts "#{output} (#{files.length} files, #{File.size(output)} bytes)"
end

desc 'Copy the extension straight into every SketchUp Plugins folder found'
task install: %i[syntax] do
  targets = plugin_dirs
  abort 'No SketchUp Plugins folder found. Set SKETCHUP_PLUGINS to one.' if targets.empty?

  targets.each do |target|
    FileUtils.mkdir_p(target)
    FileUtils.rm_rf(File.join(target, PACKAGE))
    payload.each do |archive_path, source|
      destination = File.join(target, archive_path)
      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.cp(source, destination)
    end
    puts "installed to #{target}"
  end
  puts 'Restart SketchUp to pick up the changes.'
end

desc 'Remove the extension from every SketchUp Plugins folder found'
task :uninstall do
  plugin_dirs.each do |target|
    FileUtils.rm_rf(File.join(target, PACKAGE))
    FileUtils.rm_f(File.join(target, LOADER))
    puts "removed from #{target}"
  end
end

# SketchUp keeps a Plugins folder per major version, in a different place on
# each platform. SKETCHUP_PLUGINS overrides the search for unusual setups.
def plugin_dirs
  override = ENV['SKETCHUP_PLUGINS']
  return [override] if override && !override.empty?

  windows = RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/i
  pattern =
    if windows
      "#{ENV['APPDATA'].to_s.tr('\\', '/')}/SketchUp/SketchUp */SketchUp/Plugins"
    else
      "#{Dir.home}/Library/Application Support/SketchUp */SketchUp/Plugins"
    end

  found = Dir.glob(pattern).sort
  return found unless found.empty?

  # A SketchUp that has never been launched has no Plugins folder yet. Fall
  # back to the folder the installed version will use, so a fresh machine does
  # not need the path typed in by hand.
  installed_versions(windows).map do |version|
    if windows
      "#{ENV['APPDATA'].to_s.tr('\\', '/')}/SketchUp/SketchUp #{version}/SketchUp/Plugins"
    else
      "#{Dir.home}/Library/Application Support/SketchUp #{version}/SketchUp/Plugins"
    end
  end
end

def installed_versions(windows)
  pattern =
    if windows
      "#{ENV['ProgramFiles'].to_s.tr('\\', '/')}/SketchUp/SketchUp */SketchUp.exe"
    else
      '/Applications/SketchUp */SketchUp.app'
    end

  Dir.glob(pattern).map { |path| path[%r{SketchUp (\d{4})}, 1] }.compact.uniq.sort
end

task default: %i[syntax js test]
