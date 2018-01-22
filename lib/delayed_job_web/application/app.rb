require 'sinatra/base'
require 'active_support'
require 'delayed_job_mongoid'

class DelayedJobWeb < Sinatra::Base
  set :root, File.dirname(__FILE__)
  set :static, true
  set :public_folder, File.expand_path('../public', __FILE__)
  set :views, File.expand_path('../views', __FILE__)

  # Enable sessions so we can use CSRF protection
  enable :sessions

  set :protection,
    # Various session protections
    :session => true,
    # Various non-default Rack::Protection options
    :use => [
      # Prevent destructive actions without a valid CSRF auth token
      :authenticity_token,
      # Prevent destructive actions with remote referrers
      :remote_referrer
    ],
    # Deny the request, don't clear the session
    :reaction => :deny

  before do
    @queues = (params[:queues] || "").split(",").map{|queue| queue.strip}.uniq.compact
    @search_field = (params[:search_field] || "")
  end

  def current_page
    url_path request.path_info.sub('/','')
  end

  def start
    params[:start].to_i
  end

  def per_page
    20
  end

  def url_path(*path_parts)
    url = [ path_prefix, path_parts ].join("/").squeeze('/')
    unless @queues.empty?
      url += "?queues=#{@queues.join(",")}"
      @search_field = "queue" if (@search_field.empty? && !@queues.empty?)
      url += "&search_field=#{@search_field}"
    end
    url
  end

  alias_method :u, :url_path

  def h(text)
    Rack::Utils.escape_html(text)
  end

  def path_prefix
    request.env['SCRIPT_NAME']
  end

  def tabs
    [
      {:name => 'Overview', :path => '/overview'},
      {:name => 'Enqueued', :path => '/enqueued'},
      {:name => 'Working', :path => '/working'},
      {:name => 'Pending', :path => '/pending'},
      {:name => 'Failed', :path => '/failed'},
      {:name => 'Stats', :path => '/stats'}
    ]
  end

  def delayed_job
    begin
      Delayed::Job
    rescue
      false
    end
  end

  def csrf_token
    # Set up by Rack::Protection
    session[:csrf]
  end

  def csrf_token_tag
    # If csrf_token is nil, and we submit a blank string authenticity_token
    # param, Rack::Protection will fail.
    if csrf_token
      "<input type='hidden' name='authenticity_token' value='#{h csrf_token}'>"
    end
  end

  get '/overview' do
    if delayed_job
      erb :overview
    else
      @message = "Unable to connected to Delayed::Job database"
      erb :error
    end
  end

  get '/stats' do
    erb :stats
  end

  %w(enqueued working pending failed).each do |page|
    get "/#{page}" do
      @jobs     = delayed_jobs(page.to_sym, @search_field, @queues).order_by(:created_at.desc).offset(start).limit(per_page)
      @all_jobs = delayed_jobs(page.to_sym, @search_field, @queues)
      erb page.to_sym
    end
  end

  post "/remove/:id" do
    delayed_job.find(params[:id]).delete
    redirect back
  end

  post "/requeue/all" do
    delayed_jobs(:failed, @search_field, @queues).update_all(:run_at => Time.now, :failed_at => nil)
    redirect back
  end

  post "/requeue/:id" do
    job = delayed_job.find(params[:id])
    job.update_attributes(:run_at => Time.now, :failed_at => nil)
    redirect back
  end

  post "/reload/:id" do
    job = delayed_job.find(params[:id])
    job.update_attributes(:run_at => Time.now, :failed_at => nil, :locked_by => nil, :locked_at => nil, :last_error => nil, :attempts => 0)
    redirect back
  end

  post "/failed/clear" do
    delayed_jobs(:failed, @search_field, @queues).delete_all
    redirect u('failed')
  end

  def delayed_jobs(type, search_field = "", queues = [])
    rel = delayed_job

    rel =
      case type
      when :working
        rel.where(:locked_at => {"$ne" => nil})
      when :failed
        rel.where(:last_error => {"$ne" => nil})
      when :pending
        rel.where(:attempts => 0, :locked_at => nil)
      else
        rel
      end

    unless queues.empty?
      if search_field == 'queue'
        rel = rel.where(:queue => {"$in" => queues})
      elsif search_field == 'handler'
        search_text = queues.first
        rel = rel.where(:handler => {"$regex" => /#{search_text}/i})
      elsif search_field == 'tags'
        # rel = rel.where(:tags)
      end
    end

    rel
  end

  get "/?" do
    redirect u(:overview)
  end

  def partial(template, local_vars = {})
    @partial = true
    erb(template.to_sym, {:layout => false}, local_vars)
  ensure
    @partial = false
  end

  %w(overview enqueued working pending failed stats) .each do |page|
    get "/#{page}.poll" do
      show_for_polling(page)
    end

    get "/#{page}/:id.poll" do
      show_for_polling(page)
    end
  end

  def poll
    if @polling
      text = "Last Updated: #{Time.now.strftime("%H:%M:%S")}"
    else
      text = "<a href='#{u(request.path_info + ".poll")}' rel='poll'>Live Poll</a>"
    end
    "<p class='poll'>#{text}</p>"
  end

  def show_for_polling(page)
    content_type "text/html"
    @polling = true
    # show(page.to_sym, false).gsub(/\s{1,}/, ' ')
    @jobs = delayed_jobs(page.to_sym, @search_field, @queues)
    erb(page.to_sym, {:layout => false})
  end

end

# Run the app!
#
# puts "Hello, you're running delayed_job_web"
# DelayedJobWeb.run!
