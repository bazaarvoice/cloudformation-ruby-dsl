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
require 'xmlsimple'

VENDOR_PATH = File.expand_path("../../../vendor/AWSCloudFormation-1.0.12", __FILE__)
SYSTEM_ENV = "export PATH=#{VENDOR_PATH}/bin:$PATH; export AWS_CLOUDFORMATION_HOME=#{VENDOR_PATH}"

############################# Command-line and "cfn-cmd" Support

# Parse command-line arguments based on cfn-cmd syntax (cfn-create-stack etc.) and return the parameters and region
def cfn_parse_args
  stack_name = nil
  parameters = {}
  region = default_region
  nopretty = false
  ARGV.slice_before(/^--/).each do |name, value|
    case name
    when '--stack-name'
      stack_name = value
    when '--parameters'
      parameters = Hash[value.split(/;/).map { |pair| pair.split(/=/, 2) }]
    when '--region'
      region = value
    when '--nopretty'
      nopretty = true
    end
  end
  [stack_name, parameters, region, nopretty]
end

def cfn_cmd(template)
  action = ARGV[0]
  unless %w(expand diff cfn-validate-template cfn-create-stack cfn-update-stack).include? action
    $stderr.puts "usage: #{$PROGRAM_NAME} <expand|diff|cfn-validate-template|cfn-create-stack|cfn-update-stack>"
    exit(2)
  end
  unless (ARGV & %w(--template-file --template-url)).empty?
    $stderr.puts "#{File.basename($PROGRAM_NAME)}:  The --template-file and --template-url command-line options are not allowed."
    exit(2)
  end

  # Find parameters where extension attribute :Immutable is true then remove it from the
  # cfn template since we can't pass it to CloudFormation.
  immutable_parameters = template.excise_parameter_attribute!(:Immutable)

  # Tag CloudFormation stacks based on :Tags defined in the template
  cfn_tags = template.excise_tags!

  # Can't currently support spaces because the system() call escapes them and that fouls up the CLI
  unless cfn_tags.select { |i| i =~ /\s+/ }.empty?
    $stderr.puts "ERROR: Tag names or values cannot currently contain spaces. Please remove spaces and try again."
    exit(2)
  end

  # The command line string looks like: --tag "Key=key; Value=value" --tag "Key2=key2; Value2=value"
  cfn_tags_options = cfn_tags.sort.map { |tag| ["--tag", "Key=%s; Value=%s" % tag.split('=')] }.flatten

  # example: <template.rb> cfn-create-stack my-stack-name --parameters "Env=prod" --region eu-west-1
  # Execute the AWS CLI cfn-cmd command to validate/create/update a CloudFormation stack.
  if action == 'diff' or (action == 'expand' and not template.nopretty)
    template_string = JSON.pretty_generate(template)
  else
    template_string = JSON.generate(template)
  end

  if action == 'expand'
    # Write the pretty-printed JSON template to stdout and exit.  [--nopretty] option writes output with minimal whitespace
    # example: <template.rb> expand --parameters "Env=prod" --region eu-west-1 --nopretty
    if template.nopretty
      puts template_string
    else
      puts template_string
    end
    exit(true)
  end

  temp_file = File.absolute_path("#{$PROGRAM_NAME}.expanded.json")
  File.write(temp_file, template_string)

  cmdline = ['cfn-cmd'] + ARGV + ['--template-file', temp_file] + cfn_tags_options

  # Add the required default capability if no capabilities were specified
  cmdline = cmdline + ['-c', 'CAPABILITY_IAM'] if not ARGV.include?('--capabilities') or ARGV.include?('-c')

  case action
  when 'diff'
    # example: <template.rb> diff my-stack-name --parameters "Env=prod" --region eu-west-1
    # Diff the current template for an existing stack with the expansion of this template.

    # The --parameters and --tag options were used to expand the template but we don't need them anymore.  Discard.
    _, cfn_options = extract_options(ARGV[1..-1], %w(), %w(--parameters --tag))

    # Separate the remaining command-line options into options for 'cfn-cmd' and options for 'diff'.
    cfn_options, diff_options = extract_options(cfn_options, %w(),
      %w(--stack-name --region --parameters --connection-timeout -I --access-key-id -S --secret-key -K --ec2-private-key-file-path -U --url))

    # If the first argument is a stack name then shift it from diff_options over to cfn_options.
    if diff_options[0] && !(/^-/ =~ diff_options[0])
      cfn_options.unshift(diff_options.shift)
    end

    # Run CloudFormation commands to describe the existing stack
    cfn_options_string           = cfn_options.map { |arg| "'#{arg}'" }.join(' ')
    old_template_raw             = exec_capture_stdout("cfn-cmd cfn-get-template #{cfn_options_string}")
    # ec2 template output is not valid json: TEMPLATE  "<json>\n"\n
    old_template_object          = JSON.parse(old_template_raw[11..-3])
    old_template_string          = JSON.pretty_generate(old_template_object)
    old_stack_attributes         = exec_describe_stack(cfn_options_string)
    old_tags_string              = old_stack_attributes["TAGS"]
    old_parameters_string        = old_stack_attributes["PARAMETERS"]

    # Sort the tag strings alphabetically to make them easily comparable
    old_tags_string = (old_tags_string || '').split(';').sort.map { |tag| %Q(TAG "#{tag}"\n) }.join
    tags_string     = cfn_tags.sort.map { |tag| "TAG \"#{tag}\"\n" }.join

    # Sort the parameter strings alphabetically to make them easily comparable
    old_parameters_string = (old_parameters_string || '').split(';').sort.map { |param| %Q(PARAMETER "#{param}"\n) }.join
    parameters_string     = template.parameters.sort.map { |key, value| "PARAMETER \"#{key}=#{value}\"\n" }.join

    # Diff the expanded template with the template from CloudFormation.
    old_temp_file = File.absolute_path("#{$PROGRAM_NAME}.current.json")
    new_temp_file = File.absolute_path("#{$PROGRAM_NAME}.expanded.json")
    File.write(old_temp_file, old_tags_string + old_parameters_string + old_template_string)
    File.write(new_temp_file, tags_string + parameters_string + template_string)

    # Compare templates
    puts %x( #{SYSTEM_ENV}; #{(["diff"] + diff_options + [old_temp_file, new_temp_file]).join(' ')} )

    File.delete(old_temp_file)
    File.delete(new_temp_file)

    exit(true)

  when 'cfn-validate-template'
    # The cfn-validate-template command doesn't support --parameters so remove it if it was provided for template expansion.
    _, cmdline = extract_options(cmdline, %w(), %w(--parameters --tag))

  when 'cfn-update-stack'
    # Pick out the subset of cfn-update-stack options that apply to cfn-describe-stacks.
    cfn_options, other_options = extract_options(ARGV[1..-1], %w(),
      %w(--stack-name --region --connection-timeout -I --access-key-id -S --secret-key -K --ec2-private-key-file-path -U --url))

    # If the first argument is a stack name then shift it over to cfn_options.
    if other_options[0] && !(/^-/ =~ other_options[0])
      cfn_options.unshift(other_options.shift)
    end

    # Run CloudFormation command to describe the existing stack
    cfn_options_string = cfn_options.map { |arg| "'#{arg}'" }.join(' ')
    old_stack_attributes = exec_describe_stack(cfn_options_string)

    # If updating a stack and some parameters are marked as immutable, fail if the new parameters don't match the old ones.
    if not immutable_parameters.empty?
      old_parameters_string = old_stack_attributes["PARAMETERS"]
      old_parameters = Hash[(old_parameters_string || '').split(';').map { |pair| pair.split('=', 2) }]
      new_parameters = template.parameters

      immutable_parameters.sort.each do |param|
        if old_parameters[param].to_s != new_parameters[param].to_s
          $stderr.puts "Error: cfn-update-stack may not update immutable parameter " +
                           "'#{param}=#{old_parameters[param]}' to '#{param}=#{new_parameters[param]}'."
          exit(false)
        end
      end
    end

    # Tags are immutable in CloudFormation.  The cfn-update-stack command doesn't support --tag options, so remove
    # the argument (if it exists) and validate against the existing stack to ensure tags haven't changed.
    # Compare the sorted arrays for an exact match
    old_cfn_tags = old_stack_attributes['TAGS'].split(';').sort rescue [] # Use empty Array if .split fails
    if cfn_tags.sort != old_cfn_tags
      $stderr.puts "CloudFormation stack tags do not match and cannot be updated. You must either use the same tags or create a new stack." +
                      "\n" + (old_cfn_tags - cfn_tags).map {|tag| "< #{tag}" }.join("\n") +
                      "\n" + "---" +
                      "\n" + (cfn_tags - old_cfn_tags).map {|tag| "> #{tag}"}.join("\n")
      exit(false)
    end
    _, cmdline = extract_options(cmdline, %w(), %w(--tag))
  end

  # Execute command cmdline
  puts %x( #{SYSTEM_ENV}; #{cmdline.map {|i| "\"#{i}\" "}.join} )
  unless $?
    $stderr.puts "\nExecution of 'cfn-cmd' failed.  To facilitate debugging, the generated JSON template " +
                     "file was not deleted.  You may delete the file manually if it isn't needed: #{temp_file}"
    exit(false)
  end

  File.delete(temp_file)

  exit(true)
end

def extract_kv_string(hash, prefix='')
  key = "#{prefix}Key"
  value = "#{prefix}Value"
  hash["member"].map {|a| "#{a[key]}=#{a[value]}" }.join(';') rescue ''
end

def exec_describe_stack cfn_options_string
  xml_data = exec_capture_stdout("cfn-cmd cfn-describe-stacks #{cfn_options_string} --show-xml")
  xml = XmlSimple.xml_in(xml_data, :ForceArray => false)["DescribeStacksResult"]["Stacks"]["member"]
  { "TAGS" => extract_kv_string(xml["Tags"]), "PARAMETERS" => extract_kv_string(xml["Parameters"], "Parameter") }
end

def exec_capture_stdout command
  stdout = %x( #{SYSTEM_ENV}; #{command} )
  unless $?.success?
    $stderr.puts stdout unless stdout.empty?  # cfn-cmd sometimes writes error messages to stdout
    exit(false)
  end
  stdout
end

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

##################################### Additional dsl logic
# Core interpreter for the DSL
class TemplateDSL < JsonObjectDSL
  def exec!()
    cfn_cmd(self)
  end
end

# Main entry point
def template(&block)
  stack_name, parameters, aws_region, nopretty = cfn_parse_args
  raw_template(parameters, stack_name, aws_region, nopretty, &block)
end
