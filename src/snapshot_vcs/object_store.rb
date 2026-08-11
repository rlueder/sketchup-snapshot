# frozen_string_literal: true

require 'digest'
require 'zlib'
require 'fileutils'

module SnapshotVCS
  # An object exists in the repository but cannot be read, because something
  # packed it away and there is no git binary here to unpack it.
  class ObjectUnavailable < StandardError; end

  # Reads and writes git objects directly, with no git binary involved.
  #
  # This is what removes the install requirement. A git object is nothing more
  # than "<type> <length>\0<payload>", deflated, stored under the SHA-1 of the
  # uncompressed form — and SketchUp's Ruby has both Zlib and Digest compiled
  # in. Writing blobs, trees and commits is therefore a few dozen lines, and
  # what lands on disk is a genuine git repository.
  #
  # Only loose objects are written or read. Packfiles are a different and far
  # larger problem, so repositories created here set gc.auto=0; if something
  # packs the objects anyway, reads fall back to a git binary when one happens
  # to be present and raise a clear error when it is not.
  class ObjectStore
    CHUNK = 1024 * 1024

    # Models are large and mostly incompressible (a .skp is already a
    # compressed container), so the slowest compression levels cost seconds per
    # snapshot and save almost nothing. Speed matters more here: git blocks the
    # SketchUp UI thread while it runs.
    COMPRESSION = Zlib::BEST_SPEED

    attr_reader :git_dir

    # @param git_dir [String] path to the .git directory
    # @param git [Git, nil] optional binary, used only to read packed objects
    def initialize(git_dir, git: nil)
      @git_dir = git_dir
      @git = git
      @counter = 0
    end

    # --- writing ------------------------------------------------------------

    # @return [String] the object's sha
    def write(type, payload)
      payload = payload.b
      body = "#{type} #{payload.bytesize}\0".b + payload
      sha = Digest::SHA1.hexdigest(body)
      return sha if exist?(sha)

      store(sha) { |out| out << Zlib::Deflate.deflate(body, COMPRESSION) }
      sha
    end

    # Write a file as a blob without ever holding it in memory.
    #
    # @return [String] the blob's sha
    def write_blob_from_file(path)
      size = File.size(path)
      header = "blob #{size}\0".b
      digest = Digest::SHA1.new
      digest << header

      # The sha is only known once the whole file has been read, so deflate
      # into a temporary file and name it afterwards.
      temporary = temporary_path
      deflate = Zlib::Deflate.new(COMPRESSION)
      begin
        File.open(temporary, 'wb') do |out|
          out << deflate.deflate(header)
          File.open(path, 'rb') do |io|
            while (chunk = io.read(CHUNK))
              digest << chunk
              out << deflate.deflate(chunk)
            end
          end
          out << deflate.finish
        end
      ensure
        deflate.close unless deflate.closed?
      end

      sha = digest.hexdigest
      final = loose_path(sha)
      if File.exist?(final)
        File.delete(temporary) # already stored; identical content
      else
        FileUtils.mkdir_p(File.dirname(final))
        File.rename(temporary, final)
      end
      sha
    rescue StandardError
      File.delete(temporary) if temporary && File.exist?(temporary)
      raise
    end

    # --- reading ------------------------------------------------------------

    def exist?(sha)
      File.exist?(loose_path(sha))
    end

    # @return [Array(String, String)] type and payload (binary)
    def read(sha)
      path = loose_path(sha)
      return read_via_git(sha) unless File.exist?(path)

      body = Zlib::Inflate.inflate(File.binread(path))
      split = body.index("\0".b)
      raise ObjectUnavailable, "Object #{sha} is malformed." if split.nil?

      type, = body.byteslice(0, split).split(' ')
      [type, body.byteslice(split + 1, body.bytesize - split - 1)]
    end

    def read_payload(sha)
      read(sha).last
    end

    # Expand a blob straight onto disk, again without holding it in memory.
    def read_blob_to_file(sha, destination)
      path = loose_path(sha)
      unless File.exist?(path)
        File.binwrite(destination, read_via_git(sha).last)
        return destination
      end

      inflate = Zlib::Inflate.new
      pending = +''.b
      past_header = false

      begin
        File.open(destination, 'wb') do |out|
          File.open(path, 'rb') do |io|
            while (chunk = io.read(CHUNK))
              data = inflate.inflate(chunk)
              past_header = emit(out, data, pending, past_header)
            end
          end
          emit(out, inflate.finish, pending, past_header)
        end
      ensure
        inflate.close unless inflate.closed?
      end

      destination
    end

    # --- trees ---------------------------------------------------------------

    Entry = Struct.new(:mode, :name, :sha)

    MODE_FILE = '100644'
    MODE_DIR = '40000' # git writes tree modes without the leading zero

    # @return [Array<Entry>]
    def self.parse_tree(payload)
      payload = payload.b
      entries = []
      offset = 0

      while offset < payload.bytesize
        space = payload.index(' '.b, offset)
        break if space.nil?

        nul = payload.index("\0".b, space)
        break if nul.nil?

        entries << Entry.new(
          payload.byteslice(offset, space - offset),
          payload.byteslice(space + 1, nul - space - 1),
          payload.byteslice(nul + 1, 20).unpack1('H*')
        )
        offset = nul + 21
      end

      entries
    end

    # Git requires tree entries sorted by name, with directories compared as
    # though their name ended in a slash. Getting this wrong produces a tree
    # that hashes differently from what git would write, and `git fsck` will
    # say so.
    def self.build_tree(entries)
      entries.sort_by { |entry| sort_key(entry) }.map do |entry|
        "#{entry.mode} #{entry.name}\0".b + [entry.sha].pack('H*')
      end.join.b
    end

    def self.sort_key(entry)
      entry.mode == MODE_DIR ? "#{entry.name}/".b : entry.name.b
    end

    private

    # Strip the "<type> <size>\0" header from the first bytes, then pass
    # everything else straight through.
    def emit(out, data, pending, past_header)
      return past_header if data.nil? || data.empty?

      if past_header
        out << data
        return true
      end

      pending << data
      split = pending.index("\0".b)
      return false if split.nil?

      out << pending.byteslice(split + 1, pending.bytesize - split - 1)
      true
    end

    def loose_path(sha)
      File.join(@git_dir, 'objects', sha[0, 2], sha[2..])
    end

    def temporary_path
      @counter += 1
      dir = File.join(@git_dir, 'objects', 'tmp')
      FileUtils.mkdir_p(dir)
      File.join(dir, "incoming-#{Process.pid}-#{@counter}")
    end

    def store(sha)
      temporary = temporary_path
      File.open(temporary, 'wb') { |out| yield(out) }

      final = loose_path(sha)
      FileUtils.mkdir_p(File.dirname(final))
      File.rename(temporary, final)
    rescue StandardError
      File.delete(temporary) if temporary && File.exist?(temporary)
      raise
    end

    # Objects only end up unreadable here if something ran `git gc` and packed
    # them. A real git can still read those, so use one if the machine has one.
    def read_via_git(sha)
      unless @git && @git.available?
        raise ObjectUnavailable,
              'This history has been compacted and cannot be read without git. ' \
              'Installing git will make it readable again.'
      end

      type = @git.try('cat-file', '-t', sha, chdir: @git_dir)
      raise ObjectUnavailable, "Object #{sha} is missing from this history." if type.nil?

      payload, status = @git.capture_raw('cat-file', type, sha, chdir: @git_dir)
      raise ObjectUnavailable, "Object #{sha} could not be read." unless status.success?

      [type, payload]
    end
  end
end
