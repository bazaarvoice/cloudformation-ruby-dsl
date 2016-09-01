require 'spec_helper'

RSpec.shared_examples "template acceptance validations" do
  include CommandHelpers
  include JsonHelpers
  include FileHelpers
  include AwsHelpers

  it "should create a valid JSON template from the example ruby template" do
    delete_test_file(json_template)
    json = exec_cmd("./#{ruby_template} expand", :within => "examples").first
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

  # TODO validate examples/cloudformation-ruby-script.rb
end
