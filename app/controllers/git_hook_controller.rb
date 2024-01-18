require "json"

class GitHookController < ApplicationController
  skip_before_action :verify_authenticity_token, :check_if_login_required

  def index
    message_logger = GitHook::MessageLogger.new(logger)
    if request.post?
      if request.headers["X-GitHub-Event"].present?
        git_event = request.headers["X-GitHub-Event"]
        if git_event == "push"
          update_repository(message_logger)
        elsif git_event == "pull_request_review_comment" ||
              git_event == "pull_request_review_thread" ||
              git_event == "pull_request"
          update_review_issue(message_logger, git_event)
        end
      elsif request.headers["X-Gitlab-Event"].present?
        git_event = request.headers["X-Gitlab-Event"]
        if git_event == "Push Hook"
          update_repository(message_logger)
        elsif git_event == "Note Hook" || git_event == "Merge Request Hook"
          update_review_issue(message_logger, git_event)
        end
      end
    end

    messages = message_logger.messages.map { |log| log[:message] }
    render(:json => messages)

  rescue ActiveRecord::RecordNotFound => error
    render_error_as_json(error, 404)

  rescue TypeError => error
    render_error_as_json(error, 412)
  end

  def welcome
    # Render the default layout
  end

  private

  def parse_payload
    JSON.parse(params[:payload] || "{}")
  end

  def render_error_as_json(error, status)
    render(
      :json => {
        :title => error.class.to_s,
        :message => error.message
      },
      :status => status
    )
  end

  def update_repository(logger)
    updater = GitHook::Updater.new(parse_payload, params)
    updater.logger = logger
    updater.update_repos
  end

  def update_review_issue(logger, event_type)
    updater = GitHook::Updater.new(parse_payload, params)
    updater.logger = logger
    updater.update_review_issue(event_type)
  end

end
