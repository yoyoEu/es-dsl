# ES::DSL — Design Reference

> AI-readable design document. Keep in sync with spec.md.
> Source of truth for implementation decisions.

---

## Architecture Overview

Lightweight ODM for Elasticsearch. Pure Ruby.
Entry point: `include ES::DSL::Searchable`.

### Core Classes

| Class / Module | Role |
|---|---|
| `Criteria` | Lazy query builder. Accumulates state, compiles to Hash on `to_h`. |
| `AggBuilder` | DSL for building one aggregation node (type + opts + sub-aggs). |
| `FilterClauses` | Module: term/terms/range/exists/bool/nested/geo/script/raw — filter-valid only. |
| `QueryClauses` | Module: match/match_phrase/knn/dis_max/… — scoring query clauses. |
| `FilterContext` | includes `FilterClauses` only. Used in `filter {}` blocks. `match` → `NoMethodError`. |
| `MustContext` | `FilterContext` + `QueryClauses`. Used in `must {}` / `should {}` / `must_not {}`. |
| `BoolContext` | Builds nested bool; routes sub-blocks to `FilterContext` or `MustContext`. |
| `QueryContext` | `MustContext` + QueryFilter helpers. Used in `query {}` blocks. |
| `BoolBuilder` | Attached to Criteria; exposes `.filter {}`, `.must {}`, `.should {}`. |
| `KnnBuilder` | Builds `knn` clause; `filter {}` uses `FilterContext` (scopes supported). |

---

## DSL Conventions

### Block Arity Rules

All DSL blocks support **two calling styles**. Determined by `block.arity`:

```ruby
# 0-arity — instance_exec on the context object
MockModel.filter { active }

# 1+-arity — object passed as argument
MockModel.filter { |f| f.active }
```

This applies uniformly to: `filter {}`, `aggregate {}`, `agg_scope {}`, `filters(:name) {}`.

The pattern for callers:
```ruby
blk.arity == 0 ? ctx.instance_exec(&blk) : blk.call(ctx)
```

### Symbol Field Names

All field name args (`:status`, `:team`, etc.) are stringified internally.
`term :status, 'active'` → `{ 'term' => { 'status' => 'active' } }`

### `to_h` vs `to_query`

`Criteria#to_h` is the public API (more Ruby-idiomatic).
`to_query` kept as internal/alias.

---

## `scope` Macro

```ruby
scope :active do
  term :status, 'active'
end
```

- Adds method `active` to the model's `QueryFilter` module (auto-created if absent).
- The block runs inside a `FilterCollector` context — all clause methods available.
- Usable in any block that `instance_exec`s a filter context:
  - `filter { active }` — direct via instance_exec
  - `filter { |f| f.active }` — via explicit QueryFilter arg
  - `filters(:active) { f.active }` — via closure from outer `|agg, f|`

### Parameterized scope

```ruby
scope :by_platform do |platform|
  term 'platform', platform
end

scope :followers_gte do |n|
  range 'follower_count', gte: n
end
```

Called with an argument:

```ruby
MockModel.filter { by_platform 'instagram' }
MockModel.filter { |f| f.followers_gte(5000) }
MockModel.filter { active; by_platform 'tiktok' }
```

Implementation: `qf_mod.define_method(name) { |*args| instance_exec(*args, &blk) }`

---

## `agg_scope` Macro

```ruby
agg_scope :group_by_status do |agg, f|
  agg.aggregate(:status) do |status_agg|
    status_agg.filters(:active)  { f.active }
    status_agg.filters(:deleted) { f.deleted }
  end
end
```

### Block args

| Arg | Type | Description |
|---|---|---|
| `agg` | `AggBuilder` / `AggAccumulator` | Build aggregations |
| `f` | `FilterCollector` (with QueryFilter) | Call scopes (e.g. `f.active`) |
| `*args` | any | Extra args forwarded at call site |

All args are optional. Inner blocks capture `f` via closure — no need to re-pass.

### Defines two things

1. **Class method on model**: `MockModel.group_by_status` → returns `Criteria`
2. **Method on `AggBuilder`**: `teams_agg.group_by_status` → embeds as sub-agg

### Call-time block

Optional block passed at call site adds **sub-aggs** inside the scope's aggregation:

```ruby
MockModel.group_by_status do |agg, f|
  agg.aggregate(:reach) { sum field: :reach }  # added inside :status agg
end
```

### Chaining as sibling

```ruby
MockModel.group_by_team.group_by_status.timeline
# => aggs: { teams: {...}, status: {...}, timeline: {...} }
```

