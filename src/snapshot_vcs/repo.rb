# frozen_string_literal: true

require 'json'
require 'fileutils'

# Nothing of ours is required here. Extension Warehouse encrypts submitted
# extensions to .rbe, and a plain require would still be looking for a .rb;
# main.rb loads every file in dependency order with Sketchup.require, which
# finds either.

module SnapshotVCS
  # Raised when a snapshot was requested but the file is byte-identical to the
  # last one. Not an error condition — the UI reports it as information.
  class NothingToSnapshot < StandardError; end

  # Raised when a name the user typed cannot be used for a variation.
  class InvalidVariationName < StandardError; end

  # Raised when the repository itself is unusable.
  class RepoError < StandardError
    def user_message
      message
    end
  end

  # One recorded state of the model.
  Snapshot = Struct.new(:sha, :short_sha, :time, :author, :subject, :body, :head, keyword_init: true) do
    def head?
      !!head
    end

    def to_h
      { 'sha' => sha, 'short_sha' => short_sha, 'time' => time, 'author' => author,
        'subject' => subject, 'body' => body, 'head' => head? }
    end
  end

  # One parallel line of work — a variation.
  Variation = Struct.new(:name, :label, :short_sha, :time, :current, keyword_init: true) do
    def current?
      !!current
    end

    def to_h
      { 'name' => name, 'label' => label, 'short_sha' => short_sha,
        'time' => time, 'current' => current? }
    end
  end

  # A commit, as read back out of the object store.
  Commit = Struct.new(:sha, :tree, :parents, :author, :time, :message, keyword_init: true)

  # The version history for one .skp file.
  #
  # Everything here is written with Ruby and Zlib rather than by running git,
  # so the plugin has no install requirement — but the bytes on disk are a real
  # git repository and any git can read them.
  #
  # Two deliberate boundaries keep that safe when the model happens to live in
  # a repository the user already owns:
  #
  #   * history is kept under refs/snapshots/, our own ref namespace
  #   * HEAD, the index and every other file are never touched
  #
  # So a user's own branches, staged changes and working tree carry on exactly
  # as before, and `git log --all` still shows everything this plugin recorded.
  class Repo
    # Trailer stamped on the commit that records a restore, naming the snapshot
    # that was restored.
    #
    # Going back is stored as a forward commit, so nothing can be lost. But
    # that commit is bookkeeping rather than something the user did: it is left
    # out of the history, and the trailer is what lets the panel put the "you
    # are here" marker on the snapshot that was actually restored.
    RESTORE_TRAILER = 'Snapshot-Restore'

    REF_PREFIX = 'refs/snapshots'
    DEFAULT_VARIATION = 'Original'
    DEFAULT_HISTORY_LIMIT = 200

    # Guard against a malformed history sending the walker round forever.
    MAX_WALK = 10_000

    GITIGNORE_LINES = [
      '# Added by Snapshot for SketchUp',
      '*.skb',            # SketchUp's own rolling backup
      'AutoSave_*.skp',   # SketchUp's crash-recovery autosave
      '~$*',
      '.DS_Store',
      'Thumbs.db',
      'desktop.ini'
    ].freeze

    GITATTRIBUTES_LINES = [
      '# Added by Snapshot for SketchUp',
      '*.skp binary',
      '*.skb binary',
      '*.layout binary'
    ].freeze

    attr_reader :file_path, :root, :git_dir, :relative_path, :store

    class << self
      # Find the repository containing +file_path+, or nil if there is none.
      def discover(file_path, git: Git.instance)
        file_path = File.expand_path(file_path)
        dir = File.dirname(file_path)
        return nil unless File.directory?(dir)

        root = enclosing_root(dir)
        return nil if root.nil?

        new(file_path, root, git: git)
      end

      # Create a repository in the model's own folder.
      def init!(file_path, git: Git.instance)
        file_path = File.expand_path(file_path)
        dir = File.dirname(file_path)
        raise RepoError, "Folder does not exist: #{dir}" unless File.directory?(dir)

        existing = discover(file_path, git: git)
        return existing if existing

        git_dir = File.join(dir, '.git')
        FileUtils.mkdir_p(File.join(git_dir, 'objects', 'info'))
        FileUtils.mkdir_p(File.join(git_dir, 'objects', 'pack'))
        FileUtils.mkdir_p(File.join(git_dir, 'refs', 'heads'))
        FileUtils.mkdir_p(File.join(git_dir, 'refs', 'tags'))

        # HEAD has to exist for git to recognise the directory at all. It is
        # pointed at a branch this plugin never writes to, because the plugin
        # keeps its own history under refs/snapshots instead.
        File.write(File.join(git_dir, 'HEAD'), "ref: refs/heads/main\n")
        File.write(File.join(git_dir, 'description'),
                   "SketchUp model history, kept by the Snapshot extension.\n")
        File.write(File.join(git_dir, 'config'), <<~CONFIG)
          [core]
          \trepositoryformatversion = 0
          \tfilemode = false
          \tbare = false
          \tlogallrefupdates = true
          [gc]
          \t# Snapshot reads loose objects directly and cannot read packfiles.
          \t# Running `git gc` by hand is still fine as long as git stays
          \t# installed; this only stops it happening behind your back.
          \tauto = 0
        CONFIG

        repo = new(file_path, dir, git: git)
        repo.write_support_files!
        repo
      end

      # Turn what the user typed into something usable as a git ref.
      #
      # Users will type "Flat roof"; git refuses spaces in ref names. The slug
      # is what git sees; the original text is kept as the label and is what
      # the panel shows.
      def slugify(name)
        slug = name.to_s.strip
        slug = slug.gsub(/[\s~^:?*\[\]\\]+/, '-')
        slug = slug.gsub(/\.\.+/, '-').gsub(/@\{/, '-')
        slug = slug.gsub(%r{\A[-./]+|[-./]+\z}, '')
        slug.gsub(%r{\.lock(?=/|\z)}, '-lock')
      end

      # A ref name git would accept. Mirrors `git check-ref-format --branch`
      # closely enough for names a person would actually type.
      def valid_variation_name?(slug)
        return false if slug.nil? || slug.empty?
        return false if slug.start_with?('-', '/', '.') || slug.end_with?('/', '.', '.lock')
        return false if slug.include?('..') || slug.include?('//') || slug.include?('@{')
        return false if slug =~ /[\x00-\x20\x7f~^:?*\[\]\\]/

        true
      end

      private

      # Walk up looking for .git, the same way git itself does.
      def enclosing_root(dir)
        current = dir
        loop do
          return current if git_dir_at(current)

          parent = File.dirname(current)
          return nil if parent == current # reached the filesystem root

          current = parent
        end
      end

      # @return [String, nil] the .git directory for +dir+, if it is a root
      def git_dir_at(dir)
        candidate = File.join(dir, '.git')
        return candidate if File.directory?(candidate)

        # A linked worktree has a .git *file* pointing elsewhere.
        if File.file?(candidate)
          pointer = File.read(candidate)[/\Agitdir:\s*(.+)\s*\z/m, 1]
          return nil if pointer.nil?

          pointer = pointer.strip
          resolved = File.absolute_path(pointer, dir)
          return resolved if File.directory?(resolved)
        end

        nil
      end
    end

    def initialize(file_path, root, git: Git.instance)
      @file_path = File.expand_path(file_path)
      @root = root
      @git_dir = self.class.send(:git_dir_at, root) || File.join(root, '.git')
      @git = git
      @store = ObjectStore.new(@git_dir, git: git)
      @relative_path = relative_to_root(@file_path)
      @commits = {}
    end

    # --- state ---------------------------------------------------------------

    # True when the current option has no snapshots of this model yet.
    def empty?
      tip_sha.nil? || tip_blob.nil?
    end
    alias unborn? empty?

    def tracked?
      !tip_blob.nil?
    end

    # True when the file on disk differs from the newest snapshot.
    def dirty?
      return false unless File.exist?(file_path)

      recorded = tip_blob
      return true if recorded.nil?

      working_blob_sha != recorded
    end

    def tip_sha
      ref_sha(current_variation) || adopted_tip
    end
    alias head_sha tip_sha

    # A model can already have git history — from someone using git directly,
    # or from a checkout of a shared repository. Showing it beats pretending
    # there is none, so if this plugin has recorded nothing yet, the starting
    # variation reads from whatever HEAD points at.
    #
    # This is a read only. The first snapshot writes refs/snapshots/Original
    # with that commit as its parent, and HEAD is still never touched.
    def adopted_tip
      return nil unless current_variation == DEFAULT_VARIATION

      sha = head_commit_sha
      return nil if sha.nil?

      blob_in_commit(sha) ? sha : nil
    end

    # The snapshot the model is currently showing. Normally the tip, but after
    # a restore the tip is a bookkeeping commit that names the real one.
    def current_snapshot_sha
      tip = tip_sha
      return nil if tip.nil?

      restored_sha(load_commit(tip).message) || tip
    end

    def current_variation
      raw = read_meta_file('HEAD')
      name = raw && raw[%r{\Aref:\s*#{Regexp.escape(REF_PREFIX)}/(.+)\z}m, 1]
      name = name && name.strip
      name && !name.empty? ? name : DEFAULT_VARIATION
    end

    # --- writing -------------------------------------------------------------

    # Record the current state of the model on disk.
    #
    # @return [String] the new commit's sha
    # @raise [NothingToSnapshot] when the file has not changed
    def snapshot!(message)
      message = message.to_s.strip
      raise ArgumentError, 'A snapshot needs a short description.' if message.empty?
      raise RepoError, "The model file has gone missing:\n#{file_path}" unless File.exist?(file_path)

      with_lock do
        blob = store.write_blob_from_file(file_path)
        raise NothingToSnapshot if blob == tip_blob

        sha = commit!(blob: blob, message: message)
        remember_stat(blob)
        sha
      end
    end

    # Switch the model back to how it looked at +sha+.
    #
    # @return [String, nil] the bookkeeping commit, or nil when the model was
    #   already showing that snapshot
    def restore!(sha)
      target = snapshot_for(sha)
      raise RepoError, 'That snapshot could not be found.' if target.nil?

      blob = blob_in_commit(target.sha)
      raise RepoError, 'That snapshot does not contain this file.' if blob.nil?
      return nil if current_snapshot_sha == target.sha

      with_lock do
        store.read_blob_to_file(blob, file_path)
        commit = commit!(
          blob: blob,
          message: "Restored: #{target.subject}\n\n#{RESTORE_TRAILER}: #{target.sha}\n"
        )
        remember_stat(blob)
        commit
      end
    end

    # --- history -------------------------------------------------------------

    # Snapshots the user took, newest first. Restore bookkeeping is left out.
    #
    # @return [Array<Snapshot>]
    def history(limit: DEFAULT_HISTORY_LIMIT)
      tip = tip_sha
      return [] if tip.nil?

      current = current_snapshot_sha
      hidden = hidden_shas
      snapshots = []
      sha = tip
      steps = 0

      while sha && snapshots.length < limit && steps < MAX_WALK
        steps += 1
        commit = load_commit(sha)
        break if commit.nil?

        blob = blob_in_commit(sha)
        parent = commit.parents.first
        parent_blob = parent ? blob_in_commit(parent) : nil

        # Keep the commits that changed this model and were not a restore.
        # Anything else belongs to a different file in a shared repository, or
        # is bookkeeping.
        if blob && blob != parent_blob && restored_sha(commit.message).nil? && !hidden.include?(sha)
          snapshots << to_snapshot(commit, current)
        end

        sha = parent
      end

      snapshots
    end

    # Take a snapshot out of the list.
    #
    # The commit is recorded as hidden rather than removed. Rewriting the chain
    # to drop it would change the id of every snapshot after it, break the
    # markers that restores leave pointing at those ids, and duplicate shared
    # history wherever a variation had branched off. Hiding cannot corrupt
    # anything and leaves the repository valid; the cost, stated plainly in the
    # confirmation the user sees, is that it does not free disk space.
    #
    # @return [Boolean] true when something was hidden
    def hide_snapshot!(sha)
      target = snapshot_for(sha)
      raise RepoError, 'That snapshot could not be found.' if target.nil?

      if target.sha == current_snapshot_sha
        raise RepoError, 'This is the version you are looking at right now. ' \
                         'Open a different one first, then remove this.'
      end

      hidden = hidden_shas
      return false if hidden.include?(target.sha)

      with_lock do
        write_meta_json('hidden.json', (hidden + [target.sha]).uniq)
        @hidden_shas = nil
      end
      true
    end

    # Give a snapshot a different description.
    #
    # Like hiding, this is stored alongside rather than rewritten into the
    # commit: editing a commit message changes its id, and those ids are what
    # restores point at. The original text stays in git.
    #
    # @return [Boolean] true when the description changed
    def rename_snapshot!(sha, label)
      label = label.to_s.strip
      raise ArgumentError, 'A snapshot needs a description.' if label.empty?

      target = snapshot_for(sha)
      raise RepoError, 'That snapshot could not be found.' if target.nil?
      return false if target.subject == label

      original = load_commit(target.sha).message.split("\n").first.to_s.strip
      labels = snapshot_labels

      with_lock do
        # Renaming something back to what it was leaves no override behind.
        if label == original
          labels.delete(target.sha)
        else
          labels[target.sha] = label
        end
        write_meta_json('labels.json', labels)
        @snapshot_labels = nil
      end
      true
    end

    def snapshot_labels
      @snapshot_labels ||= read_meta_json('labels.json')
    end

    # Put a hidden snapshot back in the list. Nothing in the interface calls
    # this yet; it exists because hiding must be reversible for the promise
    # that nothing is destroyed to mean anything.
    def unhide_snapshot!(sha)
      target = snapshot_for(sha)
      return false if target.nil?

      hidden = hidden_shas
      return false unless hidden.include?(target.sha)

      with_lock do
        write_meta_json('hidden.json', hidden - [target.sha])
        @hidden_shas = nil
      end
      true
    end

    def hidden_shas
      @hidden_shas ||= begin
        raw = read_meta_file('hidden.json')
        parsed = raw.nil? || raw.strip.empty? ? [] : JSON.parse(raw)
        parsed.is_a?(Array) ? parsed : []
      rescue JSON::ParserError
        []
      end
    end

    def snapshot_for(sha)
      sha = resolve(sha)
      return nil if sha.nil?

      commit = load_commit(sha)
      return nil if commit.nil?

      to_snapshot(commit, current_snapshot_sha)
    end

    # --- variations -------------------------------------------------------------

    # @return [Array<Variation>]
    def variations
      current = current_variation
      names = ref_names
      names = [DEFAULT_VARIATION] if names.empty?

      names.sort.map do |name|
        sha = ref_sha(name)
        commit = sha && load_commit(sha)
        Variation.new(
          name: name,
          label: variation_label(name),
          short_sha: sha && sha[0, 7],
          time: commit && commit.time,
          current: name == current
        )
      end
    end

    # @return [String] the variation name that was created
    def create_variation!(display_name)
      display_name = display_name.to_s.strip
      slug = self.class.slugify(display_name)
      raise InvalidVariationName, 'Give the variation a name.' if slug.empty?
      unless self.class.valid_variation_name?(slug)
        raise InvalidVariationName, %("#{display_name}" can't be used as a variation name.)
      end
      if ref_names.include?(slug)
        raise InvalidVariationName, %(A variation called "#{slug}" already exists.)
      end

      tip = tip_sha
      raise InvalidVariationName, 'Take a snapshot before creating a variation.' if tip.nil?

      with_lock do
        write_ref(slug, tip)
        set_variation_label(slug, display_name) if display_name != slug
        set_current_variation(slug)
      end
      slug
    end

    # @return [Boolean] true when the model file changed and must be reloaded
    def switch_variation!(name)
      raise InvalidVariationName, %(There is no variation called "#{name}".) unless ref_names.include?(name)

      sha = ref_sha(name)
      blob = sha && blob_in_commit(sha)
      if blob.nil?
        raise RepoError, %("#{variation_label(name)}" doesn't contain this model file, so it can't be opened.)
      end

      before = File.exist?(file_path) ? working_blob_sha : nil

      with_lock do
        set_current_variation(name)
        return false if before == blob

        store.read_blob_to_file(blob, file_path)
        remember_stat(blob)
      end

      true
    end

    def variation_label(name)
      label = variation_labels[name]
      label.to_s.strip.empty? ? name : label.strip
    end

    # --- setup ---------------------------------------------------------------

    # Written for the benefit of anyone who does use git on this folder; the
    # plugin itself does not need them.
    def write_support_files!
      append_missing_lines(File.join(root, '.gitattributes'), GITATTRIBUTES_LINES)
      append_missing_lines(File.join(root, '.gitignore'), GITIGNORE_LINES)
      nil
    end

    # Kept for compatibility with callers; identity is resolved per commit now.
    def ensure_identity!
      identity
    end

    private

    # --- commits -------------------------------------------------------------

    def commit!(blob:, message:)
      parents = [tip_sha].compact
      base_tree = parents.first ? load_commit(parents.first).tree : nil
      tree = update_tree(base_tree, path_parts, blob)
      sha = store.write('commit', commit_payload(tree, parents, message))
      write_ref(current_variation, sha)
      sha
    end

    def commit_payload(tree, parents, message)
      time = Time.now
      stamp = "#{time.to_i} #{time.strftime('%z')}"
      who = identity

      payload = String.new(encoding: Encoding::BINARY)
      payload << "tree #{tree}\n".b
      parents.each { |parent| payload << "parent #{parent}\n".b }
      payload << "author #{who} #{stamp}\n".b
      payload << "committer #{who} #{stamp}\n".b
      payload << "\n".b
      payload << message.b
      payload << "\n".b unless message.end_with?("\n")
      payload
    end

    def load_commit(sha)
      return nil if sha.nil?
      return @commits[sha] if @commits.key?(sha)

      type, payload = store.read(sha)
      return @commits[sha] = nil unless type == 'commit'

      header, message = payload.split("\n\n".b, 2)
      fields = header.to_s.split("\n".b)

      author = fields.find { |line| line.start_with?('author '.b) }.to_s
      matched = author.match(/\Aauthor (.*) <(.*)> (\d+) ([+-]\d{4})\z/)

      @commits[sha] = Commit.new(
        sha: sha,
        tree: fields.find { |line| line.start_with?('tree '.b) }.to_s.split(' ').last,
        parents: fields.select { |line| line.start_with?('parent '.b) }.map { |line| line.split(' ').last },
        author: matched ? matched[1].force_encoding(Encoding::UTF_8) : '',
        time: matched ? iso_time(matched[3].to_i, matched[4]) : nil,
        message: message.to_s.force_encoding(Encoding::UTF_8)
      )
    end

    def to_snapshot(commit, current_sha)
      lines = commit.message.split("\n")
      renamed = snapshot_labels[commit.sha].to_s.strip
      Snapshot.new(
        sha: commit.sha,
        short_sha: commit.sha[0, 7],
        time: commit.time,
        author: commit.author,
        subject: renamed.empty? ? lines.first.to_s.strip : renamed,
        body: commit.message.strip,
        head: commit.sha == current_sha
      )
    end

    # Git stores a unix timestamp plus the offset it was written in. Rebuild
    # the original local time so the panel can show when the user was working,
    # not when a UTC clock said so.
    def iso_time(epoch, zone)
      sign = zone.start_with?('-') ? -1 : 1
      offset = sign * ((zone[1, 2].to_i * 3600) + (zone[3, 2].to_i * 60))
      local = Time.at(epoch + offset).utc
      "#{local.strftime('%Y-%m-%dT%H:%M:%S')}#{zone[0, 3]}:#{zone[3, 2]}"
    end

    def restored_sha(message)
      matched = message.to_s.match(/^#{RESTORE_TRAILER}:\s*([0-9a-f]{7,40})\s*$/)
      matched && matched[1]
    end

    def resolve(sha)
      sha = sha.to_s.strip
      return nil if sha.empty?
      return sha if sha.length == 40 && store.exist?(sha)
      return nil unless sha =~ /\A[0-9a-f]{4,40}\z/

      # Abbreviated ids only ever come from our own UI, so a shallow scan of
      # the matching fan-out directory is enough.
      dir = File.join(git_dir, 'objects', sha[0, 2])
      return nil unless File.directory?(dir)

      rest = sha[2..]
      match = Dir.children(dir).find { |name| name.start_with?(rest) }
      match && "#{sha[0, 2]}#{match}"
    end

    # --- trees ---------------------------------------------------------------

    def path_parts
      @path_parts ||= relative_path.split('/').map(&:b)
    end

    def blob_in_commit(sha)
      commit = load_commit(sha)
      return nil if commit.nil?

      blob_in_tree(commit.tree, path_parts)
    end

    def blob_in_tree(tree_sha, parts)
      return nil if tree_sha.nil?

      entries = tree_entries(tree_sha)
      name = parts.first
      entry = entries.find { |candidate| candidate.name == name }
      return nil if entry.nil?

      if parts.length == 1
        entry.mode == ObjectStore::MODE_DIR ? nil : entry.sha
      else
        entry.mode == ObjectStore::MODE_DIR ? blob_in_tree(entry.sha, parts[1..]) : nil
      end
    end

    def tree_entries(sha)
      @trees ||= {}
      @trees[sha] ||= begin
        type, payload = store.read(sha)
        type == 'tree' ? ObjectStore.parse_tree(payload) : []
      end
    end

    # Rebuild the tree chain down to the model file, keeping everything else in
    # place so a repository holding more than one model stays intact.
    def update_tree(tree_sha, parts, blob_sha)
      entries = tree_sha ? tree_entries(tree_sha).dup : []
      name = parts.first
      entries = entries.reject { |entry| entry.name == name }

      if parts.length == 1
        entries << ObjectStore::Entry.new(ObjectStore::MODE_FILE, name, blob_sha)
      else
        existing = tree_sha ? tree_entries(tree_sha).find { |entry| entry.name == name } : nil
        base = existing && existing.mode == ObjectStore::MODE_DIR ? existing.sha : nil
        entries << ObjectStore::Entry.new(ObjectStore::MODE_DIR, name,
                                          update_tree(base, parts[1..], blob_sha))
      end

      store.write('tree', ObjectStore.build_tree(entries))
    end

    def tip_blob
      tip = tip_sha
      tip && blob_in_commit(tip)
    end

    # --- the working file ----------------------------------------------------

    # Hashing a large model takes real time, so the result is remembered
    # against the file's size and mtime. This is the same trick git plays with
    # its index, and it is what keeps the toolbar's indicator cheap.
    #
    # It also inherits git's "racily clean" hazard: a file rewritten to the
    # same length within the same clock tick as the cache entry looks
    # unchanged, and an edit would be missed. Sub-second mtimes make that
    # unlikely, and re-hashing anything modified around the time the entry was
    # written closes the gap for filesystems that do not provide them.
    def working_blob_sha
      stat = File.stat(file_path)
      cached = stat_cache[relative_path]

      if cached && cached['size'] == stat.size &&
         cached['mtime'] == stat.mtime.to_f &&
         cached['at'].to_f > stat.mtime.to_f + 1
        return cached['blob']
      end

      sha = hash_working_file
      write_stat_cache(stat, sha)
      sha
    end

    def hash_working_file
      digest = Digest::SHA1.new
      digest << "blob #{File.size(file_path)}\0"
      File.open(file_path, 'rb') do |io|
        while (chunk = io.read(ObjectStore::CHUNK))
          digest << chunk
        end
      end
      digest.hexdigest
    end

    def remember_stat(blob)
      write_stat_cache(File.stat(file_path), blob)
    end

    def write_stat_cache(stat, blob)
      cache = stat_cache
      cache[relative_path] = { 'size' => stat.size, 'mtime' => stat.mtime.to_f,
                               'blob' => blob, 'at' => Time.now.to_f }
      @stat_cache = cache
      write_meta_json('stat.json', cache)
    end

    def stat_cache
      @stat_cache ||= read_meta_json('stat.json')
    end

    # --- refs ----------------------------------------------------------------

    def ref_path(name)
      File.join(git_dir, REF_PREFIX, name)
    end

    def ref_sha(name)
      path = ref_path(name)
      if File.file?(path)
        value = File.read(path).strip
        return value if value =~ /\A[0-9a-f]{40}\z/
      end
      packed_refs["#{REF_PREFIX}/#{name}"]
    end

    def write_ref(name, sha)
      path = ref_path(name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "#{sha}\n")
      @packed_refs = nil
      sha
    end

    # Resolve .git/HEAD, which may name a branch or hold a sha outright.
    def head_commit_sha
      raw = File.file?(File.join(git_dir, 'HEAD')) ? File.read(File.join(git_dir, 'HEAD')).strip : nil
      return nil if raw.nil? || raw.empty?
      return raw if raw =~ /\A[0-9a-f]{40}\z/

      ref = raw[/\Aref:\s*(.+)\z/, 1]
      return nil if ref.nil?

      path = File.join(git_dir, ref.strip)
      if File.file?(path)
        value = File.read(path).strip
        return value if value =~ /\A[0-9a-f]{40}\z/
      end
      packed_refs[ref.strip]
    end

    def ref_names
      names = []

      base = File.join(git_dir, REF_PREFIX)
      if File.directory?(base)
        Dir.glob(File.join(base, '**', '*')).each do |path|
          next unless File.file?(path)

          names << path.sub("#{base}/", '')
        end
      end

      packed_refs.each_key do |ref|
        names << ref.sub("#{REF_PREFIX}/", '') if ref.start_with?("#{REF_PREFIX}/")
      end

      names.uniq
    end

    # `git pack-refs` moves loose ref files into a single file. Reading it
    # costs nothing and stops history disappearing after someone runs git gc.
    def packed_refs
      @packed_refs ||= begin
        path = File.join(git_dir, 'packed-refs')
        result = {}
        if File.file?(path)
          File.readlines(path).each do |line|
            next if line.start_with?('#', '^')

            sha, ref = line.strip.split(' ', 2)
            result[ref] = sha if ref && sha =~ /\A[0-9a-f]{40}\z/
          end
        end
        result
      end
    end

    # --- plugin metadata -----------------------------------------------------

    def meta_dir
      File.join(git_dir, 'snapshot')
    end

    def set_current_variation(name)
      write_meta_file('HEAD', "ref: #{REF_PREFIX}/#{name}\n")
    end

    # The file is still called options.json: variations were called options
    # until the name proved to mean "preferences" to everyone who read it, and
    # renaming the file would drop the labels in repositories that already
    # exist. Nothing user-facing reads it.
    def variation_labels
      @variation_labels ||= read_meta_json('options.json')
    end

    def set_variation_label(name, label)
      labels = variation_labels
      labels[name] = label
      @variation_labels = labels
      write_meta_json('options.json', labels)
    end

    def read_meta_file(name)
      path = File.join(meta_dir, name)
      File.file?(path) ? File.read(path) : nil
    end

    def write_meta_file(name, content)
      FileUtils.mkdir_p(meta_dir)
      File.write(File.join(meta_dir, name), content)
    end

    def read_meta_json(name)
      raw = read_meta_file(name)
      return {} if raw.nil? || raw.strip.empty?

      parsed = JSON.parse(raw)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    def write_meta_json(name, data)
      write_meta_file(name, JSON.generate(data))
    end

    # --- odds and ends -------------------------------------------------------

    # Two SketchUp windows can have the same folder open. The lock only covers
    # the moment a ref moves, which is the only step where interleaving would
    # lose a snapshot.
    def with_lock
      FileUtils.mkdir_p(meta_dir)
      handle = File.open(File.join(meta_dir, 'lock'), File::RDWR | File::CREAT)
      handle.flock(File::LOCK_EX)
      yield
    ensure
      if handle
        handle.flock(File::LOCK_UN)
        handle.close
      end
    end

    # Use the identity git would use, when the user has configured one, so
    # commits do not look like they came from nowhere.
    def identity
      @identity ||= begin
        name = git_config_value('name') || ENV['USER'] || ENV['USERNAME']
        email = git_config_value('email')
        name = 'SketchUp User' if name.nil? || name.strip.empty?
        email = 'snapshot@localhost' if email.nil? || email.strip.empty?
        "#{sanitise_identity(name)} <#{sanitise_identity(email)}>"
      end
    end

    # A minimal read of ~/.gitconfig. Not a full INI parser — it only has to
    # recognise user.name and user.email in a file git itself wrote.
    def git_config_value(key)
      path = File.join(Dir.home, '.gitconfig')
      return nil unless File.file?(path)

      section = nil
      File.readlines(path).each do |line|
        line = line.strip
        next if line.empty? || line.start_with?('#', ';')

        if (header = line[/\A\[([^\]\s]+)/, 1])
          section = header.downcase
          next
        end

        next unless section == 'user'

        found = line[/\A#{key}\s*=\s*(.+)\z/, 1]
        return found.strip.gsub(/\A"|"\z/, '') unless found.nil?
      end
      nil
    rescue StandardError
      nil
    end

    # Newlines and angle brackets would break the commit header's grammar.
    def sanitise_identity(value)
      value.to_s.gsub(/[<>\n\r]/, ' ').strip
    end

    def relative_to_root(path)
      prefix = "#{root}#{File::SEPARATOR}"
      relative = path.start_with?(prefix) ? path[prefix.length..] : File.basename(path)
      relative.tr('\\', '/')
    end

    def append_missing_lines(path, lines)
      existing = File.exist?(path) ? File.read(path) : ''
      present = existing.split(/\r?\n/).map(&:strip)
      missing = lines.reject { |line| present.include?(line.strip) }
      return if missing.empty?

      File.open(path, 'ab') do |io|
        io.write("\n") unless existing.empty? || existing.end_with?("\n")
        io.write(missing.join("\n"))
        io.write("\n")
      end
    end
  end
end
