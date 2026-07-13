# frozen_string_literal: true

require_relative '../models/engineer'

# Fluent search object for engineer queries.
# Each method applies a filter (or sort/pagination setting) to the criteria
# and returns self, mirroring the original QueryBuilder interface.
class EngineerSearch
  attr_reader :criteria

  def initialize
    @criteria = EngineerModel.criteria
  end

  # ── Pagination / source ──────────────────────────────────────────────────────

  def from(from)
    @criteria = @criteria.from(from)
    self
  end

  def size(size)
    @criteria = @criteria.size(size)
    self
  end

  def track_total_hits(value)
    @criteria = @criteria.track_total_hits(value)
    self
  end

  # ── Identity filters ─────────────────────────────────────────────────────────

  def engineer_ids(ids)
    return self unless ids&.any?

    @criteria = @criteria.filter { by_ids ids }
    self
  end

  def excluded_engineer_ids(ids)
    return self unless ids&.any?

    @criteria = @criteria.filter { exclude_ids ids }
    self
  end

  # ── Org filters ───────────────────────────────────────────────────────────────

  def department(department)
    return self unless department

    @criteria = @criteria.filter { by_department department }
    self
  end

  def departments(values)
    return self unless values&.any?

    @criteria = @criteria.filter { by_departments values }
    self
  end

  def roles(roles)
    return self unless roles&.any?

    @criteria = @criteria.filter { by_roles roles }
    self
  end

  # ── Status / attribute filters ───────────────────────────────────────────────

  def active_only
    @criteria = @criteria.filter { active_only }
    self
  end

  def verified_only
    @criteria = @criteria.filter { verified_only }
    self
  end

  def exclude_status(status)
    return self unless status

    @criteria = @criteria.filter { exclude_status status }
    self
  end

  # ── Location filters ─────────────────────────────────────────────────────────

  def city(city)
    return self unless city&.strip&.length&.positive?

    @criteria = @criteria.filter { by_city city }
    self
  end

  def countries(countries)
    return self unless countries&.any?

    @criteria = @criteria.filter { by_countries countries }
    self
  end

  # ── Skill filters ─────────────────────────────────────────────────────────────

  def skill(skill)
    return self unless EngineerModel::SKILLS.include?(skill)

    @criteria = @criteria.filter { has_skill skill }
    self
  end

  def any_skills(skills)
    return self unless skills&.any?

    @criteria = @criteria.filter { any_skills skills }
    self
  end

  def all_skills(skills)
    return self unless skills&.any?

    @criteria = @criteria.filter { all_skills skills }
    self
  end

  # ── Commit activity filters ──────────────────────────────────────────────────

  def commits_gte(n)
    return self unless n

    @criteria = @criteria.filter { commits_gte n }
    self
  end

  def commits_lte(n)
    return self unless n

    @criteria = @criteria.filter { commits_lte n }
    self
  end

  # ── Hire date filter ─────────────────────────────────────────────────────────

  def hired_between(from, to)
    return self unless from && to

    @criteria = @criteria.filter { hired_between from, to }
    self
  end

  # ── Certification filter ─────────────────────────────────────────────────────

  def certification(name)
    return self unless name

    @criteria = @criteria.filter { by_certification name }
    self
  end

  # ── Sort ─────────────────────────────────────────────────────────────────────

  def sort_by_relevance
    @criteria = @criteria.sort { { '_score' => 'desc' } }
    self
  end

  def sort_by(field, direction = 'desc')
    @criteria = @criteria.sort { { field.to_s => direction.to_s } }
    self
  end

  # ── Execution ────────────────────────────────────────────────────────────────

  def search
    @criteria.search
  end
end
