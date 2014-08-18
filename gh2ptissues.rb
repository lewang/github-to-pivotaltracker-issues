#!/usr/bin/env ruby

# Description:  Migrates GitHub Issues to Pivotal Tracker.

GITHUB_REPO = 'shifthealthparadigms/tickit-app'
PIVOTAL_PROJECT_ID = 1093508
PIVOTAL_PROJECT_USE_SSL = true

GITHUB_TOKEN = ENV['GITHUB_TOKEN']
PIVOTAL_TOKEN = ENV['PIVOTAL_TOKEN'].to_s unless ENV['PIVOTAL_TOKEN'].nil?
GITHUB_TAG = 'Pivotal 3'

require 'rubygems'
require 'octokit'
require 'pivotal-tracker'
require 'json'
require 'byebug'
require 'csv'
require 'rest_client'

def get_pivotal_epics_hash
  @epic_hash ||= -> {
    epic_url = 'https://www.pivotaltracker.com/services/v5/projects/' + PIVOTAL_PROJECT_ID.to_s() + '/epics' + '?token=' + PIVOTAL_TOKEN

    res = RestClient.get(epic_url, {:accept => :json})
    res_hash = JSON.parse(res)

    Hash[res_hash.map{|r| [r['name'], r["label"]["name"]]}]
  }[]
end

def get_csv_arr(file)
  csv = CSV.new(File.open(file).read, headers: true)
  csv.to_a.map{|r|r.to_h}
end

def fix_up_epics(rows)
  epic_hash = get_pivotal_epics_hash
  epic_reverse_hash = Hash[epic_hash.map(&:reverse)]
  rows.map do |row|
    epic = row["epic"]
    if epic_reverse_hash["epic"]
    elsif epic_hash[epic]
      row["epic"] = epic_hash[epic]
    else
      debugger
      raise "can't find epic: #{epic}"
    end
    row
  end

end

def github_issues_to_arr

  issues_filter = GITHUB_TAG # update filter as appropriate
  total_issues = 0

  page_issues = 1

  issues = @github.list_issues(GITHUB_REPO, { :page => page_issues, :labels => issues_filter } )
  arr = []
  while issues.count > 0

    issues.each do |issue|
      total_issues += 1

      labels = issue.labels.map(&:name).reject {|n| n =~ /#{issues_filter}/i}

      arr << {'id' => issue.number,
        'title' => issue.title,
        'labels' => labels,
        'description' => issue.body,
        'url' =>  issue.url
      }
    end

    page_issues += 1
    issues = @github.list_issues(GITHUB_REPO, { :page => page_issues, :labels => issues_filter } )
  end

  arr
end

def github_issues_to_csv(file)
  arr = github_issues_to_arr

  CSV.open(file, "w") do |csv|
    keys = arr.first.keys
    csv << keys
    arr.each do |row|
      csv << keys.map{|k| row[k]}
    end
  end
end

def pivotal_import_stories(issues)

  begin

    story_type = 'feature' # 'bug', 'feature', 'chore', 'release'. Omitting makes it a feature.

    story_current_state = 'unscheduled' # 'unscheduled', 'started', 'accepted', 'delivered', 'finished', 'unscheduled'.
    # 'unstarted' puts it in 'Current' if Commit Mode is on; 'Backlog' if Auto Mode is on.
    # Omitting puts it in the Icebox.

    issues.each do |issue|
      ### LE::skip comments
      # comments = github.issue_comments(GITHUB_REPO, issue.number)

      labels = [issue["epic"], 'github-import']
      story_hash = {:name => issue["title"],
        :description => issue["description"],
        :labels => labels,
        :story_type => story_type,
        :current_state => story_current_state
      }
      puts "story hash #{story_hash}"

      unless @dry_run
        story = @pivotal_project.stories.create(story_hash)

        puts "created #{story.url}"

        # url given is to the API endpoint to get the story
        # transform it here.
        issue_url = issue["url"].sub(/api\./, '').sub(/\/repos/, '')

        story.notes.create(
                           text: "Migrated from #{issue_url}",
                           )
        puts "created comment for #{story.url}"

        ### LE: don't import comments

        # comments.each do |comment|
        #   story.notes.create(
        #     text: comment.body.gsub(/\r\n\r\n/, "\n\n"),
        #     author: comment.user.login,
        #     noted_at: comment.created_at
        #   )
        # end

        @github.add_comment(GITHUB_REPO, issue["id"], "Migrated to pivotal tracker #{story.url}")

        ### LE: Don't close issue

        # github.close_issue(GITHUB_REPO, issue.number)

      end
    end
  rescue StandardError => se
    puts se.message
    exit 1
  end


end

# uncomment to debug
# require 'net-http-spy'
# puts ENV['GITHUB_TOKEN']
# puts ENV['PIVOTAL_TOKEN']

@dry_run = false

@github = Octokit::Client.new(:access_token => GITHUB_TOKEN)

PivotalTracker::Client.token = PIVOTAL_TOKEN
PivotalTracker::Client.use_ssl = PIVOTAL_PROJECT_USE_SSL

@pivotal_project = PivotalTracker::Project.find(PIVOTAL_PROJECT_ID)

file = "pivotal-#{GITHUB_TAG}.csv"

###########################
## export issues to csv: ##
###########################

# github_issues_to_csv(file)

###################
## import issues ##
###################

begin
  issues = fix_up_epics(get_csv_arr(file))
  pivotal_import_stories(issues)
rescue Exception => e
  puts e.backtrace
end
