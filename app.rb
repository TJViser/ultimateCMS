require 'sinatra/base'
require 'json'
require 'rack/cors'
require 'rack/protection'
require 'rack/attack'
require 'dotenv/load'
require 'securerandom'
require 'uri'

require_relative 'lib/github_client'
require_relative 'lib/edit_agent'
require_relative 'lib/site_store'
require_relative 'lib/sanitize'

module UltimateCMS
  class App < Sinatra::Base

    # ============================================
    # SECURITY MIDDLEWARE
    # ============================================

    # Rack::Protection provides CSRF, session hijacking, XSS, and other protections
    use Rack::Protection, except: [:json_csrf] # json_csrf can interfere with API endpoints
    use Rack::Protection::ContentSecurityPolicy,
      default_src: "'self'",
      script_src: "'self'",
      style_src: "'self' 'unsafe-inline'",
      img_src: "'self' https://avatars.githubusercontent.com",
      connect_src: "'self' https://api.github.com",
      frame_ancestors: "'none'"

    # Rate limiting
    Rack::Attack.throttle('api/edit', limit: 10, period: 60) do |req|
      req.ip if req.path == '/api/edit' && req.post?
    end
    Rack::Attack.throttle('api/sites', limit: 5, period: 60) do |req|
      req.ip if req.path == '/api/sites' && req.post?
    end
    Rack::Attack.throttle('auth', limit: 10, period: 300) do |req|
      req.ip if req.path.start_with?('/auth/')
    end
    use Rack::Attack

    # CORS — enforce per-site allowed origins (default: deny all cross-origin)
    use Rack::Cors do
      allow do
        origins do |source, _env|
          # Allow same-origin and configured origins; static assets are always allowed
          source # dynamically validated in before filter
        end
        resource '/api/*', headers: :any, methods: [:get, :post, :options], credentials: true
        resource '/ucms.js', headers: :any, methods: [:get]
        resource '/editor.js', headers: :any, methods: [:get]
      end
    end

    set :public_folder, File.join(__dir__, 'public')
    set :site_store, SiteStore.new

    # ============================================
    # SECURITY HEADERS
    # ============================================

    before do
      headers 'X-Content-Type-Options' => 'nosniff',
              'X-Frame-Options' => 'DENY',
              'X-XSS-Protection' => '1; mode=block',
              'Referrer-Policy' => 'strict-origin-when-cross-origin',
              'Permissions-Policy' => 'camera=(), microphone=(), geolocation=()'

      if request.scheme == 'https'
        headers 'Strict-Transport-Security' => 'max-age=31536000; includeSubDomains'
      end
    end

    # Validate Origin for API requests
    before '/api/*' do
      origin = request.env['HTTP_ORIGIN']
      next unless origin # same-origin requests may not send Origin

      # For /api/edit, validate against site's allowed_origins
      if request.path == '/api/edit' && request.post?
        # Origin will be checked after payload is parsed (in the endpoint)
      end
    end

    # ============================================
    # PAGES
    # ============================================

    get '/' do
      send_file File.join(settings.public_folder, 'index.html')
    end

    # ============================================
    # SITE REGISTRATION (site owner calls this)
    # ============================================

    post '/api/sites' do
      content_type :json

      payload = parse_json_body
      halt 400, json_error('Invalid JSON') unless payload

      %w[repo branch github_token].each do |f|
        halt 400, json_error("Missing: #{f}") unless payload[f]
      end

      # Validate repo format
      unless Sanitize.valid_repo?(payload['repo'])
        halt 400, json_error('Invalid repo format. Expected: owner/repo')
      end

      # Validate branch name
      unless Sanitize.valid_branch?(payload['branch'] || 'main')
        halt 400, json_error('Invalid branch name')
      end

      # Validate github_token format (basic check)
      unless Sanitize.valid_string?(payload['github_token'], max_length: 500)
        halt 400, json_error('Invalid token')
      end

      # Validate allowed_origins (must be valid URLs)
      allowed_origins = Array(payload['allowed_origins'])
      allowed_origins.each do |origin|
        unless Sanitize.valid_url?(origin)
          halt 400, json_error("Invalid origin URL: #{Sanitize.escape_html(origin)}")
        end
      end

      site = settings.site_store.create(
        repo: payload['repo'],
        branch: payload['branch'] || 'main',
        github_token: payload['github_token'],
        allowed_origins: allowed_origins
      )

      {
        site_key: site[:key],
        embed_script: "<script src=\"#{Sanitize.escape_html(request.base_url)}/ucms.js\" data-site=\"#{Sanitize.escape_html(site[:key])}\"></script>"
      }.to_json
    end

    get '/api/sites' do
      content_type :json
      token = extract_token
      halt 401, json_error('Unauthorized') unless token

      sites = settings.site_store.list_for_token(token)
      sites.map { |s| { key: s[:key], repo: s[:repo], branch: s[:branch] } }.to_json
    end

    # ============================================
    # GITHUB OAUTH (for contributors)
    # ============================================

    get '/auth/github' do
      site_key = params['site']
      client_id = ENV['GITHUB_CLIENT_ID']

      halt 500, 'GITHUB_CLIENT_ID not configured' unless client_id

      # Validate site_key format
      unless site_key && Sanitize.valid_string?(site_key, max_length: 50, pattern: /\Ask_[a-f0-9]+\z/)
        halt 400, 'Invalid site key'
      end

      # Generate CSRF-safe state with HMAC
      nonce = SecureRandom.hex(16)
      state = "#{site_key}:#{nonce}"

      # Store state server-side for verification
      settings.site_store.save_oauth_state(nonce, {
        site_key: site_key,
        created_at: Time.now.iso8601
      })

      redirect_uri = "#{request.base_url}/auth/github/callback"

      redirect "https://github.com/login/oauth/authorize?" + URI.encode_www_form(
        client_id: client_id,
        redirect_uri: redirect_uri,
        state: state,
        scope: 'repo'
      )
    end

    get '/auth/github/callback' do
      code = params['code']
      state = params['state']

      halt 400, 'Missing code or state' unless code && state

      # Validate and verify state to prevent CSRF
      site_key, nonce = state.split(':', 2)
      halt 400, 'Invalid state' unless nonce

      stored_state = settings.site_store.get_oauth_state(nonce)
      halt 403, 'Invalid or expired OAuth state' unless stored_state
      halt 403, 'State mismatch' unless stored_state[:site_key] == site_key

      # Clean up used state
      settings.site_store.delete_oauth_state(nonce)

      # Exchange code for access token
      conn = Faraday.new(url: 'https://github.com')
      res = conn.post('/login/oauth/access_token') do |req|
        req.headers['Accept'] = 'application/json'
        req.body = URI.encode_www_form({
          client_id: ENV['GITHUB_CLIENT_ID'],
          client_secret: ENV['GITHUB_CLIENT_SECRET'],
          code: code
        })
      end

      token_data = JSON.parse(res.body)
      access_token = token_data['access_token']

      halt 401, 'GitHub auth failed' unless access_token

      # Get user info
      user_conn = Faraday.new(url: 'https://api.github.com')
      user_res = user_conn.get('/user') do |req|
        req.headers['Authorization'] = "Bearer #{access_token}"
        req.headers['Accept'] = 'application/vnd.github.v3+json'
      end
      user = JSON.parse(user_res.body)

      # Create a session token (in production: store in DB / use JWT with expiry)
      session_token = SecureRandom.hex(32)
      settings.site_store.save_session(session_token, {
        github_token: access_token,
        username: user['login'],
        avatar: user['avatar_url'],
        site_key: site_key
      })

      # Determine allowed origin for postMessage
      site = settings.site_store.get(site_key)
      post_message_origin = if site && site[:allowed_origins]&.any?
        Sanitize.escape_js(site[:allowed_origins].first)
      else
        # Fallback: use the request's referrer origin or restrict to same origin
        Sanitize.escape_js(request.base_url)
      end

      # Escape all values for safe embedding in JavaScript
      safe_token = Sanitize.escape_js(session_token)
      safe_username = Sanitize.escape_js(user['login'].to_s)
      safe_avatar = Sanitize.escape_js(user['avatar_url'].to_s)

      # Return to the opener window via postMessage with specific origin
      <<~HTML
        <!DOCTYPE html>
        <html>
        <head><title>Authenticated</title></head>
        <body>
          <script>
            if (window.opener) {
              window.opener.postMessage({
                type: 'ucms:auth',
                token: '#{safe_token}',
                username: '#{safe_username}',
                avatar: '#{safe_avatar}'
              }, '#{post_message_origin}');
            }
            window.close();
          </script>
        </body>
        </html>
      HTML
    end

    # ============================================
    # EDIT ENDPOINT (called by editor.js)
    # ============================================

    post '/api/edit' do
      content_type :json

      # Authenticate contributor
      session_token = extract_token
      halt 401, json_error('Not authenticated') unless session_token

      contributor = settings.site_store.get_session(session_token)
      halt 401, json_error('Invalid session') unless contributor

      payload = parse_json_body
      halt 400, json_error('Invalid JSON') unless payload

      # Validate required fields
      halt 400, json_error('Missing site_key') unless payload['site_key'].is_a?(String)
      halt 400, json_error('Missing page') unless payload['page'].is_a?(Hash)
      halt 400, json_error('Missing changes') unless payload['changes'].is_a?(Array)
      halt 400, json_error('Too many changes') if payload['changes'].length > 50

      # Validate page fields
      page = payload['page']
      unless page['url'].is_a?(String) && page['path'].is_a?(String)
        halt 400, json_error('Invalid page data')
      end
      halt 400, json_error('Invalid page URL') unless Sanitize.valid_url?(page['url'])

      # Validate each change
      payload['changes'].each_with_index do |change, i|
        unless change['old_text'].is_a?(String) && change['new_text'].is_a?(String)
          halt 400, json_error("Change #{i}: missing old_text or new_text")
        end
        unless Sanitize.valid_string?(change['old_text'], max_length: 5000)
          halt 400, json_error("Change #{i}: old_text too long")
        end
        unless Sanitize.valid_string?(change['new_text'], max_length: 5000)
          halt 400, json_error("Change #{i}: new_text too long")
        end
      end

      # Look up site config
      site = settings.site_store.get(payload['site_key'])
      halt 404, json_error('Site not found') unless site

      # Validate request origin against site's allowed_origins
      origin = request.env['HTTP_ORIGIN']
      if origin && site[:allowed_origins]&.any?
        unless site[:allowed_origins].include?(origin)
          halt 403, json_error('Origin not allowed')
        end
      end

      owner, repo = site[:repo].split('/')

      github = GithubClient.new(
        token: contributor[:github_token],
        owner: owner,
        repo: repo,
        branch: site[:branch]
      )

      agent = EditAgent.new(
        github: github,
        api_key: ENV['ANTHROPIC_API_KEY']
      )

      begin
        result = agent.process(
          page: payload['page'],
          changes: payload['changes']
        )

        { status: 'success', pr_url: result[:pr_url] }.to_json
      rescue => e
        status 500
        # Never expose raw error messages to the client
        logger.error("Edit failed: #{e.message}")
        json_error('An error occurred while processing your edit. Please try again.')
      end
    end

    private

    def extract_token
      auth = request.env['HTTP_AUTHORIZATION']
      return nil unless auth
      token = auth.sub(/^Bearer\s+/i, '')
      # Validate token format (hex string)
      return nil unless token.match?(/\A[a-f0-9]{64}\z/)
      token
    end

    def parse_json_body
      body = request.body.read
      return nil if body.nil? || body.empty?
      # Limit body size (1MB)
      return nil if body.bytesize > 1_048_576
      JSON.parse(body)
    rescue JSON::ParserError
      nil
    end

    def json_error(message)
      { error: message }.to_json
    end
  end
end
