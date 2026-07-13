# frozen_string_literal: true

# spec/integration/engineer_spec.rb
#
# Integration tests against a real Elasticsearch node via Testcontainers.
# Requires Docker to be running.
#
# Run:
#   bundle exec ruby spec/integration/engineer_spec.rb
#
# Skip gracefully if Docker / testcontainers is unavailable.

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)

require 'minitest/autorun'
require 'es/dsl'
require 'date'
require 'json'

# Starts a shared Elasticsearch container via the `docker` CLI (see the file
# for why we shell out instead of using a Docker client gem). Sets ES_URL.
# Only actually starts a container the first time it's required in this
# process — see spec/integration/run_all.rb to share one container across
# multiple integration spec files.
require_relative '../support/elasticsearch_container'

# ── Client configuration ──────────────────────────────────────────────────────

ES::DSL.configure do |c|
  c.url             = ES_URL
  c.log             = false
  c.request_timeout = 30
end

# ── Admin helper (index management — not part of the ODM client) ──────────────

class ESAdmin
  def initialize(base_url)
    @base_url = base_url
  end

  def create_index(name, body)
    request(:put, "/#{name}", body)
  end

  def delete_index(name)
    request(:delete, "/#{name}", nil)
  end

  def index_doc(index, id, body)
    request(:put, "/#{index}/_doc/#{id}", body)
  end

  def refresh(index)
    request(:post, "/#{index}/_refresh", nil)
  end

  def create_alias(name, *indices)
    actions = indices.map { |idx| { add: { index: idx, alias: name } } }
    request(:post, '/_aliases', { actions: actions })
  end

  def refresh_all(*indices)
    indices.each { |idx| refresh(idx) }
  end

  private

  def request(method, path, body)
    uri = URI.parse("#{@base_url}#{path}")
    http = Net::HTTP.new(uri.host, uri.port)

    klass = { put: Net::HTTP::Put, post: Net::HTTP::Post, delete: Net::HTTP::Delete }[method]
    req = klass.new(uri.request_uri)
    req['Content-Type'] = 'application/json'
    req['Accept']       = 'application/json'
    req.body = body.to_json if body

    JSON.parse(http.request(req).body)
  end
end

ADMIN = ESAdmin.new(ES_URL)

# ── Model under test ──────────────────────────────────────────────────────────

class Engineer
  include ES::DSL::Searchable

  index_name 'test_engineers'

  scope :active do
    term 'status', 'active'
  end

  scope :on_ruby do
    term 'skills', 'ruby'
  end

  # Groups documents by department.
  # Add sub-agg scopes via the call-time block: .group_by_department { total_commits }
  agg_scope :group_by_department do |agg|
    agg.aggregate(:group_by_department) do
      terms field: 'department', size: 50
    end
  end

  # Sums commit_count across all matched documents.
  agg_scope :total_commits do |agg|
    agg.aggregate(:total_commits) { sum field: 'commit_count' }
  end

  class Response < ES::DSL::DSLResponse
    # Iterates department buckets and merges the block result into each row.
    # Returns [] if the group_by_department aggregation is absent.
    #
    # Usage (with sub-agg):
    #   response.group_by_department { |b| total_commits(bucket: b) }
    #   # => [{ department: 'platform', count: 2, total_commits: 570 }, ...]
    #
    # Usage (plain):
    #   response.group_by_department
    #   # => [{ department: 'platform', count: 2 }, ...]
    def group_by_department(bucket: nil, &block)
      src = bucket ? bucket.dig('group_by_department', 'buckets')
                   : aggregations.dig('group_by_department', 'buckets')
      return [] unless src

      src.map do |b|
        row = { department: b['key'], count: b['doc_count'] }
        row.merge!(instance_exec(b, &block)) if block_given?
        row
      end
    end

    # Returns { total_commits: value } from a bucket or the top-level aggregation.
    # Designed to be composed inside group_by_department's block.
    #
    # Usage as sub-agg:   total_commits(bucket: b)
    # Usage standalone:   total_commits
    def total_commits(bucket: nil)
      src = bucket || aggregations
      { total_commits: src.dig('total_commits', 'value').to_i }
    end
  end
