# frozen_string_literal: true

# A minimal stand-in for the SketchUp Ruby API.
#
# Enough of it exists to load the extension end to end and drive the commands,
# which catches the class of bug that is otherwise only findable by clicking
# around in SketchUp: a missing require, a constant that does not resolve, a
# prompt that fires when it should not.
#
# Every dialog is a queue. An unexpected prompt raises rather than returning a
# default, so a test cannot pass by accidentally answering something.

module SketchupStub
  class UnexpectedPrompt < StandardError; end

  class << self
    def reset!
      @messagebox_answers = []
      @inputbox_answers = []
      @prompts = []
      @opened_files = []
      @status_texts = []
      @timers = []
      @urls = []
      @repeating = {}
    end

    attr_reader :prompts, :opened_files, :status_texts, :urls

    def queue_messagebox(*answers)
      @messagebox_answers.concat(answers)
    end

    def queue_inputbox(*answers)
      @inputbox_answers.concat(answers)
    end

    def next_messagebox(text)
      @prompts << text
      raise UnexpectedPrompt, "unexpected messagebox:\n#{text}" if @messagebox_answers.empty?

      @messagebox_answers.shift
    end

    def next_inputbox(text)
      @prompts << text
      raise UnexpectedPrompt, "unexpected inputbox:\n#{text}" if @inputbox_answers.empty?

      @inputbox_answers.shift
    end

    def record_open(path)
      @opened_files << path
    end

    def record_status(text)
      @status_texts << text
    end

    def record_url(url)
      @urls << url
    end

    # SketchUp defers work through UI.start_timer; tests run it explicitly so
    # the ordering stays visible.
    def enqueue_timer(&block)
      @timers << block
    end

    # Repeating timers are held so a test can fire them deliberately.
    def register_repeating(&block)
      @repeating ||= {}
      @next_timer_id = (@next_timer_id || 100) + 1
      @repeating[@next_timer_id] = block
      @next_timer_id
    end

    def cancel_repeating(id)
      @repeating&.delete(id)
    end

    def repeating
      @repeating ||= {}
    end

    def tick!
      repeating.values.each(&:call)
    end

    def run_timers!(limit: 10)
      limit.times do
        break if @timers.empty?

        pending = @timers
        @timers = []
        pending.each(&:call)
      end
    end
  end

  reset!
end

# --- constants ------------------------------------------------------------

MB_OK = 0
MB_OKCANCEL = 1
MB_ABORTRETRYIGNORE = 2
MB_YESNOCANCEL = 3
MB_YESNO = 4
MB_RETRYCANCEL = 5

IDOK = 1
IDCANCEL = 2
IDABORT = 3
IDRETRY = 4
IDIGNORE = 5
IDYES = 6
IDNO = 7

TB_VISIBLE = 1
TB_HIDDEN = 0
TB_NEVER_SHOWN = -1

MF_ENABLED = 0
MF_GRAYED = 1
MF_DISABLED = 2
MF_CHECKED = 4
MF_UNCHECKED = 8

# --- Sketchup -------------------------------------------------------------

module Sketchup
  LOAD_STATUS_SUCCESS = 0
  LOAD_STATUS_SUCCESS_MORE_RECENT = 1

  class Model
    attr_accessor :path
    attr_reader :observers, :closed

    def initialize(path = '')
      @path = path
      @modified = false
      @observers = []
      @closed = false
      @active_view = View.new
    end

    attr_reader :active_view

    def modified?
      @modified
    end

    def modified=(value)
      @modified = value
    end

    def save(target = nil)
      @path = target if target
      @modified = false
      @observers.each { |observer| observer.onSaveModel(self) if observer.respond_to?(:onSaveModel) }
      true
    end

    def add_observer(observer)
      @observers << observer
      true
    end

    def remove_observer(observer)
      @observers.delete(observer)
      true
    end

    def close(_ignore_changes = false)
      @closed = true
      nil
    end
  end

  # Just enough camera for the view-preserving reload to be testable.
  class Camera
    attr_accessor :eye, :target, :up, :fov, :height
    attr_writer :perspective

    def initialize(eye = [0, 0, 0], target = [1, 0, 0], up = [0, 0, 1])
      @eye = eye
      @target = target
      @up = up
      @perspective = true
      @fov = 35.0
      @height = 10.0
    end

    def perspective?
      @perspective
    end

    def set(eye, target, up)
      @eye = eye
      @target = target
      @up = up
      self
    end
  end

  class View
    attr_reader :camera, :invalidated

    def initialize
      @camera = Camera.new
      @invalidated = 0
    end

    def invalidate
      @invalidated += 1
      self
    end
  end

  class ModelObserver; end
  class AppObserver; end

  class << self
    attr_writer :active_model

    def active_model
      @active_model ||= Model.new
    end

    def observers
      @observers ||= []
    end

    def add_observer(observer)
      observers << observer
      true
    end

    def version
      '26.0.100'
    end

    def platform
      :platform_osx
    end

    def require(path)
      Kernel.require(path.end_with?('.rb') ? path : "#{path}.rb")
    end

    def read_default(section, key, default = nil)
      defaults.fetch("#{section}/#{key}", default)
    end

    def write_default(section, key, value)
      defaults["#{section}/#{key}"] = value
      true
    end

    def defaults
      @defaults ||= {}
    end

    def status_text=(text)
      SketchupStub.record_status(text)
    end

    def open_file(path, with_status: false, **_rest)
      SketchupStub.record_open(path)
      self.active_model = Model.new(path)
      observers.each { |o| o.onOpenModel(active_model) if o.respond_to?(:onOpenModel) }
      with_status ? LOAD_STATUS_SUCCESS : true
    end

    def send_action(action)
      SketchupStub.record_status("send_action:#{action}")
      true
    end

    def register_extension(extension, load_now = false)
      extension.load if load_now
      true
    end
  end
