# frozen_string_literal: true

module ES
  module DSL
    # Attached to a Criteria object; exposes the new spec.md-style API:
    #
    #   query = MockModel.query
    #   query.bool.filter { |f| f.term(:status, 'active') }
    #   query.bool.must   { |f| f.match(:name, 'john') }
    #   query.bool.filter   # => array of current filter clauses (for introspection)
    #
    # Methods with a block add clauses and return the Criteria for chaining.
    # Methods without a block return the current clause array for introspection.
    class BoolBuilder
      def initialize(criteria)
        @criteria = criteria
      end

      def filter(&block)
        if block_given?
          ctx = FilterContext.new(model_qf_mod)
          block.arity.zero? ? ctx.instance_exec(&block) : block.call(ctx)
          @criteria.add_filter_clauses(ctx.clauses)
          @criteria
        else
          @criteria.filter_clauses
        end
      end

      def must(&block)
        if block_given?
          ctx = MustContext.new(model_qf_mod)
          block.arity.zero? ? ctx.instance_exec(&block) : block.call(ctx)
          @criteria.add_must_clauses(ctx.clauses)
          @criteria
        else
          @criteria.must_clauses
        end
      end

      def should(&block)
        if block_given?
          ctx = ShouldContext.new(model_qf_mod)
          block.arity.zero? ? ctx.instance_exec(&block) : block.call(ctx)
          @criteria.add_should_clauses(ctx.clauses)
          @criteria
        else
          @criteria.should_clauses
        end
      end

      def must_not(&block)
        if block_given?
          ctx = MustNotContext.new(model_qf_mod)
          block.arity.zero? ? ctx.instance_exec(&block) : block.call(ctx)
          @criteria.add_must_not_clauses(ctx.clauses)
          @criteria
        else
          @criteria.must_not_clauses
        end
      end

      def minimum_should_match(val)
        @criteria.set_minimum_should_match(val)
        @criteria
      end

      private

      def model_qf_mod
        @criteria.send(:model_filter_module)
      end
    end
  end
end
