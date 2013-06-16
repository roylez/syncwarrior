#!/usr/bin/env ruby
# coding: utf-8
#Author: Roy L Zuo (roylzuo at gmail dot com)
#Description: a simple toodledo API 

require 'net/http'
require 'json'
require 'digest'

class InformationError < Exception; end

class RemoteAPIError < Exception; end

module Toodledo
  def self.included(mod)
  end

  def initialize_service(opts = {})
    @conn = Connection.new(opts)
  end
end

class Toodledo::Connection
  def initialize(opts = {})
    @token_max_age = 60 * 60 * 4
    @appid         = opts[:appid]
    @apptoken      = opts[:apptoken]

    @password      = opts[:password]
    @token         = opts[:token]
    @userid        = opts[:userid] || get_userid(opts[:user])

    raise(InformationError, "User or Userid") unless @userid
  end

  def get_userid(user)
    call_account_api('lookup', 
                     :appid => @appid,
                     :email => user,
                     :pass => @password,
                     :sig => get_sig(user)
                    )[:userid]
  end

  def get_tasks(opts = {})
    if opts.key? :fields and opts[:fields].is_a? Array
      opts[:fields] = opts[:fields].map(&:to_s).join(',')
    end
    tasks = call_task_api(:get, opts)[1..-1]
    tasks.each do |t|
      t.delete(:completed)  unless t[:completed] and t[:completed] > 0
      t.delete(:duedate)    unless t[:duedate] and t[:duedate] > 0
      t.delete(:tag)        if t[:tag] and t[:tag].strip == ''
      t.delete(:repeat)     if t[:repeat] and t[:repeat].strip == ''
      #t.delete(:folder)     if t[:folder] and t[:folder] == '0'
      #t.delete(:context)    if t[:context] and t[:context] == '0'
      t.each_key{|key| t.delete(key) unless t[key] != '0'}
    end
    tasks
  end

  def get_deleted_tasks(after = nil)
    call_task_api(:deleted, :after => after)
  end

  def get_contexts
    call_context_api(:get)
  end

  def get_folders
    call_folder_api(:get)
  end

  def get_account
    call_account_api(:get, :key => key)
  end

  def add_context(name)
    call_context_api(:add, :name => name)
  end

  def add_folder(name)
    call_folder_api(:add, :name => name)
  end

  def add_tasks(tasks)
    call_task_api(:add, :tasks => JSON.dump(tasks))
  end

  def edit_tasks(tasks)
    call_task_api(:edit, :tasks => JSON.dump(tasks))
  end

  def delete_tasks(tasks)
    call_task_api(:edit, :tasks => JSON.dump(tasks.collect{|t| t[:id]}))
  end

  def delete_context(context_id)
    call_context_api(:delete, :id => context_id)
  end

  def delete_folder(folder_id)
    call_folder_api(:delete, :id => folder_id)
  end

  private

  def token
    if token_expired?
      res = call_account_api('token', :userid => @userid, :appid => @appid, :sig => get_sig(@userid))
      @token = [res[:token], Time.now]
    end
    @token.first
  end

  def token_expired?
    not @token or ( Time.now - @token.last > @token_max_age )
  end

  def get_sig(element)
    Digest::MD5.hexdigest(element + @apptoken)
  end

  # generate authentication key
  def key
    if not @key or token_expired?
      @key = Digest::MD5.hexdigest(Digest::MD5.hexdigest(@password) + @apptoken + token)
    end
    @key
  end

  def api_call(category, call_name, opts = {})
    url = URI.parse "http://api.toodledo.com/2/#{category}/#{call_name}.php"

    response = Net::HTTP.post_form(url, opts)
    res = JSON.parse(response.body, :symbolize_names => true)

    if res.is_a? Hash and res.key? :errorCode
      raise RemoteAPIError, res[:errorDesc]
    end

    res
  end

  def call_task_api(call_name, opts = {})
    api_call('tasks', call_name, opts.merge(:key => key))
  end

  def call_folder_api(call_name, opts = {})
    api_call('folders', call_name, opts.merge(:key => key))
  end

  def call_context_api(call_name, opts = {})
    api_call('contexts', call_name, opts.merge(:key => key))
  end

  def call_account_api(call_name, opts = {})
    api_call('account', call_name, opts)
  end
end

