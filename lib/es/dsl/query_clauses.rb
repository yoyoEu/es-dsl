# frozen_string_literal: true

module ES
  module DSL
    # Clause-building methods valid in a query/must/should/must_not context (scoring).
    # Included by MustContext in addition to FilterClauses.
    #
    # Methods here are intentionally NOT available in FilterContext so that calling
    # match/knn etc. inside filter {} raises NoMethodError at Ruby level.
    module QueryClauses
      # ── Full-text ─────────────────────────────────────────────────────────────

      def match(field_or_hash, value_or_opts = :__unset__)
        if value_or_opts == :__unset__
          add_clause('match' => normalize_field_hash(field_or_hash))
        else
          val = value_or_opts.is_a?(Hash) ? deep_stringify(value_or_opts) : value_or_opts
          add_clause('match' => { field_or_hash.to_s => val })
        end
      end

      def match_phrase(field_or_hash, value_or_opts = :__unset__)
        if value_or_opts == :__unset__
          add_clause('match_phrase' => normalize_field_hash(field_or_hash))
        else
          val = value_or_opts.is_a?(Hash) ? deep_stringify(value_or_opts) : value_or_opts
          add_clause('match_phrase' => { field_or_hash.to_s => val })
        end
      end

      def match_phrase_prefix(field, value_or_opts = {})
        val = value_or_opts.is_a?(Hash) ? deep_stringify(value_or_opts) : value_or_opts
        add_clause('match_phrase_prefix' => { field.to_s => val })
      end

      def match_all(opts = {})
        add_clause('match_all' => deep_stringify(opts))
      end

      def match_none(opts = {})
        add_clause('match_none' => deep_stringify(opts))
      end

      def multi_match(query, fields:, **opts)
        h = { 'query' => query, 'fields' => fields }
        opts.each { |k, v| h[k.to_s] = v }
        add_clause('multi_match' => h)
      end

      def query_string(query, **opts)
        h = { 'query' => query }
        opts.each { |k, v| h[k.to_s] = v }
        add_clause('query_string' => h)
      end

      def simple_query_string(query, **opts)
        h = { 'query' => query }
        opts.each { |k, v| h[k.to_s] = v }
        add_clause('simple_query_string' => h)
      end

      # ── Vector / specialised ──────────────────────────────────────────────────

      # Inline knn clause inside query {} / must {} blocks.
      # An optional block is evaluated on a KnnBuilder to add filter clauses and options.
      #
      #   query do
      #     knn(:image_embedding, query_vector: vec, k: 10, num_candidates: 15) do
      #       filter { term 'platform', 'instagram' }
      #       filter { by_platform 'instagram' }   # scope
      #     end
      #     match :caption, 'sunset'
      #   end
      def knn(field, query_vector:, k:, num_candidates:, **opts, &block)
        kb = KnnBuilder.new(
          field,
          query_vector:   query_vector,
          k:              k,
          num_candidates: num_candidates,
          model_qf_mod:   @model_qf_mod,
          **opts
        )
        BlockDispatch.call(kb, block)
        add_clause('knn' => kb.to_h)
      end

      def more_like_this(fields:, like:, **opts)
        h = { 'fields' => fields, 'like' => like }
        opts.each { |k, v| h[k.to_s] = v }
        add_clause('more_like_this' => h)
      end

      # ── Compound (scoring) ────────────────────────────────────────────────────

      def dis_max(*queries, tie_breaker: nil)
        h = { 'queries' => queries.map { |q| q.is_a?(Hash) ? q : q.to_h } }
        h['tie_breaker'] = tie_breaker if tie_breaker
        add_clause('dis_max' => h)
      end

      def constant_score(boost: nil, &block)
        cc = FilterContext.new(@model_qf_mod)
        cc.instance_exec(&block) if block_given?
        filter_h = cc.clauses.size == 1 ? clause_h(cc.clauses.first) : { 'bool' => { 'must' => cc.clauses } }
        h = { 'filter' => filter_h }
        h['boost'] = boost if boost
        add_clause('constant_score' => h)
      end

      def boosting(positive:, negative:, negative_boost:)
        add_clause('boosting' => {
          'positive'       => positive.is_a?(Hash) ? positive : positive.to_h,
          'negative'       => negative.is_a?(Hash) ? negative : negative.to_h,
          'negative_boost' => negative_boost
        })
      end

      # Catch-all: any ES query keyword not explicitly defined (e.g. percolate, pinned…)
      def method_missing(name, *args, **opts, &block)
        if name.to_s =~ /\A[a-z][a-z0-9_]*\z/
          payload = args.first || opts
          add_clause(name.to_s => deep_stringify(payload))
        else
          super
        end
      end

      def respond_to_missing?(name, include_private = false)
        name.to_s =~ /\A[a-z][a-z0-9_]*\z/ || super
      end

      private

      def clause_h(c)
        c.is_a?(Hash) ? c : c.to_h
      end
    end
  end
end
