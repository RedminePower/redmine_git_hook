module GitHook
  class Updater
    GIT_BIN = Redmine::Configuration["scm_git_command"] || "git"

    attr_writer :logger

    def initialize(payload, params = {})
      @payload = payload
      @params = params
    end

    def update_repos
      project = find_project
      repositories = git_repositories(project)
      if repositories.empty?
        log_info("Project '#{project}' ('#{project.identifier}') has no repository")
        return
      end

      repositories.each do |repository|
        tg1 = Time.now
        # Fetch the changes from Git
        update_repository(repository)
        tg2 = Time.now

        tr1 = Time.now
        # Fetch the new changesets into Redmine
        repository.fetch_changesets
        tr2 = Time.now

        logger.info { "  GitHook: Redmine repository updated: #{repository.identifier} (Git: #{time_diff_milli(tg1, tg2)}ms, Redmine: #{time_diff_milli(tr1, tr2)}ms)" }
      end
    end

    def update_review_issue(event_type)
      identifier = get_identifier
      setting = GitHookSetting.all.order(:id).select {|i| i.available? && identifier =~ Regexp.new(i.project_pattern)}.first
      unless setting.present?
        log_info("Available GitHookSetting does not exist for the project '#{identifier}'")
        return
      end

      # for GitLab
      if event_type == "Note Hook"
        update_review_issue_by_GitLab_comment(setting)
      elsif event_type == "Merge Request Hook"
        update_review_issue_by_GitLab_merge_request(setting)
      # for GitHub
      elsif event_type == "pull_request_review_comment"
        update_review_issue_by_GitHub_comment(setting)
      elsif event_type == "pull_request_review_thread"
        update_review_issue_by_GitHub_thread(setting)
      elsif event_type == "pull_request"
        update_review_issue_by_GitHub_pull_request(setting)
      else
        log_info("Event '#{event_type}' is not supported.")
      end
    end

    private

    attr_reader :params, :payload

    def log_info(msg)
      logger.info { "Redmine Git Hook plugin: #{msg}" }
    end

    def fail_not_found(msg)
      fail(ActiveRecord::RecordNotFound, "Redmine Git Hook plugin: #{msg}")
    end

    # Executes shell command. Returns true if the shell command exits with a
    # success status code.
    #
    # If directory is given the current directory will be changed to that
    # directory before executing command.
    def exec(command, directory)
      logger.debug { "  GitHook: Executing command: '#{command}'" }

      # Get a path to a temp file
      logfile = Tempfile.new("git_hook_exec")
      logfile.close

      full_command = "#{command} > #{logfile.path} 2>&1"
      success = if directory.present?
        Dir.chdir(directory) do
          system(full_command)
        end
      else
        system(full_command)
      end

      output_from_command = File.readlines(logfile.path)
      if success
        logger.debug { "  GitHook: Command output: #{output_from_command.inspect}" }
      else
        logger.error { "  GitHook: Command '#{command}' didn't exit properly. Full output: #{output_from_command.inspect}" }
      end

      return success
    ensure
      logfile.unlink if logfile && logfile.respond_to?(:unlink)
    end

    # Finds the Redmine project in the database based on the given project
    # identifier
    def find_project
      identifier = get_identifier
      project = Project.find_by_identifier(identifier.downcase)
      fail(
        ActiveRecord::RecordNotFound,
        "No project found with identifier '#{identifier}'"
      ) if project.nil?
      project
    end

    # Gets the project identifier from the querystring parameters and if that's
    # not supplied, assume the Git repository name is the same as the project
    # identifier.
    def get_identifier
      identifier = get_project_name
      fail(
        ActiveRecord::RecordNotFound,
        "Project identifier not specified"
      ) if identifier.nil?
      identifier.to_s
    end

    # Attempts to find the project name. It first looks in the params, then in
    # the payload if params[:project_id] isn't given.
    def get_project_name
      project_id = params[:project_id]
      name_from_repository = payload.fetch("repository", {}).fetch("name", nil)
      project_id || name_from_repository
    end

    def git_command(command)
      GIT_BIN + " #{command}"
    end

    def git_repositories(project)
      repositories = project.repositories.select do |repo|
        repo.is_a?(Repository::Git)
      end
      repositories || []
    end

    def logger
      @logger || NullLogger.new
    end

    def system(command)
      Kernel.system(command)
    end

    def time_diff_milli(start, finish)
      ((finish - start) * 1000.0).round(1)
    end

    # Fetches updates from the remote repository
    def update_repository(repository)
      command = git_command("fetch origin")
      fetch = exec(command, repository.url)
      return nil unless fetch

      command = git_command(
        "fetch --prune --prune-tags origin \"+refs/heads/*:refs/heads/*\""
      )
      exec(command, repository.url)
    end

    def update_review_issue_by_GitLab_comment(setting)
      unless params[:merge_request].present?
        log_info("Only comments on merge requests is supported.")
        return
      end

      reviewer = find_user(params[:user][:username], params[:user][:email])

      project = find_project
      parent = find_review_issue(project, params[:merge_request][:url], params[:merge_request][:description])
      unless parent.present?
        log_info("Linked review issue is not found. merge_request_url='#{params[:merge_request][:url]}'")
        return
      end
      if parent.closed?
        log_info("Linked review issue has been closed. '#{parent}'")
        return
      end

      child = Issue.where('project_id = ? AND description like ?',
        project.id, "%_discussion_id=#{params[:object_attributes][:discussion_id]}%").last
      view_on_git = create_link("View on Git", params[:object_attributes][:url])
      if child.present?
        child.description = child.description.gsub(/_blocking_discussions_resolved=.*,/,
          "_blocking_discussions_resolved=#{params[:merge_request][:blocking_discussions_resolved]},")
        child.description = child.description.gsub(/_type=.*,/, "_type=#{params[:object_attributes][:type]},")

        update_child(reviewer, setting, child, "#{params[:object_attributes][:note]}", view_on_git)
      else
        if params[:merge_request][:state] != "opened"
          log_info("This merge request is not open so no issues can be added. '#{params[:merge_request][:url]}'")
          return
        end

        description = "#{params[:object_attributes][:note]}"
        description << "\n\n"
        description << "---\n\n"
        description << "#{view_on_git} \n\n"
        description << "{{collapse(Please do not edit the followings.)\n"
        description << "_discussion_id=#{params[:object_attributes][:discussion_id]},\n"
        description << "_type=#{params[:object_attributes][:type]},\n"
        description << "_blocking_discussions_resolved=#{params[:merge_request][:blocking_discussions_resolved]},\n"
        description << "}} "

        create_child(reviewer, setting, parent, description)
      end
    end

    def update_review_issue_by_GitHub_comment(setting)
      reviewer = find_user(payload["comment"]["user"]["login"], payload["comment"]["user"]["email"])

      project = find_project
      parent = find_review_issue(project, payload["pull_request"]["html_url"], payload["pull_request"]["body"])
      unless parent.present?
        log_info("Linked review issue is not found. pull_request_url='#{payload["pull_request"]["html_url"]}'")
        return
      end
      if parent.closed?
        log_info("Linked review issue has been closed. '#{parent}'")
        return
      end

      child = nil
      if payload["comment"]["in_reply_to_id"].present?
        child = Issue.where('project_id = ? AND description like ?',
          project.id, "%_discussion_id=#{payload["comment"]["in_reply_to_id"]}%").last
      end
      view_on_git = create_link("View on Git", payload["comment"]["html_url"])
      if child.present?
        update_child(reviewer, setting, child, "#{payload["comment"]["body"]}", view_on_git)
      else
        if payload["pull_request"]["state"] != "open"
          log_info("This merge request is not open so no issues can be added. '#{payload["pull_request"]["url"]}'")
          return
        end

        description = "#{payload["comment"]["body"]}"
        description << "\n\n"
        description << "---\n\n"
        description << "#{view_on_git} \n\n"
        description << "{{collapse(Please do not edit the followings.)\n"
        description << "_discussion_id=#{payload["comment"]["id"]},\n"
        description << "}} "

        create_child(reviewer, setting, parent, description)
      end
    end

    def update_child(reviewer, setting, child, raw_comment, view_on_git)
      comment = "#{raw_comment}"
      keyword_to_resolve = setting.keyword_to_resolve_discussion
      if comment.include?(keyword_to_resolve)
        comment = comment.gsub!(keyword_to_resolve, "").strip
        if comment.empty?
          comment = view_on_git
        else
          comment << "\n\n"
          comment << "---\n\n"
          comment << view_on_git
        end
        close_child(reviewer, setting.remark_issue_closed_status, child, comment)
        log_info("Indicated issue closed. '#{child}'")
      else
        comment << "\n\n"
        comment << "---\n\n"
        comment << view_on_git
        child.init_journal(reviewer, comment)
        child.save
        child.reload
        log_info("Comment '#{raw_comment}' added to '#{child}'.")
      end
    end

    def create_child(reviewer, setting, parent, description)
      today = Time.zone.today
      child = Issue.new(
        :project_id => parent.project_id,
        :tracker_id => setting.remark_issue_tracker,
        :category_id => parent.category_id,
        :assigned_to_id => parent.assigned_to_id,
        :fixed_version_id => parent.fixed_version_id,
        :parent_issue_id => parent.id,
        :author_id => reviewer.id,
        :start_date => today,
        :due_date => today + 3.days,
        :subject => description.partition("\n")[0],
        :description => description
      )

      if child.save
        child.reload
        log_info("Indicated issue added. '#{child}'")
      else
        log_info("Failed to create indicated issue.")
      end
    end

    def update_review_issue_by_GitHub_thread(setting)
      if payload["action"] != "resolved"
        log_info("'#{payload["action"]}' action is not supported.")
        return
      end

      reviewer = find_user(payload["sender"]["login"], payload["sender"]["email"])

      project = find_project
      parent = find_review_issue(project, payload["pull_request"]["html_url"], payload["pull_request"]["body"])
      unless parent.present?
        log_info("Linked review issue is not found. pull_request_url='#{payload["pull_request"]["html_url"]}'")
        return
      end
      if parent.closed?
        log_info("Linked review issue has been closed. '#{parent}'")
        return
      end

      child = Issue.where('project_id = ? AND description like ?',
        project.id, "%_discussion_id=#{payload["thread"]["comments"][0]["id"]}%").last
      unless child.present?
        log_info("Indicated issue is not found. review_issue='#{parent}'")
        return
      end

      closed_id = setting.remark_issue_closed_status
      close_child(reviewer, closed_id, child, "This issue is closed because the conversation has been resolved.")
      log_info("Indicated issue closed. #{child}")
    end

    def update_review_issue_by_GitLab_merge_request(setting)
      action = params[:object_attributes][:action]
      if action != "merge" && action != "update"
        log_info("'#{action}' action is not supported.")
        return
      end

      reviewer = find_user(params[:user][:username], params[:user][:email])

      project = find_project
      parent = find_review_issue(project, params[:object_attributes][:url], params[:object_attributes][:description])
      unless parent.present?
        log_info("Linked review issue is not found. merge_request_url='#{params[:object_attributes][:url]}'")
        return
      end
      if parent.closed?
        log_info("Linked review issue has been closed. '#{parent}'")
        return
      end

      tracker_id = setting.remark_issue_tracker
      closed_id = setting.remark_issue_closed_status
      if action == "merge"
        children = parent.children.where('tracker_id = ? AND status_id != ? AND description like ?',
          tracker_id, closed_id, "%_blocking_discussions_resolved=%")
        close_children(reviewer, closed_id, children, "This issue is closed because the merge request has been merged.")
      elsif action == "update"
        resolved = params[:object_attributes][:blocking_discussions_resolved]
        if resolved
          children = parent.children.where('tracker_id = ? AND status_id != ? AND (description like ? OR description like ?)',
            tracker_id, closed_id, "%_blocking_discussions_resolved=false%", "%_type=null%")
          close_children(reviewer, closed_id, children, "This issue is closed because all threads have been resolved.")
        else
          log_info("Some threads has not been resolved.")
        end
      end
    end

    def update_review_issue_by_GitHub_pull_request(setting)
      if payload["action"] != "closed"
        log_info("'#{payload["action"]}' action is not supported.")
        return
      end

      reviewer = find_user(payload["sender"]["login"], payload["sender"]["email"])

      project = find_project
      parent = find_review_issue(project, payload["pull_request"]["html_url"], payload["pull_request"]["body"])
      unless parent.present?
        log_info("Linked review issue is not found. pull_request_url='#{payload["pull_request"]["html_url"]}'")
        return
      end
      if parent.closed?
        log_info("Linked review issue has been closed. '#{parent}'")
        return
      end

      tracker_id = setting.remark_issue_tracker
      closed_id = setting.remark_issue_closed_status
      children = parent.children.where('tracker_id = ? AND status_id != ? AND description like ?',
        tracker_id, closed_id, "%_discussion_id=%")
      close_children(reviewer, closed_id, children, "This issue is closed because the pull request has been closed.")
    end

    def find_user(username, email)
      reviewer = User.find_by_login(username)
      reviewer = User.find_by_mail(email) unless reviewer.present?
      unless reviewer.present?
        fail_not_found("Reviewer not found. username=#{username} or email=#{email}")
      end
      return reviewer
    end

    def find_review_issue(project, request_url, description)
      issues = Issue.where('project_id = ? AND description like ?',
        project.id, "%_merge_request_url=#{request_url}%")
      if issues.any?
        return issues.last
      else
        if m = description.match("refs #([0-9]+)")
          return Issue.find_by_id(m[1])
        end
      end
    end

    def create_link(header, url)
      if Setting.text_formatting == "textile"
        return "\"#{header}\":#{url} "
      elsif Setting.text_formatting == "markdown"
        return "[#{header}](#{url}) "
      else
        return url
      end
    end

    def close_child(reviewer, closed_id, child, comment)
      child.init_journal(reviewer, comment)
      child.status_id = closed_id
      child.save
      child.reload
    end

    def close_children(reviewer, closed_id, children, comment)
      if children.present? && children.any?
        comment << "\n\n"
        comment << "---\n\n"
        comment << "\"View on Git\":#{params[:object_attributes][:url]}"
        children.each do |child|
          close_child(reviewer, closed_id, child, comment)
        end
        log_info("Indicated issue(s) closed. #{children.map { |child| "'#{child}'" }.join(', ')}")
      else
        log_info("No indicated issues that need to close.")
      end
    end

  end
end
