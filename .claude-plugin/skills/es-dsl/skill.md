---
name: es-dsl
description: >
  Build Elasticsearch queries with the es-dsl Ruby ODM gem.
  Use when the user needs to write search queries, filter clauses, aggregations,
  scopes, agg_scopes, PIT pagination, or custom response classes using this gem.
metadata:
  author: eugene
  version: 1.0.3
---

# es-dsl Ruby ODM

Lightweight ODM (Object-Document Mapper) for Elasticsearch. Pure Ruby.

## When to use this skill

Use when the user is building queries with this gem — filters, bool clauses,
aggregations, scopes, agg_scopes, or search execution.

---

## Setup

```ruby
class MyModel
  include ES::DSL::Searchable
  index_name 'my_index'
end
```

---

## `scope` — named filter helper

Defines a named method usable inside any `filter {}`, `must {}`, `should {}`, or `bool {}` block.

```ruby
# No-arg scopes
scope :active    do; term :status, 'active';   end
scope :deleted   do; term :status, 'deleted';  end
scope :instagram do; term :platform, 'instagram'; end

scope :high_engagement do
  range :engagement, gte: 10_000
end

# Parameterized scopes
scope :by_platform do |platform|
  term 'platform', platform
end

scope :followers_gte do |n|
  range 'follower_count', gte: n
end
```

Scopes are called either via `instance_exec` (0-arity block) or via an explicit
`QueryFilter` arg (block with `|f|`):

```ruby
# No-arg scope — both are equivalent:
MyModel.filter { active }
MyModel.filter { |f| f.active }

# Parameterized scope:
MyModel.filter { by_platform 'instagram' }
MyModel.filter { |f| f.by_platform('instagram') }
MyModel.filter { followers_gte 10_000 }

# Combining:
MyModel.filter { active; by_platform 'tiktok' }
```

---

## `query {}` — scoring query block

Used for full-text search and scoring clauses. Multiple `query {}` calls merge into `bool.must`.

```ruby
# match_all (default when no query given)
MyModel.criteria.to_h

# full-text
MyModel.query { match :name, 'john' }.to_h
MyModel.query { match_phrase :bio, 'content creator' }.to_h
MyModel.query { multi_match('john', fields: %w[name bio]) }.to_h
MyModel.query { query_string('john AND smith') }.to_h

# smart_match — bool/should with match_phrase + match (scoring boost)
MyModel.query { smart_match :name, 'john' }.to_h

# date_range — pushes to filter context (non-scoring)
MyModel.query { date_range :published_at, from: '2025-01-01', to: '2025-12-31' }.to_h

# filter_terms — pushes to filter context
MyModel.query { filter_terms :platform, %w[instagram tiktok] }.to_h

# nested
MyModel.query { nested('tags') { term 'tags.name', 'ruby' } }.to_h

# knn
MyModel.query { knn('embedding', query_vector: [1.0, 0.5], k: 5, num_candidates: 100) }.to_h

# chaining — merged into bool/must
MyModel
  .query { smart_match :name, 'john' }
  .query { date_range :published_at, from: '2025-01-01' }
  .filter { active }
  .to_h
```

---

## `filter {}` — building filter clauses

Available clauses: `term`, `terms`, `range`, `exists`, `bool`, `nested`, geo, `script`, `raw`, scopes.
**Scoring clauses (`match`, `knn`, etc.) are not available here** — calling them raises `NoMethodError`.
Use `must {}` / `query {}` for scoring clauses.

```ruby
# Simple term filter
MyModel.filter { term :status, 'active' }.to_h

# Using a scope
MyModel.filter { active }.to_h

# Parameterized scope
MyModel.filter { by_platform 'instagram' }.to_h

# Multiple clauses (ANDed as bool/filter)
MyModel.filter do
  active
  term :team, 'team-1'
  range :followers, gte: 1000
end.to_h

# Explicit QueryFilter arg — same result
MyModel.filter do |f|
  f.active
  f.by_platform 'instagram'
  f.term :team, 'team-1'
end.to_h
```

### Top-level `must` / `should` / `must_not`

Same block style as `filter` but maps to `bool.must` / `bool.should` / `bool.must_not`:

```ruby
MyModel.must    { term :status, 'active' }.to_h
MyModel.must_not { term :status, 'deleted' }.to_h
MyModel
  .should { term :platform, 'instagram' }
  .should { term :platform, 'tiktok' }
  .to_h
```

### `bool` inside filter

