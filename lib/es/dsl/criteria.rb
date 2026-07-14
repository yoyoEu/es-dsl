# frozen_string_literal: true

module ES
  module DSL
    # Lazy query builder. Every DSL method returns `self` so calls chain freely.
    # The actual HTTP request is deferred until #search or #search_pit is called.
    #
    # Two complementary APIs:
    #
    # Old (block-based) — backwards-compatible:
    #   Engineer.query  { smart_match :first_name, "john" }
    #           .query  { date_range :hire_date, from: "2025-01-01" }
    #           .filter { term 'role', 'backend' }
    #           .from(0).size(20)
    #           .search
    #
    # New (spec.md-style):
    #   q = Engineer.query
    #   q.bool.filter { |f| f.term(:role, 'backend') }
    #   q.bool.must   { |f| f.match(:first_name, 'john') }
    #   q.aggregate(:status) { |a| a.filters { |f| f.filter(:active) { term 'status', 'active' } } }
    #   q.search
    class Criteria
      # ── Construction ─────────────────────────────────────────────────────────

      def initialize(model_class)
        @model_class      = model_class
        @query_blocks     = []
        @filter_clauses   = []   # → query.bool.filter
        @must_clauses     = []   # → query.bool.must   (from new API)
        @should_clauses   = []   # → query.bool.should (from new API)
        @must_not_clauses = []   # → query.bool.must_not (from new API)
        @minimum_should_match = nil
        @knn_builder      = nil  # → top-level knn (alongside query)
        @sort_blocks      = []
        @agg_blocks       = {}
        @raw_agg_hashes   = {}
        @highlight_block  = nil
        @from_value       = nil
        @size_value       = nil
        @source_fields    = nil
        @track_total_hits = nil
        @script_fields    = nil
      end

      # ── DSL Builders ─────────────────────────────────────────────────────────

      # Accumulate a query block. Multiple calls are merged inside bool/must.
      # The block runs with all ClauseContext methods + QueryFilter helpers +
      # any model-specific MyModel::QueryFilter helpers available.
      def query(&block)
        reset_compiled!
        @query_blocks << block if block_given?
        self
      end

      # New spec.md style: criteria.bool.filter { |f| ... }
      # Returns a BoolBuilder attached to this Criteria.
      def bool
        @bool_builder ||= BoolBuilder.new(self)
      end

      # Top-level knn clause (coexists with query for hybrid search).
      # The block is evaluated on a KnnBuilder — call filter {} inside to add
      # filter clauses (scopes are available there too).
      #
      #   Model.knn(:image_embedding, query_vector: vec, k: 10, num_candidates: 15) do
      #     filter { term 'platform', 'instagram' }
      #     filter { by_platform 'instagram' }
      #     similarity 0.8
      #   end.query { smart_match :caption, 'sunset' }.search
      def knn(field, query_vector:, k:, num_candidates:, **opts, &block)
        reset_compiled!
        @knn_builder = KnnBuilder.new(
          field,
          query_vector:   query_vector,
          k:              k,
          num_candidates: num_candidates,
          model_qf_mod:   model_filter_module,
          **opts
        )
        BlockDispatch.call(@knn_builder, block)
        self
      end

      # Accumulate filter clauses from a block (top-level Criteria API).
      # Each method call in the block adds one entry to query.bool.filter.
      def filter(&block)
        reset_compiled!
        if block_given?
          ctx = FilterContext.new(model_filter_module)
          BlockDispatch.call(ctx, block)
          @filter_clauses.concat(ctx.clauses)
        end
        self
      end

      def must(&block)
        reset_compiled!
        if block_given?
          ctx = MustContext.new(model_filter_module)
          BlockDispatch.call(ctx, block)
          @must_clauses.concat(ctx.clauses)
        end
        self
      end

      def should(&block)
        reset_compiled!
        if block_given?
          ctx = ShouldContext.new(model_filter_module)
          BlockDispatch.call(ctx, block)
          @should_clauses.concat(ctx.clauses)
        end
        self
      end

      def must_not(&block)
        reset_compiled!
        if block_given?
          ctx = MustNotContext.new(model_filter_module)
          BlockDispatch.call(ctx, block)
          @must_not_clauses.concat(ctx.clauses)
        end
        self
      end

      # Accept a DSL block or raw Hash for aggregation.
      def aggregate(name, raw_hash = nil, &block)
        reset_compiled!
        if raw_hash
          @raw_agg_hashes[name] = raw_hash
        elsif block_given?
          @agg_blocks[name] = block
        end
        self
      end

      def sort(&block)
        reset_compiled!
        @sort_blocks << block if block_given?
        self
      end

      def highlight(&block)
        reset_compiled!
        @highlight_block = block if block_given?
        self
      end

      def source(*fields)
        reset_compiled!
        @source_fields = fields.flatten
        self
      end

      def track_total_hits(value = true)
        reset_compiled!
        @track_total_hits = value
        self
      end

      def script_fields(hash)
        reset_compiled!
        @script_fields = deep_stringify(hash)
        self
      end

      def from(value)
        reset_compiled!
        @from_value = value
        self
      end

      def size(value)
        reset_compiled!
        @size_value = value
        self
      end

      # ── Clause accumulation (called by BoolBuilder + QueryContext) ─────────

      def add_filter_clauses(clauses)
        @filter_clauses.concat(clauses)
      end

      def add_must_clauses(clauses)
        reset_compiled!
        @must_clauses.concat(clauses)
      end

      def add_should_clauses(clauses)
        reset_compiled!
        @should_clauses.concat(clauses)
      end

      def add_must_not_clauses(clauses)
        reset_compiled!
        @must_not_clauses.concat(clauses)
      end

      def set_minimum_should_match(val)
        reset_compiled!
        @minimum_should_match = val
      end

      # ── Introspection accessors (for BoolBuilder and search_index) ────────

      def filter_clauses;   @filter_clauses;   end
      def must_clauses;     @must_clauses;     end
      def should_clauses;   @should_clauses;   end
      def must_not_clauses; @must_not_clauses; end

      # Legacy alias for search_index compatibility.
      alias filters filter_clauses

      # Returns the range opts hash for a date field, scanning compiled query.bool.filter
      # and query.bool.must for range clauses — used by search_index for dynamic routing.
      #
      # @return [Hash, nil]  e.g. { "gte" => "2025-01-01", "lte" => "2025-12-31" }
      def date_filter_for(field)
        field = field.to_s
        compiled = to_query

        candidates = [
          *compiled.dig('query', 'bool', 'filter'),
          *compiled.dig('query', 'bool', 'must'),
          *compiled.dig('post_filter', 'bool', 'filter')
        ].compact

        candidates.each do |f|
          # typed Query::Range object
          if f.is_a?(Query::Range) && f.field == field
            return f.to_h.dig('range', field)
          end
          # raw hash
          next unless f.is_a?(Hash)

          range = f.dig('range', field)
          return range if range
        end

        nil
      end

      # ── Execution ────────────────────────────────────────────────────────────

      # Execute a regular search request.
      #
      # @param timeout [Integer, nil]  Per-request timeout override (seconds).
      # @return [DSLResponse] (or model's custom response_class)
      def search(timeout: nil)
        index = @model_class.search_index(self)
        body  = to_query

        raw = ES::DSL.client.search(
          index:   index,
          body:    body,
          timeout: timeout
        )

        build_response(raw)
      end

      # Point-in-Time paginated search.
      #
      # Opens a PIT, issues search_after pages until the block returns falsy
      # (or all docs consumed). Closes the PIT in an ensure block.
      #
      # @param page_size  [Integer]      hits per page (default 1000)
      # @param keep_alive [String]       ES keep-alive interval (default from config)
      # @param timeout    [Integer, nil] per-request timeout
      # @yieldparam response [DSLResponse]  page response
      # @yieldparam total    [Integer]                cumulative hit count so far
      # @return [Array<DSLResponse>]  all pages collected
      #   If no block given, collects ALL pages and returns them.
      def search_pit(page_size: 1000, keep_alive: nil, timeout: nil, &block)
        keep_alive ||= ES::DSL.config.pit_keep_alive
        index        = @model_class.search_index(self)
        base_body    = to_query

        pit_response = ES::DSL.client.create_pit(
          index:      index,
          keep_alive: keep_alive
        )
        pit_id = pit_response['id']

        responses    = []
        search_after = nil
        cumulative   = 0

        begin
          loop do
            body = base_body.merge(
              'size' => page_size,
              'pit'  => { 'id' => pit_id, 'keep_alive' => keep_alive },
              'sort' => (base_body['sort'] || [{ '_shard_doc' => 'asc' }])
            )
            body['search_after'] = search_after if search_after

            raw = ES::DSL.client.search_pit(
              body:    body,
              timeout: timeout,
              params:  {}
            )

            response = build_response(raw)
            pit_id   = response.pit_id || pit_id

            break if response.empty?

            cumulative += response.size
            responses  << response

            break if block && !block.call(response, cumulative)

            search_after = response.last_sort
          end
        ensure
          begin
            ES::DSL.client.delete_pit(pit_id: pit_id)
          rescue StandardError
            # best-effort cleanup
          end
        end

        responses
      end

      # ── Compilation ──────────────────────────────────────────────────────────

      # Compile all accumulated state to a plain Hash with string keys.
      # Result is memoised; reset automatically when state changes.
      def to_query
        @_compiled ||= compile
      end
      alias to_h to_query

      def reset_compiled!
        @_compiled = nil
      end

      def inspect
        "#<#{@model_class.name || 'AnonymousModel'}::Criteria query=#{to_query}>"
      end

      private

      # ── Core compilation ─────────────────────────────────────────────────────

      def compile
        h = build_query_hash

        # Aggregations
        agg_hash = {}
        @agg_blocks.each do |name, blk|
          ab = AggBuilder.new(name, @model_class)
          f = nil
          if blk.arity > 1
            f = FilterContext.new(model_filter_module)
            ab.f_ref = f
          end
          BlockDispatch.call(ab, blk, f)
          agg_hash[name.to_s] = ab.build
        end
        @raw_agg_hashes.each do |name, raw|
          agg_hash[name.to_s] = deep_stringify(raw)
        end
        h['aggregations'] = agg_hash unless agg_hash.empty?

        # Sort — each block should return a Hash or Array of sort clauses
        unless @sort_blocks.empty?
          sort_clauses = @sort_blocks.flat_map { |blk| result = blk.call; result.is_a?(Array) ? result : [result] }.compact
          h['sort'] = sort_clauses unless sort_clauses.empty?
        end

        h['highlight']          = {} if @highlight_block   # placeholder; extend as needed
        h['from']               = @from_value              if @from_value
        h['size']               = @size_value              if @size_value
        h['_source']            = @source_fields           if @source_fields
        h['track_total_hits']   = @track_total_hits        unless @track_total_hits.nil?
        h['script_fields']      = @script_fields           if @script_fields

        if @knn_builder
          h['knn']        = @knn_builder.to_h
          h['min_score']  = @knn_builder.min_score if @knn_builder.min_score
        end

        h
      end

      # Build the `query` portion of the hash.
      def build_query_hash
        # Fresh temp buffer each compilation — query-block side effects
        # (filter {}, date_range, filter_terms) never accumulate across recompilations.
        temp_filter_clauses = []

        all_block_clauses = @query_blocks.flat_map do |blk|
          ctx = QueryContext.new(temp_filter_clauses, model_filter_module)
          ctx.instance_exec(&blk)
          ctx.clauses.map { |c| clause_h(c) }
        end

        filter_h   = (@filter_clauses + temp_filter_clauses).map { |c| clause_h(c) }
        must_h     = @must_clauses.map     { |c| clause_h(c) }
        should_h   = @should_clauses.map   { |c| clause_h(c) }
        must_not_h = @must_not_clauses.map { |c| clause_h(c) }

        has_direct_bool = filter_h.any? || must_h.any? || should_h.any? || must_not_h.any?

        if !has_direct_bool && all_block_clauses.empty?
          return { 'query' => { 'match_all' => {} } }
        end

        if all_block_clauses.size == 1 && !has_direct_bool
          return { 'query' => all_block_clauses.first }
        end

        combined_must = must_h + all_block_clauses
        bool = {}
        bool['filter']   = filter_h                                    unless filter_h.empty?
        bool['must']     = unwrap(combined_must)                       unless combined_must.empty?
        bool['should']   = should_h                                    unless should_h.empty?
        bool['must_not'] = unwrap(must_not_h)                         unless must_not_h.empty?
        bool['minimum_should_match'] = @minimum_should_match          if @minimum_should_match

        { 'query' => { 'bool' => bool } }
      end

      # ── Helpers ──────────────────────────────────────────────────────────────

      # Delegate agg_scope and QueryFilter methods directly on Criteria.
      # Agg scopes take priority; QueryFilter methods add filter clauses.
      def method_missing(name, *args, **kwargs, &block)
        # Agg scopes take priority
        if @model_class.respond_to?(:_agg_scopes) && (defn = @model_class._agg_scopes[name.to_sym])
          accum = AggAccumulator.new(@model_class)
          f = accum.f
          BlockDispatch.call_scope(defn, accum, f, args, kwargs)
          main_ab = accum.last_agg_builder
          BlockDispatch.call(main_ab, block, f) if block && main_ab
          accum.to_raw_aggs.each { |n, raw| aggregate(n, raw) }
          return self
        end

        # QueryFilter methods
        mod = model_filter_module
        if mod && mod.method_defined?(name)
          reset_compiled!
          filter_buf = []
          ctx = QueryContext.new(filter_buf, mod)
          kwargs.empty? ? ctx.public_send(name, *args, &block) : ctx.public_send(name, *args, **kwargs, &block)
          @filter_clauses.concat(ctx.clauses)
          @filter_clauses.concat(filter_buf)
          self
        else
          super
        end
      end

      def respond_to_missing?(name, include_private = false)
        (@model_class.respond_to?(:_agg_scopes) && @model_class._agg_scopes.key?(name.to_sym)) ||
          (model_filter_module&.method_defined?(name)) ||
          super
      end

      def model_filter_module
        @model_class.const_defined?(:QueryFilter, false) ? @model_class::QueryFilter : nil
      rescue NameError
        nil
      end

      def build_response(raw)
        klass = @model_class.respond_to?(:response_class) ? @model_class.response_class : DSLResponse
        klass.new(raw)
      end

      def clause_h(c)
        c.is_a?(Hash) ? c : c.to_h
      end

      def unwrap(arr)
        arr.size == 1 ? arr.first : arr
      end

      def deep_stringify(obj)
        case obj
        when Hash  then obj.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_stringify(v) }
        when Array then obj.map { |v| deep_stringify(v) }
        else            obj
        end
      end
    end
  end
end
