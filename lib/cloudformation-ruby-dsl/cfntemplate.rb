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

require 'cloudformation-ruby-dsl/dsl'

unless RUBY_VERSION >= '1.9'
  # This script uses Ruby 1.9 functions such as Enumerable.slice_before and Enumerable.chunk
  $stderr.puts "This script requires ruby 1.9+.  On OS/X use Homebrew to install ruby 1.9:"
  $stderr.puts "  brew install ruby"
  exit(2)
end

require 'rubygems'
require 'json'
require 'yaml'
require 'erb'
require 'aws-sdk'
require 'diffy'
require 'highline/import'

############################# AWS SDK Support

class AwsClients
  attr_accessor :cfn_client_instance

  def initialize(args)
    Aws.config[:region] = args[:region] if args.key?(:region)
    # Profile definition was replaced with environment variables
    if args.key?(:aws_profile) && !(args[:aws_profile].nil? || args[:aws_profile].empty?)
        ENV['AWS_PROFILE'] = args[:aws_profile]
        ENV['AWS_ACCESS_KEY'] = nil
        ENV['AWS_ACCESS_KEY_ID'] = nil
        ENV['AMAZON_ACCESS_KEY_ID'] = nil
    end
    # Following line can be uncommented only when Amazon will provide the stable version of this functionality.
    # Aws.config[:credentials] = Aws::SharedCredentials.new(profile_name: args[:aws_profile]) unless args[:aws_profile].nil?
  end

  def cfn_client
    if @cfn_client_instance == nil
        # credentials are loaded from the environment; see http://docs.aws.amazon.com/sdkforruby/api/Aws/CloudFormation/Client.html
        @cfn_client_instance = Aws::CloudFormation::Client.new(
        # we don't validate parameters because the aws-ruby-sdk gets a number parameter and expects it to be a string and fails the validation
        # see: https://github.com/aws/aws-sdk-ruby/issues/848
        validate_params: false
      )
    end
    @cfn_client_instance
  end

  def s3_client
    if @s3_client_instance == nil
      @s3_client_instance = Aws::S3::Client.new()
    end
    @s3_client_instance
  end
end

# utility class to deserialize Structs as JSON
# borrowed from http://ruhe.tumblr.com/post/565540643/generate-json-from-ruby-struct
class Struct
  def to_map
    map = Hash.new
    self.members.each { |m| map[m] = self[m] }
    map
  end

  def to_json(*a)
    to_map.to_json(*a)
  end
end

############################# Command-line support

# Parse command-line arguments and return the parameters and region
def parse_args
  args = {
    :stack_name  => nil,
    :parameters  => {},
    :interactive => false,
    :region      => default_region,
    :profile     => nil,
    :nopretty    => false,
    :s3_bucket   => nil,
  }
  ARGV.slice_before(/^--/).each do |name, value|
    case name
    when '--stack-name'
      args[:stack_name] = value
    when '--parameters'
      args[:parameters] = Hash[value.split(/;/).map { |pair| parts = pair.split(/=/, 2); [ parts[0], TemplateParameter.new(parts[1]) ] }]
    when '--interactive'
      args[:interactive] = true
    when '--region'
      args[:region] = value
    when '--profile'
      args[:profile] = value
    when '--nopretty'
      args[:nopretty] = true
    when '--s3-bucket'
      args[:s3_bucket] = value
    end
  end

  args
end

def validate_action(action)
  valid = %w[
    help
    expand
    diff
    validate
    create
    update
    cancel-update
    delete
    describe
    describe-resource
    get-template
  ]
  removed = %w[
    cfn-list-stack-resources
    cfn-list-stacks
  ]
  deprecated = {
    "cfn-validate-template"        => "validate",
    "cfn-create-stack"             => "create",
    "cfn-update-stack"             => "update",
    "cfn-cancel-update-stack"      => "cancel-update",
    "cfn-delete-stack"             => "delete",
    "cfn-describe-stack-events"    => "describe",
    "cfn-describe-stack-resources" => "describe",
    "cfn-describe-stack-resource"  => "describe-resource",
    "cfn-get-template"             => "get-template"
  }
  if deprecated.keys.include? action
    replacement = deprecated[action]
    $stderr.puts "WARNING: '#{action}' is deprecated and will be removed in a future version. Please use '#{replacement}' instead."
    action = replacement
  end
  unless valid.include? action
    if removed.include? action
      $stderr.puts "ERROR: native command #{action} is no longer supported by cloudformation-ruby-dsl."
    end
    $stderr.puts "usage: #{$PROGRAM_NAME} <#{valid.join('|')}>"
    exit(2)
  end
  action
