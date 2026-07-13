Gem::Specification.new do |s|
  s.name        = 'es-dsl'
  s.version     = '0.1.0'
  s.summary     = 'Lightweight Elasticsearch ODM — pure Ruby, no external ES dependencies'
  s.authors     = ['Eugene']
  s.files       = Dir['lib/**/*.rb']
  s.require_paths = ['lib']

  s.add_development_dependency 'minitest', '>= 5'
end