end

# ── Shared fixtures ───────────────────────────────────────────────────────────

INDEX   = 'test_engineers'
MAPPING = {
  mappings: {
    properties: {
      first_name:   { type: 'text' },
      last_name:    { type: 'text' },
      bio:          { type: 'text' },
      status:       { type: 'keyword' },
      role:         { type: 'keyword' },
      department:   { type: 'keyword' },
      skills:       { type: 'keyword' },
      commit_count: { type: 'integer' },
      hire_date:    { type: 'date' },
      verified:     { type: 'boolean' },
      location: {
        properties: {
          city:    { type: 'keyword' },
          country: { type: 'keyword' }
        }
      },
      certifications: {
        type: 'nested',
        properties: {
          name:   { type: 'keyword' },
          issuer: { type: 'keyword' },
          year:   { type: 'integer' }
        }
      },
      embedding: { type: 'dense_vector', dims: 4, index: true, similarity: 'cosine' }
    }
  }
}.freeze

DOCS = [
  {
    id: 1, first_name: 'John', last_name: 'Doe', status: 'active', role: 'backend',
    department: 'platform', skills: %w[ruby elasticsearch], commit_count: 420,
    hire_date: '2025-03-01', verified: true,
    location: { city: 'Taipei', country: 'Taiwan' },
    bio: 'Backend engineer specializing in Ruby and Elasticsearch.',
    certifications: [{ name: 'AWS Certified Solutions Architect', issuer: 'AWS', year: 2023 }],
    embedding: [0.1, 0.2, 0.3, 0.4]
  },
  {
    id: 2, first_name: 'Jane', last_name: 'Smith', status: 'active', role: 'data',
    department: 'data', skills: %w[python spark], commit_count: 610,
    hire_date: '2025-06-15', verified: true,
    location: { city: 'Tokyo', country: 'Japan' },
    bio: 'Data engineer working on large-scale pipelines.',
    certifications: [],
    embedding: [0.9, 0.8, 0.1, 0.2]
  },
  {
    id: 3, first_name: 'Bob', last_name: 'Jones', status: 'inactive', role: 'backend',
    department: 'platform', skills: %w[ruby kubernetes], commit_count: 150,
    hire_date: '2024-09-10', verified: false,
    location: { city: 'Taipei', country: 'Taiwan' },
    bio: 'Former backend engineer.',
    certifications: [{ name: 'CKA', issuer: 'CNCF', year: 2022 }],
    embedding: [0.15, 0.25, 0.1, 0.5]
  },
  {
    id: 4, first_name: 'Alice', last_name: 'Wong', status: 'active', role: 'mobile',
    department: 'mobile', skills: %w[swift kotlin], commit_count: 900,
    hire_date: '2025-01-20', verified: true,
    location: { city: 'Singapore', country: 'Singapore' },
    bio: 'Mobile engineer building iOS and Android apps.',
    certifications: [{ name: 'Google Associate Android Developer', issuer: 'Google', year: 2024 }],
    embedding: [0.4, 0.3, 0.2, 0.1]
  }
].freeze

# ── Test cases ────────────────────────────────────────────────────────────────

