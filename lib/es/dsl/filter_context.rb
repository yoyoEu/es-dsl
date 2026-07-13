# frozen_string_literal: true

module ES
  module DSL
    # Evaluated inside filter {} blocks.
    #
    # Includes only FilterClauses (term, terms, range, exists, bool, nested, …).
    # Full-text query clauses (match, match_phrase, knn, …) are intentionally absent —
    # calling them here raises NoMethodError, catching the mistake at Ruby level.
    #
    # Scope methods (from model's QueryFilter module) are injected via extend at
    # initialization, matching the pattern established by the old FilterCollector.
    class FilterContext
      include FilterClauses

      attr_reader :clauses

      def initialize(model_qf_mod = nil)
        @clauses      = []
        @model_qf_mod = model_qf_mod
        extend(model_qf_mod) if model_qf_mod
      end

      def add_clause(clause)
        @clauses << clause
        self
      end
    end
  end
end