module Toodledo
  def check_changes
    @account_info = @conn.get_account 

    if @prev_account_info
      @remote_task_modified    = has_new_info? :lastedit_task
      @remote_task_deleted     = has_new_info? :lastdelete_task
      @remote_folder_modified  = has_new_info? :lastedit_folder
      @remote_context_modified = has_new_info? :lastedit_context
    end
  end

  def sync_folders
    if @remote_folder_modified.nil? or @remote_folder_modified
      @remote_folders = get_folders
      @remote_folder_modified =false
    end
  end

  def sync_contexts
    if @remote_context_modified.nil? or @remote_context_modified
      @remote_contexts = get_contexts
      @remote_context_modified = false
    end
  end

  def sync_tasks
    # if we first upload, and in the case that a task is modified locally and
    # completed remotely, the modification would be uploaded to server, and it
    # remains completed on server. Depending implementation of sync, there could
    # have been two situations: 1. it could not be marked as completed locally;
    # 2. it could be marked complete, but all merges done remotely should be
    # download again.
    #
    # If we first download, we could make the merge locally and upload anything
    # that worth uploading; and next time when sync starts, we only needs to
    # shift @last_sync a few seconds later to avoid double downloads.
    #
    # As TaskWarrior keeps a parent task for recurring items while toodledo does
    # not, parent/child task pair is treated as a single task when syncing,
    # which means whenever a recurring item is completed on toodledo, the whole
    # pair locally are removed from list (completion for child, deletion for
    # parent). Similar applies to remote modification, deletion or creation.
    #
    # The flow of syncing ....
    #   download -> local merge -> upload -> ( remote merge ) -> save files
    #
    #   1. calculate local changes, keep **uuid** in @push
    #   2. download remote changes, keep changed tasks in @pull
    #   3. push local changes according to @push
    #   4. locally merge @pull into @task_warrior
    #
    log.info "#{@task_warrior.size} tasks in local repository(completed: #{@task_warrior.completed.size}, pending: #{@task_warrior.pending.size})"

    update_local_changes

    update_remote_changes

    local_merge

    %Q{Ready to commit changes: 
      Upload:     NEW:#{@push[:add].size}    EDIT:#{@push[:edit].size}
      Download:   EDIT:#{@pull[:edit].size}   DELETE:#{@pull[:delete].size}
    }.strip.split("\n").each{|l| log.info l }

    commit_changes

    log.info "Commit completed. "

    log.info "#{@task_warrior.size} tasks in local repository(completed: #{@task_warrior.completed.size}, pending: #{@task_warrior.pending.size})"
  end

  def sync
    sync_folders

    sync_contexts

    true
  end

  def update_remote_changes
    useful_fields = [:folder, :context, :tag, :duedate, :priority, :added, :repeat] 

    # download new tasks and edited tasks 
    #
    ntasks = []
    if first_sync?
      #ntasks = get_tasks(:fields => useful_fields, :comp => 0)
      ntasks = get_tasks(:fields => useful_fields)
    elsif @remote_task_modified
      ntasks = @conn.get_tasks(:fields => useful_fields, :modafter => @last_sync )
    end
    ntasks.each do |t|
      unless id = t[:id] and @task_warrior[id]
        @pull[:add] << t
        log.new("=> #{t}")
      else
        @pull[:edit] << t
        log.edit("=> #{t}")
      end
    end

    # download the list of deleted tasks
    #
    if @remote_task_deleted
      dtasks = get_deleted_tasks(@last_sync)
      # toodledo ids in local tasks
      @pull[:delete] = dtasks.select{|i| i[:id]}
    end

    @pull[:delete].each do |t|
      log.delete "=> #{t}"
    end
  end

  def commit_remote_changes
    @push.each do |k, v|
      next if v.empty?
      res = @conn.send("#{k}_tasks".to_sym, v.collect{|uuid| taskwarrior_to_toodle(@task_warrior[uuid])})
      if k == :add  # append remote toodleid to local
        ids = Hash[ [v, res].transpose ]
        ids.each { |uuid, t| @task_warrior[uuid].toodleid = t[:id] }
      end
    end
  end

end

