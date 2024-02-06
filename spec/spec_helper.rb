require 'rspec'
require 'fileutils'
require 'json'
require 'open3'
require 'aws-sdk'
require 'cloudformation-ruby-dsl/dsl'
##
# Error encapsulating information about a failed command
class CommandError < StandardError
  attr_reader :command, :status, :stderr

  def initialize(command, status, stderr)
    @command = command
    @status = status
    @stderr = stderr
    super "FAILURE (#{status}) #{stderr}"
  end
end

##
# Helpers for dealing with pathing from specs
module PathHelpers
  ##
  # Returns an absolute path for the specified path that
  # is relative to the project root irregardless of where
  # rspec/ruby is invoked
  def from_project_root(relative_path)
    source_dir = File.expand_path(File.dirname(__FILE__))
    File.join(source_dir, "..", relative_path)
  end
end

##
# Mixin containing helper methods for working with
# commands executed in a subshell
module CommandHelpers
  include PathHelpers

  ##
  # Logs the command that failed and raises an exception
  # inlcuding status and stderr
  def cmd_failed(command, status, stderr)
    STDERR.puts("FAILURE executing #{command}")
    raise CommandError.new(command, status, stderr)
  end

  ##
  # execute a command within a specified directory and
  # return results or yield them to a block if one is
  # given to this method.  Results are an array of
  # strings:
  #
  # [stdout, token1, token2, ..., tokenN]
  #
  # where stdout is the captured standard output and
  # the tokens are the words extracted from the output.
  #
  # If the command has a non-zero  exit status, an
  # exception is raised including the exit code
  # and stderr.
  #
  # example call:
  #   exec_cmd("ls", :within => "/")
  def exec_cmd(cmd, opts={:within => "."})
    exec_dir = from_project_root(opts[:within])
    Dir.chdir(exec_dir) do
      stdout, stderr, status = Open3.capture3(cmd)
      results = stdout.split(" ").unshift(stdout)

      cmd_failed(cmd, status, stderr) if status != 0
      if (block_given?)
        yield results
      else
        results
      end
    end
  end
end

##
# Mixin with helper methods for dealing with JSON generated
# from cloudformation-ruby-dsl
module JsonHelpers
  ##
  # Parse the json string, making sure to write all of it to
  # STDERR if parsing fails to make it easier to troubleshoot
  # failures in generated json.
  def jsparse(json_string)
    begin
      JSON.parse(json_string)
    rescue StandardError => e
      STDERR.puts "Error parsing JSON:"
      STDERR.puts json_string
      raise e
    end
  end
end

##
# Mixin with helper methods for dealing with files generated
# from a test/spec
module FileHelpers
  include PathHelpers

  ##
  # Delete a file from the spec/tmp directory
  def delete_test_file(filename)
    abs_path = File.join(from_project_root("spec/tmp"), filename)
    FileUtils.rm(abs_path) if File.exist?(abs_path)
  end

  ##
  # Write a file to the spec/tmp directory
  def write_test_file(filename, contents)
    dest_dir = from_project_root("spec/tmp")
    dest_file = File.join(dest_dir, filename)

    FileUtils.mkdir_p(dest_dir)
    File.open(dest_file, "w") { |f| f.write(contents) }
    dest_file
  end
end

##
# Mixin to assist in using aws cli for validating results of
# cloudformation-ruby-dsl
module AwsHelpers
  include CommandHelpers

  ##
  # Validate a cloudformation template within the spec/tmp directory
  # using aws cli
  def validate_cfn_template(template_name)
    template_path = File.join(from_project_root("spec/tmp"), template_name)
    command = validation_command(template_path)
    exec_cmd(command) do |output|
      begin
        JSON.parse(output.first)
      rescue JSON::ParserError
        STDERR.puts "ERROR parsing output of: #{command}"
        raise
      end
    end
  end

  def profile
    ENV["AWS_PROFILE"] || "default"
  end

  def region
    ENV["AWS_REGION"] || "us-east-1"
  end

  private

  def validation_command(template_path)
    return <<-EOF
      aws cloudformation validate-template --template-body file://#{template_path} \
                                           --region #{region} \
                                           --profile #{profile}
    EOF
  end
end


class RspecHelpers
  class << self
    def cloudformation
      @_cloudformation_ ||= ::Aws::CloudFormation::Client.new(region: region, profile: profile)
    end
  end
end

RSpec.configure do |c|
  c.include CommandHelpers
  c.include JsonHelpers
  c.include FileHelpers
  c.include AwsHelpers
end

Dir["./spec/support/*.rb", "./spec/matchers/*.rb"].each {|f| require f}

