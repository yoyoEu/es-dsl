# frozen_string_literal: true

# spec/support/elasticsearch_container.rb
#
# Shared Elasticsearch container bootstrap for integration specs. Starts a
# single container via the `docker` CLI the first time this file is required.
# `require`/`require_relative` only evaluate a file once per process, so any
# number of integration spec files can require this and still share exactly
# one container — as long as they run in the same process.
#
# A single `bundle exec ruby spec/integration/some_spec.rb` run is its own
# process, so that file gets its own container. To share one container across
# several spec files, run them together in one process — see run_all.rb.

require 'minitest/autorun'
require 'net/http'
require 'uri'
require 'open3'

ES_IMAGE       = 'elasticsearch:8.13.4'
ES_HOST_PORT   = 9250
ES_URL         = "http://localhost:#{ES_HOST_PORT}"
CONTAINER_NAME = "es-dsl-test-#{Process.pid}"

def docker_available?
  system('docker', 'info', out: File::NULL, err: File::NULL)
end

def wait_for_elasticsearch(url, timeout: 90)
  deadline = Time.now + timeout
  loop do
    begin
      res = Net::HTTP.get_response(URI("#{url}/_cluster/health"))
      return true if res.is_a?(Net::HTTPSuccess)
    rescue StandardError
      # not ready yet — keep polling
    end
    raise "Elasticsearch did not become ready within #{timeout}s" if Time.now > deadline

    sleep 1
  end
end

unless docker_available?
  warn 'Docker is not available — skipping integration tests. Is Docker Desktop running?'
  exit 0
end

puts "Starting Elasticsearch container (#{ES_IMAGE})... (first run pulls the image, ~1GB)"
_out, start_err, start_status = Open3.capture3(
  'docker', 'run', '-d', '--rm',
  '--name', CONTAINER_NAME,
  '-p', "#{ES_HOST_PORT}:9200",
  '-e', 'discovery.type=single-node',
  '-e', 'xpack.security.enabled=false',
  '-e', 'ES_JAVA_OPTS=-Xms512m -Xmx512m',
  ES_IMAGE
)

unless start_status.success?
  warn "Could not start Elasticsearch container: #{start_err}"
  exit 0
end

Minitest.after_run { system('docker', 'stop', CONTAINER_NAME, out: File::NULL, err: File::NULL) }

begin
  wait_for_elasticsearch(ES_URL)
rescue => e
  warn "Elasticsearch did not become ready: #{e.message}"
  system('docker', 'stop', CONTAINER_NAME, out: File::NULL, err: File::NULL)
  exit 0
end
