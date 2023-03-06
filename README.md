# dockhand

`dockhand` is a collection of helper commands that you can run *inside* a Docker
container to set up a Rails application.

  ```console
  $ dockhand --help
  Commands:
    dockhand help [COMMAND]                     # Describe available commands or one specific command.
    dockhand install-gems                       # Install gems with Bundler.
    dockhand install-node                       # Install Node.js.
    dockhand install-node-modules               # Install Node.js modules using Yarn, NPM, or PNPM.
    dockhand install-packages [PACKAGES...]     # Install apt packages.
    dockhand prepare-rails-app                  # Precompile assets, precompile code with Bootsnap, and normalize binstubs.
    dockhand rails-entrypoint                   # Entrypoint for a Rails application.
    dockhand transmute-to-artifacts [PATHS...]  # Move files and directories to an artifacts directory, and replace the originals with symlinks.
  ```


For example, in the following `Dockerfile`:

  ```dockerfile
  FROM ruby:3.2.0-slim

  RUN gem install dockhand

  WORKDIR /rails

  COPY Gemfile Gemfile.lock .
  RUN dockhand install-packages --buildtime --gem-buildtime --gem-runtime --clean \
   && dockhand install-gems --clean

  COPY . .
  RUN dockhand prepare-rails-app --clean

  ENV RAILS_ENV=production
  ENTRYPOINT ["dockhand", "rails-entrypoint"]
  CMD ["bin/rails", "server"]
  EXPOSE 3000
  ```

* `dockhand install-packages ...` installs the apt packages needed for common
  gems in the `Gemfile`, such as `libsqlite3-0` if using the `sqlite3` gem or
  `postgresql-client` if using the `pg` gem.  Then it cleans up the apt cache
  directories so the image won't contain unnecessary files.

* `dockhand install-gems ...` installs the gems specified by `Gemfile.lock`,
  treating the lock file as frozen to ensure reproducible builds.  Then it
  cleans up Bundler's cache so the image won't contain unnecessary files.

* `dockhand prepare-rails-app ...` precompiles code with [`bootsnap`][],
  precompiles assets with a dummy `SECRET_KEY_BASE`, and fixes binstubs in
  `bin/` for Windows users.  Then it cleans up the assets precompilation cache
  so the image won't contain unnecessary files.

  [`bootsnap`]: https://rubygems.org/gems/bootsnap

* `dockhand rails-entrypoint` injects a call to `bin/rails db:prepare` if the
  given command is `bin/rails server` (or an alias thereof).


As another example, the following `Dockerfile` uses a [multi-stage build][] and
precompiles assets using Node.js:

  ```dockerfile
  # Builder stage
  FROM ruby:3.2.0-slim as builder

  RUN gem install dockhand

  WORKDIR /artifacts/rails

  COPY Gemfile Gemfile.lock .
  RUN dockhand install-packages --buildtime --gem-buildtime \
   && dockhand install-gems --clean \
   && dockhand transmute-to-artifacts $GEM_HOME

  COPY .node-version package.json yarn.lock .
  RUN dockhand install-node \
   && dockhand install-node-modules

  COPY . .
  RUN dockhand prepare-rails-app --clean


  # Application stage
  FROM ruby:3.2.0-slim

  RUN gem install dockhand

  WORKDIR /rails

  COPY Gemfile Gemfile.lock .
  RUN dockhand install-packages --gem-runtime --clean

  COPY --from=builder /artifacts /

  ENV RAILS_ENV=production
  ENTRYPOINT ["dockhand", "rails-entrypoint"]
  CMD ["bin/rails", "server"]
  EXPOSE 3000
  ```

* `dockhand transmute-to-artifacts ...` moves `/usr/local/bundle` (`$GEM_HOME`)
  to `/artifacts/usr/local/bundle` and creates a symlink at `/usr/local/bundle`
  that points to `/artifacts/usr/local/bundle`.  This makes it easy to copy gems
  as artifacts from the builder stage to the final application stage, while
  still allowing subsequent commands in the builder stage to use those gems.

* `dockhand install-node` installs the appropriate version of Node.js based on
  `.node-version`.  If you don't provide a `.node-version` file, it will try
  to choose a version based on the `engines.node` value in `package.json`.

* `dockhand install-node-modules` installs Node.js modules specified by
  `yarn.lock`, using the appropriate version of Yarn and treating the lock file
  as frozen to ensure reproducible builds.  It also supports NPM and PNPM lock
  files.

[multi-stage build]: https://docs.docker.com/build/building/multi-stage/


***If you're looking for a more turn-key solution for your application's
`Dockerfile`, including reduced build times using mounted caches, check out
[`railbarge`][] which is built on `dockhand`.***

[`railbarge`]: https://github.com/jonathanhefner/railbarge


## Installation

Install the [`dockhand` gem](https://rubygems.org/gems/dockhand) in your
`Dockerfile`:

  ```dockerfile
  RUN gem install dockhand
  ```


## Contributing

Run `rake test` to run the tests.


## License

[MIT License](LICENSE.txt)
