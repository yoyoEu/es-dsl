# frozen_string_literal: true

module ES
  module DSL
    # Evaluated inside must {} / should {} / must_not {} blocks.
    #
    # Extends FilterContext with QueryClauses (match, match_phrase, knn, …),
    # so all scoring query keywords are valid here in addition to filter-level ones.
    class MustContext < FilterContext
      include QueryClauses
    end

    # should {} and must_not {} accept the same clause set as must {}.
    ShouldContext  = MustContext
    MustNotContext = MustContext
  end
end