`agg_scope` methods are available on `Criteria` (adds to `@raw_agg_hashes`).

### Parameterized agg_scope

Extra args (positional or keyword) after `agg, f` are forwarded at call site:

```ruby
agg_scope :by_field do |agg, f, field, size: 10|
  agg.aggregate(:by_field) { terms field: field.to_s, size: size }
end

agg_scope :top_by_field do |agg, f, field|
  agg.aggregate(:top)       { top_hits size: 3 }
  agg.aggregate(:terms_agg) { terms field: field.to_s }
end
```

Called as:

```ruby
MockModel.by_field('platform')           # default size: 10
MockModel.by_field('team', size: 20)     # override keyword arg
MockModel.top_by_field('status')         # positional arg
```

Block arity dispatch (applied in 5 locations across `searchable.rb`, `agg_builder.rb`, `criteria.rb`):

```ruby
case defn.arity
when 0 then accum.instance_exec(&defn)
when 1 then defn.call(accum)
when 2 then defn.call(accum, f)
else        defn.call(accum, f, *args)
end
```

---

## `aggregate` API Changes

### New `filters(:name) { }` shorthand

Old (two-level):
```ruby
agg.aggregate(:status) do |a|
  a.filters do |f|
    f.filter(:active) { term 'status', 'active' }
  end
end
```

New (flat):
```ruby
agg.aggregate(:status) do |status_agg|
  status_agg.filters(:active)  { term :status, 'active' }
  status_agg.filters(:deleted) { term :status, 'deleted' }
end
```

Each `filters(:name) { }` call adds one named bucket to the ES `filters` aggregation.
Multiple calls accumulate buckets on the same agg node.

---

## `filter` Block Context

Inside `filter {}` / `bool {}` / `should {}` / `filters(:name) {}`:
- All ES clause methods: `term`, `terms`, `range`, `exists`, `bool`, `must_not`, etc.
- All `scope` methods from the model's `QueryFilter`
- `bool do ... end` nests a bool clause; inside: `should`, `must`, `must_not`, `minimum_should_match`

---

## Aggregation Nesting

### Sub-agg via block on `aggregate`

```ruby
agg.aggregate(:teams) do |teams_agg|
  teams_agg.terms field: :team, size: 10
  teams_agg.aggregate(:total_reach) { sum field: :reach }  # sub-agg
end
```

### Sub-agg via `agg_scope` name on AggBuilder

```ruby
agg.group_by_team do |teams_agg|
  teams_agg.group_by_status   # embeds group_by_status inside teams bucket
end
```

### Output structure (team_with_status)

```json
{
  "aggs": {
    "teams": {
      "terms": { "field": "team", "size": 10 },
      "aggs": {
        "status": {
          "filters": {
            "filters": {
              "active":  { "term": { "status": "active" } },
              "deleted": { "term": { "status": "deleted" } }
            }
          }
        }
      }
    }
  }
}
```

---

## Timeline Agg Scope

```ruby
agg_scope :timeline do |agg|
  agg.aggregate(:timeline) do
    date_histogram field: :published_at, calendar_interval: 'month'
  end
end
```

Composable with other scopes:
```ruby
agg_scope :timeline_with_status do |agg, f|
  agg.timeline do |tl_agg|
    tl_agg.group_by_status
  end
end
```

---

## Implementation Notes

### `scope` implementation

```ruby
def scope(name, &block)
  qf = const_defined?(:QueryFilter, false) ? const_get(:QueryFilter) : const_set(:QueryFilter, Module.new)
  blk = block
  qf.define_method(name) { |*args| instance_exec(*args, &blk) }
end
```

Supports parameterized scopes: `scope :by_platform do |p| term 'platform', p end`

### `agg_scope` implementation

Needs to define method in two places:
1. `define_singleton_method(name)` on model class → returns Criteria
2. Register name+definition so `AggBuilder` can call it as sub-agg

AggBuilder needs a reference to the model's registered agg_scopes.

### `filters(:name) { }` on AggBuilder

`filters` currently takes a block yielding `FiltersBuilder`.
New behavior: when called with a name arg, accumulates named buckets:

```ruby
def filters(name = nil, &block)
  if name
    # accumulate named bucket
    @filters_buckets ||= {}
    collector = FilterCollector.new(@model_qf_mod)
    block.arity == 0 ? collector.instance_exec(&block) : block.call(collector)
    @filters_buckets[name.to_s] = build_clause(collector)
    set_agg('filters', { 'filters' => @filters_buckets })
  else
    # existing FiltersBuilder path
    ...
  end
end
```