end

class SketchupExtension
  attr_accessor :version, :creator, :copyright, :description
  attr_reader :name, :path

  def initialize(name, path)
    @name = name
    @path = path
  end

  def load
    Kernel.require(@path.end_with?('.rb') ? @path : "#{@path}.rb")
  end
end

# --- UI -------------------------------------------------------------------

module UI
  class Command
    attr_accessor :menu_text, :tooltip, :status_bar_text, :small_icon, :large_icon
    attr_reader :title, :block, :validation_proc

    def initialize(title, &block)
      @title = title
      @block = block
    end

    def set_validation_proc(&block)
      @validation_proc = block
      true
    end

    def invoke
      @block.call
    end
  end

  class Menu
    attr_reader :items

    def initialize(name)
      @name = name
      @items = []
    end

    def add_submenu(name)
      Menu.new("#{@name}/#{name}")
    end

    def add_item(command, &block)
      @items << (command || block)
      @items.length
    end

    def add_separator
      @items << :separator
    end
  end

  class Toolbar
    attr_reader :items, :name

    # Pretend every toolbar is brand new, which is the state that matters:
    # it is what the extension uses to decide whether to introduce itself.
    def initialize(name)
      @name = name
      @items = []
      @visible = false
      @last_state = TB_NEVER_SHOWN
    end

    def add_item(command)
      @items << command
      self
    end

    def add_separator
      @items << :separator
      self
    end

    def get_last_state # rubocop:disable Naming/AccessorMethodName
      @last_state
    end

    def restore
      @last_state = TB_VISIBLE
      @visible = true
      nil
    end

    def show
      @visible = true
      nil
    end

    def hide
      @visible = false
      nil
    end

    def visible?
      @visible
    end
  end

  class HtmlDialog
    STYLE_DIALOG = 0
    STYLE_WINDOW = 1
    STYLE_UTILITY = 2

    attr_reader :callbacks, :scripts, :file, :html

    def initialize(_options = {})
      @callbacks = {}
      @scripts = []
      @visible = false
    end

    def add_action_callback(name, &block)
      @callbacks[name] = block
      true
    end

    def set_file(path)
      @file = path
    end

    def set_html(content)
      @html = content
    end

    def execute_script(script)
      @scripts << script
    end

    def set_on_closed(&block)
      @on_closed = block
    end

    def show
      @visible = true
    end

    def visible?
      @visible
    end

    def bring_to_front; end

    def center
      @centered = (@centered || 0) + 1
    end

    def centered
      @centered || 0
    end

    def close
      @visible = false
      @on_closed&.call
    end
  end

  class << self
    def messagebox(text, type = MB_OK)
      answer = SketchupStub.next_messagebox(text)
      return answer unless answer == :default

      type == MB_OK ? IDOK : IDCANCEL
    end

    def inputbox(prompts, defaults = [], _title = nil)
      answer = SketchupStub.next_inputbox(Array(prompts).join(' | '))
      answer == :default ? defaults : answer
    end

    def menu(name = 'Plugins')
      menus[name] ||= Menu.new(name)
    end

    def menus
      @menus ||= {}
    end

    def start_timer(_seconds, repeat = false, &block)
      return SketchupStub.register_repeating(&block) if repeat

      SketchupStub.enqueue_timer(&block)
      1
    end

    def stop_timer(id)
      SketchupStub.cancel_repeating(id)
      nil
    end

    def openURL(url)
      SketchupStub.record_url(url)
      true
    end
  end
end

# --- sketchup.rb helpers --------------------------------------------------

def file_loaded_registry
  $sketchup_loaded_files ||= []
end

def file_loaded?(path)
  file_loaded_registry.include?(path)
end

def file_loaded(path)
  file_loaded_registry << path unless file_loaded?(path)
end