end

def cfn(template)
  aws_clients = AwsClients.new({:region => template.aws_region, :aws_profile => template.aws_profile})
  cfn_client = aws_clients.cfn_client
  s3_client = aws_clients.s3_client

  action = validate_action( ARGV[0] )

  # Find parameters where extension attributes are true then remove them from the
  # cfn template since we can't pass it to CloudFormation.
  excised_parameters = template.excise_parameter_attributes!([:Immutable, :UsePreviousValue])

  # Tag CloudFormation stacks based on :Tags defined in the template.
  # Remove them from the template as well, so that the template is valid.
  cfn_tags = template.excise_tags!

  # Find tags where extension attribute `:Immutable` is true then remove it from the
  # tag's properties hash since it can't be passed to CloudFormation.
  immutable_tags = template.get_tag_attribute(cfn_tags, :Immutable)

  cfn_tags.each {|k, v| cfn_tags[k] = v[:Value].to_s}

  template_string = generate_template(template)

  # Derive stack name from ARGV
  _, options = extract_options(ARGV[1..-1], %w(--nopretty), %w(--profile --stack-name --region --parameters --tag --s3-bucket))
  # If the first argument is not an option and stack_name is undefined, assume it's the stack name
  # The second argument, if present, is the resource name used by the describe-resource command
  if template.stack_name.nil?
    stack_name = options.shift if options[0] && !(/^-/ =~ options[0])
    resource_name = options.shift if options[0] && !(/^-/ =~ options[0])
  else
    stack_name = template.stack_name
  end

  case action
  when 'help'
  begin
    # Give some basic usage.
    help_string=%q(
## Usage

To convert existing JSON templates to use the DSL, run

    cfntemplate-to-ruby [EXISTING_CFN] > [NEW_NAME.rb]

You may need to preface this with `bundle exec` if you installed via Bundler.

Make the resulting file executable (`chmod +x [NEW_NAME.rb]`). It can respond to the following subcommands (which are listed if you run without parameters):
- `expand`: output the JSON template to the command line (takes optional `--nopretty` to minimize the output)
- `diff`: compare an existing stack with your template. Produces following exit codes:
```
    0 - no differences, nothing to update
    1 - stack does not exist, template Validation error
    2 - there are differences between an existing stack and your template
```
- `validate`: run validation against the stack definition
- `create`: create a new stack from the output
- `update`: update an existing stack from the output. Produces following exit codes:
```
    0 - update finished successfully
    1 - no updates to perform, stack doesn't exist, unable to update immutable parameter or tag, AWS ServiceError exception
```
- `cancel-update`: cancel updating a stack
- `delete`: delete a stack (with prompt)
- `describe`: get output of an existing stack and output it (takes optional `--nopretty` to minimize output)
- `describe-resource`: given two arguments: stack-name and logical-resource-id, get output from a stack concerning the specific resource (takes optional `--nopretty` to minimize output)
- `get-template`: get entire template output of an existing stack

Command line options similar to cloudformation commands, but parsed by the dsl.
 --profile --stack-name --region --parameters --tag --s3-bucket

Any other parameters are passed directly onto cloudformation. (--disable-rollback for instance)

Using the ruby scripts:
template.rb create --stack-name my_stack --parameters "BucketName=bucket-s3-static;SnsQueue=mysnsqueue"

)
    puts help_string
    exit(true)
  end

  when 'expand'
    # Write the pretty-printed JSON template to stdout and exit.  [--nopretty] option writes output with minimal whitespace
    # example: <template.rb> expand --parameters "Env=prod" --region eu-west-1 --nopretty
    template_string

  when 'diff'
    # example: <template.rb> diff my-stack-name --parameters "Env=prod" --region eu-west-1
    # Diff the current template for an existing stack with the expansion of this template.

    # `diff` operation exit codes are:
      # 0 - no differences are found. Outputs nothing to make it easy to use the output of the diff call from within other scripts.
      # 1 - produced by any ValidationError exception (e.g. "Stack with id does not exist")
      # 2 - there are changes to update (tags, params, template)
    # If you want output of the entire file, simply use this option with a large number, i.e., -U 10000
    # In fact, this is what Diffy does by default; we just don't want that, and we can't support passing arbitrary options to diff
    # because Diffy's "context" configuration is mutually exclusive with the configuration to pass arbitrary options to diff
    if !options.include? '-U'
      options.push('-U', '0')
    end

    # Ensure a stack name was provided
    if stack_name.empty?
      $stderr.puts "Error: a stack name is required"
      exit(false)
    end

    # describe the existing stack
    begin
      old_template_body = cfn_client.get_template({stack_name: stack_name}).template_body
    rescue Aws::CloudFormation::Errors::ValidationError => e
      $stderr.puts "Error: #{e}"
      exit(false)
    end

    # parse the string into a Hash, then convert back into a string; this is the only way Ruby JSON lets us pretty print a JSON string
    old_template   = JSON.pretty_generate(JSON.parse(old_template_body))
    # there is only ever one stack, since stack names are unique
    old_attributes = cfn_client.describe_stacks({stack_name: stack_name}).stacks[0]
    old_tags       = old_attributes.tags
    old_parameters = Hash[old_attributes.parameters.map { |p| [p.parameter_key, p.parameter_value]}]

    # Sort the tag strings alphabetically to make them easily comparable
    old_tags_string = old_tags.map { |tag| %Q(TAG "#{tag.key}=#{tag.value}"\n) }.sort.join
    tags_string     = cfn_tags.map { |k, v| %Q(TAG "#{k.to_s}=#{v}"\n) }.sort.join

    # Sort the parameter strings alphabetically to make them easily comparable
    old_parameters_string = old_parameters.sort.map { |key, value| %Q(PARAMETER "#{key}=#{value}"\n) }.join
    parameters_string     = template.parameters.sort.map do |key, value|
      value = old_parameters[key] if value.empty? && value.use_previous_value && !old_parameters[key].to_s.empty?
      value = value.default if value.empty? && !value.default.to_s.empty?
      "PARAMETER \"#{key}=#{value}\"\n"
    end.join

    # set default diff options
    Diffy::Diff.default_options.merge!(
      :diff    => "#{options.join(' ')}",
    )
    # set default diff output
    Diffy::Diff.default_format = :color

    tags_diff     = Diffy::Diff.new(old_tags_string, tags_string).to_s.strip!
    params_diff   = Diffy::Diff.new(old_parameters_string, parameters_string).to_s.strip!
    template_diff = Diffy::Diff.new(old_template, template_string).to_s.strip!

    if !tags_diff.empty?
      puts "====== Tags ======"
      puts tags_diff
      puts "=================="
      puts
    end

    if !params_diff.empty?
      puts "====== Parameters ======"
      puts params_diff
      puts "========================"
      puts
    end

    if !template_diff.empty?
      puts "====== Template ======"
      puts template_diff
      puts "======================"
      puts
    end

    if tags_diff.empty? && params_diff.empty? && template_diff.empty?
      exit(true)
    else
      exit(2)
    end

  when 'validate'
    begin
      validation_payload = {}
      if template.s3_bucket.nil? then
        validation_payload = {template_body: template_string}
      else
        template_path = "#{Time.now.strftime("%s")}/#{stack_name}.json"
        # assumption: JSON is the only supported serialization format (YAML not allowed)
        template_url = "https://s3.amazonaws.com/#{template.s3_bucket}/#{template_path}"
        begin
          s3_client.put_object({
            bucket: template.s3_bucket,
            key: template_path,
            # canned ACL for authorized users to read the bucket (that should be *this* IAM role!)
            acl: "private",
            body: template_string,
          })
        rescue Aws::S3::Errors::ServiceError => e
          $stderr.puts "Failed to upload stack template to S3: #{e}"
          exit(false)
        end
        validation_payload = {template_url: template_url}
      end
      valid = cfn_client.validate_template(validation_payload)
      if valid.successful?
        puts "Validation successful"
        exit(true)
      end
    rescue Aws::CloudFormation::Errors::ValidationError => e
      $stderr.puts "Validation error: #{e}"
      exit(false)
    end

  when 'create'
    begin

      # Apply any default parameter values
      apply_parameter_defaults(template.parameters)

      # default options (not overridable)
      create_stack_opts = {
          stack_name: stack_name,
          parameters: template.parameters.map { |k,v| {parameter_key: k, parameter_value: v}}.to_a,
          tags: cfn_tags.map { |k,v| {"key" => k.to_s, "value" => v} }.to_a,
          capabilities: ["CAPABILITY_NAMED_IAM"],
      }

      # If the user supplied the --s3-bucket option and
      # access to the bucket, upload the template body to S3
      if template.s3_bucket.nil? then
        create_stack_opts["template_body"] = template_string
      else
        template_path = "#{Time.now.strftime("%s")}/#{stack_name}.json"
        # assumption: JSON is the only supported serialization format (YAML not allowed)
        template_url = "https://s3.amazonaws.com/#{template.s3_bucket}/#{template_path}"
        begin
          s3_client.put_object({
            bucket: template.s3_bucket,
            key: template_path,
            # canned ACL for authorized users to read the bucket (that should be *this* IAM role!)
            acl: "private",
            body: template_string,
          })
        rescue Aws::S3::Errors::ServiceError => e
          $stderr.puts "Failed to upload stack template to S3: #{e}"
          exit(false)
        end
        create_stack_opts["template_url"] = template_url
      end

      # fill in options from the command line
      extra_options = parse_arg_array_as_hash(options)
      create_stack_opts = extra_options.merge(create_stack_opts)

      # remove custom options
      create_stack_opts.delete(:interactive)

      # create stack
      create_result = cfn_client.create_stack(create_stack_opts)
      if create_result.successful?
        puts create_result.stack_id
        exit(true)
      end
    rescue Aws::CloudFormation::Errors::ServiceError => e
      $stderr.puts "Failed to create stack: #{e}"
      exit(false)
    end

  when 'cancel-update'
    begin
      cancel_update_result = cfn_client.cancel_update_stack({stack_name: stack_name})
      if cancel_update_result.successful?
        $stderr.puts "Canceled updating stack #{stack_name}."
        exit(true)
      end
    rescue Aws::CloudFormation::Errors::ServiceError => e
      $stderr.puts "Failed to cancel updating stack: #{e}"
      exit(false)
    end

  when 'delete'
    begin
      if HighLine.agree("Really delete #{stack_name} in #{cfn_client.config.region}? [Y/n]")
        delete_result = cfn_client.delete_stack({stack_name: stack_name})
        if delete_result.successful?
          $stderr.puts "Deleted stack #{stack_name}."
          exit(true)
        end
      else
        $stderr.puts "Canceled deleting stack #{stack_name}."
        exit(true)
      end
      rescue Aws::CloudFormation::Errors::ServiceError => e
        $stderr.puts "Failed to delete stack: #{e}"
        exit(false)
    end

  when 'describe'
    begin
      describe_stack = cfn_client.describe_stacks({stack_name: stack_name})
      describe_stack_resources = cfn_client.describe_stack_resources({stack_name: stack_name})
      if describe_stack.successful? and describe_stack_resources.successful?
        stacks = {}
        stack_resources = {}
        describe_stack_resources.stack_resources.each { |stack_resource|
          if stack_resources[stack_resource.stack_name].nil?
            stack_resources[stack_resource.stack_name] = []
          end
          stack_resources[stack_resource.stack_name].push({
            logical_resource_id: stack_resource.logical_resource_id,
            physical_resource_id: stack_resource.physical_resource_id,
            resource_type: stack_resource.resource_type,
            timestamp: stack_resource.timestamp,
            resource_status: stack_resource.resource_status,
            resource_status_reason: stack_resource.resource_status_reason,
            description: stack_resource.description,
          })
        }
        describe_stack.stacks.each { |stack| stacks[stack.stack_name] = stack.to_map.merge!({resources: stack_resources[stack.stack_name]}) }
        unless template.nopretty
          puts JSON.pretty_generate(stacks)
        else
          puts JSON.generate(stacks)
        end
        exit(true)
      end
    rescue Aws::CloudFormation::Errors::ServiceError => e
      $stderr.puts "Failed describe stack #{stack_name}: #{e}"
      exit(false)
    end

  when 'describe-resource'
    begin
      describe_stack_resource = cfn_client.describe_stack_resource({
        stack_name: stack_name,
        logical_resource_id: resource_name,
      })
      if describe_stack_resource.successful?
        unless template.nopretty
          puts JSON.pretty_generate(describe_stack_resource.stack_resource_detail)
        else
          puts JSON.generate(describe_stack_resource.stack_resource_detail)
        end
        exit(true)
      end
    rescue Aws::CloudFormation::Errors::ServiceError => e
      $stderr.puts "Failed get stack resource details: #{e}"
      exit(false)
    end

  when 'get-template'
    begin
      get_template_result = cfn_client.get_template({stack_name: stack_name})
      template_body = JSON.parse(get_template_result.template_body)
      if get_template_result.successful?
        unless template.nopretty
          puts JSON.pretty_generate(template_body)
        else
          puts JSON.generate(template_body)
        end
        exit(true)
      end
    rescue Aws::CloudFormation::Errors::ServiceError => e
      $stderr.puts "Failed get stack template: #{e}"
      exit(false)
    end

  when 'update'

    # Run CloudFormation command to describe the existing stack
    old_stack = cfn_client.describe_stacks({stack_name: stack_name}).stacks

    # this might happen if, for example, stack_name is an empty string and the Cfn client returns ALL stacks
    if old_stack.length > 1
      $stderr.puts "Error: found too many stacks with this name. There should only be one."
      exit(false)
    else
      # grab the first (and only) result
      old_stack = old_stack[0]
    end

    # If updating a stack and some parameters or tags are marked as immutable, set the variable to true.
    immutables_exist = nil

    old_parameters = Hash[old_stack.parameters.map { |p| [p.parameter_key, p.parameter_value]}]
    new_parameters = template.parameters
    excised_parameters.each do |extension_attribute, parameters|
      if !parameters.empty?
        parameters.sort.each do |param|
          if old_parameters[param] != new_parameters[param] && old_parameters.key?(param)
            case extension_attribute
            when :Immutable
              if !excised_parameters[:UsePreviousValue].include?(param)
                $stderr.puts "Error: unable to update immutable parameter " +
                                 "'#{param}=#{old_parameters[param]}' to '#{param}=#{new_parameters[param]}'."
                immutables_exist = true
              end
            when :UsePreviousValue
              if !immutables_exist && new_parameters[param].empty?
                $stderr.puts "Using previous parameter " +
                                 "'#{param}=#{old_parameters[param]}'."
                new_parameters[param] = TemplateParameter.new(old_parameters[param])
                new_parameters[param].use_previous_value = true
              end
            end
          end
        end
      end
    end

    if not immutable_tags.empty?
      old_cfn_tags = Hash[old_stack.tags.map { |t| [t.key, t.value]}]
      cfn_tags_ary = Hash[cfn_tags.map { |k,v| [k, v]}]
      immutable_tags.sort.each do |tag|
        if old_cfn_tags[tag].to_s != cfn_tags_ary[tag].to_s && old_cfn_tags.key?(tag)
          $stderr.puts "Error: unable to update immutable tag " +
                           "'#{tag}=#{old_cfn_tags[tag]}' to '#{tag}=#{cfn_tags_ary[tag]}'."
          immutables_exist = true
        end
      end
    end

    # Fail if some parameters or tags were marked as immutable.
    if immutables_exist
      exit(false)
    end

    # Apply any default parameter values
    apply_parameter_defaults(template.parameters)

    # Compare the sorted arrays of parameters for an exact match and print difference.
    old_parameters = old_stack.parameters.map { |p| [p.parameter_key, p.parameter_value]}.sort
    new_parameters = template.parameters.sort
    if new_parameters != old_parameters
      puts "\nCloudFormation stack parameters that do not match and will be updated:" +
               "\n" + (old_parameters - new_parameters).map {|param| "< #{param}" }.join("\n") +
               "\n" + "---" +
               "\n" + (new_parameters - old_parameters).map {|param| "> #{param}"}.join("\n")
    end

    # Compare the sorted arrays of tags for an exact match and print difference.
    old_cfn_tags = old_stack.tags.map { |t| [t.key, t.value]}.sort
    cfn_tags_ary = cfn_tags.map { |k,v| [k, v]}.sort
    if cfn_tags_ary != old_cfn_tags
      puts "\nCloudFormation stack tags that do not match and will be updated:" +
               "\n" + (old_cfn_tags - cfn_tags_ary).map {|tag| "< #{tag}" }.join("\n") +
               "\n" + "---" +
               "\n" + (cfn_tags_ary - old_cfn_tags).map {|tag| "> #{tag}"}.join("\n")
    end

    # update the stack
    begin

      # default options (not overridable)
      update_stack_opts = {
          stack_name: stack_name,
          parameters: template.parameters.map { |k,v| (v.use_previous_value && old_parameters.include?([k,v])) ? {parameter_key: k, use_previous_value: v.use_previous_value.to_s} : {parameter_key: k, parameter_value: v}}.to_a,
          tags: cfn_tags.map { |k,v| {"key" => k.to_s, "value" => v.to_s} }.to_a,
          capabilities: ["CAPABILITY_NAMED_IAM"],
      }

      # if the the user supplies a bucket bucket and
      # access to it, upload the template body
      if template.s3_bucket.nil? then
        update_stack_opts["template_body"] = template_string
      else
        template_path = "#{Time.now.strftime("%s")}/#{stack_name}.json"
        # assumption: JSON is the only supported serialization format (YAML not allowed)
        template_url = "https://s3.amazonaws.com/#{template.s3_bucket}/#{template_path}"
        s3_client.put_object({
          bucket: template.s3_bucket,
          key: template_path,
          # canned ACL for authorized users to read the bucket (that should be *this* IAM role!)
          acl: "private",
          body: template_string,
        })
        update_stack_opts["template_url"] = template_url
      end

      # fill in options from the command line
      extra_options = parse_arg_array_as_hash(options)
      update_stack_opts = extra_options.merge(update_stack_opts)

      # remove custom options
      update_stack_opts.delete(:interactive)

      # update the stack
      update_result = cfn_client.update_stack(update_stack_opts)
      if update_result.successful?
        puts update_result.stack_id
        exit(true)
      end
    rescue Aws::CloudFormation::Errors::ServiceError => e
      $stderr.puts "Failed to update stack: #{e}"
      exit(false)
    end

  end
