#!/usr/bin/env ruby
require 'bundler/setup'
require 'cloudformation-ruby-dsl/cfntemplate'

tmpl = template do
  @stack_name = 'hello-bucket-example'

  parameter 'Label',
            :Description => 'The label to apply to the bucket.',
            :Type => 'String',
            :Default => 'cfnrdsl',
            :UsePreviousValue => true

  resource "HelloBucket",
            :Type => 'AWS::S3::Bucket',
            :Properties => {
              :BucketName => ref('Label')
            }
            
end

tmpl.exec!
