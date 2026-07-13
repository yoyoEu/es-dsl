# frozen_string_literal: true

module ES
  module DSL
    # DSL for building aggregations inside Criteria#aggregate { } blocks.
    #
    # Named aggregation types are methods; unknown types fall through method_missing
    # so every ES aggregation keyword works automatically.
    #
    # Example (DSL block):
    #   .aggregate(:by_platform) { terms field: 'platform', size: 5 }
    #   .aggregate(:status) { |a| a.filters(:active) { term 'status', 'active' } }
    #
    # Example (raw hash — still supported for complex/legacy aggregations):
    #   .aggregate(:dist, { filters: { filters: { ... } } })
    class AggBuilder
      def initialize(name, model_class = nil)
        @name            = name.to_s
        @type            = nil
        @opts            = {}
        @sub_aggs        = {}
        @model_class     = model_class
        @f_ref           = nil
        @filters_buckets = nil
      end

      attr_writer :f_ref

      # ── Common aggregation types (explicit for IDE auto-complete) ─────────────

      def terms(**opts)
        set_agg('terms', deep_stringify(opts))
      end

      def date_histogram(**opts)
        set_agg('date_histogram', deep_stringify(opts))
      end

      def histogram(**opts)
        set_agg('histogram', deep_stringify(opts))
      end

      %w[avg max min sum stats extended_stats value_count cardinality
         top_hits geo_bounds geo_centroid percentiles
         missing sum_bucket min_bucket max_bucket avg_bucket
         bucket_script bucket_selector bucket_sort].each do |metric|
        define_method(metric) { |**opts| set_agg(metric, deep_stringify(opts)) }
      end

      def nested(**opts)
        set_agg('nested', deep_stringify(opts))
      end

      def composite(&block)
        cb = CompositeBuilder.new(@model_class)
        if block_given?
          block.arity == 0 ? cb.instance_exec(&block) : block.call(cb)
        end
        set_agg('composite', cb.to_h)
      end

      def reverse_nested(**opts)
        set_agg('reverse_nested', deep_stringify(opts))
      end

      # ES `filter` aggregation — takes a filter block.
      def filter(&block)
        collector = FilterContext.new(model_qf_mod)
        if block_given?
          block.arity == 0 ? collector.instance_exec(&block) : block.call(collector)
        end
        clause = if collector.clauses.size == 1
          clause_h(collector.clauses.first)
        else
          { 'bool' => { 'must' => collector.clauses.map { |c| clause_h(c) } } }
        end
        set_agg('filter', clause)
      end

      # ES `filters` aggregation — two modes:
      #
      # Old mode (no name): yields a FiltersBuilder (backward compat)
      #   .filters { |f| f.filter(:active) { term 'status', 'active' } }
      #
      # New mode (with name): accumulates named buckets flat
      #   .filters(:active)  { term :status, 'active' }
      #   .filters(:deleted) { term :status, 'deleted' }
      def filters(name = nil, &block)
        if name.nil?
          fb = FiltersBuilder.new(model_qf_mod)
          yield fb if block_given?
          set_agg('filters', { 'filters' => fb.to_h })
        else
          @filters_buckets ||= {}
          collector = FilterContext.new(model_qf_mod)
          if block_given?
            if block.arity == 0
              # Track @f_ref clauses before/after: { f.active } pattern adds to @f_ref
              f_before_count = @f_ref ? @f_ref.clauses.length : 0
              collector.instance_exec(&block)
              if @f_ref && @f_ref.clauses.length > f_before_count
                # New clauses appeared on @f_ref — move them into collector
                delta = @f_ref.clauses.slice!(f_before_count, @f_ref.clauses.length - f_before_count)
                delta.each { |c| collector.clauses << c }
              end
            else
              block.call(collector)
            end
          end
          @filters_buckets[name.to_s] = if collector.clauses.size == 1
            clause_h(collector.clauses.first)
          else
            { 'bool' => { 'must' => collector.clauses.map { |c| clause_h(c) } } }
          end
          set_agg('filters', { 'filters' => @filters_buckets })
        end
      end

      # Sub-aggregations
      def aggs(name, &block)
        ab = AggBuilder.new(name, @model_class)
        ab.f_ref = @f_ref
        if block_given?
          case block.arity
          when 0 then ab.instance_exec(&block)
          when 1 then block.call(ab)
          else        block.call(ab, @f_ref)
          end
        end
        @sub_aggs[name.to_s] = ab.build
        self
      end
      alias aggregate aggs

      # ── Compilation ──────────────────────────────────────────────────────────

      # Returns just the agg body (type + opts + sub-aggs), keyed by type.
      def build
        raise ArgumentError, "No aggregation type set for '#{@name}'" unless @type

        h = { @type => @opts }
        h['aggs'] = @sub_aggs unless @sub_aggs.empty?
        h
      end

      # Returns the full { name => { type => opts } } hash for top-level merging.
      def to_h
        { @name => build }
      end

      # Catch-all: agg_scopes first, then generic ES agg keywords.
      def method_missing(name, *args, **opts, &call_block)
        # Check agg_scopes first
        if @model_class && @model_class.respond_to?(:_agg_scopes)
          defn = @model_class._agg_scopes[name.to_sym]
          if defn
            accum = AggAccumulator.new(@model_class, @f_ref)
            f = @f_ref || accum.f
            case defn.arity
            when 0 then accum.instance_exec(&defn)
            when 1 then defn.call(accum)
            when 2 then defn.call(accum, f)
            else        defn.call(accum, f, *args, **opts)
            end
            main_ab = accum.last_agg_builder
            if call_block && main_ab
              case call_block.arity
              when 0 then main_ab.instance_exec(&call_block)
              when 1 then call_block.call(main_ab)
              else        call_block.call(main_ab, f)
              end
            end
            accum.to_raw_aggs.each { |n, raw| @sub_aggs[n] = raw }
            return self
          end
        end
        # Original behavior
        if name.to_s =~ /\A[a-z][a-z0-9_]*\z/
          payload = args.first || opts
          set_agg(name.to_s, deep_stringify(payload))
        else
          super
        end
      end

      def respond_to_missing?(name, include_private = false)
        if @model_class && @model_class.respond_to?(:_agg_scopes) &&
           @model_class._agg_scopes.key?(name.to_sym)
          return true
        end
        name.to_s =~ /\A[a-z][a-z0-9_]*\z/ || super
      end

      private

      def model_qf_mod
        return nil unless @model_class
        return @model_class::QueryFilter if @model_class.const_defined?(:QueryFilter, false)
        nil
      rescue NameError
        nil
      end

      def set_agg(type, opts)
        @type = type
        @opts = opts
        self
      end

      def clause_h(c)
        c.is_a?(Hash) ? c : c.to_h
      end

      def deep_stringify(obj)
        case obj
        when Hash  then obj.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_stringify(v) }
        when Array then obj.map { |v| deep_stringify(v) }
        else            obj
        end
      end
    end

    # ── AggAccumulator ────────────────────────────────────────────────────────
    # Used by agg_scope definitions (and AggBuilder#method_missing) to accumulate
    # multiple named AggBuilders into a hash of raw agg bodies.
    class AggAccumulator
      attr_reader :f

      def initialize(model_class, f_ref = nil)
        @model_class = model_class
        @f = f_ref || build_f
        @aggs = {}
        @last_ab = nil
      end

      def aggregate(name, &block)
        ab = AggBuilder.new(name.to_s, @model_class)
        ab.f_ref = @f
        if block
          case block.arity
          when 0 then ab.instance_exec(&block)
          when 1 then block.call(ab)
          else        block.call(ab, @f)
          end
        end
        @aggs[name.to_s] = ab
        @last_ab = ab
        ab
      end

      def last_agg_builder
        @last_ab
      end

      def to_raw_aggs
        @aggs.transform_values(&:build)
      end

      def method_missing(name, *args, **kwargs, &call_block)
        scopes = @model_class.respond_to?(:_agg_scopes) ? @model_class._agg_scopes : {}
        defn = scopes[name.to_sym]
        return super unless defn

        pre_keys = @aggs.keys.dup
        case defn.arity
        when 0 then instance_exec(&defn)
        when 1 then defn.call(self)
        when 2 then defn.call(self, @f)
        else        defn.call(self, @f, *args, **kwargs)
        end

        new_abs = @aggs.select { |k, _| !pre_keys.include?(k) }.values
        main_ab = new_abs.last
        @last_ab = main_ab

        if call_block && main_ab
          case call_block.arity
          when 0 then main_ab.instance_exec(&call_block)
          when 1 then call_block.call(main_ab)
          else        call_block.call(main_ab, @f)
          end
        end

        main_ab
      end

      def respond_to_missing?(name, include_all = false)
        scopes = @model_class.respond_to?(:_agg_scopes) ? @model_class._agg_scopes : {}
        scopes.key?(name.to_sym) || super
      end

      private

      def build_f
        qf_mod = @model_class.const_defined?(:QueryFilter, false) ? @model_class::QueryFilter : nil
        FilterContext.new(qf_mod)
      end
    end

    # ── CompositeBuilder ─────────────────────────────────────────────────────
    # Evaluated inside AggBuilder#composite { } blocks.
    # Provides size / sources DSL that maps to the ES composite aggregation body.
    class CompositeBuilder
      def initialize(model_class = nil)
        @model_class = model_class
        @size        = nil
        @sources_builder = CompositeSourcesBuilder.new(model_class)
      end

      def size(n)
        @size = n
        self
      end

      def sources(&block)
        if block_given?
          block.arity == 0 ? @sources_builder.instance_exec(&block) : block.call(@sources_builder)
        end
        self
      end

      def to_h
        h = {}
        h['size']    = @size                        if @size
        h['sources'] = @sources_builder.to_a        unless @sources_builder.empty?
        h
      end
    end

    # ── CompositeSourcesBuilder ───────────────────────────────────────────────
    # Evaluated inside CompositeBuilder#sources { } blocks.
    # Each call appends one { name => { type => opts } } entry to the sources array.
    #
    # Two ways to add a source:
    #   aggregate(:paid) { terms field: 'paid' }   # inline
    #   paid                                        # resolved via agg_scope :paid
    class CompositeSourcesBuilder
      def initialize(model_class = nil)
        @model_class = model_class
        @sources     = []
      end

      def aggregate(name, &block)
        ab = AggBuilder.new(name, @model_class)
        if block_given?
          block.arity == 0 ? ab.instance_exec(&block) : block.call(ab)
        end
        @sources << { name.to_s => ab.build }
        self
      end

      def to_a
        @sources
      end

      def empty?
        @sources.empty?
      end

      def method_missing(name, *args, **opts, &block)
        if @model_class && @model_class.respond_to?(:_agg_scopes)
          defn = @model_class._agg_scopes[name.to_sym]
          if defn
            accum = AggAccumulator.new(@model_class)
            case defn.arity
            when 0 then accum.instance_exec(&defn)
            when 1 then defn.call(accum)
            when 2 then defn.call(accum, accum.f)
            else        defn.call(accum, accum.f, *args)
            end
            accum.to_raw_aggs.each { |n, raw| @sources << { n => raw } }
            return self
          end
        end
        super
      end

      def respond_to_missing?(name, include_private = false)
        (@model_class&.respond_to?(:_agg_scopes) &&
          @model_class._agg_scopes.key?(name.to_sym)) || super
      end
    end

    # ── FiltersBuilder ────────────────────────────────────────────────────────
    # Used inside AggBuilder#filters { } (no-name mode) to define named filter buckets.
    class FiltersBuilder
      def initialize(model_qf_mod = nil)
        @named_filters = {}
        @model_qf_mod  = model_qf_mod
      end

      def filter(name, &block)
        collector = FilterContext.new(@model_qf_mod)
        if block_given?
          block.arity == 0 ? collector.instance_exec(&block) : block.call(collector)
        end
        @named_filters[name.to_s] = if collector.clauses.size == 1
          clause_h(collector.clauses.first)
        else
          { 'bool' => { 'must' => collector.clauses.map { |c| clause_h(c) } } }
        end
        self
      end

      def to_h
        @named_filters
      end

      private

      def clause_h(c)
        c.is_a?(Hash) ? c : c.to_h
      end
    end
  end
end
