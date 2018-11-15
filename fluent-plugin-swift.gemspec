# encoding: utf-8
$:.push File.expand_path('../lib', __FILE__)

Gem::Specification.new do |gem|
  gem.name        = "fluent-plugin-swift"
  gem.description = "OpenStack Storage Service (Swift) output plugin for Fluentd event collector"
  gem.homepage    = "https://github.com/yuuzi41/fluent-plugin-swift"
  gem.summary     = gem.description
  gem.version     = File.read("VERSION").strip
  gem.license     = "Apache-2.0"
  gem.authors     = ["yuuzi41"]
  gem.email       = ""
  #gem.has_rdoc    = false
  #gem.platform    = Gem::Platform::RUBY
  gem.files       = `git ls-files`.split("\n")
  gem.test_files  = `git ls-files -- {test,spec,features}/*`.split("\n")
  gem.executables = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  gem.require_paths = ['lib']

  gem.add_runtime_dependency "fluentd", [">= 0.14.2", "< 2"]
  gem.add_runtime_dependency "fog-openstack"
  gem.add_runtime_dependency "uuidtools"
  gem.add_development_dependency "flexmock", ">= 1.2.0"
  gem.add_development_dependency "bundler", "~> 1.14"
  gem.add_development_dependency "rake", "~> 12.0"
  gem.add_development_dependency "test-unit", ">= 3.1.0"
# fog
  gem.add_dependency("xmlrpc") if RUBY_VERSION.to_s >= "2.4"
end
