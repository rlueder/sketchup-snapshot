# frozen_string_literal: true

require 'zlib'

# Writes the .rbz archive.
#
# An .rbz is a plain zip with a different extension. Ruby's standard library
# has no zip writer and the rubyzip gem is not worth a dependency for this, so
# entries are written uncompressed — the extension is a hundred kilobytes of
# text and vectors, and SketchUp does not care either way.
#
# Timestamps are fixed so that building the same sources twice produces
# byte-identical archives.
module RBZ
  DOS_DATE = ((2020 - 1980) << 9) | (1 << 5) | 1 # 2020-01-01
  DOS_TIME = 0
  UTF8_FLAG = 0x0800 # filenames are UTF-8, not CP437

  Entry = Struct.new(:name, :data, :crc, :offset)

  module_function

  # @param output [String] path of the .rbz to write
  # @param files [Hash{String=>String}] archive path => absolute source path
  def write(output, files)
    entries = []
    body = +''.b

    files.keys.sort.each do |archive_path|
      data = File.binread(files[archive_path])
      entry = Entry.new(archive_path, data, Zlib.crc32(data), body.bytesize)
      body << local_header(entry) << data
      entries << entry
    end

    directory_offset = body.bytesize
    directory = +''.b
    entries.each { |entry| directory << central_header(entry) }

    File.binwrite(output, body + directory + end_record(entries.length, directory.bytesize, directory_offset))
    output
  end

  def local_header(entry)
    name = entry.name.b
    [
      0x04034b50,       # local file header signature
      20,               # version needed to extract (2.0)
      UTF8_FLAG,
      0,                # method: stored
      DOS_TIME, DOS_DATE,
      entry.crc,
      entry.data.bytesize,
      entry.data.bytesize,
      name.bytesize,
      0                 # extra field length
    ].pack('VvvvvvVVVvv') + name
  end

  def central_header(entry)
    name = entry.name.b
    [
      0x02014b50,       # central directory header signature
      20,               # version made by
      20,               # version needed to extract
      UTF8_FLAG,
      0,                # method: stored
      DOS_TIME, DOS_DATE,
      entry.crc,
      entry.data.bytesize,
      entry.data.bytesize,
      name.bytesize,
      0, 0,             # extra field length, comment length
      0,                # disk number start
      0,                # internal attributes
      0o100644 << 16,   # external attributes: regular file, rw-r--r--
      entry.offset
    ].pack('VvvvvvvVVVvvvvvVV') + name
  end

  def end_record(count, directory_size, directory_offset)
    [
      0x06054b50,       # end of central directory signature
      0, 0,             # disk numbers
      count, count,
      directory_size,
      directory_offset,
      0                 # comment length
    ].pack('VvvvvVVv')
  end
end