```ruby
MyModel.filter do
  bool do
    should do
      active
      deleted
    end
    minimum_should_match 1
  end
end.to_h
```

### `raw` — inject an arbitrary Hash clause

```ruby
MyModel.filter do
  raw(bool: { should: [{term: {status: 'active'}}, {term: {status: 'deleted'}}],
              minimum_should_match: 1 })
end.to_h
```

### Injecting pre-built clause arrays into `BoolContext`

`bool { filter/must/should/must_not }` also accept a plain Array instead of a block.
Use this to forward accumulated clauses from another `Criteria`:

```ruby
c = MyModel
  .filter { active }
  .filter { term 'platform', 'instagram' }
  .should { term 'type', 'video' }

MyModel.knn(:image_embedding, query_vector: vec, k: k, num_candidates: n) do
  filter do
    bool do
      filter   c.filter_clauses    # Array — no block needed
      should   c.should_clauses
      minimum_should_match 1
    end
  end
end.search
```

---

## `knn` — vector search

### Top-level knn (alongside `query` for hybrid search)

```ruby
MyModel.knn(:image_embedding, query_vector: vec, k: 10, num_candidates: 15) do
  filter { term 'platform', 'instagram' }
  filter { active }          # scope
  similarity 0.8
  min_score 0.5
end.query { smart_match :caption, 'sunset' }
  .search
```

- Multiple `filter {}` calls accumulate; >1 clause is wrapped as `{ bool: { filter: [...] } }`.
- `min_score` is emitted at the top-level body, not inside the `knn` clause.
- `match` inside `filter {}` raises `NoMethodError`.

### Inline knn inside `query {}`

```ruby
MyModel.query do
  knn(:image_embedding, query_vector: vec, k: 10, num_candidates: 15) do
    filter { active }
  end
  match :caption, 'sunset'
end.to_h
```

### query vs knn routing pattern

```ruby
criteria = base_criteria  # already has filter/should/must clauses

if query_vector.present?
  MyModel.knn(:image_embedding, query_vector: query_vector,
              k: k, num_candidates: (k * 1.5).ceil) do
    filter do
      bool do
        filter   criteria.filter_clauses
        should   criteria.should_clauses
        minimum_should_match criteria.should_clauses.any? ? 1 : nil
      end
    end
  end.search
else
  criteria.search
end
```

---

## New-style `bool` API

An alternative to `filter {}` blocks — attach directly to a Criteria object:

```ruby
q = MyModel.criteria
q.bool.filter  { |f| f.term('status', 'active') }
q.bool.must    { |f| f.match('name', 'john') }
q.bool.should  { |f| f.term('platform', 'instagram') }
q.bool.should  { |f| f.term('platform', 'tiktok') }
q.bool.minimum_should_match(1)
q.to_h
```

Without a block, `q.bool.filter` returns the accumulated clauses array (for introspection).

---

## Criteria top-level parameters

```ruby
MyModel.criteria
  .from(0)
  .size(20)
  .source('name', 'platform')         # _source filtering
  .track_total_hits(true)             # true / false / integer threshold
  .script_fields(
    engagement: { script: { source: 'doc["likes"].value + doc["comments"].value' } }
  )
  .sort { { published_at: { order: 'desc' } } }
  .to_h
```

`track_total_hits` values:
- `true` — exact count always
- `false` — skip counting
- `10_000` — count up to N; returns `"relation": "gte"` if exceeded

---

## `date_filter_for` — introspect date range

Used by `search_index` overrides to inspect the compiled query's date filters:

```ruby
def self.search_index(criteria = nil)
  range = criteria&.date_filter_for(:published_at)
  # range => { "gte" => "2025-01-01", "lte" => "2025-12-31" } or nil
  return index_name unless range

  year = Date.parse(range['gte'] || range['lte']).year
  "content_#{year}"
rescue ArgumentError, TypeError
  index_name
end
```

Scans both `query.bool.filter` and `query.bool.must` for range clauses on the given field.

---

## `aggregate` — inline aggregation