module Toodledo::Translation
  # convert from TaskWarriror to Toodledo format
  def taskwarrior_to_toodle(task)
    task = task.dup
    toodletask = {}
    toodletask[:title]    = task[:description]
    toodletask[:id]       = task[:toodleid]                         if task[:toodleid]
    toodletask[:duedate]  = to_toodle_date(task[:due].to_i)         if task[:due]
    toodletask[:completed]= to_toodle_date(task[:end].to_i)         if task[:end]
    toodletask[:priority] = tw_priority_to_toodle(task[:priority])  if task[:priority]
    toodletask[:folder]   = tw_project_to_toodle(task[:project])    if task[:project]
    if task[:recur]
      toodletask[:repeat] = tw_recur_to_toodle(task[:recur])
      toodletask[:repeatfrom] = @repeat_from
    end 
    if task[:tags]
      context = task[:tags].find{|i| i.start_with? '@' }
      if context
        toodletask[:context] = tw_context_to_toodle(context)
        task[:tags] = task[:tags].select{|t| not t.start_with? '@'}
      end
      toodletask[:tag] = task[:tags].join(",")
    end
    toodletask
  end

  # TW project => toodle folder
  def tw_project_to_toodle(project_name)
    folder = @remote_folders.find{|f| f[:name] == project_name}
    unless folder
      folder = add_folder(project_name).first
      @remote_folders << folder
    end
    folder[:id]
  end

  def tw_recur_to_toodle(recur)
    case recur.to_s.downcase
    when /\A(daily|weekly|biweekly|monthly|quarterly|yearly)\Z/; $1
    when /\A(annually)\Z/; 'Yearly'
    when /\A(fortneight)\Z/; 'Biweekly'
    when /\A(semiannual)\Z/; 'Semiannually'
    when /\A(weekdays)\Z/; 'Every weekday'
    when /\A(weekends)\Z/; 'Every weekend'
    when /\A(monday|tuesday|wednesday|thursday|friday|satday|sunday)/; "Every #{$1}"
    when /\A(\d)(\w+)\Z/; 
      unit = case $2
             when /^da/; 'day'
             when /^mo/; 'month'
             when /^(wk|week)/; 'week'
             when /^(yr|year)/; 'year'
             end
      "Every #{$1} #{unit}"
    end
  end 

  # TW @tag => toodle context
  def tw_context_to_toodle(context_name)
    # remove prefixing '@'
    context_name = context_name.delete("@")
    context = @remote_contexts.find{|c| c[:name] == context_name}
    unless context
      context = add_context(context_name).first
      @remote_contexts << context
    end
    context[:id]
  end

  # toodle folder => TW project
  def toodle_folder_to_tw(folderid)
    @remote_folders.find{|f| f[:id] == folderid}[:name]
  end

  def toodle_context_to_tw(contextid)
    '@' + @remote_contexts.find{|c| c[:id] == contextid}[:name]
  end
  
  def toodle_priority_to_tw(priority)
    case priority.to_i
    when 1; 'L'
    when 2; 'M'
    when 3; 'H'
    else; nil
    end
  end

  def toodle_repeat_to_tw(repeat)
    case repeat.downcase
    when /(daily|weekly|biweekly|monthly|quarterly|semiannual|yearly|weekday|weekend|monday|tuesday|wednesday|thursday|friday|satday|sunday)/; $1
    when /^every (\d+) (\w+)/; "#{$1}#{$2}"
    end
  end 

  def tw_priority_to_toodle(tw_priority)
    case tw_priority
    when 'L'; 1
    when 'M'; 2
    when 'H'; 3
    else; 0
    end
  end

  # toodle use GMT, all timestamps for date will be adjust to GMT noon
  #
  def to_toodle_date(secs, noon = true)
    t = Time.at(secs).
      strftime("%Y-%m-%d #{noon ? '12:00:00' : '%H:%M:%S'} UTC")
    Time.parse(t).to_i
  end

  def from_toodle_date(secs)
    t = Time.at(secs).utc.strftime("%Y-%m-%d 00:00:00")
    Time.parse(t).to_i
  end

  # convert from toodledo to TaskWarrior format as a hash
  def toodle_to_taskwarrior(task)
    twtask = {}
    twtask[:toodleid]    = task[:id]
    twtask[:description] = task[:title]
    twtask[:due]         = from_toodle_date(task[:duedate].to_i)  if task[:duedate]
    twtask[:tags]        = task[:tag].split(",").map(&:strip)     if task[:tag]
    twtask[:project]     = toodle_folder_to_tw(task[:folder])     if task[:folder]
    twtask[:priority]    = toodle_priority_to_tw(task[:priority]) if task[:priority]
    twtask[:status]      = task[:completed] ? "completed" : "pending"
    twtask[:entry]       = from_toodle_date(task[:added])
    twtask[:end]         = from_toodle_date(task[:completed])     if task[:completed]
    twtask[:modified]    = from_toodle_date(task[:modified])      if task[:modified]
    twtask[:recur]       = toodle_repeat_to_tw(task[:repeat])     if task[:repeat]
    if task[:context]
      con = toodle_context_to_tw(task[:context])
      twtask[:tags] = twtask[:tags] ? twtask[:tags].concat([ con ]) : [con]
    end

    twtask
  end
end
