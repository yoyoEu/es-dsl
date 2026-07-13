# frozen_string_literal: true

# spec/criteria_spec.rb  (minitest)

$LOAD_PATH.unshift File.expand_path('./lib', __dir__)
require 'es/dsl'
require 'minitest/autorun'
require 'date'

class MockEngineer
  include ES::DSL::Searchable
  index_name 'mock_engineers'

  def self.search_index(criteria = nil)
    range = criteria&.date_filter_for(:hire_date)
    if range
      'engineers_2025'
    else
      'engineers_alias'
    end
  end

  # Scopes — add named filter methods to QueryFilter
  scope :active do
    term 'status', 'active'
  end

  scope :inactive do
    term 'status', 'inactive'
  end

  scope :by_role do |role|
    term 'role', role
  end

  scope :commits_gte do |n|
    range 'commit_count', gte: n
  end

  # Model-specific QueryFilter helpers — available in both query {} and filter {} blocks
  module QueryFilter
    def role(value)
      term 'role', value
    end
  end

  # Agg scopes
  agg_scope :group_by_status do |agg, f|
    agg.aggregate(:status) do |status_agg|
      status_agg.filters(:active)   { f.active }
      status_agg.filters(:inactive) { f.inactive }
    end
  end

  agg_scope :group_by_department do |agg|
    agg.aggregate(:departments) do
      terms field: 'department', size: 10
    end
  end

  agg_scope :timeline do |agg|
    agg.aggregate(:timeline) do
      date_histogram field: 'hire_date', calendar_interval: 'month'
    end
  end

  agg_scope :department_with_status do |agg, f|
    agg.group_by_department do |dept_agg|
      dept_agg.group_by_status
    end
  end

  agg_scope :by_role_source do |a|
    a.aggregate(:role) { terms field: 'role' }
  end

  agg_scope :by_status_source do |a|
    a.aggregate(:status_source) { terms field: 'status' }
  end

  agg_scope :by_field do |agg, f, field, size: 10|
    agg.aggregate(:by_field) { terms field: field.to_s, size: size }
  end

  agg_scope :top_by_field do |agg, f, field|
    agg.aggregate(:top) { top_hits size: 3 }
    agg.aggregate(:terms_agg) { terms field: field.to_s }
  end

  # Custom response class
  class Response < ES::DSL::DSLResponse
    def active_records
      records.select { |r| r['status'] == 'active' }
    end
  end
end

