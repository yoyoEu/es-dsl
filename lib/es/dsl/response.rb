# frozen_string_literal: true

module ES
  module DSL
    # Wraps the raw Elasticsearch JSON response with a clean interface.
    #
    # Custom response classes: define MyModel::Response inheriting from
    # DSLResponse to add model-specific helpers.
    #
    #   class MyModel
    #     include ES::DSL::Searchable
    #
    #     class Response < ES::DSL::DSLResponse
    #       def active_records
    #         records.select { |r| r['status'] == 'active' }
    #       end
    #     end
    #   end
    #
    # All searches on MyModel will return instances of MyModel::Response.
    # Override `self.response_class` in your model to use a different class.
    class DSLResponse
      attr_reader :raw

      def initialize(raw)
        @raw = raw
      end

      # ── Hits ──────────────────────────────────────────────────────────────

      def hits
        @hits ||= raw.dig('hits', 'hits') || []
      end

      def total
        value = raw.dig('hits', 'total')
        return value.to_i if value.is_a?(Integer)
        return value['value'].to_i if value.is_a?(Hash)

        0
      end

      def sources
        hits.map { |h| h['_source'] }
      end

      # Returns hits as plain Hashes with _id/_index merged into _source.
      def records
        hits.map do |h|
          h['_source'].merge('_id' => h['_id'], '_index' => h['_index'])
        end
      end

      # ── Aggregations ──────────────────────────────────────────────────────

      def aggregations
        raw['aggregations'] || {}
      end

      def agg(name)
        aggregations[name.to_s]
      end

      # ── Pagination ────────────────────────────────────────────────────────

      def empty?
        hits.empty?
      end

      def size
        hits.size
      end

      # Sort value of the last hit, used for search_after PIT pagination.
      def last_sort
        hits.last&.dig('sort')
      end

      # PIT id returned with the response (present during PIT searches).
      def pit_id
        raw['pit_id']
      end

      # ── Misc ──────────────────────────────────────────────────────────────

      def took
        raw['took']
      end

      def timed_out?
        raw['timed_out']
      end

      def scroll_id
        raw['_scroll_id']
      end

      def [](key)
        raw[key.to_s]
      end

      def to_h
        raw
      end

      def inspect
        "#<#{self.class.name} total=#{total} hits=#{size} took=#{took}ms>"
      end
    end
  end
end