### `bool` inside filter block

`bool do ... end` inside a FilterCollector context creates a nested bool clause.
Inside the bool block, `should do ... end`, `must do ... end`, `must_not do ... end`,
and `minimum_should_match N` are available.

---

## Constraints

- Ruby 2.6 compatible — no endless methods, no `...` forwarding
- Tests: minitest 5.18.1
- `rescue` modifier form disallowed (Rubocop)
- `Date` requires explicit `require 'date'`
- `Criteria#to_h` outputs `'aggregations'` key (ES accepts both `aggs`/`aggregations`)

---

## Context Hierarchy

```
FilterContext   (FilterClauses only)
  └─ MustContext = ShouldContext = MustNotContext   (+ QueryClauses)
       └─ QueryContext   (+ QueryFilter helpers)
```

Calling a scoring clause (`match`, `knn`, …) inside `FilterContext` raises `NoMethodError`
at Ruby level — caught before the query is sent to ES.

`BoolContext` routes each sub-block to the appropriate context:

| Method | Context used |
|---|---|
| `filter {}` | `FilterContext` |
| `must {}` | `MustContext` |
| `should {}` | `ShouldContext` |
| `must_not {}` | `MustNotContext` |

---

## FilterContext Clause Reference

Available inside `filter {}`, `filters(:name) {}`, and `bool.filter {}` blocks.

### Term-level

```ruby
term  'status', 'active'                            # exact match
terms 'platform', %w[instagram tiktok]             # any of
range 'followers', gte: 1000, lte: 50_000
exists 'published_at'
ids [1, 2, 3]
prefix  'name', 'joh'
wildcard 'name', 'jo*'
```

### Compound

```ruby
bool do
  must    { active }
  should  { term 'platform', 'instagram' }
  must_not { term 'status', 'deleted' }
  minimum_should_match 1
end

bool({ must_not: { exists: { field: 'deleted_at' } } })  # raw hash form
```

### Injecting pre-built clause arrays

`BoolContext#filter`, `#must`, `#should`, `#must_not` also accept a plain Array
of clauses directly (no block). Useful to forward clauses from another `Criteria`:

```ruby
c = MockModel.filter { active }.filter { term 'platform', 'instagram' }

MockModel.knn(:image_embedding, query_vector: vec, k: k, num_candidates: n) do
  filter do
    bool do
      filter   c.filter_clauses    # array form
      should   c.should_clauses
      must_not c.must_not_clauses
    end
  end
end
```

### Escape hatch

```ruby
raw({ 'script' => { 'script' => { 'source' => '...' } } })
```

---

## MustContext / ShouldContext / MustNotContext Clause Reference

Inherits all `FilterContext` clauses plus:

```ruby
match        'bio', 'content creator'
match_phrase 'bio', 'content creator'
match_phrase_prefix 'name', 'joh'
match_all
multi_match 'john', fields: %w[name bio], type: 'best_fields'
query_string 'john AND (smith OR doe)'
simple_query_string 'john smith'
knn 'embedding', query_vector: [1.0, 0.5], k: 5, num_candidates: 100
more_like_this fields: %w[name bio], like: 'john'
dis_max({ match: { name: 'john' } }, { match: { bio: 'john' } }, tie_breaker: 0.3)
constant_score(boost: 1.5) { term 'status', 'active' }
boosting positive: { term: { status: 'active' } },
         negative: { term: { status: 'deleted' } }, negative_boost: 0.5
```

Any unknown ES keyword falls through `method_missing` to `add_clause`.

---

## Query Context Clause Reference

Available inside `query {}` blocks. Inherits `MustContext` plus QueryFilter helpers:

```ruby
# DSL helpers (QueryFilter)
smart_match    :name, 'john'                        # bool/should: phrase + fuzzy
date_range     :published_at, from: '2025-01-01', to: '2025-12-31'
filter_terms   :platform, %w[instagram tiktok]     # non-scoring filter
```

---

## KnnBuilder

`KnnBuilder` is the block context for `Model.knn(...)` and inline `knn(...)` inside `query {}`.

### Block DSL

```ruby
filter {}          # FilterContext block — scopes available, match → NoMethodError
similarity(float)  # similarity threshold
min_score(float)   # top-level min_score (top-level knn only, not written inside knn body)
boost(float)
```

### Top-level knn — coexists with query (hybrid search)

```ruby
Model.knn(:image_embedding, query_vector: vec, k: 10, num_candidates: 15) do
  filter { active }
  filter { term 'platform', 'instagram' }
  similarity 0.8
  min_score 0.5
end.query { match :caption, 'sunset' }.search
```

