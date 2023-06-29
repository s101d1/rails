# frozen_string_literal: true

require "service/storj_shared_service_tests"
require "net/http"
require "database/setup"

if SERVICE_CONFIGURATIONS[:storj]
  class ActiveStorage::Service::StorjServiceTest < ActiveSupport::TestCase
    SERVICE = ActiveStorage::Service.configure(:storj, SERVICE_CONFIGURATIONS)

    include ActiveStorage::Service::StorjSharedServiceTests

    test "name" do
      assert_equal :storj, @service.name
    end

    test "direct upload" do
      key      = SecureRandom.base58(24)
      data     = "Something else entirely!"
      checksum = OpenSSL::Digest::MD5.base64digest(data)
      url      = @service.url_for_direct_upload(key, expires_in: 5.minutes, content_type: "text/plain", content_length: data.size, checksum: checksum)

      uri = URI.parse url
      request = Net::HTTP::Put.new uri.request_uri
      request.body = data
      request.add_field "Content-Type", "text/plain"
      request.add_field "Content-MD5", checksum
      Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        http.request request
      end

      assert_equal data, @service.download(key)
    ensure
      @service.delete key
    end

    test "direct upload with content disposition" do
      key      = SecureRandom.base58(24)
      data     = "Something else entirely!"
      checksum = OpenSSL::Digest::MD5.base64digest(data)
      url      = @service.url_for_direct_upload(key, expires_in: 5.minutes, content_type: "text/plain", content_length: data.size, checksum: checksum)

      uri = URI.parse url
      request = Net::HTTP::Put.new uri.request_uri
      request.body = data
      @service.headers_for_direct_upload(key, checksum: checksum, content_type: "text/plain", filename: ActiveStorage::Filename.new("test.txt"), disposition: :attachment).each do |k, v|
        request.add_field k, v
      end
      Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        http.request request
      end

      assert_equal("attachment; filename=\"test.txt\"; filename*=UTF-8''test.txt", @service.s3_bucket.object(key).content_disposition)
      assert_equal("attachment; filename=\"test.txt\"; filename*=UTF-8''test.txt", @service.object(key).custom["content-disposition"])
    ensure
      @service.delete key
    end

    test "directly uploading file larger than the provided content-length does not work" do
      key      = SecureRandom.base58(24)
      data     = "Some text that is longer than the specified content length"
      checksum = OpenSSL::Digest::MD5.base64digest(data)
      url      = @service.url_for_direct_upload(key, expires_in: 5.minutes, content_type: "text/plain", content_length: data.size - 1, checksum: checksum)

      uri = URI.parse url
      request = Net::HTTP::Put.new uri.request_uri
      request.body = data
      request.add_field "Content-Type", "text/plain"
      request.add_field "Content-MD5", checksum
      upload_result = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        http.request request
      end

      assert_equal "403", upload_result.code
      assert_raises ActiveStorage::FileNotFoundError do
        @service.download(key)
      end
    ensure
      @service.delete key
    end

    test "linkshare URL generation" do
      url = @service.url(@key, expires_in: 5.minutes)

      assert_match(/#{@link_sharing_address}\/raw\/[a-z].*\/#{@service.bucket}\/#{@key}/, url)
    end

    test "upload a zero byte file" do
      blob = directly_upload_file_blob filename: "empty_file.txt", content_type: nil
      user = User.create! name: "DHH", avatar: blob

      assert_equal user.avatar.blob, blob
    end

    test "upload with content type" do
      key          = SecureRandom.base58(24)
      data         = "Something else entirely!"
      content_type = "text/plain"

      @service.upload(
        key,
        StringIO.new(data),
        checksum: OpenSSL::Digest::MD5.base64digest(data),
        filename: "cool_data.txt",
        content_type: content_type
      )

      assert_equal content_type, @service.object(key).custom["content-type"]
    ensure
      @service.delete key
    end

    test "upload with custom_metadata" do
      key      = SecureRandom.base58(24)
      data     = "Something else entirely!"
      @service.upload(
        key,
        StringIO.new(data),
        checksum: Digest::MD5.base64digest(data),
        content_type: "text/plain",
        custom_metadata: { "foo" => "baz" },
        filename: "custom_metadata.txt"
      )

      assert_equal "baz", @service.object(key).custom["foo"]
    ensure
      @service.delete key
    end

    test "upload with content disposition" do
      key  = SecureRandom.base58(24)
      data = "Something else entirely!"

      @service.upload(
        key,
        StringIO.new(data),
        checksum: OpenSSL::Digest::MD5.base64digest(data),
        filename: ActiveStorage::Filename.new("cool_data.txt"),
        disposition: :attachment
      )

      assert_equal("attachment; filename=\"cool_data.txt\"; filename*=UTF-8''cool_data.txt", @service.object(key).custom["content-disposition"])
    ensure
      @service.delete key
    end

    test "uploading a large object in multiple parts" do
      key  = SecureRandom.base58(24)
      data = SecureRandom.bytes(8.megabytes)

      @service.upload key, StringIO.new(data), checksum: OpenSSL::Digest::MD5.base64digest(data)
      assert data == @service.download(key)
    ensure
      @service.delete key
    end

    test "uploading a small object with multipart_upload_threshold configured" do
      service = build_service(multipart_upload_threshold: 6.megabytes)

      key  = SecureRandom.base58(24)
      data = SecureRandom.bytes(5.megabytes)

      service.upload key, StringIO.new(data), checksum: OpenSSL::Digest::MD5.base64digest(data)
      assert data == service.download(key)
    ensure
      service.delete key
    end

    test "update custom_metadata" do
      key      = SecureRandom.base58(24)
      data     = "Something else entirely!"
      @service.upload(key, StringIO.new(data), checksum: OpenSSL::Digest::MD5.base64digest(data), disposition: :attachment, filename: ActiveStorage::Filename.new("test.html"), content_type: "text/html", custom_metadata: { "foo" => "baz" })

      @service.update_metadata(key, disposition: :inline, filename: ActiveStorage::Filename.new("test.txt"), content_type: "text/plain", custom_metadata: { "foo" => "bar" })

      object = @service.object(key)
      assert_equal "text/plain", object.custom["content-type"]
      assert_match(/inline;.*test.txt/, object.custom["content-disposition"])
      assert_equal "bar", object.custom["foo"]
    ensure
      @service.delete key
    end

    private
      def build_service(configuration = {})
        ActiveStorage::Service.configure :storj, SERVICE_CONFIGURATIONS.deep_merge(storj: configuration)
      end
  end
else
  puts "Skipping Storj Service tests because no storj configuration was supplied"
end
