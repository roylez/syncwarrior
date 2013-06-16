#!/usr/bin/env ruby
# coding: utf-8
#Author: Roy L Zuo (roylzuo at gmail dot com)
#Description: Sync taskwarrior task to toodledo

require 'logger'
require 'time'
require 'yaml'
require 'io/console'
YAML::ENGINE.yamler = 'psych' # to use UTF-8 in yaml
require 'securerandom'
require_relative 'taskwarrior'

require_relative 'services/toodledo'

require 'logger'
#require 'pry-debugger'

module Logger::Severity
  NEW    = 6
  EDIT   = 7
  DELETE = 8
end

class ScreenLogger < Logger
  def initialize
    super(STDOUT)
    @level = INFO
    @formatter = proc do |severity, time, progname, msg|
      "#{time.strftime("%Y-%m-%d %H:%M:%S")} [#{severity}]: #{msg}\n"
    end
  end

  alias :add_orig :add 
  SEVS = %w(DEBUG INFO WARN ERROR FATAL UNKNOWN NEW EDIT DELETE)
  LEVEL_COLOR = { 
    INFO => nil,
    DEBUG => nil,
    WARN => "\e[1;33m",
    ERROR => "\e[1;31m",
    FATAL => "\e[1;35m",
    NEW => "\e[1;32m",
    EDIT => "\e[1;33m",
    DELETE => "\e[1;31m",
  }

  [:NEW, :EDIT, :DELETE].each do |tag|
    define_method(tag.to_s.downcase.gsub(/\W+/, '_').to_sym) do |progname, &block|
      add(ScreenLogger.const_get(tag), nil, progname, &block)
    end 
  end

  def format_severity(severity)
    SEVS[severity] || 'ANY'
  end

  def add(severity, message = nil, progname = nil, &block)
    severity ||= UNKNOWN
    if @logdev.nil? or severity < @level
      return true
    end
    progname ||= @progname
    if message.nil?
      if block_given?
        message = yield
      else
        message = progname
        progname = @progname
      end
    end
    #severity = "#{LEVEL_COLOR[severity]}#{severity}\e[m"    if LEVEL_COLOR[severity]
    @logdev.write( format_message("#{LEVEL_COLOR[severity]}#{format_severity(severity)}\e[m", Time.now, progname, message))
    true
  end
end

class TaskCollection
  # must exclude recurring parent here
  def new_task_ids
    select{|i| not i.toodleid and i.status != 'recurring' }.collect(&:uuid)
  end
end

