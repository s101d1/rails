# frozen_string_literal: true

require "service/shared_service_tests"

module ActiveStorage::Service::StorjSharedServiceTests
  extend ActiveSupport::Concern

  include ActiveStorage::Service::SharedServiceTests

  included do
    # Override the "downloading in chunks" test for dealing with download chunk size 7408 bytes limit issue: https://github.com/storj/uplink-c/issues/21
    # TODO: delete the StorjSharedServiceTests class if the issue had been solved.
    def test_downloading_in_chunks
      key = SecureRandom.base58(24)
      expected_chunks = [ "a" * 7408, "b" ]
      actual_chunks = []

      begin
        @service.upload key, StringIO.new(expected_chunks.join)

        @service.download key do |chunk|
          actual_chunks << chunk
        end

        assert_equal expected_chunks, actual_chunks, "Downloaded chunks did not match uploaded data"
      ensure
        @service.delete key
      end
    end
  end
end
