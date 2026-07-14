# frozen_string_literal: true

module ES
  module DSL
    # Builds a knn clause for either top-level (alongside query) or inline use.
    #
    # Supports filter {} blocks with full scope support:
    #
    #   # Top-level — coexists with query for hybrid search:
    #   Model.knn(:image_embedding, query_vector: vec, k: 10, num_candidates: 15) do
    #     filter { term 'platform', 'instagram' }
    #     filter { by_platform 'instagram' }   # scope
    #     similarity 0.8
    #   end
    #   .query { smart_match :caption, 'sunset' }
    #   .search
    #
    #   # Inline inside query {}:
    #   Model.query do
    #     knn(:image_embedding, query_vector: vec, k: 10, num_candidates: 15) do
    #       filter { term 'status', 'active' }
    #     end
    #     match :caption, 'sunset'
    #   end
    class KnnBuilder
      def initialize(field, query_vector:, k:, num_candidates:, model_qf_mod: nil, **opts)
        @field          = field.to_s
        @query_vector   = query_vector
        @k              = k
        @num_candidates = num_candidates
        @model_qf_mod   = model_qf_mod
        @extra_opts     = opts
        @filter_clauses = []
        @boost          = nil
        @similarity     = nil
        @min_score      = nil
      end

      # Adds filter clauses. Multiple calls accumulate.
      # Block runs in FilterContext — term/range/exists/bool/nested/scopes.
      # match/knn etc. are not available (NoMethodError), same as filter {} elsewhere.
      def filter(&block)
        ctx = FilterContext.new(@model_qf_mod)
        BlockDispatch.call(ctx, block)
        @filter_clauses.concat(ctx.clauses)
        self
      end

      def boost(val)
        @boost = val
        self
      end

      # Minimum similarity score threshold (0.0–1.0 depending on space type).
      def similarity(val)
        @similarity = val
        self
      end

      # Top-level min_score applied when knn is used as a top-level clause.
      # Called with a value inside a block (setter); called without a value by Criteria (getter).
      def min_score(val = :__unset__)
        return @min_score if val == :__unset__

        @min_score = val
        self
      end

      def to_h
        h = {
          'field'          => @field,
          'query_vector'   => @query_vector,
          'k'              => @k,
          'num_candidates' => @num_candidates
        }
        @extra_opts.each { |k, v| h[k.to_s] = v }

        unless @filter_clauses.empty?
          clauses = @filter_clauses.map { |c| c.is_a?(Hash) ? c : c.to_h }
          h['filter'] = clauses.size == 1 ? clauses.first : { 'bool' => { 'filter' => clauses } }
        end

        h['boost']      = @boost      if @boost
        h['similarity'] = @similarity if @similarity

        h
      end
    end
  end
end
