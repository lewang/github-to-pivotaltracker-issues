#!/usr/bin/env ruby

# Description:  Migrates GitHub Issues to Pivotal Tracker.

require 'rubygems'
require 'bundler/setup'

require 'octokit'
require 'pivotal-tracker'
require 'json'
require 'byebug'
require 'csv'
require 'rest_client'
# "blank?" you know you want dis.
require 'active_support/all'
require 'thor'


I18n.enforce_available_locales = false

# uncomment to debug
# require 'net-http-spy'
# puts ENV['@github_token']
# puts ENV['@pivotal_token']


class GhImporter

  PIVOTAL_PROJECT_USE_SSL = true

  DEFAULTS = HashWithIndifferentAccess.new({
    dry_run: true
  })

  def initialize(args)
    args = DEFAULTS.merge(args)

    @dry_run = args[:dry_run]
    @github_repo = args[:github_repo]

    @pivotal_project_id = args[:pivotal_project_id]
    @pivotal_token = args[:pivotal_token]
    @github_tag = args[:github_tag]

    @github = Octokit::Client.new(:access_token => args[:github_token])


    if @pivotal_token
      PivotalTracker::Client.token = @pivotal_token
      PivotalTracker::Client.use_ssl = PIVOTAL_PROJECT_USE_SSL
      @pivotal_project = PivotalTracker::Project.find(@pivotal_project_id)
    end
  end

  def get_pivotal_epics_hash
    @epic_hash ||= -> {
      epic_url = 'https://www.pivotaltracker.com/services/v5/projects/' + @pivotal_project_id.to_s() + '/epics' + '?token=' + @pivotal_token

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
    lacking_epic = rows.find_all{|r| r["epic"].blank?}

    unless lacking_epic.blank?
      raise "Rows found without epics, bro. -- %s" % lacking_epic.map{|l| l['id']}.to_json
    end

    epic_hash = get_pivotal_epics_hash
    epic_reverse_hash = Hash[epic_hash.map(&:reverse)]
    rows.map do |row|
      epic = row["epic"]
      if epic_reverse_hash["epic"]
      elsif epic_hash[epic]
        row["epic"] = epic_hash[epic]
      else
        raise "can't find epic: #{epic}"
      end
      row
    end

  end

  def github_issues_to_arr

    @github_tag or raise "Must specify github tag."

    total_issues = 0

    require 'bundler/setup'

    page_issues = 1

    issues = @github.list_issues(@github_repo, { :page => page_issues, :labels => @github_tag } )
    arr = []
    while issues.count > 0

      issues.each do |issue|
        total_issues += 1

        labels = issue.labels.map(&:name).reject {|n| n =~ /#{@github_tag}/i}

        arr << {'id' => issue.number,
          'title' => issue.title,
          'labels' => labels,
          'description' => issue.body,
          'url' =>  issue.url
        }
      end

      page_issues += 1
      issues = @github.list_issues(@github_repo, { :page => page_issues, :labels => @github_tag } )
    end

    arr
  end

  def github_issues_to_csv(file)
    arr = github_issues_to_arr

    if @dry_run
      puts "Dry run specified, skipping actually doing things."
    else
      CSV.open(file, "w") do |csv|
        keys = arr.first.keys
        csv << keys
        arr.each do |row|
          csv << keys.map{|k| row[k]}
        end
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
        # comments = github.issue_comments(@github_repo, issue.number)

        labels = [issue["epic"], 'github-import']
        story_hash = {:name => issue["title"],
          :description => issue["description"],
          :labels => labels,
          :story_type => story_type,
          :current_state => story_current_state
        }
        puts "story hash #{story_hash}"

        if @dry_run
          puts "Dry run specified, skipping actually doing things."
        else
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

          @github.add_comment(@github_repo, issue["id"], "Migrated to pivotal tracker #{story.url}")
          @github.close_issue(@github_repo, issue["id"])

          ### LE: Don't close issue

          # github.close_issue(@github_repo, issue.number)

        end
      end
    rescue StandardError => se
      puts se.message
      exit 1
    end
  end
end

class ImporterThor < Thor

  DEFAULT_ARGS = {
    github_token: ENV['GITHUB_TOKEN'],
    github_repo: 'shifthealthparadigms/tickit-app',
    pivotal_token: ENV['PIVOTAL_TOKEN'],
    pivotal_project_id: 1093508,
    dry_run: true
  }

  desc "get_issues_csv [CSV_FILE]", "Download issues csv from github. (default is \"issues-<tag>.csv\")"
  method_option :dry_run, {
    type: :boolean,
    desc: "Dry run, don't generate output file.",
    default: true,
    required: false
  }
  method_option :github_token, {
    type: :string,
    desc: "Github token make one from https://github.com/settings/applications",
    default: ENV['GITHUB_TOKEN'],
    required: !ENV['GITHUB_TOKEN']
  }
  method_option :github_repo, {
    type: :string,
    desc: "Github repository",
    default: 'shifthealthparadigms/tickit-app',
    required: false
  }
  method_option :github_tag, {
    type: :string,
    desc: "Tag to to filter issues.",
    required: true
  }

  def get_issues_csv(csv_file=nil)
    args = {}
    importer = GhImporter.new(options)
    csv_file = csv_file || "issues-#{options[:github_tag].parameterize}.csv"
    importer.github_issues_to_csv(csv_file)
  end



  desc "pivotal_import CSV_FILE", "Import processed CSV into pivotal."
  method_option :dry_run, {
    type: :boolean,
    desc: "Dry run, don't actually do the import bit.",
    default: true,
    required: false
  }
  method_option :github_token, {
    type: :string,
    desc: "Github token make one from https://github.com/settings/applications",
    default: ENV['GITHUB_TOKEN'],
    required: !ENV['GITHUB_TOKEN']
  }
  method_option :github_repo, {
    type: :string,
    desc: "Github repository",
    default: 'shifthealthparadigms/tickit-app',
    required: false
  }

  method_option :pivotal_token, {
    type: :string,
    desc: "Pivotal API token, make one from https://www.pivotaltracker.com/profile",
    default: ENV['PIVOTAL_TOKEN'],
    required: !ENV['PIVOTAL_TOKEN']
  }
  method_option :pivotal_project_id, {
    type: :string,
    desc: "Pivotal project id -- last part of the URL of the project page.",
    default: '1093508',
    required: false
  }
  def pivotal_import(csv_file)
    args = {}
    importer = GhImporter.new(options)
    issues = importer.fix_up_epics(importer.get_csv_arr(csv_file))
    importer.pivotal_import_stories(issues)
  end

end

ImporterThor.start
