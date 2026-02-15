class FirehoseController < ApplicationController
  include Firehose::Stream

  # Public endpoint - no auth required.
  # Uncomment below to add authentication and stream authorization.

  # before_action :authenticate_user!
  #
  # def authorize_streams(streams)
  #   streams.select { |s| current_user.can_access?(s) }
  # end
  #
  # def build_event(event)
  #   event  # transform or return nil to skip
  # end
end
