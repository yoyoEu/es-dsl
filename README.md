# es-dsl

Lightweight Elasticsearch ODM (Object-Document Mapper) — pure Ruby.

## Requirements

- Ruby 3.4.3+
- Bundler 4+
- Docker (for integration tests)

## Installation

```bash
bundle install
```

---

## Testing

### Unit tests (no Docker required)

```bash
bundle exec ruby spec/criteria_spec.rb
```

### Integration tests (requires Docker)

Run a single spec file (starts and stops its own container):

```bash
bundle exec ruby spec/integration/engineer_spec.rb
```

Run every integration spec file together, sharing one container (faster once there's more than one spec file):

```bash
bundle exec ruby spec/integration/run_all.rb
```

The first run will automatically pull the `elasticsearch:8.13.4` image (~1GB). Subsequent runs use the cached image.

New integration spec files should `require_relative '../support/elasticsearch_container'` instead of duplicating the container bootstrap — see `spec/integration/engineer_spec.rb` for the pattern.

---

## Docker Installation

### macOS Sonoma (14+)

```bash
brew install --cask docker
open /Applications/Docker.app
```

### macOS Ventura (13) and older

Docker Desktop 4.x does not support macOS 13. Use Colima instead:

```bash
brew install colima docker docker-compose
colima start
```

---

## Troubleshooting

Integration tests shell out to the `docker` CLI directly (not a Ruby Docker client library), so they work the same way on macOS, Linux, and Windows as long as `docker` on your `PATH` can talk to your Docker daemon — verify with `docker info`.

### `Docker is not available — skipping integration tests`

`docker info` failed. Make sure Docker Desktop (or your Docker daemon) is running, then re-run the tests.

### `This software does not run on macOS versions older than Sonoma`

Docker Desktop does not support your macOS version. Use Colima instead (see installation steps above).

### `rbenv: command not found`

rbenv is not loaded in the current shell. Add the following to `~/.zshrc`:

```bash
export PATH="/opt/homebrew/bin:$PATH"
eval "$(/opt/homebrew/bin/rbenv init -)"
```

Then reload:

```bash
source ~/.zshrc
```

### Wrong Ruby version (e.g. system Ruby 2.6)

Once rbenv is set up, pin the project to Ruby 3.4.3:

```bash
rbenv local 3.4.3
ruby --version   # should print 3.4.3
gem install bundler
bundle install
```

---

## Quick Reference

```bash
# 1. Verify Ruby version
ruby --version   # 3.4.3

# 2. Install gems
bundle install

# 3. Run unit tests
bundle exec ruby spec/criteria_spec.rb

# 4. Run integration tests (Docker must be running)
bundle exec ruby spec/integration/engineer_spec.rb
```