class EngineerIntegrationTest < Minitest::Test
  def setup
    ADMIN.create_index(INDEX, MAPPING)
    DOCS.each { |doc| ADMIN.index_doc(INDEX, doc[:id], doc.reject { |k, _| k == :id }) }
    ADMIN.refresh(INDEX)
  end

  def teardown
    ADMIN.delete_index(INDEX)
  end

  # ── Basic queries ─────────────────────────────────────────────────────────

  def test_match_all
    results = Engineer.criteria.search
    assert_equal 4, results.total
  end

  def test_filter_by_term
    results = Engineer.filter { term 'department', 'platform' }.search
    assert_equal 2, results.total
  end

  def test_must_clause
    results = Engineer.must { term 'department', 'data' }.search
    assert_equal 1, results.total
    assert_equal 'Jane', results.sources.first['first_name']
  end

  def test_must_not_clause
    results = Engineer.must_not { term 'status', 'inactive' }.search
    assert_equal 3, results.total
  end

  def test_should_clause
    results = Engineer
      .should { term 'department', 'platform' }
      .should { term 'department', 'data' }
      .search
    assert results.total >= 3
  end

  # ── Scopes ────────────────────────────────────────────────────────────────

  def test_scope_active
    results = Engineer.filter { active }.search
    assert_equal 3, results.total
  end

  def test_scope_chaining
    results = Engineer.filter { active }.filter { on_ruby }.search
    assert_equal 1, results.total
    assert_equal 'John', results.sources.first['first_name']
  end

  def test_scope_inside_query_block
    results = Engineer.query { filter { active } }.search
    assert_equal 3, results.total
  end

  # ── DSL helpers ───────────────────────────────────────────────────────────

  def test_date_range
    results = Engineer
      .query { date_range :hire_date, from: '2025-01-01', to: '2025-12-31' }
      .search
    assert_equal 3, results.total
  end

  def test_smart_match
    results = Engineer.query { smart_match :first_name, 'john' }.search
    assert results.total >= 1
    assert_includes results.sources.map { |s| s['first_name'] }, 'John'
  end

  def test_filter_terms_multi
    results = Engineer
      .query { filter_terms :skills, %w[ruby swift] }
      .search
    assert_equal 3, results.total
  end

  # ── Boolean field ─────────────────────────────────────────────────────────

  def test_filter_boolean_field
    results = Engineer.filter { term 'verified', true }.search
    assert_equal 3, results.total
    refute_includes results.sources.map { |s| s['first_name'] }, 'Bob'
  end

  # ── Nested field ──────────────────────────────────────────────────────────

  def test_nested_certification_filter
    results = Engineer
      .query { nested('certifications') { term 'certifications.issuer', 'AWS' } }
      .search
    assert_equal 1, results.total
    assert_equal 'John', results.sources.first['first_name']
  end

  # ── knn (vector) search ───────────────────────────────────────────────────

  def test_knn_search_returns_nearest_neighbor_first
    results = Engineer.knn(:embedding, query_vector: [0.1, 0.2, 0.3, 0.4], k: 2, num_candidates: 4).search
    assert results.total >= 1
    assert_equal 'John', results.sources.first['first_name']
  end

  # ── Aggregations ──────────────────────────────────────────────────────────

  def test_terms_aggregation
    results = Engineer.criteria.size(0)
      .aggregate(:by_department) { terms field: 'department' }
      .search

    buckets = results.aggregations.dig('by_department', 'buckets')
    refute_nil buckets
    assert_includes buckets.map { |b| b['key'] }, 'platform'
    assert_includes buckets.map { |b| b['key'] }, 'data'
  end

  def test_avg_aggregation
    results = Engineer.criteria.size(0)
      .aggregate(:avg_commits) { avg field: 'commit_count' }
      .search

    avg_val = results.aggregations.dig('avg_commits', 'value')
    refute_nil avg_val
    assert avg_val > 0
  end

  # ── Agg scopes ────────────────────────────────────────────────────────────

  def test_agg_scope_group_by_department
    # Plain — no sub-aggs
    results = Engineer.criteria.size(0).group_by_department.search

    buckets = results.aggregations.dig('group_by_department', 'buckets')
    refute_nil buckets
    assert_includes buckets.map { |b| b['key'] }, 'platform'
    assert_includes buckets.map { |b| b['key'] }, 'data'
    assert_includes buckets.map { |b| b['key'] }, 'mobile'
  end

  def test_agg_scope_group_by_department_with_total_commits_sub_agg
    # Composed — total_commits embedded per department bucket via call-time block
    results = Engineer.criteria.size(0).group_by_department { total_commits }.search

    buckets = results.aggregations.dig('group_by_department', 'buckets')
    platform = buckets.find { |b| b['key'] == 'platform' }
    assert_equal 570, platform.dig('total_commits', 'value').to_i
  end

  def test_agg_scope_total_commits
    results = Engineer.criteria.size(0).total_commits.search

    total = results.aggregations.dig('total_commits', 'value').to_i
    assert_equal 2080, total
  end

  def test_agg_scope_total_commits_with_filter
    results = Engineer.filter { active }.size(0).total_commits.search

    total = results.aggregations.dig('total_commits', 'value').to_i
    assert_equal 1930, total  # excludes bob jones (inactive, 150)
  end

  def test_response_group_by_department_plain
    results = Engineer.criteria.size(0).group_by_department.search

    assert_instance_of Engineer::Response, results

    rows = results.group_by_department
    assert_equal 3, rows.size
    assert rows.all? { |r| r.key?(:department) && r.key?(:count) }

    platform = rows.find { |r| r[:department] == 'platform' }
    assert_equal 2, platform[:count]
  end

  def test_response_total_commits_by_department
    # Compose agg_scopes at query time; read composed result via response helper
    results = Engineer.criteria.size(0).group_by_department { total_commits }.search

    by_department = results.group_by_department { |b| total_commits(bucket: b) }
    assert_equal 3, by_department.size

    mobile = by_department.find { |r| r[:department] == 'mobile' }
    assert_equal({ department: 'mobile', count: 1, total_commits: 900 }, mobile)

    platform = by_department.find { |r| r[:department] == 'platform' }
    assert_equal({ department: 'platform', count: 2, total_commits: 570 }, platform)
  end

  def test_response_total_commits_standalone
    results = Engineer.criteria.size(0).total_commits.search

    assert_equal({ total_commits: 2080 }, results.total_commits)
  end

  def test_response_group_by_department_returns_empty_without_agg
    results = Engineer.criteria.size(0).search

    assert_equal [], results.group_by_department
  end

  # ── Pagination ────────────────────────────────────────────────────────────

  def test_pagination_no_overlap
    page1 = Engineer.criteria.from(0).size(2).search
    page2 = Engineer.criteria.from(2).size(2).search

    assert_equal 2, page1.size
    assert_equal 2, page2.size
    assert_equal 4, page1.total

    names1 = page1.sources.map { |s| s['first_name'] }
    names2 = page2.sources.map { |s| s['first_name'] }
    assert_empty names1 & names2
  end

  def test_source_fields
    results = Engineer.criteria.source('first_name', 'department').search
    first = results.sources.first
    assert first.key?('first_name')
    assert first.key?('department')
    refute first.key?('commit_count')
  end
