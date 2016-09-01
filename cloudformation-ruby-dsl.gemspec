# -*- encoding: utf-8 -*-

# Copyright 2013-2014 Bazaarvoice, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'cloudformation-ruby-dsl/version'

Gem::Specification.new do |gem|
  gem.name          = "cloudformation-ruby-dsl"
  gem.version       = Cfn::Ruby::Dsl::VERSION
  gem.authors       = ["Shawn Smith", "Dave Barcelo", "Morgan Fletcher", "Csongor Gyuricza", "Igor Polishchuk", "Nathaniel Eliot", "Jona Fenocchi", "Tony Cui"]
  gem.email         = ["Shawn.Smith@bazaarvoice.com", "Dave.Barcelo@bazaarvoice.com", "Morgan.Fletcher@bazaarvoice.com", "Csongor.Gyuricza@bazaarvoice.com", "Igor.Polishchuk@bazaarvoice.com", "Nathaniel.Eliot@bazaarvoice.com", "Jona.Fenocchi@bazaarvoice.com", "Tony.Cui@bazaarvoice.com"]
  gem.description   = %q{Ruby DSL library that provides a wrapper around the CloudFormation.}
  gem.summary       = %q{Ruby DSL library that provides a wrapper around the CloudFormation.  Written by [Bazaarvoice](http://www.bazaarvoice.com).}
  gem.homepage      = "http://github.com/bazaarvoice/cloudformation-ruby-dsl"

  gem.files         = `git ls-files`.split($/)
  gem.executables   = gem.files.grep(%r{^bin/}).map{ |f| File.basename(f) }
  gem.test_files    = gem.files.grep(%r{^(test|spec|features)/})
  gem.require_paths = %w{lib bin}

  gem.add_runtime_dependency    'detabulator'
  gem.add_runtime_dependency    'json'
  gem.add_runtime_dependency    'bundler'
  gem.add_runtime_dependency    'aws-sdk', '>=2.5.1'
  gem.add_runtime_dependency    'diffy'
  gem.add_runtime_dependency    'highline'
  gem.add_runtime_dependency    'rake'

  gem.add_development_dependency 'rspec'
  gem.add_development_dependency 'pry'
end
