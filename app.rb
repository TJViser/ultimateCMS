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
require_relative 'lib/jwt_session'

module UltimateCMS
  class App < Sinatra::Base

    # ============================================
    # SECURITY MIDDLEWARE
    # ============================================

    use Rack::Protection, except: [:json_csrf]
    use Rack::Protection::ContentSecurityPolicy,
      default_src: "'self'",
      script_src: "'self'",
      style_src: "'self' 'unsafe-inline'",
      img_src: "'self' https://avatars.githubusercontent.com",
      connect_src: "'self' https://api.github.com",
      frame_ancestors: "'none'"

    Rack::Attack.throttle('api/edit', limit: 10, period: 60) do |req|
      req.ip if req.path == '/api/edit' && req.post?
    end
    Rack::Attack.throttle('api/sites', limit: 5, period: 60) do |req|
      req.ip if req.path.start_with?('/api/owner/sites') && req.post?
    end
    Rack::Attack.throttle('auth', limit: 10, period: 300) do |req|
      req.ip if req.path.start_with?('/auth/')
    end
    use Rack::Attack

    use Rack::Cors do
      allow do
        # Same-origin requests for dashboard API + static assets
        origins do |source, _env|
          # Allow same-origin always; cross-origin is validated per-endpoint
          source
        end
        resource '/api/owner/*', headers: :any, methods: [:get, :post, :patch, :delete, :options], credentials: true
        resource '/ucms.js', headers: :any, methods: [:get]
        resource '/editor.js', headers: :any, methods: [:get]
      end

      # /api/edit and /api/sites need cross-origin access (called from embedded scripts)
      allow do
        origins do |source, _env|
          # All origins allowed at CORS level; per-site validation in endpoint
          source
        end
        resource '/api/edit', headers: :any, methods: [:post, :options], credentials: true
        resource '/api/sites', headers: :any, methods: [:get, :post, :options], credentials: true
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

    before '/api/*' do
      origin = request.env['HTTP_ORIGIN']
      next unless origin

      if request.path == '/api/edit' && request.post?
        # Origin checked after payload is parsed (in the endpoint)
      end
    end

    # ============================================
    # PAGES
    # ============================================

    get '/' do
      send_file File.join(settings.public_folder, 'index.html')
    end

    get '/dashboard' do
      send_file File.join(settings.public_folder, 'dashboard.html')
    end

    # ============================================
    # DASHBOARD AUTH (for site owners)
    # ============================================

    get '/auth/github/dashboard' do
      client_id = ENV['GITHUB_CLIENT_ID']
      halt 500, 'GITHUB_CLIENT_ID not configured' unless client_id

      nonce = SecureRandom.hex(16)
      state = "dashboard:#{nonce}"

      settings.site_store.save_oauth_state(nonce, {
        site_key: 'dashboard',
        flow: 'dashboard'
      })

      redirect_uri = "#{request.base_url}/auth/github/dashboard/callback"

      redirect "https://github.com/login/oauth/authorize?" + URI.encode_www_form(
        client_id: client_id,
        redirect_uri: redirect_uri,
        state: state,
        scope: 'repo'
      )
    end

    get '/auth/github/dashboard/callback' do
      code = params['code']
      state = params['state']

      halt 400, 'Missing code or state' unless code && state

      prefix, nonce = state.split(':', 2)
      halt 400, 'Invalid state' unless prefix == 'dashboard' && nonce

      stored_state = settings.site_store.get_oauth_state(nonce)
      halt 403, 'Invalid or expired OAuth state' unless stored_state
      halt 403, 'State mismatch' unless stored_state[:flow] == 'dashboard'

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

      # Create JWT session
      session_token = JwtSession.encode(
        github_token: access_token,
        username: user['login'],
        avatar: user['avatar_url'],
        flow: 'dashboard'
      )

      # Redirect back to dashboard with token in fragment (not query — fragments aren't sent to server)
      redirect "/dashboard#token=#{URI.encode_www_form_component(session_token)}"
    end

    # ============================================
    # DASHBOARD API (site owner endpoints)
    # ============================================

    # Get authenticated owner's profile
    get '/api/owner/me' do
      content_type :json
      owner = authenticate_owner!

      {
        username: owner[:username],
        avatar: owner[:avatar]
      }.to_json
    end

    # List sites for authenticated owner
    get '/api/owner/sites' do
      content_type :json
      owner = authenticate_owner!

      sites = settings.site_store.list_for_owner(owner[:username])
      sites.map do |s|
        {
          key: s[:key],
          repo: s[:repo],
          branch: s[:branch],
          allowed_origins: s[:allowed_origins] || [],
          created_at: s[:created_at],
          embed_script: "<script src=\"#{Sanitize.escape_html(request.base_url)}/ucms.js\" data-site=\"#{Sanitize.escape_html(s[:key])}\"></script>"
        }
      end.to_json
    end

    # Create a new site
    post '/api/owner/sites' do
      content_type :json
      owner = authenticate_owner!

      payload = parse_json_body
      halt 400, json_error('Invalid JSON') unless payload

      # Validate required fields
      halt 400, json_error('Missing repository') unless payload['repo'].is_a?(String) && !payload['repo'].empty?
      unless Sanitize.valid_repo?(payload['repo'])
        halt 400, json_error('Invalid repo format. Expected: owner/repo')
      end

      branch = payload['branch'] || 'main'
      unless Sanitize.valid_branch?(branch)
        halt 400, json_error('Invalid branch name')
      end

      # Validate allowed_origins
      allowed_origins = Array(payload['allowed_origins']).select { |o| o.is_a?(String) && !o.empty? }
      allowed_origins.each do |origin|
        unless Sanitize.valid_url?(origin)
          halt 400, json_error("Invalid origin URL: #{Sanitize.escape_html(origin)}")
        end
      end

      # Limit sites per owner (prototype: max 20)
      existing = settings.site_store.list_for_owner(owner[:username])
      halt 400, json_error('Site limit reached (max 20)') if existing.length >= 20

      # Prevent duplicate site (same repo + branch)
      duplicate = existing.find { |s| s[:repo] == payload['repo'] && s[:branch] == branch }
      if duplicate
        halt 409, json_error("Site already exists for #{payload['repo']} (#{branch})")
      end

      site = settings.site_store.create(
        repo: payload['repo'],
        branch: branch,
        github_token: owner[:github_token],
        allowed_origins: allowed_origins,
        owner: owner[:username]
      )

      status 201
      {
        key: site[:key],
        repo: site[:repo],
        branch: site[:branch],
        allowed_origins: site[:allowed_origins],
        created_at: site[:created_at],
        embed_script: "<script src=\"#{Sanitize.escape_html(request.base_url)}/ucms.js\" data-site=\"#{Sanitize.escape_html(site[:key])}\"></script>"
      }.to_json
    end

    # Update a site
    patch '/api/owner/sites/:key' do
      content_type :json
      owner = authenticate_owner!
      site_key = params['key']

      # Validate key format
      unless Sanitize.valid_string?(site_key, max_length: 50, pattern: /\Ask_[a-f0-9]+\z/)
        halt 400, json_error('Invalid site key')
      end

      site = settings.site_store.get(site_key)
      halt 404, json_error('Site not found') unless site
      halt 403, json_error('Not your site') unless site[:owner] == owner[:username]

      payload = parse_json_body
      halt 400, json_error('Invalid JSON') unless payload

      updates = {}

      if payload.key?('branch')
        unless Sanitize.valid_branch?(payload['branch'])
          halt 400, json_error('Invalid branch name')
        end
        updates[:branch] = payload['branch']
      end

      if payload.key?('allowed_origins')
        origins = Array(payload['allowed_origins']).reject { |o| !o.is_a?(String) || o.empty? }
        origins.each do |origin|
          unless Sanitize.valid_url?(origin)
            halt 400, json_error("Invalid origin URL: #{Sanitize.escape_html(origin)}")
          end
        end
        updates[:allowed_origins] = origins
      end

      updated = settings.site_store.update(site_key, **updates)
      halt 404, json_error('Site not found') unless updated

      {
        key: updated[:key],
        repo: updated[:repo],
        branch: updated[:branch],
        allowed_origins: updated[:allowed_origins] || [],
        created_at: updated[:created_at],
        embed_script: "<script src=\"#{Sanitize.escape_html(request.base_url)}/ucms.js\" data-site=\"#{Sanitize.escape_html(updated[:key])}\"></script>"
      }.to_json
    end

    # Delete a site
    delete '/api/owner/sites/:key' do
      content_type :json
      owner = authenticate_owner!
      site_key = params['key']

      # Validate key format
      unless Sanitize.valid_string?(site_key, max_length: 50, pattern: /\Ask_[a-f0-9]+\z/)
        halt 400, json_error('Invalid site key')
      end

      site = settings.site_store.get(site_key)
      halt 404, json_error('Site not found') unless site
      halt 403, json_error('Not your site') unless site[:owner] == owner[:username]

      settings.site_store.delete(site_key)
      { status: 'deleted' }.to_json
    end

    # ============================================
    # CONTRIBUTOR AUTH (for editing)
    # ============================================

    get '/auth/github' do
      site_key = params['site']
      client_id = ENV['GITHUB_CLIENT_ID']

      halt 500, 'GITHUB_CLIENT_ID not configured' unless client_id

      unless site_key && Sanitize.valid_string?(site_key, max_length: 50, pattern: /\Ask_[a-f0-9]+\z/)
        halt 400, 'Invalid site key'
      end

      nonce = SecureRandom.hex(16)
      state = "#{site_key}:#{nonce}"

      settings.site_store.save_oauth_state(nonce, {
        site_key: site_key,
        flow: 'contributor'
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

      site_key, nonce = state.split(':', 2)
      halt 400, 'Invalid state' unless nonce

      stored_state = settings.site_store.get_oauth_state(nonce)
      halt 403, 'Invalid or expired OAuth state' unless stored_state
      halt 403, 'State mismatch' unless stored_state[:site_key] == site_key

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

      session_token = JwtSession.encode(
        github_token: access_token,
        username: user['login'],
        avatar: user['avatar_url'],
        flow: 'contributor',
        site_key: site_key
      )

      # Determine allowed origin for postMessage
      site = settings.site_store.get(site_key)
      post_message_origin = if site && site[:allowed_origins]&.any?
        Sanitize.escape_js(site[:allowed_origins].first)
      else
        Sanitize.escape_js(request.base_url)
      end

      safe_token = Sanitize.escape_js(session_token)
      safe_username = Sanitize.escape_js(user['login'].to_s)
      safe_avatar = Sanitize.escape_js(user['avatar_url'].to_s)

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

      session_token = extract_token
      halt 401, json_error('Not authenticated') unless session_token

      contributor = JwtSession.decode(session_token)
      halt 401, json_error('Invalid or expired session') unless contributor

      payload = parse_json_body
      halt 400, json_error('Invalid JSON') unless payload

      halt 400, json_error('Missing site_key') unless payload['site_key'].is_a?(String)
      halt 400, json_error('Missing page') unless payload['page'].is_a?(Hash)
      halt 400, json_error('Missing changes') unless payload['changes'].is_a?(Array)
      halt 400, json_error('Too many changes') if payload['changes'].length > 50

      page = payload['page']
      unless page['url'].is_a?(String) && page['path'].is_a?(String)
        halt 400, json_error('Invalid page data')
      end
      halt 400, json_error('Invalid page URL') unless Sanitize.valid_url?(page['url'])

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

      site = settings.site_store.get(payload['site_key'])
      halt 404, json_error('Site not found') unless site

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
        logger.error("Edit failed: #{e.message}")
        json_error('An error occurred while processing your edit. Please try again.')
      end
    end

    # ============================================
    # LEGACY SITE REGISTRATION (API-only)
    # ============================================

    post '/api/sites' do
      content_type :json

      payload = parse_json_body
      halt 400, json_error('Invalid JSON') unless payload

      %w[repo branch github_token].each do |f|
        halt 400, json_error("Missing: #{f}") unless payload[f]
      end

      unless Sanitize.valid_repo?(payload['repo'])
        halt 400, json_error('Invalid repo format. Expected: owner/repo')
      end

      unless Sanitize.valid_branch?(payload['branch'] || 'main')
        halt 400, json_error('Invalid branch name')
      end

      unless Sanitize.valid_string?(payload['github_token'], max_length: 500)
        halt 400, json_error('Invalid token')
      end

      allowed_origins = Array(payload['allowed_origins']).select { |o| o.is_a?(String) && !o.empty? }
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

      session = JwtSession.decode(token)
      halt 401, json_error('Invalid session') unless session

      sites = settings.site_store.list_for_token(session[:github_token])
      sites.map { |s| { key: s[:key], repo: s[:repo], branch: s[:branch] } }.to_json
    end

    private

    def authenticate_owner!
      token = extract_token
      halt 401, json_error('Not authenticated') unless token

      session = JwtSession.decode(token)
      halt 401, json_error('Invalid or expired session') unless session

      session
    end

    def extract_token
      auth = request.env['HTTP_AUTHORIZATION']
      return nil unless auth
      token = auth.sub(/^Bearer\s+/i, '')
      # Accept JWT format: three base64url segments separated by dots
      return nil unless token.match?(/\A[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\z/)
      token
    end

    def parse_json_body
      body = request.body.read
      return nil if body.nil? || body.empty?
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