end

# ── Routed model ──────────────────────────────────────────────────────────────

class RoutedEngineer
  include ES::DSL::Searchable

  index_name 'test_routed_alias'

  def self.search_index(criteria = nil)
    range = criteria&.date_filter_for(:hire_date)
    return index_name unless range

    gte_year = range['gte'] ? (Date.parse(range['gte']).year rescue nil) : nil
    lte_year = range['lte'] ? (Date.parse(range['lte']).year rescue nil) : nil
    year     = gte_year || lte_year
    return index_name unless year

    # Span multiple years → search alias (all indices)
    return index_name if gte_year && lte_year && gte_year != lte_year

    "test_routed_#{year}"
  end
end

ROUTED_MAPPING = {
  mappings: {
    properties: {
      first_name: { type: 'keyword' },
      hire_date:  { type: 'date' }
    }
  }
}.freeze

# ── Search-index routing tests ────────────────────────────────────────────────

class EngineerRoutingTest < Minitest::Test
  IDX_2025  = 'test_routed_2025'
  IDX_2026  = 'test_routed_2026'
  ALIAS     = 'test_routed_alias'

  def setup
    ADMIN.create_index(IDX_2025, ROUTED_MAPPING)
    ADMIN.create_index(IDX_2026, ROUTED_MAPPING)
    ADMIN.create_alias(ALIAS, IDX_2025, IDX_2026)

    ADMIN.index_doc(IDX_2025, 1, { first_name: 'alice', hire_date: '2025-06-01' })
    ADMIN.index_doc(IDX_2025, 2, { first_name: 'bob',   hire_date: '2025-09-15' })
    ADMIN.index_doc(IDX_2026, 3, { first_name: 'carol', hire_date: '2026-01-10' })
    ADMIN.refresh(IDX_2025)
    ADMIN.refresh(IDX_2026)
  end

  def teardown
    ADMIN.delete_index(IDX_2025)
    ADMIN.delete_index(IDX_2026)
  end

  def test_no_date_filter_searches_alias
    results = RoutedEngineer.criteria.search
    assert_equal 3, results.total
  end

  def test_2025_filter_routes_to_2025_index
    results = RoutedEngineer
      .query { date_range :hire_date, from: '2025-01-01', to: '2025-12-31' }
      .search
    assert_equal 2, results.total
    names = results.sources.map { |s| s['first_name'] }
    assert_includes names, 'alice'
    assert_includes names, 'bob'
    refute_includes names, 'carol'
  end

  def test_2026_filter_routes_to_2026_index
    results = RoutedEngineer
      .query { date_range :hire_date, from: '2026-01-01', to: '2026-12-31' }
      .search
    assert_equal 1, results.total
    assert_equal 'carol', results.sources.first['first_name']
  end

  def test_cross_year_filter_searches_alias
    results = RoutedEngineer
      .query { date_range :hire_date, from: '2025-01-01', to: '2026-12-31' }
      .search
    assert_equal 3, results.total
  end
