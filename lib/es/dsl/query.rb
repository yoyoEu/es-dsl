# frozen_string_literal: true

module ES
  module DSL
    # Typed query clause objects.
    # Most clauses are built as raw hashes in ClauseContext / FilterCollector.
    # Query::Range is a typed object so search_index can introspect it:
    #
    #   criteria.bool.filter.find { |f| f.is_a?(Query::Range) && f.field == 'published_at' }
    #
    # It is also hash-compatible so legacy code like `f['range']` and `f.dig(...)` still works.
    module Query
      class Range
        attr_reader :field

        def initialize(field, opts = {})
          @field = field.to_s
          @opts  = opts.transform_keys(&:to_s)
        end

        def gte;    @opts['gte'];    end
        def lte;    @opts['lte'];    end
        def gt;     @opts['gt'];     end
        def lt;     @opts['lt'];     end
        def format; @opts['format']; end

        def to_h
          { 'range' => { @field => @opts } }
        end

        # Hash-compatibility: legacy `f['range']`, `f.key?('range')`, `f.dig(...)` work.
        def [](key)
          to_h[key.to_s]
        end

        def key?(key)
          to_h.key?(key.to_s)
        end

        def dig(*keys)
          to_h.dig(*keys.map(&:to_s))
        end

        def keys
          to_h.keys
        end

        def to_s
          to_h.to_s
        end

        def inspect
          "#<Query::Range field=#{@field} #{@opts.inspect}>"
        end
      end
    end
  end
end
