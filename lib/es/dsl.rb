require_relative 'dsl/configuration'
require_relative 'dsl/client'
require_relative 'dsl/query'
require_relative 'dsl/filter_clauses'
require_relative 'dsl/query_clauses'
require_relative 'dsl/filter_context'
require_relative 'dsl/must_context'
require_relative 'dsl/bool_context'
require_relative 'dsl/knn_builder'
require_relative 'dsl/query_filter'
require_relative 'dsl/query_context'
require_relative 'dsl/bool_builder'
require_relative 'dsl/agg_builder'
require_relative 'dsl/response'
require_relative 'dsl/criteria'
require_relative 'dsl/searchable'

module ES
  module DSL
    extend Configuration

    class << self
      # Shared HTTP client (lazily built, reset on configure).
      def client
        @client ||= Client.new(config)
      end
    end
  end
end
