module Bosh; module Director; end; end

require "digest/sha1"
require "erb"
require "fileutils"
require "forwardable"
require "logger"
require "monitor"
require "optparse"
require "ostruct"
require "pp"
require "thread"
require "tmpdir"
require "yaml"

require "bcrypt"
require "blobstore_client"
require "eventmachine"
require "netaddr"
require "resque"
require "sequel"
require "sinatra"
require "uuidtools"
require "yajl"
require "esxmq"

require "director/thread_formatter"
require "director/deep_copy"
require "director/ext"
require "director/http_constants"
require "director/task_helper"
require "director/validation_helper"

require "director/config"

require "director/client"
require "director/ip_util"
require "director/agent_client"
require "director/cloud"
require "director/cloud/vsphere"
require "director/cloud/esx"
require "director/cloud/dummy"
require "director/configuration_hasher"
require "director/cycle_helper"
require "director/deployment_plan"
require "director/deployment_plan_compiler"
require "director/errors"
require "director/instance_updater"
require "director/job_updater"
require "director/lock"
require "director/models"
require "director/nats_rpc"
require "director/package_compiler"
require "director/release_manager"
require "director/resource_pool_updater"
require "director/task_manager"
require "director/thread_pool"
require "director/user_manager"
require "director/deployment_manager"
require "director/stemcell_manager"
require "director/jobs/base_job"
require "director/jobs/delete_deployment"
require "director/jobs/delete_release"
require "director/jobs/delete_stemcell"
require "director/jobs/update_deployment"
require "director/jobs/update_release"
require "director/jobs/update_stemcell"

module Bosh::Director

  class Controller < Sinatra::Base

    def initialize
      super
      @deployment_manager = DeploymentManager.new
      @release_manager    = ReleaseManager.new
      @stemcell_manager   = StemcellManager.new
      @task_manager       = TaskManager.new
      @user_manager       = UserManager.new
      @logger             = Config.logger
    end

    mime_type :tgz, "application/x-compressed"

    def self.consumes(*types)
      types = Set.new(types)
      types.map! { |t| mime_type(t) }

      condition do
        types.include?(request.content_type)
      end
    end

    configure do
      set(:show_exceptions, false)
      set(:raise_errors, false)
      set(:dump_errors, false)
    end

    before do
      @auth ||=  Rack::Auth::Basic::Request.new(request.env)

      if @auth.provided? && @auth.basic? && @auth.credentials && @auth.credentials.length == 2 &&
              @user_manager.authenticate(*@auth.credentials)
        @user = @auth.username
        env["REMOTE_USER"] = @user # for logging
      else
        response["WWW-Authenticate"] = %(Basic realm="Testing HTTP Auth")
        error(UNAUTHORIZED, "Not authorized")
      end
    end

    error do
      exception = request.env['sinatra.error']
      if exception.kind_of?(DirectorError)
        @logger.debug("Request failed with response code: #{exception.response_code} error code: " +
                         "#{exception.error_code} error: #{exception.message}")
        status(exception.response_code)
        error_payload                = Hash.new
        error_payload['code']        = exception.error_code
        error_payload['description'] = exception.message
        Yajl::Encoder.encode(error_payload)
      else
        msg = ["#{exception.class} - #{exception.message}"]
        unless exception.kind_of?(ServerError) && exception.omit_stack
          msg[0] = msg[0] + ":"
          msg.concat(exception.backtrace)
        end
        @logger.warn(msg.join("\n"))
        status(500)
      end
    end

    post "/users", :consumes => [:json] do
      user = @user_manager.get_user_from_request(request)
      @user_manager.create_user(user)
      status(204)
      nil
    end

    put "/users/:username", :consumes => [:json] do
      user = @user_manager.get_user_from_request(request)
      raise UserImmutableUsername unless user.username == params[:username]
      @user_manager.update_user(user)
      status(204)
      nil
    end

    delete "/users/:username" do
      @user_manager.delete_user(params[:username])
      status(204)
      nil
    end

    post "/releases", :consumes => :tgz do
      task = @release_manager.create_release(request.body)
      redirect "/tasks/#{task.id}"
    end

    get "/releases" do
      releases = Models::Release.order_by(:name.asc).map do |release|
        {
          "name"     => release.name,
          "versions" => release.versions_dataset.order_by(:version.asc).all.map { |rv| rv.version.to_s }
        }
      end

      Yajl::Encoder.encode(releases)
    end

    delete "/releases/:name" do
      release = Models::Release[:name => params[:name]]
      raise ReleaseNotFound.new(params[:name]) if release.nil?

      options = {}
      options["force"] = true if params["force"] == "true"

      task = @release_manager.delete_release(release, options)
      redirect "/tasks/#{task.id}"
    end

    post "/deployments", :consumes => :yaml do
      task = @deployment_manager.create_deployment(request.body)
      redirect "/tasks/#{task.id}"
    end

    get "/deployments" do
      deployments = Models::Deployment.order_by(:name.asc).map do |deployment|
        {
          "name" => deployment.name
        }
      end

      Yajl::Encoder.encode(deployments)
    end

    delete "/deployments/:name" do
      deployment = Models::Deployment[:name => params[:name]]
      raise DeploymentNotFound.new(params[:name]) if deployment.nil?
      task = @deployment_manager.delete_deployment(deployment)
      redirect "/tasks/#{task.id}"
    end

    # TODO: get information about an existing deployment
    # TODO: stop, start, restart jobs/instances

    post "/stemcells", :consumes => :tgz do
      task = @stemcell_manager.create_stemcell(request.body)
      redirect "/tasks/#{task.id}"
    end

    get "/stemcells" do
      stemcells = Models::Stemcell.order_by(:name.asc).map do |stemcell|
        {
          "name"    => stemcell.name,
          "version" => stemcell.version,
          "cid"     => stemcell.cid
        }
      end
      Yajl::Encoder.encode(stemcells)
    end

    delete "/stemcells/:name/:version" do
      stemcell = Models::Stemcell[:name => params[:name], :version => params[:version]]
      raise StemcellNotFound.new(params[:name], params[:version]) if stemcell.nil?
      task = @stemcell_manager.delete_stemcell(stemcell)
      redirect "/tasks/#{task.id}"
    end

    get "/tasks" do
      dataset = Models::Task.dataset
      limit = params["limit"]
      if limit
        limit = limit.to_i
        limit = 1 if limit < 1
        dataset = dataset.limit(limit)
      end

      state = params["state"]
      if state
        dataset = dataset.filter(:state => state)
      end

      tasks = dataset.order_by(:timestamp.desc).map do |task|
        @task_manager.task_to_json(task)
      end

      content_type(:json)
      Yajl::Encoder.encode(tasks)
    end

    get "/tasks/:id" do
      task = Models::Task[params[:id]]
      raise TaskNotFound.new(params[:id]) if task.nil?
      content_type(:json)
      task_json = @task_manager.task_to_json(task)
      Yajl::Encoder.encode(task_json)
    end

    get "/tasks/:id/output" do
      task = Models::Task[params[:id]]
      raise TaskNotFound.new(params[:id]) if task.nil?
      if task.output && File.file?(task.output)
        send_file(task.output, :type => "text/plain")
      else
        status(NO_CONTENT)
      end
    end

    get "/status" do
      # TODO: add version to director
      Yajl::Encoder.encode("status" => "Bosh Director (logged in as #{@user})")
    end

  end

end

