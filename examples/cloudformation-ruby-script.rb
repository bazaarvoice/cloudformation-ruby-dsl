#!/usr/bin/env ruby

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

require 'bundler/setup'
require 'cloudformation-ruby-dsl/cfntemplate'
require 'cloudformation-ruby-dsl/table'

# Note: this is only intended to demonstrate the cloudformation-ruby-dsl. It compiles
#   and validates correctly, but won't produce a viable CloudFormation stack.

template do

  # Metadata may be embedded into the stack, as per http://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/metadata-section-structure.html
  # The below definition produces CloudFormation interface metadata.
  metadata 'AWS::CloudFormation::Interface', {
    :ParameterGroups => [
      {
        :Label => { :default => 'Instance options' },
        :Parameters => [ 'InstanceType', 'ImageId', 'KeyPairName' ]
      },
      {
        :Label => { :default => 'Other options' },
        :Parameters => [ 'Label', 'EmailAddress' ]
      }
    ],
    :ParameterLabels => {
      :EmailAddress => {
        :default => "We value your privacy!"
      }
    }
  }

  parameter 'Label',
            :Description => 'The label to apply to the servers.',
            :Type => 'String',
            :MinLength => '2',
            :MaxLength => '25',
            :AllowedPattern => '[_a-zA-Z0-9]*',
            :ConstraintDescription => 'Maximum length of the Label parameter may not exceed 25 characters and may only contain letters, numbers and underscores.',
            # The :Immutable attribute is a Ruby CFN extension.  It affects the behavior of the '<template> update ...'
            # operation in that a stack update may not change the values of parameters marked w/:Immutable => true.
            :Immutable => true

  parameter 'InstanceType',
            :Description => 'EC2 instance type',
            :Type => 'String',
            :Default => 'm2.xlarge',
            :AllowedValues => %w(t1.micro m1.small m1.medium m1.large m1.xlarge m2.xlarge m2.2xlarge m2.4xlarge c1.medium c1.xlarge),
            :ConstraintDescription => 'Must be a valid EC2 instance type.'

  parameter 'ImageId',
            :Description => 'EC2 Image ID',
            :Type => 'String',
            :Default => 'ami-255bbc4c',
            :AllowedPattern => 'ami-[a-f0-9]{8}',
            :ConstraintDescription => 'Must be ami-XXXXXXXX (where X is a hexadecimal digit)'

  parameter 'KeyPairName',
            :Description => 'Name of KeyPair to use.',
            :Type => 'String',
            :MinLength => '1',
            :MaxLength => '40',
            :Default => parameters['Label']

  parameter 'EmailAddress',
            :Type => 'String',
            :Description => 'Email address at which to send notification events.'

  parameter 'BucketName',
            :Type => 'String',
            :Description => 'Name of the bucket to upload to.'

  mapping 'InlineExampleMap',
          :team1 => {
              :name => 'test1',
              :email => 'test1@example.com',
          },
          :team2 => {
              :name => 'test2',
              :email => 'test2@example.com',
          }

  # Generates mappings from external files with various formats.
  mapping 'JsonExampleMap', 'maps/map.json'

  mapping 'RubyExampleMap', 'maps/map.rb'

  mapping 'YamlExampleMap', 'maps/map.yaml'

  # Loads JSON mappings dynamically from example directory.
  Dir.entries('maps/more_maps').each_with_index do |path, index|
    next if path == "." or path == ".."
    mapping "ExampleMap#{index - 1}", "maps/more_maps/#{path}"
  end

  # Selects all rows in the table which match the name/value pairs of the predicate object and returns a
  # set of nested maps, where the key for the map at level n is the key at index n in the specified keys,
  # except for the last key in the specified keys which is used to determine the value of the leaf-level map.
  text = Table.load 'maps/table.txt'
  mapping 'TableExampleMap',
      text.get_map({ :column0 => 'foo' }, :column1, :column2, :column3)

  # Shows how to create a table useful for looking up subnets that correspond to a particular env/region for eg. vpc placement.
  vpc = Table.load 'maps/vpc.txt'
  mapping 'TableExampleMultimap',
          vpc.get_multimap({ :visibility => 'private', :zone => ['a', 'c'] }, :env, :region, :subnet)

  # Shows how to use a table for iterative processing.
  domains = Table.load 'maps/domains.txt'
  domains.get_multihash(:purpose, {:product => 'demo', :alias => 'true'}, :prefix, :target, :alias_hosted_zone_id).each_pair do |key, value|
    resource key+'Route53RecordSet', :Type => 'AWS::Route53::RecordSet', :Properties => {
        :Comment => '',
        :HostedZoneName => 'bazaarvoice.com',
        :Name => value[:prefix]+'.bazaarvoice.com',
        :Type => 'A',
        :AliasTarget => {
          :DNSName => value[:target],
          :HostedZoneId => value[:alias_hosted_zone_id]
        }
    }
  end


  # The tag type is a DSL extension; it is not a property of actual CloudFormation templates.
  #   These tags are excised from the template and used to generate a series of --tag arguments
  #   which are passed to CloudFormation when a stack is created.
  #   They do not ultimately appear in the expanded CloudFormation template.
  #   The diff subcommand will compare tags with the running stack and identify any changes,
  #   but a stack update will do the diff and throw an error on any immutable tags update attempt.
  #   The tags are propagated to all resources created by the stack, including the stack itself.
  #   If a resource has its own tag with the same name as CF's it's not overwritten.
  #
  # Amazon has set the following restrictions on CloudFormation tags:
  #   => limit 10
  # CloudFormation tags declaration examples:

  tag 'My:New:Tag',
      :Value => 'ImmutableTagValue',
      :Immutable => true

  tag :MyOtherTag,
      :Value => 'My Value With Spaces'

  tag(:"tag:name", :Value => 'tag_value', :Immutable => true)

  # Following format is deprecated and not advised. Please declare CloudFormation tags as described above.
  tag :TagName => 'tag_value'    # It's immutable.

  resource 'SecurityGroup', :Type => 'AWS::EC2::SecurityGroup', :Properties => {
      :GroupDescription => 'Lets any vpc traffic in.',
      :SecurityGroupIngress => {:IpProtocol => '-1', :FromPort => '0', :ToPort => '65535', :CidrIp => "10.0.0.0/8"}
  }

  resource "ASG", :Type => 'AWS::AutoScaling::AutoScalingGroup', :Properties => {
      :AvailabilityZones => 'us-east-1',
      :HealthCheckType => 'EC2',
      :LaunchConfigurationName => ref('LaunchConfig'),
      :MinSize => 1,
      :MaxSize => 5,
      :NotificationConfiguration => {
          :TopicARN => ref('EmailSNSTopic'),
          :NotificationTypes => %w(autoscaling:EC2_INSTANCE_LAUNCH autoscaling:EC2_INSTANCE_LAUNCH_ERROR autoscaling:EC2_INSTANCE_TERMINATE autoscaling:EC2_INSTANCE_TERMINATE_ERROR),
      },
      :Tags => [
          {
              :Key => 'Name',
              # Grabs a value in an external map file.
              :Value => find_in_map('TableExampleMap', 'corge', 'grault'),
              :PropagateAtLaunch => 'true',
          },
          {
              :Key => 'Label',
              :Value => parameters['Label'],
              :PropagateAtLaunch => 'true',
          }
      ],
  }

  resource 'EmailSNSTopic', :Type => 'AWS::SNS::Topic', :Properties => {
      :Subscription => [
          {
              :Endpoint => ref('EmailAddress'),
              :Protocol => 'email',
          },
      ],
  }

  resource 'WaitConditionHandle', :Type => 'AWS::CloudFormation::WaitConditionHandle', :Properties => {}

  resource 'WaitCondition', :Type => 'AWS::CloudFormation::WaitCondition', :DependsOn => 'ASG', :Properties => {
      :Handle => ref('WaitConditionHandle'),
      :Timeout => 1200,
      :Count => "1"
  }

  resource 'LaunchConfig', :Type => 'AWS::AutoScaling::LaunchConfiguration', :Properties => {
      :ImageId => parameters['ImageId'],
      :KeyName => ref('KeyPairName'),
      :IamInstanceProfile => ref('InstanceProfile'),
      :InstanceType => ref('InstanceType'),
      :InstanceMonitoring => 'false',
      :SecurityGroups => [ref('SecurityGroup')],
      :BlockDeviceMappings => [
          {:DeviceName => '/dev/sdb', :VirtualName => 'ephemeral0'},
          {:DeviceName => '/dev/sdc', :VirtualName => 'ephemeral1'},
          {:DeviceName => '/dev/sdd', :VirtualName => 'ephemeral2'},
          {:DeviceName => '/dev/sde', :VirtualName => 'ephemeral3'},
      ],
      # Loads an external userdata script with an interpolated argument.
      :UserData => base64(interpolate(file('userdata.sh'), time: Time.now)),
  }

  resource 'InstanceProfile', :Type => 'AWS::IAM::InstanceProfile', :Properties => {
      # use cfn intrinsic conditional to choose the 2nd value because the expression evaluates to false
      :Path => fn_if(equal(3, 0), '/unselected/', '/'),
      :Roles => [ ref('InstanceRole') ],
  }

  resource 'InstanceRole', :Type => 'AWS::IAM::Role', :Properties => {
      :AssumeRolePolicyDocument => {
          :Statement => [
              {
                  :Effect => 'Allow',
                  :Principal => { :Service => [ 'ec2.amazonaws.com' ] },
                  :Action => [ 'sts:AssumeRole' ],
              },
          ],
      },
      :Path => '/',
  }

  # Use sub to set bucket names for an S3 Policy.
  resource 'ManagedPolicy', :Type => "AWS::IAM::ManagedPolicy", :Properties => {
    :Description => 'Access policy for S3 Buckets',
    :PolicyDocument => {
      :Version => "2012-10-17",
      :Statement => [
        {
          :Action => ["s3:ListBucket"],
          :Effect => "Allow",
          :Resource => [
            sub("arn:aws:s3:::${BucketName}"),
            sub("arn:aws:s3:::${BaseName}${Hash}", {:BaseName => 'Bucket', :Hash => '3bsd73w'}),
          ]
        }
      ]
    }
  }

  resource 'Vpc', :Type => "AWS::EC2::VPC", :Properties => {
    :CidrBlock => "10.0.0.0/16"
  }

  resource 'Subnet', :Type => "AWS::EC2::Subnet", :DependsOn => 'Vpc', :Properties => {
    :AvailabilityZone => select(0, get_azs()),
    :CidrBlock => select(0, cidr(get_att('Vpc', 'CidrBlock'), 8, 8)),
    :VpcId => ref('vpc')
  }

  # add conditions that can be used elsewhere in the template
  condition 'myCondition', fn_and(equal("one", "two"), not_equal("three", "four"))

  output 'EmailSNSTopicARN',
          :Value => ref('EmailSNSTopic'),
          :Description => 'ARN of SNS Topic used to send emails on events.'

  output 'MappingLookup',
          :Value => find_in_map('TableExampleMap', 'corge', 'grault'),
          :Description => 'An example map lookup.'

end.exec!