class CriteriaTest < Minitest::Test
  # ── query building ──────────────────────────────────────────────────────────

  def test_query_returns_criteria
    c = MockEngineer.query { match_all }
    assert_instance_of ES::DSL::Criteria, c
  end

  def test_chaining_returns_criteria
    c = MockEngineer.query { match_all }.from(0).size(10)
    assert_instance_of ES::DSL::Criteria, c
  end

  def test_compiled_query_contains_match_all
    c = MockEngineer.query { match_all }
    assert_equal({ 'match_all' => {} }, c.to_query['query'])
  end

  # ── smart_match injection ────────────────────────────────────────────────────

  def test_smart_match_builds_bool_should
    c = MockEngineer.query { smart_match :first_name, 'john' }
    q = c.to_query
    bool = q.dig('query', 'bool')
    assert bool, "Expected bool query, got: #{q.inspect}"
    assert_equal 2, bool['should'].size
    types = bool['should'].map { |s| s.keys.first }
    assert_includes types, 'match_phrase'
    assert_includes types, 'match'
  end

  # ── date_range injection ─────────────────────────────────────────────────────

  def test_date_range_builds_filter_range
    c = MockEngineer.query { date_range :hire_date, from: '2025-01-01', to: '2025-12-31' }
    filters = c.to_query.dig('query', 'bool', 'filter')
    assert filters, 'Expected filter context'
    range = filters.find { |f| f['range'] }
    assert range, 'Expected a range filter'
    assert_equal '2025-01-01', range.dig('range', 'hire_date', 'gte')
    assert_equal '2025-12-31', range.dig('range', 'hire_date', 'lte')
  end

  # ── date_filter_for introspection ───────────────────────────────────────────

  def test_date_filter_for_returns_range_hash
    c = MockEngineer.query { date_range :hire_date, from: '2025-01-01' }
    range = c.date_filter_for(:hire_date)
    assert_equal '2025-01-01', range['gte']
  end

  def test_date_filter_for_returns_nil_when_absent
    c = MockEngineer.query { match_all }
    assert_nil c.date_filter_for(:hire_date)
  end

  # ── from / size ──────────────────────────────────────────────────────────────

  def test_from_and_size_appear_in_query
    c = MockEngineer.criteria.from(10).size(5)
    q = c.to_query
    assert_equal 10, q['from']
    assert_equal 5,  q['size']
  end

  # ── default index name ───────────────────────────────────────────────────────

  def test_index_name_default
    assert_equal 'mock_engineers', MockEngineer.index_name
  end

  # ── search_index dynamic routing ─────────────────────────────────────────────

  def test_search_index_routing
    router = build_router
    c_no_date   = router.criteria
    c_with_date = router.query { date_range :hire_date, from: '2025-03-01' }

    assert_equal 'alias_name',   router.search_index(c_no_date)
    assert_equal 'content_2025', router.search_index(c_with_date)
  end

  # ── filter {} block ─────────────────────────────────────────────────────────

  def test_filter_block_adds_bool_filter_clauses
    c = MockEngineer.filter { term 'status', 'active'; term 'role', 'backend' }
    filters = c.to_query.dig('query', 'bool', 'filter')
    assert_instance_of Array, filters
    assert_equal 2, filters.size
    assert_includes filters, { 'term' => { 'status' => 'active' } }
    assert_includes filters, { 'term' => { 'role' => 'backend' } }
  end

  def test_filter_chaining_accumulates_clauses
    c = MockEngineer.filter { term 'status', 'active' }
                    .filter { exists 'first_name' }
    filters = c.to_query.dig('query', 'bool', 'filter')
    assert_equal 2, filters.size
    assert_includes filters, { 'term' => { 'status' => 'active' } }
    assert_includes filters, { 'exists' => { 'field' => 'first_name' } }
  end

  def test_filter_merges_with_query_bool_filter
    c = MockEngineer.query { date_range :hire_date, from: '2025-01-01' }
                    .filter { term 'role', 'backend' }
    filters = c.to_query.dig('query', 'bool', 'filter')
    assert_instance_of Array, filters
    assert filters.any? { |f| f['term'] },  'expected term filter'
    assert filters.any? { |f| f['range'] }, 'expected range filter'
  end

  # ── model-specific QueryFilter helpers ──────────────────────────────────────

  def test_model_query_filter_in_filter_block
    c = MockEngineer.filter { role 'backend' }
    filters = c.to_query.dig('query', 'bool', 'filter')
    assert_includes filters, { 'term' => { 'role' => 'backend' } }
  end

  # ── raw hash aggregate (filters agg type) ───────────────────────────────────

  def test_raw_aggregate_hash
    c = MockEngineer.aggregate(:project_assignment_distribution, {
      filters: {
        filters: {
          assigned:   { exists: { field: 'project_ids' } },
          unassigned: { bool: { must_not: { exists: { field: 'project_ids' } } } }
        }
      },
      aggs: {
        project_ids: { terms: { field: 'project_ids', size: 10 } }
      }
    })

    aggs = c.to_query['aggregations']
    assert aggs, 'expected aggregations key'

    dist = aggs['project_assignment_distribution']
    assert dist, 'expected project_assignment_distribution agg'
    assert dist['filters'], 'expected filters key'
    assert_equal 'project_ids', dist.dig('filters', 'filters', 'assigned', 'exists', 'field')
    assert dist.dig('aggs', 'project_ids', 'terms')
  end

  def test_raw_aggregate_mixed_with_dsl_aggregate
    c = MockEngineer
          .aggregate(:by_role) { terms field: 'role', size: 5 }
          .aggregate(:unassigned, { filters: { filters: { unassigned: { bool: { must_not: { exists: { field: 'project_ids' } } } } } } })

    aggs = c.to_query['aggregations']
    assert aggs['by_role'],    'dsl agg missing'
    assert aggs['unassigned'], 'raw agg missing'
  end

  # ── filter_collector range / bool ────────────────────────────────────────────

  def test_filter_block_with_range
    c = MockEngineer.filter { range 'hire_date', gte: '2025-01-01', lte: '2025-12-31' }
    filters = c.to_query.dig('query', 'bool', 'filter')
    range = filters.find { |f| f['range'] }
    assert range
    assert_equal '2025-01-01', range.dig('range', 'hire_date', 'gte')
  end

  def test_filter_block_with_bool
    c = MockEngineer.filter { bool(must_not: { exists: { field: 'terminated_at' } }) }
    filters = c.to_query.dig('query', 'bool', 'filter')
    bool_clause = filters.find { |f| f['bool'] }
    assert bool_clause
    assert bool_clause.dig('bool', 'must_not', 'exists', 'field')
  end

  # ── new API: query.bool.filter {} ──────────────────────────────────────────

  def test_bool_builder_filter
    q = MockEngineer.criteria
    q.bool.filter { |f| f.term('status', 'active') }
    q.bool.filter { |f| f.term('role', 'backend') }
    filters = q.to_query.dig('query', 'bool', 'filter')
    assert_includes filters, { 'term' => { 'status' => 'active' } }
    assert_includes filters, { 'term' => { 'role' => 'backend' } }
  end

  def test_bool_builder_filter_returns_criteria_for_chaining
    q = MockEngineer.criteria
    result = q.bool.filter { |f| f.term('status', 'active') }
    assert_instance_of ES::DSL::Criteria, result
  end

  def test_bool_builder_filter_introspection
    q = MockEngineer.criteria
    q.bool.filter { |f| f.range('hire_date', gte: '2025-01-01') }
    filters = q.bool.filter   # no block → returns array
    assert_equal 1, filters.size
    assert filters.first.is_a?(ES::DSL::Query::Range)
    assert_equal 'hire_date', filters.first.field
  end

  # ── DSL aggregate with filters ───────────────────────────────────────────────

  def test_dsl_aggregate_filters
    c = MockEngineer.aggregate(:status) do |a|
      a.filters do |f|
        f.filter(:active)   { term 'status', 'active' }
        f.filter(:inactive) { term 'status', 'inactive' }
      end
    end
    aggs = c.to_query['aggregations']
    assert aggs['status']
    assert_equal({ 'term' => { 'status' => 'active' } },   aggs.dig('status', 'filters', 'filters', 'active'))
    assert_equal({ 'term' => { 'status' => 'inactive' } }, aggs.dig('status', 'filters', 'filters', 'inactive'))
  end

  # ── scope macro ──────────────────────────────────────────────────────────────

  def test_scope_adds_method_to_query_filter
    assert MockEngineer::QueryFilter.method_defined?(:active)
    assert MockEngineer::QueryFilter.method_defined?(:inactive)
  end

  def test_scope_usable_in_filter_block_zero_arity
    c = MockEngineer.filter { active }
    filters = c.to_query.dig('query', 'bool', 'filter')
    assert_includes filters, { 'term' => { 'status' => 'active' } }
  end

  def test_scope_usable_in_filter_block_one_arity
    c = MockEngineer.filter { |f| f.active }
    filters = c.to_query.dig('query', 'bool', 'filter')
    assert_includes filters, { 'term' => { 'status' => 'active' } }
  end

  def test_scope_auto_creates_query_filter_module
    model = Class.new do
      include ES::DSL::Searchable
      scope :verified do
        term 'verified', true
      end
    end
    assert model.const_defined?(:QueryFilter, false)
    assert model::QueryFilter.method_defined?(:verified)
  end

  # ── to_h alias ───────────────────────────────────────────────────────────────

  def test_to_h_alias_for_to_query
    c = MockEngineer.filter { active }
    assert_equal c.to_query, c.to_h
  end

  # ── filters(:name) flat API ──────────────────────────────────────────────────

  def test_filters_named_bucket_flat_api
    c = MockEngineer.aggregate(:status) do |agg|
      agg.filters(:active)   { term 'status', 'active' }
      agg.filters(:inactive) { term 'status', 'inactive' }
    end
    aggs = c.to_query['aggregations']
    assert_equal({ 'term' => { 'status' => 'active' } },   aggs.dig('status', 'filters', 'filters', 'active'))
    assert_equal({ 'term' => { 'status' => 'inactive' } }, aggs.dig('status', 'filters', 'filters', 'inactive'))
  end

  def test_filters_named_bucket_with_scope
    c = MockEngineer.aggregate(:status) do |agg, f|
      agg.filters(:active)   { f.active }
      agg.filters(:inactive) { f.inactive }
    end
    aggs = c.to_query['aggregations']
    assert_equal({ 'term' => { 'status' => 'active' } },   aggs.dig('status', 'filters', 'filters', 'active'))
    assert_equal({ 'term' => { 'status' => 'inactive' } }, aggs.dig('status', 'filters', 'filters', 'inactive'))
  end

  # ── bool { should { } } with scopes ─────────────────────────────────────────

  def test_bool_with_should_and_scopes
    c = MockEngineer.filter do
      bool do
        should do
          active
          inactive
        end
        minimum_should_match 1
      end
    end
    filters = c.to_query.dig('query', 'bool', 'filter')
    bool_clause = filters.find { |f| f['bool'] }
    assert bool_clause, 'expected bool clause'
    should_clauses = bool_clause.dig('bool', 'should')
    assert_instance_of Array, should_clauses
    assert_includes should_clauses, { 'term' => { 'status' => 'active' } }
    assert_includes should_clauses, { 'term' => { 'status' => 'inactive' } }
    assert_equal 1, bool_clause.dig('bool', 'minimum_should_match')
  end

  # ── agg_scope ────────────────────────────────────────────────────────────────

  def test_agg_scope_defines_class_method
    assert MockEngineer.respond_to?(:group_by_status)
    assert MockEngineer.respond_to?(:group_by_department)
    assert MockEngineer.respond_to?(:timeline)
  end

  def test_agg_scope_returns_criteria
    c = MockEngineer.group_by_status
    assert_instance_of ES::DSL::Criteria, c
  end

  def test_agg_scope_group_by_status_builds_filters_agg
    aggs = MockEngineer.group_by_status.to_query['aggregations']
    assert aggs.key?('status'), "expected 'status' key"
    assert_equal({ 'term' => { 'status' => 'active' } },   aggs.dig('status', 'filters', 'filters', 'active'))
    assert_equal({ 'term' => { 'status' => 'inactive' } }, aggs.dig('status', 'filters', 'filters', 'inactive'))
  end

  def test_agg_scope_group_by_department_builds_terms_agg
    aggs = MockEngineer.group_by_department.to_query['aggregations']
    assert aggs.key?('departments'), "expected 'departments' key"
    assert_equal({ 'field' => 'department', 'size' => 10 }, aggs.dig('departments', 'terms'))
  end

  def test_agg_scope_timeline_builds_date_histogram
    aggs = MockEngineer.timeline.to_query['aggregations']
    assert aggs.key?('timeline'), "expected 'timeline' key"
    assert_equal 'hire_date', aggs.dig('timeline', 'date_histogram', 'field')
    assert_equal 'month', aggs.dig('timeline', 'date_histogram', 'calendar_interval')
  end

  def test_agg_scope_returns_chainable_criteria
    c = MockEngineer.group_by_department
    assert_instance_of ES::DSL::Criteria, c
    assert_equal 0, c.size(0).to_query['size']
  end

  def test_agg_scope_with_call_time_sub_agg_block
    c = MockEngineer.group_by_status do |agg|
      agg.aggregate(:commit_total) { sum field: 'commit_count' }
    end
    aggs = c.to_query['aggregations']
    assert_equal({ 'term' => { 'status' => 'active' } }, aggs.dig('status', 'filters', 'filters', 'active'))
    assert_equal({ 'field' => 'commit_count' }, aggs.dig('status', 'aggs', 'commit_total', 'sum'))
  end

  def test_agg_scope_sibling_chaining
    aggs = MockEngineer.group_by_department.group_by_status.timeline.to_query['aggregations']
    assert aggs.key?('departments'), "expected 'departments'"
    assert aggs.key?('status'),      "expected 'status'"
    assert aggs.key?('timeline'),    "expected 'timeline'"
  end

  def test_agg_scope_nested_department_with_status
    aggs = MockEngineer.department_with_status.to_query['aggregations']
    assert aggs.key?('departments'), "expected 'departments' key"
    assert_equal({ 'field' => 'department', 'size' => 10 }, aggs.dig('departments', 'terms'))
    assert aggs.dig('departments', 'aggs', 'status'), "expected nested 'status' agg"
    assert_equal(
      { 'term' => { 'status' => 'active' } },
      aggs.dig('departments', 'aggs', 'status', 'filters', 'filters', 'active')
    )
  end

  def test_agg_scope_on_criteria_via_method_missing
    c = MockEngineer.criteria.group_by_status
    assert_instance_of ES::DSL::Criteria, c
    aggs = c.to_query['aggregations']
    assert aggs.key?('status')
  end

  def test_agg_scope_respond_to_on_criteria
    c = MockEngineer.criteria
    assert c.respond_to?(:group_by_status)
  end

  # ── custom response class ────────────────────────────────────────────────────

  def test_custom_response_class_detected
    assert_equal MockEngineer::Response, MockEngineer.response_class
  end

  # ── FilterCollector clause methods ────────────────────────────────────────────

  def test_filter_terms_clause
    c = MockEngineer.filter { terms 'skills', %w[ruby elasticsearch] }
    filters = c.to_query.dig('query', 'bool', 'filter')
    assert_includes filters, { 'terms' => { 'skills' => %w[ruby elasticsearch] } }
  end

  def test_filter_match_clause_raises
    # match is a scoring query clause and must not be used in filter context
    assert_raises(NoMethodError) { MockEngineer.filter { match 'first_name', 'john' } }
  end

  def test_filter_match_phrase_clause_raises
    # match_phrase is a scoring query clause and must not be used in filter context
    assert_raises(NoMethodError) { MockEngineer.filter { match_phrase 'bio', 'backend engineer' } }
  end

  def test_filter_prefix_clause
    c = MockEngineer.filter { prefix 'last_name', 'smi' }
    filters = c.to_query.dig('query', 'bool', 'filter')
    assert_includes filters, { 'prefix' => { 'last_name' => { 'value' => 'smi' } } }
  end

  def test_filter_wildcard_clause
    c = MockEngineer.filter { wildcard 'last_name', 'sm*' }
    filters = c.to_query.dig('query', 'bool', 'filter')
    assert_includes filters, { 'wildcard' => { 'last_name' => { 'value' => 'sm*' } } }
  end

  def test_filter_regexp_clause
    c = MockEngineer.filter { regexp 'role', 'back.*' }
    filters = c.to_query.dig('query', 'bool', 'filter')
    assert_includes filters, { 'regexp' => { 'role' => { 'value' => 'back.*' } } }
  end

  def test_filter_fuzzy_clause
    c = MockEngineer.filter { fuzzy 'last_name', 'Smth' }
    filters = c.to_query.dig('query', 'bool', 'filter')
    assert_includes filters, { 'fuzzy' => { 'last_name' => { 'value' => 'Smth' } } }
  end

  def test_filter_ids_clause
    c = MockEngineer.filter { ids [1, 2, 3] }
    filters = c.to_query.dig('query', 'bool', 'filter')
    assert_includes filters, { 'ids' => { 'values' => [1, 2, 3] } }
  end

  def test_filter_raw_clause
    raw_clause = { 'term' => { 'employee_id' => 'E-1042' } }
    c = MockEngineer.filter { raw(raw_clause) }
    filters = c.to_query.dig('query', 'bool', 'filter')
    assert_includes filters, raw_clause
  end

  def test_filter_script_clause
    c = MockEngineer.filter { script('doc["commit_count"].value > 100') }
    filters = c.to_query.dig('query', 'bool', 'filter')
    assert_includes filters, { 'script' => { 'script' => { 'source' => 'doc["commit_count"].value > 100' } } }
  end

  def test_filter_term_clause_with_boolean_value
    c = MockEngineer.filter { term 'verified', true }
    filters = c.to_query.dig('query', 'bool', 'filter')
    assert_includes filters, { 'term' => { 'verified' => true } }
  end

  # ── has_child / has_parent ───────────────────────────────────────────────────

  def test_filter_has_child_clause
    c = MockEngineer.filter { has_child('review') { term 'status', 'approved' } }
    filters = c.to_query.dig('query', 'bool', 'filter')
    assert_includes filters, { 'has_child' => { 'type' => 'review', 'query' => { 'term' => { 'status' => 'approved' } } } }
  end

  def test_filter_has_parent_clause
    c = MockEngineer.filter { has_parent('department') { term 'status', 'active' } }
    filters = c.to_query.dig('query', 'bool', 'filter')
    assert_includes filters, { 'has_parent' => { 'parent_type' => 'department', 'query' => { 'term' => { 'status' => 'active' } } } }
  end

  # ── Criteria-level must / should / must_not ────────────────────────────────

  def test_criteria_must_single
    c = MockEngineer.must { term 'status', 'active' }
    assert_equal({ 'term' => { 'status' => 'active' } },
                 c.to_query.dig('query', 'bool', 'must'))
  end

  def test_criteria_must_accumulates_multiple
    c = MockEngineer.must { term 'status', 'active' }
                    .must { term 'role', 'backend' }
    must = c.to_query.dig('query', 'bool', 'must')
    assert_instance_of Array, must
    assert_equal 2, must.size
    assert_includes must, { 'term' => { 'status' => 'active' } }
    assert_includes must, { 'term' => { 'role' => 'backend' } }
  end

  def test_criteria_should_multiple
    c = MockEngineer.should { term 'role', 'backend' }
                    .should { term 'role', 'frontend' }
    should_clauses = c.to_query.dig('query', 'bool', 'should')
    assert_instance_of Array, should_clauses
    assert_equal 2, should_clauses.size
    assert_includes should_clauses, { 'term' => { 'role' => 'backend' } }
    assert_includes should_clauses, { 'term' => { 'role' => 'frontend' } }
  end

  def test_criteria_must_not_single
    c = MockEngineer.must_not { term 'status', 'inactive' }
    assert_equal({ 'term' => { 'status' => 'inactive' } },
                 c.to_query.dig('query', 'bool', 'must_not'))
  end

  def test_bool_builder_minimum_should_match
    c = MockEngineer.criteria
    c.bool.should { |f| f.term('role', 'backend') }
    c.bool.should { |f| f.term('role', 'frontend') }
    c.bool.minimum_should_match(1)
    assert_equal 1, c.to_query.dig('query', 'bool', 'minimum_should_match')
  end

  # ── Query context clause methods ───────────────────────────────────────────

  def test_query_terms_clause
    c = MockEngineer.query { terms 'skills', %w[ruby elasticsearch] }
    assert_equal({ 'terms' => { 'skills' => %w[ruby elasticsearch] } },
                 c.to_query['query'])
  end

  def test_query_multi_match_clause
    c = MockEngineer.query { multi_match('john', fields: %w[first_name bio]) }
    q = c.to_query['query']
    assert_equal 'john',              q.dig('multi_match', 'query')
    assert_equal %w[first_name bio],  q.dig('multi_match', 'fields')
  end

  def test_query_string_clause
    c = MockEngineer.query { query_string('john AND smith') }
    assert_equal 'john AND smith', c.to_query.dig('query', 'query_string', 'query')
  end

  def test_query_nested_clause
    c = MockEngineer.query { nested('certifications') { term 'certifications.name', 'aws-certified' } }
    q = c.to_query['query']
    assert_equal 'certifications', q.dig('nested', 'path')
    assert_equal({ 'term' => { 'certifications.name' => 'aws-certified' } }, q.dig('nested', 'query'))
  end

  def test_query_nested_clause_with_match
    c = MockEngineer.query do
      nested('certifications') do
        match 'certifications.name', 'AWS Certified Solutions Architect'
      end
    end
    q = c.to_query['query']
    assert_equal 'certifications', q.dig('nested', 'path')
    assert_equal({ 'match' => { 'certifications.name' => 'AWS Certified Solutions Architect' } }, q.dig('nested', 'query'))
  end

  def test_query_knn_clause
    c = MockEngineer.query { knn('embedding', query_vector: [1.0, 0.5], k: 5, num_candidates: 100) }
    knn = c.to_query.dig('query', 'knn')
    assert_equal 'embedding', knn['field']
    assert_equal 5,   knn['k']
    assert_equal 100, knn['num_candidates']
  end

  # ── Additional scoring query clauses ───────────────────────────────────────

  def test_query_match_phrase_prefix_clause
    c = MockEngineer.query { match_phrase_prefix('bio', 'senior ru') }
    assert_equal({ 'match_phrase_prefix' => { 'bio' => 'senior ru' } }, c.to_query['query'])
  end

  def test_query_match_none_clause
    c = MockEngineer.query { match_none }
    assert_equal({ 'match_none' => {} }, c.to_query['query'])
  end

  def test_query_simple_query_string_clause
    c = MockEngineer.query { simple_query_string('senior +ruby') }
    assert_equal 'senior +ruby', c.to_query.dig('query', 'simple_query_string', 'query')
  end

  def test_query_more_like_this_clause
    c = MockEngineer.query { more_like_this(fields: ['bio'], like: 'ruby backend expert') }
    mlt = c.to_query.dig('query', 'more_like_this')
    assert_equal ['bio'], mlt['fields']
    assert_equal 'ruby backend expert', mlt['like']
  end

  def test_query_dis_max_clause
    c = MockEngineer.query do
      dis_max({ term: { role: 'backend' } }, { term: { role: 'frontend' } }, tie_breaker: 0.3)
    end
    dm = c.to_query.dig('query', 'dis_max')
    assert_equal 0.3, dm['tie_breaker']
    assert_equal [{ term: { role: 'backend' } }, { term: { role: 'frontend' } }], dm['queries']
  end

  def test_query_constant_score_clause
    c = MockEngineer.query { constant_score(boost: 2) { term 'status', 'active' } }
    cs = c.to_query.dig('query', 'constant_score')
    assert_equal 2, cs['boost']
    assert_equal({ 'term' => { 'status' => 'active' } }, cs['filter'])
  end

  def test_query_boosting_clause
    c = MockEngineer.query do
      boosting(
        positive:       { term: { status: 'active' } },
        negative:       { term: { status: 'inactive' } },
        negative_boost: 0.2
      )
    end
    b = c.to_query.dig('query', 'boosting')
    assert_equal({ term: { status: 'active' } },   b['positive'])
    assert_equal({ term: { status: 'inactive' } }, b['negative'])
    assert_equal 0.2, b['negative_boost']
  end

  # ── Aggregate metric methods ───────────────────────────────────────────────

  def test_aggregate_avg
    aggs = MockEngineer.aggregate(:avg_commits) { avg field: 'commit_count' }.to_query['aggregations']
    assert_equal({ 'field' => 'commit_count' }, aggs.dig('avg_commits', 'avg'))
  end

  def test_aggregate_sum
    aggs = MockEngineer.aggregate(:total_prs) { sum field: 'pr_count' }.to_query['aggregations']
    assert_equal({ 'field' => 'pr_count' }, aggs.dig('total_prs', 'sum'))
  end

  def test_aggregate_max
    aggs = MockEngineer.aggregate(:max_points) { max field: 'story_points' }.to_query['aggregations']
    assert_equal({ 'field' => 'story_points' }, aggs.dig('max_points', 'max'))
  end

  def test_aggregate_min
    aggs = MockEngineer.aggregate(:min_points) { min field: 'story_points' }.to_query['aggregations']
    assert_equal({ 'field' => 'story_points' }, aggs.dig('min_points', 'min'))
  end

  def test_aggregate_cardinality
    aggs = MockEngineer.aggregate(:uniq_departments) { cardinality field: 'department' }.to_query['aggregations']
    assert_equal({ 'field' => 'department' }, aggs.dig('uniq_departments', 'cardinality'))
  end

  def test_aggregate_value_count
    aggs = MockEngineer.aggregate(:cnt) { value_count field: 'department' }.to_query['aggregations']
    assert_equal({ 'field' => 'department' }, aggs.dig('cnt', 'value_count'))
  end

  def test_aggregate_missing
    aggs = MockEngineer.aggregate(:no_cert) { missing field: 'certifications' }.to_query['aggregations']
    assert_equal({ 'field' => 'certifications' }, aggs.dig('no_cert', 'missing'))
  end

  def test_aggregate_stats
    aggs = MockEngineer.aggregate(:commit_stats) { stats field: 'commit_count' }.to_query['aggregations']
    assert_equal({ 'field' => 'commit_count' }, aggs.dig('commit_stats', 'stats'))
  end

  def test_aggregate_percentiles
    aggs = MockEngineer.aggregate(:review_latency) { percentiles field: 'review_latency_ms', percents: [50, 95, 99] }
                       .to_query['aggregations']
    pct = aggs.dig('review_latency', 'percentiles')
    assert_equal 'review_latency_ms', pct['field']
    assert_equal [50, 95, 99],        pct['percents']
  end

  def test_aggregate_top_hits
    aggs = MockEngineer.aggregate(:top) { top_hits size: 3 }.to_query['aggregations']
    assert_equal({ 'size' => 3 }, aggs.dig('top', 'top_hits'))
  end

  # ── Pipeline aggregations ──────────────────────────────────────────────────

  def test_aggregate_sum_bucket
    c = MockEngineer.aggregate(:total_commits) do |a|
      a.sum_bucket(buckets_path: 'by_month>commits')
    end
    aggs = c.to_query['aggregations']
    assert_equal({ 'buckets_path' => 'by_month>commits' }, aggs.dig('total_commits', 'sum_bucket'))
  end

  def test_aggregate_bucket_script
    c = MockEngineer.aggregate(:review_rate) do |a|
      a.bucket_script(
        buckets_path: { 'pr' => 'prs>value', 'review' => 'reviews>value' },
        script: 'params.pr / params.review'
      )
    end
    aggs = c.to_query['aggregations']
    bs = aggs.dig('review_rate', 'bucket_script')
    assert_equal 'params.pr / params.review', bs['script']
    assert_equal({ 'pr' => 'prs>value', 'review' => 'reviews>value' }, bs['buckets_path'])
  end

  # ── Composite aggregation ──────────────────────────────────────────────────

  def test_aggregate_composite_inline_sources
    c = MockEngineer.aggregate(:by_combo) do |a|
      a.composite do
        size 20
        sources do
          aggregate(:role)   { terms field: 'role' }
          aggregate(:status) { terms field: 'status' }
        end
      end
    end
    aggs  = c.to_query['aggregations']
    comp  = aggs.dig('by_combo', 'composite')
    assert_equal 20, comp['size']
    assert_equal [
      { 'role'   => { 'terms' => { 'field' => 'role' } } },
      { 'status' => { 'terms' => { 'field' => 'status' } } }
    ], comp['sources']
  end

  def test_aggregate_composite_with_agg_scope_sources
    c = MockEngineer.aggregate(:by_combo) do |a|
      a.composite do
        size 10
        sources do
          by_role_source
          by_status_source
        end
      end
    end
    aggs    = c.to_query['aggregations']
    sources = aggs.dig('by_combo', 'composite', 'sources')
    assert_equal 2, sources.size
    assert_equal({ 'terms' => { 'field' => 'role' } },   sources[0]['role'])
    assert_equal({ 'terms' => { 'field' => 'status' } }, sources[1]['status_source'])
  end

  # ── KnnBuilder ────────────────────────────────────────────────────────────

  VEC = Array.new(4, 0.1)

  def test_knn_top_level_basic
    c = MockEngineer.knn(:embedding, query_vector: VEC, k: 5, num_candidates: 10)
    knn = c.to_query['knn']
    assert_equal 'embedding', knn['field']
    assert_equal VEC,         knn['query_vector']
    assert_equal 5,           knn['k']
    assert_equal 10,          knn['num_candidates']
  end

  def test_knn_top_level_with_filter_block
    c = MockEngineer.knn(:embedding, query_vector: VEC, k: 5, num_candidates: 10) do
      filter { term 'role', 'backend' }
    end
    filter = c.to_query.dig('knn', 'filter')
    assert_equal({ 'term' => { 'role' => 'backend' } }, filter)
  end

  def test_knn_top_level_with_scope_in_filter
    c = MockEngineer.knn(:embedding, query_vector: VEC, k: 5, num_candidates: 10) do
      filter { active }
    end
    filter = c.to_query.dig('knn', 'filter')
    assert_equal({ 'term' => { 'status' => 'active' } }, filter)
  end

  def test_knn_top_level_multiple_filters_wrapped_in_bool
    c = MockEngineer.knn(:embedding, query_vector: VEC, k: 5, num_candidates: 10) do
      filter { term 'role', 'backend' }
      filter { active }
    end
    filter = c.to_query.dig('knn', 'filter')
    assert_equal 'bool', filter.keys.first
    assert_equal 2, filter.dig('bool', 'filter').size
  end

  def test_knn_top_level_with_similarity
    c = MockEngineer.knn(:embedding, query_vector: VEC, k: 5, num_candidates: 10) do
      similarity 0.8
    end
    assert_equal 0.8, c.to_query.dig('knn', 'similarity')
  end

  def test_knn_top_level_with_min_score
    c = MockEngineer.knn(:embedding, query_vector: VEC, k: 5, num_candidates: 10) do
      min_score 0.5
    end
    assert_equal 0.5, c.to_query['min_score']
    refute c.to_query['knn'].key?('min_score')
  end

  def test_knn_hybrid_with_query
    c = MockEngineer
          .knn(:embedding, query_vector: VEC, k: 5, num_candidates: 10)
          .query { match :bio, 'backend engineer' }
    q = c.to_query
    assert q.key?('knn')
    assert q.key?('query')
    assert_equal({ 'match' => { 'bio' => 'backend engineer' } }, q['query'])
  end

  def test_knn_inline_in_query_block
    c = MockEngineer.query do
      knn(:embedding, query_vector: VEC, k: 5, num_candidates: 10) do
        filter { term 'role', 'backend' }
      end
    end
    knn = c.to_query.dig('query', 'knn')
    assert_equal 'embedding', knn['field']
    assert_equal({ 'term' => { 'role' => 'backend' } }, knn['filter'])
  end

  def test_knn_filter_rejects_match
    assert_raises(NoMethodError) do
      MockEngineer.knn(:embedding, query_vector: VEC, k: 5, num_candidates: 10) do
        filter { match :bio, 'backend' }
      end.to_query
    end
  end

  # ── BoolContext clause-array injection ────────────────────────────────────

  def test_bool_context_filter_accepts_clause_array
    # Build a criteria first, then inject its clauses into a knn filter
    c = MockEngineer.filter { active }.filter { term 'role', 'backend' }
    knn_c = MockEngineer.knn(:embedding, query_vector: VEC, k: 5, num_candidates: 10) do
      filter do
        bool do
          filter c.filter_clauses
        end
      end
    end
    inner_filter = knn_c.to_query.dig('knn', 'filter', 'bool', 'filter')
    assert_includes inner_filter, { 'term' => { 'status' => 'active' } }
    assert_includes inner_filter, { 'term' => { 'role' => 'backend' } }
  end

  def test_bool_context_should_accepts_clause_array
    c = MockEngineer.should { term 'role', 'backend' }.should { term 'role', 'frontend' }
    knn_c = MockEngineer.knn(:embedding, query_vector: VEC, k: 5, num_candidates: 10) do
      filter do
        bool do
          should c.should_clauses
        end
      end
    end
    inner_should = knn_c.to_query.dig('knn', 'filter', 'bool', 'should')
    assert_includes inner_should, { 'term' => { 'role' => 'backend' } }
    assert_includes inner_should, { 'term' => { 'role' => 'frontend' } }
  end

  def test_bool_context_mixed_clause_arrays
    filter_criteria = MockEngineer.filter { active }
    should_criteria = MockEngineer.should { term 'role', 'frontend' }
    knn_c = MockEngineer.knn(:embedding, query_vector: VEC, k: 5, num_candidates: 10) do
      filter do
        bool do
          filter filter_criteria.filter_clauses
          should should_criteria.should_clauses
          minimum_should_match 1
        end
      end
    end
    bool_h = knn_c.to_query.dig('knn', 'filter', 'bool')
    assert_equal [{ 'term' => { 'status' => 'active' } }], bool_h['filter']
    assert_equal [{ 'term' => { 'role' => 'frontend' } }], bool_h['should']
    assert_equal 1, bool_h['minimum_should_match']
  end

  def test_bool_context_must_and_must_not_accept_clause_arrays
    must_c     = MockEngineer.must     { term 'verified', true }
    must_not_c = MockEngineer.must_not { inactive }
    bc = ES::DSL::BoolContext.new
    bc.must(must_c.must_clauses)
    bc.must_not(must_not_c.must_not_clauses)
    h = bc.to_h['bool']
    assert_equal({ 'term' => { 'verified' => true } }, h['must'])
    assert_equal({ 'term' => { 'status' => 'inactive' } }, h['must_not'])
  end

  # ── Criteria top-level params ──────────────────────────────────────────────

  def test_track_total_hits_true
    c = MockEngineer.criteria.track_total_hits
    assert_equal true, c.to_query['track_total_hits']
  end

  def test_track_total_hits_false
    c = MockEngineer.criteria.track_total_hits(false)
    assert_equal false, c.to_query['track_total_hits']
  end

  def test_track_total_hits_integer
    c = MockEngineer.criteria.track_total_hits(5000)
    assert_equal 5000, c.to_query['track_total_hits']
  end

  def test_script_fields
    c = MockEngineer.criteria.script_fields(
      commit_score: { script: { source: 'doc["commit_count"].value * 1.0' } }
    )
    sf = c.to_query['script_fields']
    assert sf.key?('commit_score')
    assert sf.dig('commit_score', 'script', 'source')
  end

  def test_sort_block
    c = MockEngineer.criteria.sort { { 'hire_date' => { 'order' => 'desc' } } }
    assert_equal [{ 'hire_date' => { 'order' => 'desc' } }], c.to_query['sort']
  end

  def test_sort_multiple_fields
    c = MockEngineer.criteria
                    .sort { { 'commit_count' => 'desc' } }
                    .sort { { 'hire_date' => 'asc' } }
    assert_equal 2, c.to_query['sort'].size
  end

  # ── Scope inside must / should / must_not ─────────────────────────────────

  def test_scope_in_must_block
    c = MockEngineer.must { active }
    assert_equal({ 'term' => { 'status' => 'active' } },
                 c.to_query.dig('query', 'bool', 'must'))
  end

  def test_scope_in_should_block
    c = MockEngineer.should { active }
                    .should { inactive }
    should_clauses = c.to_query.dig('query', 'bool', 'should')
    assert_includes should_clauses, { 'term' => { 'status' => 'active' } }
    assert_includes should_clauses, { 'term' => { 'status' => 'inactive' } }
  end

  def test_scope_in_must_not_block
    c = MockEngineer.must_not { inactive }
    assert_equal({ 'term' => { 'status' => 'inactive' } },
                 c.to_query.dig('query', 'bool', 'must_not'))
  end

  def test_scope_in_nested_bool_must
    c = MockEngineer.filter do
      bool do
        must { active }
        must { role 'backend' }
      end
    end
    filters     = c.to_query.dig('query', 'bool', 'filter')
    bool_clause = filters.find { |f| f['bool'] }
    assert bool_clause
    must = bool_clause.dig('bool', 'must')
    assert_instance_of Array, must
    assert_includes must, { 'term' => { 'status' => 'active' } }
    assert_includes must, { 'term' => { 'role' => 'backend' } }
  end

  # ── Parameterized scope ───────────────────────────────────────────────────

  def test_parameterized_scope_in_filter_block
    c = MockEngineer.filter { by_role 'backend' }
    filters = c.to_query.dig('query', 'bool', 'filter')
    assert_includes filters, { 'term' => { 'role' => 'backend' } }
  end

  def test_parameterized_scope_with_explicit_f
    c = MockEngineer.filter { |f| f.by_role('frontend') }
    filters = c.to_query.dig('query', 'bool', 'filter')
    assert_includes filters, { 'term' => { 'role' => 'frontend' } }
  end

  def test_parameterized_scope_range
    c = MockEngineer.filter { commits_gte 500 }
    filters = c.to_query.dig('query', 'bool', 'filter')
    range = filters.find { |f| f['range'] }
    assert range
    assert_equal 500, range.dig('range', 'commit_count', 'gte')
  end

  def test_parameterized_scope_chained_with_non_param_scope
    c = MockEngineer.filter { active }.filter { by_role 'devops' }
    filters = c.to_query.dig('query', 'bool', 'filter')
    assert_includes filters, { 'term' => { 'status' => 'active' } }
    assert_includes filters, { 'term' => { 'role' => 'devops' } }
  end

  # ── Parameterized agg_scope ──────────────────────────────────────────────

  def test_parameterized_agg_scope_basic
    aggs = MockEngineer.by_field('role').to_query['aggregations']
    assert aggs.key?('by_field')
    assert_equal({ 'field' => 'role', 'size' => 10 }, aggs.dig('by_field', 'terms'))
  end

  def test_parameterized_agg_scope_keyword_arg_override
    aggs = MockEngineer.by_field('department', size: 20).to_query['aggregations']
    assert_equal({ 'field' => 'department', 'size' => 20 }, aggs.dig('by_field', 'terms'))
  end

  def test_parameterized_agg_scope_multiple_aggs
    aggs = MockEngineer.top_by_field('role').to_query['aggregations']
    assert aggs.key?('top')
    assert aggs.key?('terms_agg')
    assert_equal({ 'field' => 'role' }, aggs.dig('terms_agg', 'terms'))
  end

  def test_parameterized_agg_scope_chained_with_other_agg_scopes
    aggs = MockEngineer.by_field('status').group_by_department.to_query['aggregations']
    assert aggs.key?('by_field')
    assert aggs.key?('departments')
  end

  def test_parameterized_agg_scope_with_call_time_sub_agg
    aggs = MockEngineer.by_field('role') do |ab|
      ab.aggregate(:commit_total) { sum field: 'commit_count' }
    end.to_query['aggregations']
    assert_equal({ 'field' => 'role', 'size' => 10 }, aggs.dig('by_field', 'terms'))
    assert_equal({ 'field' => 'commit_count' }, aggs.dig('by_field', 'aggs', 'commit_total', 'sum'))
  end

  # ── Nested agg_scope (composite with scope sources) ───────────────────────

  def test_agg_scope_composite_sources_via_scope
    aggs = MockEngineer.aggregate(:by_combo) do |a|
      a.composite do
        size 5
        sources do
          by_role_source
          by_status_source
        end
      end
    end.to_query['aggregations']
    sources = aggs.dig('by_combo', 'composite', 'sources')
    assert_equal 2, sources.size
    assert sources.any? { |s| s.key?('role') }
    assert sources.any? { |s| s.key?('status_source') }
  end

  private

  def build_router
    Class.new do
      include ES::DSL::Searchable
      index_name 'alias_name'

      def self.search_index(criteria = nil)
        range = criteria&.date_filter_for(:hire_date)
        return 'alias_name' unless range

        year = parse_year(range['gte'] || range['lte'])
        year ? "content_#{year}" : 'alias_name'
      end

      def self.parse_year(date_str)
        Date.parse(date_str).year
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
