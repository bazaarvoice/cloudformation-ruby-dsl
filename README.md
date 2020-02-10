# cloudformation-ruby-dsl

A Ruby DSL and helper utilities for building CloudFormation templates dynamically.

Written by [Bazaarvoice](http://www.bazaarvoice.com): see [the contributors page](https://github.com/bazaarvoice/cloudformation-ruby-dsl/graphs/contributors) and [the initial contributions](https://github.com/bazaarvoice/cloudformation-ruby-dsl/blob/master/initial_contributions.md) for more details.

## Motivation

CloudFormation templates often contain repeated stanzas, information which must be loaded from external sources, and other functionality that would be easier handled as code, instead of configuration.

Consider when a userdata script needs to be added to a CloudFormation template. Traditionally, you would re-write the script by hand in a valid JSON format. Using the DSL, you can specify the file containing the script and generate the correct information at runtime.

    :UserData => base64(interpolate(file('userdata.sh')))

Additionally, CloudFormation templates are just massive JSON documents, making general readability and reusability an issue. The DSL allows not only a cleaner format (and comments!), but will also allow the same DSL template to be reused as needed.

## Installation

Run `gem install cloudformation-ruby-dsl` to install system-wide.

To use in a specific project, add `gem 'cloudformation-ruby-dsl'` to your Gemfile, and then run `bundle`.

## Releasing

See [Releasing](docs/Releasing.md).

## Contributing

See [Contributing](docs/Contributing.md).

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
- `create`: create a new stack from the output (takes optional `--s3-bucket` to upload the template to the specified S3 bucket prior to creating the stack)
- `update`: update an existing stack from the output (takes optional `--s3-bucket` to upload the template to the specified S3 bucket prior to creating the stack). Produces following exit codes:
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
- `--profile`
- `--stack-name`
- `--region`
- `--parameters`
- `--tag`

Any other parameters are passed directly onto cloudformation. (--disable-rollback for instance)

Using the ruby scripts:
```
template.rb create --stack-name my_stack --parameters "BucketName=bucket-s3-static;SnsQueue=mysnsqueue"
```

Below are the various functions currently available in the DSL. See [the example script](examples/cloudformation-ruby-script.rb) for more usage information.

### DSL Statements

Add the named object to the appropriate collection.
- `parameter(name, options)` (may be marked :Immutable, which will raise error on a later change)
- `mapping(name, options)`
- `condition(name, conditions)`
- `resource(name, options)`
- `output(name, options)`
- `metadata(object)`

### CloudFormation Function Calls

Invoke an intrinsic CloudFormation function.
- `base64(value)`
- `find_in_map(map, key, name)`
- `get_att(resource, attribute)`
- `get_azs(region)`
- `split(delim, string)`
- `join(delim, *list)`
- `select(index, list)`
- `ref(name)`
- `import_value(value)`
- `sub(sub_string)`
- `sub(sub_string, var_map)`

Intrinsic conditionals are also supported, with some syntactic sugar.
- `fn_not(condition)`
- `fn_or(*condition_list)`
- `fn_and(*condition_list)`
- `fn_if(condition, value_if_true, value_if_false)`
- `equal(lhsOperand, rhsOperand)`
- `not_equal(lhsOperand, rhsOperand)`

Reference a CloudFormation pseudo parameter.
- `aws_account_id()`
- `aws_notification_arns()`
- `aws_no_value()`
- `aws_region()`
- `aws_stack_id()`
- `aws_stack_name()`

### Utility Functions

Additional capabilities for file inclusion, etc.
- `tag(tag_name, tag_options_hash)`: add tags to the stack, which are inherited by all resources in that stack. `tag_options_hash` includes `:Value=>value` and `:Immutable=>true` properties. `tag(tag_value_hash)` is deprecated and will be removed in a future version.
- `file(name)`: return the named file as a string, for further use
- `load_from_file(filename)`: load the named file by a given type; currently handles YAML, JSON, and Ruby
- `interpolate(string)`: embed CFN references into a string (`{{ref('Service')}}`) for later interpretation by the CFN engine
- `Table.load(filename)`: load a table from the listed file, which can then be turned into mappings (via `get_map`)

### Default Region

The tool defaults to region `us-east-1`. To change this set either `EC2_REGION` or `AWS_DEFAULT_REGION` in your environment.

## Usage as a library

See [examples/simple_template.rb](examples/simple_template.rb)