class SyncWarrior
  include Toodledo
  include Toodledo::Translation

  attr_reader   :userid

  def initialize(userid, password, taskfile, compfile, cachefile, opts = {})
    @task_file         = taskfile
    @comp_file         = compfile
    @cache_file        = cachefile

    @task_warrior      = TaskCollection.from_task_file(@task_file, @comp_file)

    @remote_folders    = []
    @remote_contexts   = []

    @token             = nil
    @prev_account_info = nil
    @last_sync         = nil
    @userid            = userid

    @appid             = 'syncwarrior'
    @apptoken          = 'api512ab65a08df3'

    #@repeat_from       = opts[:repeat_from] || 1

    # things to be merged with remote
    @push              = {:add => [], :edit => []}
    @pull              = {:add => [], :edit => [], :delete  => []}
    
    @logger            = ScreenLogger.new

    read_cache_file

    # must have userid till now
    initialize_service(:userid => userid, 
                       :password => password, 
                       :user => opts[:user], 
                       :apptoken => @apptoken, 
                       :appid => @appid,
                       :token => @token)

    check_changes
  end

  def local_merge
    @pull[:add].each    {|t| changes = toodle_to_taskwarrior(t); add_tw_task(changes) }
    @pull[:edit].each   {|t| changes = toodle_to_taskwarrior(t); edit_tw_task(t[:id], changes) }
    @pull[:delete].each {|t| delete_tw_task(t[:id]) }
  end

  def log
    @logger
  end

  def update_local_changes
    # upload new tasks
    new_ids = @task_warrior.new_task_ids
    new_ids.each { |uuid| @push[:add] << uuid }

    # upload modified
    if @last_sync
      @task_warrior.modified_after(@last_sync).collect(&:uuid).each do |uuid|
        next if new_ids.include?(uuid)  # avoid double upload
        next if @task_warrior[uuid].status == 'recurring'   # avoid recurring parent
        @push[:edit] << uuid
      end
    end

    #TODO: deleted tasks are added as edited
    #

    @push.each do |k,v|
      v.each do |uuid|
        key = (k == :add) ? :new : k
        log.send(key, "<= #{@task_warrior[uuid].to_h}")
      end
    end
  end

  def sync
    super

    sync_tasks

    true
  end

  def commit_changes

    commit_remote_changes

    commit_local_changes

    write_cache_file
  end

  private

  def add_tw_task(changes)
    tid = @task_warrior.add_task(changes.merge(:uuid => SecureRandom.uuid))
    # create parent for recurring tasks
    if @task_warrior[tid].recur and @task_warrior[tid].status == 'pending'
      pid = @task_warrior.add_task(
        changes.merge(
          :mask => '-', 
          :status => 'recurring', 
          :uuid => SecureRandom.uuid
        )
      )
      @task_warrior.edit_task(tid, :imask => '0', :parent => pid)
    end
  end

  def edit_tw_task(id, changes)
    task = @task_warrior[id]
    @task_warrior.edit_task(id, changes)
    parent_mask =  case task.status
                   when 'completed'; '+'
                   when 'deleted'; '*'
                   when 'pending'; '-'
                   end
    # sync changes to parent as well
    if pid = task.parent
      @task_warrior.edit_task(pid, changes.merge(:status => 'recurring', :mask => parent_mask))
      # delete all other children, so that when next time a task command is run,
      # all information would be updated
      delete_list = @task_warrior.find_children(pid).map(&:uuid).reject{|uuid| uuid == task.uuid }
      delete_list.each {|id| @task_warrior.delete_by_id(id) }
    end
  end

  def delete_tw_task(id)
    return unless @task_warrior[id]
    pid = @task_warrior[id].parent
    @task_warrior.delete_task(id)
    # permanently delete parent task and all of its other children 
    # if remote recurring task is deleted
    if pid
      delete_list = [pid]
      @task_warrior.find_children(pid).each{|t| delete_list << t.uuid }
      delete_list.each {|id| @task_warrior.delete_by_id(id) }
    end
  end

  def first_sync?
    not @last_sync or @task_warrior.size.zero?
  end

  def commit_local_changes
    @task_warrior.to_file(@task_file, @comp_file)
  end

  # has new value in account_info?
  def has_new_info?(field)
    @account_info[field] > @prev_account_info[field]
  end

  # read from previous sync stats, if it contains information....
  def read_cache_file
    return nil unless File.file? @cache_file

    cache = YAML.load_file(@cache_file)

    return nil unless cache.is_a? Hash
    return nil unless cache[:userid] == @userid

    @token             = cache[:token]
    @prev_account_info = cache[:account_info]
    @remote_folders    = cache[:remote_folders]
    @remote_contexts   = cache[:remote_contexts]
    @last_sync         = cache[:last_sync]
  end

  # write cache data to cache file
  def write_cache_file
    open(@cache_file, 'w') do |f|
      f.puts({ 
        :userid => @userid,
        :token => @token,
        :account_info => @account_info,
        :remote_folders => @remote_folders,
        :remote_contexts => @remote_contexts,
        :last_sync => Time.now.to_i ,
      }.to_yaml)
    end
  end

end

# prompt user to input something
#
def question_prompt(field, opts = {})
    trap("INT") { exit 1 }
    begin
      print "Please input #{field}: "
      response = opts[:password] ? STDIN.noecho(&:gets).strip : STDIN.gets.strip
    end until not response.empty?
    response
end

if __FILE__ == $0
  TASK_BASE_DIR = File.join(ENV['HOME'], '.task')
  TASK_FILE     = File.join(TASK_BASE_DIR, 'pending.data')
  COMP_FILE     = File.join(TASK_BASE_DIR, 'completed.data')
  CACHE_FILE    = File.join(TASK_BASE_DIR, 'syncwarrior_cache.yml')
  CONFIG_FILE   = File.join(TASK_BASE_DIR, 'syncwarrior_conf.yml')

  begin
    $config = YAML.load_file(CONFIG_FILE)
  rescue
    $config = {}
  end

  unless $config[:userid] and $config[:password]
    puts "It looks like this is your first time using this SyncWarrior."
    puts
    first_run = true
    $config[:userid] = nil
    $config[:user] = question_prompt("toodledo login name")
    $config[:password] = question_prompt("toodledo password", :password => true)
    puts
  end

  begin
    w = SyncWarrior.new($config[:userid], $config[:password], 
                        TASK_FILE, COMP_FILE, CACHE_FILE, 
                        $config.reject{|k,_| [:userid, :password].include? k}
                       )
    res = w.sync
  rescue RemoteAPIError => e
    puts "API Error: #{e.message}"
    exit 1
  rescue Exception => e
    puts "Error: #{e}"
    puts e.backtrace  if $DEBUG
    exit 1
  end

  if res and first_run
    open(CONFIG_FILE, 'w'){|f| f.puts( $config.merge(:userid => w.userid).to_yaml )}
  elsif not res
    puts "Sync does not complete successfully, please check your login credentials."
  end
end