Compiles to `{ knn: {...}, query: {...}, min_score: 0.5 }`.
Multiple `filter {}` calls accumulate; if >1, wrapped in `{ bool: { filter: [...] } }`.

### Inline knn inside query {}

```ruby
Model.query do
  knn(:image_embedding, query_vector: vec, k: 10, num_candidates: 15) do
    filter { term 'platform', 'instagram' }
  end
  match :caption, 'sunset'
end
```

Compiles to `{ query: { bool: { must: [{ knn: {...} }, { match: {...} }] } } }`.

### Forwarding clauses from another Criteria

Pre-built `filter_clauses` / `should_clauses` / `must_clauses` / `must_not_clauses`
from a `Criteria` object can be injected directly via `BoolContext` array form:

```ruby
c = Model.filter { active }.filter { term 'platform', 'instagram' }
        .should { term 'type', 'video' }

Model.knn(:image_embedding, query_vector: vec, k: k, num_candidates: n) do
  filter do
    bool do
      filter   c.filter_clauses
      should   c.should_clauses
      minimum_should_match 1
    end
  end
end.search
```

---

## Criteria Top-Level Parameters

```ruby
.from(0)
.size(20)
.source('name', 'platform')          # _source filter
.sort { { 'published_at' => { 'order' => 'desc' } } }
.sort { [{ score: 'desc' }, { published_at: 'asc' }] }  # multiple fields
.track_total_hits                     # true (default arg)
.track_total_hits(false)              # disable (search_after performance)
.track_total_hits(5000)              # cap at N
.script_fields(
  engagement: { script: { source: 'doc["likes"].value' } }
)
```

---

## Aggregation Type Reference

### Metric aggregations

```ruby
.aggregate(:name) { avg          field: 'followers' }
.aggregate(:name) { max          field: 'followers' }
.aggregate(:name) { min          field: 'followers' }
.aggregate(:name) { sum          field: 'reach' }
.aggregate(:name) { stats        field: 'score' }
.aggregate(:name) { extended_stats field: 'score' }
.aggregate(:name) { value_count  field: 'user_id' }
.aggregate(:name) { cardinality  field: 'user_id' }
.aggregate(:name) { percentiles  field: 'latency', percents: [50, 95, 99] }
.aggregate(:name) { top_hits     size: 3 }
.aggregate(:name) { missing      field: 'category' }
.aggregate(:name) { geo_bounds   field: 'location' }
.aggregate(:name) { geo_centroid field: 'location' }
```

### Bucket aggregations

```ruby
.aggregate(:name) { terms         field: 'platform', size: 10 }
.aggregate(:name) { date_histogram field: 'published_at', calendar_interval: 'month' }
.aggregate(:name) { histogram      field: 'followers', interval: 1000 }
.aggregate(:name) { nested         path: 'tags' }
.aggregate(:name) { reverse_nested }
.aggregate(:name) { filter  { term 'status', 'active' } }
.aggregate(:name) do |a|
  a.filters do |f|
    f.filter(:active)  { term 'status', 'active' }
    f.filter(:deleted) { term 'status', 'deleted' }
  end
end
# flat shorthand:
.aggregate(:name) do |a|
  a.filters(:active)  { term 'status', 'active' }
  a.filters(:deleted) { term 'status', 'deleted' }
end
```

### Pipeline aggregations

```ruby
.aggregate(:name) { sum_bucket      buckets_path: 'by_month>sales' }
.aggregate(:name) { min_bucket      buckets_path: 'by_month>sales' }
.aggregate(:name) { max_bucket      buckets_path: 'by_month>sales' }
.aggregate(:name) { avg_bucket      buckets_path: 'by_month>sales' }
.aggregate(:name) do |a|
  a.bucket_script(
    buckets_path: { eng: 'engagement>value', fol: 'followers>value' },
    script: 'params.eng / params.fol'
  )
end
.aggregate(:name) { bucket_selector buckets_path: { sales: 'sales>value' }, script: 'params.sales > 0' }
```

### Composite aggregation

```ruby
# Inline sources
.aggregate(:by_combo) do |a|
  a.composite do
    size 20
    sources do
      aggregate(:platform) { terms field: 'platform' }
      aggregate(:status)   { terms field: 'status' }
    end
  end
end

# agg_scope sources — resolve by name
agg_scope :by_platform_source do |a|
  a.aggregate(:platform) { terms field: 'platform' }
end

.aggregate(:by_combo) do |a|
  a.composite do
    size 10
    sources do
      by_platform_source  # resolved from agg_scope
      by_status_source
    end
  end
end
```

