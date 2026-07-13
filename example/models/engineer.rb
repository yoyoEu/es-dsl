# frozen_string_literal: true

require_relative '../../lib/es/dsl'

class EngineerModel
  include ES::DSL::Searchable
  index_name 'engineers'

  SKILLS = %w[ruby python javascript elasticsearch kubernetes react go rust aws terraform].freeze

  # ── Filter scopes ────────────────────────────────────────────────────────────

  scope :verified_only do
    term :verified, true
  end

  scope :active_only do
    term :status, 'active'
  end

  scope :exclude_status do |status|
    bool do
      must_not { term :status, status }
    end
  end

  scope :by_ids do |ids|
    terms :_id, ids
  end

  scope :exclude_ids do |ids|
    bool do
      must_not { terms :_id, ids }
    end
  end

  scope :by_department do |department|
    term 'department', department
  end

  scope :by_departments do |departments|
    terms 'department', departments
  end

  scope :by_roles do |roles|
    terms 'role', roles
  end

  scope :by_city do |city|
    term 'location.city', city
  end

  scope :by_countries do |countries|
    terms 'location.country', countries
  end

  scope :has_skill do |skill|
    term 'skills', skill
  end

  # Matches engineers who have at least one of the given skills.
  scope :any_skills do |skills|
    bool do
      skills.each { |s| should { term 'skills', s } }
      minimum_should_match 1
    end
  end

  # Matches engineers who have all of the given skills.
  scope :all_skills do |skills|
    bool do
      skills.each { |s| must { term 'skills', s } }
    end
  end

  scope :commits_gte do |n|
    range 'commit_count', gte: n
  end

  scope :commits_lte do |n|
    range 'commit_count', lte: n
  end

  scope :hired_between do |from, to|
    range 'hire_date', gte: from, lte: to
  end

  # Nested certifications filter: matches engineers holding a given certification.
  scope :by_certification do |name|
    nested('certifications') { term 'certifications.name', name }
  end

  # ── Aggregation scopes ───────────────────────────────────────────────────────

  # Builds a department terms aggregation with per-skill filter sub-aggs.
  agg_scope :group_by_department_with_skills do |agg|
    agg.aggregate('group_by_department') do
      terms field: 'department', size: 50
      aggregate(:skills) do |sub|
        SKILLS.each do |skill|
          sub.filters(skill.to_sym) { term 'skills', skill }
        end
      end
    end
  end
end