```ruby
# terms agg
MyModel.aggregate(:teams) do |agg|
  agg.terms field: :team, size: 10
end.to_h

# metric sub-aggs
MyModel.aggregate(:teams) do |agg|
  agg.terms field: :team, size: 10
  agg.aggregate(:total_reach)     { sum field: :reach }
  agg.aggregate(:total_followers) { sum field: :followers }
end.to_h

# named-bucket filters agg
MyModel.aggregate(:status) do |agg|
  agg.filters(:active)  { term :status, 'active' }
  agg.filters(:deleted) { term :status, 'deleted' }
end.to_h

# with QueryFilter arg (f captured by closure in inner blocks, supports scopes)
MyModel.aggregate(:status) do |agg, f|
  agg.filters(:active)  { f.active }
  agg.filters(:deleted) { f.deleted }
end.to_h

# composite agg — inline sources
MyModel.aggregate(:by_combo) do |a|
  a.composite do
    size 20
    sources do
      aggregate(:platform) { terms field: 'platform' }
      aggregate(:paid)     { terms field: 'paid' }
    end
  end
end.to_h

# composite agg — sources from agg_scopes (see agg_scope section)
MyModel.aggregate(:by_combo) do |a|
  a.composite do
    size 10
    sources do
      by_platform_source  # resolved from agg_scope
      by_status_source
    end
  end
end.to_h

# pipeline agg
MyModel.aggregate(:total_sales) do |a|
  a.sum_bucket(buckets_path: 'by_month>sales')
end.to_h

MyModel.aggregate(:rate) do |a|
  a.bucket_script(
    buckets_path: { eng: 'engagement>value', fol: 'followers>value' },
    script: 'params.eng / params.fol'
  )
end.to_h
```

---

## `agg_scope` — reusable aggregations

Defines a named aggregation that becomes:
1. A class method on the model: `MyModel.group_by_status`
2. A method on `AggBuilder` for embedding as a sub-agg: `teams_agg.group_by_status`

```ruby
# No-arg (agg only)
agg_scope :group_by_team do |agg|
  agg.aggregate(:teams) do
    terms field: :team, size: 10
  end
end

# With filter context (f carries scopes)
agg_scope :group_by_status do |agg, f|
  agg.aggregate(:status) do |status_agg|
    status_agg.filters(:active)  { f.active }
    status_agg.filters(:deleted) { f.deleted }
  end
end

# Parameterized — extra args after agg, f
agg_scope :by_field do |agg, f, field, size: 10|
  agg.aggregate(:by_field) { terms field: field.to_s, size: size }
end

agg_scope :timeline do |agg|
  agg.aggregate(:timeline) do
    date_histogram field: :published_at, calendar_interval: 'month'
  end
end
```

### Calling agg_scopes

```ruby
# Standalone
MyModel.group_by_status.to_h
MyModel.timeline.to_h

# Parameterized
MyModel.by_field('platform').to_h
MyModel.by_field('team', size: 20).to_h

# Chained as siblings (all aggs merged at top level)
MyModel.group_by_team.group_by_status.timeline.to_h

# With call-site sub-agg block
MyModel.group_by_status do |agg|
  agg.aggregate(:reach) { sum field: :reach }
end.to_h

# Parameterized + call-site sub-agg
MyModel.by_field('platform') do |ab|
  ab.aggregate(:reach) { sum field: 'reach' }
end.to_h
```

### Nested / composed agg_scopes

```ruby
# Embed one agg_scope inside another
agg_scope :team_with_status do |agg, f|
  agg.group_by_team do |teams_agg|
    teams_agg.group_by_status   # sub-agg via AggBuilder method
  end
end

# Output:
# { aggs: { teams: { terms: {...}, aggs: { status: { filters: {...} } } } } }
```

---

## Chaining filter + agg_scope + sort

```ruby
MyModel
  .filter { |f| f.instagram }
  .group_by_status
  .sort(:published_at, :desc)
  .size(0)
  .to_h

# filter + agg_scope + inline sub-agg
MyModel
  .filter { |f| f.instagram }
  .timeline do |agg, f|
    agg.group_by_status
    agg.aggregate(:total_reach) { sum field: :reach }
  end
  .size(0)
  .to_h
```

---

## Dynamic index routing

Override `search_index` on the model class. Receives the `Criteria` object so
you can inspect filters (e.g. date ranges):

```ruby
def self.search_index(criteria = nil)
  range = criteria&.date_filter_for(:published_at)
  return index_name unless range

  year = Date.parse(range['gte'] || range['lte']).year
  "content_#{year}"
rescue ArgumentError, TypeError
  index_name
end
```

---

## Custom response class

Define `MyModel::Response < DSLResponse` — it is auto-detected:

