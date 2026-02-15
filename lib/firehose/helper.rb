module Firehose
  module Helper
    # Renders a <firehose-stream-source> element for the given streamables.
    #
    # Usage in Phlex:
    #   firehose_stream_from @report
    #   firehose_stream_from "dashboard", "user:#{current_user.id}"
    #   firehose_stream_from @report, path: "/my-cable"
    #
    def firehose_stream_from(*streamables, path: "/firehose")
      streams = streamables.map { |s| stream_name_for(s) }.join(",")
      render FirehoseStreamSource.new(streams:, path:)
    end

    private

    def stream_name_for(streamable)
      case streamable
      when String, Symbol
        streamable.to_s
      else
        # ActiveRecord model - use global ID or model name + id
        streamable.to_gid_param
      end
    end

    class FirehoseStreamSource < Phlex::HTML
      register_element :firehose_stream_source

      def initialize(streams:, path:)
        @streams = streams
        @path = path
      end

      def view_template
        firehose_stream_source(streams: @streams, path: @path)
      end
    end
  end
end