end

# extract options and arguments from a command line string
#
# Example:
#
# desired, unknown = extract_options("arg1 --option withvalue --optionwithoutvalue", %w(--option), %w())
#
# puts desired => Array{"arg1", "--option", "withvalue"}
# puts unknown => Array{}
#
# @param args
#   the Array of arguments (split the command line string by whitespace)
# @param opts_no_val
#   the Array of options with no value, i.e., --force
# @param opts_1_val
#   the Array of options with exaclty one value, i.e., --retries 3
# @returns
#   an Array of two Arrays.
#   The first array contains all the options that were extracted (both those with and without values) as a flattened enumerable.
#   The second array contains all the options that were not extracted.
def extract_options(args, opts_no_val, opts_1_val)
  args = args.clone
  opts = []
  rest = []
  while (arg = args.shift) != nil
    if opts_no_val.include?(arg)
      opts.push(arg)
    elsif opts_1_val.include?(arg)
      opts.push(arg)
      opts.push(arg) if (arg = args.shift) != nil
    else
      rest.push(arg)
    end
  end
  [opts, rest]
end

# convert an array of option strings to a hash
# example input: ["--option", "value", "--optionwithnovalue"]
# example output: {:option => "value", :optionwithnovalue: true}
def parse_arg_array_as_hash(options)
  result = {}
  options.slice_before(/\A--[a-zA-Z_-]\S/).each { |o|
      key = ((o[0].sub '--', '').gsub '-', '_').downcase.to_sym
      value = if o.length > 1 then o.drop(1) else true end
      value = value[0] if value.is_a?(Array) and value.length == 1
      result[key] = value
  }
  result
end

# Apply the default value for any parameter not assigned by the user
def apply_parameter_defaults(parameters)
  parameters.each do |k, v|
    if v.empty?
      parameters[k] = TemplateParameter.new(v.default)
      $stderr.puts "Using default parameter value " +
                       "'#{k}=#{parameters[k]}'."
    end
  end
end

##################################### Additional dsl logic
# Core interpreter for the DSL
class TemplateDSL < JsonObjectDSL
  def exec!
    puts cfn(self)
  end
  def exec
    cfn(self)
  end
end

# Main entry point
def template(&block)
  options = parse_args
  raw_template(options, &block)
end
