# frozen_string_literal: true

require "bundler"
require "fileutils"
require "json"
require "pathname"
require "shellwords"
require "tmpdir"
require "thor"

class Dockhand::Command < Thor
  include Thor::Actions

  desc "install-packages [PACKAGES...]",
    "Install apt packages."
  method_option :buildtime, type: :boolean,
    desc: "Include buildtime packages (e.g. `build-essential`)."
  method_option :gem_buildtime, type: :boolean,
    desc: "Include gem-related buildtime packages (e.g. `libsqlite3-dev` if using SQLite)."
  method_option :gem_runtime, type: :boolean,
    desc: "Include gem-related runtime packages (e.g. `libsqlite3-0` if using SQLite)."
  method_option :clean, type: :boolean,
    desc: "Clean apt cache directories after installing packages."
  def install_packages(*packages)
    packages.concat(essential_buildtime_packages) if options[:buildtime]
    packages.concat(gem_buildtime_packages) if options[:gem_buildtime]
    packages.concat(gem_runtime_packages) if options[:gem_runtime]

    unless packages.empty?
      run "apt-get update -qq"
      run "apt-get install --no-install-recommends --yes", *packages
    end

    FileUtils.rm_rf(["/var/cache/apt", "/var/lib/apt"]) if options[:clean]
  end


  desc "transmute-to-artifacts [PATHS...]",
    "Move files and directories to an artifacts directory, and replace the originals with symlinks."
  method_option :artifacts_dir, default: "/artifacts",
    desc: "The artifacts directory."
  def transmute_to_artifacts(*paths)
    paths.each do |path|
      path = File.expand_path(path)
      artifacts_dir = File.expand_path(options[:artifacts_dir])
      artifacts_subpath = "#{artifacts_dir}/#{path}"

      FileUtils.mkdir_p(File.dirname(artifacts_subpath))
      FileUtils.mv(path, artifacts_subpath)
      FileUtils.ln_s(artifacts_subpath, path)
    end
  end


  desc "install-gems",
    "Install gems with Bundler."
  method_option :clean, type: :boolean,
    desc: "Clean Bundler cache after installing gems."
  def install_gems
    # Support for `BUNDLE_ONLY` was recently added in Bundler 2.4.0, but we can
    # support `BUNDLE_ONLY` for older Bundler versions by converting the value
    # to `BUNDLE_WITHOUT` (and updating `BUNDLE_WITH`).
    #
    # TODO Remove this hack when Bundler >= 2.4.0 is more widespread.
    settings = [:without, :with].to_h { |key| [key, Bundler.settings[key].map(&:to_s)] }
    only = Array(Bundler.settings[:only]).join(":").split(/\W/)
    unless only.empty?
      settings[:without] |= Bundler.definition.groups.map(&:to_s) - only
      settings[:with] &= only
    end

    settings.each do |key, values|
      run "bundle config set --local #{key} #{values.join(":").inspect}"
    end
    run "bundle install", env: { "BUNDLE_FROZEN" => "1" }
    FileUtils.rm_rf("#{Bundler.bundle_path}/cache") if options[:clean]
  end


  desc "install-node",
    "Install Node.js."
  method_option :optional, type: :boolean,
    desc: "Skips install if a .node-version or package.json file is not present."
  method_option :prefix, default: "/usr/local",
    desc: "The destination superdirectory.  Files will be installed in `bin/`, `lib/`, etc."
  def install_node
    version_file = Dir["{.node-version,.nvmrc}"].first

    if !version_file && !package_json.dig("engines", "node")
      return if options[:optional] && !package_json_path
      raise <<~ERROR
        Missing Node.js version from `.node-version`, `.nvmrc`, or `package.json`.

        You can create a version file by running the following command in the same directory as `package.json`:

          $ node --version > .node-version
      ERROR
    end

    Dir.mktmpdir do |tmp|
      installer = "#{tmp}/n"
      get "https://raw.githubusercontent.com/tj/n/HEAD/bin/n", installer
      FileUtils.chmod("a+x", installer)
      run installer, "lts" if !version_file && !which("node")
      run installer, "auto", env: { "N_PREFIX" => options[:prefix] }
    end
  end


  desc "install-node-modules",
    "Install Node.js modules using Yarn, NPM, or PNPM."
  method_option :optional, type: :boolean,
    desc: "Skips install if a `yarn.lock`, `package-lock.json`, or `pnpm-lock.yaml` file is not present."
  def install_node_modules
    lock_file = Dir["{yarn.lock,package-lock.json,pnpm-lock.yaml}"].first

    if !lock_file
      return if options[:optional] && !package_json_path
      raise "Missing Node.js modules lock file (`yarn.lock`, `package-lock.json`, or `pnpm-lock.yaml`)"
    end

    run "npm install --global corepack" unless which("corepack")
    run "corepack enable"

    case lock_file
    when "yarn.lock"
      run "yarn install --frozen-lockfile"
    when "package-lock.json"
      run "npm ci"
    when "pnpm-lock.yaml"
      run "pnpm install --frozen-lockfile"
    end
  end


  desc "prepare-rails-app",
    "Precompile assets, precompile code with Bootsnap, and normalize binstubs."
  method_option :clean, type: :boolean,
    desc: "Clean asset precompilation cache after precompiling."
  def prepare_rails_app
    Pathname.glob("bin/**/*") { |path| normalize_binstub(path) if path.file? }
    run "bundle exec bootsnap precompile --gemfile app/ lib/" if gem?("bootsnap")
    run "bin/rails assets:precompile", env: secret_key_base_dummy if rake_task?("assets:precompile")
    FileUtils.rm_rf("tmp/cache/assets") if options[:clean]
  end


  desc "rails-entrypoint",
    "Entrypoint for a Rails application."
  def rails_entrypoint(*args)
    if File.exist?("bin/docker-entrypoint")
      exec("bin/docker-entrypoint", *args)
    else
      run "bin/rails db:prepare" if /\brails s(erver)?$/.match?(args[0..1].join(" "))
      exec(*args)
    end
  end

  private
    GEM_RUNTIME_PACKAGES = {
      "mysql2" => %w[default-mysql-client],
      "pg" => %w[postgresql-client],
      "ruby-vips" => %w[libvips],
      "sqlite3" => %w[libsqlite3-0],
    }

    GEM_BUILDTIME_PACKAGES = GEM_RUNTIME_PACKAGES.merge(
      "mysql2" => %w[default-libmysqlclient-dev],
      "pg" => %w[libpq-dev],
      "sqlite3" => %w[libsqlite3-dev],
    )

    def essential_buildtime_packages
      %w[build-essential pkg-config git python-is-python3 curl]
    end

    def gem_buildtime_packages
      GEM_BUILDTIME_PACKAGES.slice(*gems).values.flatten
    end

    def gem_runtime_packages
      GEM_RUNTIME_PACKAGES.slice(*gems).values.flatten
    end

    def gems
      @gems ||= Bundler.settings.temporary(frozen: true) do
        Bundler.definition.resolve.for(Bundler.definition.requested_dependencies).map(&:name)
      end
    end

    def gem?(name)
      gems.include?(name)
    end

    def rails_version
      Bundler.definition.specs.find { |spec| spec.name == "rails" }.version.to_s
    end

    def secret_key_base_dummy
      if !ENV["SECRET_KEY_BASE"] && !ENV["RAILS_MASTER_KEY"] && !File.exist?("config/master.key")
        rails_version < "7.1" ? { "SECRET_KEY_BASE" => "1" } : { "SECRET_KEY_BASE_DUMMY" => "1" }
      end
    end

    def rake_task?(name)
      !`rake --tasks '^#{name}$'`.empty?
    end

    def package_json_path
      (@package_json_paths ||= Pathname.glob("{.,*}/package.json")).first
    end

    def package_json
      @package_json ||= package_json_path ? JSON.load_file(package_json_path) : {}
    end

    def normalize_binstub(path)
      path.open("r+") do |file|
        shebang = file.read(2)

        if shebang == "#!"
          shebang << file.gets.chomp!
          if shebang.include?("ruby")
            shebang = "#!/usr/bin/env #{File.basename Thor::Util.ruby_command}"
          end

          content = file.read
          content.delete!("\r")

          file.rewind
          file.truncate(file.write(shebang, "\n", content))
          path.chmod(0755 & ~File.umask)
        end
      end
    end

    def which(bin)
      path = `sh -c 'command -v #{bin}'`
      path unless path.empty?
    end

    def run(*cmd, env: nil)
      cmd[0] = Shellwords.split(cmd[0]) if cmd[0].include?(" ")
      cmd.flatten!
      cmd.compact!
      cmd.unshift(env) if env
      system(*cmd, exception: true)
    end

    def self.exit_on_failure?
      true
    end
end
