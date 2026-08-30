MRuby::Gem::Specification.new('mruby-mrbmacs-agent') do |spec|
  spec.license = 'MIT'
  spec.authors = 'masahino'
  spec.version = '0.1.0'

  spec.add_dependency 'mruby-mrbmacs-base', github: 'masahino/mruby-mrbmacs-base'
end
