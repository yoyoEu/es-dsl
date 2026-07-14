# frozen_string_literal: true

module ES
  module DSL
    # Shared block-arity dispatch used by every DSL builder context.
    #
    # DSL blocks support two calling styles, chosen by the block's arity:
    #   MockModel.filter { active }        # 0-arity  → instance_exec'd on the receiver
    #   MockModel.filter { |f| f.active }  # 1+-arity → receiver passed as argument(s)
    module BlockDispatch
      module_function

      # Dispatches +block+ against +receiver+. When the block takes more than
      # one argument (e.g. an agg block's `|agg, f|` form), +extra_args+ is
      # forwarded alongside the receiver.
      def call(receiver, block, *extra_args)
        return unless block

        case block.arity
        when 0 then receiver.instance_exec(&block)
        when 1 then block.call(receiver)
        else        block.call(receiver, *extra_args)
        end
      end

      # Dispatches a `scope` / `agg_scope` definition block against +accum+:
      #   0 → instance_exec'd on accum
      #   1 → accum only
      #   2 → accum, f
      #   3+ → accum, f, *args, **kwargs
      def call_scope(defn, accum, f, args = [], kwargs = {})
        case defn.arity
        when 0 then accum.instance_exec(&defn)
        when 1 then defn.call(accum)
        when 2 then defn.call(accum, f)
        else        defn.call(accum, f, *args, **kwargs)
        end
      end
    end
  end
end
