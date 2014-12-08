#fail 'need Ruby2.0 or newer' unless RUBY_VERSION.split[0].to_i >= 2

require 'aws-sdk'

# Overridable parameters
SERVICE_VERSION = ENV['SERVICE_VERSION'] || ENV['GO_PIPELINE_LABEL']
SERVICE_SANDBOX = ENV['SERVICE_SANDBOX'] || (ENV['GO_JOB_NAME'].nil? && `whoami`.strip)
GLOBAL_VERSION  = ENV['GLOBAL_VERSION']
GLOBAL_SANDBOX  = ENV['GLOBAL_SANDBOX']

module ServiceStack

  class << self
    attr_writer :name, :sandbox, :version
  end

  def self.stack_name
    fail 'name not set' if name.nil? || name.empty?
    (sandbox ? "#{sandbox}-" : '') + name
  end

  def self.name
    @name ||= SERVICE_NAME
  end

  def self.sandbox
    @sandbox ||= SERVICE_SANDBOX
  end

  def self.version
    @version ||= SERVICE_VERSION
  end

  def self.create_or_update(template, parameters)
    GlobalStack.outputs.each do |o|
      parameters[o.output_key] = o.output_value
    end
    parameters[:ServiceVersion] = version
    Stacker.create_or_update_stack(stack_name, template, parameters)
  end

  def self.delete
    Stacker.delete_stack(stack_name)
  end

end

module GlobalStack

  class << self
    attr_accessor :sandbox, :version
  end

  def self.stack_name
    (sandbox ? "#{sandbox}-" : '') + name
  end

  def self.name
    'global'
  end

  def self.sandbox
    @sandbox ||= GLOBAL_SANDBOX
  end

  def self.version
    @version ||= GLOBAL_VERSION || 21
    # TODO: find current version from prod. maybe a tag in s3 must be updated, or you have to search in s3
  end

  def self.outputs
    @lazy_outputs ||= Stacker.find_stack(stack_name).outputs.inject({}) do |m, o|
      m[o.output_key.to_sym] = o.output_value
    end
  end

  def self.create # stack_name, version
    Stacker.create_stack(stack_name, template, {Sandbox: stack_name})
  end

  def self.update
    Stacker.update_stack(stack_name, template, {Sandbox: stack_name})
  end

  def self.delete
     Stacker.delete_stack(stack_name)
  end

  def self.template
    # TODO: How to get the current version used on live?
    s3 = Aws::S3::Client.new
    s3.get_object(bucket: 'as24.tatsu.artefacts', key: "scaffolding/#{version}/infra-vpc.json").body.read
  end
end

module Stacker

  def self.create_or_update_stack(stack_name, template_body, parameters)
    if find_stack(stack_name).nil?
      create_stack(stack_name, template_body, parameters)
    else
      update_stack(stack_name, template_body, parameters)
    end
  end

  def self.create_stack(stack_name, template_body, parameters)
    cloud_formation.create_stack(stack_name:    stack_name,
                                 template_body: template_body,
                                 on_failure:    'DELETE',
                                 parameters:    transform(parameters),
                                 capabilities:  ['CAPABILITY_IAM'])
    wait_for_stack(stack_name, :create)
  end

  def self.update_stack(stack_name, template_body, parameters)
    begin
      cloud_formation.update_stack(stack_name:    stack_name,
                                   template_body: template_body,
                                   parameters:    transform(parameters),
                                   capabilities:  ['CAPABILITY_IAM'])
    rescue Aws::CloudFormation::Errors::ValidationError => error
      raise error unless error.message =~ /No updates are to be performed/i # may be flaky, do more research in API
    end
    wait_for_stack(stack_name, :update)
  end

  def self.delete_stack(stack_name)
    cloud_formation.delete_stack(stack_name: stack_name)
    wait_for_stack(stack_name, :delete)
  end

  def self.wait_for_stack(stack_name, operation, timeout_in_minutes: 15)
    stop_time = Time.now + timeout_in_minutes * 60
    while Time.now < stop_time
      stack = find_stack(stack_name)
      return nil if stack.nil? # could happen if stack operation was delete
      puts "waiting for stack #{stack_name}, current status #{stack.stack_status}"
      #TODO match expected operation
      return stack if  stack.stack_status =~ /(CREATE_COMPLETE|UPDATE_COMPLETE|DELETE_COMPLETE)$/
      fail "wait for stack failed #{stack.stack_status}" if stack.stack_status =~ /(ROLLBACK_COMPLETE|ROLLBACK_FAILED|CREATE_FAILED)$/i
      sleep(5)
    end
    fail "wait_for_stack timeout after #{timeout_in_minutes} minutes"
  end

  def self.find_stack(stack_name)
    cloud_formation.describe_stacks(stack_name: stack_name).stacks.first
  rescue Aws::CloudFormation::Errors::ValidationError => error
    raise error unless error.message =~ /does not exist/i # may be flaky, do more research in API
    nil
  end

  def self.transform(params)
    params.inject([]){|m, kv| m << {parameter_key: kv[0].to_s, parameter_value: kv[1].to_s }}
  end

  def self.cloud_formation # lazy CloudFormation client
    @lazy_cloud_formation ||= Aws::CloudFormation::Client.new
  end

end

if $0 ==__FILE__ # placeholder for interactive testing

end
