# frozen_string_literal: true

# spec/integration/run_all.rb
#
# Runs every integration spec in this directory in a single process, so they
# all share one Elasticsearch container (spec/support/elasticsearch_container.rb)
# instead of each file starting and stopping its own.
#
# Run:
#   bundle exec ruby spec/integration/run_all.rb

Dir[File.join(__dir__, '*_spec.rb')].sort.each { |f| require f }
