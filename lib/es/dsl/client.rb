require 'net/http'
require 'uri'
require 'json'

module ES
  module DSL
    # Thin HTTP wrapper around Net::HTTP.
    # Swap this out for Faraday / elasticsearch-ruby client if preferred.
    class Client
      attr_reader :config

      def initialize(config)
        @config = config
      end

      # POST /<index>/_search
      def search(index:, body:, timeout: nil, params: {})
        timeout ||= config.request_timeout
        query_params = params.map { |k, v| "#{k}=#{v}" }.join('&')
        path = "/#{index}/_search"
        path += "?#{query_params}" unless query_params.empty?

        post(path, body, timeout: timeout)
      end

      def search_pit(body:, timeout: nil, params: {})
        timeout ||= config.request_timeout
        query_params = params.map { |k, v| "#{k}=#{v}" }.join('&')
        path = '/_search'
        path += "?#{query_params}" unless query_params.empty?

        post(path, body, timeout: timeout)
      end

      # POST /<index>/_pit?keep_alive=<keep_alive>
      def create_pit(index:, keep_alive:)
        post("/#{index}/_pit?keep_alive=#{keep_alive}", nil)
      end

      # DELETE /_pit
      def delete_pit(pit_id:)
        delete('/_pit', { id: pit_id })
      end

      private

      def post(path, body, timeout: nil)
        timeout ||= config.request_timeout
        request(:post, path, body, timeout: timeout)
      end

      def delete(path, body, timeout: nil)
        timeout ||= config.request_timeout
        request(:delete, path, body, timeout: timeout)
      end

      def request(method, path, body, timeout: nil)
        uri = URI.parse("#{config.url}#{path}")

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl   = uri.scheme == 'https'
        http.open_timeout = timeout
        http.read_timeout = timeout

        req_class = { post: Net::HTTP::Post, delete: Net::HTTP::Delete }.fetch(method)
        req = req_class.new(uri.request_uri)
        req['Content-Type'] = 'application/json'
        req['Accept']       = 'application/json'

        config.headers.each { |k, v| req[k.to_s] = v }

        if config.user
          req.basic_auth(config.user, config.password)
        end

        req.body = body.to_json if body

        log_request(method, uri, body) if config.log

        response = http.request(req)

        parsed = JSON.parse(response.body, symbolize_names: false)

        log_response(response.code, parsed) if config.log

        unless response.is_a?(Net::HTTPSuccess)
          raise RequestError.new(response.code.to_i, parsed)
        end

        parsed
      end

      def log_request(method, uri, body)
        warn "[ES] #{method.upcase} #{uri} #{body&.to_json}"
      end

      def log_response(code, body)
        warn "[ES] #{code} #{body.inspect}"
      end
    end

    class RequestError < StandardError
      attr_reader :status, :body

      def initialize(status, body)
        @status = status
        @body   = body
        super("[#{status}] #{body}")
      end
    end
  end
end
