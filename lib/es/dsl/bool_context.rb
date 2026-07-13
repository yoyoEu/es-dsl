# frozen_string_literal: true

module ES
  module DSL
    # Evaluated inside bool {} blocks.
    # Provides filter / must / should / must_not / minimum_should_match / boost.
    #
    # Each sub-block runs in the appropriate context:
    #   filter    → FilterContext  (term/range/exists/…; no match/knn)
    #   must      → MustContext    (FilterContext + match/match_phrase/knn/…)
    #   should    → ShouldContext  (= MustContext)
    #   must_not  → MustNotContext (= MustContext)
    class BoolContext
      def initialize(model_qf_mod = nil)
        @model_qf_mod         = model_qf_mod
        @filter               = []
        @must                 = []
        @should               = []
        @must_not             = []
        @minimum_should_match = nil
        @boost                = nil
      end

      def filter(clauses = nil, &block)
        if block_given?
          ctx = FilterContext.new(@model_qf_mod)
          block.arity.zero? ? ctx.instance_exec(&block) : block.call(ctx)
          @filter.concat(ctx.clauses)
        elsif clauses
          @filter.concat(clauses)
        end
        self
      end

      def must(clauses = nil, &block)
        if block_given?
          ctx = MustContext.new(@model_qf_mod)
          block.arity.zero? ? ctx.instance_exec(&block) : block.call(ctx)
          @must.concat(ctx.clauses)
        elsif clauses
          @must.concat(clauses)
        end
        self
      end

      def should(clauses = nil, &block)
        if block_given?
          ctx = ShouldContext.new(@model_qf_mod)
          block.arity.zero? ? ctx.instance_exec(&block) : block.call(ctx)
          @should.concat(ctx.clauses)
        elsif clauses
          @should.concat(clauses)
        end
        self
      end

      def must_not(clauses = nil, &block)
        if block_given?
          ctx = MustNotContext.new(@model_qf_mod)
          block.arity.zero? ? ctx.instance_exec(&block) : block.call(ctx)
          @must_not.concat(ctx.clauses)
        elsif clauses
          @must_not.concat(clauses)
        end
        self
      end

      def minimum_should_match(val)
        @minimum_should_match = val
        self
      end

      def boost(val)
        @boost = val
        self
      end

      def to_h
        bool = {}
        bool['filter']               = @filter.map { |c| clause_h(c) }   unless @filter.empty?
        bool['must']                 = unwrap(@must)                       unless @must.empty?
        bool['should']               = @should.map { |c| clause_h(c) }    unless @should.empty?
        bool['must_not']             = unwrap(@must_not)                   unless @must_not.empty?
        bool['minimum_should_match'] = @minimum_should_match               if @minimum_should_match
        bool['boost']                = @boost                              if @boost
        { 'bool' => bool }
      end

      private

      def clause_h(c)
        c.is_a?(Hash) ? c : c.to_h
      end

      def unwrap(arr)
        clauses = arr.map { |c| clause_h(c) }
        clauses.size == 1 ? clauses.first : clauses
      end
    end
  end
end
