# frozen_string_literal: true

module ES
  module DSL
    # Custom DSL helpers mixed into QueryContext (inside query {} blocks).
    #
    # All helpers communicate with the Criteria via @_criteria_ref / @_filter_module
    # which QueryContext sets before instance_exec-ing user blocks.
    #
    # Model-specific helpers are defined in MyModel::QueryFilter and are
    # available in both query {} and filter {} blocks.
    module QueryFilter
      # Two-argument term so `term 'field', value` is consistent in both contexts.
      def term(field, value = :__unset__)
        if value == :__unset__
          super(field)
        else
          super(field, value)
        end
      end

      # One-argument exists so `exists 'field'` works in query blocks.
      def exists(field = :__unset__, opts = {})
        if field == :__unset__
          super()
        else
          super(field)
        end
      end

      # Builds a bool/should that tries phrase match first, then falls back to fuzzy.
      def smart_match(field, value, opts = {})
        fuzziness    = opts.fetch(:fuzziness,    'AUTO')
        boost_phrase = opts.fetch(:boost_phrase, 2)

        bool do
          should { match_phrase(field, { 'query' => value, 'boost' => boost_phrase }) }
          should { match(field, { 'query' => value, 'fuzziness' => fuzziness }) }
          minimum_should_match 1
        end
      end

      # Adds a date range into the non-scoring filter buffer.
      def date_range(field, from: nil, to: nil, format: 'strict_date_optional_time')
        opts = { format: format }
        opts[:gte] = from if from
        opts[:lte] = to   if to
        @_filter_buf&.concat([Query::Range.new(field, opts)])
      end

      # Adds a term/terms filter into the non-scoring filter buffer.
      def filter_terms(field, values)
        values = Array(values)
        clause = values.size == 1 ?
          { 'term'  => { field.to_s => values.first } } :
          { 'terms' => { field.to_s => values } }
        @_filter_buf&.concat([clause])
      end
    end
  end
end
