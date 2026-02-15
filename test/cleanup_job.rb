require_relative "../../../config/environment"

describe Firehose::CleanupJob do
  before do
    @original_threshold = Firehose.cleanup_threshold
  end

  after do
    Firehose.cleanup_threshold = @original_threshold
  end

  def create_messages(stream, count)
    channel = Firehose::Channel.find_or_create_by!(name: stream)
    count.times do |i|
      seq = channel.sequence + 1
      channel.update_columns(sequence: seq)
      channel.messages.create!(sequence: seq, data: "event-#{i}")
    end
    channel.update_columns(messages_count: channel.messages.count)
    channel
  end

  it "keeps exactly threshold number of messages" do
    Firehose.cleanup_threshold = 5
    stream = "cleanup-exact-#{SecureRandom.hex(4)}"

    channel = create_messages(stream, 10)
    expect(channel.messages.count).to be == 10

    Firehose::CleanupJob.perform_now(stream)

    expect(channel.messages.count).to be == 5
  end

  it "keeps the newest messages" do
    Firehose.cleanup_threshold = 3
    stream = "cleanup-newest-#{SecureRandom.hex(4)}"

    channel = create_messages(stream, 6)

    Firehose::CleanupJob.perform_now(stream)

    remaining = channel.messages.order(:sequence).pluck(:data)
    expect(remaining).to be == ["event-3", "event-4", "event-5"]
  end

  it "does nothing when messages equal threshold" do
    Firehose.cleanup_threshold = 5
    stream = "cleanup-equal-#{SecureRandom.hex(4)}"

    channel = create_messages(stream, 5)

    Firehose::CleanupJob.perform_now(stream)

    expect(channel.messages.count).to be == 5
  end

  it "does nothing when messages below threshold" do
    Firehose.cleanup_threshold = 10
    stream = "cleanup-below-#{SecureRandom.hex(4)}"

    channel = create_messages(stream, 3)

    Firehose::CleanupJob.perform_now(stream)

    expect(channel.messages.count).to be == 3
  end

  it "does nothing for empty stream" do
    Firehose.cleanup_threshold = 5
    stream = "cleanup-empty-#{SecureRandom.hex(4)}"

    Firehose::CleanupJob.perform_now(stream)

    expect(Firehose::Channel.find_by(name: stream)).to be_nil
  end

  it "only affects the specified stream" do
    Firehose.cleanup_threshold = 3
    stream_a = "cleanup-a-#{SecureRandom.hex(4)}"
    stream_b = "cleanup-b-#{SecureRandom.hex(4)}"

    channel_a = create_messages(stream_a, 5)
    channel_b = create_messages(stream_b, 5)

    Firehose::CleanupJob.perform_now(stream_a)

    expect(channel_a.messages.count).to be == 3
    expect(channel_b.messages.count).to be == 5
  end

  it "handles threshold of 1" do
    Firehose.cleanup_threshold = 1
    stream = "cleanup-one-#{SecureRandom.hex(4)}"

    channel = create_messages(stream, 5)

    Firehose::CleanupJob.perform_now(stream)

    remaining = channel.messages
    expect(remaining.count).to be == 1
    expect(remaining.first.data).to be == "event-4"
  end

  it "handles very large threshold" do
    Firehose.cleanup_threshold = 1000
    stream = "cleanup-large-#{SecureRandom.hex(4)}"

    channel = create_messages(stream, 10)

    Firehose::CleanupJob.perform_now(stream)

    expect(channel.messages.count).to be == 10
  end

  it "can be run multiple times safely" do
    Firehose.cleanup_threshold = 5
    stream = "cleanup-idempotent-#{SecureRandom.hex(4)}"

    channel = create_messages(stream, 10)

    3.times { Firehose::CleanupJob.perform_now(stream) }

    expect(channel.messages.count).to be == 5
  end

  it "deletes channel when all messages are cleaned up" do
    Firehose.cleanup_threshold = 0
    stream = "cleanup-delete-#{SecureRandom.hex(4)}"

    channel = create_messages(stream, 3)
    expect(Firehose::Channel.find_by(name: stream)).not.to be_nil

    Firehose::CleanupJob.perform_now(stream)

    expect(Firehose::Channel.find_by(name: stream)).to be_nil
  end

  with "concurrent cleanup" do
    it "handles messages added during cleanup" do
      Firehose.cleanup_threshold = 5
      stream = "cleanup-concurrent-#{SecureRandom.hex(4)}"

      channel = create_messages(stream, 10)

      Firehose::CleanupJob.perform_now(stream)

      # Add more messages after cleanup
      3.times do |i|
        seq = channel.reload.sequence + 1
        channel.update_columns(sequence: seq)
        channel.messages.create!(sequence: seq, data: "new-#{i}")
      end
      channel.update_columns(messages_count: channel.messages.count)

      expect(channel.messages.count).to be == 8
    end
  end
end
