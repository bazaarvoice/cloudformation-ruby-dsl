# frozen_string_literal: true

require 'rspec/expectations'
require 'json'
require 'aws-sdk'
require 'cfn-model'

RSpec::Matchers.define :have_default_parameter_value do |parameter, param_val|
  # actual == stack dsl
  match do |actual|
    params = JSON.parse(actual.to_json)['Parameters']
    params[parameter.to_s]['Default'] == param_val
  end
  diffable
end

RSpec::Matchers.define :have_output do |output_name|
  match do |actual|
    !JSON.parse(actual.to_json)['Outputs'][output_name.to_s].nil?
  end
  diffable
end

# this can cause rate exceeded exceptions..
RSpec::Matchers.define :validate_with_aws do
  match do |actual|
    begin
      RspecHelpers.cloudformation
                  .validate_template(template_body: actual.to_json)
    rescue Aws::CloudFormation::Errors::ServiceError => e
      puts e
      false
    end
  end
end

RSpec::Matchers.define :contain_resource_type do |cf_resource_type|
  match do |actual|
    cfn_model = CfnParser.new.parse(actual.to_json)
    !cfn_model.resources_by_type(cf_resource_type).empty?
  end
end
