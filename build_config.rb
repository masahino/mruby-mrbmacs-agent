MRuby::Build.new do |conf|
  toolchain :clang
  conf.enable_test
  conf.gembox 'default'
  conf.gem github: 'iij/mruby-regexp-pcre' do |gem|
    gem.skip_test = true
  end
  conf.gem github: 'mattn/mruby-iconv' do |gem|
    gem.skip_test = true
  end
  conf.gem github: 'masahino/mruby-scintilla-base'
  conf.gem github: 'masahino/mruby-mrbmacs-base'
  conf.gem File.expand_path(__dir__)
end
