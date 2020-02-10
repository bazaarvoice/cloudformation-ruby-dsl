require 'spec_helper'

RSpec.shared_examples "template acceptance validations" do
  it "should create a valid JSON template from the example ruby template" do
    delete_test_file(json_template)
    json = exec_cmd("./#{ruby_template} expand", :within => "examples").first
    write_test_file(json_template, json)
    validate_cfn_template(json_template)
  end
end

describe "cloudformation-ruby-dsl" do
  context "simplest template" do
    let(:ruby_template) { "simple_template_script.rb" }
    let(:json_template) { "simple_template_script.json" }

    include_examples "template acceptance validations"
  end

  # TODO validate examples/cloudformation-ruby-script.rb
end

describe 'simple_template' do
  subject do
    dsl_file = File.join(from_project_root('examples'), 'simple_template.rb')
    TemplateDSL.new({}).load_from_file(dsl_file)
  end

  it 'has the required parameters' do
    expect(subject).to have_default_parameter_value('Label', 'abcd-label')
  end

  it 'contains SNS topic' do
    expect(subject).to contain_resource_type("AWS::SNS::Topic")
  end
end
