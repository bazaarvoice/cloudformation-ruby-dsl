#!/usr/bin/env ruby
require 'bundler/setup'
require 'cloudformation-ruby-dsl/cfntemplate'

template = template do
  resource "HelloBucket", :Type => "AWS::S3::Bucket"
end

template.exec!
