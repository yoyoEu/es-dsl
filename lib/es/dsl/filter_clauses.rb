# frozen_string_literal: true

module ES
  module DSL
    # Clause-building methods valid in a filter context (non-scoring).
    # Included by FilterContext and inherited by MustContext/ShouldContext/MustNotContext.
    #
    # Every method calls add_clause(hash), which is implemented by the including class.
    # Nested sub-blocks that require full query capability run inside a MustContext.
    module FilterClauses
      # ── Term-level ────────────────────────────────────────────────────────────

      def term(field, value = :__unset__, opts = {})
        if value == :__unset__
          add_clause('term' => deep_stringify(field))
        else
          add_clause('term' => { field.to_s => value })
        end
      end

      def terms(field, values = :__unset__)
        if values == :__unset__
          add_clause('terms' => deep_stringify(field))
        else
          add_clause('terms' => { field.to_s => Array(values) })
        end
      end

      # Stores a typed Query::Range for introspection (hash-compatible).
      def range(field, opts = {})
        add_clause(Query::Range.new(field, opts))
      end

      def exists(field = :__unset__, opts = {})
        if field == :__unset__
          add_clause('exists' => deep_stringify(opts))
        else
          add_clause('exists' => { 'field' => field.to_s })
        end
      end

      def ids(values)
        add_clause('ids' => { 'values' => Array(values) })
      end

      def prefix(field, value_or_opts)
        val = value_or_opts.is_a?(Hash) ? deep_stringify(value_or_opts) : { 'value' => value_or_opts }
        add_clause('prefix' => { field.to_s => val })
      end

      def wildcard(field, value_or_opts)
        val = value_or_opts.is_a?(Hash) ? deep_stringify(value_or_opts) : { 'value' => value_or_opts }
        add_clause('wildcard' => { field.to_s => val })
      end

      def regexp(field, value_or_opts)
        val = value_or_opts.is_a?(Hash) ? deep_stringify(value_or_opts) : { 'value' => value_or_opts }
        add_clause('regexp' => { field.to_s => val })
      end

      def fuzzy(field, value_or_opts)
        val = value_or_opts.is_a?(Hash) ? deep_stringify(value_or_opts) : { 'value' => value_or_opts }
        add_clause('fuzzy' => { field.to_s => val })
      end

      # ── Compound ──────────────────────────────────────────────────────────────

      def bool(raw = nil, &block)
        if block_given?
          bc = BoolContext.new(@model_qf_mod)
          BlockDispatch.call(bc, block)
          add_clause(bc.to_h)
        else
          add_clause('bool' => deep_stringify(raw || {}))
        end
      end

      # ── Joining ───────────────────────────────────────────────────────────────

      # Inner block runs in MustContext so match/match_phrase are available inside nested.
      def nested(path, &block)
        cc = MustContext.new(@model_qf_mod)
        cc.instance_exec(&block) if block_given?
        query = cc.clauses.size == 1 ? cc.clauses.first : { 'bool' => { 'must' => cc.clauses } }
        add_clause('nested' => { 'path' => path.to_s, 'query' => query })
      end

      def has_child(type, **opts, &block)
        cc = MustContext.new(@model_qf_mod)
        cc.instance_exec(&block) if block_given?
        query = cc.clauses.size == 1 ? cc.clauses.first : { 'bool' => { 'must' => cc.clauses } }
        h = { 'type' => type.to_s, 'query' => query }
        opts.each { |k, v| h[k.to_s] = v }
        add_clause('has_child' => h)
      end

      def has_parent(parent_type, **opts, &block)
        cc = MustContext.new(@model_qf_mod)
        cc.instance_exec(&block) if block_given?
        query = cc.clauses.size == 1 ? cc.clauses.first : { 'bool' => { 'must' => cc.clauses } }
        h = { 'parent_type' => parent_type.to_s, 'query' => query }
        opts.each { |k, v| h[k.to_s] = v }
        add_clause('has_parent' => h)
      end

      # ── Geo ───────────────────────────────────────────────────────────────────

      def geo_distance(field, distance:, **location)
        h = { 'distance' => distance, field.to_s => location.transform_keys(&:to_s) }
        add_clause('geo_distance' => h)
      end

      def geo_bounding_box(field, top_left:, bottom_right:)
        add_clause('geo_bounding_box' => { field.to_s => {
          'top_left'     => top_left,
          'bottom_right' => bottom_right
        } })
      end

      # ── Script ────────────────────────────────────────────────────────────────

      def script(source, params: nil, lang: nil)
        s = { 'source' => source }
        s['params'] = params if params
        s['lang']   = lang   if lang
        add_clause('script' => { 'script' => s })
      end

      # ── Escape hatch ─────────────────────────────────────────────────────────

      def raw(hash)
        add_clause(deep_stringify(hash))
      end

      private

      def deep_stringify(obj)
        case obj
        when Hash  then obj.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_stringify(v) }
        when Array then obj.map { |v| deep_stringify(v) }
        else            obj
        end
      end

      def normalize_field_hash(h)
        h.each_with_object({}) do |(k, v), out|
          out[k.to_s] = v.is_a?(Hash) ? deep_stringify(v) : v
        end
      end
    end
  end
end
