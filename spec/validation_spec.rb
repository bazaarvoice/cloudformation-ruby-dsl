require 'spec_helper'

RSpec.shared_examples "template acceptance validations" do
  include CommandHelpers
  include JsonHelpers
  include FileHelpers
  include AwsHelpers

  it "should create a valid JSON template from the example ruby template" do
    delete_test_file(json_template)
    command = "./#{ruby_template} expand"
    if defined?(parameters)
      params_str = parameters.map { |k, v| [k, v].join('=') }.join(';')
      command += " --parameters #{params_str}"
    end
    json = exec_cmd(command, :within => "examples").first
    write_test_file(json_template, json)
    validate_cfn_template(json_template)
  end
end

describe "cloudformation-ruby-dsl" do
  context "simplest template" do
    let(:ruby_template) { "simple_template.rb" }
    let(:json_template) { "simple_template.json" }

    include_examples "template acceptance validations"
  end

  context "complex template" do
    let(:ruby_template) { "cloudformation-ruby-script.rb" }
    let(:json_template) { "cloudformation-ruby-script.json" }
    let(:parameters) { Hash['Label' => 'Foobar'] }

    include_examples "template acceptance validations"
  end
end
