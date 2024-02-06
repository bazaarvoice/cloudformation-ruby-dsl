require "yaml"

def params
  @_params_ ||= ::YAML.load_file(__dir__ + "/simple_template_params.yml")
end

def sns_topic(name)
  resource "#{name}Topic", Type: 'AWS::SNS::Topic', Properties: {
      DisplayName: name,
      TopicName: name
    }
end