Output:
```json
{
  "by_combo": {
    "composite": {
      "size": 10,
      "sources": [
        { "platform": { "terms": { "field": "platform" } } },
        { "status":   { "terms": { "field": "status" } } }
      ]
    }
  }
}
```

### Sub-aggregations

```ruby
.aggregate(:by_platform) do |a|
  a.terms field: 'platform', size: 10
  a.aggregate(:avg_followers) { avg field: 'follower_count' }
end
```

### Raw hash (escape hatch)

```ruby
.aggregate(:my_agg, {
  filters: { filters: { active: { term: { status: 'active' } } } },
  aggs:    { count: { value_count: { field: 'id' } } }
})
```

---

## Custom Response Class

`MyModel::Response < DSLResponse` is auto-detected via `response_class`.

### Composable response methods

Split response helpers into small methods composable via blocks.
Block is `instance_exec`d on `self` (the Response), so callers write `total_followers(bucket: b)`
without a `results.` prefix — the method resolves on the Response object.

```ruby
# agg_scopes — independent, composed at query time
agg_scope :group_by_platform do |agg|
  agg.aggregate(:group_by_platform) { terms field: 'platform', size: 50 }
end

agg_scope :total_followers do |agg|
  agg.aggregate(:total_followers) { sum field: 'follower_count' }
end

class Response < DSLResponse
  # `bucket: nil` — reads from top-level agg; with bucket, reads sub-agg data.
  # Block is instance_exec'd: `{ |b| total_followers(bucket: b) }` resolves on self.
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

  def total_followers(bucket: nil)
    src = bucket || aggregations
    { total_followers: src.dig('total_followers', 'value').to_i }
  end
end
```

### Usage patterns

```ruby
# Plain — no sub-aggs
MyModel.criteria.size(0).group_by_platform.search
  .group_by_platform
# => [{ platform: 'youtube', count: 1 }, ...]

# Composed — add total_followers sub-agg per bucket via call-time block
MyModel.criteria.size(0).group_by_platform { total_followers }.search
  .group_by_platform { |b| total_followers(bucket: b) }
# => [{ platform: 'youtube', count: 1, total_followers: 100_000 }, ...]

# Standalone sum
MyModel.filter { active }.size(0).total_followers.search
  .total_followers
# => { total_followers: 160_000 }
```

### Why `instance_exec`

`row.merge!(instance_exec(b, &block))` — the block runs as if defined on the Response object.
This lets the caller write a clean block: `{ |b| total_followers(bucket: b) }`
rather than `{ |b| results.total_followers(bucket: b) }`.

### Returning safe defaults

- `group_by_platform` returns `[]` when the agg was not requested
- `total_followers` returns `{ total_followers: 0 }` when bucket/agg has no value

---

## Point-in-Time Pagination

Opens a PIT, loops `search_after` pages, closes PIT in `ensure`.

```ruby
# With block — process each page; return falsy to stop early
Model.criteria
     .filter  { active }
     .sort    { { 'published_at' => 'asc' } }
     .search_pit(page_size: 1000, keep_alive: '2m') do |response, cumulative_total|
       process(response.sources)
       cumulative_total < 50_000   # return false to stop early
     end

# Without block — collect all pages
pages = Model.criteria.search_pit(page_size: 1000)
all_sources = pages.flat_map(&:sources)
```

`search_pit` options:

| Option | Default | Description |
|---|---|---|
| `page_size` | `1000` | Hits per page |
| `keep_alive` | config value | ES keep-alive (e.g. `'2m'`) |
| `timeout` | `nil` | Per-request timeout (seconds) |

---

## Dynamic Index Routing

Override `search_index` on the model to route searches to per-year (or other) indices:

```ruby
class Content
  include ES::DSL::Searchable
  index_name 'content_alias'           # default: alias covering all years

  def self.search_index(criteria = nil)
    range    = criteria&.date_filter_for(:published_at)
    return index_name unless range

    gte_year = range['gte'] ? Date.parse(range['gte']).year : nil rescue nil
    lte_year = range['lte'] ? Date.parse(range['lte']).year : nil rescue nil
    year     = gte_year || lte_year
    return index_name unless year

    # Multi-year span → use alias
    return index_name if gte_year && lte_year && gte_year != lte_year

    "content_#{year}"
  end
end
```

Usage:
```ruby
# Routes to content_2025
Content.query { date_range :published_at, from: '2025-01-01', to: '2025-12-31' }.search

# Routes to content_alias (all years)
Content.criteria.search
```
