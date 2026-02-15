require_relative "../../../config/environment"

describe Firehose::CleanupJob do
  before do
    @original_threshold = Firehose.cleanup_threshold
  end

  after do
    Firehose.cleanup_threshold = @original_threshold
  end

  it "keeps exactly threshold number of events" do
    Firehose.cleanup_threshold = 5
    stream = "cleanup-exact-#{SecureRandom.hex(4)}"

    # Create 10 events
    10.times { |i| Firehose::Event.create!(stream:, data: "event-#{i}") }
    expect(Firehose::Event.where(stream:).count).to be == 10

    Firehose::CleanupJob.perform_now(stream)

    expect(Firehose::Event.where(stream:).count).to be == 5
  end

  it "keeps the newest events" do
    Firehose.cleanup_threshold = 3
    stream = "cleanup-newest-#{SecureRandom.hex(4)}"

    events = 6.times.map { |i| Firehose::Event.create!(stream:, data: "event-#{i}") }

    Firehose::CleanupJob.perform_now(stream)

    remaining = Firehose::Event.where(stream:).order(:id).pluck(:data)
    expect(remaining).to be == ["event-3", "event-4", "event-5"]
  end

  it "does nothing when events equal threshold" do
    Firehose.cleanup_threshold = 5
    stream = "cleanup-equal-#{SecureRandom.hex(4)}"

    5.times { |i| Firehose::Event.create!(stream:, data: "event-#{i}") }

    Firehose::CleanupJob.perform_now(stream)

    expect(Firehose::Event.where(stream:).count).to be == 5
  end

  it "does nothing when events below threshold" do
    Firehose.cleanup_threshold = 10
    stream = "cleanup-below-#{SecureRandom.hex(4)}"

    3.times { |i| Firehose::Event.create!(stream:, data: "event-#{i}") }

    Firehose::CleanupJob.perform_now(stream)

    expect(Firehose::Event.where(stream:).count).to be == 3
  end

  it "does nothing for empty stream" do
    Firehose.cleanup_threshold = 5
    stream = "cleanup-empty-#{SecureRandom.hex(4)}"

    # No error should be raised
    Firehose::CleanupJob.perform_now(stream)

    expect(Firehose::Event.where(stream:).count).to be == 0
  end

  it "only affects the specified stream" do
    Firehose.cleanup_threshold = 3
    stream_a = "cleanup-a-#{SecureRandom.hex(4)}"
    stream_b = "cleanup-b-#{SecureRandom.hex(4)}"

    5.times { |i| Firehose::Event.create!(stream: stream_a, data: "a-#{i}") }
    5.times { |i| Firehose::Event.create!(stream: stream_b, data: "b-#{i}") }

    Firehose::CleanupJob.perform_now(stream_a)

    expect(Firehose::Event.where(stream: stream_a).count).to be == 3
    expect(Firehose::Event.where(stream: stream_b).count).to be == 5
  end

  it "handles threshold of 1" do
    Firehose.cleanup_threshold = 1
    stream = "cleanup-one-#{SecureRandom.hex(4)}"

    5.times { |i| Firehose::Event.create!(stream:, data: "event-#{i}") }

    Firehose::CleanupJob.perform_now(stream)

    remaining = Firehose::Event.where(stream:)
    expect(remaining.count).to be == 1
    expect(remaining.first.data).to be == "event-4"
  end

  it "handles very large threshold" do
    Firehose.cleanup_threshold = 1000
    stream = "cleanup-large-#{SecureRandom.hex(4)}"

    10.times { |i| Firehose::Event.create!(stream:, data: "event-#{i}") }

    Firehose::CleanupJob.perform_now(stream)

    # All events should remain
    expect(Firehose::Event.where(stream:).count).to be == 10
  end

  it "can be run multiple times safely" do
    Firehose.cleanup_threshold = 5
    stream = "cleanup-idempotent-#{SecureRandom.hex(4)}"

    10.times { |i| Firehose::Event.create!(stream:, data: "event-#{i}") }

    3.times { Firehose::CleanupJob.perform_now(stream) }

    expect(Firehose::Event.where(stream:).count).to be == 5
  end

  with "concurrent cleanup" do
    it "handles events added during cleanup" do
      Firehose.cleanup_threshold = 5
      stream = "cleanup-concurrent-#{SecureRandom.hex(4)}"

      10.times { |i| Firehose::Event.create!(stream:, data: "event-#{i}") }

      Firehose::CleanupJob.perform_now(stream)

      # Add more events after cleanup
      3.times { |i| Firehose::Event.create!(stream:, data: "new-#{i}") }

      # Should have 5 (kept) + 3 (new) = 8 events
      expect(Firehose::Event.where(stream:).count).to be == 8
    end
  end
end