```ruby
class MyModel
  include ES::DSL::Searchable

  class Response < ES::DSL::DSLResponse
    def content_ids
      sources.map { |s| s['content_id'] }
    end

    def timeline_buckets
      agg('timeline')&.fetch('buckets', []) || []
    end
  end
end

result = MyModel.filter { active }.search
result.content_ids       # => [...]
result.timeline_buckets  # => [...]
```

### Composable response methods

Split response helpers into small, composable methods that can be combined via blocks.
Use `instance_exec(b, &block)` so inner blocks resolve method names on `self` (the Response),
avoiding the need for `results.` prefix inside the block.

```ruby
agg_scope :group_by_platform do |agg|
  agg.aggregate(:group_by_platform) { terms field: 'platform', size: 50 }
end

agg_scope :total_followers do |agg|
  agg.aggregate(:total_followers) { sum field: 'follower_count' }
end

class Response < ES::DSL::DSLResponse
  # Iterates platform buckets; merges the block result into each row.
  # `bucket:` is for recursive/nested calls — omit when reading from top-level agg.
  def group_by_platform(bucket: nil, &block)
    src = bucket ? bucket.dig('group_by_platform', 'buckets')
                 : aggregations.dig('group_by_platform', 'buckets')
    return [] unless src

    src.map do |b|
      row = { platform: b['key'], count: b['doc_count'] }
      row.merge!(instance_exec(b, &block)) if block_given?
      row
    end
  end

  # Returns { total_followers: N } from a bucket or the top-level aggregation.
  def total_followers(bucket: nil)
    src = bucket || aggregations
    { total_followers: src.dig('total_followers', 'value').to_i }
  end
end
```

**Query:** compose agg_scopes with a call-time block to embed sub-aggs per bucket:

```ruby
# group_by_platform alone — no sub-aggs
results = MyModel.criteria.size(0).group_by_platform.search
results.group_by_platform
# => [{ platform: 'youtube', count: 1 }, { platform: 'instagram', count: 2 }, ...]

# group_by_platform + total_followers sub-agg (call-time block)
results = MyModel.criteria.size(0).group_by_platform { total_followers }.search
results.group_by_platform { |b| total_followers(bucket: b) }
# => [{ platform: 'youtube', count: 1, total_followers: 100_000 }, ...]

# total_followers standalone (across all docs)
results = MyModel.criteria.size(0).total_followers.search
results.total_followers
# => { total_followers: 165_000 }

# with a filter
results = MyModel.filter { active }.size(0).total_followers.search
results.total_followers
# => { total_followers: 160_000 }
```

**Key points:**
- `instance_exec(b, &block)` — block resolves `total_followers` on `self` (the Response object), no `results.` needed
- `bucket: nil` — same method works standalone or as sub-agg reader
- Call-time block `group_by_platform { total_followers }` embeds `total_followers` as a sub-agg on the AggBuilder
- Returns `[]` / `{ total_followers: 0 }` if the aggregation was not requested

---

## PIT pagination

```ruby
MyModel.filter { active }.search_pit(page_size: 500) do |response, total|
  response.sources.each { |doc| process(doc) }
  puts "Processed #{total} so far"
end
```

---

## Fluent query builder pattern

For complex search objects, accumulate state in a plain Ruby class and delegate
to `Criteria`:

```ruby
class MySearch
  def initialize
    @criteria = MyModel.criteria
  end

  def platforms(values)
    @criteria.platforms(values) if values&.any?
    self
  end

  def start_date(date)
    @criteria.start_date(date)
    self
  end

  def search
    @criteria.search
  end
end

MySearch.new.platforms(['instagram']).start_date('2025-01-01').search
```

---

## Block arity rule (for gem internals / advanced use)

All DSL blocks support two styles — the gem detects `block.arity`:

```ruby
# 0-arity → instance_exec on the context object
MyModel.filter { active }

# 1+-arity → object passed as argument
MyModel.filter { |f| f.active }
```

---

## Common gotchas

- **Ruby 2.6**: no endless method syntax (`def foo = expr` will fail)
- **`Criteria#to_h`** is the public API; `to_query` is an alias
- **`filters(:name) {}`** accumulates named buckets on the same agg node —
  multiple calls build the `filters.filters` hash incrementally
- **`must_not` inside `bool {}`** takes a block, not a plain Hash
- **`date_range`** / `filter_terms` push to the non-scoring filter buffer
  (equivalent to ES `filter` context), not the query context
- **`scope` blocks** run inside a `FilterCollector` — all clause methods work,
  but the block is re-executed fresh on each use (not cached)
- **`Date`** requires explicit `require 'date'` in scripts/specs
