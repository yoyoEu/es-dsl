# frozen_string_literal: true

module ES
  module DSL
    # Include this module in any class to give it Elasticsearch query capabilities.
    #
    #   class Engineer
    #     include ES::DSL::Searchable
    #
    #     index_name 'engineers'
    #
    #     # Optional: custom response class (must inherit DSLResponse)
    #     class Response < ES::DSL::DSLResponse
    #       def active_records = records.select { |r| r['status'] == 'active' }
    #     end
    #
    #     # Optional: dynamic index routing
    #     def self.search_index(criteria = nil)
    #       range = criteria&.date_filter_for(:hire_date)
    #       return "content_#{Date.parse(range['gte']).year}" if range
    #
    #       'engineers'
    #     end
    #   end
    module Searchable
      def self.included(base)
        base.extend(ClassMethods)
        default_index = base.name ? "#{base.name.downcase}s" : 'unknown'
        base.instance_variable_set(:@_es_index_name, default_index)
      end

      module ClassMethods
        # ── Index configuration ───────────────────────────────────────────────

        # Get or set the default index name.
        def index_name(name = nil)
          if name
            @_es_index_name = name.to_s
          else
            @_es_index_name
          end
        end

        # Response class used by all searches on this model.
        # Defaults to MyModel::Response if defined, else DSLResponse.
        def response_class
          return @_response_class if defined?(@_response_class) && @_response_class

          @_response_class = if const_defined?(:Response, false)
            const_get(:Response, false)
          else
            DSLResponse
          end
        end

        # Explicitly set the response class.
        def response_class=(klass)
          @_response_class = klass
        end

        # ── Query entry points ────────────────────────────────────────────────

        # Start building a lazy query. Returns a Criteria (does NOT execute).
        #
        #   Engineer.query { smart_match :first_name, "john" }.from(0).size(10).search
        def query(&block)
          Criteria.new(self).query(&block)
        end

        # Convenience: build a Criteria without any initial query block.
        def criteria
          Criteria.new(self)
        end

        # Start building with filter clauses.
        def filter(&block)
          Criteria.new(self).filter(&block)
        end

        def must(&block)
          Criteria.new(self).must(&block)
        end

        def should(&block)
          Criteria.new(self).should(&block)
        end

        def must_not(&block)
          Criteria.new(self).must_not(&block)
        end

        # Start building with a top-level knn clause.
        def knn(field, query_vector:, k:, num_candidates:, **opts, &block)
          Criteria.new(self).knn(field, query_vector: query_vector, k: k,
                                        num_candidates: num_candidates, **opts, &block)
        end

        # Start building with an aggregation.
        def aggregate(name, raw_hash = nil, &block)
          Criteria.new(self).aggregate(name, raw_hash, &block)
        end

        # Stored agg_scope definitions accessible by AggBuilder method_missing.
        def _agg_scopes
          @_agg_scopes ||= {}
        end

        # Defines a named filter clause callable inside filter/bool/agg blocks.
        # Adds method to the model's QueryFilter module (auto-created if absent).
        def scope(name, &block)
          qf_mod = if const_defined?(:QueryFilter, false)
            const_get(:QueryFilter, false)
          else
            const_set(:QueryFilter, Module.new)
          end
          blk = block
          qf_mod.define_method(name) { |*args| instance_exec(*args, &blk) }
        end

        # Define a reusable named aggregate method.
        #
        # The definition block receives |agg, f| where:
        #   agg = AggAccumulator — build aggregations
        #   f   = FilterCollector — call scopes (e.g. f.active)
        # Both args are optional. Inner blocks capture f via closure.
        #
        # Defines both a class method on the model and registers the scope
        # so AggBuilder#method_missing can embed it as a sub-agg.
        def agg_scope(name, &definition_block)
          _agg_scopes[name.to_sym] = definition_block
          model = self

          define_singleton_method(name) do |*args, **kwargs, &call_block|
            accum = AggAccumulator.new(model)
            f = accum.f
            BlockDispatch.call_scope(definition_block, accum, f, args, kwargs)
            main_ab = accum.last_agg_builder
            BlockDispatch.call(main_ab, call_block, f) if call_block && main_ab
            c = Criteria.new(model)
            accum.to_raw_aggs.each { |agg_name, raw| c.aggregate(agg_name, raw) }
            c
          end
        end

        # Start building with a sort clause. Two forms:
        #
        #   # Field + direction shorthand:
        #   Model.sort(:published_at, :desc).filter { ... }.search
        #
        #   # Block returning a Hash or Array of sort clauses (full ES syntax):
        #   Model.sort { { published_at: { order: :desc }, _score: :desc } }.search
        def sort(field = nil, direction = :asc, &block)
          c = Criteria.new(self)
          if block_given?
            c.sort(&block)
          elsif field
            f = field.to_s
            d = direction.to_s
            c.sort { { f => { 'order' => d } } }
          else
            c
          end
        end

        # ── Index routing ─────────────────────────────────────────────────────

        # Override in your model for dynamic routing.
        # Receives the Criteria so you can inspect query conditions.
        #
        #   def self.search_index(criteria = nil)
        #     range = criteria&.date_filter_for(:published_at)
        #     range ? "content_#{Date.parse(range['gte']).year}" : index_name
        #   end
        #
        # @param criteria [Criteria, nil]
        # @return [String, Array<String>]
        def search_index(_criteria = nil)
          @_es_index_name
        end
      end
    end
  end
end