end

# ── Point-in-Time pagination tests ────────────────────────────────────────────

PIT_INDEX   = 'test_pit_engineers'
PIT_MAPPING = {
  mappings: {
    properties: {
      first_name: { type: 'keyword' },
      seq:        { type: 'integer' }
    }
  }
}.freeze
PIT_TOTAL = 5

class EngineerPitTest < Minitest::Test
  def setup
    ADMIN.create_index(PIT_INDEX, PIT_MAPPING)
    PIT_TOTAL.times do |i|
      ADMIN.index_doc(PIT_INDEX, i + 1, { first_name: "doc_#{i + 1}", seq: i + 1 })
    end
    ADMIN.refresh(PIT_INDEX)
  end

  def teardown
    ADMIN.delete_index(PIT_INDEX)
  end

  def test_search_pit_retrieves_all_docs
    all_names = []
    pages     = 0
    pit_model.criteria.sort { { 'seq' => 'asc' } }.search_pit(page_size: 2) do |response, _total|
      pages += 1
      all_names.concat(response.sources.map { |s| s['first_name'] })
    end

    assert_equal PIT_TOTAL, all_names.size
    assert_equal PIT_TOTAL.times.map { |i| "doc_#{i + 1}" }.sort, all_names.sort
    assert_equal 3, pages  # 2 + 2 + 1
  end

  def test_search_pit_without_block_returns_all_pages
    pages = pit_model.criteria.sort { { 'seq' => 'asc' } }.search_pit(page_size: 2)
    assert_equal 3, pages.size
    assert_equal PIT_TOTAL, pages.sum { |p| p.sources.size }
  end

  def test_search_pit_early_stop
    count = 0
    pit_model.criteria.sort { { 'seq' => 'asc' } }.search_pit(page_size: 2) do |response, _total|
      count += response.sources.size
      false  # stop after first page
    end
    assert_equal 2, count
  end

  private

  def pit_model
    @pit_model ||= Class.new do
      include ES::DSL::Searchable
      index_name PIT_INDEX
    end
  end
end
