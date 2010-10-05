#!/usr/bin/env ruby
=begin
  Teambox Stat Generator

  (C) 2010 James S Urquhart.
 
  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in
  all copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
  THE SOFTWARE.
=end

require 'rubygems'
require 'json'
require 'haml'
require 'uri'
require 'gruff'
require 'optparse'
require 'httparty'

class Activity
  attr_accessor :data
  attr_accessor :user
  attr_accessor :type
  attr_accessor :body
  attr_accessor :clean_body
  attr_accessor :date
  attr_accessor :action
  attr_accessor :object
  
  NAME_SCAN = /@(\w+) /
  WORD_SCAN = /\w+/
  HTML_TAGS = /<[A-Za-z\/][^>]*>/
  QUESTION_SCAN = /\?/
  URL_SCAN = /(?:[a-z]+):\/\/[^ '"\)]+/
  
  def initialize(data, references)
    @data = data
    @references = references
    @ident = data['target_id']
    @type = data['target_type'].to_sym
    @user = @references["User#{@data['user_id']}"]
    @action = data['action'].to_sym
    
    @object = @references["#{@type}#{@ident}"]
    if target
      @body = @object['body']
      @clean_body = (@body || '').gsub(HTML_TAGS, '')
    end
    
    @date = Time.parse(data['created_at'])
  end
  
  def username
    @user['username']
  end
  
  # Comment target. Usually no target == Person invited, Task created, or Conversation created. 
  # For create, Comments will be listed twice (once for create, the other for the actual comment)
  def target
    type = target_type
    type ? @references["#{target_type}#{target_id}"] : nil
  end
  
  def target_type
    @object['target_type'] ? @object['target_type'].to_sym : nil
  end
  
  def target_id
    @object['target_id']
  end
  
  def mentions
    (@body || "").scan(NAME_SCAN).flatten
  end
  
  def words
    (@clean_body || "").scan(WORD_SCAN)
  end
  
  def urls
    (@body || "").scan(URL_SCAN)
  end
end

class MapList
  attr_accessor :list
  attr_accessor :maps
  attr_accessor :sums
  
  def initialize(list)
    @maps = {}
    @sums = {}
    @list = list
  end
  
  # Sums @items into @sums[map_type][map][sum_type]
  # Or in the case of @list, @sums[:list][sum_type]
  def sum(map_type, sum_type, &block)
    total = 0
    
    @sums[map_type] ||= {}
    sum_list = @sums[map_type]
    
    if map_type == :list
      items = @list
      sum_list[sum_type] = sum_array(v, &block)
    else
      items = @maps[map_type]
      items.each {|k,v| sum_list[k] ||= {}; sum_list[k][sum_type] = sum_array(v, &block)}
    end
  end
  
  def sum_array(list, &block)
    last_item = nil
    total = 0
    list.each do |value|
      result = block.call(value)
      unless result.nil? or result == 0
        last_item = value
        total += result
      end
    end
    
    [total, last_item]
  end
  
  def map(map_type, previous_map=nil, &block)
    items = previous_map ? @maps[previous_map] : @list
    item_map = {}
    
    items.each do |item|
      Array(block.call(item)).each { |map| next if map.nil?; item_map[map] ||= []; item_map[map] << item }
    end
    
    #puts "Mapped #{map_type}: size == #{item_map.length}, keys == " + item_map.map{|k,v| "#{k}=#{v.length}"}.join(',')
    @maps[map_type] = item_map
  end
end

class Report
BASE_STYLE = <<EOS  
   a {
     text-decoration: none;
   }
 
   a:link, a:visited {
     color: #0b407a;
   }
 
   a:hover {
     text-decoration: underline;
     color: #0b407a;
   }
 
   h2, h3 {
     font-size: 13px;
     border: 1px solid #ccc;
   }
 
   h2 {
     color: white;
     font-weight: bold;
     text-align: center;
     background-color: #78ACD7;
   }
 
   body {
     background-color: #ffffff;
     font-family: Verdana, Arial, sans-serif;
     font-size: 13px;
     color: black;
     text-align: center;
     margin: 0pt auto;
     width: 780px;
   }
 
   table {
     width: 780px;
     border-spacing: 1px 2px;
     border-collapse: separate;
   }
 
   td, th {
     font-family: Verdana, Arial, sans-serif;
     font-size: 13px;
     color: black;
     text-align: left;
   }
 
   td {
     background-color: #FAFAFA;
   }
   
   td.user img {
     display: block;
   }
   
   td div.example {
     width: 500px;
   }
   
   table.interest {
     border-spacing: 0px 2px;
   }
 
   table.interest td {
     border-left: 4px solid #EEE;
     padding: 3px;
   }
 
   table.interest p {
     margin: 3px 0px;
   }
 
   .title {
     font-family: Tahoma, Arial, sans-serif;
     font-size: 16px;
     font-weight: bold;
   }
 
   .tdtop {
     background-color: #CCCCCC;
     padding: 3px;
   }
 
   .rankc {
     background-color: #E0E0E0;
     padding: 3px;
   }
 
   .small {
     font-family: Verdana, Arial, sans-serif;
     font-size: 10px;
   }
 
   a.small {
     font-family: "Arial narrow", Arial, sans-serif;
     font-size: 10px;
     color: black;
     text-align: center;
   }
EOS

BASE_TEMPLATE = <<EOT
%html
  %head
    %title= @title
    %style{:type => 'text/css'}= @style
  %body
    %h1.title=@title
    %p= "Covers the period between \#{@lines[0].date} and \#{@lines[-1].date}"
    %h2= "Most active times"
    %div.graph
      %img{:src => 'hours.png'}/
    %h2= "Most active users"
    %table
      %tr
        %th
        %th.tdtop= "User"
        %th.tdtop= "Number of activities"
        %th.tdtop= "When?"
        %th.tdtop= "Random quote"
      - @sorted_nick_activity[0..25].each_index do |idx|
        - login = @sorted_nick_activity[idx]
        - data = @reports.maps[:users][login]
        %tr
          %th.rankc= idx
          %td.user
            %img{:src => @reports.maps[:users][@sorted_nick_activity[idx]][0].user['avatar_url']}/
            %strong= @sorted_nick_activity[idx]
          %td= data.length
          %td
          %td
            - if @reports.maps[:user_comments][login]
              %div.example= @reports.maps[:user_comments][login][rand(@reports.maps[:user_comments][login].length-1)].body
    - if @sorted_nick_activity.length > 25 # runners up
      %h3.title= "These didn't make it to the top:"
      = render_runners_up(@sorted_nick_activity[25...55])
      - if @sorted_nick_activity.length > 55
        %h3.title= "By the way, there were \#{@sorted_nick_activity.length-55} other users."
    %h2= "Big numbers"
    %table.interest
      - unless @top_question[0].nil?
        %tr
          %td
            %p= "Is <strong>\#{@top_question[0]}</strong> stupid or just asking too many questions? \#{'%.1f' % @top_question[1]}% lines contained a question!"
            - unless @next_question[0].nil?
              %p= "<strong>\#{@next_question[0]}</strong> didn't know that much either. \#{'%.1f' % @next_question[1]}% of his/her lines were questions."
      - unless @top_line[0].nil?
        %tr
          %td
            %p= "<strong>\#{@top_line[0]}</strong> wrote the longest lines, averaging \#{@top_line[1].to_i} letters per line."
            - unless @next_line[0].nil?
              %p= "<strong>\#{@next_line[0]}</strong> average was \#{@next_line[1].to_i} letters per line."
      - unless @low_line[0].nil?
        %tr
          %td
            %p= "<strong>\#{@low_line[0]}</strong> wrote the shortest lines, averaging \#{@low_line[1].to_i} characters per line."
            - unless @next_low_line[0].nil?
              %p= "<strong>\#{@next_low_line[0]}</strong> was light-lipped too, averaging \#{@next_low_line[1].to_i} characters per line."
      - unless @top_word[0].nil?
        %tr
          %td
            %p= "<strong>\#{@top_word[0]}</strong> spoke a total of \#{@top_word[1]} words!"
            - unless @next_word[0].nil?
              %p= "\#{@top_word[0]}'s faithful follower, <strong>\#{@next_word[0]}</strong>, didn't speak so much: \#{@next_word[1]} words."
      
      - unless @top_happy_smiley[0].nil?
        %tr
          %td
            %p= "<strong>\#{@top_happy_smiley[0]}</strong> brings happiness to the world. \#{'%.1f' % @top_happy_smiley[1]}% lines contained smiling faces. :)"
            - unless @next_happy_smiley[0].nil?
              %p= "<strong>\#{@next_happy_smiley[0]}</strong> isn't a sad person either, smiling \#{'%.1f' % @next_happy_smiley[1]}% of the time."
      
      - unless @top_sad_smiley[0].nil?
        %tr
          %td
            %p= "<strong>\#{@top_sad_smiley[0]}</strong> seems to be sad at the moment: \#{'%.1f' % @top_sad_smiley[1]}% lines contained sad faces. :("
            - unless @next_sad_smiley[0].nil?
              %p= "<strong>\#{@next_sad_smiley[0]}</strong> is also a sad person, crying \#{'%.1f' % @next_sad_smiley[1]}% of the time."
    - unless @sorted_words.empty?
      %h2= "Most used words"
      %table
        %tr
          %th
          %th.tdtop= "Word"
          %th.tdtop= "Number of uses"
          %th.tdtop= "Last Used By"
        - @sorted_words[0...10].each_index do |idx|
          - entries = @reports.maps[:words][@sorted_words[idx]]
          %tr
            %td.rankc= idx+1
            %td= @sorted_words[idx]
            %td= entries.length
            %td= entries[-1].username
    - unless @sorted_refs.empty?
      %h2= "Most referenced user"
      %table
        %tr
          %th
          %th.tdtop= "User"
          %th.tdtop= "Number of uses"
          %th.tdtop= "Last Used by"
        - @sorted_refs[0...5].each_index do |idx|
          - entries = @reports.maps[:refs][@sorted_refs[idx]]
          %tr
            %td.rankc= idx+1
            %td= @sorted_refs[idx]
            %td= entries.length
            %td= entries[-1].username
    - unless @sorted_urls.empty?
      %h2= "Most referenced URLs"
      %table
        %tr
          %th
          %th.tdtop= "URL"
          %th.tdtop= "Number of uses"
          %th.tdtop= "Last Used by"
          - @sorted_urls[0...5].each_index do |idx|
            - entries = @reports.maps[:urls][@sorted_urls[idx]]
            %tr
              %td.rankc= idx+1
              %td= @sorted_urls[idx]
              %td= entries.length
              %td= entries[-1].username
    %h2= "Other interesting numbers"
    %table.interest
      - if @sorted_conversations.length > 0
        %tr
          %td
            - entry = @reports.maps[:conversations][@sorted_conversations[0]]
            %p= "<strong>\#{resolve_conversation(@sorted_conversations[0])['name']}</strong> is the talk of the project, containing \#{entry.length} comments."
            - if @sorted_conversations.length > 1
              - entry = @reports.maps[:conversations][@sorted_conversations[1]]
              %p= "The runner up, <strong>\#{resolve_conversation(@sorted_conversations[1])['name']}</strong> contains \#{entry.length} comments."
      - unless @top_task_change[0].nil?
        %tr
          %td
            %p= "<strong>\#{resolve_task(@top_task_change[0])['name']}</strong> is a bit of a hot potato. It's changed hands \#{@top_task_change[1]} times."
            - unless @next_task_change[0].nil?
              %p= "<strong>\#{resolve_task(@next_task_change[0])['name']}</strong> is also reasonably warm, changing hands \#{@next_task_change[1]} times."
      - unless @top_task_create[0].nil?
        %tr
          %td
            %p= "<strong>\#{@top_task_create[0]}</strong> is quite the delegator, having created \#{@top_task_create[1]} tasks!"
            - unless @next_task_create[0].nil?
              %p= "The runner up, <strong>\#{@next_task_create[0]}</strong> is also management material, creating \#{@next_task_create[1]} tasks."
      - unless @top_conversation_create[0].nil?
        %tr
          %td
            %p= "<strong>\#{@top_conversation_create[0]}</strong> is a bit of a chatterbox, creating \#{@top_conversation_create[1]} conversations."
            - unless @next_conversation_create[0].nil?
              %p= "Another chatterbox, <strong>\#{@next_conversation_create[0]}</strong> also can't keep their mouth shut, creating \#{@next_conversation_create[1]} conversations."
    %p= "Total number of activities: \#{@lines.length}."
    %p= "Generated using the example Teambox API Stat Generator."
EOT

  attr_reader :lines
  attr_accessor :conversations
  attr_accessor :tasks
  attr_accessor :title

  def initialize(lines)
    @lines = lines
    @title = "Teambox report"
    @conversations = {}
    @tasks = {}
  end
  
  def resolve_task(id)
    if @tasks[id]
      @tasks[id]
    else
      {'id' => id, 'name' => "Task ##{id}"}
    end
  end
  
  def resolve_conversation(id)
    if @conversations[id]
      conversations[id]
    else
      {'id' => id, 'name' => "Conversation ##{id}"}
    end
  end
  
  def render_runners_up(activities)
    rowcount = 0
    content = activities.map do |id|
      name = @reports.maps[:users][id][0].username
      "<td>#{name}</td>"
    end
    
    str = []
    content.each_index do |idx|
      str << if idx % 5 == 0
        "<tr>#{content[idx]}"
      elsif idx % 5 == 4
        "#{content[idx]}</tr>"
      else
        content[idx]
      end
    end
    
    if (content.length-1) % 5 != 4
      str << "</tr>"
    end
    
    "<table>#{str.join('')}</table>"
  end
  
  # Checks for highest or lowest sum
  # returns [user, value, example_line]
  def sum_compete(map_type, sum_type, check_high, &block)
    winner = check_high ? [nil, 0, nil] : [nil, nil, nil]
    runner = winner.clone
    
    @reports.sums[map_type].each do |k,v|
      the_sum = v[sum_type]
      value = block.call(k,the_sum)
      next if value == 0
      
      if (check_high and value > winner[1]) or (!check_high and (winner[1].nil? or value < winner[1]))
        winner[0] = k
        winner[1] = value
        winner[2] = the_sum[2]
      elsif (check_high and value > runner[1]) or (!check_high and (runner[1].nil? or value < runner[1]))
        runner[0] = k
        runner[1] = value
        runner[2] = the_sum[2]
      end
    end
    
    [winner, runner]
  end
  
  def generate
    @reports = MapList.new(@lines)
    
    # Maps...
    @reports.map(:tasks) { |activity| activity.target_type == :Task ? activity.target_id : nil }
    @reports.map(:conversations) { |activity| activity.target_type == :Conversation ? activity.target_id : nil }
    
    @reports.map(:users) { |activity| activity.username }
    @reports.map(:user_comments) { |activity| (activity.type == :Comment && !activity.body.nil?) ? activity.username : nil }
    @reports.map(:hours) { |activity| activity.date.hour }
    
    @reports.map(:words) { |activity| activity.words }
    @reports.map(:urls) { |activity| activity.urls }
    @reports.map(:refs) { |activity| activity.mentions }
    
    # Sums...
    @reports.sum :users, :word_count do |activity| 
      activity.words.length
    end

    @reports.sum :users, :question_count do |activity|
      if activity.body
        activity.body.scan(Activity::QUESTION_SCAN).length > 0 ? 1 : nil
      else
        nil
      end
    end
    
    @reports.sum :users, :line_length do |activity|
      if activity.body
        lines = activity.body.split("\n")
        unless lines.empty?
          (lines.map(&:length).inject{|r,e| r + e} || 0) / lines.length.to_f
        else
          nil
        end
      else
        nil
      end
    end
    
    sad_match = / :\(/
    happy_match = / :\)/
    @reports.sum :users, :happy_smileys do |activity|
      if activity.body
        activity.body.scan(happy_match).length > 0 ? 1 : nil
      else
        nil
      end
    end
    
    @reports.sum :users, :sad_smileys do |activity|
      if activity.body
        activity.body.scan(sad_match).length > 0 ? 1 : nil
      else
        nil
      end
    end
    
    @reports.sum :tasks, :potato do |activity|
      (activity.object['assigned_id'] != activity.object['previous_assigned_id']) ? 1 : nil
    end
    
    @reports.sum :users, :created_tasks do |activity|
      (activity.action == :create and activity.type == :Task) ? 1 : nil
    end
    
    @reports.sum :users, :created_conversations do |activity|
      (activity.action == :create and activity.type == :Conversation) ? 1 : nil
    end
    
    # Derived stats
    
    # Top lists
    @sorted_nick_activity = @reports.maps[:users].map{|k,v| [k, v.length]}.sort{|a,b| a[1] <=> b[1]}.map{|i|i[0]}.reverse
    @sorted_words = @reports.maps[:words].map{|k,v| [k, v.length]}.sort{|a,b| a[1] <=> b[1]}.map{|i|i[0]}.reverse
    @sorted_urls = @reports.maps[:urls].map{|k,v| [k, v.length]}.sort{|a,b| a[1] <=> b[1]}.map{|i|i[0]}.reverse
    @sorted_refs = @reports.maps[:refs].map{|k,v| [k, v.length]}.sort{|a,b| a[1] <=> b[1]}.map{|i|i[0]}.reverse
    
    # Top conversation
    @sorted_conversations = @reports.maps[:conversations].map{|k,v| [k, v.length]}.sort{|a,b| a[1] <=> b[1]}.map{|i|i[0]}.reverse
    
    # Top question
    @compete_question = sum_compete(:users, :question_count, true){|k,s|(s[0].to_f / @reports.maps[:users][k].length) * 100}
    @top_question = @compete_question[0]
    @next_question = @compete_question[1]
    
    # Top line length
    @compete_line = sum_compete(:users, :line_length, true){|k,s|s[0]}
    @top_line = @compete_line[0]
    @next_line = @compete_line[1]
    
    # Lowest line length
    @compete_low_line = sum_compete(:users, :line_length, false){|k,s|s[0]}
    @low_line = @compete_low_line[0]
    @next_low_line = @compete_low_line[1]
    
    # Word length
    @compete_top_words = sum_compete(:users, :word_count, true){|k,s|s[0]}
    @top_word = @compete_top_words[0]
    @next_word = @compete_top_words[1]
    
    # Smileys :)
    @compete_top_happy = sum_compete(:users, :happy_smileys, true){|k,s|(s[0].to_f / @reports.maps[:users][k].length) * 100}
    @top_happy_smiley = @compete_top_happy[0]
    @next_happy_smiley = @compete_top_happy[1]
    
    # Smileys :(
    @compete_top_sad = sum_compete(:users, :sad_smileys, true){|k,s|(s[0].to_f / @reports.maps[:users][k].length) * 100}
    @top_sad_smiley = @compete_top_sad[0]
    @next_sad_smiley = @compete_top_sad[1]
    
    # Task changes
    @compete_task_change = sum_compete(:tasks, :potato, true){|k,s|s[0]}
    @top_task_change = @compete_task_change[0]
    @next_task_change = @compete_task_change[1]
    
    @top_task_change[0] = nil if @top_task_change[1] < 2
    @next_task_change[0] = nil if @next_task_change[1] == @top_task_change[1]
    
    # Task creation
    @compete_task_create = sum_compete(:users, :created_tasks, true){|k,s|s[0]}
    @top_task_create = @compete_task_create[0]
    @next_task_create = @compete_task_create[1]
    
    @top_task_create[0] = nil if @top_task_create[1] < 2
    @next_task_create[0] = nil if @next_task_create[1] == @top_task_create[1]
    
    # Conversation creation
    @compete_conversation_create = sum_compete(:users, :created_conversations, true){|k,s|s[0]}
    @top_conversation_create = @compete_conversation_create[0]
    @next_conversation_create = @compete_conversation_create[1]
    
    @top_conversation_create[0] = nil if @top_conversation_create[1] < 2
    @next_conversation_create[0] = nil if @next_conversation_create[1] == @top_conversation_create[1]
    
    # Generate the hours graph
    hours_graph = Gruff::Bar.new(710)
    labels = {}
    set = (0..23).map do |hour|
      labels[hour] = hour.to_s
      value = @reports.maps[:hours][hour]
      value.nil? ? 0 : value.length
    end
    hours_graph.y_axis_label = "Activities"
    hours_graph.hide_legend = true
    hours_graph.marker_font_size = 13
    hours_graph.left_margin = hours_graph.top_margin = 2
    hours_graph.title_margin = hours_graph.legend_margin = 0
    hours_graph.data("Hour", set)
    hours_graph.labels = labels
    hours_graph.write('hours.png')
    
    # Final output
    @style = BASE_STYLE
    Haml::Engine.new(BASE_TEMPLATE).render self
  end
end

module Teambox
  include HTTParty
  base_uri "teambox.com/api/1"
  
  API_LIMIT=25
  
  # Util to grab a lot of items in separate requests
  def self.grab_list(url, max, options={})
    count = 0
    query = (options[:query]||{}).merge({:count => [API_LIMIT,max].min})
    items = []
    while count < max
      list = get(url, options.merge(:query => query)).map{|l|l}
      items << list
      count += list.length
      break if list.length == 0
      query['max_id'] = list[-1]['id']
    end
    
    puts "Grabbed #{items.flatten.length} items from #{url} in #{items.length} requests."
    items.flatten
  end
  
  # Util to grab a lot of items in separate requests, but which use
  # {objects:[], references:[]} for the response.
  def self.grab_list_with_refs(url, max, options={})
    count = 0
    query = (options[:query]||{}).merge({:count => [API_LIMIT,max].min})
    items = []
    references = {}
    while count < max
      data = get(url, options.merge(:query => query))
      list = data['objects']
      data['references'].each do |ref|
        key = "#{ref['type']}#{ref['id']}"
        references[key] ||= ref
      end
      items << list
      count += list.length
      break if list.length == 0
      query['max_id'] = list[-1]['id']
    end
    
    puts "Grabbed #{items.flatten.length} items with #{references.keys.length} references from #{url} in #{items.length} requests."
    {'objects' => items.flatten, 'references' => references}
  end
end

OPTIONS = {
  :auth => {
    :username => nil,
    :password => nil,
  },

  :project_id => nil,
  :activities_file => nil,
  :tasks_file => nil,
  :conversations_file => nil,
  
  :limit => 100,
  :dump => false
}

def load_activities
  if OPTIONS[:activities_file]
    JSON.parse(File.open(OPTIONS[:activities_file]){|f| f.read})
  else
    Teambox.grab_list_with_refs("/projects/#{OPTIONS[:project_id]}/activities", OPTIONS[:limit], :basic_auth => OPTIONS[:auth]).tap do |list|
      File.open('activities.json', 'w'){|f| f.write JSON.pretty_generate(list)} if OPTIONS[:dump]
    end
  end
end

def load_tasks
  tasks = {}
  if OPTIONS[:tasks_file]
    JSON.parse(File.open(OPTIONS[:tasks_file]){|f| f.read})
  else
    Teambox.grab_list_with_refs("/projects/#{OPTIONS[:project_id]}/tasks", 1000, :basic_auth => OPTIONS[:auth]).tap do |list|
      File.open('tasks.json', 'w'){|f| f.write JSON.pretty_generate(list)} if OPTIONS[:dump]
    end
  end['objects'].each{|c| tasks[c['id']] = c}
  tasks
end

def load_conversations
  conversations = {}
  if OPTIONS[:conversations_file]
    JSON.parse(File.open(OPTIONS[:conversations_file]){|f| f.read})
  else
    Teambox.grab_list_with_refs("/projects/#{OPTIONS[:project_id]}/conversations", 200, :basic_auth => OPTIONS[:auth]).tap do |list|
      File.open('conversations.json', 'w'){|f| f.write JSON.pretty_generate(list)} if OPTIONS[:dump]
    end
  end['objects'].each{|c| conversations[c['id']] = c}
  conversations
end

def entry(project_name)
  # Check minimum requirements...
  OPTIONS[:project_id] = project_name
  if [OPTIONS[:auth][:username], OPTIONS[:auth][:password]].include?(nil) and 
     [OPTIONS[:activities_file], OPTIONS[:tasks_file], OPTIONS[:conversations_file]].include?(nil)
    puts "Not enough information available to dump! (you need either a valid login OR a complete set of API dumps)."
    exit
  end
  
  if project_name.nil?
    puts "Please specify the project you want to dump"
    exit
  end
  
  # Generate the report!
  activities = load_activities
  references = activities['references']
  report = Report.new(activities['objects'].reverse.map{|a| Activity.new(a, references)})
  report.tasks = load_tasks
  report.conversations = load_conversations
  report.title = "#{project_name} Report"
  
  puts "Generating report..."
  output = report.generate
  File.open('out.html', 'w') {|f|f.write(output)}
  
  puts "DONE!"
end

OptionParser.new do |opts|
  opts.banner = "Usage: teamboxstats.rb [options] project"
  opts.on( '-u', '--user USER', 'Username' ) { |user| OPTIONS[:auth][:username] = user }
  opts.on( '-p', '--password PASSWORD', 'Password' ) { |password| OPTIONS[:auth][:password] = password }
  opts.on( '-a', '--activities FILE', 'Read from an activities dump instead of the API' ) { |file| OPTIONS[:activities_file] = file }
  opts.on( '-c', '--conversations FILE', 'Read from a conversations dump instead of the API' ) { |file| OPTIONS[:conversations_file] = file }
  opts.on( '-t', '--tasks FILE', 'Read from a tasks dump instead of the API' ) { |file| OPTIONS[:tasks_file] = file }
  opts.on( '-l', '--limit LIMIT', 'How many activities should be retrieved' ) { |limit| OPTIONS[:limit] = limit.to_i }
  opts.on( '-d', '--dump', 'Dump API lists to activities.json, tasks.json, and conversations.json' ) { OPTIONS[:dump] = true }
  opts.on( '-h', '--help', 'Display this screen' ) { puts opts; exit }
end.parse!

entry(ARGV[0])
